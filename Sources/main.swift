import Cocoa
import WebKit
import os
import Carbon.HIToolbox

let log = Logger(subsystem: "com.ltw.wallpaper", category: "app")

// MARK: - Scene model

struct Scene {
    enum Kind: String { case html, image, video }
    let name: String
    let url: URL
    let kind: Kind
}

// MARK: - A borderless window that lives at the desktop layer (behind icons, above the system wallpaper)

final class WallpaperWindow: NSWindow {
    let webView: WKWebView
    let ucc = WKUserContentController()   // kept here: webView.configuration returns a copy
    let screenIndex: Int

    init(screen: NSScreen, index: Int, handler: WKScriptMessageHandler) {
        screenIndex = index
        let cfg = WKWebViewConfiguration()
        cfg.userContentController = ucc
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Let scenes fetch() files next to them (e.g. .obj models) from file:// URLs.
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.setValue(true, forKey: "allowUniversalAccessFromFileURLs")
        ucc.add(WeakHandler(handler), name: "ltw")
        webView = WKWebView(frame: NSRect(origin: .zero, size: screen.frame.size), configuration: cfg)
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = .black
        contentView = webView
        setFrame(screen.frame, display: true)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    let defaults = UserDefaults.standard
    let fm = FileManager.default
    var statusItem: NSStatusItem!
    let menu = NSMenu()
    var windows: [WallpaperWindow] = []
    var windowObservers: [NSObjectProtocol] = []
    var scenes: [Scene] = []
    var current: Scene?
    var screenChangeWork: DispatchWorkItem?
    var syncWork: DispatchWorkItem?
    var refreshTimer: Timer?
    let power = PowerMonitor()
    let settings = AppSettings()
    let dock = DockSettings()
    var caffeinate: Process?
    let stats = SystemStats()
    let mixer = AudioMixer()
    let levels = AudioLevels()
    var sceneWants = (pointer: false, audio: false)   // declared by the current scene's SCHEMA
    var pointerTimer: Timer?
    var lastPointer: [Int: (Double, Double)] = [:]
    var statsTimer: Timer?
    var statItems: [NSMenuItem] = []
    var rotateTimer: Timer?
    let hotkeys = HotKeys()
    let windowManager = WindowManager()
    let wheel = RadialMenu()
    var thumbWork: DispatchWorkItem?
    var panel: CustomizePanel?
    lazy var store = SettingsStore(dir: appSupport.appendingPathComponent("settings", isDirectory: true))

    static let imageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "heic", "webp", "avif", "tiff", "bmp"]
    static let videoExts: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let htmlExts: Set<String> = ["html", "htm"]

    var appSupport: URL {
        fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LtwWallpaper", isDirectory: true)
    }

    /// Scenes live in ~/Library/Application Support/LtwWallpaper/scenes (build.sh and `ltw reload` mirror the
    /// project's scenes/ folder there). `defaults write com.ltw.wallpaper scenesPath <dir>` overrides this;
    /// note that a folder under Desktop/Documents/Downloads makes macOS show a permission prompt on every rebuild.
    lazy var scenesDir: URL = {
        if let p = defaults.string(forKey: "scenesPath"), fm.fileExists(atPath: p) {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return appSupport.appendingPathComponent("scenes", isDirectory: true)
    }()

    var imagesDir: URL { scenesDir.appendingPathComponent("images", isDirectory: true) }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ensureScenesDir()
        installEditMenu()
        setupStatusItem()
        refreshScenes()
        rebuildWindows()
        let saved = defaults.string(forKey: "lastScene")
        if let s = scenes.first(where: { $0.name == saved }) ?? scenes.first {
            load(s)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        power.onChange = { [weak self] in self?.pushRuntimeToAll(); self?.updateFeeds() }
        power.onHide = { [weak self] in
            guard let self = self, self.menuBarMode == "match", self.settings.bool("lockScreenFrame") else { return }
            log.notice("lock screen: snapshotting the current frame")
            self.syncSystemWallpaper(force: true)
        }
        levels.onFrame = { [weak self] f in self?.pushAudio(f) }
        restartRefreshTimer()
        if settings.bool("dockIcon") { NSApp.setActivationPolicy(.regular) }
        applyKeepAwake()
        mixer.onChange = { [weak self] in self?.pushMixer() }
        mixer.refresh()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.statsTick() }
        restartRotateTimer()
        applyHotkeys()
    }

    // MARK: Scene rotation, pause, hotkeys, thumbnails

    func restartRotateTimer() {
        rotateTimer?.invalidate(); rotateTimer = nil
        let minutes = settings.double("rotateEvery")
        guard minutes > 0 else { return }
        rotateTimer = Timer.scheduledTimer(withTimeInterval: minutes * 60, repeats: true) { [weak self] _ in self?.nextScene() }
    }

    @objc func nextScene() {
        refreshScenes()
        guard !scenes.isEmpty else { return }
        let i = scenes.firstIndex { $0.name == current?.name } ?? -1
        if settings.bool("rotateShuffle"), scenes.count > 1 {
            var j = Int.random(in: 0..<scenes.count)
            while j == i { j = Int.random(in: 0..<scenes.count) }
            load(scenes[j])
        } else {
            load(scenes[(i + 1) % scenes.count])
        }
    }

    @objc func togglePause() {
        power.userPaused.toggle()
        updateStatusIcon()
        if !power.userPaused { scheduleWallpaperSync() }
    }

