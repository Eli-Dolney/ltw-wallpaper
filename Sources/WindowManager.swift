import Cocoa
import ApplicationServices

/// The layouts the window wheel and the Window menu can apply to the frontmost window.
enum WindowLayout: String, CaseIterable {
    case maximize, topRight, right, bottomRight, bottom, bottomLeft, left, topLeft, top
    case center, nextDisplay, minimize, restore

    /// The eight wedges of the wheel, clockwise from the top. Their position on the wheel matches
    /// where the window ends up on the screen.
    static let wheel: [WindowLayout] = [.maximize, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left, .topLeft]

    var label: String {
        switch self {
        case .maximize: return "Fill Screen"
        case .left: return "Left Half"
        case .right: return "Right Half"
        case .top: return "Top Half"
        case .bottom: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .center: return "Center"
        case .nextDisplay: return "Next Display"
        case .minimize: return "Minimize"
        case .restore: return "Restore Size"
        }
    }

    /// Where the window lands, as fractions of the screen's visible area (x, y from the top-left, w, h).
    var fraction: CGRect? {
        switch self {
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .left: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .center: return CGRect(x: 0.15, y: 0.12, width: 0.7, height: 0.76)
        default: return nil
        }
    }
}

/// Moves and resizes other apps' windows, lists them, and switches between apps, through the
/// Accessibility API. Needs the user to allow Ltw Wallpaper under System Settings → Privacy &
/// Security → Accessibility.
final class WindowManager {
    struct Target {
        let window: AXUIElement
        let app: NSRunningApplication
    }

    /// One entry of the app switcher: an app, or one window of an app.
    struct SwitchItem {
        let app: NSRunningApplication
        let window: AXUIElement?
        let title: String
    }

    /// Frames before the last few layouts, so "Restore Size" can undo them.
    private var remembered: [(AXUIElement, CGRect)] = []
    /// Space to leave between tiled windows and the screen edges, in points.
    var gap: CGFloat = 0
    /// Apps in the order they were last activated, most recent first (our own app excluded).
    private(set) var recent: [NSRunningApplication] = []
    private var observer: NSObjectProtocol?

