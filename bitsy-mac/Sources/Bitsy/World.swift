import AppKit
import ApplicationServices

// Things Bitsy can stand on, in global CG coordinates (origin top-left of the main display, y down).
// Negative ids are screen floors (top of the Dock / bottom of the screen); others are window numbers.
struct Platform { let id: Int; let x0: Double; let x1: Double; let y: Double }

final class World {
    var platforms: [Platform] = []
    var windows: [Int: CGRect] = [:]
    var order: [Int] = []                 // window numbers front to back
    var visible: [CGRect] = []

    enum Edge { case top, bottom }
    var includeWindows = true
    var activeID: Int?
    private(set) var fullscreen = false   // an app is full screen on the display with the notch
    private(set) var dockFloorID = -1
    private var dock: CGRect?
    private var dockChecked = Date.distantPast
    private let pid = ProcessInfo.processInfo.processIdentifier

    var H: Double { Double(NSScreen.screens.first?.frame.height ?? 0) }
    var lowest: Double { NSScreen.screens.map { Double(toCG($0.frame).maxY) }.max() ?? 1000 }
    /// The floor Bitsy returns to: the Dock bar, or the bottom of the screen that has the Dock.
    var homeFloor: Platform? { platforms.first { $0.id == dockFloorID } ?? platforms.first { $0.id < 0 } }

