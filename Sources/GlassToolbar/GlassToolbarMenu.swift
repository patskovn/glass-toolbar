import AppKit

/// An item's stand-in for when the toolbar has no room for it: a menu item for the overflow menu, made
/// from the item's buttons.
///
/// A toolbar item with a view of its own gets nothing in that menu unless it says what — its buttons
/// would just be gone from a narrow window.
@MainActor
enum GlassToolbarMenu {

    /// One menu item for a lone button, otherwise an item titled `title` with the buttons in a submenu,
    /// a separator between one pill's and the next's. `nil` when nothing can be shown.
    static func representation(for groups: [[NSView]], title: String,
                               provider: ((NSView) -> NSMenuItem?)?) -> NSMenuItem? {
        let sections = groups
            .map { $0.compactMap { menuItem(for: $0, provider: provider) } }
            .filter { !$0.isEmpty }
        let all = Array(sections.joined())
        guard let first = all.first else { return nil }
        if all.count == 1 { return first }

        let menu = NSMenu(title: title)
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            section.forEach(menu.addItem)
        }
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        parent.submenu = menu
        return parent
    }

    private static func menuItem(for view: NSView, provider: ((NSView) -> NSMenuItem?)?) -> NSMenuItem? {
        if let custom = provider?(view) { return custom }
        guard let button = view as? NSButton else { return nil }
        let title = [button.accessibilityLabel(), button.toolTip, button.title]
            .compactMap { $0 }.first { !$0.isEmpty }
        guard let title else { return nil }
        let item = NSMenuItem(title: title, action: #selector(GlassToolbarMenuTarget.press(_:)), keyEquivalent: "")
        item.target = GlassToolbarMenuTarget.shared
        item.representedObject = button
        item.image = button.image
        return item
    }
}

/// Presses the button a menu item stands for: the button's own action, sent from the button, so the
/// receiver cannot tell the menu from a click.
@MainActor
final class GlassToolbarMenuTarget: NSObject, NSMenuItemValidation {
    static let shared = GlassToolbarMenuTarget()

    @objc func press(_ sender: NSMenuItem) {
        guard let button = sender.representedObject as? NSButton, button.isEnabled, let action = button.action else { return }
        NSApplication.shared.sendAction(action, to: button.target, from: button)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        (menuItem.representedObject as? NSButton)?.isEnabled ?? false
    }
}
