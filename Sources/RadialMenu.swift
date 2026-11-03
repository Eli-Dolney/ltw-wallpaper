import Cocoa

/// One wedge (or the hub) of a wheel.
struct WheelItem {
    var label: String
    var icon: NSImage? = nil          // app icon (switcher)
    var layout: WindowLayout? = nil   // mini layout glyph (window wheel)
    var subtitle: String = ""         // window title under the app name, shown in the hub
}

/// A GTA-style weapon wheel. Hold the hotkey: the wheel opens around the cursor, moving toward a
/// wedge highlights it, letting go picks it. Tapping the hotkey keeps the wheel open so you can click
/// a wedge (or press Esc / right-click / click outside to cancel). One instance serves both the window
/// wheel (⌃⌥W) and the app wheel (⌃⌥Tab).
final class RadialMenu {
    struct Look {
        var accent = NSColor(calibratedRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
        var radius: CGFloat = 160
        var dim: CGFloat = 0.25
        var labels = true
    }

    var look = Look()
    private(set) var isShown = false
    private var sticky = false
    private let panel: NSPanel
    private let view: WheelView
    private var onPick: ((WheelView.Hover) -> Void)?

    init() {
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
        view.onClick = { [weak self] in self?.clicked() }
        view.onCancel = { [weak self] in self?.hide() }
    }

    /// Opens the wheel at the cursor. `hub` is the center action (nil: the hub only shows the title).
    /// `onPick` receives `.hub` or `.wedge(i)`.
    func show(items: [WheelItem], hub: WheelItem?, hubIcon: NSImage?, hubTitle: String, trusted: Bool,
              sticky: Bool, onPick: @escaping (WheelView.Hover) -> Void) {
        if isShown { if sticky { hide() }; return }
        self.sticky = sticky
        self.onPick = onPick
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        panel.setFrame(screen.frame, display: false)
        // Keep the whole wheel on screen, with a margin for the labels.
        let r = look.radius + (look.labels ? 48 : 24)
        let v = screen.visibleFrame
        var center = CGPoint(x: mouse.x - screen.frame.minX, y: mouse.y - screen.frame.minY)
        center.x = min(max(center.x, v.minX - screen.frame.minX + r), v.maxX - screen.frame.minX - r)
        center.y = min(max(center.y, v.minY - screen.frame.minY + r), v.maxY - screen.frame.minY - r)
        view.configure(items: items, hub: hub, hubIcon: hubIcon, hubTitle: hubTitle, trusted: trusted,
                       center: center, radius: look.radius, accent: look.accent, dim: look.dim, labels: look.labels, sticky: sticky)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        isShown = true
        view.animateIn()
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        view.updateHover(panelPoint: panel.convertPoint(fromScreen: mouse))
    }

    /// Hotkey released: pick the highlighted wedge, or stay open when it was just a tap.
    func released() {
        guard isShown, !sticky else { return }
        if view.hover != .none { pick(view.hover) } else { sticky = true; view.sticky = true }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.1; panel.animator().alphaValue = 0 },
                                            completionHandler: { [panel] in if !self.isShown { panel.orderOut(nil) } })
    }

    private func clicked() {
        if view.hover != .none { pick(view.hover) } else { hide() }
    }

    private func pick(_ h: WheelView.Hover) {
        let cb = onPick
        hide()
        cb?(h)
    }
}

/// Draws the wheel: a dim backdrop, N wedges with icons or mini layout glyphs, and a center disc with
/// an icon and the highlighted item's name.
final class WheelView: NSView {
    enum Hover: Equatable { case none, hub, wedge(Int) }

    var onClick: (() -> Void)?
    var onCancel: (() -> Void)?
    var sticky = false
    private(set) var hover: Hover = .none { didSet { if hover != oldValue { needsDisplay = true } } }
    private var items: [WheelItem] = []
    private var hub: WheelItem?
    private var hubIcon: NSImage?
    private var hubTitle = ""
    private var trusted = true
    private var center = CGPoint.zero
    private var radius: CGFloat = 160
    private var accent = NSColor.orange
    private var labels = true
    private var scale: CGFloat = 1

    override var acceptsFirstResponder: Bool { true }

