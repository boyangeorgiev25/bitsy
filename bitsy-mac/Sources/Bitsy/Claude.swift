import Foundation

// Reads Claude Code's local transcripts (~/.claude/projects/**/*.jsonl) to tell whether Claude is
// working right now, plus today's usage and the current 5-hour window. Nothing leaves the Mac except
// the public status check against status.anthropic.com.

struct ClaudeSnapshot: Equatable {
    enum State { case working, done, idle }
    struct Finish: Equatable { var id: Int; var title: String; var project: String?; var at: Date }
    var state = State.idle
    var project: String?
    var model: String?
    var lastActive: Date?
    var activeSessions = 0
    var todayMessages = 0
    var todayTokens = 0
    var todaySessions = 0
    var blockStart: Date?
    var blockTokens = 0
    var service = "Checking…"
    var serviceLevel = "unknown"   // none, minor, major, critical, maintenance
    var finish: Finish?            // the latest turn Claude finished; its id grows with each one
    var workingSince: Date?        // when the current turn started
    var task: String?              // title of the session that's working
    var usage: UsageLimits?        // real plan usage from the status line bridge
    var working: Bool { state == .working }
}

final class ClaudeMonitor {
    private(set) var snap = ClaudeSnapshot()

    private struct FileState {
        var offset: UInt64 = 0
        var mtime = Date.distantPast
        var last = ""            // "user" (waiting on Claude), "tool" (mid-turn), "end" (turn finished), "stopped"
        var cwd: String?
        var model: String?
        var session: String?
        var title: String?       // the session's title (yours, or the one Claude gave it)
        var customTitle = false
        var prompt: String?
        var wasBusy: Bool?
        var busySince: Date?
    }