    func toCG(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height) }
    func toCG(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: H - p.y) }

    func refresh() {
        visible = NSScreen.screens.map { toCG($0.visibleFrame) }
        if Date().timeIntervalSince(dockChecked) > 2 { dockChecked = Date(); dock = dockBar() }

        // Floors: the top of the Dock bar where it's showing, otherwise the very bottom of each screen.
        var plats: [Platform] = []
        for (i, scr) in NSScreen.screens.enumerated() {
            let f = toCG(scr.frame), id = -(i + 1)
            if let d = dock, f.contains(CGPoint(x: d.midX, y: d.midY)) {
                plats.append(Platform(id: id, x0: Double(d.minX) + 6, x1: Double(d.maxX) - 6, y: Double(d.minY)))
                dockFloorID = id
            } else {
                plats.append(Platform(id: id, x0: Double(f.minX), x1: Double(f.maxX), y: Double(f.maxY)))
                if i == 0 && dock == nil { dockFloorID = id }
            }
        }
        var wins: [Int: CGRect] = [:]
        var ord: [Int] = []
        var full = false
        let notchScreen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 }.map { (toCG($0.frame), $0.safeAreaInsets.top) }
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        activeID = nil

        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
            var front: [CGRect] = []   // the list is ordered front to back
            for w in list {
                guard (w[kCGWindowLayer as String] as? Int) == 0,
                      let owner = w[kCGWindowOwnerPID as String] as? Int32, owner != pid,
                      let bd = w[kCGWindowBounds as String] as? NSDictionary,
                      let r = CGRect(dictionaryRepresentation: bd as CFDictionary),
                      let num = w[kCGWindowNumber as String] as? Int else { continue }
                if (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.1 || r.width < 160 || r.height < 80 { continue }
                defer { front.append(r) }
                wins[num] = r
                ord.append(num)
                if let (f, top) = notchScreen, abs(r.width - f.width) < 2, r.minY <= f.minY + top + 1, r.maxY >= f.maxY - 1 { full = true }
                if activeID == nil && owner == frontPID { activeID = num }   // frontmost window of the app you're using
                if !includeWindows { continue }

                // the parts of the top edge you can see; background windows count too
                var segs = [(Double(r.minX), Double(r.maxX))]
                for f in front where f.minY < r.minY - 2 && f.maxY > r.minY + 2 {
                    segs = subtract(segs, Double(f.minX), Double(f.maxX))
                }
                for v in visible where r.minY >= v.minY + 70 && r.minY <= v.maxY - 40 {
                    for (a, b) in segs {
                        let s = max(a, Double(v.minX)), e = min(b, Double(v.maxX))
                        if e - s >= 60 { plats.append(Platform(id: num, x0: s, x1: e, y: Double(r.minY))) }
                    }
                }
            }
        }
        platforms = plats
        windows = wins
        order = ord
        fullscreen = full
    }

    /// The visible stretches of a window's top or bottom edge: on a screen and not behind another window.
    /// Unlike `platforms` this ignores headroom, so a window pushed up against the menu bar still has one
    /// (Bitsy can hang from it even when it can't stand on it).
    func edgeSegments(_ id: Int, _ edge: Edge) -> [(Double, Double)] {
        guard let r = windows[id] else { return [] }
        let ey = Double(edge == .top ? r.minY : r.maxY)
        var segs = [(Double(r.minX), Double(r.maxX))]
        for f in order.prefix(while: { $0 != id }).compactMap({ windows[$0] }) where Double(f.minY) < ey - 2 && Double(f.maxY) > ey + 2 {
            segs = subtract(segs, Double(f.minX), Double(f.maxX))
        }
        var out: [(Double, Double)] = []
        for v in visible where ey >= Double(v.minY) - 1 && ey <= Double(v.maxY) + 1 {
            for (a, b) in segs {
                let s = max(a, Double(v.minX)), e = min(b, Double(v.maxX))
                if e - s >= 60 { out.append((s, e)) }
            }
        }
        return out
    }

    /// The Dock bar in CG coords, or nil when it's hidden or on the side of the screen.
    func dockBar() -> CGRect? {
        let prefs = UserDefaults(suiteName: "com.apple.dock")
        if prefs?.bool(forKey: "autohide") == true { return nil }
        if let o = prefs?.string(forKey: "orientation"), o != "bottom" { return nil }
        guard let scr = NSScreen.screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 8 }) else { return nil }
        if let exact = axDockFrame() { return exact }

        // Estimate from the Dock's settings: icon slots are tilesize + 4 wide, centered on the screen.
        let f = toCG(scr.frame), v = toCG(scr.visibleFrame)
        let tile = max(16, prefs?.double(forKey: "tilesize") ?? 48)
        let pinned = prefs?.array(forKey: "persistent-apps") as? [[String: Any]] ?? []
        let pinnedPaths = Set(pinned.compactMap { tile -> String? in
            guard let td = tile["tile-data"] as? [String: Any], let fd = td["file-data"] as? [String: Any],
                  let u = fd["_CFURLString"] as? String else { return nil }
            return URL(string: u)?.standardizedFileURL.path
        })
        let unpinned = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != "com.apple.finder"
                && !pinnedPaths.contains($0.bundleURL?.standardizedFileURL.path ?? "")
        }.count
        let showRecents = prefs?.object(forKey: "show-recents") == nil || prefs?.bool(forKey: "show-recents") == true
        let recents = showRecents ? min(3, (prefs?.array(forKey: "recent-apps") ?? []).count) : 0
        let others = (prefs?.array(forKey: "persistent-others") ?? []).count
        let slots = 1 + pinned.count + unpinned + recents + others + 1   // Finder … Trash
        let seps = 1 + (recents > 0 ? 1 : 0)
        let w = min(Double(f.width) - 8, Double(slots) * (tile + 4) + Double(seps) * 16 + 12)
        return CGRect(x: Double(f.midX) - w / 2, y: Double(v.maxY) + 3, width: w, height: tile + 12)
    }

    /// Exact Dock frame via Accessibility, when Bitsy has been allowed to use it.
    private func axDockFrame() -> CGRect? {
        guard AXIsProcessTrusted(),
              let dockApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        var kids: CFTypeRef?, pos: CFTypeRef?, size: CFTypeRef?
        let app = AXUIElementCreateApplication(dockApp.processIdentifier)
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
              let list = (kids as? [AXUIElement])?.first,
              AXUIElementCopyAttributeValue(list, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(list, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &sz), sz.width > 0 else { return nil }
        return CGRect(origin: p, size: sz)
    }

    /// Where the Dynamic Island docks, in CG coords: the real notch on a MacBook screen, or on a display without one
    /// a notch-sized spot hanging from the middle of the menu bar. `near`: the screen under that point; without it,
    /// the screen with a notch, else the main one.
    func notchRect(near p: CGPoint? = nil) -> CGRect? {
        let screens = NSScreen.screens
        let scr = p.flatMap { pt in screens.first { toCG($0.frame).contains(pt) } }
            ?? screens.first { $0.safeAreaInsets.top > 0 } ?? screens.first
        guard let scr else { return nil }
        let f = toCG(scr.frame)
        if scr.safeAreaInsets.top > 0 {
            let lw = scr.auxiliaryTopLeftArea?.width ?? 0, rw = scr.auxiliaryTopRightArea?.width ?? 0
            let w = f.width - lw - rw
            if w > 0, w < f.width / 2 { return CGRect(x: f.minX + lw, y: f.minY, width: w, height: scr.safeAreaInsets.top) }
        }
        let menuBottom = toCG(scr.visibleFrame).minY   // no notch: hang from the menu bar
        return CGRect(x: f.midX - 100, y: menuBottom, width: 200, height: 30)
    }

    /// Cheap single-window update so Bitsy can ride a window you're dragging between full refreshes.
    func track(_ id: Int) {
        guard id >= 0, let old = windows[id] else { return }
        guard let w = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]])?.first,
              (w[kCGWindowIsOnscreen as String] as? Bool) ?? false,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary) else {
            windows[id] = nil
            platforms.removeAll { $0.id == id }
            return
        }
        let dx = Double(r.minX - old.minX), dy = Double(r.minY - old.minY)
        if dx == 0 && dy == 0 { return }
        windows[id] = r
        platforms = platforms.map { $0.id == id ? Platform(id: id, x0: $0.x0 + dx, x1: $0.x1 + dx, y: $0.y + dy) : $0 }
    }

    /// First platform crossed when falling from `from` to `to` at `x`.
    func landing(x: Double, from: Double, to: Double, skipping: Int? = nil) -> Platform? {
        platforms.filter { $0.id != skipping && x >= $0.x0 && x <= $0.x1 && $0.y >= from - 0.5 && $0.y <= to }.min { $0.y < $1.y }
    }

    func platform(id: Int?, x: Double, y: Double) -> Platform? {
        platforms.first { $0.id == id && x >= $0.x0 - 12 && x <= $0.x1 + 12 && abs($0.y - y) < 40 }
    }

    private func subtract(_ segs: [(Double, Double)], _ a: Double, _ b: Double) -> [(Double, Double)] {
        var out: [(Double, Double)] = []
        for (s, e) in segs {
            if b <= s || a >= e { out.append((s, e)); continue }
            if a > s { out.append((s, a)) }
            if b < e { out.append((b, e)) }
        }
        return out
    }
}
