import AppKit

/// A button for a `GlassToolbarItem` pill: the image-only, bordered, extra-large `.toolbar` button AppKit
/// itself puts inside toolbar glass, so a hand-made pill looks like the system's next to it.
///
/// - `.toolbar` bezel, bordered: a borderless button draws template images at ~50% black, which reads
///   as greyed out next to the system's items.
/// - `.extraLarge`: toolbar buttons have a 36pt natural height. At `.regular` they are 24pt, and
///   stretched to the pill they draw a hover highlight with 2pt to spare from the rim.
@MainActor
public final class GlassToolbarButton: NSButton {

    public convenience init(symbol: String, label: String, target: AnyObject?, action: Selector?) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        self.init(image: image ?? NSImage(), label: label, target: target, action: action)
    }

    /// For a glyph drawn by something else on top (the Rive glyphs): pass a blank image the size of the
    /// symbol it stands in for, and the button sizes, hovers and presses exactly like its neighbours.
    public convenience init(image: NSImage, label: String, target: AnyObject?, action: Selector?) {
        self.init(image: image, target: target, action: action)
        bezelStyle = .toolbar
        isBordered = true
        controlSize = .extraLarge
        imagePosition = .imageOnly
        toolTip = label
        setAccessibilityLabel(label)
    }

    /// Called as the button's press highlight comes and goes — on mouse down, dragging out and back in,
    /// and release — for a glyph drawn on top that animates its own pressed state (the Rive glyphs).
    public var onPressChange: ((Bool) -> Void)?

    public override class var cellClass: AnyClass? {
        get { GlassToolbarButtonCell.self }
        set {}
    }

    /// The press as it is reported: pressed on mouse down, then following the cell's highlight as the
    /// pointer is dragged out and back in, and released once the click is over whatever the cell said.
    fileprivate var isPressReported = false {
        didSet {
            guard isPressReported != oldValue else { return }
            onPressChange?(isPressReported)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        isPressReported = true
        // NSButton tracks the click until the mouse comes back up, then returns.
        super.mouseDown(with: event)
        isPressReported = false
    }

    /// Swaps the symbol, keeping the accessibility description in step with what it shows.
    public func setSymbol(_ symbol: String, label: String) {
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        toolTip = label
        setAccessibilityLabel(label)
    }

    /// Where the button sits in its pill, which decides the shape of its hover highlight.
    ///
    /// AppKit shapes a toolbar button's highlight from the view's glass context options: a private
    /// bitmask NSView passes down its hierarchy (bit 0: first in the glass group, bit 1: last). Alone in
    /// its glass the highlight fills the whole pill; otherwise it is the inset 28pt one. Inside the
    /// system's pills `NSToolbarItemViewer` sets these; nobody does for ours, so the pill sets them here.
    ///
    /// ⚠️ Private (`-[NSView _setGlassContextOptions:]`, macOS 26/27), found by disassembling
    /// `-[NSView _isFirstItemInGlassGroup]`. Checked with `responds(to:)` first, so if it goes away the
    /// highlight falls back to the inset one rather than anything crashing.
    struct GlassGroupPosition: Equatable {
        var first = false
        var last = false
        fileprivate var options: Int { (first ? 0x1 : 0) | (last ? 0x2 : 0) }
    }

    var glassGroupPosition = GlassGroupPosition() {
        didSet {
            guard glassGroupPosition != oldValue,
                  responds(to: NSSelectorFromString("_setGlassContextOptions:"))
            else { return }
            setValue(glassGroupPosition.options, forKey: "glassContextOptions")
        }
    }
}

/// The standard button cell, reporting its press highlight to `GlassToolbarButton`. AppKit highlights
/// and unhighlights it through here as the pointer is dragged out of the button and back during a click.
private final class GlassToolbarButtonCell: NSButtonCell {
    override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
        super.highlight(flag, withFrame: cellFrame, in: controlView)
        MainActor.assumeIsolated {
            (controlView as? GlassToolbarButton)?.isPressReported = flag
        }
    }
}

/// How a pill's views come and go, after iOS bar buttons: blurred, shrunk and faded on the way out,
/// coming into focus on the way in. The fade itself rides the pill's own clock; this adds the blur and
/// the scale as layer animations.
@MainActor
enum GlassToolbarTransition {
    /// In points: fully smeared at the start of an appearance, as on iOS.
    static let blurRadius: CGFloat = 5
    static let scale: CGFloat = 0.6
    static let duration: TimeInterval = 0.3

    /// Identifies a view's newest transition, so a superseded one doesn't clean up after the next.
    private static var generations: [ObjectIdentifier: Int] = [:]

    static func run(on view: NSView, appearing: Bool, slowdown: Double) {
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        guard let layer = view.layer else { return }
        let key = ObjectIdentifier(view)
        let generation = (generations[key] ?? 0) + 1
        generations[key] = generation

        // Core Image works in pixels.
        let radius = blurRadius * (view.window?.backingScaleFactor ?? 2)
        guard let blur = CIFilter(name: "CIGaussianBlur") else { return }
        blur.name = "glassToolbarBlur"
        // The model value is the end state, so nothing snaps back if the animation is cut short.
        blur.setValue(appearing ? 0 : radius, forKey: kCIInputRadiusKey)
        view.contentFilters = [blur]

        let blurAnimation = CABasicAnimation(keyPath: "filters.glassToolbarBlur.inputRadius")
        blurAnimation.fromValue = appearing ? radius : 0
        blurAnimation.toValue = appearing ? 0 : radius

        let shrunk = NSValue(caTransform3D: layer.scaledAboutCenter(scale))
        let identity = NSValue(caTransform3D: CATransform3DIdentity)
        let scaleAnimation = CABasicAnimation(keyPath: "transform")
        scaleAnimation.fromValue = appearing ? shrunk : identity
        scaleAnimation.toValue = appearing ? identity : shrunk

        let group = CAAnimationGroup()
        group.animations = [blurAnimation, scaleAnimation]
        group.duration = duration * slowdown
        group.timingFunction = CAMediaTimingFunction(name: appearing ? .easeOut : .easeIn)
        // A leaving view keeps its last frame until it is detached; an arriving one ends at identity.
        group.fillMode = .forwards
        group.isRemovedOnCompletion = appearing

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in
            MainActor.assumeIsolated {
                guard let view, generations[key] == generation else { return }
                generations[key] = nil
                // In focus: drop the filter, so a resting button renders exactly like a system one.
                if appearing { view.contentFilters = [] }
            }
        }
        layer.add(group, forKey: "glassToolbarTransition")
        CATransaction.commit()
    }

    /// Ends whatever transition a view is in, for a view leaving the toolbar for good.
    static func reset(_ view: NSView) {
        generations[ObjectIdentifier(view)] = nil
        view.layer?.removeAnimation(forKey: "glassToolbarTransition")
        view.contentFilters = []
    }

    static func isRunning(on view: NSView) -> Bool {
        view.layer?.animation(forKey: "glassToolbarTransition") != nil
    }
}

private extension CALayer {
    /// A `transform` scaling around the centre; AppKit anchors view layers at their origin.
    func scaledAboutCenter(_ scale: CGFloat) -> CATransform3D {
        let dx = bounds.width * (0.5 - anchorPoint.x), dy = bounds.height * (0.5 - anchorPoint.y)
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        return CATransform3DTranslate(transform, -dx, -dy, 0)
    }
}
