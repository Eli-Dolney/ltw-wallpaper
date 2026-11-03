import Cocoa
import ServiceManagement

/// App-wide settings (menu bar icon, menu bar tint, battery saver, login item). Stored in UserDefaults
/// and shown on the "App" tab of the Customize window, rendered from `schema` like a scene's SCHEMA.
final class AppSettings {
    let d = UserDefaults.standard

    static let symbols: [[String: String]] = [
        ["value": "sparkles.rectangle.stack", "label": "Sparkles stack"],
        ["value": "sparkles", "label": "Sparkles"],
        ["value": "wand.and.stars", "label": "Wand"],
        ["value": "photo.on.rectangle", "label": "Photo"],
        ["value": "paintpalette", "label": "Palette"],
        ["value": "moon.stars", "label": "Moon & stars"],
        ["value": "circle.hexagongrid", "label": "Hex grid"],
        ["value": "cube", "label": "Cube"],
        ["value": "hand.raised", "label": "Hand"],
        ["value": "flame", "label": "Flame"],
        ["value": "drop", "label": "Drop"],
        ["value": "bolt", "label": "Bolt"],
        ["value": "leaf", "label": "Leaf"],
        ["value": "star", "label": "Star"],
        ["value": "display", "label": "Display"],
        ["value": "rectangle.on.rectangle", "label": "Rectangles"],
    ]

    static let defaults: [String: Any] = [
        "menuIcon": "sparkles.rectangle.stack",
        "menuIconEmoji": "",
        "menuIconImage": "",
        "menuIconColor": false,
        "menuShowScene": false,
        "menuBarMode": "match",
        "menuBarColor": "#1a1a1a",
        "menuBarDim": 0.0,
        "menuBarRefresh": 0.0,
        "lockScreenFrame": true,
        "batterySaver": "auto",
        "keepAwake": false,
        "menuReadout": "none",
        "rotateEvery": 0.0,
        "rotateShuffle": false,
        "audioReactive": true,
        "hotkeys": true,
        "wheel": true,
        "wheelSize": 160.0,
        "wheelDim": 0.25,
        "wheelGap": 0.0,
        "switcher": true,
        "switcherMode": "apps",
        "switcherMax": 8.0,
        "switcherLabels": true,
        "switcherPinned": [String](),
        "switcherHidden": [String](),
        "switcherPinnedOnly": false,
        "switcherSort": "recent",
        "statsInMenu": true,
        "statsInterval": 2.0,
        "statsTop": true,
        "loginItem": false,
        "dockIcon": false,
        "panelStyle": "translucent",
        "panelOpacity": 1.0,
        "panelTheme": "dark",
        "panelAccent": "#d97757",
        "panelButtons": true,
        "panelOnTop": true,
        "panelAutoHide": false,
    ]

    // One constant per group: a single literal this size is too much for the type checker.
    private static let group1: [String: Any] = ["label": "Menu bar icon", "fields": [
            ["key": "menuIcon", "type": "select", "label": "Symbol", "options": symbols],
            ["key": "menuIconEmoji", "type": "text", "label": "Emoji or text instead", "placeholder": "e.g. ✨ (leave empty for the symbol)"],
            ["key": "menuIconImage", "type": "file", "label": "Custom image", "placeholder": "PNG with transparency"],
            ["key": "menuIconColor", "type": "toggle", "label": "Keep image colors", "showIf": ["key": "menuIconImage", "not": ""]],
            ["key": "menuShowScene", "type": "toggle", "label": "Show scene name"],
        ]]

    private static let group2: [String: Any] = ["label": "Menu bar tint", "fields": [
            ["key": "menuBarMode", "type": "select", "label": "Tint from", "options": [
                ["value": "match", "label": "Snapshot of the scene"],
                ["value": "color", "label": "A solid color"],
                ["value": "off", "label": "Off (keep system wallpaper)"],
            ]],
            ["key": "menuBarColor", "type": "color", "label": "Color", "showIf": ["key": "menuBarMode", "is": "color"]],
            ["key": "menuBarDim", "type": "range", "label": "Darken", "min": 0, "max": 0.9, "step": 0.05, "showIf": ["key": "menuBarMode", "is": "match"]],
            ["key": "menuBarRefresh", "type": "range", "label": "Refresh every (s)", "min": 0, "max": 300, "step": 5, "showIf": ["key": "menuBarMode", "is": "match"]],
            ["key": "lockScreenFrame", "type": "toggle", "label": "Lock screen shows the last frame", "showIf": ["key": "menuBarMode", "is": "match"]],
            ["key": "_lock", "type": "note", "label": "macOS can only show a still picture on the lock screen. This grabs the frame on screen the moment you lock or the display sleeps.", "showIf": ["key": "lockScreenFrame", "is": true]],
        ]]

    private static let group3: [String: Any] = ["label": "Power", "fields": [
            ["key": "batterySaver", "type": "select", "label": "Battery saver", "options": [
                ["value": "auto", "label": "Auto (follows Low Power Mode)"],
                ["value": "on", "label": "On (15 fps cap)"],
                ["value": "off", "label": "Off"],
            ]],
            ["key": "keepAwake", "type": "toggle", "label": "Keep Mac awake (caffeinate)"],
        ]]

