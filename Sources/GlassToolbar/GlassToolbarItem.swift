import AppKit
import SwiftUI // only for `Spring`, the spring maths SwiftUI and UIKit bars use

/// A toolbar item made of our own Liquid Glass pills, whose changes animate the way iOS bar buttons do.
///
/// Used like an `NSToolbarItemGroup`: where a group takes `subitems` and AppKit puts them on one piece of
/// glass, this takes `groups` — one array of views per pill — and draws the glass itself. Views are
/// usually `GlassToolbarButton`s; any other view (the Rive refresh glyph) is hosted at its fitting size.
///
/// Why not the system's items: AppKit snaps its toolbar when items are added, removed, shown or hidden —
/// the glass jumps to its new size in one frame. Ours spring:
/// - a pill keeps its identity while any of its views stays, so its width springs (interruptibly: a new
///   change continues from the current width and speed), staying views slide, new ones come into focus
///   out of a blur and leaving ones blur away (`GlassToolbarTransition`);
/// - pills that share no views are paired by position from the anchored edge, so one screen's actions
///   turn into the next screen's rather than one set leaving while another arrives;
/// - a pill with no partner grows out of, or shrinks into, its place;
/// - a pill whose contents change briefly swells and reaches across to its neighbour, and since all the
///   pills are in one `NSGlassEffectContainerView` their glass bridges and parts again, as on iOS.
///
/// Everything is stepped per display frame by the bar itself: constraint `animator()`s ignore custom
/// timing curves, and NSToolbar lays items out in whole points, so the item's slot is rounded up and the
/// glass placed inside it at fractional positions — otherwise it moves in uneven 1–4pt jumps.
@MainActor
public final class GlassToolbarItem: NSToolbarItem {

    /// The edge the pills stay put against while their widths change; the item grows away from it.
    public enum Anchor: Sendable { case leading, trailing }

    private let bar: GlassPillBar
    /// Groups waiting for the toolbar to put the view back after unhiding the item.
    private var pendingReveal: [[NSView]]?

    public init(itemIdentifier: NSToolbarItem.Identifier, anchor: Anchor = .trailing) {
        bar = GlassPillBar(anchor: anchor)
        super.init(itemIdentifier: itemIdentifier)
        view = bar
        isBordered = false
        bar.debugName = itemIdentifier.rawValue
        // Empty, the item hides: the toolbar gives even a zero-width item a 36pt slot.
        bar.onSettledEmpty = { [weak self] in
            guard let self, pendingReveal == nil, bar.groups.isEmpty else { return }
            isHidden = true
        }
    }

    /// The pills, as last set: one array of views per pill.
    public var groups: [[NSView]] { pendingReveal ?? bar.groups }

    /// Sets the pills, animating from what is on screen. Calling it again with the same groups is cheap
    /// and re-measures the views, so a view whose size changed (a glyph's inset) is followed.
    public func setGroups(_ groups: [[NSView]], animated: Bool = true) {
        if pendingReveal != nil {
            pendingReveal = groups
            return
        }
        guard isHidden, groups.contains(where: { !$0.isEmpty }) else {
            return bar.setGroups(groups, animated: animated)
        }
        // Coming back from hidden: the toolbar re-inserts the view when it gets to it — sometimes at once,
        // sometimes a pass or two later — and the pills grow in once it is on screen. Set before that,
        // they would be measured and placed out of a window, and appear without growing.
        isHidden = false
        pendingReveal = groups
        let reveal = { [weak self] in
            guard let self, let groups = pendingReveal else { return }
            pendingReveal = nil
            bar.setGroups(groups, animated: animated)
        }
        if bar.window != nil {
            DispatchQueue.main.async { reveal() }
        } else {
            bar.whenInWindow = reveal
        }
    }

    /// Between the buttons of one pill. 8pt is what `NSToolbarItemGroup` puts between its subitems; the
    /// system's pill of plain adjacent items has none, so use 0 to look like that.
    public var buttonSpacing: CGFloat {
        get { bar.buttonSpacing }
        set { bar.buttonSpacing = newValue }
    }

    /// For pills drawn over something with an appearance of its own — the open letter. `nil` follows
    /// the window.
    public var contentAppearance: NSAppearance? {
        get { bar.appearance }
        set { bar.appearance = newValue }
    }
}

// MARK: - Bar

/// The item's view: the pills inside one glass container, laid out from the anchored edge.
@MainActor
final class GlassPillBar: NSView {

