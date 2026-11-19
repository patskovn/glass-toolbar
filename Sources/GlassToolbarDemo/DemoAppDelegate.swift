import AppKit

@MainActor
final class DemoAppDelegate: NSObject, NSApplicationDelegate {

    private var controller: DemoWindowController!
    private var commands: CommandChannel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        func value(after flag: String) -> String? {
            arguments.firstIndex(of: flag).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }

        NSApp.mainMenu = Self.mainMenu()
        controller = DemoWindowController(
            layout: value(after: "--layout").map(DemoLayout.init(tokens:)) ?? .mail(system: false),
            screen: value(after: "--screen").flatMap(DemoScreen.init(rawValue:)) ?? .folder
        )
        controller.window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        commands = CommandChannel(controller: controller)
        commands.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Glass Toolbar Demo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }
}
