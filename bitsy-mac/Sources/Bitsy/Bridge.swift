import AppKit
import ApplicationServices
import SwiftUI
import BitsyKit

// Answers bitsy-mcp (your Claude agent) over a private socket: read a window's text, the clipboard, say something
// in Bitsy's bubble, and click or scroll — those two only after you press Allow.

final class BridgeServer {
    weak var pet: Pet?
    private var fd: Int32 = -1

    func start() {
        let path = Bridge.socketPath
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        guard let fd = Unix.listen(path, mode: 0o600) else { return }
        self.fd = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            let c = accept(fd, nil, nil)
            if c < 0 { continue }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(c, &uid, &gid) == 0, uid == getuid() else { close(c); continue }   // only you
            DispatchQueue.global(qos: .userInitiated).async { self.serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var tv = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var buf = [UInt8](), chunk = [UInt8](repeating: 0, count: 4096)
        while !buf.contains(0x0A) {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { break }
            buf += chunk[0..<n]
        }
        guard let msg = (try? JSONSerialization.jsonObject(with: Data(buf))) as? [String: Any],
              let cmd = msg["cmd"] as? String else { return }
        let reply = handle(cmd, msg)
        guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        data.append(0x0A)
        _ = Unix.writeAll(c, [UInt8](data))
    }

    private func handle(_ cmd: String, _ msg: [String: Any]) -> [String: Any] {
        switch cmd {
        case "read_window":
            guard let pid = DispatchQueue.main.sync(execute: { targetPID(msg["app"] as? String) }) else { return ["error": "No app called \(msg["app"] ?? "") is running."] }
            return AXReader.read(pid: pid)
        case "clipboard":
            return DispatchQueue.main.sync { clipboard() }
        case "capture":   // Bitsy has Screen Recording, so any Claude app can see through it without its own permission
            let args: [String]
            if let id = msg["window_id"] as? Int { args = ["-o", "-l", "\(id)"] }
            else if let d = msg["display"] as? Int { args = ["-D", "\(d)"] }
            else { return ["error": "Say which window or display."] }
            let path = NSTemporaryDirectory() + "bitsy-capture-\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = ["-x", "-t", "png"] + args + [path]
            try? p.run(); p.waitUntilExit()
            guard let png = NSImage(contentsOfFile: path)?.downscaledPNG(maxSide: 1568) else { return ["error": "Screenshot failed."] }
            return ["png": png.base64EncodedString()]
        case "say":
            let text = (msg["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return ["error": "Nothing to say."] }
            let title = (msg["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Claude"
            DispatchQueue.main.async { self.pet?.sayFromClaude(title, text) }
            return ["ok": true]
        case "click", "scroll":
            return act(cmd, msg)
        case "elements":
            guard let pid = DispatchQueue.main.sync(execute: { targetPID(msg["app"] as? String) }) else { return ["error": "No app called \(msg["app"] ?? "") is running."] }
            return Elements.list(pid: pid, query: msg["query"] as? String)
        case "press":
            return press(msg["ref"] as? Int ?? 0)
        case "event":   // what the agent is doing, for Bitsy to act out
            let r = (msg["rect"] as? [Double]).flatMap { $0.count == 4 ? CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) : nil }
            let kind = msg["kind"] as? String ?? "", url = msg["url"] as? String
            DispatchQueue.main.async { self.pet?.agentEvent(kind, rect: r, url: url) }
            return ["ok": true]
        default:
            return ["error": "Unknown request."]
        }
    }

    /// The named running app (by name, loosely), else the app you're using.
    private func targetPID(_ name: String?) -> pid_t? {
        let ws = NSWorkspace.shared
        guard let q = name?.lowercased(), !q.isEmpty else { return ws.frontmostApplication?.processIdentifier }
        let apps = ws.runningApplications.filter { $0.activationPolicy == .regular }
        return (apps.first { $0.localizedName?.lowercased() == q } ?? apps.first { $0.localizedName?.lowercased().contains(q) == true })?.processIdentifier
    }

    private func clipboard() -> [String: Any] {
        let pb = NSPasteboard.general
        var r: [String: Any] = [:]
        if let s = pb.string(forType: .string), !s.isEmpty { r["text"] = String(s.prefix(60_000)) }
        if let img = NSImage(pasteboard: pb), let png = img.downscaledPNG(maxSide: 1568) { r["image_png"] = png.base64EncodedString() }
        if r.isEmpty { r["empty"] = true }
        return r
    }

    // MARK: click and scroll, after you allow it

    private func act(_ cmd: String, _ msg: [String: Any]) -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": "Bitsy needs Accessibility permission to click or scroll."] }
        guard let wid = msg["window_id"] as? Int, let (r, pid) = windowInfo(wid) else { return ["error": "That window isn't on screen."] }
        let fx = min(max(msg["x"] as? Double ?? 0.5, 0), 1), fy = min(max(msg["y"] as? Double ?? 0.5, 0), 1)
        let point = CGPoint(x: r.minX + r.width * fx, y: r.minY + r.height * fy)
        let lines = Int(msg["amount"] as? Double ?? 5)
        let what = cmd == "click" ? "click here" : (lines >= 0 ? "scroll down" : "scroll up")
        let owner = NSRunningApplication(processIdentifier: pid)
        let app = owner?.localizedName ?? (msg["app_name"] as? String) ?? "this window"
        let bundle = owner?.bundleIdentifier

        if let denied = approve(what, app: app, bundle: bundle, at: point) { return denied }
        return perform(cmd, at: point, lines: lines)
    }

    /// Your say-so: nothing for apps you always allow (only the ring on the spot), else Allow / Deny on screen.
    /// Returns why not, or nil to go ahead.
    private func approve(_ what: String, app: String, bundle: String?, at point: CGPoint) -> [String: Any]? {
        if let bundle, ClickTrust.allowed(bundle) {
            // you said Always for this app: just mark the spot so you see where
            DispatchQueue.main.async { self.pet?.confirm.mark(point) }
            usleep(450_000)
        } else {
            // ask on screen, wait for the answer (30 s, then no)
            let sem = DispatchSemaphore(value: 0)
            var allowed = false
            DispatchQueue.main.async {
                self.pet?.confirm.ask("Claude wants to \(what) in \(app)", at: point, always: bundle == nil ? nil : app) { ok, always in
                    allowed = ok
                    if ok, always, let bundle { ClickTrust.add(bundle) }
                    sem.signal()
                }
            }
            if sem.wait(timeout: .now() + 30) == .timedOut {
                DispatchQueue.main.async { self.pet?.confirm.dismiss() }
                return ["error": "You didn't answer, so nothing was done."]
            }
            guard allowed else { return ["denied": true, "message": "You chose Deny, so nothing was done."] }
        }
        return nil
    }

    /// Press an element from the last list: the app's own Press action, or a real click on it if it has none.
    private func press(_ ref: Int) -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": "Bitsy needs Accessibility permission."] }
        guard let (el, pid, r) = Elements.get(ref) else { return ["error": "No element [\(ref)] any more. List the elements again."] }
        if Elements.isSecure(el) { return ["error": "That's a password field. The user types passwords themselves."] }
        let owner = NSRunningApplication(processIdentifier: pid)
        let app = owner?.localizedName ?? "this app"
        let point = CGPoint(x: r.midX, y: r.midY)
        let name = Elements.describe(el)
        if let denied = approve("press \(name)", app: app, bundle: owner?.bundleIdentifier, at: point) { return denied }
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return ["ok": true, "pressed": name] }
        _ = perform("click", at: point, lines: 0)
        return ["ok": true, "clicked": name]
    }

    private func perform(_ cmd: String, at point: CGPoint, lines: Int) -> [String: Any] {

        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(80_000)
        if cmd == "click" {
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(50_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            return ["ok": true, "clicked": ["x": Int(point.x), "y": Int(point.y)]]
        }
        for _ in 0..<abs(lines) {   // a line at a time reads as real scrolling
            CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: lines > 0 ? -3 : 3, wheel2: 0, wheel3: 0)?.post(tap: .cghidEventTap)
            usleep(25_000)
        }
        return ["ok": true, "scrolled": lines]
    }

    private func windowInfo(_ id: Int) -> (CGRect, pid_t)? {
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first,
              let bd = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
              let pid = w[kCGWindowOwnerPID as String] as? pid_t else { return nil }
        return (r, pid)
    }
}

/// Apps where you chose "Always allow": Claude's clicks and scrolls there go ahead without asking.
enum ClickTrust {
    private static let key = "alwaysAllowClicks"
    static var apps: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func allowed(_ bundle: String) -> Bool { apps.contains(bundle) }
    static func add(_ bundle: String) { if !allowed(bundle) { UserDefaults.standard.set(apps + [bundle], forKey: key) } }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: reading a window's text (Accessibility)

enum AXReader {
    /// The window's title, its web address when it is a browser, and its text in reading order (capped).
    static func read(pid: pid_t, limit: Int = 20_000) -> [String: Any] {
        guard AXIsProcessTrusted() else { return ["error": "Bitsy needs Accessibility permission to read window text."] }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.6)
        var r: [String: Any] = ["app": NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"]
        guard let win = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) else {
            r["error"] = "That app has no window open."; return r
        }
        let root = win as! AXUIElement
        if let t = attr(root, kAXTitleAttribute) as? String { r["title"] = t }
        var (text, url) = walk(root, limit: limit)
        // Browsers build a page's accessibility tree on first request: give it a moment and read again.
        if url == nil, let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
           ["com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "com.microsoft.edgemac", "com.brave.Browser", "org.mozilla.firefox"].contains(id) {
            Thread.sleep(forTimeInterval: 0.6)
            (text, url) = walk(root, limit: limit)
        }
        // Electron and Chrome only build their accessibility tree once someone asks for it.
        if text.isEmpty, AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue) == .success {
            Thread.sleep(forTimeInterval: 0.8)
            (text, url) = walk(root, limit: limit)
        }
        if let url { r["url"] = url }
        r["text"] = text
        return r
    }

