import Cocoa
import os

/// The macOS Dock's own preferences (com.apple.dock), shown on the "Dock" tab of Customize. Values are read
/// from the Dock's defaults domain and written back with /usr/bin/defaults; the Dock is restarted to pick
/// them up (debounced, since a restart makes it blink). Nothing here touches the app's own settings.
/// Note: hiding the Dock's background tray is not possible through preferences on current macOS.
final class DockSettings {
    private let suite = UserDefaults(suiteName: "com.apple.dock")
    private var restartWork: DispatchWorkItem?

    /// macOS defaults, used for the ↺ markers and for Reset.
    static let defaults: [String: Any] = [
        "tilesize": 48, "magnification": false, "largesize": 96, "orientation": "bottom",
        "autohide": false, "autohide-delay": 0.5, "autohide-time-modifier": 0.5,
        "mineffect": "genie", "minimize-to-application": false, "show-recents": true,
        "static-only": false, "showhidden": false, "show-process-indicators": true,
        "launchanim": true, "single-app": false, "scroll-to-open": false,
    ]

    static let schema: [String: Any] = ["groups": [
        ["label": "Size & position", "fields": [
            ["key": "tilesize", "type": "range", "label": "Icon size", "min": 16, "max": 128, "step": 1],
            ["key": "magnification", "type": "toggle", "label": "Magnify on hover"],
            ["key": "largesize", "type": "range", "label": "Magnified size", "min": 16, "max": 128, "step": 1, "showIf": ["key": "magnification", "is": true]],
            ["key": "orientation", "type": "select", "label": "Position", "options": [
                ["value": "bottom", "label": "Bottom"], ["value": "left", "label": "Left"], ["value": "right", "label": "Right"]]],
        ]],
        ["label": "Hiding", "fields": [
            ["key": "autohide", "type": "toggle", "label": "Auto-hide"],
            ["key": "autohide-delay", "type": "range", "label": "Show delay (s)", "min": 0, "max": 2, "step": 0.05, "showIf": ["key": "autohide", "is": true]],
            ["key": "autohide-time-modifier", "type": "range", "label": "Slide time (s)", "min": 0, "max": 2, "step": 0.05, "showIf": ["key": "autohide", "is": true]],
        ]],
        ["label": "Behavior", "fields": [
            ["key": "mineffect", "type": "select", "label": "Minimize effect", "options": [
                ["value": "genie", "label": "Genie"], ["value": "scale", "label": "Scale"], ["value": "suck", "label": "Suck (hidden)"]]],
            ["key": "minimize-to-application", "type": "toggle", "label": "Minimize into app icon"],
            ["key": "show-recents", "type": "toggle", "label": "Show recent apps"],
            ["key": "static-only", "type": "toggle", "label": "Only running apps"],
            ["key": "showhidden", "type": "toggle", "label": "Dim hidden apps"],
            ["key": "show-process-indicators", "type": "toggle", "label": "Running dots"],
            ["key": "launchanim", "type": "toggle", "label": "Bounce on launch"],
            ["key": "scroll-to-open", "type": "toggle", "label": "Scroll icon to show windows"],
            ["key": "single-app", "type": "toggle", "label": "Single-app mode (hides others)"],
        ]],
        ["label": "Spacers", "fields": [
            ["key": "spacer", "type": "action", "label": "Add a spacer", "button": "Add"],
            ["key": "small-spacer", "type": "action", "label": "Add a half-width spacer", "button": "Add"],
            ["key": "restart", "type": "action", "label": "Restart the Dock now", "button": "Restart"],
        ]],
    ]]

    var config: [String: Any] {
        var c = Self.defaults
        for k in c.keys { if let v = suite?.object(forKey: k) { c[k] = v } }
        return c
    }

    /// Writes one key with the type its field implies, then schedules a Dock restart.
    func set(_ key: String, _ value: Any) {
        guard let def = Self.defaults[key] else { return }
        var args = ["write", "com.apple.dock", key]
        switch def {
        case is Bool:   args += ["-bool", ((value as? NSNumber)?.boolValue ?? false) ? "true" : "false"]
        case is Int:    args += ["-int", String(Int((value as? NSNumber)?.doubleValue ?? 0))]
        case is Double: args += ["-float", String((value as? NSNumber)?.doubleValue ?? 0)]
        default:        args += ["-string", value as? String ?? ""]
        }
        run("/usr/bin/defaults", args)
        scheduleRestart()
    }

    func action(_ name: String) {
        switch name {
        case "spacer":
            run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", "{tile-type=\"spacer-tile\";}"])
            scheduleRestart()
        case "small-spacer":
            run("/usr/bin/defaults", ["write", "com.apple.dock", "persistent-apps", "-array-add", "{tile-type=\"small-spacer-tile\";}"])
            scheduleRestart()
        case "restart":
            restart()
        default:
            break
        }
    }

    /// Removes every key this tab manages (apps and spacers stay) and restarts the Dock.
    func reset() {
        for k in Self.defaults.keys { run("/usr/bin/defaults", ["delete", "com.apple.dock", k]) }
        scheduleRestart()
    }

    func scheduleRestart() {
        restartWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.restart() }
        restartWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: w)
    }

    func restart() {
        restartWork?.cancel()
        run("/usr/bin/killall", ["Dock"])
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = nil
        p.standardError = nil
        do { try p.run() } catch { log.notice("dock: \(path) failed: \(error.localizedDescription)"); return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