    private let q = DispatchQueue(label: "bitsy.claude", qos: .utility)
    private let root = ProcessInfo.processInfo.environment["BITSY_CLAUDE_DIR"].map { URL(fileURLWithPath: $0) }   // debugging
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    private var files: [String: FileState] = [:]
    private var events: [(time: Date, tokens: Int, session: String)] = []   // one per assistant message
    private var seen = Set<String>()
    private var timer: DispatchSourceTimer?
    private var lastServiceCheck = Date.distantPast
    private var service = ("Checking…", "unknown")
    private var finishSeq = 0
    private var lastFinish: ClaudeSnapshot.Finish?
    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    func start() {
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(500))
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    private func poll() {
        let now = Date(), cutoff = now.addingTimeInterval(-26 * 3600)
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        if let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let m = (try? url.resourceValues(forKeys: Set(keys)))?.contentModificationDate, m > cutoff else { continue }
                var st = files[url.path] ?? FileState()
                if m != st.mtime { st.mtime = m; read(url, &st) }
                files[url.path] = st
            }
        }
        // a main session going from busy to a finished turn: that's a "done"
        for (path, var f) in files {
            let b = busy(f, now)
            if f.wasBusy == true, !b, f.last == "end", !path.contains("/subagents/") {
                finishSeq += 1
                let task = f.title ?? f.prompt.map { String($0.split(separator: "\n").first ?? "") } ?? "Task"
                lastFinish = .init(id: finishSeq, title: task, project: f.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }, at: now)
            }
            if b && f.wasBusy != true { f.busySince = now }
            f.wasBusy = b
            files[path] = f
        }
        events.removeAll { $0.time < cutoff }
        if seen.count > 200_000 { seen.removeAll() }

        if now.timeIntervalSince(lastServiceCheck) > 300 { lastServiceCheck = now; checkService() }

        let s = snapshot(now)
        DispatchQueue.main.async { self.snap = s }
    }

    private func read(_ url: URL, _ st: inout FileState) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < st.offset { st.offset = 0 }   // file was rewritten
        try? h.seek(toOffset: st.offset)
        guard let data = try? h.readToEnd(), let nl = data.lastIndex(of: 0x0A) else { return }
        let chunk = data[data.startIndex...nl]   // only whole lines; the rest is read next time
        st.offset += UInt64(chunk.count)

        for line in chunk.split(separator: 0x0A) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = o["type"] as? String else { continue }
            if let c = o["cwd"] as? String { st.cwd = c }
            if let s = o["sessionId"] as? String { st.session = s }
            let ts = (o["timestamp"] as? String).flatMap { iso.date(from: $0) }

            if type == "user", o["isMeta"] as? Bool != true {
                let text = ((o["message"] as? [String: Any])?["content"]).map { "\($0)" } ?? ""
                st.last = text.contains("[Request interrupted") ? "stopped" : "user"
            } else if type == "custom-title", let t = o["customTitle"] as? String, !t.isEmpty {
                st.title = t; st.customTitle = true
            } else if type == "ai-title", let t = o["aiTitle"] as? String, !t.isEmpty, !st.customTitle {
                st.title = t
            } else if type == "last-prompt", let t = o["lastPrompt"] as? String {
                st.prompt = t
            } else if type == "assistant", let msg = o["message"] as? [String: Any] {
                if let m = msg["model"] as? String, !m.hasPrefix("<") { st.model = m }
                let stop = msg["stop_reason"] as? String
                st.last = stop == nil || stop == "tool_use" ? "tool" : "end"
                let key = "\(msg["id"] as? String ?? UUID().uuidString)|\(o["requestId"] as? String ?? "")"
                if let u = msg["usage"] as? [String: Any], let ts, seen.insert(key).inserted {
                    let tok = (u["input_tokens"] as? Int ?? 0) + (u["output_tokens"] as? Int ?? 0)
                        + (u["cache_creation_input_tokens"] as? Int ?? 0)
                    events.append((ts, tok, st.session ?? url.path))
                }
            }
        }
    }

    private func busy(_ f: FileState, _ now: Date) -> Bool {
        let age = now.timeIntervalSince(f.mtime)
        return (f.last == "tool" && age < 600) || (f.last == "user" && age < 90)
    }

    private func snapshot(_ now: Date) -> ClaudeSnapshot {
        var s = ClaudeSnapshot()
        s.finish = lastFinish
        let all = Array(files.values)
        let working = all.filter { busy($0, now) }
        let newest = all.max { $0.mtime < $1.mtime }

        if let w = working.max(by: { $0.mtime < $1.mtime }) {
            s.state = .working
            s.workingSince = w.busySince
            s.task = w.title ?? w.prompt.map { String($0.split(separator: "\n").first ?? "") }
            s.project = w.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            s.model = w.model.map(prettyModel)
        } else if let n = newest {
            s.state = n.last == "end" && now.timeIntervalSince(n.mtime) < 180 ? .done : .idle
            s.project = n.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            s.model = n.model.map(prettyModel)
        }
        s.lastActive = newest?.mtime
        s.activeSessions = Set(working.compactMap { $0.session }).count

        let dayStart = Calendar.current.startOfDay(for: now)
        let today = events.filter { $0.time >= dayStart }
        s.todayMessages = today.count
        s.todayTokens = today.reduce(0) { $0 + $1.tokens }
        s.todaySessions = Set(today.map { $0.session }).count

        // Usage windows last 5 hours from the hour of the first message after the previous window ended.
        var start: Date?, tokens = 0
        for e in events.sorted(by: { $0.time < $1.time }) {
            if let st = start, e.time < st.addingTimeInterval(5 * 3600) { tokens += e.tokens }
            else { start = Calendar.current.dateInterval(of: .hour, for: e.time)?.start ?? e.time; tokens = e.tokens }
        }
        if let st = start, now < st.addingTimeInterval(5 * 3600) { s.blockStart = st; s.blockTokens = tokens }

        s.usage = readUsage(now)
        s.service = service.0
        s.serviceLevel = service.1
        return s
    }

    /// Plan usage that Claude Code handed to the status line bridge (bitsy-statusline). Windows whose reset time
    /// has passed are dropped, as Claude Code does.
    private func readUsage(_ now: Date) -> UsageLimits? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bitsy/statusline.json")
        guard let d = try? Data(contentsOf: url), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let limits = o["rate_limits"] as? [String: Any] else { return nil }
        let day = DateFormatter()
        day.dateFormat = "EEE H:mm"
        var rows: [UsageLimits.Row] = []
        for (key, label) in [("five_hour", "Session"), ("seven_day", "Week")] {
            guard let w = limits[key] as? [String: Any], let pct = w["used_percentage"] as? Double,
                  let at = (w["resets_at"] as? Double).map(Date.init(timeIntervalSince1970:)), at > now else { continue }
            let resets = key == "five_hour" ? "resets in " + fmtDuration(at.timeIntervalSince(now)) : "resets " + day.string(from: at)
            rows.append(.init(label: label, pct: pct, resets: resets))
        }
        guard !rows.isEmpty else { return nil }
        return UsageLimits(rows: rows, updated: (o["updated"] as? Double).map(Date.init(timeIntervalSince1970:)))
    }

    private func checkService() {
        guard let url = URL(string: "https://status.anthropic.com/api/v2/status.json") else { return }
        URLSession.shared.dataTask(with: url) { [weak self] d, _, _ in
            guard let self, let d, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let st = o["status"] as? [String: Any] else { return }
            self.q.async { self.service = (st["description"] as? String ?? "Unknown", st["indicator"] as? String ?? "unknown") }
        }.resume()
    }
}

/// "claude-opus-5-5" → "Opus 5.5", "claude-sonnet-4-5-20250929" → "Sonnet 4.5"
func prettyModel(_ id: String) -> String {
    let parts: [String] = id.replacingOccurrences(of: "claude-", with: "")
        .components(separatedBy: "-").filter { !$0.isEmpty && $0.count < 5 }
    guard let first = parts.first else { return id }
    let family = first.prefix(1).uppercased() + String(first.dropFirst())
    let version = parts.dropFirst().joined(separator: ".")
    return version.isEmpty ? family : "\(family) \(version)"
}

func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

/// Plan usage as Claude's Settings › Usage shows it (session, weekly, per model), when a real source is connected.
struct UsageLimits: Equatable {
    struct Row: Equatable { var label: String; var pct: Double; var resets: String }
    var rows: [Row]
    var updated: Date?
}
