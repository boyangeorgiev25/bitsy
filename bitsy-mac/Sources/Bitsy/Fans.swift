import AppKit
import BitsyKit

// Fan presets and rules. Reading speeds needs nothing; changing them goes through the root helper,
// which Bitsy installs once with an admin password.

final class FanController {
    enum Mode: String, CaseIterable {
        case auto, smart, medium, high, max
        var label: String { ["auto": "Auto", "smart": "Smart", "medium": "Medium", "high": "High", "max": "Max"][rawValue]! }
        var pct: Double? { ["medium": 50, "high": 75, "max": 100][rawValue] }
    }

    struct State: Equatable {
        var fans: [Fan] = []
        var mode = Mode.auto
        var appliedPct: Double?          // nil: macOS is in charge
        var reason = ""
        var helperInstalled = false
        var helperRunning = false
        var error: String?
        var windy: Bool { fans.contains { $0.rpm > 3500 } }
    }

    private(set) var state = State()

    // settings
    var mode: Mode = .auto { didSet { save() } }
    var boostClaude = true { didSet { save() } }
    var boostCPU = true { didSet { save() } }
    var quietAtNight = true { didSet { save() } }
    var boostLevel = 100.0 { didSet { save() } }

    // what's going on, pushed from the main thread each tick
    private let lock = NSLock()
    private var claudeWorking = false, night = false
    func update(claudeWorking: Bool, night: Bool) {
        lock.lock(); self.claudeWorking = claudeWorking; self.night = night; lock.unlock()
    }

    private let smc = SMC()
    private let sys = SystemStats()
    private var cpuAvg = 0.0
    private var sentAuto = false
    private let q = DispatchQueue(label: "bitsy.fans", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let d = UserDefaults.standard

    init() {
        if let m = d.string(forKey: "fanMode").flatMap(Mode.init) { mode = m }
        if d.object(forKey: "boostClaude") != nil { boostClaude = d.bool(forKey: "boostClaude") }
        if d.object(forKey: "boostCPU") != nil { boostCPU = d.bool(forKey: "boostCPU") }
        if d.object(forKey: "quietAtNight") != nil { quietAtNight = d.bool(forKey: "quietAtNight") }
        if d.object(forKey: "boostLevel") != nil { boostLevel = d.double(forKey: "boostLevel") }
        _ = sys.cpu()
    }

    private func save() {
        d.set(mode.rawValue, forKey: "fanMode")
        d.set(boostClaude, forKey: "boostClaude")
        d.set(boostCPU, forKey: "boostCPU")
        d.set(quietAtNight, forKey: "quietAtNight")
        d.set(boostLevel, forKey: "boostLevel")
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 1, repeating: 2, leeway: .milliseconds(300))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    /// Hand the fans back to macOS (on quit).
    func releaseFans() {
        if state.appliedPct != nil { _ = FanHelper.send("auto") }
    }

    private func step() {
        var s = State()
        s.fans = smc?.fans() ?? []
        s.mode = mode
        s.helperInstalled = FanHelper.installed
        cpuAvg = cpuAvg * 0.7 + sys.cpu() * 0.3   // smoothed over ~6 s

        lock.lock(); let claude = claudeWorking, isNight = night; lock.unlock()

        var want: Double?
        switch mode {
        case .auto:
            s.reason = "macOS controls the fans"
        case .medium, .high, .max:
            want = mode.pct
            s.reason = "Held at \(mode.label.lowercased())"
        case .smart:
            var why: [String] = []
            if boostCPU && cpuAvg > 0.8 { why.append("CPU at \(Int(cpuAvg * 100))%") }
            if boostClaude && claude {
                if quietAtNight && isNight { s.reason = "Claude is working, but it's sleeping hours" }
                else { why.append("Claude is working") }
            }
            if !why.isEmpty { want = boostLevel; s.reason = "Boosting: " + why.joined(separator: ", ") }
            else if s.reason.isEmpty { s.reason = "Waiting · CPU \(Int(cpuAvg * 100))%" }
        }

        if s.helperInstalled {
            if let pct = want {
                let r = FanHelper.send(String(format: "set %.0f", pct))   // also renews the 30 s lease
                s.helperRunning = r != nil
                s.appliedPct = r == "ok" ? pct : nil
                if let r, r != "ok" { s.error = r.replacingOccurrences(of: "error ", with: "") }
                sentAuto = false
            } else if !sentAuto {
                let r = FanHelper.send("auto")
                s.helperRunning = r != nil
                sentAuto = r == "ok"
            } else {
                s.helperRunning = FanHelper.send("status") != nil
            }
            if !s.helperRunning { s.error = "The fan helper isn't responding. Reinstall it from the menu." }
        } else if want != nil {
            s.error = "Install the fan helper to change fan speeds."
        }

        DispatchQueue.main.async { self.state = s }
    }

    // MARK: install / uninstall (admin password)

    func install(done: @escaping (String?) -> Void) {
        guard let bin = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("bitsy-fand").path,
              FileManager.default.fileExists(atPath: bin) else { done("bitsy-fand is missing from the app bundle."); return }
        let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" "
            + "\"http://www.apple.com/DTDs/PropertyList-1.0.dtd\"><plist version=\"1.0\"><dict>"
            + "<key>Label</key><string>\(FanHelper.label)</string>"
            + "<key>ProgramArguments</key><array><string>\(FanHelper.binaryPath)</string><string>--uid</string><string>\(getuid())</string></array>"
            + "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/></dict></plist>"
        let cmds = [
            "/bin/launchctl bootout system/\(FanHelper.label) 2>/dev/null; true",
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/bin/cp \(sh(bin)) \(FanHelper.binaryPath)",
            "/usr/sbin/chown root:wheel \(FanHelper.binaryPath)",
            "/bin/chmod 755 \(FanHelper.binaryPath)",
            "/usr/bin/printf '%s' \(sh(plist)) > \(FanHelper.plistPath)",
            "/usr/sbin/chown root:wheel \(FanHelper.plistPath)",
            "/bin/chmod 644 \(FanHelper.plistPath)",
            "/bin/launchctl bootstrap system \(FanHelper.plistPath)",
        ]
        runAsAdmin(cmds.joined(separator: " && "), prompt: "Bitsy needs your password to install its fan helper.", done: done)
    }

    func uninstall(done: @escaping (String?) -> Void) {
        let cmds = [
            "/bin/launchctl bootout system/\(FanHelper.label) 2>/dev/null; true",
            "/bin/rm -f \(FanHelper.plistPath) \(FanHelper.binaryPath) \(FanHelper.socketPath)",
        ]
        mode = .auto
        runAsAdmin(cmds.joined(separator: " && "), prompt: "Bitsy needs your password to remove its fan helper.", done: done)
    }

    private func sh(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    private func runAsAdmin(_ shell: String, prompt: String, done: @escaping (String?) -> Void) {
        let esc = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }
        let script = "do shell script \"\(esc(shell))\" with prompt \"\(esc(prompt))\" with administrator privileges"
        q.async {
            let p = Process(), err = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            p.standardError = err
            p.standardOutput = FileHandle.nullDevice
            let started = (try? p.run()) != nil
            if started { p.waitUntilExit() }
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            self.sentAuto = false
            DispatchQueue.main.async { done(started && p.terminationStatus == 0 ? nil : (msg?.isEmpty == false ? msg : "Install failed.")) }
        }
    }
}
