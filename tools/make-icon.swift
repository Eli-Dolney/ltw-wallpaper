// Renders Resources/AppIcon.icns: a dark rounded square with the sparkles symbol in the accent color.
//   swift tools/make-icon.swift [accent=#d97757]
import Cocoa

let accent = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "#d97757"
func color(_ hex: String) -> NSColor {
    var s = hex; if s.hasPrefix("#") { s.removeFirst() }
    let v = UInt32(s, radix: 16) ?? 0xd97757
    return NSColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: the squircle sits inside a ~10% margin with ~22.4% corner radius.
    let inset = s * 0.1, side = s - inset * 2
    let rect = NSRect(x: inset, y: inset, width: side, height: side)
    let path = NSBezierPath(roundedRect: rect, xRadius: side * 0.224, yRadius: side * 0.224)
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSGradient(colors: [color("#1c2029"), color("#0b0d10")])!.draw(in: path, angle: -90)
    NSShadow().set()
    // faint topo-like rings
    path.addClip()
    for i in 1...6 {
        let r = side * 0.12 * CGFloat(i)
        let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - r, y: rect.minY - r * 0.4, width: r * 2, height: r * 2))
        ring.lineWidth = s * 0.004
        color(accent).withAlphaComponent(0.10).setStroke(); ring.stroke()
    }
    // sparkles symbol with a glow
    let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.5, weight: .medium)
    let sym = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let tinted = NSImage(size: sym.size, flipped: false) { r in
        sym.draw(in: r); color(accent).set(); r.fill(using: .sourceAtop); return true
    }
    let glow = NSShadow(); glow.shadowColor = color(accent).withAlphaComponent(0.7); glow.shadowBlurRadius = s * 0.06
    glow.set()
    let sz = tinted.size
    tinted.draw(in: NSRect(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2, width: sz.width, height: sz.height))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let set = URL(fileURLWithPath: "Resources/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                   ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.launchPath = "/usr/bin/iconutil"; p.arguments = ["-c", "icns", set.path, "-o", "Resources/AppIcon.icns"]
p.launch(); p.waitUntilExit()
try? FileManager.default.removeItem(at: set)
print(p.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