    static let pillHeight: CGFloat = 36
    /// Room above and below for the swell, so it never changes the toolbar's own layout.
    private static let swellHeadroom: CGFloat = 4
    /// Between two pills at rest, and the distance at which the container starts merging their glass —
    /// just under the gap, so they are apart at rest and bridge while one reaches across.
    static let gap: CGFloat = 8
    private static let mergeSpacing: CGFloat = 7
    /// Kept clear between the anchored edge of the item's slot and the first pill.
    ///
    /// The toolbar pads the slot of one of its own glass items by 4pt on every side that does not face a
    /// flexible space: the system's Back button sat 4pt in from the column separator, and its pills 4pt
    /// short of the separator and of the window's edge (8pt from the edge itself). An item with a view of
    /// its own, as this one is, gets a slot the exact size of the view, so without this the pills sit 4pt
    /// closer to those edges than the sidebar toggle next to them. The anchored edge is the one facing
    /// something fixed; the other side grows into a flexible space, where the system pads nothing either.
    static let anchoredEdgeMargin: CGFloat = 4

    /// Fitted to a recording of iOS 27 bar buttons: half way in ~180ms, 90% in ~330ms.
    nonisolated static let spring = Spring(duration: 0.675, bounce: 0.16)

    /// Debug only: `GLASS_TOOLBAR_SLOWMO=6` plays every pill animation six times slower.
    nonisolated static let slowdown: Double = {
        #if DEBUG
        ProcessInfo.processInfo.environment["GLASS_TOOLBAR_SLOWMO"].flatMap(Double.init) ?? 1
        #else
        1
        #endif
    }()

    let anchor: GlassToolbarItem.Anchor
    var buttonSpacing: CGFloat = 8
    /// The item's identifier, for the debug self-check's reports.
    var debugName = ""
    private let container = NSGlassEffectContainerView()
    private let stage = NSView()
    private var widthConstraint: NSLayoutConstraint!

    /// Leading to trailing, including pills on their way out.
    private var pills: [GlassPill] = []
    /// Views that need a host to be laid out by frame (they size themselves with constraints).
    private var hosts: [ObjectIdentifier: GlassPillMemberHost] = [:]
    private var displayLink: CADisplayLink?
    /// Toolbar buttons only report their real size once in a window; until then nothing animates.
    private var isMeasured = false

    /// Called when the motion has ended with no pills left.
    var onSettledEmpty: (() -> Void)?
    /// Run once the view is next in a window (and measured there), instead of the usual settle.
    var whenInWindow: (() -> Void)?

    /// Where each pill's glass goes, worked out per frame from the anchored edge, then placed in
    /// `layout()` against the bounds the toolbar actually gave us.
    private var placements: [ObjectIdentifier: GlassPill.Placement] = [:]

    var groups: [[NSView]] {
        pills.filter { !$0.isLeaving }.map { $0.members.map { ($0 as? GlassPillMemberHost)?.hosted ?? $0 } }
    }

