import AppKit
import AVFoundation
import ServiceManagement
import UniformTypeIdentifiers

enum SceneChoice: String {
    case horizon, nebula, video
}

// MARK: - Video wallpaper

final class VideoView: NSView {
    let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var watch: NSKeyValueObservation?

    /// `onFailure` runs on the main thread if the file turns out not to be playable.
    init(frame: NSRect, url: URL, onFailure: @escaping (String) -> Void) {
        super.init(frame: frame)
        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.backgroundColor = NSColor.black.cgColor
        layer = playerLayer
        wantsLayer = true
        player.isMuted = true
        player.preventsDisplaySleepDuringVideoPlayback = false
        let looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        self.looper = looper
        watch = looper.observe(\.status, options: [.initial, .new]) { looper, _ in
            guard looper.status == .failed else { return }
            let reason = looper.error?.localizedDescription ?? "The file could not be played."
            DispatchQueue.main.async { onFailure(reason) }
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: - One wallpaper window per screen

final class WallpaperWindow {
    let window: NSWindow
    private(set) var scene: SceneView?
    private var video: VideoView?

    /// Returns nil rather than a window with nothing to show: a bare window at
    /// this level would be a black rectangle over the user's real wallpaper.
    init?(screen: NSScreen, choice: SceneChoice, videoURL: URL?, onVideoFailure: @escaping (String) -> Void) {
        let bounds = NSRect(origin: .zero, size: screen.frame.size)
        let content: NSView
        if choice == .video, let url = videoURL {
            let v = VideoView(frame: bounds, url: url, onFailure: onVideoFailure)
            video = v
            content = v
        } else if Renderer.shared != nil {
            let s = SceneView(frame: bounds, kind: choice == .nebula ? .nebula : .horizon)
            scene = s
            content = s
        } else {
            return nil
        }

        window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        // Above the system wallpaper, below desktop icons and every app window.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.backgroundColor = .black
        window.setFrame(screen.frame, display: false)
        window.contentView = content
        window.orderFrontRegardless()
    }

    func setPlaying(_ playing: Bool, videoAllowed: Bool) {
        scene?.playing = playing
        if let player = video?.player {
            if playing && videoAllowed { player.play() } else { player.pause() }
        }
    }

    /// Stops drawing but leaves the last frame on screen until `close()`.
    func retire() {
        setPlaying(false, videoAllowed: false)
        scene?.stop()
    }

    func close() {
        retire()
        window.close()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let repository = "https://github.com/yxshee/MacOS-Live-Wallpaper"

    private var windows: [WallpaperWindow] = []
    private var builtFor = ""                       // screens and scene the current windows were made for
    private var statusItem: NSStatusItem!
    private let defaults = UserDefaults.standard
    private var displayAsleep = false
    private var sessionActive = true

    private var videoURL: URL? {
        guard let path = defaults.string(forKey: "videoPath"),
              FileManager.default.isReadableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }
    private var choice: SceneChoice {
        get {
            let saved = defaults.string(forKey: "scene").flatMap { SceneChoice(rawValue: $0) } ?? .horizon
            return saved == .video && videoURL == nil ? .horizon : saved
        }
        set { defaults.set(newValue.rawValue, forKey: "scene") }
    }
    private var userPaused: Bool {
        get { defaults.bool(forKey: "paused") }
        set { defaults.set(newValue, forKey: "paused") }
    }
    /// The generated scenes need Metal; the video scene does not.
    private var cannotDraw: Bool { choice != .video && Renderer.shared == nil }

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "mountain.2.fill",
                                           accessibilityDescription: "Live Wallpaper")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(screensChanged),
                       name: NSApplication.didChangeScreenParametersNotification, object: nil)
        nc.addObserver(self, selector: #selector(updatePlayback),
                       name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        nc.addObserver(self, selector: #selector(placeChanged),
                       name: .NSSystemTimeZoneDidChange, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensSlept),
                       name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke),
                       name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionResigned),
                       name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionBecameActive),
                       name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        Conditions.shared.onChange = { [weak self] in self?.updatePlayback() }