    init() {
        let me = ProcessInfo.processInfo.processIdentifier
        recent = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.processIdentifier != me }
        if let front = NSWorkspace.shared.frontmostApplication { noteActivated(front) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.noteActivated(app) }
        }
    }

    private func noteActivated(_ app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy == .regular else { return }
        recent.removeAll { $0.processIdentifier == app.processIdentifier || $0.isTerminated }
        recent.insert(app, at: 0)
    }

    static var trusted: Bool { AXIsProcessTrusted() }
    private static var prompted = false

    /// Shows the system prompt and opens the Accessibility pane, once per launch unless `force`
    /// (the "Allow Window Management…" menu item). The wheel itself just says "Allow Accessibility"
    /// in its hub after that.
    static func requestTrust(force: Bool = false) {
        guard force || !prompted else { return }
        prompted = true
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    /// The app the user is working in: the frontmost one, or, when that is Ltw Wallpaper itself
    /// (Customize window open, wheel panel just clicked), the app that was active before it.
    func userApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me, f.activationPolicy == .regular { return f }
        return recent.first { !$0.isTerminated }
    }

    /// The focused (or main, or first) window of the app the user is working in.
    func frontmost() -> Target? {
        guard let app = userApp() else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        for attr in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(ax, attr as CFString, &value) == .success, let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() {
                return Target(window: v as! AXUIElement, app: app)
            }
        }
        if let w = windows(of: app).first { return Target(window: w, app: app) }
        return nil
    }

    /// The app's windows (AX order: front to back).
    func windows(of app: NSRunningApplication) -> [AXUIElement] {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, kAXWindowsAttribute as CFString, &value) == .success, let list = value as? [AXUIElement] else { return [] }
        return list
    }

    func title(of window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    // MARK: App switcher

    /// Items for the app wheel: apps in recency order, or their windows. `max` caps the count.
    func switchItems(windows wantWindows: Bool, max: Int) -> [SwitchItem] {
        recent.removeAll { $0.isTerminated }
        let me = ProcessInfo.processInfo.processIdentifier
        // Apps that launched since we last looked (or before recency tracking saw them) go last.
        var apps = recent
        for a in NSWorkspace.shared.runningApplications where a.activationPolicy == .regular && a.processIdentifier != me
            && !apps.contains(where: { $0.processIdentifier == a.processIdentifier }) { apps.append(a) }
        var items: [SwitchItem] = []
        for app in apps {
            if wantWindows, WindowManager.trusted {
                for w in windows(of: app) {
                    let t = title(of: w)
                    guard !t.isEmpty else { continue }
                    items.append(SwitchItem(app: app, window: w, title: t))
                    if items.count >= max { return items }
                }
            } else {
                items.append(SwitchItem(app: app, window: nil, title: app.localizedName ?? "App"))
                if items.count >= max { return items }
            }
        }
        return items
    }

    /// Brings an app (or one of its windows) to the front.
    func activate(_ item: SwitchItem) {
        if item.app.isHidden { item.app.unhide() }
        if let w = item.window {
            if isMinimized(w) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        } else if WindowManager.trusted {
            // Every window minimized: bring one back so activating shows something.
            let ws = windows(of: item.app)
            if !ws.isEmpty, ws.allSatisfy({ isMinimized($0) }), let w = ws.first {
                AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
        }
        item.app.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: Geometry

    func frame(of window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let s = sizeRef else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    /// `rect` is in Accessibility coordinates: origin at the top-left of the main display, y down.
    @discardableResult
    func setFrame(_ window: AXUIElement, _ rect: CGRect) -> Bool {
        var pos = rect.origin, size = rect.size
        guard let p = AXValueCreate(.cgPoint, &pos), let s = AXValueCreate(.cgSize, &size) else { return false }
        // Size first so a window pinned to the bottom/right edge does not get pushed off-screen, then
        // position, then size again for apps that clamp the size to their minimum.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        let ok = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, p) == .success
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, s)
        return ok
    }

    /// Cocoa (y up from the bottom of the main display) → Accessibility (y down from its top).
    static func axRect(from cocoa: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: cocoa.minX, y: mainHeight - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    static func cocoaRect(from ax: CGRect) -> CGRect {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: ax.minX, y: mainHeight - ax.maxY, width: ax.width, height: ax.height)
    }

    /// The screen that holds most of the window (falls back to the one under the mouse).
    func screen(for window: AXUIElement) -> NSScreen? {
        if let f = frame(of: window) {
            let c = WindowManager.cocoaRect(from: f)
            let center = CGPoint(x: c.midX, y: c.midY)
            if let s = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return s }
            let mouse = NSEvent.mouseLocation
            if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) { return s }
        }
        return NSScreen.main
    }

    /// Applies a layout to the frontmost window. Returns false when there is nothing to act on.
    @discardableResult
    func apply(_ layout: WindowLayout, to target: Target? = nil) -> Bool {
        guard WindowManager.trusted else { WindowManager.requestTrust(); return false }
        guard let t = target ?? frontmost() else { return false }
        let w = t.window
        switch layout {
        case .minimize:
            return AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success
        case .restore:
            guard let i = remembered.lastIndex(where: { CFEqual($0.0, w) }) else { return false }
            let r = remembered.remove(at: i).1
            return setFrame(w, r)
        case .nextDisplay:
            let screens = NSScreen.screens
            guard screens.count > 1, let cur = screen(for: w), let i = screens.firstIndex(of: cur),
                  let f = frame(of: w) else { return false }
            let next = screens[(i + 1) % screens.count]
            let from = cur.visibleFrame, to = next.visibleFrame
            let c = WindowManager.cocoaRect(from: f)
            // Keep the window's relative position and relative size on the new display.
            let rx = (c.minX - from.minX) / max(from.width, 1), ry = (c.minY - from.minY) / max(from.height, 1)
            let rw = min(1, c.width / max(from.width, 1)), rh = min(1, c.height / max(from.height, 1))
            var dest = CGRect(x: to.minX + rx * to.width, y: to.minY + ry * to.height, width: rw * to.width, height: rh * to.height)
            dest.origin.x = min(max(dest.minX, to.minX), to.maxX - dest.width)
            dest.origin.y = min(max(dest.minY, to.minY), to.maxY - dest.height)
            remember(w)
            return setFrame(w, WindowManager.axRect(from: dest))
        default:
            guard let fr = layout.fraction, let s = screen(for: w) else { return false }
            let v = s.visibleFrame.insetBy(dx: gap, dy: gap)
            // Fractions are measured from the top-left; Cocoa's y runs up.
            let width = v.width * fr.width - (fr.width < 1 ? gap / 2 : 0)
            let height = v.height * fr.height - (fr.height < 1 ? gap / 2 : 0)
            let x = v.minX + v.width * fr.minX + (fr.minX > 0 ? gap / 2 : 0)
            let top = v.maxY - v.height * fr.minY - (fr.minY > 0 ? gap / 2 : 0)
            let dest = CGRect(x: x, y: top - height, width: width, height: height)
            remember(w)
            return setFrame(w, WindowManager.axRect(from: dest))
        }
    }

    private func remember(_ w: AXUIElement) {
        guard let f = frame(of: w) else { return }
        remembered.removeAll { CFEqual($0.0, w) }
        remembered.append((w, f))
        if remembered.count > 24 { remembered.removeFirst() }
    }
}
