import Foundation

// The Bitsy app listens on a Unix socket in the user's own Application Support folder (mode 600, and the peer's
// uid is checked). bitsy-mcp asks it for what needs the app's permissions (Accessibility, the clipboard) or its
// face on screen (speech bubbles, Allow/Deny prompts). One request per connection: a JSON line in, a JSON line out.
public enum Bridge {
    public static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Bitsy/bridge.sock").path
    }

    /// nil when Bitsy isn't running (or didn't answer in time).
    public static func request(_ msg: [String: Any], timeout: Int = 5) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: msg), let line = String(data: body, encoding: .utf8),
              let reply = Unix.request(socketPath, line, timeout: timeout), let d = reply.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

public enum Unix {
    /// Connect, send one line, read one line back.
    public static func request(_ path: String, _ line: String, timeout: Int) -> String? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr(path)
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, writeAll(fd, Array((line + "\n").utf8)) else { return nil }
        var out = [UInt8](), buf = [UInt8](repeating: 0, count: 65536)
        while out.last != 0x0A {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out += buf[0..<n]
        }
        return String(bytes: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A listening socket at `path`, replacing any stale one; nil on failure.
    public static func listen(_ path: String, mode: mode_t) -> Int32? {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: Darwin.sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard fd >= 0, bound == 0, Darwin.listen(fd, 8) == 0 else { return nil }
        chmod(path, mode)
        return fd
    }

    public static func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var sent = 0
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return false }
            sent += n
        }
        return true
    }

    public static func sockaddr(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { p in for i in 0..<min(bytes.count, p.count - 1) { p[i] = bytes[i] } }
        return addr
    }
}
