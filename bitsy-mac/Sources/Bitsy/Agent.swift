import AppKit
import ApplicationServices
import BitsyKit

// Bitsy acting out what your Claude agent does (lowered on a rope to look at a window, taking the photo, typing an
// address), plus two things you start yourself: Ask Claude… and spotting errors in your terminal or editor.

struct Rope {
    var rect: CGRect          // the window Bitsy looks at
    var top: Double           // the screen's top edge, where the rope hangs from
    var start: Double
    var photo: Bool           // take a picture (look) or only read (read)
    var backX: Double         // where Bitsy was, to drop back afterwards
    var flashed = false
}

/// The rope Bitsy hangs from: a thin twisted line from the top of the screen down to its hands.
final class RopePanel {
    private let panel: NSPanel
    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 6, height: 10), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false; panel.ignoresMouseEvents = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = RopeView(frame: NSRect(x: 0, y: 0, width: 6, height: 10))
    }
    /// x, from the top down to the hands (CG coords).
    func show(x: Double, top: Double, hands: Double, H: Double) {
        let h = max(1, hands - top)
        panel.setFrame(NSRect(x: (x - 3).rounded(), y: (H - hands).rounded(), width: 6, height: h.rounded()), display: true)
        panel.orderFrontRegardless()
    }
    func hide() { panel.orderOut(nil) }
}

final class RopeView: NSView {
    override func draw(_ r: NSRect) {
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setFillColor(rgb(0xCDBFAE)); ctx.fill(CGRect(x: 1.5, y: 0, width: 3, height: bounds.height))
        ctx.setFillColor(rgb(0x9C8C78))   // the twist
        var y: CGFloat = 0
        while y < bounds.height { ctx.fill(CGRect(x: 1.5, y: y, width: 3, height: 2)); y += 7 }
    }
}

extension Pet {
    func agentEvent(_ kind: String, rect: CGRect?, url: String?) {
        switch kind {
        case "look", "read":
            guard let r = rect, mode != .drag, mode != .perch else {
                if mode == .perch { islandNote = (kind == "look" ? "Taking a photo for Claude" : "Reading for Claude", Date()) }
                return
            }
            startRope(r, photo: kind == "look")
        case "type_url":
            typeAddress(url ?? "")
        default: break
        }
    }

    // MARK: on a rope

    func startRope(_ r: CGRect, photo: Bool) {
        let screen = NSScreen.screens.map { world.toCG($0.frame) }.first { $0.intersects(r) } ?? world.toCG(NSScreen.main?.frame ?? .zero)
        rope = Rope(rect: r, top: Double(screen.minY), start: CACurrentMediaTime(), photo: photo, backX: x)
        mode = .rope; vx = 0; vy = 0; supportID = nil; supportRect = nil; walkTarget = nil; pendingHop = nil
        stats.close(); bubble.hide()
        x = Double(r.midX)
        go(.hang, 99)
        ropeStep()
    }

    /// 0–0.8 s down · look · (photo: flash at 1.3 s, holds it up) · from 1.8 s back up · drops home at 2.6 s.
    func ropeStep() {
        guard var rp = rope else { startFall(); return }
        let t = CACurrentMediaTime() - rp.start
        let down = rp.top - 120, low = Double(rp.rect.minY) + min(Double(rp.rect.height) * 0.3, 220)
        let ease = { (u: Double) -> Double in u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
        let hands: Double
        if t < 0.8 { hands = down + (low - down) * ease(t / 0.8) + 6 * sin(t * 9) * (1 - t / 0.8) }      // lowered, with a little bounce
        else if t < 1.8 { hands = low + 2 * sin(t * 2.4) }
        else { hands = low + (down - low) * ease(min(1, (t - 1.8) / 0.7)) }
        if rp.photo, !rp.flashed, t >= 1.3 {
            rp.flashed = true
            flash(rp.rect)
            NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif", byReference: true)?.play()
        }
        rope = rp
        y = hands + 69
        ropePanel.show(x: x, top: rp.top, hands: hands + 4, H: world.H)
        if t >= 2.6 {   // back to where it was: drop in from the top
            ropePanel.hide()
            let home = rp.backX
            rope = nil
            x = home; y = rp.top + 40
            startFall()
        }
    }

    /// Eyes on the window, a magnifying glass, and the photo once it's taken.
    func ropeDecorate(_ f: inout Frame) {
        guard let rp = rope else { return }
        let t = CACurrentMediaTime() - rp.start
        f.pose.lookY = 1; f.pose.look = 0
        f.pose.eyes = t > 0.8 && t < 1.8 ? .open : (t < 0.8 ? .wide : .happy)
        if t > 0.7 && t < (rp.photo ? 1.3 : 1.8) {
            f.fx.append(FX(g: "mag", x: 22 + (sin(t * 3) * 1.5).rounded(), y: 13, c: rgb(0xE8EEF5)))
        }
        if rp.photo && t >= 1.3 { f.fx.append(FX(g: "photo", x: 23, y: 12, c: rgb(0xFFFFFF))) }
    }

    func flash(_ r: CGRect) {
        let p = NSPanel(contentRect: NSRect(x: r.minX, y: world.H - r.maxY, width: r.width, height: r.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.backgroundColor = .white; p.level = .floating; p.alphaValue = 0.8; p.ignoresMouseEvents = true
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.45; p.animator().alphaValue = 0 }) { p.orderOut(nil) }
    }

    // MARK: typing an address

    func typeAddress(_ address: String) {
        let text = String(address.prefix(40))
        if mode == .ground { walkTarget = nil; pendingHop = nil; go(.work, 2.2) }
        if mode == .perch { islandNote = ("Opening " + text, Date()); return }
        for i in 0...text.count {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) { [weak self] in
                self?.bubble.show("Opening", String(text.prefix(i)) + (i < text.count ? "▌" : ""), seconds: 1.6)
            }
        }
    }

