import Cocoa

/// A small HUD line ("Pinned Safari", "Needs Accessibility") that fades in near the bottom of the
/// screen the cursor is on and disappears by itself. Never takes focus.
final class Toast {
    static let shared = Toast()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTimer: Timer?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.layer?.masksToBounds = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        box.addSubview(icon)
        box.addSubview(label)
        panel.contentView = box
        panel.alphaValue = 0
    }

    /// `symbol` is an SF Symbol name; `accent` tints it.
    static func show(_ text: String, symbol: String? = nil, accent: NSColor? = nil, seconds: TimeInterval = 1.6) {
        shared.present(text, symbol: symbol, accent: accent, seconds: seconds)
    }

    private func present(_ text: String, symbol: String?, accent: NSColor?, seconds: TimeInterval) {
        label.stringValue = text
        let img = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        icon.image = img
        icon.contentTintColor = accent ?? .white
        let textW = min(520, label.attributedStringValue.size().width + 2)
        let iconW: CGFloat = img == nil ? 0 : 26
        let w = textW + iconW + 32, h: CGFloat = 40
        icon.frame = NSRect(x: 16, y: (h - 18) / 2, width: img == nil ? 0 : 18, height: 18)
        label.frame = NSRect(x: 16 + iconW, y: (h - 17) / 2, width: textW, height: 17)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let v = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: v.midX - w / 2, y: v.minY + 64, width: w, height: h), display: true)
        panel.contentView?.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hideTimer?.invalidate()
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        // A Timer in the common run-loop modes keeps firing while a modal alert is up; a main-queue
        // dispatch would wait for the alert to close.
        let t = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in self?.fadeOut() }
        RunLoop.main.add(t, forMode: .common)
        hideTimer = t
    }

    /// Hides the HUD now (before a dialog takes over, for instance).
    static func hide() { shared.hideTimer?.invalidate(); shared.fadeOut() }

    private func fadeOut() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.3; panel.animator().alphaValue = 0 },
                                            completionHandler: { [panel] in if panel.alphaValue == 0 { panel.orderOut(nil) } })
    }
}

// MARK: - Update check (GitHub releases, then tags)

enum Updater {
    static let repo = "Eli-Dolney/ltw-wallpaper"
    static var page: URL { URL(string: "https://github.com/\(repo)/releases")! }

    static var installedVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Compares dotted version strings numerically ("0.10" > "0.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.filter(\.isNumber)) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Calls back on the main queue with the latest published version (without a leading "v"), or an error text.
    static func latest(_ done: @escaping (Result<String, Error>) -> Void) {
        func finish(_ r: Result<String, Error>) { DispatchQueue.main.async { done(r) } }
        func fetch(_ path: String, _ handle: @escaping (Any?) -> Void) {
            var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/\(path)")!)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.timeoutInterval = 10
            URLSession.shared.dataTask(with: req) { data, _, err in
                if let err = err { finish(.failure(err)); return }
                handle(data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            }.resume()
        }
        fetch("releases/latest") { obj in
            if let d = obj as? [String: Any], let tag = d["tag_name"] as? String { finish(.success(clean(tag))); return }
            fetch("tags") { obj in
                let tags = (obj as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
                let best = tags.map(clean).max { isNewer($1, than: $0) }
                finish(.success(best ?? installedVersion))
            }
        }
    }

    private static func clean(_ tag: String) -> String { tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag }
}

// MARK: - Diagnostics report (Advanced → Copy Diagnostics)

enum Diagnostics {
    static func report(scene: String, settings: AppSettings, trusted: Bool, displays: Int, extra: [String: String] = [:]) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var model = "unknown"
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var buf = [CChar](repeating: 0, count: size)
            if sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 { model = String(cString: buf) }
        }
        var lines = [
            "Ltw Wallpaper \(Updater.installedVersion)",
            "macOS \(os) on \(model), \(ProcessInfo.processInfo.activeProcessorCount) cores, \(SystemStats.bytes(Double(ProcessInfo.processInfo.physicalMemory))) RAM",
            "App: \(Bundle.main.bundlePath)",
            "Scene: \(scene) on \(displays) display(s)",
            "Accessibility: \(trusted ? "granted" : "not granted")",
            "Low Power Mode: \(ProcessInfo.processInfo.isLowPowerModeEnabled)",
        ]
        for (k, v) in extra.sorted(by: { $0.key < $1.key }) { lines.append("\(k): \(v)") }
        lines.append("")
        lines.append("Settings:")
        for (k, v) in settings.config.sorted(by: { $0.key < $1.key }) where !"\(v)".isEmpty {
            if let d = AppSettings.defaults[k], "\(d)" == "\(v)" { continue }   // only what differs from the defaults
            lines.append("  \(k) = \(v)")
        }
        lines.append("")
        lines.append("Log: /usr/bin/log show --last 10m --predicate 'subsystem == \"com.ltw.wallpaper\"' --style compact")
        return lines.joined(separator: "\n")
    }
}
