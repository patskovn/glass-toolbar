import AppKit

/// What the window is showing, which decides the buttons each toolbar item has up — after a mail app:
/// a list of mail, one message, a conversation, a saved search being edited.
enum DemoScreen: String, CaseIterable {
    case inbox, email, thread, folder, saved, cleaner, none

    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .email: "Email"
        case .thread: "Thread"
        case .folder: "New folder"
        case .saved: "Saved folder"
        case .cleaner: "Cleaner"
        case .none: "Nothing"
        }
    }

    /// The detail column's actions: one array of symbols per pill.
    var actions: [[String]] {
        switch self {
        case .email: [["bell.slash", "arrowshape.turn.up.left", "heart", "trash"]]
        case .thread: [["arrowshape.turn.up.left", "trash"]]
        case .folder: [["arrow.uturn.backward", "checkmark"]]
        case .saved: [["trash"], ["arrow.uturn.backward", "checkmark"]]
        case .inbox, .cleaner, .none: []
        }
    }

    var back: [[String]] {
        switch self {
        case .email, .thread: [["chevron.backward"]]
        default: []
        }
    }

    /// The list column's pill.
    var content: [[String]] {
        switch self {
        case .inbox, .email, .thread: [["line.3.horizontal.decrease", "arrow.clockwise"]]
        case .cleaner, .folder, .saved: [["arrow.clockwise"]]
        case .none: []
        }
    }

    /// For the plain test items, which only come and go.
    var sample: [[String]] {
        self == .none ? [] : [["arrowshape.turn.up.left", "trash"]]
    }
}

/// A toolbar, as a row of tokens. `help` on standard input describes them.
struct DemoLayout: Equatable {
    var tokens: [String]

    init(tokens: String) {
        self.tokens = tokens.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
    }

    /// A mail app's toolbar over three columns, with glass items or the system's in the same places.
    static func mail(system: Bool) -> DemoLayout {
        let prefix = system ? "n" : ""
        return DemoLayout(tokens: "toggle sep1 space title flex \(prefix)content sep2 \(prefix)back flex label flex \(prefix)actions")
    }

    var usesSystemItems: Bool { tokens.contains { ["ncontent", "nback", "nactions"].contains($0) } }

    static let help = """
    tokens:
      toggle            the sidebar toggle
      sep1 sep2         separators tracking the first and second divider
      space flex        a fixed and a flexible space
      title label       plain text items
      content back actions     glass items showing the screen's buttons (back is leading-anchored)
      ncontent nback nactions  the same from the system's own items, for comparison
      glass glassL      a glass item with two buttons, trailing- and leading-anchored (empty on `none`)
      native group      a system bordered item, and a system group of two (hidden on `none`)
    """
}

extension NSToolbarItem.Identifier {
    static func demo(_ token: String, _ index: Int) -> NSToolbarItem.Identifier {
        NSToolbarItem.Identifier("demo.\(token)#\(index)")
    }

    /// The token an identifier was made from, if it is one of the demo's.
    var demoToken: String? {
        guard rawValue.hasPrefix("demo.") else { return nil }
        return rawValue.dropFirst(5).split(separator: "#").first.map(String.init)
    }
}
