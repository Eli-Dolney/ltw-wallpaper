import Cocoa
import Carbon.HIToolbox

// MARK: - Global hotkeys (Carbon; no accessibility permission needed)

final class HotKeys {
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var actions: [UInt32: () -> Void] = [:]
    private var releases: [UInt32: () -> Void] = [:]

    init() {
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event = event, let userData = userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let me = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) { me.releases[id.id]?() } else { me.actions[id.id]?() }
            return noErr
        }, 2, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    /// `modifiers` are Carbon flags (controlKey, optionKey, cmdKey, shiftKey). `released` fires when the
    /// combination is let go (hold-to-use shortcuts such as the window wheel).
    func register(id: UInt32, keyCode: UInt32, modifiers: UInt32, released: (() -> Void)? = nil, _ action: @escaping () -> Void) {
        var ref: EventHotKeyRef?
        let hk = EventHotKeyID(signature: OSType(0x4C545721), id: id)   // 'LTW!'
        if RegisterEventHotKey(keyCode, modifiers, hk, GetApplicationEventTarget(), 0, &ref) == noErr, let r = ref {
            refs.append(r)
            actions[id] = action
            releases[id] = released
        }
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        actions = [:]
        releases = [:]
    }
}

// MARK: - Small system actions for the "System" submenu

enum SystemActions {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = nil; p.standardError = nil
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static var desktopIconsHidden: Bool {
        (UserDefaults(suiteName: "com.apple.finder")?.object(forKey: "CreateDesktop") as? Bool) == false
    }

    /// Hides or shows the Finder's desktop icons (Finder restarts; its windows reopen).
    static func setDesktopIconsHidden(_ hidden: Bool) {
        run("/usr/bin/defaults", ["write", "com.apple.finder", "CreateDesktop", "-bool", hidden ? "false" : "true"])
        run("/usr/bin/killall", ["Finder"])
    }

    /// Asks System Events to flip the appearance (macOS asks once to allow controlling System Events).
    static func toggleDarkMode() {
        run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"])
    }

    static func sleepDisplay() { run("/usr/bin/pmset", ["displaysleepnow"]) }

    static func startScreenSaver() { run("/usr/bin/open", ["-a", "ScreenSaverEngine"]) }
}

// MARK: - Settings export / import

enum SettingsBundle {
    static let appKeys = Array(AppSettings.defaults.keys).filter { $0 != "loginItem" } + ["mixerLevels", "mixerMuted", "lastScene"]

    static func export(store: SettingsStore, scenes: [Scene]) -> [String: Any] {
        var app: [String: Any] = [:]
        for k in appKeys { if let v = UserDefaults.standard.object(forKey: k) { app[k] = v } }
        var sceneSettings: [String: Any] = [:]
        for s in scenes {
            let d = store.load(s.name)
            if !d.isEmpty { sceneSettings[s.name] = d }
        }
        return ["ltwWallpaper": 1, "exported": ISO8601DateFormatter().string(from: Date()), "app": app, "scenes": sceneSettings]
    }

    static func apply(_ bundle: [String: Any], store: SettingsStore) -> Bool {
        guard bundle["ltwWallpaper"] != nil else { return false }
        if let app = bundle["app"] as? [String: Any] {
            for (k, v) in app where appKeys.contains(k) { UserDefaults.standard.set(v, forKey: k) }
        }
        if let scenes = bundle["scenes"] as? [String: Any] {
            for (name, v) in scenes {
                guard let d = v as? [String: Any] else { continue }
                store.reset(name)
                for (k, val) in d { store.set(name, key: k, value: val) }
            }
        }
        return true
    }
}
