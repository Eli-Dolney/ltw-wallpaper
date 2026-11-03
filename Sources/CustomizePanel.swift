import Cocoa
import WebKit

/// WKUserContentController retains its handlers; this proxy avoids a retain cycle with the app delegate.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(u, didReceive: m)
    }
}

/// The "Customize…" window: a small floating window showing scenes/_panel.html, which renders the
/// current scene's SCHEMA (and the app's own settings) as controls and posts changes back through the
/// "ltw" message handler. Its look (blur, opacity, theme, accent, window buttons) comes from AppSettings.
final class CustomizePanel: NSWindowController {
    let webView: WKWebView
    let effect = NSVisualEffectView()
    var autoHide = false
    private var resignObserver: NSObjectProtocol?

    init(handler: WKScriptMessageHandler, panelURL: URL, readAccess: URL) {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(WeakHandler(handler), name: "ltw")
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        let frame = NSRect(x: 0, y: 0, width: 380, height: 640)
        webView = WKWebView(frame: frame, configuration: cfg)
        let win = NSWindow(contentRect: frame,
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.title = "Customize"
        win.level = .floating
        win.isReleasedWhenClosed = false
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 300, height: 380)
        win.isMovableByWindowBackground = true
        win.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        let container = NSView(frame: frame)
        effect.frame = frame
        effect.autoresizingMask = [.width, .height]
        effect.blendingMode = .behindWindow
        effect.material = .sidebar
        effect.state = .active
        container.addSubview(effect)
        webView.frame = frame
        webView.autoresizingMask = [.width, .height]
        webView.setValue(false, forKey: "drawsBackground")   // let the blur (or the window color) show through
        webView.underPageBackgroundColor = .clear
        container.addSubview(webView)
        win.contentView = container
        win.setFrameAutosaveName("CustomizePanel")
        super.init(window: win)
        webView.loadFileURL(panelURL, allowingReadAccessTo: readAccess)
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: win, queue: .main) { [weak self] _ in
            guard let self = self, self.autoHide else { return }
            // Ignore focus moving to our own color panel or an open/save sheet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                if NSApp.isActive { return }   // focus went to our own color panel or a sheet
                log.notice("customize: hidden after focus moved to another app")
                self.window?.orderOut(nil)
            }
        }
    }

    /// Opens the window, or hides it when it is already in front (⌃⌥C and the menu item toggle).
    func toggle() {
        if window?.isVisible == true, window?.isKeyWindow == true { window?.orderOut(nil) } else { show() }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func send(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    /// Keys: panelStyle (translucent|solid), panelOpacity, panelTheme (dark|light), panelButtons, panelOnTop.
    func apply(look: [String: Any]) {
        guard let win = window else { return }
        let light = look["panelTheme"] as? String == "light"
        win.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        let translucent = (look["panelStyle"] as? String ?? "translucent") == "translucent"
        effect.isHidden = !translucent
        win.isOpaque = !translucent
        win.backgroundColor = translucent ? .clear : (light ? NSColor(calibratedWhite: 0.95, alpha: 1) : NSColor(calibratedWhite: 0.09, alpha: 1))
        win.alphaValue = CGFloat((look["panelOpacity"] as? NSNumber)?.doubleValue ?? 1)
        let buttons = (look["panelButtons"] as? NSNumber)?.boolValue ?? true
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            win.standardWindowButton(b)?.isHidden = !buttons
        }
        win.level = ((look["panelOnTop"] as? NSNumber)?.boolValue ?? true) ? .floating : .normal
        autoHide = (look["panelAutoHide"] as? NSNumber)?.boolValue ?? false
        win.invalidateShadow()
    }
}
