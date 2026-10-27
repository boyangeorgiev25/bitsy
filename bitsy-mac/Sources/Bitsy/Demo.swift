import AppKit

// Demo mode (BITSY_DEMO=1) for recording a promo: a fixed script of beats instead of random behavior.
// Pair it with BITSY_DROP (where Bitsy starts) and BITSY_CLAUDE_DIR (a folder of sample transcripts).

extension Pet {
    func runDemo() {
        paused = true; followClicks = false; watchTyping = false
        media.demoSet(nil)   // no real music in a recording
        let beats: [(Double, () -> Void)] = [
            (1.2, { self.go(.wave, 1.4) }),
            (2.8, { self.demoHop(toWindowAt: 590, x: 600) }),          // Dock → design.png
            (4.6, { self.demoSendPicture() }),
            (7.0, { self.demoHop(toWindowAt: 300, x: 760) }),          // design.png → terminal
            (11.3, { self.demoWalk(to: 756, run: true) }),
            (21.0, { self.demoCarryToNotch(duration: 1.8) }),
            (24.0, { self.media.demoSet(NowPlaying(app: "Spotify", title: "Night Drive", artist: "Bitsy FM", playing: true)) }),
            (25.5, { self.syncStats(); self.island.expand(music: true) }),
            (30.0, { self.island.collapse() }),
        ]
        for (t, beat) in beats { DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: beat) }
    }

    func demoWalk(to tx: Double, run: Bool = false) {
        guard mode == .ground else { return }
        walkTarget = tx
        dir = tx > x ? 1 : -1
        go(run ? .run : .walk, 99)
    }

    /// Hop onto the window whose top edge is near `y` (global, top-left origin), landing near `x`.
    func demoHop(toWindowAt y: Double, x lx: Double) {
        guard mode == .ground,
              let p = world.platforms.filter({ $0.id >= 0 && $0.id != supportID && abs($0.y - y) < 50 }).first else { return }
        hop((p, min(max(lx, p.x0 + 40), p.x1 - 40)))
    }

    /// What a double-click looks like: the window under Bitsy flashes like a screenshot, then the bubble.
    /// (Shown only; a recording never pastes into a real chat.)
    func demoSendPicture() {
        guard let id = supportID, id >= 0, let r = world.windows[id] else { return }
        let flash = NSPanel(contentRect: NSRect(x: r.minX, y: world.H - r.maxY, width: r.width, height: r.height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        flash.backgroundColor = .white
        flash.level = .floating
        flash.alphaValue = 0.85
        flash.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; flash.animator().alphaValue = 0 }) { flash.orderOut(nil) }
        go(.wave, 1.6)
        bubble.show("Sent to Claude", "Screenshot of design.png", seconds: 2.2)
    }

    /// Carried to the notch as if by the mouse, then dropped into the island.
    func demoCarryToNotch(duration: Double) {
        guard let n = world.notchRect() else { return }
        let grab = CGPoint(x: x, y: y - (Pet.foot - 9 * Double(Pet.S)))
        demoCarry = (grab, CGPoint(x: n.midX, y: n.midY), CACurrentMediaTime(), duration)
        mode = .drag; dragging = true; supportID = nil; supportRect = nil; walkTarget = nil; pendingHop = nil
        go(.dangle, 99)
    }

    func demoCarryStep() {
        guard let c = demoCarry else { return }
        let t = min(1, (CACurrentMediaTime() - c.start) / c.dur)
        let u = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        let p = CGPoint(x: c.from.x + (c.to.x - c.from.x) * u + 60 * sin(u * .pi),
                        y: c.from.y + (c.to.y - c.from.y) * u)
        x = p.x
        y = p.y + Pet.foot - 9 * Double(Pet.S)
        guard let n = world.notchRect() else { return }
        let gap = hypot(max(Double(n.minX) - p.x, 0, p.x - Double(n.maxX)), max(p.y - Double(n.maxY), 0))
        notchLevel = Pet.snapZone(n).contains(p) ? 2 : gap < 150 ? 1 : 0
        island.preview(notchLevel, notch: n, world: world)
        if t >= 1 {
            demoCarry = nil; dragging = false; notchLevel = 0
            enterIsland(auto: false)
        }
    }
}
