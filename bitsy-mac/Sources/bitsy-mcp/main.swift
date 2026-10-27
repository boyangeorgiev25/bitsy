import AppKit
import BitsyKit

// Bitsy MCP server (stdio, newline-delimited JSON-RPC).
// Gives an agent what's on your screen so you don't have to describe it or paste screenshots.

let sys = SystemStats()

func out(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: d, encoding: .utf8) else { return }
    FileHandle.standardOutput.write((s + "\n").data(using: .utf8)!)
}

func json(_ obj: Any) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    return String(data: d, encoding: .utf8) ?? "{}"
}

func rect(_ r: CGRect) -> [String: Int] { ["x": Int(r.minX), "y": Int(r.minY), "w": Int(r.width), "h": Int(r.height)] }

struct Win { let id: Int; let pid: Int32; let app: String; let title: String?; let bounds: CGRect }

/// Normal app windows on the current Space, front to back.
func listWindows() -> [Win] {
    let mine = ProcessInfo.processInfo.processIdentifier
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
    return list.compactMap { w in
        guard (w[kCGWindowLayer as String] as? Int) == 0,
              let pid = w[kCGWindowOwnerPID as String] as? Int32, pid != mine,
              let bd = w[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: bd as CFDictionary), r.width >= 80, r.height >= 40,
              let id = w[kCGWindowNumber as String] as? Int else { return nil }
        let app = w[kCGWindowOwnerName as String] as? String ?? "?"
        if app == "Bitsy" { return nil }
        let title = (w[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Win(id: id, pid: pid, app: app, title: title, bounds: r)
    }
}

func displays() -> [[String: Any]] {
    let H = NSScreen.screens.first?.frame.height ?? 0
    return NSScreen.screens.enumerated().map { i, s in
        let f = s.frame
        return ["index": i, "name": s.localizedName, "main": i == 0,
                "frame": rect(CGRect(x: f.minX, y: H - f.maxY, width: f.width, height: f.height)),
                "scale": s.backingScaleFactor]
    }
}

func displayIndex(of r: CGRect) -> Int? {
    let H = NSScreen.screens.first?.frame.height ?? 0
    let c = NSPoint(x: r.midX, y: H - r.midY)
    return NSScreen.screens.firstIndex { $0.frame.contains(c) }
}

func screenContext() -> [String: Any] {
    _ = sys.cpu()
    let front = NSWorkspace.shared.frontmostApplication
    let wins = listWindows()
    let active = wins.first { $0.pid == front?.processIdentifier }
    let canSeeTitles = CGPreflightScreenCaptureAccess()
    let since = { (t: CGEventType) in Int(CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: t)) }
    let mouse = NSEvent.mouseLocation, H = NSScreen.screens.first?.frame.height ?? 0
    Thread.sleep(forTimeInterval: 0.25)   // short CPU sample window
    let mem = sys.memory(), bat = sys.battery()

    var ctx: [String: Any] = [
        "time": ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime]),
        "frontmost_app": ["name": front?.localizedName ?? "?", "bundle_id": front?.bundleIdentifier ?? "?"],
        "windows": wins.prefix(25).map { w -> [String: Any] in
            var d: [String: Any] = ["id": w.id, "app": w.app, "bounds": rect(w.bounds)]
            if let t = w.title { d["title"] = t }
            if let i = displayIndex(of: w.bounds) { d["display"] = i }
            return d
        },
        "displays": displays(),
        "user_activity": [
            "seconds_since_keypress": since(.keyDown),
            "seconds_since_mouse_move": since(.mouseMoved),
            "typing_now": since(.keyDown) < 3,
            "mouse": ["x": Int(mouse.x), "y": Int(H - mouse.y)],
        ],
        "system": [
            "cpu_percent": Int((sys.cpu() * 100).rounded()),
            "memory_used_gb": NSDecimalNumber(string: String(format: "%.1f", mem.used / 1_073_741_824)),
            "memory_total_gb": (mem.total / 1_073_741_824).rounded(),
            "battery_percent": bat.map { $0.pct as Any } ?? NSNull(),
            "charging": bat?.charging ?? false,
            "fans": (SMC()?.fans() ?? []).map { ["rpm": Int($0.rpm), "min_rpm": Int($0.min), "max_rpm": Int($0.max), "manual": $0.manual] as [String: Any] },
            "uptime_hours": NSDecimalNumber(string: String(format: "%.1f", ProcessInfo.processInfo.systemUptime / 3600)),
        ],
        "coordinates": "Global screen points, origin top-left of the main display.",
    ]
    if let a = active {
        var d: [String: Any] = ["id": a.id, "app": a.app, "bounds": rect(a.bounds)]
        if let t = a.title { d["title"] = t }
        ctx["active_window"] = d
    }
    if !canSeeTitles {
        ctx["note"] = "Window titles are hidden and screenshots will be blank until the app running this server has Screen Recording permission (System Settings > Privacy & Security > Screen & System Audio Recording)."
    }
    return ctx
}

