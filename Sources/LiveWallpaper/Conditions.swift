import AppKit
import IOKit.ps

// MARK: - What the machine can spare, and whether anyone is looking

/// Read every frame; kept current by notifications, never by polling.
final class Conditions {
    static let shared = Conditions()
    private(set) var onBattery = false
    private(set) var saving = false           // Low Power Mode, or the Mac is running hot
    private(set) var desktopInFront = false   // Finder is the active app: you are looking at the desktop
    /// Called on the main thread when the power state changes.
    var onChange: (() -> Void)?

    private init() {
        refresh()
        desktopInFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        let nc = NotificationCenter.default
        nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.desktopInFront = app?.bundleIdentifier == "com.apple.finder"
        }
        if let source = IOPSNotificationCreateRunLoopSource({ _ in Conditions.shared.refresh() }, nil)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    func refresh() {
        let before = (saving, onBattery)
        let info = ProcessInfo.processInfo
        saving = info.isLowPowerModeEnabled || info.thermalState == .serious || info.thermalState == .critical
        if let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let type = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue() {
            onBattery = (type as String) == "Battery Power"
        }
        if before != (saving, onBattery) { onChange?() }
    }
}