    private static func walk(_ root: AXUIElement, limit: Int) -> (String, String?) {
        var parts: [String] = [], total = 0, nodes = 0, url: String?
        var stack: [AXUIElement] = [root]
        let deadline = Date().addingTimeInterval(2.5)
        while let el = stack.popLast(), nodes < 8000, total < limit, Date() < deadline {
            nodes += 1
            let role = attr(el, kAXRoleAttribute) as? String ?? ""
            if role == "AXWebArea", url == nil, let u = attr(el, "AXURL") { url = (u as? URL)?.absoluteString ?? "\(u)" }
            if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading", "AXLink"].contains(role),
               var s = attr(el, kAXValueAttribute) as? String ?? (role == "AXStaticText" || role == "AXLink" ? attr(el, kAXTitleAttribute) as? String ?? attr(el, kAXDescriptionAttribute) as? String : nil) {
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if role == "AXTextArea", s.count > 8000 { s = "…" + String(s.suffix(8000)) }   // terminals: the latest output
                if !s.isEmpty, s != parts.last { parts.append(s); total += s.count }
            }
            if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] { stack.append(contentsOf: kids.reversed()) }
        }
        return (String(parts.joined(separator: "\n").prefix(limit)), url)
    }

    static func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }
}

extension NSImage {
    func downscaledPNG(maxSide: CGFloat) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let s = min(1, maxSide / CGFloat(max(cg.width, cg.height)))
        let w = Int(CGFloat(cg.width) * s), h = Int(CGFloat(cg.height) * s)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:])
    }
}

