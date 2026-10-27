import AppKit

// The 32×32 pixel rig. Coordinates are logical pixels, y pointing down.

struct Palette { let key: String; let name: String; let body: CGColor; let shade: CGColor; let light: CGColor }

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

let pal = Palette(key: "clay", name: "Clay", body: rgb(0xD97757), shade: rgb(0xB35D40), light: rgb(0xEB9A7F))
let INK = rgb(0x1B1512), SHINE = rgb(0xF7EFE6)

enum Eyes { case open, blink, focus, wide, happy, closed, squint }
enum Arm { case side, up, up2, down, out, type, hide }
enum Mouth { case none, o, smile }

struct Pose: Equatable {
    var dx = 0, dy = 0, air = 0, squash = 0, top = 0
    var legs = [0, 0, 0, 0], feet = [0, 0, 0, 0], legLen = 4
    var dangle = false
    var eyes: Eyes = .open
    var look = 0, lookY = 0
    var armL: Arm = .side, armR: Arm = .side
    var armOff = [0, 0]
    var mouth: Mouth = .none
    var laptop = false, noShadow = false
    var headphones = false
    var nightcap = false
}

struct FX: Equatable { var g: String; var x: Double; var y: Double; var c: CGColor; var a: Double = 1 }
struct Frame: Equatable { var pose: Pose; var fx: [FX] = [] }

let GLYPHS: [String: [String]] = [
    "z": ["1111", "0010", "0100", "1111"],
    "Z": ["11111", "00010", "00100", "01000", "11111"],
    "heart": ["11011", "11111", "11111", "01110", "00100"],
    "note": ["0111", "0101", "0100", "1100", "1100"],
    "bang": ["11", "11", "11", "11", "00", "11"],
    "q": ["0110", "1001", "0001", "0010", "0000", "0010"],
    "spark": ["010", "111", "010"],
    "drop": ["010", "111", "111"],
    "dust": ["11", "11"],
    "flame": ["1", "1"], "stick": ["1", "1", "1"], "glow": ["01110", "11111", "11111", "01110"],
    "moon": ["0110", "1100", "1100", "0110"], "dot": ["1"], "wind": ["11110", "00011"],
    "check": ["000001", "000010", "100100", "011000"],
    "mag": ["0111000", "1000100", "1000100", "1000100", "0111100", "0000110", "0000011"],
    "photo": ["1111111", "1000001", "1011101", "1011101", "1000001", "1111111"],
    "lt": ["01", "10", "01"], "gt": ["10", "01", "10"], "sl": ["01", "01", "10"],
]

func drawFX(_ ctx: CGContext, _ S: CGFloat, _ f: FX) {
    guard let g = GLYPHS[f.g], let c = f.c.copy(alpha: f.c.alpha * CGFloat(max(0, min(1, f.a)))) else { return }
    ctx.setFillColor(c)
    let x = Int(f.x.rounded()), y = Int(f.y.rounded())
    for (j, row) in g.enumerated() {
        for (i, ch) in row.enumerated() where ch == "1" {
            ctx.fill(CGRect(x: CGFloat(x + i) * S, y: CGFloat(y + j) * S, width: S, height: S))
        }
    }
}

