import AppKit

// Spotify and Apple Music announce every play/pause/track change with a distributed notification,
// so Bitsy knows what's playing without any permission. Controlling playback goes through
// AppleScript, which asks once for Automation permission.

struct NowPlaying: Equatable {
    var app: String
    var title: String
    var artist: String
    var playing: Bool
}

final class MediaMonitor {
    private(set) var now: NowPlaying? { didSet { if now != oldValue { updateArtwork() } } }
    private(set) var artwork: NSImage?
    private var artworkKey = ""
    private let players = [
        (name: "Spotify", bundle: "com.spotify.client", note: "com.spotify.client.PlaybackStateChanged"),
        (name: "Music", bundle: "com.apple.Music", note: "com.apple.Music.playerInfo"),
    ]
    private let q = DispatchQueue(label: "bitsy.media", qos: .userInitiated)

    init() {
        let dnc = DistributedNotificationCenter.default()
        for p in players {
            dnc.addObserver(forName: Notification.Name(p.note), object: nil, queue: .main) { [weak self] n in
                self?.handle(p.name, n.userInfo)
            }
        }
        // Players only announce changes, so ask directly when Bitsy starts (music may already be playing).
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.query() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil, queue: .main) { [weak self] n in
            guard let self, let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let cur = self.now, self.players.first(where: { $0.name == cur.app })?.bundle == app.bundleIdentifier { self.now = nil }
        }
    }

    var isPlaying: Bool { now?.playing == true }

    /// A player that's open, even if nothing has played since Bitsy started.
    var runningPlayer: String? {
        if let n = now { return n.app }
        return players.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundle).isEmpty }?.name
    }

    private func handle(_ app: String, _ info: [AnyHashable: Any]?) {
        let state = info?["Player State"] as? String ?? ""
        if state == "Stopped" { if now?.app == app { now = nil }; return }
        let playing = state == "Playing"
        if !playing, let n = now, n.app != app, n.playing { return }   // keep showing the one that's actually playing
        now = NowPlaying(app: app, title: info?["Name"] as? String ?? "", artist: info?["Artist"] as? String ?? "", playing: playing)
    }

    /// cmd: "playpause", "next track", "previous track"
    func control(_ cmd: String) {
        guard let app = runningPlayer else { return }
        run("tell application \"\(app)\" to \(cmd)") { [weak self] _ in self?.query() }
    }

    /// Ask the player directly (used when the popup opens and nothing has been announced yet).
    func query() {
        guard let app = runningPlayer else { return }
        let src = """
        tell application "\(app)"
            set s to (player state as string)
            if s is "stopped" then return s
            return s & linefeed & (name of current track) & linefeed & (artist of current track)
        end tell
        """
        run(src) { [weak self] out in
            guard let self, let out else { return }
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if lines.first == "stopped" { self.now = nil; return }
            guard lines.count >= 3 else { return }
            self.now = NowPlaying(app: app, title: lines[1], artist: lines[2], playing: lines[0] == "playing")
        }
    }

    /// Cover art for the current track. Spotify hands out a URL, Music the raw image bytes (osascript prints
    /// those as «data JPEG…» hex). Fetched once per track; the key check drops a late answer for an old track.
    private func updateArtwork() {
        guard let n = now else { artwork = nil; artworkKey = ""; return }
        let key = "\(n.app)|\(n.title)|\(n.artist)"
        guard key != artworkKey else { return }
        artworkKey = key
        artwork = nil
        let src = n.app == "Spotify"
            ? "tell application \"Spotify\" to return artwork url of current track"
            : "tell application \"Music\" to return data of artwork 1 of current track"
        run(src) { [weak self] out in
            guard let self, self.artworkKey == key, let out, !out.isEmpty else { return }
            if out.hasPrefix("http"), let url = URL(string: out) {
                URLSession.shared.dataTask(with: url) { data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async { if self.artworkKey == key { self.artwork = img } }
                }.resume()
            } else if out.hasPrefix("«data "), out.count > 12 {
                let hex = Array(out.dropFirst(10).replacingOccurrences(of: "»", with: ""))
                var bytes = [UInt8](); bytes.reserveCapacity(hex.count / 2)
                var i = 0
                while i + 1 < hex.count, let v = UInt8(String(hex[i...i + 1]), radix: 16) { bytes.append(v); i += 2 }
                if let img = NSImage(data: Data(bytes)) { self.artwork = img }
            }
        }
    }

    private func run(_ src: String, done: @escaping (String?) -> Void) {
        q.async {
            let p = Process(), pipe = Pipe()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { DispatchQueue.main.async { done(nil) }; return }
            p.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            DispatchQueue.main.async { done(p.terminationStatus == 0 ? out : nil) }
        }
    }
}

// MARK: coding apps

private let IDE_BUNDLES: Set<String> = [
    "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium", "com.todesktop.230313mzl4w4u92",   // Cursor
    "com.exafunction.windsurf", "com.apple.dt.Xcode", "dev.zed.Zed", "dev.zed.Zed-Preview", "com.sublimetext.4",
    "com.panic.Nova", "com.google.android.studio", "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
    "com.mitchellh.ghostty", "com.github.wez.wezterm", "net.kovidgoyal.kitty", "co.zeit.hyper",
]

/// Name of the frontmost app if it's an editor, IDE or terminal.
func frontmostIDE() -> String? {
    guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier else { return nil }
    if IDE_BUNDLES.contains(id) || id.hasPrefix("com.jetbrains.") { return app.localizedName ?? "your editor" }
    return nil
}