    func configure(items: [WheelItem], hub: WheelItem?, hubIcon: NSImage?, hubTitle: String, trusted: Bool,
                   center: CGPoint, radius: CGFloat, accent: NSColor, dim: CGFloat, labels: Bool, sticky: Bool) {
        self.items = items; self.hub = hub; self.hubIcon = hubIcon; self.hubTitle = hubTitle; self.trusted = trusted
        self.center = center; self.radius = radius; self.accent = accent; self.labels = labels; self.sticky = sticky
        hover = .none
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
        guard !items.isEmpty else { hover = .none; return }
        let dx = p.x - center.x, dy = p.y - center.y
        let d = sqrt(dx * dx + dy * dy)
        let inner = radius * 0.42
        if d < inner * 0.9 {
            // Inside the hub: its action once the cursor has clearly moved in, nothing in the dead zone.
            hover = (hub == nil || (d < radius * 0.12 && !sticky)) ? .none : .hub
        } else if d < radius * 1.35 || !sticky {
            // Clockwise from the top; wedge i is centered on its direction.
            let n = CGFloat(items.count)
            var a = atan2(dx, dy)                    // 0 = up, π/2 = right
            if a < 0 { a += 2 * .pi }
            let step = 2 * .pi / n
            hover = .wedge(Int((a + step / 2) / step) % items.count)
        } else {
            hover = .none
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext, !items.isEmpty else { return }
        ctx.saveGState()
        ctx.translateBy(x: center.x, y: center.y)
        ctx.scaleBy(x: scale, y: scale)
        let R = radius, r = radius * 0.42
        let n = items.count
        let step = 2 * CGFloat.pi / CGFloat(n)
        let gap: CGFloat = min(0.028, step * 0.08)
        // Soft halo under the wheel.
        let halo = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: [NSColor.black.withAlphaComponent(0.35).cgColor, NSColor.black.withAlphaComponent(0).cgColor] as CFArray,
                              locations: [0.75, 1])!
        ctx.drawRadialGradient(halo, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: R * 1.18, options: [])
        for (i, item) in items.enumerated() {
            // Wedge i is centered at angle (90° − i·step) in standard math orientation.
            let mid = CGFloat.pi / 2 - CGFloat(i) * step
            let a0 = mid - step / 2 + gap, a1 = mid + step / 2 - gap
            let path = CGMutablePath()
            path.addArc(center: .zero, radius: R, startAngle: a0, endAngle: a1, clockwise: false)
            path.addArc(center: .zero, radius: r, startAngle: a1, endAngle: a0, clockwise: true)
            path.closeSubpath()
            let on = hover == .wedge(i)
            ctx.addPath(path)
            ctx.setFillColor(on ? accent.withAlphaComponent(0.96).cgColor : NSColor(calibratedWhite: 0.07, alpha: 0.78).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(on ? 0.9 : 0.16).cgColor)
            ctx.setLineWidth(on ? 1.5 : 1)
            ctx.strokePath()
            let gm = (R + r) / 2
            let gc = CGPoint(x: cos(mid) * gm, y: sin(mid) * gm)
            if let layout = item.layout {
                drawGlyph(ctx, layout, at: gc, size: R * 0.19, on: on)
            } else if let icon = item.icon {
                // Icon sized to the wedge; the label sits outside the ring, along the wedge direction.
                let s = min(R * 0.3, gm * step * 0.62)
                icon.draw(in: CGRect(x: gc.x - s / 2, y: gc.y - s / 2, width: s, height: s), from: .zero, operation: .sourceOver, fraction: on ? 1 : 0.92)
                if labels {
                    let lp = CGPoint(x: cos(mid) * (R + 14), y: sin(mid) * (R + 14))
                    drawLabel(item.label, at: lp, angle: mid, size: max(9, R * 0.07), on: on)
                }
            }
        }
        // Hub.
        let hubR = r * 0.88
        ctx.setFillColor(NSColor(calibratedWhite: 0.05, alpha: 0.92).cgColor)
        ctx.fillEllipse(in: CGRect(x: -hubR, y: -hubR, width: hubR * 2, height: hubR * 2))
        let hubOn = hover == .hub
        ctx.setStrokeColor((hubOn ? accent : NSColor.white.withAlphaComponent(0.25)).cgColor)
        ctx.setLineWidth(hubOn ? 2.5 : 1)
        ctx.strokeEllipse(in: CGRect(x: -hubR, y: -hubR, width: hubR * 2, height: hubR * 2))
        var icon = hubIcon
        var title = hubTitle, sub = ""
        if !trusted { title = "Allow Accessibility"; sub = "in System Settings" }
        else if case .wedge(let i) = hover { title = items[i].label; sub = items[i].subtitle; icon = items[i].icon ?? icon }
        else if hubOn, let h = hub { title = h.label; sub = h.subtitle; icon = h.icon ?? icon }
        else if sticky { sub = "Click to pick" }
        if let icon = icon {
            let s = hubR * 0.7
            icon.draw(in: CGRect(x: -s / 2, y: hubR * 0.08, width: s, height: s), from: .zero, operation: .sourceOver, fraction: 0.95)
        }
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(10, hubR * 0.19), weight: .semibold),
            .foregroundColor: (hubOn || !trusted) ? accent : NSColor.white.withAlphaComponent(0.92), .paragraphStyle: para]
        let box = CGRect(x: -hubR * 0.95, y: -hubR * 0.6, width: hubR * 1.9, height: hubR * 0.45)
        NSAttributedString(string: title, attributes: attrs).draw(in: box)
        if !sub.isEmpty {
            let subAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: max(8, hubR * 0.13)),
                                                           .foregroundColor: NSColor.white.withAlphaComponent(0.6), .paragraphStyle: para]
            NSAttributedString(string: sub, attributes: subAttrs).draw(in: box.offsetBy(dx: 0, dy: -hubR * 0.28))
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

    /// A short label outside the ring, anchored toward the wedge so it never overlaps the wheel.
    private func drawLabel(_ text: String, at p: CGPoint, angle: CGFloat, size: CGFloat, on: Bool) {
        let para = NSMutableParagraphStyle(); para.lineBreakMode = .byTruncatingTail
        let c = cos(angle)
        para.alignment = c > 0.3 ? .left : (c < -0.3 ? .right : .center)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: on ? .semibold : .medium),
                                                    .foregroundColor: on ? accent : NSColor.white.withAlphaComponent(0.85), .paragraphStyle: para]
        let w = size * 9, h = size * 1.4
        var box: CGRect
        switch para.alignment {
        case .left: box = CGRect(x: p.x, y: p.y - h / 2, width: w, height: h)
        case .right: box = CGRect(x: p.x - w, y: p.y - h / 2, width: w, height: h)
        default: box = CGRect(x: p.x - w / 2, y: sin(angle) > 0 ? p.y : p.y - h, width: w, height: h)
        }
        // Text shadow for legibility over bright windows.
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.8); shadow.shadowBlurRadius = 3
        var a = attrs; a[.shadow] = shadow
        NSAttributedString(string: text, attributes: a).draw(in: box)
    }
}