// MARK: Allow / Deny, with a marker on the exact spot

final class ConfirmModel: ObservableObject {
    @Published var text = ""
    @Published var alwaysApp: String?   // offer "Always allow in <app>"
    var answer: (Bool, Bool) -> Void = { _, _ in }
}

struct ConfirmView: View {
    @ObservedObject var m: ConfirmModel
    private let accent = Color(cgColor: pal.body)
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cursorarrow.click.2").foregroundColor(accent)
                Text(m.text).font(.system(size: 13, weight: .semibold)).foregroundColor(.white).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                button("Deny", fill: Color.white.opacity(0.1), ink: .white) { m.answer(false, false) }
                button("Allow", fill: accent, ink: .black) { m.answer(true, false) }
            }
            if let app = m.alwaysApp {
                Button { m.answer(true, true) } label: {
                    Text("Always allow in \(app)").font(.system(size: 11.5, weight: .medium)).foregroundColor(accent)
                        .frame(maxWidth: .infinity).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(14).frame(width: 280)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(red: 0.12, green: 0.115, blue: 0.11)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(accent.opacity(0.6)))
    }
    private func button(_ t: String, fill: Color, ink: Color, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Text(t).font(.system(size: 12.5, weight: .semibold)).foregroundColor(ink)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(fill)).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

