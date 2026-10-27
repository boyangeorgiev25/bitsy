import Foundation
import BitsyKit

// Bitsy's fan helper. Runs as root from /Library/LaunchDaemons and does exactly three things:
// report fan status, force a speed between each fan's own minimum and maximum, or hand fans back to macOS.
// Only the user who installed it (and root) may talk to it, and manual speeds expire unless renewed.

signal(SIGPIPE, SIG_IGN)
let args = CommandLine.arguments
let allowedUID: uid_t? = args.firstIndex(of: "--uid").flatMap { $0 + 1 < args.count ? UInt32(args[$0 + 1]) : nil }

guard getuid() == 0 else { fputs("bitsy-fand must run as root\n", stderr); exit(1) }
guard let smc = SMC() else { fputs("bitsy-fand: can't open AppleSMC\n", stderr); exit(1) }

let q = DispatchQueue(label: "io.bitsy.fand")
var manualPct: Double?
var leaseUntil = Date.distantPast

func applyAuto() {
    for f in smc.fans() { smc.setNumber(smc.modeKey(f.index), 0) }
    if smc.exists("Ftst") { smc.setNumber("Ftst", 0) }
    manualPct = nil
}

@discardableResult
func applyManual(_ pct: Double) -> Bool {
    if smc.exists("Ftst") { smc.setNumber("Ftst", 1) }
    var ok = true
    for f in smc.fans() {
        let rpm = f.min + (f.max - f.min) * max(0, min(1, pct / 100))   // never below the fan's own minimum
        if !smc.setNumber(smc.modeKey(f.index), 1) { ok = false }
        if !smc.setNumber("F\(f.index)Tg", rpm) { ok = false }
    }
    return ok
}

struct Status: Codable { var manual: Bool; var pct: Double?; var fans: [Fan] }

func handle(_ line: String) -> String {
    let parts = line.split(separator: " ")
    switch parts.first.map(String.init) {
    case "status":
        let data = (try? JSONEncoder().encode(Status(manual: manualPct != nil, pct: manualPct, fans: smc.fans()))) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    case "set":
        guard parts.count == 2, let v = Double(parts[1]), v.isFinite else { return "error expected: set <0-100>" }
        let pct = max(0, min(100, v))
        leaseUntil = Date().addingTimeInterval(FanHelper.leaseSeconds)
        manualPct = pct
        return applyManual(pct) ? "ok" : "error SMC refused the write"
    case "auto":
        leaseUntil = .distantPast
        applyAuto()
        return "ok"
    default:
        return "error unknown command"
    }
}

// Start from a clean state, and always give the fans back on the way out.
q.sync { applyAuto() }
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: q)
term.setEventHandler { applyAuto(); exit(0) }
term.resume()

// Lease: drop back to automatic when Bitsy stops renewing; otherwise keep re-asserting the speed.
let lease = DispatchSource.makeTimerSource(queue: q)
lease.schedule(deadline: .now() + 2, repeating: 2)
lease.setEventHandler {
    guard let pct = manualPct else { return }
    if Date() > leaseUntil { applyAuto() } else if smc.fans().contains(where: { !$0.manual }) { applyManual(pct) }
}
lease.resume()

// Socket
unlink(FanHelper.socketPath)
let server = socket(AF_UNIX, SOCK_STREAM, 0)
var addr = FanHelper.sockaddr(FanHelper.socketPath)
let bound = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
}
guard server >= 0, bound == 0, listen(server, 8) == 0 else { fputs("bitsy-fand: can't listen\n", stderr); exit(1) }
chmod(FanHelper.socketPath, 0o666)   // anyone may connect; the peer's uid is checked below

Thread.detachNewThread {
    while true {
        let c = accept(server, nil, nil)
        if c < 0 { continue }
        var uid: uid_t = 0, gid: gid_t = 0
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var reply = "error not allowed"
        if getpeereid(c, &uid, &gid) == 0, uid == 0 || uid == allowedUID {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = read(c, &buf, buf.count - 1)
            if n > 0, let line = String(bytes: buf[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                reply = q.sync { handle(line) }
            }
        }
        let out = Array((reply + "\n").utf8)
        _ = write(c, out, out.count)
        close(c)
    }
}

dispatchMain()
