import AppKit

// `--render`, `--bench` and `--help` draw frames off screen and exit; see Headless.swift.
let headlessFlags: Set<String> = ["--render", "--bench", "--help"]
if !headlessFlags.isDisjoint(with: CommandLine.arguments) {
    Headless.run(CommandLine.arguments)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