final class TargetView: NSView {
    override func draw(_ r: NSRect) {
        let c = pal.body
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.setStrokeColor(c); ctx.setLineWidth(4)
        ctx.strokeEllipse(in: bounds.insetBy(dx: 6, dy: 6))
        ctx.setFillColor(c); ctx.fillEllipse(in: CGRect(x: bounds.midX - 5, y: bounds.midY - 5, width: 10, height: 10))
    }
}

final class ConfirmController {
    private let model = ConfirmModel()
    private let panel: NSPanel
    private let marker: NSPanel

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 280, height: 100), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ConfirmView(m: model))
        marker = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: true)
        marker.isOpaque = false; marker.backgroundColor = .clear; marker.ignoresMouseEvents = true
        marker.level = .statusBar; marker.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        marker.contentView = TargetView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
    }

    /// Shows the request next to the spot (CG coords). `done(true)` only when you press Allow.
    func ask(_ text: String, at p: CGPoint, always app: String?, done: @escaping (Bool, Bool) -> Void) {
        let H = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = NSPoint(x: p.x, y: H - p.y)
        marker.setFrameOrigin(NSPoint(x: cocoa.x - 32, y: cocoa.y - 32))
        marker.orderFrontRegardless()
        model.text = text
        model.alwaysApp = app
        model.answer = { [weak self] ok, always in self?.dismiss(); done(ok, always) }
        let size = (panel.contentView as! NSHostingView<ConfirmView>).fittingSize
        let vf = (NSScreen.screens.first { $0.frame.contains(cocoa) } ?? NSScreen.main)?.visibleFrame ?? .zero
        let ox = min(max(cocoa.x - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        var oy = cocoa.y + 44
        if oy + size.height > vf.maxY { oy = cocoa.y - 44 - size.height }
        panel.setFrame(NSRect(x: ox, y: max(vf.minY + 8, oy), width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
        NSSound(named: "Tink")?.play()
    }

    func dismiss() { panel.orderOut(nil); marker.orderOut(nil) }

    /// Only the ring on the spot, for a moment (apps you always allow).
    func mark(_ p: CGPoint) {
        let H = NSScreen.screens.first?.frame.height ?? 0
        marker.setFrameOrigin(NSPoint(x: p.x - 32, y: H - p.y - 32))
        marker.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in self?.marker.orderOut(nil) }
    }
}

// MARK: Claude talking through Bitsy

extension Pet {
    /// A message from your Claude agent, in Bitsy's bubble (or the island when Bitsy is in the notch).
    func sayFromClaude(_ title: String, _ text: String) {
        let short = text.count > 140 ? String(text.prefix(138)) + "…" : text
        bubble.show(title, short, seconds: min(12, max(4, Double(short.count) / 12)))
        islandNote = (title + ": " + short, Date())
        if mode == .ground { walkTarget = nil; pendingHop = nil; go(.wave, 1.8) }
    }
}
