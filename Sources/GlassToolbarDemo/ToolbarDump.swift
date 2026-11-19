import AppKit

/// Reads the toolbar's layout off its views, in window points — what the system gave each item, and where
/// the glass ended up — so the glass items can be compared with the system's.
@MainActor
enum ToolbarDump {

    static func toolbarView(in window: NSWindow) -> NSView? {
        guard let root = window.contentView?.superview else { return nil }
        return first(in: root) { $0.className.contains("NSToolbarView") }
    }

    /// The views that matter, nested as they are: each item's slot, its view, the glass and the buttons.
    static func tree(of window: NSWindow) -> String {
        guard let toolbar = toolbarView(in: window) else { return "no toolbar view" }
        var lines: [String] = []
        func walk(_ view: NSView, depth: Int) {
            var depth = depth
            if let name = interestingName(view) {
                let frame = view.convert(view.bounds, to: nil)
                var line = String(repeating: "  ", count: depth) + name
                line += " x=\(number(frame.minX)) w=\(number(frame.width)) maxX=\(number(frame.maxX))"
                if view.isHiddenOrHasHiddenAncestor { line += " hidden" }
                if let button = view as? NSButton, let tip = button.toolTip { line += " “\(tip)”" }
                if let field = view as? NSTextField { line += " “\(field.stringValue)”" }
                lines.append(line)
                depth += 1
            }
            for subview in view.subviews { walk(subview, depth: depth) }
        }
        walk(toolbar, depth: 0)
        return lines.joined(separator: "\n")
    }

    /// One line for a frame of an animation: every slot (V), piece of glass (G) and text (T), as `x:width`.
    static func trace(of window: NSWindow) -> String {
        guard let toolbar = toolbarView(in: window) else { return "" }
        var parts: [(CGFloat, String)] = []
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            let name = view.className
            let tag: String? = if name.contains("NSToolbarItemViewer") { "V" }
                else if name == "NSGlassEffectView" { "G" }
                else if view is NSTextField { "T" }
                else { nil }
            if let tag {
                let frame = view.convert(view.bounds, to: nil)
                parts.append((frame.minX, "\(tag)\(number(frame.minX)):\(number(frame.width))"))
            }
            for subview in view.subviews { walk(subview) }
        }
        walk(toolbar)
        return parts.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    private static func interestingName(_ view: NSView) -> String? {
        let name = view.className
        if name.contains("HostingView") || name.contains("ContentHolder") { return nil }
        let wanted = ["NSToolbarView", "ToolbarItemViewer", "PlatterView", "GlassPillBar", "NSGlassEffectView",
                      "ToolbarSpace", "FlexibleSpace", "Separator", "ItemGroupView", "LayoutWrapper"]
        if view is NSButton || view is NSTextField || wanted.contains(where: name.contains) {
            return name.split(separator: ".").last.map(String.init) ?? name
        }
        return nil
    }

    private static func first(in view: NSView, where matches: (NSView) -> Bool) -> NSView? {
        if matches(view) { return view }
        for subview in view.subviews {
            if let found = first(in: subview, where: matches) { return found }
        }
        return nil
    }

    private static func number(_ value: CGFloat) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}