func drawPet(_ ctx: CGContext, _ S: CGFloat, _ p: Pose) {
    func r(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: CGColor) {
        guard w > 0, h > 0 else { return }
        ctx.setFillColor(c)
        ctx.fill(CGRect(x: CGFloat(x) * S, y: CGFloat(y) * S, width: CGFloat(w) * S, height: CGFloat(h) * S))
    }
    let dx = p.dx, air = p.air, s = p.squash, dy = p.dy
    let x0 = 7 - s + dx, x1 = 24 + s + dx
    let y1 = 22 + dy - air, y0 = 12 + 2 * s + dy + p.top - air

    if !p.noShadow { let k = min(4, air / 2); r(9 + k + dx, 28, 14 - 2 * k, 1, rgb(0, 0.32)) }

    // legs
    let hang = air > 0 || p.dangle
    for (i, lx0) in [8, 12, 18, 22].enumerated() {
        let lx = lx0 + dx, top = y1 + 1
        let bot = hang ? top + p.legLen - 1 - p.legs[i] : 27 - p.legs[i]
        if bot < top { continue }
        for y in top...bot {
            let o = (p.feet[i] != 0 && y >= bot - 1) ? p.feet[i] : 0
            r(lx + o, y, 1, 1, pal.body); r(lx + o + 1, y, 1, 1, pal.shade)
        }
    }

    // body
    r(x0, y0, x1 - x0 + 1, y1 - y0 + 1, pal.body)
    r(x0 + 1, y0, x1 - x0 - 1, 1, pal.light)
    r(x1, y0 + 1, 1, y1 - y0, pal.shade)
    r(x0, y1, x1 - x0, 1, pal.shade)

    // headphones (drawn under the arm nubs)
    if p.headphones {
        let band = rgb(0x3A3940), cup = rgb(0x26252B)
        r(x0 + 1, y0 - 2, x1 - x0 - 1, 1, band)
        r(x0, y0 - 1, 1, 2, band); r(x1, y0 - 1, 1, 2, band)
        r(x0 - 1, y0 + 1, 2, 4, cup); r(x1, y0 + 1, 2, 4, cup)
        r(x0 - 1, y0 + 2, 1, 2, pal.light); r(x1 + 1, y0 + 2, 1, 2, pal.light)
    }

    // floppy nightcap with a pom-pom drooping to the right
    if p.nightcap {
        let cap = rgb(0x5468C8), capD = rgb(0x3F4FA6), trim = rgb(0xEDE8E1)
        r(x0 + 1, y0 - 1, x1 - x0 - 1, 1, trim)
        r(x0 + 3, y0 - 2, x1 - x0 - 5, 1, cap)
        r(x0 + 5, y0 - 3, x1 - x0 - 8, 1, cap)
        r(x0 + 8, y0 - 4, x1 - x0 - 10, 1, capD)
        r(x1 - 3, y0 - 3, 2, 1, capD)
        r(x1 - 1, y0 - 2, 2, 2, trim)
    }

    // arm nubs
    func arm(_ side: Int, _ pose: Arm, _ off: Int) {
        if pose == .hide { return }
        var w = 2, h = 3, ax = side < 0 ? x0 - 2 : x1 + 1, ay = y0 + 3 + off
        switch pose {
        case .up: ay = y0 - 2 + off
        case .up2: ay = y0 - 3 + off; ax += side
        case .down: ay = y0 + 5
        case .out: w = 3; h = 2; ax = side < 0 ? x0 - 3 : x1 + 1; ay = y0 + 4 + off
        case .type:
            ax = side < 0 ? x0 + 1 : x1 - 2; ay = y1 + 1 + off
            r(ax, ay, 2, 1, pal.light); r(ax, ay + 1, 2, 1, pal.body)
            return
        default: break
        }
        r(ax, ay, w, h, pal.body); r(ax, ay + h - 1, w, 1, pal.shade)
    }
    if !p.laptop { arm(-1, p.armL, p.armOff[0]); arm(1, p.armR, p.armOff[1]) }

    // eyes
    let ey = y0 + 2 + p.lookY
    for (i, ex0) in [11, 19].enumerated() {
        let ex = ex0 + dx + p.look
        switch p.eyes {
        case .open: r(ex, ey, 2, 4, INK); r(ex + 1, ey, 1, 1, SHINE)
        case .blink: r(ex, ey + 2, 2, 1, INK)
        case .focus: r(ex, ey + 1, 2, 3, INK); r(ex + 1, ey + 1, 1, 1, SHINE)
        case .wide: let x = i == 1 ? ex : ex - 1; r(x, ey - 1, 3, 5, INK); r(x + 2, ey - 1, 1, 2, SHINE)
        case .happy: r(ex - 1, ey + 2, 1, 1, INK); r(ex, ey + 1, 2, 1, INK); r(ex + 2, ey + 2, 1, 1, INK)
        case .closed: r(ex - 1, ey + 2, 1, 1, INK); r(ex, ey + 3, 2, 1, INK); r(ex + 2, ey + 2, 1, 1, INK)
        case .squint:
            if i == 0 { r(ex, ey + 1, 1, 1, INK); r(ex + 1, ey + 2, 1, 1, INK); r(ex, ey + 3, 1, 1, INK) }
            else { r(ex + 1, ey + 1, 1, 1, INK); r(ex, ey + 2, 1, 1, INK); r(ex + 1, ey + 3, 1, 1, INK) }
        }
    }

    // mouth
    switch p.mouth {
    case .o: r(15 + dx, y0 + 7, 2, 2, INK)
    case .smile: r(14 + dx, y0 + 7, 1, 1, INK); r(15 + dx, y0 + 8, 2, 1, INK); r(17 + dx, y0 + 7, 1, 1, INK)
    case .none: break
    }

    // tiny laptop
    if p.laptop {
        r(9 + dx, y1 - 3, 14, 6, rgb(0x2B2A2F)); r(9 + dx, y1 - 3, 14, 1, rgb(0x4A4950)); r(15 + dx, y1 - 1, 2, 2, pal.light)
        r(6 + dx, y1 + 3, 20, 1, rgb(0xC4C3CA)); r(6 + dx, y1 + 4, 20, 1, rgb(0x85848C))
        arm(-1, .type, p.armOff[0]); arm(1, .type, p.armOff[1])
    }
}
