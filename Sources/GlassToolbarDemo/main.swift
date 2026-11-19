import AppKit

// A window to try `GlassToolbarItem` in, beside the system's own toolbar items.
//
//     swift run GlassToolbarDemo [--layout "toggle sep1 space title flex content sep2 back flex label flex actions"]
//                                [--screen folder]
//
// Everything the window's controls do can also be typed on standard input, one command a line
// (`help` lists them), which is how the layout is measured from scripts.

let app = NSApplication.shared
let delegate = DemoAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