    init(anchor: GlassToolbarItem.Anchor) {
        self.anchor = anchor
        super.init(frame: NSRect(x: 0, y: 0, width: 0, height: Self.pillHeight + Self.swellHeadroom))
        translatesAutoresizingMaskIntoConstraints = false
        container.spacing = Self.mergeSpacing
        container.contentView = stage
        addSubview(container)
        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            widthConstraint,
            heightAnchor.constraint(equalToConstant: Self.pillHeight + Self.swellHeadroom),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: Setting the pills

    func setGroups(_ newGroups: [[NSView]], animated: Bool) {
        let groups = newGroups.filter { !$0.isEmpty }.map { $0.map(member(for:)) }
        // In a window the buttons measure right, which is all animating needs; out of one there is
        // nothing on screen to animate.
        let animated = animated && window != nil
        let now = clock(CACurrentMediaTime())
        #if DEBUG
        if GlassToolbarSelfCheck.isOn, !animated, window != nil,
           groups.map({ $0.map(ObjectIdentifier.init) }) != pills.filter({ !$0.isLeaving }).map({ $0.members.map(ObjectIdentifier.init) }) {
            GlassToolbarSelfCheck.report("SNAP \(debugName): a visible change was not animated")
        }
        #endif

        // A pill that keeps any of its views is the same pill — a leaving one comes back.
        var assigned: [Int: GlassPill] = [:]
        var taken = Set<ObjectIdentifier>()
        for (index, group) in groups.enumerated() {
            if let pill = pills.first(where: { pill in
                !taken.contains(ObjectIdentifier(pill)) && group.contains { pill.owns($0) }
            }) {
                assigned[index] = pill
                taken.insert(ObjectIdentifier(pill))
            }
        }
        // The rest pair up by position, counted from the anchored edge.
        var freePills = pills.filter { !$0.isLeaving && !taken.contains(ObjectIdentifier($0)) }
        var freeGroups = groups.indices.filter { assigned[$0] == nil }
        if anchor == .trailing {
            freePills.reverse()
            freeGroups.reverse()
        }
        for (pill, index) in zip(freePills, freeGroups) {
            assigned[index] = pill
            taken.insert(ObjectIdentifier(pill))
        }

        // New order: the groups' order, with pills on their way out kept near where they were.
        let oldIndex = Dictionary(uniqueKeysWithValues: pills.enumerated().map { (ObjectIdentifier($1), $0) })
        let departing = pills.filter { !taken.contains(ObjectIdentifier($0)) }
        var leaving = departing
        var order: [GlassPill] = []
        var resolved: [(pill: GlassPill, group: [NSView], isNew: Bool)] = []
        for (index, group) in groups.enumerated() {
            if let pill = assigned[index] {
                if let position = oldIndex[ObjectIdentifier(pill)] {
                    while let first = leaving.first, (oldIndex[ObjectIdentifier(first)] ?? .max) < position {
                        order.append(leaving.removeFirst())
                    }
                }
                order.append(pill)
                resolved.append((pill, group, false))
            } else {
                let pill = GlassPill(anchorsTrailing: anchor == .trailing, spacing: { [unowned self] in buttonSpacing })
                stage.addSubview(pill.glass)
                order.append(pill)
                resolved.append((pill, group, true))
            }
        }
        order.append(contentsOf: leaving)
        pills = order

        // A view that moved to another pill is that pill's now, not one leaving this one.
        let claimed = Set(groups.flatMap { $0 }.map(ObjectIdentifier.init))
        for entry in resolved {
            entry.pill.setMembers(entry.group, claimedElsewhere: claimed, isNew: entry.isNew,
                                  animated: animated, now: now)
        }
        for pill in departing where !pill.isLeaving {
            pill.leave(animated: animated, now: now)
        }

        guard animated else { return finish() }
        if pills.contains(where: { !$0.isSettled(at: now) }) {
            startTicking()
            advance(to: now)
        } else if displayLink == nil {
            // Nothing moving: just keep the layout current (a re-measured width, an inset).
            finish()
        }
    }

    /// The view laid out in a pill for `view`: a `GlassToolbarButton` itself, anything else wrapped in a
    /// host that sizes it from its constraints.
    private func member(for view: NSView) -> NSView {
        guard !(view is GlassToolbarButton) else { return view }
        if let host = hosts[ObjectIdentifier(view)] { return host }
        let host = GlassPillMemberHost(hosting: view)
        hosts[ObjectIdentifier(view)] = host
        return host
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else {
            finish()
            return
        }
        // Deferred: this runs inside the toolbar's own insertion pass, which ignores a width set now and
        // keeps the slot it had.
        // Not while something is moving: a pill growing in as the item is unhidden would snap to rest.
        DispatchQueue.main.async { [weak self] in
            guard let self, window != nil else { return }
            isMeasured = true
            if let whenInWindow {
                self.whenInWindow = nil
                whenInWindow()
            } else if displayLink == nil {
                finish()
            }
        }
    }

    // MARK: Accessibility

    // A group of its buttons, so VoiceOver reaches each of them; left to itself the toolbar showed the
    // item as one button named after its label, with nothing inside.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityChildren() -> [Any]? {
        NSAccessibility.unignoredChildren(from: Array(groups.joined()))
    }

    // MARK: Motion

    private func startTicking() {
        guard displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Sampled at the time the frame will be on screen, not when the callback happens to run: callback
    /// timing jitters by several milliseconds, which reads as uneven steps.
    @objc private func tick(_ link: CADisplayLink) {
        advance(to: clock(link.targetTimestamp))
    }

    /// The bar's own animation time. While something moves it never advances more than `maxStep`
    /// between two frames: when the main thread is busy — opening an email loads it, often right after
    /// the change that started the motion — the motion pauses and carries on from where it was, rather
    /// than leaping to wherever the spring would have got to meanwhile. Core Animation's animations
    /// run outside the main thread and need no such care; these are stepped on it.
    private func clock(_ time: CFTimeInterval) -> CFTimeInterval {
        var t = time - clockSkew
        if displayLink != nil, let last = lastClock, t - last > Self.maxStep {
            clockSkew += t - last - Self.maxStep
            t = last + Self.maxStep
        }
        // Frames are stepped to when they will be on screen, a little ahead of now; a change made in
        // between must not take the motion back to before the frame already drawn.
        if let last = lastClock, t < last { t = last }
        lastClock = t
        return t
    }

    private var clockSkew: CFTimeInterval = 0
    private var lastClock: CFTimeInterval?
    /// Two frames at 60Hz: a single late frame still moves at full speed.
    private static let maxStep: CFTimeInterval = 0.034

    private func advance(to now: CFTimeInterval) {
        place(at: now)
        if pills.allSatisfy({ $0.isSettled(at: now) }) {
            finish()
        }
    }

    /// Ends all motion: leaving pills and views go, everything else snaps to rest.
    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        for pill in pills where pill.isLeaving {
            pill.detach()
        }
        pills.removeAll { $0.isLeaving }
        for pill in pills {
            pill.settle(remeasure: isMeasured)
        }
        place(at: clock(CACurrentMediaTime()))
        if pills.isEmpty { onSettledEmpty?() }
        #if DEBUG
        if GlassToolbarSelfCheck.isOn {
            // After the toolbar has laid the item out, and only if nothing started moving meanwhile.
            DispatchQueue.main.async { [weak self] in
                // Out of a window there is nothing on screen to check, and nothing is laid out.
                guard let self, displayLink == nil, window != nil else { return }
                selfCheck()
            }
        }
        #endif
    }

