import Cocoa

/// A GTA-style weapon wheel for windows. Hold the hotkey: the wheel opens around the cursor, moving
/// toward a wedge highlights it, letting go applies that layout to the frontmost window. Tapping the
/// hotkey keeps the wheel open so you can click a wedge (or press Esc / click outside to cancel).
final class RadialMenu {
    struct Look {
        var accent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        var radius: CGFloat = 160
        var dim: CGFloat = 0.25
    }

    var look = Look()
    var onSelect: ((WindowLayout, WindowManager.Target?) -> Void)?
    private(set) var isShown = false
    private var sticky = false
    private var movedFar = false
    private let panel: NSPanel
    private let view: WheelView
    private var target: WindowManager.Target?
    private let manager: WindowManager

    init(manager: WindowManager) {
        self.manager = manager
        view = WheelView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        panel = NSPanel(contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.contentView = view
        view.onHover = { [weak self] in self?.hoverChanged() }
        view.onClick = { [weak self] in self?.clicked() }
        view.onCancel = { [weak self] in self?.hide() }
    }

    /// Hotkey pressed (hold mode) or the menu item / CLI (sticky).
    func show(sticky: Bool) {
        if isShown { if sticky { hide() }; return }
        target = manager.frontmost()
        if !WindowManager.trusted { WindowManager.requestTrust() }
        self.sticky = sticky
        movedFar = false
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        panel.setFrame(screen.frame, display: false)
        // Keep the whole wheel on screen, with a margin for the center label.
        let r = look.radius + 24
        let v = screen.visibleFrame
        var center = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        center.x = min(max(center.x, v.minX - screen.frame.minX + r), v.maxX - screen.frame.minX - r)
        center.y = min(max(center.y, v.minY - screen.frame.minY + r), v.maxY - screen.frame.minY - r)
        view.configure(center: center, radius: look.radius, accent: look.accent, dim: look.dim,
                       appIcon: target?.app.icon, appName: target?.app.localizedName ?? "No window",
                       trusted: WindowManager.trusted)
        view.highlight = nil
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        isShown = true
        view.animateIn()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        // Start the highlight from the current cursor position.
        view.updateHover(panelPoint: panel.convertPoint(fromScreen: mouse))
        log.notice("wheel: shown (\(sticky ? "sticky" : "hold", privacy: .public)) for \(self.target?.app.localizedName ?? "nothing", privacy: .public)")
    }

    /// Hotkey released: apply the highlighted layout, or stay open when it was just a tap.
    func released() {
        guard isShown, !sticky else { return }
        if let h = view.highlight { select(h) } else { sticky = true; view.sticky = true }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; panel.animator().alphaValue = 0 },
                                            completionHandler: { [panel] in if !self.isShown { panel.orderOut(nil) } })
    }

    private func hoverChanged() {
        if view.highlight != nil { movedFar = true }
    }

    private func clicked() {
        if let h = view.highlight { select(h) } else { hide() }
    }

    private func select(_ layout: WindowLayout) {
        let t = target
        hide()
        onSelect?(layout, t)
    }
}

/// Draws the wheel: a dim backdrop, eight wedges with mini layout glyphs, and a center disc with the
/// app icon and the highlighted action's name.
final class WheelView: NSView {
    var onHover: (() -> Void)?
    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var sticky = false
    var highlight: WindowLayout? { didSet { if highlight != oldValue { needsDisplay = true; onHover?() } } }
    private var center = CGPoint.zero
    private var radius: CGFloat = 160
    private var accent = NSColor.orange
    private var dim: CGFloat = 0.25
    private var appIcon: NSImage?
    private var appName = ""
    private var trusted = true
    private var scale: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    func configure(center: CGPoint, radius: CGFloat, accent: NSColor, dim: CGFloat, appIcon: NSImage?, appName: String, trusted: Bool) {
        self.center = center; self.radius = radius; self.accent = accent; self.dim = dim
        self.appIcon = appIcon; self.appName = appName; self.trusted = trusted
        sticky = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(dim).cgColor
        needsDisplay = true
    }

