import Foundation

// Claude Code status line bridge. Claude Code pipes session JSON on stdin after each assistant message;
// this saves the documented `rate_limits` part for Bitsy and prints a short status line.
// Docs: https://code.claude.com/docs/en/statusline

let input = FileHandle.standardInput.readDataToEndOfFile()
let json = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] ?? [:]
let limits = json["rate_limits"] as? [String: Any]
let model = (json["model"] as? [String: Any])?["display_name"] as? String

let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bitsy")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
var out: [String: Any] = ["updated": Date().timeIntervalSince1970, "has_rate_limits": limits != nil]
if let limits { out["rate_limits"] = limits }
if let model { out["model"] = model }
if let data = try? JSONSerialization.data(withJSONObject: out) {
    try? data.write(to: dir.appendingPathComponent("statusline.json"), options: .atomic)
}

func pct(_ key: String) -> Int? {
    ((limits?[key] as? [String: Any])?["used_percentage"] as? Double).map { Int($0.rounded()) }
}
var parts = [model ?? "Claude"]
if let s = pct("five_hour") { parts.append("session \(s)%") }
if let w = pct("seven_day") { parts.append("week \(w)%") }
print(parts.joined(separator: " · "))