    #if DEBUG
    private var lastTrace: (time: CFTimeInterval, edges: [ObjectIdentifier: (near: CGFloat, far: CGFloat)], moving: Bool, infos: [ObjectIdentifier: String])?

    /// A pill edge moving further in one frame than the spring ever does (~8pt at its fastest, for the
    /// widest change) means something snapped. In distances from the anchored edge, so the toolbar
    /// moving the whole item doesn't count; scaled up for a frame the app dropped.
    private func traceJumps(at now: CFTimeInterval) {
        let edges = placements.mapValues { (near: $0.near, far: $0.far) }
        let infos = placements.mapValues(\.debugInfo)
        if let last = lastTrace, now > last.time {
            // After a pause the last trace is the resting position, which a start must not jump from.
            // A long gap while moving is the main thread stalling mid-motion: reported, not judged.
            let gap = now - last.time
            if gap > 0.1, last.moving {
                GlassToolbarSelfCheck.report(String(format: "STALL %@: no frame for %.0fms mid-motion", debugName, gap * 1000))
                lastTrace = (now, edges, displayLink != nil, infos)
                return
            }
            let frames = gap > 0.1 ? 1 : max(1, gap / (1.0 / 60))
            for (key, edge) in edges {
                guard let before = last.edges[key] else { continue }
                let moved = max(abs(edge.near - before.near), abs(edge.far - before.far))
                if moved > 20 * frames {
                    GlassToolbarSelfCheck.report(String(
                        format: "JUMP %@: a pill edge moved %.1fpt in %.0fms: %.1f…%.1f → %.1f…%.1f; was %@, now %@",
                        debugName, moved, (now - last.time) * 1000, before.near, before.far, edge.near, edge.far,
                        last.infos[key] ?? "?", infos[key] ?? "?"))
                }
            }
        }
        lastTrace = (now, edges, displayLink != nil, infos)
    }

    /// Everything that should hold once the bar is at rest.
    private func selfCheck() {
        var problems: [String] = []
        if pills.contains(where: \.isLeaving) { problems.append("a leaving pill is still there") }
        let glassViews = Set(pills.map { ObjectIdentifier($0.glass) })
        if Set(stage.subviews.map(ObjectIdentifier.init)) != glassViews {
            problems.append("stage has \(stage.subviews.count) views for \(pills.count) pills")
        }
        for (index, pill) in pills.enumerated() {
            problems += pill.debugProblems(in: bounds).map { "pill \(index): \($0)" }
        }
        let widths = pills.map(\.restWidth)
        let expected = Self.slotWidth(forPillsSpanning: widths.reduce(0, +) + Self.gap * CGFloat(max(0, widths.count - 1)))
        if abs(widthConstraint.constant - expected) > 0.5 {
            problems.append("slot \(widthConstraint.constant) for pills needing \(expected)")
        }
        if window != nil, !pills.isEmpty, abs(bounds.width - widthConstraint.constant) > 0.5 {
            problems.append("toolbar gave \(bounds.width) for a \(widthConstraint.constant) slot")
        }
        if problems.isEmpty {
            GlassToolbarSelfCheck.report("OK \(debugName) pills=\(pills.map { $0.members.count })")
        } else {
            GlassToolbarSelfCheck.report("FAIL \(debugName): " + problems.joined(separator: "; "))
        }
    }
    #endif