/// Captures a window or display to PNG, scaled down to a long edge of 1568 px.
func screenshot(_ args: [String: Any]) -> (Data?, String) {
    let target = args["target"] as? String ?? "active_window"
    let path = NSTemporaryDirectory() + "bitsy-shot-\(UUID().uuidString).png"
    var cmd = ["-x", "-t", "png"]
    var label = ""
    switch target {
    case "screen":
        let d = (args["display"] as? Int ?? 0) + 1
        cmd += ["-D", "\(d)"]
        label = "display \(d - 1)"
    default:
        let wins = listWindows()
        let id = args["window_id"] as? Int
            ?? wins.first(where: { $0.pid == NSWorkspace.shared.frontmostApplication?.processIdentifier })?.id
        guard let id, let w = wins.first(where: { $0.id == id }) else { return (nil, "No matching window on screen.") }
        cmd += ["-o", "-l", "\(id)"]
        label = "\(w.app)\(w.title.map { " — \($0)" } ?? "")"
    }
    func run(_ exe: String, _ a: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = a
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
    run("/usr/sbin/screencapture", cmd + [path])
    run("/usr/bin/sips", ["-Z", "1568", path])
    defer { try? FileManager.default.removeItem(atPath: path) }
    guard let data = FileManager.default.contents(atPath: path) else {
        return (nil, "Screenshot failed. The app running this server probably needs Screen Recording permission.")
    }
    return (data, "Screenshot of \(label).")
}

let tools: [[String: Any]] = [
    [
        "name": "get_screen_context",
        "description": "What the user is looking at right now on their Mac: frontmost app, the active window (title, bounds), all visible windows front to back, displays, whether they are typing, mouse position, and CPU/memory/battery. Call this instead of asking the user to describe their screen.",
        "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
        "name": "screenshot",
        "description": "Take a screenshot of the user's active window (default), a specific window by id from get_screen_context, or a whole display. Use when you need to see the content, not just the window titles.",
        "inputSchema": [
            "type": "object",
            "properties": [
                "target": ["type": "string", "enum": ["active_window", "window", "screen"], "description": "What to capture. Default active_window."],
                "window_id": ["type": "integer", "description": "Window id from get_screen_context (with target=window)."],
                "display": ["type": "integer", "description": "Display index from get_screen_context (with target=screen). Default 0."],
            ],
        ],
    ],
]

func handle(_ msg: [String: Any]) {
    guard let method = msg["method"] as? String else { return }
    let id = msg["id"]
    func reply(_ result: [String: Any]) { if let id { out(["jsonrpc": "2.0", "id": id, "result": result]) } }
    func fail(_ code: Int, _ m: String) { if let id { out(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": m]]) } }

    switch method {
    case "initialize":
        let params = msg["params"] as? [String: Any]
        reply([
            "protocolVersion": params?["protocolVersion"] as? String ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "bitsy", "version": "0.1"],
            "instructions": "Bitsy can see the user's Mac screen. Prefer get_screen_context before asking the user what app, window or page they are on; use screenshot when you need to read the window's content.",
        ])
    case "ping":
        reply([:])
    case "tools/list":
        reply(["tools": tools])
    case "tools/call":
        let params = msg["params"] as? [String: Any] ?? [:]
        let args = params["arguments"] as? [String: Any] ?? [:]
        switch params["name"] as? String {
        case "get_screen_context":
            reply(["content": [["type": "text", "text": json(screenContext())]]])
        case "screenshot":
            let (data, text) = screenshot(args)
            if let data {
                reply(["content": [["type": "image", "data": data.base64EncodedString(), "mimeType": "image/png"], ["type": "text", "text": text]]])
            } else {
                reply(["content": [["type": "text", "text": text]], "isError": true])
            }
        default:
            fail(-32602, "Unknown tool")
        }
    default:
        if id != nil { fail(-32601, "Method not found: \(method)") }
    }
}

setvbuf(stdout, nil, _IONBF, 0)
while let line = readLine() {
    guard let d = line.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
    handle(msg)
}
