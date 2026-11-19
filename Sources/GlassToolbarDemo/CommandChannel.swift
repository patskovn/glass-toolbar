import AppKit

/// Runs the demo from standard input, one command a line, and answers on standard output — so a script can
/// lay the toolbar out, change screens and read back where everything ended up.
@MainActor
final class CommandChannel {

    private let controller: DemoWindowController
    private var traceTimer: Timer?

    init(controller: DemoWindowController) {
        self.controller = controller
    }

    func start() {
        FileHandle.standardInput.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in
                for line in text.split(separator: "\n") {
                    self?.run(String(line))
                }
            }
        }
    }

    static let help = """
    commands:
      screen <\(DemoScreen.allCases.map(\.rawValue).joined(separator: "|"))>   change what the items show, animated
      layout <tokens…>      rebuild the toolbar from tokens
      mail <glass|system>   the mail layout with glass or system items
      size <width> <height> resize the window's content
      dump                  the toolbar's views and where they are
      items                 the toolbar's items: visible or in the overflow menu, and their menu items
      trace <seconds>       a line per frame with every slot, glass and text position
      help | quit
    \(DemoLayout.help)
    """

    private func run(_ line: String) {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return }
        let arguments = Array(words.dropFirst())
        switch command {
        case "help":
            say(Self.help)
        case "screen":
            guard let screen = arguments.first.flatMap(DemoScreen.init(rawValue:)) else { return say("unknown screen") }
            controller.setScreen(screen)
            say("screen \(screen.rawValue)")
        case "layout":
            controller.setLayout(DemoLayout(tokens: arguments.joined(separator: " ")))
            say("layout \(controller.layout.tokens.joined(separator: " "))")
        case "mail":
            controller.setLayout(.mail(system: arguments.first == "system"))
            say("layout \(controller.layout.tokens.joined(separator: " "))")
        case "size":
            guard arguments.count == 2, let width = Double(arguments[0]), let height = Double(arguments[1]) else { return say("size <width> <height>") }
            controller.window.setContentSize(NSSize(width: width, height: height))
            say("size \(Int(width)) \(Int(height))")
        case "dump":
            say("--- dump screen=\(controller.screen.rawValue) layout=\(controller.layout.tokens.joined(separator: " "))")
            say(ToolbarDump.tree(of: controller.window))
            say("--- end")
        case "items":
            say("--- items")
            let visible = Set((controller.window.toolbar?.visibleItems ?? []).map(\.itemIdentifier))
            for (identifier, item) in controller.allItems {
                var line = "\(identifier.rawValue): \(item.isHidden ? "hidden" : visible.contains(identifier) ? "visible" : "overflow")"
                if let menu = item.menuFormRepresentation { line += " menu=\(Self.describe(menu))" }
                say(line)
            }
            say("--- end")
        case "trace":
            let seconds = arguments.first.flatMap(Double.init) ?? 1
            let start = CACurrentMediaTime()
            say("--- trace")
            var last = ""
            traceTimer?.invalidate()
            traceTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let elapsed = CACurrentMediaTime() - start
                    let line = ToolbarDump.trace(of: self.controller.window)
                    // Only what changed: a toolbar at rest says nothing.
                    if line != last {
                        self.say(String(format: "%.3f ", elapsed) + line)
                        last = line
                    }
                    if elapsed >= seconds {
                        self.traceTimer?.invalidate()
                        self.traceTimer = nil
                        self.say("--- end")
                    }
                }
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            say("unknown command: \(command) (try help)")
        }
    }

    private static func describe(_ item: NSMenuItem) -> String {
        guard let submenu = item.submenu else { return "“\(item.title)”" }
        return "“\(item.title)”[" + submenu.items.map(describe).joined(separator: ", ") + "]"
    }

    private func say(_ text: String) {
        print(text)
        fflush(stdout)
    }
}