    /// Works out every pill's glass for the moment `now`, as distances from the anchored edge.
    private func place(at now: CFTimeInterval) {
        let outward = anchor == .trailing ? Array(pills.reversed()) : pills
        var cursor: CGFloat = 0
        var previousPresence: CGFloat?
        var spans: [(pill: GlassPill, near: CGFloat, far: CGFloat, state: GlassPill.State)] = []
        for (index, pill) in outward.enumerated() {
            let state = pill.state(at: now)
            if let previousPresence {
                // A pill's gap comes and goes with it.
                cursor += Self.gap * min(previousPresence, state.presence)
            }
            let occupied = state.width * state.presence
            var near = cursor, far = cursor + occupied
            if state.swell > 0 || state.swell < 0 {
                if index == 0 {
                    // Against the anchored edge it can only grow outward.
                    far += state.swell
                } else {
                    near -= state.swell / 2
                    far += state.swell / 2
                }
            }
            spans.append((pill, near, far, state))
            cursor += occupied
            previousPresence = state.presence
        }

        placements = [:]
        var extent: CGFloat = 0
        for (index, span) in spans.enumerated() {
            var near = span.near, far = span.far
            let core = (near: near, far: far)
            // Reaching across the gap to the neighbour on the anchored side (or the other side, for the
            // pill against the edge), so their glass bridges.
            if span.state.reach > 0 {
                if index > 0 {
                    near -= max(0, near - spans[index - 1].far) * span.state.reach
                } else if index + 1 < spans.count {
                    far += max(0, spans[index + 1].near - far) * span.state.reach
                }
            }
            let height = Self.pillHeight * min(span.state.presence, 1) + span.state.swell
            placements[ObjectIdentifier(span.pill)] = .init(
                near: near, far: far, coreNear: core.near, coreFar: core.far,
                height: max(0, height), layoutWidth: span.state.width, slide: span.state.slide,
                contentExtra: span.state.contentExtra
            )
            #if DEBUG
            placements[ObjectIdentifier(span.pill)]?.debugInfo = String(
                format: "#%d/%d%@ views=%d p=%.2f reach=%.2f swell=%.1f w=%.1f presence[%@]",
                index, spans.count, span.pill.isLeaving ? " leaving" : "", span.pill.members.count,
                span.state.presence, span.state.reach, span.state.swell, span.state.width,
                span.pill.debugPresence(at: now))
            #endif
            extent = max(extent, far)
        }

        #if DEBUG
        if GlassToolbarSelfCheck.isOn { traceJumps(at: now) }
        #endif

        let slot = Self.slotWidth(forPillsSpanning: extent)
        if widthConstraint.constant != slot {
            widthConstraint.constant = slot
        }
        needsLayout = true
    }

    /// The slot for pills reaching `extent` from the anchored edge: whole points, as the toolbar lays
    /// items out, with the margin the system leaves its own pills. Nothing for no pills, so an emptied
    /// item takes no room in the moment before it hides.
    static func slotWidth(forPillsSpanning extent: CGFloat) -> CGFloat {
        guard extent > 0.001 else { return 0 }
        return (extent + anchoredEdgeMargin - 0.001).rounded(.up)
    }

    override func layout() {
        super.layout()
        container.frame = bounds
        stage.frame = container.bounds
        for pill in pills {
            guard let placement = placements[ObjectIdentifier(pill)] else { continue }
            pill.apply(placement, in: bounds, anchor: anchor)
        }
    }
}

// MARK: - Pill

/// One piece of glass and the views on it.
@MainActor
private final class GlassPill {

    struct State {
        var width: CGFloat
        var presence: CGFloat
        var swell: CGFloat
        var reach: CGFloat
        var slide: CGFloat
        /// See `GlassPill.contentExtra(at:)`.
        var contentExtra: CGFloat
    }

    /// Distances from the anchored edge; `core` leaves out the reach, which only stretches the glass.
    struct Placement {
        var near: CGFloat, far: CGFloat
        var coreNear: CGFloat, coreFar: CGFloat
        var height: CGFloat
        var layoutWidth: CGFloat
        var slide: CGFloat
        var contentExtra: CGFloat
        #if DEBUG
        var debugInfo = ""
        #endif
    }

    let glass = NSGlassEffectView()
    private let content = NSView()

    /// In order; views in `leavingMembers` are fading out and stay subviews until the motion ends.
    private(set) var members: [NSView] = []
    private var leavingMembers: [NSView] = []
    private(set) var isLeaving = false

    private var width = GlassSpringTrack.rest(0)
    private var presence = GlassSpringTrack.rest(1)
    private var slideProgress = GlassSpringTrack.rest(1)
    private var slides: [ObjectIdentifier: (from: NSRect, to: NSRect)] = [:]
    private var fades: [ObjectIdentifier: (view: NSView, from: CGFloat, to: CGFloat, start: CFTimeInterval)] = [:]
    /// When the contents last changed: drives the swell and the reach.
    private var morphStart: CFTimeInterval?
    private var transitionsEnd: CFTimeInterval = 0

    /// Between this pill's views, from its bar.
    private let spacing: () -> CGFloat

    /// The views hang off the pill's anchored edge, as the glass does: while a trailing-anchored pill
    /// grows leftward, a view arriving at its trailing end is in view from the start rather than clipped
    /// until the glass reaches it.
    private let anchorsTrailing: Bool

    init(anchorsTrailing: Bool, spacing: @escaping () -> CGFloat) {
        self.anchorsTrailing = anchorsTrailing
        self.spacing = spacing
        glass.cornerRadius = GlassPillBar.pillHeight / 2
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        glass.contentView = content
    }

    #if DEBUG
    func debugPresence(at now: CFTimeInterval) -> String {
        guard let start = presence.start else { return "rest" }
        return String(format: "%.2f→%.2f v=%.2f t=%.0fms", presence.from, presence.to, presence.velocity, (now - start) * 1000)
    }

    var restWidth: CGFloat { slotFrames().last?.maxX ?? 0 }