    private static let group4: [String: Any] = ["label": "Scenes", "fields": [
            ["key": "rotateEvery", "type": "select", "label": "Change scene automatically", "options": [
                ["value": 0, "label": "Never"], ["value": 15, "label": "Every 15 minutes"], ["value": 30, "label": "Every 30 minutes"],
                ["value": 60, "label": "Every hour"], ["value": 180, "label": "Every 3 hours"], ["value": 1440, "label": "Every day"]]],
            ["key": "rotateShuffle", "type": "toggle", "label": "Shuffle", "showIf": ["key": "rotateEvery", "not": 0]],
            ["key": "audioReactive", "type": "toggle", "label": "Audio-reactive scenes listen to system sound"],
            ["key": "_audio", "type": "note", "label": "Visualizer, Warp, Liquid and Synthwave move to whatever is playing. Needs “System Audio Recording”; otherwise they run a demo groove.", "showIf": ["key": "audioReactive", "is": true]],
        ]]

    private static let group5: [String: Any] = ["label": "Shortcuts", "fields": [
            ["key": "hotkeys", "type": "toggle", "label": "Global shortcuts"],
            ["key": "_hk", "type": "note", "label": "⌃⌥N next scene · ⌃⌥P pause animation · ⌃⌥K keep awake · ⌃⌥M mixer · ⌃⌥C customize · ⌃⌥W window wheel · ⌃⌥Tab app wheel",
             "showIf": ["key": "hotkeys", "is": true]],
        ]]

    private static let group6: [String: Any] = ["label": "Window wheel", "fields": [
            ["key": "wheel", "type": "toggle", "label": "Window wheel (⌃⌥W)"],
            ["key": "_wheel", "type": "note", "label": "Hold ⌃⌥W, move the mouse toward a layout, let go: the front window snaps there. Tap ⌃⌥W to keep the wheel open and click. Needs Accessibility access once.",
             "showIf": ["key": "wheel", "is": true]],
            ["key": "wheelSize", "type": "range", "label": "Size", "min": 100, "max": 260, "step": 10, "showIf": ["key": "wheel", "is": true]],
            ["key": "wheelDim", "type": "range", "label": "Dim the screen behind", "min": 0, "max": 0.6, "step": 0.05, "showIf": ["key": "wheel", "is": true]],
            ["key": "wheelGap", "type": "range", "label": "Gap between windows (px)", "min": 0, "max": 40, "step": 2, "showIf": ["key": "wheel", "is": true]],
        ]]

    private static let group7: [String: Any] = ["label": "App wheel", "fields": [
            ["key": "switcher", "type": "toggle", "label": "App wheel (⌃⌥Tab)"],
            ["key": "_switcher", "type": "note", "label": "A radial ⌘Tab: hold ⌃⌥Tab, move toward an app, let go. The hub jumps back to the previous app. Tap to keep it open and click.",
             "showIf": ["key": "switcher", "is": true]],
            ["key": "switcherMode", "type": "select", "label": "Show", "options": [
                ["value": "apps", "label": "Apps (most recent first)"],
                ["value": "windows", "label": "Windows (needs Accessibility)"],
            ], "showIf": ["key": "switcher", "is": true]],
            ["key": "switcherMax", "type": "range", "label": "Slots on the wheel", "min": 3, "max": 12, "step": 1, "showIf": ["key": "switcher", "is": true]],
            ["key": "switcherSort", "type": "select", "label": "Order", "options": [
                ["value": "recent", "label": "Most recent first"],
                ["value": "name", "label": "Alphabetical"],
            ], "showIf": ["key": "switcher", "is": true]],
            ["key": "switcherLabels", "type": "toggle", "label": "Names around the ring", "showIf": ["key": "switcher", "is": true]],
            ["key": "_wheelShared", "type": "note", "label": "Size, dim and the accent color are shared with the window wheel above.", "showIf": ["key": "switcher", "is": true]],
        ]]

    private static let group8: [String: Any] = ["label": "Apps on the wheel", "fields": [
            ["key": "_pins", "type": "note", "label": "Pin an app and it keeps its place on the wheel, running or not (picking it launches it). Hide an app and it never shows. Pins come first, in this order."],
            ["key": "switcherApps", "type": "apps", "label": "Apps"],
            ["key": "switcherPinnedOnly", "type": "toggle", "label": "Only pinned apps (a fixed launcher wheel)"],
            ["key": "switcherPinned", "type": "list", "label": "Pinned (bundle id or name, one per line, wheel order)", "rows": 3],
            ["key": "switcherHidden", "type": "list", "label": "Hidden", "rows": 2],
            ["key": "_pinsCli", "type": "note", "label": "Shell: ./ltw apps pin Safari · ./ltw apps unpin Safari · ./ltw apps hide Music · ./ltw apps show Music · ./ltw apps list"],
        ]]

