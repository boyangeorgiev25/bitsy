// Draws the DMG window background: swift background.swift <out-dir>
// Writes background.png (640×420) and background@2x.png for Retina.
import AppKit

let W: CGFloat = 640, H: CGFloat = 420
let accent = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)

func draw(scale: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.translateBy(x: 0, y: H); ctx.scaleBy(x: 1, y: -1)   // y down, like Finder's icon coordinates
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // warm dark gradient
    let g = NSGradient(colors: [NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
                                NSColor(srgbRed: 0.08, green: 0.075, blue: 0.07, alpha: 1)])!
    g.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: 90)

    // faint pixel grid
    ctx.setFillColor(NSColor(white: 1, alpha: 0.025).cgColor)
    for x in stride(from: 0, to: W, by: 16) { for y in stride(from: 0, to: H, by: 16) { ctx.fill(CGRect(x: x, y: y, width: 2, height: 2)) } }

    func text(_ s: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat) {
        let style = NSMutableParagraphStyle(); style.alignment = .center
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: style]
        NSAttributedString(string: s, attributes: a).draw(in: NSRect(x: 0, y: y, width: W, height: size * 1.5))
    }
    text("Drag Bitsy into Applications", 22, .bold, .white, y: 46)
    text("Then open it from your Applications folder.", 13, .regular, NSColor(white: 1, alpha: 0.55), y: 80)

    // pixel-art arrow between the two icons (icons sit at x 170 and 470, y 215)
    let p: CGFloat = 6
    func px(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat = 1) { ctx.setFillColor(accent.withAlphaComponent(a).cgColor); ctx.fill(CGRect(x: x, y: y, width: p, height: p)) }
    let y0: CGFloat = 212
    var x: CGFloat = 262
    var i = 0
    while x < 362 { px(x, y0, 0.35 + 0.65 * CGFloat(i) / 16); x += p * 1.5; i += 1 }   // dotted shaft, fading in
    for k in 0..<5 { px(362 + CGFloat(k) * p, y0 - CGFloat(4 - k) * p); px(362 + CGFloat(k) * p, y0 + CGFloat(4 - k) * p) }   // head
    px(362 + 4 * p, y0)

    // sparkles
    for (sx, sy) in [(120.0, 140.0), (530.0, 128.0), (318.0, 300.0)] {
        ctx.setFillColor(NSColor(srgbRed: 1, green: 0.88, blue: 0.54, alpha: 0.7).cgColor)
        ctx.fill(CGRect(x: sx, y: sy - 4, width: 4, height: 12)); ctx.fill(CGRect(x: sx - 4, y: sy, width: 12, height: 4))
    }

    // first-launch hint for builds that aren't notarized
    ctx.setFillColor(NSColor(white: 1, alpha: 0.06).cgColor)
    ctx.addPath(CGPath(roundedRect: CGRect(x: 70, y: 352, width: W - 140, height: 40), cornerWidth: 10, cornerHeight: 10, transform: nil)); ctx.fillPath()
    text("First launch: System Settings › Privacy & Security › Open Anyway", 12, .medium, NSColor(white: 1, alpha: 0.7), y: 363)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
for (scale, name) in [(1.0, "background.png"), (2.0, "background@2x.png")] {
    try! draw(scale: scale).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