    func debugProblems(in bounds: NSRect) -> [String] {
        var problems: [String] = []
        if members.isEmpty { problems.append("no views") }
        if !leavingMembers.isEmpty { problems.append("\(leavingMembers.count) leaving views left") }
        if Set(content.subviews.map(ObjectIdentifier.init)) != Set(members.map(ObjectIdentifier.init)) {
            problems.append("content has \(content.subviews.count) views for \(members.count) members")
        }
        for (view, frame) in zip(members, slotFrames()) {
            let name = view.accessibilityLabel() ?? "\(type(of: view))"
            if view.alphaValue != 1 { problems.append("\(name) alpha \(view.alphaValue)") }
            if !view.contentFilters.isEmpty { problems.append("\(name) still blurred") }
            if GlassToolbarTransition.isRunning(on: view) { problems.append("\(name) transition stuck") }
            if abs(view.frame.minX - frame.minX) > 0.5 || abs(view.frame.width - frame.width) > 0.5 {
                problems.append("\(name) at \(view.frame.minX)+\(view.frame.width), slot \(frame.minX)+\(frame.width)")
            }
        }
        if abs(glass.frame.width - restWidth) > 0.5 { problems.append("glass \(glass.frame.width) wide for \(restWidth)") }
        if abs(glass.frame.height - GlassPillBar.pillHeight) > 0.5 { problems.append("glass \(glass.frame.height) tall") }
        if glass.frame.minX < bounds.minX - 0.5 || glass.frame.maxX > bounds.maxX + 0.5 {
            problems.append("glass \(glass.frame) outside \(bounds)")
        }
        if content.bounds.origin != .zero { problems.append("content shifted \(content.bounds.origin)") }
        return problems
    }
    #endif

    func owns(_ view: NSView) -> Bool {
        members.contains { $0 === view } || leavingMembers.contains { $0 === view }
    }

    // MARK: Changes

    func setMembers(_ new: [NSView], claimedElsewhere claimed: Set<ObjectIdentifier>, isNew: Bool,
                    animated: Bool, now: CFTimeInterval) {
        let old = members
        let revived = isLeaving
        isLeaving = false
        // Coming back mid-exit, every view was on its way out: all of them come back into focus.
        let staying = revived ? [] : old.filter { view in new.contains { $0 === view } }
        let removed = old.filter { view in !new.contains { $0 === view } }
        let added = new.filter { view in !staying.contains { $0 === view } }

        // Attach first: toolbar buttons only report their real size inside a window, and positions next:
        // a button's width depends on them too (a lone one is 36pt, a grouped one 35pt).
        for view in added {
            leavingMembers.removeAll { $0 === view }
            if view.superview !== content { content.addSubview(view) }
        }
        members = new
        updateGroupPositions()
        let frames = slotFrames()
        let target = frames.last?.maxX ?? 0

        guard animated else {
            for view in removed where !claimed.contains(ObjectIdentifier(view)) {
                retire(view)
            }
            width = .rest(target)
            presence = .rest(1)
            return
        }

        // Retargeting the width moves where the content hangs from (`contentExtra`); views already on
        // screen are moved back by as much, so nothing jumps.
        var rebase: CGFloat = 0
        if isNew {
            width = .rest(target)
            presence = .init(from: 0, to: 1, start: now)
        } else {
            let before = contentExtra(at: now)
            // Also follows a view whose own size changed, without the rest of a change's motion.
            width.retarget(to: target, at: now)
            rebase = before - contentExtra(at: now)
            if revived { presence.retarget(to: 1, at: now) }
            if !added.isEmpty || !removed.isEmpty {
                morphStart = now
            }
        }
        guard !added.isEmpty || !removed.isEmpty || abs(rebase) > 0.001 else { return }
        for view in leavingMembers + removed {
            view.frame.origin.x += rebase
        }

        // Staying views slide from wherever they are now.
        slides = [:]
        for (view, frame) in zip(members, frames) where !added.contains(where: { $0 === view }) {
            slides[ObjectIdentifier(view)] = (view.frame.offsetBy(dx: rebase, dy: 0), frame)
        }
        slideProgress = .init(from: 0, to: 1, start: now)

        for (view, frame) in zip(members, frames) where added.contains(where: { $0 === view }) {
            view.frame = frame
            // A view coming back mid fade-out continues from where it got to.
            if !GlassToolbarTransition.isRunning(on: view) { view.alphaValue = 0 }
            fades[ObjectIdentifier(view)] = (view, view.alphaValue, 1, now)
            GlassToolbarTransition.run(on: view, appearing: true, slowdown: GlassPillBar.slowdown)
        }
        for view in removed where !claimed.contains(ObjectIdentifier(view)) {
            leavingMembers.append(view)
            fades[ObjectIdentifier(view)] = (view, view.alphaValue, 0, now)
            GlassToolbarTransition.run(on: view, appearing: false, slowdown: GlassPillBar.slowdown)
        }
        transitionsEnd = now + GlassToolbarTransition.duration * GlassPillBar.slowdown
    }

