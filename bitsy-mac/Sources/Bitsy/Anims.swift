import Foundation
import CoreGraphics

enum Anim: String {
    case idle, walk, run, jump, wave, love, surprised, think, work, dance, sleep, dangle
    case vibe, hang, drowsy, cheer
    case fall, land, crouch, leap, teeter   // physics-driven
}

func m(_ a: Double, _ b: Double) -> Double { a.truncatingRemainder(dividingBy: b) }
func step(_ t: Double, _ fps: Double, _ n: Int) -> Int { Int(floor(t * fps)) % n }
func blink(_ t: Double) -> Bool { m(t, 3.3) < 0.12 || m(t + 1.7, 5.9) < 0.1 }
func fade(_ ph: Double) -> Double { ph < 0.15 ? ph / 0.15 : ph > 0.7 ? (1 - ph) / 0.3 : 1 }
func rise(_ t: Double, _ period: Double, _ n: Int, _ make: (Double, Int) -> FX) -> [FX] {
    (0..<n).map { i in make(m(t / period + Double(i) / Double(n), 1), i) }
}

let SPARK = rgb(0xFFE08A), HEART = rgb(0xFF6B81), BANG = rgb(0xFF5A5F), PALE = rgb(0xE8E2DA)
let ZCOL = rgb(0xD9D1C7), DUST = rgb(0xA89F95), DROP = rgb(0x7CC6FE), NOTE1 = rgb(0x8ECDF0), NOTE2 = rgb(0xF3D36B)