    func animateIn() {
        scale = 0.82
        let start = CACurrentMediaTime()
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self = self else { t.invalidate(); return }
            let p = min(1, (CACurrentMediaTime() - start) / 0.16)
            let e = 1 - pow(1 - p, 3)
            self.scale = 0.82 + 0.18 * CGFloat(e)
            self.needsDisplay = true
            if p >= 1 { t.invalidate() }
        }
    }

    // MARK: Input

    override func mouseMoved(with event: NSEvent) { updateHover(panelPoint: event.locationInWindow) }
    override func mouseDragged(with event: NSEvent) { updateHover(panelPoint: event.locationInWindow) }
    override func mouseDown(with event: NSEvent) { updateHover(panelPoint: event.locationInWindow); onClick?() }
    override func rightMouseDown(with event: NSEvent) { onCancel?() }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { onCancel?() } }   // Esc

    func updateHover(panelPoint p: CGPoint) {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = sqrt(dx * dx + dy * dy)
        let inner = radius * 0.42
        if d < inner * 0.9 {
            // Inside the hub: "Center" once the cursor has clearly moved in, nothing in the dead zone.
            highlight = (d < radius * 0.12 && !sticky) ? nil : .center
        } else if d < radius * 1.35 || !sticky {
            // Clockwise from the top; a wedge spans 45° centered on its direction.
            var a = atan2(dx, dy)                    // 0 = up, π/2 = right
            if a < 0 { a += 2 * .pi }
            let i = Int((a + .pi / 8) / (.pi / 4)) % 8
            highlight = WindowLayout.wheel[i]
        } else {
            highlight = nil
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        let R = radius, r = radius * 0.42
        let gap: CGFloat = 0.028   // radians between wedges
        // Soft halo under the wheel.
        let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0.75, 1])!
        ctx.drawRadialGradient(halo, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: R * 1.18, options: [])
        for (i, layout) in WindowLayout.wheel.enumerated() {
            // Wedge i is centered at angle (90° − i·45°) in standard math orientation.
            let mid = CGFloat.pi / 2 - CGFloat(i) * .pi / 4
            let a0 = mid - .pi / 8 + gap, a1 = mid + .pi / 8 - gap
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: R, startAngle: a0, endAngle: a1, clockwise: false)
            path.addArc(center: .zero, radius: r, startAngle: a1, endAngle: a0, clockwise: true)
            path.closeSubpath()
            let on = highlight == layout
            ctx.addPath(path)
            ctx.setFillColor(on ? accent.withAlphaComponent(0.96).cgColor : NSColor(calibratedWhite: 0.07, alpha: 0.78).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(on ? 0.9 : 0.16).cgColor)
            ctx.setLineWidth(on ? 1.5 : 1)
            ctx.strokePath()
            // Mini layout glyph at the middle of the wedge.
            let gm = (R + r) / 2
            let gc = CGPoint(x: cos(mid) * gm, y: sin(mid) * gm)
            drawGlyph(ctx, layout, at: gc, size: R * 0.19, on: on)
        }
        // Hub.
        let hub = r * 0.88
        ctx.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
        let hubOn = highlight == .center
        ctx.setStrokeColor((hubOn ? accent : NSColor.white.withAlphaComponent(0.25)).cgColor)
        ctx.setLineWidth(hubOn ? 2.5 : 1)
        ctx.strokeEllipse(in: CGRect(x: -hub, y: -hub, width: hub * 2, height: hub * 2))
        if let icon = appIcon {
            let s = hub * 0.7
            icon.draw(in: CGRect(x: -s / 2, y: hub * 0.08, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 0.95)
        }
        let title: String
        if !trusted { title = "Allow Accessibility" }
        else if let h = highlight { title = h.label }
        else { title = sticky ? "Click a layout" : appName }
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, hub * 0.2), weight: .semibold),
            .foregroundColor: (hubOn || !trusted) ? accent : NSColor.white.withAlphaComponent(0.92), .paragraphStyle: para]
        let box = CGRect(x: -hub, y: -hub * 0.62, width: hub * 2, height: hub * 0.5)
        NSAttributedString(string: title, attributes: attrs).draw(in: box)
        if !trusted {
            let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(8, hub * 0.13)),
                                                      .foregroundColor: NSColor.white.withAlphaComponent(0.6), .paragraphStyle: para]
            NSAttributedString(string: "in System Settings", attributes: sub).draw(in: box.offsetBy(dx: 0, dy: -hub * 0.3))
        }
        ctx.restoreGState()
    }

    /// A rounded screen outline with the window's area filled in.
    private func drawGlyph(_ ctx: CGContext, _ layout: WindowLayout, at c: CGPoint, size: CGFloat, on: Bool) {
        let w = size, h = size * 0.68
        let box = CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        let fg = on ? NSColor.black.withAlphaComponent(0.85) : NSColor.white.withAlphaComponent(0.9)
        ctx.setStrokeColor(fg.withAlphaComponent(on ? 0.7 : 0.55).cgColor)
        ctx.setLineWidth(1.2)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 2.5, cornerHeight: 2.5, transform: nil))
        ctx.strokePath()
        guard let f = layout.fraction else { return }
        let inset = box.insetBy(dx: 2, dy: 2)
        // `f` is measured from the top-left; this view's y runs up.
        let fill = CGRect(x: inset.minX + inset.width * f.minX, y: inset.maxY - inset.height * (f.minY + f.height),
                          width: inset.width * f.width, height: inset.height * f.height)
        ctx.setFillColor(fg.cgColor)
        ctx.addPath(CGPath(roundedRect: fill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
        ctx.fillPath()
    }
}