    func leave(animated: Bool, now: CFTimeInterval) {
        isLeaving = true
        guard animated else { return }
        presence.retarget(to: 0, at: now)
        for view in members {
            fades[ObjectIdentifier(view)] = (view, view.alphaValue, 0, now)
            GlassToolbarTransition.run(on: view, appearing: false, slowdown: GlassPillBar.slowdown)
        }
        transitionsEnd = now + GlassToolbarTransition.duration * GlassPillBar.slowdown
    }

    /// Back to rest: leaving views go, the rest at full opacity in their slots.
    func settle(remeasure: Bool) {
        for view in leavingMembers { retire(view) }
        leavingMembers = []
        fades = [:]
        slides = [:]
        morphStart = nil
        slideProgress = .rest(1)
        presence = .rest(1)
        for view in members { view.alphaValue = 1 }
        if remeasure { updateGroupPositions() }
        width = .rest(slotFrames().last?.maxX ?? 0)
    }

    func detach() {
        for view in members + leavingMembers { retire(view) }
        members = []
        leavingMembers = []
        glass.removeFromSuperview()
    }

    private func retire(_ view: NSView) {
        guard view.superview === content else { return }
        GlassToolbarTransition.reset(view)
        view.alphaValue = 1
        view.removeFromSuperview()
    }

    // MARK: Motion

    func state(at now: CFTimeInterval) -> State {
        let t = morphStart.map { (now - $0) / GlassPillBar.slowdown }
        for (key, fade) in fades {
            let duration = fade.to > fade.from ? 0.25 : 0.2
            let x = min(1, max(0, (now - fade.start) / GlassPillBar.slowdown / duration))
            fade.view.alphaValue = fade.from + (fade.to - fade.from) * CGFloat(1 - (1 - x) * (1 - x))
            if x >= 1 { fades[key] = nil }
        }
        return State(
            width: width.value(at: now),
            presence: max(0, presence.value(at: now)),
            swell: t.map(Self.swell(at:)) ?? 0,
            reach: t.map(Self.reach(at:)) ?? 0,
            slide: slideProgress.value(at: now),
            contentExtra: contentExtra(at: now)
        )
    }

    func isSettled(at now: CFTimeInterval) -> Bool {
        let morphDone = morphStart.map { (now - $0) / GlassPillBar.slowdown >= Self.morphDuration } ?? true
        return width.isSettled(at: now) && presence.isSettled(at: now) && slideProgress.isSettled(at: now)
            && morphDone && fades.isEmpty && now >= transitionsEnd
    }

    private static let morphDuration: TimeInterval = 0.45

    /// How far the content sits from where it rests, so it hangs off the anchored edge while the width
    /// springs: zero at rest, and for a leading-anchored pill always (its content starts there anyway).
    private func contentExtra(at now: CFTimeInterval) -> CGFloat {
        anchorsTrailing ? width.value(at: now) - width.to : 0
    }

    /// The glass "breath" on every change of contents: up ~4pt, slightly under, settled.
    private static func swell(at t: TimeInterval) -> CGFloat {
        keyframes([(0, 0), (0.13, 4), (0.3, -0.6), (0.45, 0)], at: t)
    }

    /// How far across the gap to the neighbour the glass reaches, 0…1: across fast, hold, let go. From a
    /// recording of iOS 27: it touches the neighbour ~0.1s in and parts again by ~0.35s.
    private static func reach(at t: TimeInterval) -> CGFloat {
        keyframes([(0, 0), (0.11, 1), (0.2, 1), (0.36, 0)], at: t)
    }

    private static func keyframes(_ keys: [(t: TimeInterval, v: CGFloat)], at t: TimeInterval) -> CGFloat {
        guard let last = keys.last, t < last.t, t >= 0 else { return 0 }
        let i = keys.lastIndex { $0.t <= t } ?? 0
        let (a, b) = (keys[i], keys[i + 1])
        let x = (t - a.t) / (b.t - a.t)
        return a.v + (b.v - a.v) * x * x * (3 - 2 * x) // smoothstep
    }

    // MARK: Layout

    /// Natural-size slots, left to right. Never stretched: a toolbar button fills its frame with the hover
    /// highlight, so a stretched one gets a highlight that no longer sits evenly inside the rim.
    private func slotFrames() -> [NSRect] {
        var x: CGFloat = 0
        let spacing = spacing()
        return members.map { view in
            let size = Self.naturalSize(of: view)
            defer { x += size.width + spacing }
            return NSRect(x: x, y: (GlassPillBar.pillHeight - size.height) / 2, width: size.width, height: size.height)
        }
    }

    private static func naturalSize(of view: NSView) -> NSSize {
        if let host = view as? GlassPillMemberHost { return host.naturalSize }
        let size = view.intrinsicContentSize
        return NSSize(width: max(0, size.width), height: size.height > 0 ? size.height : GlassPillBar.pillHeight)
    }

    /// What AppKit tells the buttons in its own pills: first and last in the glass.
    private func updateGroupPositions() {
        for view in members {
            guard let button = view as? GlassToolbarButton else { continue }
            button.glassGroupPosition = .init(first: view === members.first, last: view === members.last)
        }
    }