func frame(_ a: Anim, _ t: Double, _ dir: Int = 1) -> Frame {
    var p = Pose()
    switch a {
    case .idle:
        p.dy = m(t, 2) < 1 ? 0 : -1
        p.eyes = blink(t) ? .blink : .open
        p.look = [0, 0, 0, 1, 1, 0, 0, -1, -1, 0][step(t, 1.4, 10)]
        return Frame(pose: p)

    case .walk, .run:
        let run = a == .run
        let fr = step(t, run ? 14 : 8, 4), A = fr == 0, B = fr == 2
        p.dy = A || B ? -1 : 0
        p.legs = [A, B, A, B].map { $0 ? (run ? 2 : 1) : 0 }
        p.feet = [A, B, A, B].map { $0 ? dir : 0 }
        p.look = dir
        if run {
            p.eyes = .focus; p.armL = .out; p.armR = .out; p.armOff = [A ? -1 : 0, B ? -1 : 0]
            let fx = rise(t, 0.45, 3) { ph, _ in
                FX(g: "dust", x: dir > 0 ? 6 - ph * 5 : 24 + ph * 5, y: 26 - ph * 3, c: DUST, a: 0.9 - ph)
            }
            return Frame(pose: p, fx: fx)
        }
        p.eyes = blink(t) ? .blink : .open
        p.armOff = [A ? -1 : B ? 1 : 0, A ? 1 : B ? -1 : 0]
        return Frame(pose: p)

    case .jump:
        let c = m(t, 1.7)
        if c < 0.2 { p.squash = 1; p.dy = 1; p.eyes = .squint; p.armL = .down; p.armR = .down; return Frame(pose: p) }
        if c < 0.85 {
            let u = (c - 0.2) / 0.65, air = Int((sin(u * .pi) * 10).rounded())
            p.air = air; p.squash = u < 0.25 ? -1 : 0; p.eyes = .happy; p.armL = .up; p.armR = .up
            p.legs = u < 0.5 ? [1, 1, 1, 1] : [0, 0, 0, 0]
            let fx = u > 0.3 && u < 0.7
                ? [FX(g: "spark", x: 3, y: Double(12 - air), c: SPARK), FX(g: "spark", x: 27, y: Double(9 - air), c: SPARK)] : []
            return Frame(pose: p, fx: fx)
        }
        if c < 1.0 { p.squash = 1; p.dy = 1; p.eyes = .happy; p.armL = .out; p.armR = .out }
        return Frame(pose: p)

    case .wave:
        let w = step(t, 6, 2) == 1
        p.eyes = m(t, 2.4) < 1.8 ? .happy : .open; p.armR = w ? .up2 : .up; p.mouth = .smile
        return Frame(pose: p, fx: [FX(g: "spark", x: w ? 29 : 28, y: w ? 5 : 6, c: SPARK, a: 0.9)])

    case .love:
        p.dy = m(t, 0.5) < 0.25 ? -1 : 0; p.eyes = .happy; p.mouth = .smile
        let fx = rise(t, 1.8, 3) { ph, i in
            FX(g: "heart", x: Double([2, 14, 25][i]) + sin(ph * 6 + Double(i)).rounded(), y: 10 - ph * 10, c: HEART, a: fade(ph))
        }
        return Frame(pose: p, fx: fx)

    case .surprised:
        let c = m(t, 2.4)
        if c < 0.1 { return Frame(pose: p) }
        if c < 0.5 {
            let u = (c - 0.1) / 0.4, air = Int((sin(u * .pi) * 4).rounded())
            p.air = air; p.eyes = .wide; p.mouth = .o; p.armL = .up; p.armR = .up
            return Frame(pose: p, fx: [FX(g: "bang", x: 15, y: Double(4 - air), c: BANG)])
        }
        p.eyes = c > 1.8 && blink(t) ? .blink : .wide
        p.mouth = c < 1.4 ? .o : .none
        p.armL = c < 1 ? .up : .side; p.armR = p.armL
        return Frame(pose: p, fx: c < 1.3 ? [FX(g: "bang", x: 15, y: 4, c: BANG)] : [])

    case .think:
        p.look = -1; p.lookY = -1; p.eyes = blink(t) ? .blink : .open
        p.armR = step(t, 3, 2) == 1 ? .up : .up2; p.legs = [0, 0, 0, step(t, 4, 2)]
        return Frame(pose: p, fx: [FX(g: "q", x: 3, y: m(t, 1.2) < 0.6 ? 3 : 4, c: PALE)])

    case .work:
        let k = step(t, 10, 2) == 1
        p.laptop = true; p.eyes = blink(t) ? .blink : .focus; p.lookY = 1; p.armOff = [k ? -1 : 0, k ? 0 : -1]
        let fx = rise(t, 1.6, 3) { ph, i in
            FX(g: ["lt", "sl", "gt"][i], x: Double([2, 28, 27][i]) + sin(ph * 5).rounded(), y: 20 - ph * 16, c: pal.light, a: fade(ph))
        }
        return Frame(pose: p, fx: fx)

    case .dance:
        let b = step(t, 4, 4), up = b < 2
        p.dx = [0, 1, 0, -1][b]; p.dy = b % 2 == 1 ? 0 : -1; p.eyes = .happy; p.mouth = .smile
        p.armL = up ? .up : .side; p.armR = up ? .side : .up
        p.legs = b == 0 ? [1, 0, 0, 1] : b == 2 ? [0, 1, 1, 0] : [0, 0, 0, 0]
        let fx = rise(t, 2.2, 3) { ph, i in
            FX(g: "note", x: Double(i % 2 == 1 ? 26 : 1) + sin(ph * 7 + Double(i)).rounded(), y: 14 - ph * 13,
               c: i % 2 == 1 ? NOTE2 : NOTE1, a: fade(ph))
        }
        return Frame(pose: p, fx: fx)

    case .sleep:
        p.dy = 4; p.top = m(t, 2.4) < 1.2 ? 0 : 1; p.eyes = .closed; p.armL = .down; p.armR = .down
        let fx = rise(t, 2.7, 3) { ph, i in
            FX(g: i % 2 == 1 ? "z" : "Z", x: 21 + ph * 5, y: 13 - ph * 12, c: ZCOL, a: fade(ph))
        }
        return Frame(pose: p, fx: fx)

    case .dangle:
        let sw = Int(sin(t * 9).rounded())
        p.dangle = true; p.squash = -1; p.dy = -3; p.legLen = 5; p.feet = [sw, -sw, sw, -sw]
        p.eyes = .squint; p.armL = .up; p.armR = .up; p.noShadow = true
        return Frame(pose: p, fx: m(t, 1) < 0.6 ? [FX(g: "drop", x: 27, y: 9, c: DROP)] : [])

    case .fall:
        p.dangle = true; p.dy = -3; p.legLen = 5; p.eyes = .wide; p.mouth = .o; p.armL = .up2; p.armR = .up2; p.noShadow = true
        return Frame(pose: p)

    case .land:
        p.squash = 1; p.dy = 1; p.eyes = .squint; p.armL = .out; p.armR = .out
        return Frame(pose: p, fx: [FX(g: "dust", x: 4, y: 25, c: DUST, a: 0.8), FX(g: "dust", x: 26, y: 25, c: DUST, a: 0.8)])

    case .crouch:
        p.squash = 1; p.dy = 1; p.eyes = .squint; p.armL = .down; p.armR = .down; p.look = dir
        return Frame(pose: p)

    case .vibe:   // music playing: head bob, foot tap, notes
        let b = step(t, 2.2, 2) == 1
        p.dy = b ? -1 : 0; p.eyes = m(t, 4) < 2.5 ? .closed : .happy; p.mouth = .smile
        p.legs = b ? [0, 0, 0, 1] : [0, 0, 0, 0]
        let fx = rise(t, 2.4, 2) { ph, i in
            FX(g: "note", x: Double(i == 1 ? 26 : 1) + sin(ph * 6 + Double(i)).rounded(), y: 12 - ph * 11,
               c: i == 1 ? NOTE2 : NOTE1, a: fade(ph))
        }
        return Frame(pose: p, fx: fx)

    case .drowsy:   // up past bedtime: heavy eyelids, candle in hand, the odd yawn
        let c = m(t, 7), yawn = c > 5 && c < 6.2
        p.eyes = yawn ? .closed : (m(t, 2.6) < 0.45 ? .blink : .focus)
        p.mouth = yawn ? .o : .none
        p.dy = yawn ? -1 : 0
        p.armR = .up
        let lit = step(t, 7, 2) == 1
        var fx = [
            FX(g: "glow", x: 24, y: 3 + Double(p.dy), c: rgb(0xFFD166), a: lit ? 0.22 : 0.16),
            FX(g: "stick", x: 26, y: 7 + Double(p.dy), c: rgb(0xF4F0EA)),
            FX(g: "flame", x: 26, y: 5 + Double(p.dy), c: lit ? rgb(0xFFD166) : rgb(0xFF9F43)),
        ]
        if yawn { fx.append(FX(g: "z", x: 2, y: 6 - (c - 5) * 4, c: ZCOL, a: 0.9)) }
        return Frame(pose: p, fx: fx)

    case .hang:   // holding on under the notch
        let sw = Int(sin(t * 2).rounded())
        p.dangle = true; p.squash = -1; p.dy = -3; p.legLen = 5; p.feet = [sw, sw, sw, sw]
        p.armL = .up; p.armR = .up; p.noShadow = true
        p.eyes = blink(t) ? .blink : .open; p.look = [0, 1, 1, 0, -1, -1][step(t, 0.8, 6)]
        return Frame(pose: p)

    case .cheer:   // Claude finished: two happy hops, arms waving, a big green check
        let u = m(t, 0.8) / 0.8, air = u < 0.6 ? Int((sin(u / 0.6 * .pi) * 5).rounded()) : 0
        let w = step(t, 6, 2) == 1
        p.air = air; p.eyes = .happy; p.mouth = .smile
        p.armL = w ? .up2 : .up; p.armR = w ? .up : .up2
        return Frame(pose: p, fx: [
            FX(g: "check", x: 13, y: Double(4 - air), c: rgb(0x7BD389)),
            FX(g: "spark", x: w ? 2 : 3, y: Double(10 - air), c: SPARK),
            FX(g: "spark", x: w ? 28 : 27, y: Double(12 - air), c: SPARK),
        ])

    case .teeter:   // the window under it is moving: arms windmill, about to fall
        let w = step(t, 12, 2) == 1
        p.dx = w ? 1 : -1; p.eyes = .wide; p.mouth = .o
        p.armL = w ? .up : .out; p.armR = w ? .out : .up
        p.legs = w ? [1, 0, 0, 0] : [0, 0, 0, 1]
        return Frame(pose: p, fx: [FX(g: "drop", x: w ? 27 : 2, y: 8, c: DROP)])

    case .leap:
        p.dangle = true; p.legLen = 3; p.squash = t < 0.12 ? -1 : 0; p.eyes = .happy
        p.armL = .up; p.armR = .up; p.noShadow = true; p.look = dir
        return Frame(pose: p)
    }
}