        rebuild()
        if cannotDraw {
            alert("Live Wallpaper can't draw on this Mac",
                  (Renderer.failure ?? "Metal is unavailable.")
                  + "\n\nYour desktop has been left as it was. You can still choose a video from the menu-bar icon.")
        } else if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            alert("Live Wallpaper is running",
                  "It lives in the menu bar: click the mountain icon to change the scene, set your location, pause, or quit.")
        }
    }

    // MARK: Windows

    /// Screen notifications arrive in bursts (waking, docking); act once they settle.
    @objc private func screensChanged() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rebuildIfNeeded), object: nil)
        perform(#selector(rebuildIfNeeded), with: nil, afterDelay: 0.3)
    }

    @objc private func rebuildIfNeeded() { rebuild() }

    private func signature() -> String {
        let screens = NSScreen.screens.map { "\($0.frame)@\($0.backingScaleFactor)" }.joined(separator: "|")
        return "\(choice.rawValue)|\(videoURL?.path ?? "")|\(screens)"
    }

    /// Replaces the windows only when the screens or the scene really changed.
    /// New windows go up before the old ones come down, so the desktop is never bare.
    private func rebuild(force: Bool = false) {
        let wanted = signature()
        guard force || wanted != builtFor else { return }
        builtFor = wanted
        let old = windows
        old.forEach { $0.retire() }
        let c = choice, url = videoURL
        windows = NSScreen.screens.compactMap { screen in
            WallpaperWindow(screen: screen, choice: c, videoURL: url) { [weak self] reason in
                self?.videoFailed(reason)
            }
        }
        old.forEach { $0.close() }
        updatePlayback()
    }

    // Draw only what can be seen: a wallpaper fully covered by other windows,
    // on a sleeping display, or behind another user's session costs nothing.
    @objc private func updatePlayback() {
        let forced = ProcessInfo.processInfo.environment["LW_ALWAYS_PLAY"] != nil   // testing aid
        for w in windows {
            let visible = w.window.occlusionState.contains(.visible) || forced
            w.setPlaying(!userPaused && !displayAsleep && sessionActive && visible,
                         videoAllowed: !Conditions.shared.saving)
        }
    }

    private func redraw() { windows.forEach { $0.scene?.drawNow() } }

    @objc private func screensSlept() { displayAsleep = true; updatePlayback() }
    @objc private func screensWoke() {
        displayAsleep = false
        updatePlayback()
        windows.forEach { $0.scene?.greet() }
    }
    @objc private func sessionResigned() { sessionActive = false; updatePlayback() }
    @objc private func sessionBecameActive() { sessionActive = true; updatePlayback() }

    @objc private func placeChanged() {
        SceneModel.shared.refreshPlace()
        redraw()
    }

    private func videoFailed(_ reason: String) {
        guard choice == .video else { return }
        let name = videoURL?.lastPathComponent ?? "The video"
        defaults.removeObject(forKey: "videoPath")
        choice = .horizon
        rebuild()
        alert("\(name) can't be played", "\(reason)\n\nThe wallpaper has gone back to Horizon.")
    }

    private func alert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let current = choice
        let model = SceneModel.shared

        let header = NSMenuItem(title: statusLine(current), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let generated = Renderer.shared != nil
        let horizon = add(menu, "Horizon", #selector(chooseScene(_:)), SceneChoice.horizon.rawValue)
        horizon.state = current == .horizon && generated ? .on : .off
        let nebula = add(menu, "Nebula", #selector(chooseScene(_:)), SceneChoice.nebula.rawValue)
        nebula.state = current == .nebula && generated ? .on : .off
        if !generated { horizon.action = nil; nebula.action = nil }
        add(menu, current == .video ? "Video: \(videoURL?.lastPathComponent ?? "")" : "Video…",
            #selector(chooseVideo)).state = current == .video ? .on : .off

        if current == .horizon && generated {
            menu.addItem(.separator())
            let sky = NSMenuItem(title: "Sky", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for mode in SkyMode.allCases {
                if mode == .dawn || mode == .lapse { sub.addItem(.separator()) }
                add(sub, mode.title, #selector(chooseSky(_:)), mode.rawValue).state = model.skyMode == mode ? .on : .off
            }
            sky.submenu = sub
            menu.addItem(sky)
            add(menu, "Location…", #selector(chooseLocation))
            add(menu, "New Landscape", #selector(newLandscape))
            add(menu, "Lean Toward Pointer", #selector(toggleParallax)).state = model.parallax ? .on : .off
        }

        menu.addItem(.separator())
        add(menu, userPaused ? "Resume" : "Pause", #selector(togglePause))
        let login = add(menu, "Launch at Login", #selector(toggleLogin))
        switch SMAppService.mainApp.status {
        case .enabled: login.state = .on
        case .requiresApproval:
            login.state = .mixed
            login.title = "Launch at Login (approve in System Settings)"
        default: login.state = .off
        }
        menu.addItem(.separator())
        add(menu, "About Live Wallpaper", #selector(about))
        add(menu, "Quit Live Wallpaper", #selector(quit))
    }

    private func statusLine(_ current: SceneChoice) -> String {
        if cannotDraw { return "Can't draw on this Mac" }
        if userPaused { return "Paused" }
        if current == .video { return Conditions.shared.saving ? "Video paused to save power" : "Playing a video" }
        guard let scene = windows.first(where: { $0.scene?.playing == true })?.scene else {
            return "Resting while the desktop is covered"
        }
        let c = Conditions.shared
        let rate = scene.fps == 1 ? "1 frame a second" : String(format: "%.0f frames a second", scene.fps)
        return "Running at \(rate)" + (c.saving ? ", saving power" : c.onBattery ? ", on battery" : "")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ tag: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = tag
        menu.addItem(item)
        return item
    }

    @objc private func chooseScene(_ sender: NSMenuItem) {
        guard let c = (sender.representedObject as? String).flatMap({ SceneChoice(rawValue: $0) }) else { return }
        choice = c
        rebuild()
    }

    @objc private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a video to loop as your wallpaper"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        defaults.set(url.path, forKey: "videoPath")
        choice = .video
        rebuild()       // an unplayable file reports back through videoFailed and is forgotten
    }

    @objc private func chooseSky(_ sender: NSMenuItem) {
        guard let mode = (sender.representedObject as? String).flatMap({ SkyMode(rawValue: $0) }) else { return }
        SceneModel.shared.skyMode = mode
        // Time-lapse is a demonstration: it is never restored at the next launch.
        defaults.set((mode == .lapse ? SkyMode.real : mode).rawValue, forKey: "sky")
        redraw()
    }

    /// Latitude and longitude, for sunrise and sunset to the minute. Without
    /// them the time zone's reference city is used, which can be far away.
    @objc private func chooseLocation() {
        let place = SceneModel.shared.place
        let a = NSAlert()
        a.messageText = "Where are you?"
        a.informativeText = "The sun and moon are placed for \(place.summary).\n\n"
            + "Enter your own latitude and longitude in degrees (south and west are negative), "
            + "or go back to the time zone's city. Nothing is sent anywhere."
        let lat = NSTextField(string: String(format: "%.4f", place.latitude))
        let lon = NSTextField(string: String(format: "%.4f", place.longitude))
        lat.placeholderString = "Latitude, -90 to 90"
        lon.placeholderString = "Longitude, -180 to 180"
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Latitude"), lat],
                                      [NSTextField(labelWithString: "Longitude"), lon]])
        grid.column(at: 1).width = 160
        grid.frame.size = grid.fittingSize
        a.accessoryView = grid
        a.addButton(withTitle: "Use These")
        a.addButton(withTitle: "Use Time Zone")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn:
            guard let la = Double(lat.stringValue.trimmingCharacters(in: .whitespaces)),
                  let lo = Double(lon.stringValue.trimmingCharacters(in: .whitespaces)),
                  abs(la) <= 90, abs(lo) <= 180 else {
                alert("That isn't a place", "Latitude runs from -90 to 90 and longitude from -180 to 180, in decimal degrees.")
                return
            }
            defaults.set(la, forKey: "latitude")
            defaults.set(lo, forKey: "longitude")
        case .alertSecondButtonReturn:
            defaults.removeObject(forKey: "latitude")
            defaults.removeObject(forKey: "longitude")
        default:
            return
        }
        placeChanged()
    }

    @objc private func newLandscape() {
        let seed = UInt64.random(in: 1...1_000_000)
        defaults.set(Int(seed), forKey: "seed")
        SceneModel.shared.reseed(seed)
        Renderer.shared?.terrainChanged()
        redraw()
    }

    @objc private func toggleParallax() {
        SceneModel.shared.parallax.toggle()
        defaults.set(SceneModel.shared.parallax, forKey: "parallax")
    }

    @objc private func togglePause() {
        userPaused.toggle()
        updatePlayback()
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled:
                try service.unregister()
            case .requiresApproval:
                SMAppService.openSystemSettingsLoginItems()
            default:
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            alert("Couldn't change the login item",
                  "\(error.localizedDescription)\n\nYou can also add Live Wallpaper yourself in System Settings › General › Login Items.")
        }
    }

    @objc private func about() {
        let credits = NSMutableAttributedString(
            string: "A wallpaper that follows your real sky.\n",
            attributes: [.foregroundColor: NSColor.labelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
        credits.append(NSAttributedString(
            string: AppDelegate.repository,
            attributes: [.link: AppDelegate.repository, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