    private static let group9: [String: Any] = ["label": "Monitor", "fields": [
            ["key": "statsInMenu", "type": "toggle", "label": "Stats at the top of the menu"],
            ["key": "menuReadout", "type": "select", "label": "Next to the menu bar icon", "options": [
                ["value": "none", "label": "Nothing"], ["value": "cpu", "label": "CPU %"], ["value": "gpu", "label": "GPU %"],
                ["value": "cpu+gpu", "label": "CPU + GPU"], ["value": "mem", "label": "Memory used"], ["value": "cpu+mem", "label": "CPU + memory"],
                ["value": "battery", "label": "Battery %"], ["value": "battery+time", "label": "Battery % + time left"], ["value": "watts", "label": "Power draw (W)"],
                ["value": "net", "label": "Download speed"], ["value": "net2", "label": "Download + upload"], ["value": "disk", "label": "Disk read / write"],
                ["value": "load", "label": "Load average"], ["value": "temp", "label": "Battery temperature"],
            ]],
            ["key": "statsInterval", "type": "select", "label": "Update every", "options": [
                ["value": 1, "label": "1 second"], ["value": 2, "label": "2 seconds"], ["value": 5, "label": "5 seconds"], ["value": 10, "label": "10 seconds"]]],
            ["key": "statsTop", "type": "toggle", "label": "Top processes in the Stats tab"],
            ["key": "_statsScene", "type": "note", "label": "The Monitor scene puts all of this on the wallpaper; any scene can read LTW.stats."],
        ]]

    private static let group10: [String: Any] = ["label": "Customize window", "fields": [
            ["key": "panelStyle", "type": "select", "label": "Background", "options": [
                ["value": "translucent", "label": "Translucent blur"],
                ["value": "solid", "label": "Solid"],
            ]],
            ["key": "panelOpacity", "type": "range", "label": "Opacity", "min": 0.4, "max": 1, "step": 0.05],
            ["key": "panelTheme", "type": "select", "label": "Theme", "options": [
                ["value": "dark", "label": "Dark"],
                ["value": "light", "label": "Light"],
                ["value": "system", "label": "Match system"],
            ]],
            ["key": "panelAccent", "type": "color", "label": "Accent"],
            ["key": "panelButtons", "type": "toggle", "label": "Window buttons"],
            ["key": "panelOnTop", "type": "toggle", "label": "Keep on top"],
            ["key": "panelAutoHide", "type": "toggle", "label": "Hide when I click elsewhere"],
        ]]

    private static let group11: [String: Any] = ["label": "Startup", "fields": [
            ["key": "loginItem", "type": "toggle", "label": "Open at login"],
            ["key": "dockIcon", "type": "toggle", "label": "Show in Dock"],
        ]]

    static let schema: [String: Any] = ["groups": [group1, group2, group3, group4, group5, group6, group7, group8, group9, group10, group11]]

    init() {
        // Older builds stored the tint as a Bool.
        if d.object(forKey: "menuBarMode") == nil, d.object(forKey: "syncSystemWallpaper") as? Bool == false {
            d.set("off", forKey: "menuBarMode")
        }
    }

    func string(_ k: String) -> String { d.object(forKey: k) as? String ?? (Self.defaults[k] as? String ?? "") }
    func double(_ k: String) -> Double { (d.object(forKey: k) as? NSNumber)?.doubleValue ?? (Self.defaults[k] as? Double ?? 0) }
    func bool(_ k: String) -> Bool { (d.object(forKey: k) as? NSNumber)?.boolValue ?? (Self.defaults[k] as? Bool ?? false) }

    var loginItem: Bool { SMAppService.mainApp.status == .enabled }

    /// Effective values, for the panel.
    var config: [String: Any] {
        var c = Self.defaults
        for k in c.keys { if let v = d.object(forKey: k) { c[k] = v } }
        c["loginItem"] = loginItem
        return c
    }

    func set(_ k: String, _ v: Any) {
        guard Self.defaults[k] != nil, k != "loginItem" else { return }
        d.set(v, forKey: k)
    }

    func list(_ k: String) -> [String] { (d.object(forKey: k) as? [String]) ?? (Self.defaults[k] as? [String] ?? []) }

    var switcherConfig: WindowManager.SwitcherConfig {
        WindowManager.SwitcherConfig(pinned: list("switcherPinned"), hidden: list("switcherHidden"),
                                     pinnedOnly: bool("switcherPinnedOnly"), sortByName: string("switcherSort") == "name")
    }

    /// Adds or removes an entry (bundle id or name) from one of the app-wheel lists. Returns the new state.
    @discardableResult
    func toggle(_ k: String, _ entry: String, on: Bool? = nil) -> Bool {
        var l = list(k)
        let has = l.contains { $0.caseInsensitiveCompare(entry) == .orderedSame }
        let want = on ?? !has
        if want, !has { l.append(entry) }
        if !want { l.removeAll { $0.caseInsensitiveCompare(entry) == .orderedSame } }
        d.set(l, forKey: k)
        return want
    }

    func reset() {
        for k in Self.defaults.keys where k != "loginItem" { d.removeObject(forKey: k) }
    }

    /// Registers or removes the app as a login item; the real state is read back from the system.
    func setLoginItem(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                  blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