    func apply(_ placement: Placement, in bounds: NSRect, anchor: GlassToolbarItem.Anchor) {
        let margin = GlassPillBar.anchoredEdgeMargin
        let x: (CGFloat) -> CGFloat = anchor == .trailing
            ? { bounds.maxX - margin - $0 }
            : { bounds.minX + margin + $0 }
        let glassMinX = min(x(placement.near), x(placement.far))
        let glassWidth = abs(placement.far - placement.near)
        let coreMinX = min(x(placement.coreNear), x(placement.coreFar))
        let coreWidth = abs(placement.coreFar - placement.coreNear)
        glass.frame = NSRect(x: glassMinX, y: (bounds.height - placement.height) / 2,
                             width: glassWidth, height: placement.height)
        glass.cornerRadius = placement.height / 2

        // The views keep their natural layout, centred in the glass without its reach: shrunk glass clips
        // them from both sides, swollen glass leaves room around them.
        let shiftX = (coreMinX - glassMinX) + (coreWidth - placement.layoutWidth) / 2 + placement.contentExtra
        let shiftY = (placement.height - GlassPillBar.pillHeight) / 2
        content.bounds.origin = NSPoint(x: -shiftX, y: -shiftY)

        let frames = slotFrames()
        let p = placement.slide
        for (view, frame) in zip(members, frames) {
            if let slide = slides[ObjectIdentifier(view)], p < 1 {
                view.frame = NSRect(
                    x: slide.from.minX + (slide.to.minX - slide.from.minX) * p,
                    y: slide.from.minY + (slide.to.minY - slide.from.minY) * p,
                    width: slide.from.width + (slide.to.width - slide.from.width) * p,
                    height: slide.from.height + (slide.to.height - slide.from.height) * p
                )
            } else {
                view.frame = frame
            }
        }
    }
}

// MARK: - Spring track

/// One animated value on `GlassPillBar.spring`; at rest when it has no start.
private struct GlassSpringTrack {
    var from: CGFloat
    var to: CGFloat
    var velocity: CGFloat = 0
    var start: CFTimeInterval?

    static func rest(_ value: CGFloat) -> Self { .init(from: value, to: value, start: nil) }

    private func elapsed(_ now: CFTimeInterval) -> TimeInterval {
        start.map { max(0, (now - $0) / GlassPillBar.slowdown) } ?? .infinity
    }

    func value(at now: CFTimeInterval) -> CGFloat {
        guard start != nil else { return to }
        let t = elapsed(now)
        guard t < GlassPillBar.spring.settlingDuration else { return to }
        return CGFloat(GlassPillBar.spring.value(fromValue: Double(from), toValue: Double(to),
                                                 initialVelocity: Double(velocity), time: t))
    }

    func currentVelocity(at now: CFTimeInterval) -> CGFloat {
        guard start != nil else { return 0 }
        let t = elapsed(now)
        guard t < GlassPillBar.spring.settlingDuration else { return 0 }
        return CGFloat(GlassPillBar.spring.velocity(fromValue: Double(from), toValue: Double(to),
                                                    initialVelocity: Double(velocity), time: t))
    }

    func isSettled(at now: CFTimeInterval) -> Bool {
        start == nil || elapsed(now) >= GlassPillBar.spring.settlingDuration
    }

    /// Heads for `target` from the current value and speed, so an interrupted change carries on smoothly.
    mutating func retarget(to target: CGFloat, at now: CFTimeInterval) {
        guard target != to || !isSettled(at: now) else { return }
        let value = value(at: now), speed = currentVelocity(at: now)
        self = .init(from: value, to: target, velocity: speed, start: now)
    }
}

// MARK: - Hosting

/// Lays out a view that sizes itself with constraints (the Rive glyphs) inside a frame-based pill.
@MainActor
final class GlassPillMemberHost: NSView {
    let hosted: NSView

    init(hosting view: NSView) {
        hosted = view
        super.init(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: leadingAnchor),
            view.trailingAnchor.constraint(equalTo: trailingAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var naturalSize: NSSize {
        let size = hosted.fittingSize
        return NSSize(width: size.width, height: GlassPillBar.pillHeight)
    }
}

#if DEBUG
/// Debug builds only: with `GLASS_TOOLBAR_CHECK=1` in the environment, every glass toolbar item checks
/// itself each time it comes to rest — no pill or view left behind, nothing still blurred or faded, every
/// glass the size of its buttons, the slot the size of its pills — and reports any change it made
/// without animating while on screen. Results go to the log as `GLASSCHECK` lines.
@MainActor
enum GlassToolbarSelfCheck {
    static let isOn = ProcessInfo.processInfo.environment["GLASS_TOOLBAR_CHECK"] != nil

    static func report(_ message: String) {
        NSLog("GLASSCHECK %@", message)
    }
}
#endif
