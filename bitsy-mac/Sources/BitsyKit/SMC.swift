import Foundation
import IOKit

// Minimal AppleSMC client. Reading works for any user; writing (fan control) needs root.
// The kernel struct is 80 bytes; fields are read and written at their C offsets.

public final class SMC {
    private var conn: io_connect_t = 0

    public init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &conn) == kIOReturnSuccess else { return nil }
    }

    deinit { IOServiceClose(conn) }

    private enum Off { static let key = 0, size = 28, type = 32, result = 40, cmd = 42, bytes = 48, total = 80 }
    private enum Cmd { static let read: UInt8 = 5, write: UInt8 = 6, info: UInt8 = 9 }

    private static func fourCC(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
    private static func string(_ v: UInt32) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xff) }, encoding: .ascii) ?? "????"
    }

    private func call(_ input: [UInt8]) -> [UInt8]? {
        var inp = input, out = [UInt8](repeating: 0, count: Off.total), outSize = Off.total
        let kr = IOConnectCallStructMethod(conn, 2, &inp, Off.total, &out, &outSize)
        return kr == kIOReturnSuccess && out[Off.result] == 0 ? out : nil
    }

    private func put32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        withUnsafeBytes(of: v) { for i in 0..<4 { b[off + i] = $0[i] } }
    }
    private func get32(_ b: [UInt8], _ off: Int) -> UInt32 {
        b[off..<off + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    private func info(_ key: String) -> (size: Int, type: String)? {
        var b = [UInt8](repeating: 0, count: Off.total)
        put32(&b, Off.key, Self.fourCC(key))
        b[Off.cmd] = Cmd.info
        guard let o = call(b) else { return nil }
        return (Int(get32(o, Off.size)), Self.string(get32(o, Off.type)))
    }

    public func read(_ key: String) -> (type: String, bytes: [UInt8])? {
        guard let i = info(key), i.size > 0, i.size <= 32 else { return nil }
        var b = [UInt8](repeating: 0, count: Off.total)
        put32(&b, Off.key, Self.fourCC(key))
        put32(&b, Off.size, UInt32(i.size))
        b[Off.cmd] = Cmd.read
        guard let o = call(b) else { return nil }
        return (i.type, Array(o[Off.bytes..<Off.bytes + i.size]))
    }

    @discardableResult
    public func write(_ key: String, _ bytes: [UInt8]) -> Bool {
        guard let i = info(key), i.size == bytes.count else { return false }
        var b = [UInt8](repeating: 0, count: Off.total)
        put32(&b, Off.key, Self.fourCC(key))
        put32(&b, Off.size, UInt32(i.size))
        b[Off.cmd] = Cmd.write
        for (j, v) in bytes.enumerated() { b[Off.bytes + j] = v }
        return call(b) != nil
    }

    public func exists(_ key: String) -> Bool { info(key) != nil }

    /// Decodes the numeric SMC types fans use.
    public func number(_ key: String) -> Double? {
        guard let (type, b) = read(key) else { return nil }
        switch type {
        case "flt ": return b.count == 4 ? Double(b.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) }) : nil
        case "fpe2": return b.count == 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 4 : nil
        case "ui8 ": return Double(b[0])
        case "ui16": return b.count == 2 ? Double(UInt16(b[0]) << 8 | UInt16(b[1])) : nil
        case "ui32": return b.count == 4 ? Double(b.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) : nil
        default: return nil
        }
    }

    /// Encodes `v` in the key's own type and writes it.
    @discardableResult
    public func setNumber(_ key: String, _ v: Double) -> Bool {
        guard let (type, _) = read(key) else { return false }
        switch type {
        case "flt ": return write(key, withUnsafeBytes(of: Float32(v)) { Array($0) })
        case "fpe2": let u = UInt16(max(0, min(16383, v)) * 4); return write(key, [UInt8(u >> 8), UInt8(u & 0xff)])
        case "ui8 ": return write(key, [UInt8(max(0, min(255, v)))])
        default: return false
        }
    }
}

// MARK: fans

public struct Fan: Codable, Equatable {
    public var index: Int
    public var rpm: Double
    public var min: Double
    public var max: Double
    public var target: Double
    public var manual: Bool
}

public extension SMC {
    var fanCount: Int { Int(number("FNum") ?? 0) }

    /// Manual/auto switch: "F0md" on recent Apple Silicon, "F0Md" on older models.
    func modeKey(_ i: Int) -> String { exists("F\(i)md") ? "F\(i)md" : "F\(i)Md" }

    func fans() -> [Fan] {
        (0..<fanCount).compactMap { i in
            guard let rpm = number("F\(i)Ac"), let mn = number("F\(i)Mn"), let mx = number("F\(i)Mx") else { return nil }
            return Fan(index: i, rpm: rpm, min: mn, max: mx, target: number("F\(i)Tg") ?? rpm, manual: (number(modeKey(i)) ?? 0) >= 1)
        }
    }
}

// MARK: talking to the root helper

/// The root fan helper listens on a Unix socket. One request per connection: a command line in, a reply line out.
///   status        → JSON {"manual": Bool, "pct": Double?, "fans": [Fan]}
///   set <0-100>   → forced speed between each fan's minimum and maximum; lasts 30 s unless repeated
///   auto          → give the fans back to macOS
public enum FanHelper {
    public static let label = "io.bitsy.fand"
    public static let socketPath = "/var/run/io.bitsy.fand.sock"
    public static let binaryPath = "/Library/PrivilegedHelperTools/io.bitsy.fand"
    public static let plistPath = "/Library/LaunchDaemons/io.bitsy.fand.plist"
    public static let leaseSeconds = 30.0

    public static var installed: Bool { FileManager.default.fileExists(atPath: plistPath) }

    public static func send(_ line: String) -> String? { Unix.request(socketPath, line, timeout: 2) }

    public static func sockaddr(_ path: String) -> sockaddr_un { Unix.sockaddr(path) }

}
