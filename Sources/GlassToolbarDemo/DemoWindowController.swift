import AppKit
import GlassToolbar

/// A three-column window whose toolbar is built from a `DemoLayout`, showing the buttons of a `DemoScreen`.
@MainActor
final class DemoWindowController: NSObject, NSToolbarDelegate {

    let window: NSWindow
    private let split = NSSplitViewController()

    private(set) var layout: DemoLayout
    private(set) var screen: DemoScreen

    private var identifiers: [NSToolbarItem.Identifier] = []
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    /// Buttons are kept per item and symbol: a button that stays between two screens is the same view, which
    /// is what lets its pill keep its identity and slide it.
    private var glassButtons: [NSToolbarItem.Identifier: [String: GlassToolbarButton]] = [:]
    private var systemSubitems: [NSToolbarItem.Identifier: [String: NSToolbarItem]] = [:]
    private var generation = 0

    private let screenControl = NSSegmentedControl()
    private let kindControl = NSSegmentedControl()
    private let layoutField = NSTextField()
    private let logLabel = NSTextField(labelWithString: "")

    init(layout: DemoLayout, screen: DemoScreen) {
        self.layout = layout
        self.screen = screen
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 640),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "Glass Toolbar Demo"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false

        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.pane(width: 250))
        let list = NSSplitViewItem(contentListWithViewController: Self.pane(width: 350))
        list.minimumThickness = 240
        let detail = NSSplitViewItem(viewController: detailPane())
        detail.minimumThickness = 320
        split.splitViewItems = [sidebar, list, detail]
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1200, height: 640))
        window.center()

        setLayout(layout)
    }

    // MARK: Layout and screen

    func setLayout(_ layout: DemoLayout) {
        self.layout = layout
        generation += 1
        items = [:]
        glassButtons = [:]
        systemSubitems = [:]
        identifiers = layout.tokens.enumerated().map { index, token in
            switch token {
            case "toggle": .toggleSidebar
            case "space": .space
            case "flex": .flexibleSpace
            default: .demo(token, index)
            }
        }
        // A new toolbar each time: the old one's items cannot be told to leave and return in another order.
        let toolbar = NSToolbar(identifier: "GlassToolbarDemo.\(generation)")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar

        layoutField.stringValue = layout.tokens.joined(separator: " ")
        kindControl.selectedSegment = layout.usesSystemItems ? 1 : 0
        applyScreen(animated: false)
    }

    func setScreen(_ screen: DemoScreen, animated: Bool = true) {
        self.screen = screen
        applyScreen(animated: animated)
    }

    /// The toolbar's items by token, for scripts.
    func items(for token: String) -> [NSToolbarItem] {
        identifiers.filter { $0.demoToken == token }.compactMap { items[$0] }
    }

    var allItems: [(identifier: NSToolbarItem.Identifier, item: NSToolbarItem)] {
        identifiers.compactMap { identifier in items[identifier].map { (identifier, $0) } }
    }

    private func applyScreen(animated: Bool) {
        screenControl.selectedSegment = DemoScreen.allCases.firstIndex(of: screen) ?? 0
        for (identifier, item) in items {
            guard let token = identifier.demoToken else { continue }
            let symbols: [[String]]
            switch token {
            case "content", "ncontent": symbols = screen.content
            case "back", "nback": symbols = screen.back
            case "actions", "nactions": symbols = screen.actions
            case "glass", "glassL", "group": symbols = screen.sample
            case "title":
                (item.view as? NSTextField)?.stringValue = screen.title
                continue
            default: continue
            }
            if let glass = item as? GlassToolbarItem {
                glass.setGroups(symbols.map { $0.map { glassButton($0, in: identifier) } }, animated: animated)
            } else if let group = item as? NSToolbarItemGroup {
                // The system has one piece of glass per group, so two pills become one here.
                group.subitems = symbols.joined().map { systemSubitem($0, in: identifier) }
                group.isHidden = symbols.isEmpty
            } else {
                item.isHidden = symbols.isEmpty
            }
        }
    }

    private func glassButton(_ symbol: String, in identifier: NSToolbarItem.Identifier) -> GlassToolbarButton {
        if let button = glassButtons[identifier]?[symbol] { return button }
        let button = GlassToolbarButton(symbol: symbol, label: Self.label(for: symbol),
                                        target: self, action: #selector(buttonPressed(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        glassButtons[identifier, default: [:]][symbol] = button
        return button
    }

    private func systemSubitem(_ symbol: String, in identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        if let item = systemSubitems[identifier]?[symbol] { return item }
        let item = Self.systemItem(NSToolbarItem.Identifier("\(identifier.rawValue).\(symbol)"), symbol: symbol,
                                   target: self, action: #selector(buttonPressed(_:)))
        systemSubitems[identifier, default: [:]][symbol] = item
        return item
    }

    private static func systemItem(_ identifier: NSToolbarItem.Identifier, symbol: String,
                                   target: AnyObject, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label(for: symbol))
        item.label = label(for: symbol)
        item.isBordered = true
        item.target = target
        item.action = action
        return item
    }

    static func label(for symbol: String) -> String {
        switch symbol {
        case "bell.slash": "Unsubscribe"
        case "arrowshape.turn.up.left": "Reply"
        case "heart": "Favourite"
        case "trash": "Delete"
        case "arrow.uturn.backward": "Revert"
        case "checkmark": "Save"
        case "chevron.backward": "Back"
        case "line.3.horizontal.decrease": "Filter"
        case "arrow.clockwise": "Refresh"
        default: symbol
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = items[identifier] { return item }
        guard let token = identifier.demoToken else { return nil }
        let item: NSToolbarItem
        switch token {
        case "sep1", "sep2":
            item = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView,
                                                  dividerIndex: token == "sep1" ? 0 : 1)
        case "title", "label":
            item = NSToolbarItem(itemIdentifier: identifier)
            let field = NSTextField(labelWithString: token == "title" ? screen.title : "Sender")
            field.font = token == "title" ? .systemFont(ofSize: 15, weight: .semibold) : .systemFont(ofSize: NSFont.systemFontSize)
            field.textColor = token == "title" ? .labelColor : .secondaryLabelColor
            item.view = field
        case "content", "actions", "glass":
            item = GlassToolbarItem(itemIdentifier: identifier, anchor: .trailing)
            item.label = token.capitalized
        case "back", "glassL":
            item = GlassToolbarItem(itemIdentifier: identifier, anchor: .leading)
            item.label = token.capitalized
        case "ncontent", "nactions", "group":
            item = NSToolbarItemGroup(itemIdentifier: identifier)
            item.label = token.capitalized
        case "nback":
            item = Self.systemItem(identifier, symbol: "chevron.backward", target: self, action: #selector(buttonPressed(_:)))
        case "native":
            item = Self.systemItem(identifier, symbol: "heart", target: self, action: #selector(buttonPressed(_:)))
        default:
            return nil
        }
        if token == "content" { (item as? GlassToolbarItem)?.buttonSpacing = 0 }
        items[identifier] = item
        // Items are made as the toolbar asks for them; give this one the current screen's buttons.
        DispatchQueue.main.async { [weak self] in self?.applyScreen(animated: false) }
        return item
    }

    // MARK: Actions

    @objc private func buttonPressed(_ sender: Any?) {
        let name = (sender as? NSButton)?.toolTip ?? (sender as? NSToolbarItem)?.label ?? "?"
        logLabel.stringValue = "Pressed \(name)"
        print("pressed \(name)")
        fflush(stdout)
        // Back does what it says, so the swap can be played by hand.
        if name == "Back" { setScreen(.folder) }
    }

    @objc private func screenPicked(_ sender: NSSegmentedControl) {
        setScreen(DemoScreen.allCases[sender.selectedSegment])
    }

    @objc private func kindPicked(_ sender: NSSegmentedControl) {
        setLayout(.mail(system: sender.selectedSegment == 1))
    }

    @objc private func layoutEdited(_ sender: NSTextField) {
        setLayout(DemoLayout(tokens: sender.stringValue))
    }

    // MARK: Panes

    private static func pane(width: CGFloat) -> NSViewController {
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 640))
        return controller
    }

    private func detailPane() -> NSViewController {
        let controller = NSViewController()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 640))

        screenControl.segmentCount = DemoScreen.allCases.count
        for (index, screen) in DemoScreen.allCases.enumerated() {
            screenControl.setLabel(screen.title, forSegment: index)
        }
        screenControl.trackingMode = .selectOne
        screenControl.target = self
        screenControl.action = #selector(screenPicked(_:))

        kindControl.segmentCount = 2
        kindControl.setLabel("Glass items", forSegment: 0)
        kindControl.setLabel("System items", forSegment: 1)
        kindControl.trackingMode = .selectOne
        kindControl.target = self
        kindControl.action = #selector(kindPicked(_:))

        layoutField.placeholderString = "Toolbar layout, as tokens"
        layoutField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        layoutField.target = self
        layoutField.action = #selector(layoutEdited(_:))

        let help = NSTextField(wrappingLabelWithString: DemoLayout.help)
        help.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        help.textColor = .secondaryLabelColor
        logLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            NSTextField(labelWithString: "Screen"), screenControl,
            NSTextField(labelWithString: "Toolbar"), kindControl, layoutField, help, logLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            layoutField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            help.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        controller.view = view
        return controller
    }
}