    func applyHotkeys() {
        hotkeys.unregisterAll()
        guard settings.bool("hotkeys") else { return }
        let mods = UInt32(controlKey | optionKey)
        hotkeys.register(id: 1, keyCode: UInt32(kVK_ANSI_N), modifiers: mods) { [weak self] in self?.nextScene() }
        hotkeys.register(id: 2, keyCode: UInt32(kVK_ANSI_P), modifiers: mods) { [weak self] in self?.togglePause() }
        hotkeys.register(id: 3, keyCode: UInt32(kVK_ANSI_K), modifiers: mods) { [weak self] in self?.toggleKeepAwake() }
        hotkeys.register(id: 4, keyCode: UInt32(kVK_ANSI_M), modifiers: mods) { [weak self] in self?.openMixer() }
        hotkeys.register(id: 5, keyCode: UInt32(kVK_ANSI_C), modifiers: mods) { [weak self] in self?.toggleCustomize() }
        if settings.bool("wheel") {
            hotkeys.register(id: 6, keyCode: UInt32(kVK_ANSI_W), modifiers: mods,
                             released: { [weak self] in self?.wheel.released() }) { [weak self] in self?.showWheel(sticky: false) }
        }
        if settings.bool("switcher") {
            hotkeys.register(id: 7, keyCode: UInt32(kVK_Tab), modifiers: mods,
                             released: { [weak self] in self?.wheel.released() }) { [weak self] in self?.showSwitcher(sticky: false) }
        }
    }

    // MARK: Window wheel and app wheel

    func applyWheelLook() {
        wheel.look.accent = NSColor(hex: settings.string("panelAccent")) ?? wheel.look.accent
        wheel.look.radius = CGFloat(settings.double("wheelSize"))
        wheel.look.dim = CGFloat(settings.double("wheelDim"))
        wheel.look.labels = settings.bool("switcherLabels")
        windowManager.gap = CGFloat(settings.double("wheelGap"))
    }

    /// ⌃⌥W: eight layouts around the cursor, "Center" in the hub, applied to the user's front window.
    func showWheel(sticky: Bool) {
        applyWheelLook()
        if !WindowManager.trusted { WindowManager.requestTrust() }
        let target = windowManager.frontmost()
        let items = WindowLayout.wheel.map { WheelItem(label: $0.label, layout: $0) }
        log.notice("wheel: shown (\(sticky ? "sticky" : "hold", privacy: .public)) for \(target?.app.localizedName ?? "nothing", privacy: .public)")
        wheel.show(items: items, hub: WheelItem(label: WindowLayout.center.label), hubIcon: target?.app.icon,
                   hubTitle: target?.app.localizedName ?? "No window", trusted: WindowManager.trusted, sticky: sticky) { [weak self] pick in
            guard let self = self else { return }
            let layout: WindowLayout
            switch pick {
            case .hub: layout = .center
            case .wedge(let i): layout = WindowLayout.wheel[i]
            case .none: return
            }
            let ok = self.windowManager.apply(layout, to: target)
            log.notice("wheel: \(layout.rawValue, privacy: .public) → \(target?.app.localizedName ?? "none", privacy: .public) \(ok ? "ok" : "failed", privacy: .public)")
        }
    }

    /// ⌃⌥Tab: running apps (or their windows) around the cursor, most recent first; the hub goes back
    /// to the previous app, like ⌘Tab.
    func showSwitcher(sticky: Bool) {
        applyWheelLook()
        let windowsMode = settings.string("switcherMode") == "windows"
        let maxItems = max(3, min(12, Int(settings.double("switcherMax"))))
        if windowsMode, !WindowManager.trusted { WindowManager.requestTrust() }
        let all = windowManager.switchItems(windows: windowsMode, max: maxItems + 1)
        let current = windowManager.userApp()
        // The app you are in is the hub's "previous app" target only in apps mode; its wedge is dropped
        // so the ring holds the places you can go to.
        var list = all
        var hub: WheelItem? = nil
        if !windowsMode, let cur = current, let i = list.firstIndex(where: { $0.app.processIdentifier == cur.processIdentifier }) {
            list.remove(at: i)
        }
        list = Array(list.prefix(maxItems))
        if let prev = list.first {
            hub = WheelItem(label: prev.title, icon: prev.app.icon, subtitle: windowsMode ? (prev.app.localizedName ?? "") : "previous")
        }
        guard !list.isEmpty else { return }
        let items = list.map { WheelItem(label: windowsMode ? ($0.app.localizedName ?? "") : $0.title, icon: $0.app.icon,
                                         subtitle: windowsMode ? $0.title : "") }
        log.notice("switcher: shown (\(sticky ? "sticky" : "hold", privacy: .public)) \(list.count) items")
        wheel.show(items: items, hub: hub, hubIcon: current?.icon, hubTitle: current?.localizedName ?? "Apps",
                   trusted: !windowsMode || WindowManager.trusted, sticky: sticky) { [weak self] pick in
            guard let self = self else { return }
            let item: WindowManager.SwitchItem
            switch pick {
            case .hub: item = list[0]
            case .wedge(let i): item = list[i]
            case .none: return
            }
            log.notice("switcher: → \(item.title, privacy: .public)")
            self.windowManager.activate(item)
        }
    }

    @objc func wheelFromMenu() { showWheel(sticky: true) }
    @objc func switcherFromMenu() { showSwitcher(sticky: true) }

    @objc func windowAction(_ sender: NSMenuItem) {
        guard let layout = WindowLayout(rawValue: sender.representedObject as? String ?? "") else { return }
        applyWheelLook()
        windowManager.apply(layout)
    }

    @objc func allowWindowManagement() { WindowManager.requestTrust(force: true) }

    var thumbsDir: URL { scenesDir.appendingPathComponent("_thumbs", isDirectory: true) }

    static func thumbFile(_ name: String) -> String {
        let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        return String(name.unicodeScalars.map { ok.contains($0) ? Character($0) : "_" }) + ".jpg"
    }

