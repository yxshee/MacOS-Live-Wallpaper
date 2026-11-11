import AppKit

// Any `--option` is a request to draw off screen and exit (see Headless.swift);
// unknown ones are rejected there. A mistyped flag must never start a wallpaper.
if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) {
    Headless.run(CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