    // MARK: Ask Claude…

    /// Type a question; it goes to your Claude chat together with a picture of the window you're on.
    func askClaude() {
        let target = shareableWindow   // before the question box takes focus
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Ask Claude"
        a.informativeText = "Your question goes to your Claude chat with a picture of the window you're on."
        a.addButton(withTitle: "Ask"); a.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "What's wrong with this page?"
        a.accessoryView = field
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard let claude = NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first else {
            bubble.show("Open Claude first", "Then ask again.", seconds: 4); return
        }
        guard AXIsProcessTrusted() else {
            bubble.show("Needs Accessibility", "Allow \(name) under Accessibility so it can paste into Claude.", seconds: 6); return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var captured = false
            if let id = target, CGPreflightScreenCaptureAccess() {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                p.arguments = ["-x", "-o", "-c", "-l", "\(id)"]
                try? p.run(); p.waitUntilExit()
                captured = p.terminationStatus == 0
            }
            DispatchQueue.main.async {
                claude.activate()
                let after = { (s: Double, f: @escaping () -> Void) in DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
                if captured { after(0.5) { Pet.press(9, cmd: true) } }                    // the picture
                after(captured ? 1.0 : 0.5) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(q, forType: .string)
                    Pet.press(9, cmd: true)                                               // the question
                }
                after(captured ? 1.4 : 0.9) { Pet.press(36, cmd: false) }                 // send
                if self.mode == .ground { self.go(.wave, 1.6) }
                self.bubble.show("Asked Claude", q, seconds: 3)
            }
        }
    }

    static func press(_ key: CGKeyCode, cmd: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            if cmd { e?.flags = .maskCommand }
            e?.post(tap: .cghidEventTap)
        }
    }

    // MARK: spotting errors

    /// Reads the terminal or editor in front; a new error line makes Bitsy jump and offer to send it to Claude.
    func spotErrors() {
        guard !errorCheckBusy, AXIsProcessTrusted(), let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return }
        errorCheckBusy = true
        DispatchQueue.global(qos: .utility).async {
            let text = String((AXReader.read(pid: pid, limit: 12_000)["text"] as? String ?? "").suffix(1500))
            let pattern = #"(^|\s)(error|Error|ERROR)(\[|:)|Traceback \(most recent call last\)|Exception:|\bFAILED\b|^fatal:|panic:|npm ERR!"#
            let hit = text.split(separator: "\n").map(String.init).last { $0.range(of: pattern, options: .regularExpression) != nil }
            DispatchQueue.main.async {
                self.errorCheckBusy = false
                guard let hit else { self.errorPIDs.insert(pid); return }
                let sig = "\(pid)|\(hit)"
                guard self.errorPIDs.contains(pid) else { self.errorPIDs.insert(pid); self.seenErrors.insert(sig); return }   // old errors don't count
                guard self.seenErrors.insert(sig).inserted, self.mode != .perch else { return }
                if self.mode == .ground { self.walkTarget = nil; self.pendingHop = nil; self.go(.surprised, 1.2) }
                let line = String(hit.trimmingCharacters(in: .whitespaces).prefix(90))
                self.bubble.show("Spotted an error", line + "\nClick here to send it to Claude", seconds: 8) { [weak self] in self?.shareWindow() }
            }
        }
    }
}