    /// A small snapshot of the running scene for the Customize picker, taken a few seconds after it loads.
    func scheduleThumbnail(for scene: Scene) {
        thumbWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.captureThumbnail(for: scene) }
        thumbWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
    }

    func captureThumbnail(for scene: Scene) {
        guard current?.name == scene.name, !power.forcedPause, let webView = windows.first?.webView else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.snapshotWidth = 400
        webView.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self = self, let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return }
            try? self.fm.createDirectory(at: self.thumbsDir, withIntermediateDirectories: true)
            let url = self.thumbsDir.appendingPathComponent(Self.thumbFile(scene.name))
            try? jpg.write(to: url)
            if self.panel?.window?.isVisible == true {
                self.panel?.send("window.__panelThumb && __panelThumb(\(self.json(scene.name)), \(self.json(self.thumbURL(scene.name) ?? "")))")
            }
        }
    }

    func thumbURL(_ name: String) -> String? {
        let url = thumbsDir.appendingPathComponent(Self.thumbFile(name))
        guard let attrs = try? fm.attributesOfItem(atPath: url.path), let date = attrs[.modificationDate] as? Date else { return nil }
        return "_thumbs/" + Self.thumbFile(name).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + "?v=\(Int(date.timeIntervalSince1970))"
    }

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let credits = NSAttributedString(string: "Live wallpaper engine for macOS: animated scenes behind your desktop icons, a Customize window for scenes, the menu bar, the Dock, per-app volume and system stats.\n\nScenes live in \(scenesDir.path)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Ltw Wallpaper", .applicationVersion: version, .credits: credits,
                                                     .version: ""])
    }

    @objc func toggleDesktopIcons() { SystemActions.setDesktopIconsHidden(!SystemActions.desktopIconsHidden) }
    @objc func toggleDarkMode() { SystemActions.toggleDarkMode() }
    @objc func sleepDisplay() { SystemActions.sleepDisplay() }
    @objc func startScreenSaver() { SystemActions.startScreenSaver() }

    @objc func exportSettings() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "Ltw Wallpaper settings.json"
        save.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard save.runModal() == .OK, let url = save.url else { return }
        let bundle = SettingsBundle.export(store: store, scenes: scenes)
        if let data = try? JSONSerialization.data(withJSONObject: bundle, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: url) }
    }

    @objc func importSettings() {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url, let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], SettingsBundle.apply(obj, store: store) else {
            let a = NSAlert(); a.messageText = "Not a Ltw Wallpaper settings file."; a.runModal(); return
        }
        applyAllAppSettings()
        restartRotateTimer()
        applyHotkeys()
        if let c = current { load(c) }
        panelLoad()
    }

    /// Opening the app icon again (Finder, Launchpad, Spotlight) while it is already running lands here:
    /// the engine is a single instance, so show the Customize window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        log.notice("reopen requested while running; showing Customize")
        customize()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        restoreOriginalWallpaper()
        caffeinate?.terminate()
        mixer.teardownEngine()
    }

    // MARK: System monitor + mixer plumbing

    func statsTick() {
        stats.sample()
        let lines = stats.menuLines
        for (i, item) in statItems.enumerated() where i < lines.count { item.title = lines[i] }
        if settings.string("menuReadout") != "none" { updateStatusIcon() }
        if panel?.window?.isVisible == true {
            panel?.send("window.__stats && __stats(\(json(stats.last.json)))")
            mixer.refresh()
        }
    }

    func pushMixer() {
        guard panel?.window?.isVisible == true else { return }
        panel?.send("window.__mixerState && __mixerState(\(json(mixer.state())))")
    }

    @objc func openMixer() {
        customize()
        panel?.send("window.__panelTab && __panelTab('audio')")
        mixer.refresh(force: true)
    }

    // MARK: Keep awake
    // Runs /usr/bin/caffeinate -di (no idle sleep, no display sleep) while the toggle is on.

    func applyKeepAwake() {
        let on = settings.bool("keepAwake")
        if on, caffeinate?.isRunning != true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-di"]
            do { try p.run(); caffeinate = p } catch { log.notice("caffeinate failed: \(error.localizedDescription)") }
        } else if !on, let p = caffeinate {
            p.terminate()
            caffeinate = nil
        }
        updateStatusIcon()
    }

    @objc func toggleKeepAwake() {
        applyAppSetting("keepAwake", !settings.bool("keepAwake"))
        panelLoad()
    }

    /// An LSUIElement app has no visible menu bar, but key equivalents still resolve through the main
    /// menu, so Cmd+C/V/A/W work inside the Customize window.
    func installEditMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu(); appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q")
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        NSApp.mainMenu = main
    }

    // MARK: Scenes folder

    func ensureScenesDir() {
        try? fm.createDirectory(at: scenesDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: imagesDir, withIntermediateDirectories: true)
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("scenes"),
              fm.fileExists(atPath: bundled.path) else { return }
        let bundledItems = (try? fm.contentsOfDirectory(at: bundled, includingPropertiesForKeys: nil)) ?? []
        // Internal files (_media.html, _ltw.js, _panel.html) are required; scenes are only seeded into an empty folder.
        refreshScenes()
        for item in bundledItems {
            let name = item.lastPathComponent
            let dest = scenesDir.appendingPathComponent(name)
            let required = name.hasPrefix("_")
            if (required || scenes.isEmpty) && !fm.fileExists(atPath: dest.path) {
                try? fm.copyItem(at: item, to: dest)
            }
        }
    }

    func refreshScenes() {
        var found: [Scene] = []
        let items = (try? fm.contentsOfDirectory(
            at: scenesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in items {
            let name = url.lastPathComponent
            if name.hasPrefix("_") || name.hasPrefix(".") { continue }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                let index = url.appendingPathComponent("index.html")
                if fm.fileExists(atPath: index.path) { found.append(Scene(name: name, url: index, kind: .html)) }
                continue
            }
            let ext = url.pathExtension.lowercased()
            let base = url.deletingPathExtension().lastPathComponent
            if Self.htmlExts.contains(ext) { found.append(Scene(name: base, url: url, kind: .html)) }
            else if Self.imageExts.contains(ext) { found.append(Scene(name: name, url: url, kind: .image)) }
            else if Self.videoExts.contains(ext) { found.append(Scene(name: name, url: url, kind: .video)) }
        }
        scenes = found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func listImages() -> [String] {
        let items = (try? fm.contentsOfDirectory(at: imagesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { Self.imageExts.contains($0.pathExtension.lowercased()) }
            .map { "images/" + $0.lastPathComponent }
            .sorted()
    }

    // MARK: Windows

    func rebuildWindows() {
        windowObservers.forEach { NotificationCenter.default.removeObserver($0) }
        windowObservers = []
        for w in windows { w.orderOut(nil); w.close() }
        windows = []
        for (i, screen) in NSScreen.screens.enumerated() {
            let w = WallpaperWindow(screen: screen, index: i, handler: self)
            w.webView.navigationDelegate = self
            w.orderFrontRegardless()
            windows.append(w)
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: w, queue: .main) { [weak self, weak w] _ in
                if let w = w { self?.pushRuntime(to: w) }
                self?.updateFeeds()
            }
            windowObservers.append(token)
        }
    }

    func json(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Each page gets `window.LTW` with screen info, the image list, its saved settings and the runtime state,
    /// injected before the scene's own scripts run.
    func userScriptSource(for w: WallpaperWindow, settings: [String: Any]) -> String {
        let screens = NSScreen.screens
        let screen = screens.indices.contains(w.screenIndex) ? screens[w.screenIndex] : screens[0]
        let info: [String: Any] = [
            "screen": [
                "index": w.screenIndex, "count": screens.count,
                "width": Double(screen.frame.width), "height": Double(screen.frame.height),
                "scale": Double(screen.backingScaleFactor),
            ],
            "images": listImages(),
            "scenesPath": scenesDir.path,
            "settings": settings,
            "runtime": ["paused": power.forcedPause, "maxFps": power.maxFps],
        ]
        return "window.LTW = \(json(info));"
    }

    // MARK: Loading

    func load(_ scene: Scene) {
        current = scene
        defaults.set(scene.name, forKey: "lastScene")
        for w in windows { load(scene, into: w) }
        updateStatusIcon()
        scheduleWallpaperSync()
        scheduleThumbnail(for: scene)
    }

    func load(_ scene: Scene, into w: WallpaperWindow) {
        let settings = scene.kind == .html ? store.load(scene.name) : [:]
        w.ucc.removeAllUserScripts()
        w.ucc.addUserScript(WKUserScript(source: userScriptSource(for: w, settings: settings),
                                         injectionTime: .atDocumentStart, forMainFrameOnly: true))
        switch scene.kind {
        case .html:
            w.webView.loadFileURL(scene.url, allowingReadAccessTo: scenesDir)
        case .image, .video:
            let rel = scene.url.path.replacingOccurrences(of: scenesDir.path + "/", with: "")
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~/")
            let encoded = rel.addingPercentEncoding(withAllowedCharacters: allowed) ?? rel
            var comps = URLComponents(url: scenesDir.appendingPathComponent("_media.html"), resolvingAgainstBaseURL: false)!
            comps.fragment = "type=\(scene.kind.rawValue)&file=\(encoded)"
            w.webView.loadFileURL(comps.url!, allowingReadAccessTo: scenesDir)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let c = current, let w = windows.first(where: { $0.webView === webView }) { load(c, into: w) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let w = windows.first(where: { $0.webView === webView }) { pushRuntime(to: w) }
        if webView === windows.first?.webView {
            webView.evaluateJavaScript("JSON.stringify(window.LTW && LTW.schema ? {p: !!LTW.schema.pointer, a: !!LTW.schema.audio} : null)") { [weak self] r, _ in
                guard let self = self else { return }
                var wants = (pointer: false, audio: false)
                if let str = r as? String, let d = try? JSONSerialization.jsonObject(with: Data(str.utf8)) as? [String: Any] {
                    wants = ((d["p"] as? Bool) ?? false, (d["a"] as? Bool) ?? false)
                }
                self.sceneWants = wants
                self.updateFeeds()
            }
        }
        if webView === windows.first?.webView, panel?.window?.isVisible == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.panelLoad() }
        }
    }

    // MARK: Runtime (pause / fps cap)

    func pushRuntime(to w: WallpaperWindow) {
        let paused = power.forcedPause || !w.occlusionState.contains(.visible)
        let rt: [String: Any] = ["paused": paused, "maxFps": power.maxFps]
        log.notice("screen \(w.screenIndex): paused=\(paused) maxFps=\(self.power.maxFps)")
        w.webView.evaluateJavaScript("window.__ltwRuntime && __ltwRuntime(\(json(rt)))", completionHandler: nil)
    }

    func pushRuntimeToAll() { for w in windows { pushRuntime(to: w) } }

    // MARK: Pointer and audio feeds (only while the scene asks for them and is visible)

    func updateFeeds() {
        let visible = !power.forcedPause && windows.contains { $0.occlusionState.contains(.visible) }
        let wantAudio = visible && sceneWants.audio && settings.bool("audioReactive")
        if wantAudio != levels.running { log.notice("feeds: audio \(wantAudio) pointer \(visible && self.sceneWants.pointer)") }
        levels.setEnabled(wantAudio)
        let wantPointer = visible && sceneWants.pointer
        if wantPointer, pointerTimer == nil {
            pointerTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pointerTick() }
        } else if !wantPointer, let t = pointerTimer {
            t.invalidate(); pointerTimer = nil; lastPointer = [:]
        }
    }

    func pointerTick() {
        let loc = NSEvent.mouseLocation
        let screens = NSScreen.screens
        for w in windows {
            guard screens.indices.contains(w.screenIndex) else { continue }
            let f = screens[w.screenIndex].frame
            let x = max(-1, min(1, ((loc.x - f.minX) / f.width) * 2 - 1))
            let y = max(-1, min(1, ((loc.y - f.minY) / f.height) * 2 - 1))
            if let p = lastPointer[w.screenIndex], abs(p.0 - x) < 0.002, abs(p.1 - y) < 0.002 { continue }
            lastPointer[w.screenIndex] = (Double(x), Double(y))
            w.webView.evaluateJavaScript(String(format: "window.__ltwPointer && __ltwPointer(%.4f, %.4f)", x, y), completionHandler: nil)
        }
    }

    func pushAudio(_ f: AudioLevels.Frame) {
        guard levels.running else { return }
        let js = "window.__ltwAudio && __ltwAudio(\(json(f.json)))"
        for w in windows where w.occlusionState.contains(.visible) { w.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    // MARK: Live settings

    func applyLive(_ patch: [String: Any]) {
        let js = "window.__ltwApply && __ltwApply(\(json(patch)))"
        for w in windows { w.webView.evaluateJavaScript(js, completionHandler: nil) }
    }

    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "ready":
            panelLoad()
        case "set":
            guard let c = current, let key = body["key"] as? String, let value = body["value"] else { return }
            store.set(c.name, key: key, value: value)
            applyLive([key: value])
            scheduleWallpaperSync()
        case "reset":
            guard let c = current else { return }
            store.reset(c.name)
            load(c)
        case "scene":
            if let n = body["name"] as? String, let s = scenes.first(where: { $0.name == n }) { load(s) }
        case "tab":
            if let n = body["name"] as? String { defaults.set(n, forKey: "panelTab") }
        case "close":
            panel?.window?.performClose(nil)
        case "appset":
            if let key = body["key"] as? String, let value = body["value"] { applyAppSetting(key, value) }
        case "appreset":
            settings.reset()
            applyAllAppSettings()
            panelLoad()
        case "pickfile":
            if let key = body["key"] as? String { pickFile(forKey: key, app: body["ctx"] as? String == "appset") }
        case "dockset":
            if let key = body["key"] as? String, let value = body["value"] { dock.set(key, value) }
        case "dockreset":
            dock.reset()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.panelLoad() }
        case "action":
            if body["ctx"] as? String == "dockset", let name = body["name"] as? String { dock.action(name) }
        case "mixer":
            let num = { (k: String) -> Double? in (body[k] as? NSNumber)?.doubleValue }
            let on = (body["on"] as? NSNumber)?.boolValue ?? false
            switch body["action"] as? String ?? "" {
            case "volume": if let k = body["key"] as? String, let v = num("value") { mixer.setVolume(k, v) }
            case "mute": if let k = body["key"] as? String { mixer.setMuted(k, on) }
            case "master": if let v = num("value") { mixer.masterVolume = v }
            case "masterMute": mixer.masterMuted = on; pushMixer()
            case "output": if let uid = body["uid"] as? String { mixer.setOutput(uid: uid) }
            case "retry": mixer.retryEngine()
            default: mixer.refresh(force: true)
            }
        case "log":
            log.info("scene: \(String(describing: body["text"] ?? ""))")
        default:
            break
        }
    }

    // MARK: Customize panel

    /// Menu item and ⌃⌥C: open, or hide when it is already the front window.
    @objc func toggleCustomize() {
        if panel?.window?.isVisible == true, panel?.window?.isKeyWindow == true { panel?.window?.orderOut(nil) } else { customize() }
    }

    @objc func customize() {
        if panel == nil {
            panel = CustomizePanel(handler: self, panelURL: scenesDir.appendingPathComponent("_panel.html"), readAccess: scenesDir)
            panel?.window?.center()
        }
        applyPanelLook()
        panel?.show()
        panelLoad()
    }

    /// Ask the running scene for its schema/defaults/config and hand everything to the panel page.
    func panelLoad() {
        guard let panel = panel, let c = current else { return }
        let finish: ([String: Any]?) -> Void = { [weak self] desc in
            guard let self = self else { return }
            var payload: [String: Any] = [
                "scene": c.name, "kind": c.kind.rawValue,
                "scenes": self.scenes.map { $0.name },
                "settings": self.store.load(c.name),
                "schema": NSNull(), "defaults": NSNull(), "config": NSNull(),
                "app": ["schema": AppSettings.schema, "defaults": AppSettings.defaults, "config": self.settings.config],
                "look": self.panelLook,
                "dock": ["schema": DockSettings.schema, "defaults": DockSettings.defaults, "config": self.dock.config],
                "mixer": self.mixer.state(),
                "stats": self.stats.last.json,
                "tab": self.defaults.string(forKey: "panelTab") ?? "scene",
                "sceneList": self.scenes.map { s -> [String: Any] in ["name": s.name, "kind": s.kind.rawValue, "thumb": self.thumbURL(s.name).map { $0 as Any } ?? NSNull()] },
            ]
            if let d = desc {
                payload["schema"] = d["schema"] ?? NSNull()
                payload["defaults"] = d["defaults"] ?? NSNull()
                payload["config"] = d["config"] ?? NSNull()
            }
            panel.send("window.__panelLoad && __panelLoad(\(self.json(payload)))")
        }
        guard c.kind == .html, let wv = windows.first?.webView else { finish(nil); return }
        wv.evaluateJavaScript("JSON.stringify(window.LTW && LTW.describe ? LTW.describe() : null)") { r, _ in
            let desc = (r as? String).flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            finish(desc)
        }
    }

    // MARK: Menu

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        menu.delegate = self
        statusItem.menu = menu
    }

    /// Menu bar icon: a custom image, else emoji/text, else an SF Symbol; optionally followed by the scene name.
    func updateStatusIcon() {
        guard let b = statusItem.button else { return }
        b.image = nil
        b.title = ""
        let emoji = settings.string("menuIconEmoji").trimmingCharacters(in: .whitespaces)
        let imagePath = settings.string("menuIconImage")
        if !imagePath.isEmpty, let img = NSImage(contentsOfFile: imagePath), img.size.height > 0 {
            let h: CGFloat = 18
            img.size = NSSize(width: img.size.width * h / img.size.height, height: h)
            img.isTemplate = !settings.bool("menuIconColor")
            b.image = img
        } else if !emoji.isEmpty {
            b.title = emoji
        } else {
            let img = NSImage(systemSymbolName: settings.string("menuIcon"), accessibilityDescription: "Ltw Wallpaper")
                ?? NSImage(systemSymbolName: "sparkles.rectangle.stack", accessibilityDescription: "Ltw Wallpaper")
            img?.isTemplate = true
            b.image = img
        }
        if settings.bool("menuShowScene"), let c = current {
            b.title = b.title.isEmpty ? c.name : b.title + " " + c.name
        }
        let readout = stats.readout(settings.string("menuReadout"))
        if !readout.isEmpty { b.title = b.title.isEmpty ? readout : b.title + "  " + readout }
        b.imagePosition = b.image == nil ? .noImage : (b.title.isEmpty ? .imageOnly : .imageLeading)
        statusItem.length = b.title.isEmpty ? NSStatusItem.squareLength : NSStatusItem.variableLength
        b.toolTip = (current.map { "Ltw Wallpaper — \($0.name)" } ?? "Ltw Wallpaper") + (settings.bool("keepAwake") ? " · keeping awake" : "") + (power.userPaused ? " · paused" : "")
        b.appearsDisabled = power.userPaused
    }

    // MARK: App settings (the "App" tab of Customize)

    func applyAppSetting(_ key: String, _ value: Any) {
        if key == "loginItem" {
            do { try settings.setLoginItem((value as? NSNumber)?.boolValue ?? false) }
            catch { log.notice("login item: \(error.localizedDescription)") }
            log.notice("login item now: \(self.settings.loginItem)")
            panelLoad()   // show the state the system actually has
            return
        }
        settings.set(key, value)
        switch key {
        case "menuIcon", "menuIconEmoji", "menuIconImage", "menuIconColor", "menuShowScene", "menuReadout":
            updateStatusIcon()
        case "menuBarMode", "menuBarColor", "menuBarDim":
            if menuBarMode == "off" { syncWork?.cancel(); restoreOriginalWallpaper() } else { scheduleWallpaperSync(after: 0.4) }
            restartRefreshTimer()
        case "menuBarRefresh":
            restartRefreshTimer()
        case "rotateEvery", "rotateShuffle":
            restartRotateTimer()
        case "hotkeys", "wheel", "switcher":
            applyHotkeys()
        case "batterySaver":
            power.saver = PowerMonitor.Saver(rawValue: settings.string("batterySaver")) ?? .auto
        case "keepAwake":
            applyKeepAwake()
        case "audioReactive":
            updateFeeds()
        case "dockIcon":
            NSApp.setActivationPolicy(settings.bool("dockIcon") ? .regular : .accessory)
            panel?.show()
        case _ where key.hasPrefix("panel"):
            applyPanelLook()
        default:
            break
        }
    }

    func applyAllAppSettings() {
        updateStatusIcon()
        power.saver = PowerMonitor.Saver(rawValue: settings.string("batterySaver")) ?? .auto
        if menuBarMode == "off" { syncWork?.cancel(); restoreOriginalWallpaper() } else { scheduleWallpaperSync(after: 0.4) }
        restartRefreshTimer()
        NSApp.setActivationPolicy(settings.bool("dockIcon") ? .regular : .accessory)
        applyKeepAwake()
        applyPanelLook()
    }

    /// The Customize window's look, with "system" resolved to the current appearance.
    var panelLook: [String: Any] {
        var theme = settings.string("panelTheme")
        if theme == "system" {
            theme = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua ? "light" : "dark"
        }
        return [
            "panelStyle": settings.string("panelStyle"),
            "panelOpacity": settings.double("panelOpacity"),
            "panelTheme": theme,
            "panelAccent": settings.string("panelAccent"),
            "panelButtons": settings.bool("panelButtons"),
            "panelOnTop": settings.bool("panelOnTop"),
            "panelAutoHide": settings.bool("panelAutoHide"),
        ]
    }

    func applyPanelLook() {
        guard let panel = panel else { return }
        let look = panelLook
        panel.apply(look: look)
        panel.send("window.__panelLook && __panelLook(\(json(look)))")
    }

    func pickFile(forKey key: String, app: Bool) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.png, .jpeg, .tiff, .pdf, .heic]
        open.allowsMultipleSelection = false
        open.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        if app { applyAppSetting(key, url.path) }
        else if let c = current { store.set(c.name, key: key, value: url.path); applyLive([key: url.path]) }
        panelLoad()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshScenes()
        menu.removeAllItems()
        statItems = []
        if settings.bool("statsInMenu") {
            stats.sample()
            for line in stats.menuLines {
                let it = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                it.isEnabled = false
                menu.addItem(it)
                statItems.append(it)
            }
            menu.addItem(.separator())
        }
        let header = NSMenuItem(title: "Scenes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if scenes.isEmpty {
            let empty = NSMenuItem(title: "No scenes found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for (i, s) in scenes.enumerated() {
            let item = NSMenuItem(title: s.name, action: #selector(pickScene(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.target = self
            item.tag = i
            item.image = symbol(s.kind == .video ? "film" : s.kind == .image ? "photo" : "sparkles")
            item.state = (s.name == current?.name) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "Customize…", #selector(toggleCustomize), ",", "slider.horizontal.3")
        add(menu, "Volume Mixer…", #selector(openMixer), "m", "speaker.wave.2")
        add(menu, "Save Snapshot", #selector(saveSnapshot), "s", "camera")
        let pause = add(menu, power.userPaused ? "Resume Animation" : "Pause Animation", #selector(togglePause), "p", power.userPaused ? "play.circle" : "pause.circle")
        pause.toolTip = "Freezes every scene (⌃⌥P). Handy on battery or during a call."
        let awake = add(menu, "Keep Awake", #selector(toggleKeepAwake), "k", "cup.and.saucer")
        awake.state = settings.bool("keepAwake") ? .on : .off
        awake.toolTip = "Stops the Mac and display from sleeping (caffeinate) until switched off."
        menu.addItem(.separator())
        let system = NSMenuItem(title: "System", action: nil, keyEquivalent: "")
        system.image = symbol("macwindow")
        let sys = NSMenu()
        let icons = add(sys, "Hide Desktop Icons", #selector(toggleDesktopIcons), "", "rectangle.dashed")
        icons.state = SystemActions.desktopIconsHidden ? .on : .off
        icons.toolTip = "Finder restarts to hide or show the icons; the wallpaper stays."
        add(sys, "Toggle Dark Mode", #selector(toggleDarkMode), "", "circle.lefthalf.filled")
        add(sys, "Start Screen Saver", #selector(startScreenSaver), "", "sparkles.tv")
        add(sys, "Sleep Display", #selector(sleepDisplay), "", "display")
        system.submenu = sys
        menu.addItem(system)
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        window.image = symbol("circle.grid.cross")
        let win = NSMenu()
        let wheelItem = add(win, "Window Wheel…", #selector(wheelFromMenu), "w", "circle.grid.cross")
        wheelItem.toolTip = "Hold ⌃⌥W anywhere, move toward a layout, let go."
        let appsItem = add(win, "App Wheel…", #selector(switcherFromMenu), "", "circle.grid.3x3")
        appsItem.toolTip = "Hold ⌃⌥Tab, move toward an app, let go."
        win.addItem(.separator())
        for layout in [WindowLayout.left, .right, .top, .bottom, .maximize, .center, .nextDisplay, .minimize, .restore] {
            let item = NSMenuItem(title: layout.label, action: #selector(windowAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.rawValue
            win.addItem(item)
        }
        if !WindowManager.trusted {
            win.addItem(.separator())
            add(win, "Allow Window Management…", #selector(allowWindowManagement), "", "lock.open")
        }
        window.submenu = win
        menu.addItem(window)
        // Everything a casual user never needs lives under Advanced; battery saver and the menu bar tint are in Customize → App.
        let advanced = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advanced.image = symbol("ellipsis.circle")
        let adv = NSMenu()
        add(adv, "Reload Scenes", #selector(reload), "r", "arrow.clockwise")
        add(adv, "Open Scenes Folder", #selector(openScenesFolder), "o", "folder")
        add(adv, "Open Current Scene in Browser", #selector(openInBrowser), "b", "safari")
        adv.addItem(.separator())
        add(adv, "Refresh Menu Bar Tint", #selector(syncNow), "", "paintbrush")
        add(adv, "Restore Original Wallpaper", #selector(restoreOriginalWallpaper), "", "arrow.uturn.backward")
        adv.addItem(.separator())
        add(adv, "Export Settings…", #selector(exportSettings), "", "square.and.arrow.up")
        add(adv, "Import Settings…", #selector(importSettings), "", "square.and.arrow.down")
        advanced.submenu = adv
        menu.addItem(advanced)
        menu.addItem(.separator())
        add(menu, "About Ltw Wallpaper", #selector(showAbout), "", "info.circle")
        add(menu, "Quit Ltw Wallpaper", #selector(quit), "q", "power")
    }

    func symbol(_ name: String) -> NSImage? {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        img?.isTemplate = true
        return img
    }

    @discardableResult
    func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ key: String, _ icon: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.image = symbol(icon)
        menu.addItem(item)
        return item
    }

    @objc func pickScene(_ sender: NSMenuItem) {
        guard scenes.indices.contains(sender.tag) else { return }
        load(scenes[sender.tag])
    }

    @objc func reload() {
        refreshScenes()
        rebuildWindows()
        if let c = current, let s = scenes.first(where: { $0.name == c.name }) { load(s) }
        else if let s = scenes.first { load(s) }
    }

    @objc func openScenesFolder() { NSWorkspace.shared.open(scenesDir) }

    @objc func openInBrowser() {
        guard let c = current else { return }
        NSWorkspace.shared.open(c.url)
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func screensChanged() {
        screenChangeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    // MARK: ltw:// URLs  (see the `ltw` script)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    func handle(_ url: URL) {
        guard url.scheme == "ltw" else { return }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let arg = { (name: String) -> String? in query.first { $0.name == name }?.value }
        switch url.host {
        case "scene":
            let name = url.pathComponents.dropFirst().joined(separator: "/")
            refreshScenes()
            if let s = scenes.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { load(s) }
        case "next":
            nextScene()
        case "pause":
            togglePause()
        case "reload":
            reload()
        case "sync":
            syncSystemWallpaper()
        case "snapshot":
            if let p = arg("path"), !p.isEmpty { snapshot(to: URL(fileURLWithPath: p)) } else { saveSnapshot() }
        case "customize":
            customize()
        case "wheel":
            showWheel(sticky: true)
        case "apps":
            showSwitcher(sticky: true)
        case "window":
            let name = url.pathComponents.dropFirst().first ?? ""
            if let layout = WindowLayout(rawValue: name) { applyWheelLook(); windowManager.apply(layout) }
        case "set":
            guard let c = current, let key = arg("key"), let raw = arg("value"),
                  let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            store.set(c.name, key: key, value: value)
            applyLive([key: value])
            scheduleWallpaperSync()
        case "reset":
            if let c = current { store.reset(c.name); load(c) }
        case "appset":
            guard let key = arg("key"), let raw = arg("value"), let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            applyAppSetting(key, value)
            panelLoad()
        case "vol":
            guard let key = arg("key"), let raw = arg("value"), let v = Double(raw) else { return }
            mixer.refresh()
            let k = mixer.apps.first { $0.key.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }?.key ?? key
            mixer.setVolume(k, v / 100)
        case "dock":
            guard let key = arg("key"), let raw = arg("value"), let data = raw.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return }
            dock.set(key, value)
        default:
            break
        }
    }

    // MARK: System wallpaper (menu bar tint)
    // macOS tints the menu bar (and the show-desktop view) from the *system* wallpaper, not from our
    // window. "match" hands it a snapshot of the running scene (optionally darkened), "color" a solid
    // color, "off" leaves the system wallpaper alone. The original is remembered and put back on quit.

    var menuBarMode: String { settings.string("menuBarMode") }

    @objc func syncNow() { if menuBarMode != "off" { syncSystemWallpaper() } }

    func scheduleWallpaperSync(after delay: TimeInterval = 2.5) {
        syncWork?.cancel()
        guard menuBarMode != "off" else { return }
        let work = DispatchWorkItem { [weak self] in self?.syncSystemWallpaper() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Optional periodic re-snapshot so the tint follows an animated or slideshow scene.
    func restartRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        let every = settings.double("menuBarRefresh")
        guard menuBarMode == "match", every > 0 else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) { [weak self] _ in self?.syncSystemWallpaper() }
    }

    var syncDir: URL { appSupport.appendingPathComponent("system-wallpaper", isDirectory: true) }

    /// `force` takes the snapshot even though the wallpaper is (about to be) hidden: the frame the lock
    /// screen shows.
    func syncSystemWallpaper(force: Bool = false) {
        guard force || !power.forcedPause else { if !power.userPaused { scheduleWallpaperSync() }; return }
        let mode = menuBarMode
        guard mode != "off" else { return }
        try? fm.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let screens = NSScreen.screens
        let dim = CGFloat(settings.double("menuBarDim"))
        for w in windows {
            guard screens.indices.contains(w.screenIndex) else { continue }
            let screen = screens[w.screenIndex]
            rememberOriginalWallpaper(for: screen, index: w.screenIndex)
            if mode == "color" {
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                let color = NSColor(hex: settings.string("menuBarColor")) ?? .black
                draw(into: rep) { r in color.setFill(); r.fill() }
                setSystemWallpaper(rep, for: screen, index: w.screenIndex)
                continue
            }
            w.webView.takeSnapshot(with: nil) { [weak self] image, _ in
                guard let self = self, let tiff = image?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                if dim > 0 { self.draw(into: rep) { r in NSColor.black.withAlphaComponent(dim).setFill(); r.fill(using: .sourceOver) } }
                self.setSystemWallpaper(rep, for: screen, index: w.screenIndex)
            }
        }
    }

    func draw(into rep: NSBitmapImageRep, _ body: (NSRect) -> Void) {
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        body(NSRect(origin: .zero, size: rep.size))
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    func setSystemWallpaper(_ rep: NSBitmapImageRep, for screen: NSScreen, index: Int) {
        guard let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        // A fresh file name each time; macOS does not re-read a wallpaper whose path is unchanged.
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = syncDir.appendingPathComponent("screen\(index)-\(stamp).jpg")
        do {
            try jpg.write(to: url)
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        } catch { return }
        let old = (try? fm.contentsOfDirectory(at: syncDir, includingPropertiesForKeys: nil)) ?? []
        for f in old where f.lastPathComponent.hasPrefix("screen\(index)-") && f != url {
            try? fm.removeItem(at: f)
        }
    }

    func rememberOriginalWallpaper(for screen: NSScreen, index: Int) {
        let key = "originalWallpaper\(index)"
        guard defaults.string(forKey: key) == nil,
              let current = NSWorkspace.shared.desktopImageURL(for: screen),
              !current.path.hasPrefix(syncDir.path) else { return }
        defaults.set(current.path, forKey: key)
    }

    @objc func restoreOriginalWallpaper() {
        syncWork?.cancel()
        for (i, screen) in NSScreen.screens.enumerated() {
            let key = "originalWallpaper\(i)"
            guard let path = defaults.string(forKey: key), fm.fileExists(atPath: path) else { continue }
            try? NSWorkspace.shared.setDesktopImageURL(URL(fileURLWithPath: path), for: screen, options: [:])
        }
    }

    // MARK: Snapshots

    /// Saves to ~/Pictures/Ltw Wallpaper (Desktop would need a privacy permission).
    @objc func saveSnapshot() {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let dir = fm.urls(for: .picturesDirectory, in: .userDomainMask)[0].appendingPathComponent("Ltw Wallpaper", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        snapshot(to: dir.appendingPathComponent("LtwWallpaper \(f.string(from: Date())).png"))
    }

    func snapshot(to url: URL) {
        guard let webView = windows.first?.webView else { return }
        webView.takeSnapshot(with: nil) { image, _ in
            guard let image = image, let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: url)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
