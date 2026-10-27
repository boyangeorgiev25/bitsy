import AppKit

// Renders Bitsy's app icon from the pet's own pixel rig. Two looks: "dark" (the popup's warm charcoal)
// "cream" (clay on parchment) and "white" (flat, no gradient). Pose variants: laptop (default), wave, plain.
//   render <out.png> [laptop|wave|plain] [dark|cream|white]
let N: CGFloat = 1024
let out = CommandLine.arguments[1]
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "laptop"
let style = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "dark"
let cs = CGColorSpaceCreateDeviceRGB()

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
}

let img = NSImage(size: NSSize(width: N, height: N), flipped: true) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    // macOS icon grid: 824 pt squircle centred on the 1024 canvas
    let box = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: box, cornerWidth: 186, cornerHeight: 186, transform: nil)
    let dark = style == "dark"

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    if style == "white" {
        // flat: a white slab and the pet with its own pixel shadow, nothing else
        ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(box)
        let S: CGFloat = 24
        var p = Pose()
        p.mouth = .smile
        switch variant {
        case "wave": p.armR = .up2; p.eyes = .happy
        case "plain": p.eyes = .open
        default: p.laptop = true; p.eyes = .focus
        }
        ctx.translateBy(x: 512 - 16 * S, y: 512 - 18.5 * S + 18)
        drawPet(ctx, S, p)
        ctx.restoreGState()
        return true
    }
    // base: a quiet top-to-bottom gradient, lit from above
    if dark { linear(ctx, [rgb(0x332C27), rgb(0x1C1714), rgb(0x120F0D)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924)) }
    else { linear(ctx, [rgb(0xF7F1E8), rgb(0xEDE3D6), rgb(0xE3D6C6)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924)) }
    // soft light from the top, like the system icons
    radial(ctx, [rgb(0xFFFFFF, dark ? 0.10 : 0.55), rgb(0xFFFFFF, 0)], center: CGPoint(x: 512, y: 60), radius: 620)
    // a faint warm halo behind the pet so it doesn't float in a void
    radial(ctx, [rgb(0xD97757, dark ? 0.16 : 0.12), rgb(0xD97757, 0)], center: CGPoint(x: 512, y: 540), radius: 360)
    // vignette towards the corners
    radial(ctx, [rgb(0x000000, 0), rgb(0x000000, 0), rgb(0x000000, dark ? 0.35 : 0.10)], center: CGPoint(x: 512, y: 512), radius: 640)

    // the pet, 24 px per logical pixel; sprite box x 6…26, y 10…27 (own pixel shadow off, soft one below)
    let S: CGFloat = 24
    var p = Pose()
    p.noShadow = true
    p.mouth = .smile
    switch variant {
    case "wave": p.armR = .up2; p.eyes = .happy
    case "plain": p.eyes = .open
    default: p.laptop = true; p.eyes = .focus
    }
    let ox = 512 - 16 * S, oy = 512 - 18.5 * S + 18
    // contact shadow: a blurred ellipse under the feet
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 46, color: rgb(0x000000, dark ? 0.75 : 0.35))
    ctx.setFillColor(rgb(0x000000, dark ? 0.55 : 0.22))
    ctx.fillEllipse(in: CGRect(x: ox + 8 * S, y: oy + 27 * S - 10, width: 16 * S, height: 40))
    ctx.restoreGState()
    ctx.saveGState()
    ctx.translateBy(x: ox, y: oy)
    drawPet(ctx, S, p)
    ctx.restoreGState()
    ctx.restoreGState()

    // edge: a hairline rim light on top, a darker hairline below, so the slab has thickness
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    ctx.addPath(CGPath(roundedRect: box.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    ctx.setLineWidth(4)
    ctx.replacePathWithStrokedPath(); ctx.clip()
    linear(ctx, [rgb(0xFFFFFF, dark ? 0.22 : 0.9), rgb(0xFFFFFF, 0.0), rgb(0x000000, dark ? 0.3 : 0.12)], from: CGPoint(x: 512, y: 100), to: CGPoint(x: 512, y: 924))
    ctx.restoreGState()
    return true
}
let tiff = img.tiffRepresentation!, rep = NSBitmapImageRep(data: tiff)!
rep.size = NSSize(width: N, height: N)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
