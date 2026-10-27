import Foundation
import IOKit.ps

// MARK: system readings

public final class SystemStats {
    public init() {}
    private let host = mach_host_self()
    private var prev: host_cpu_load_info?

    /// Fraction of CPU busy since the previous call.
    public func cpu() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        defer { prev = info }
        guard let p = prev else { return 0 }
        let u = Double(info.cpu_ticks.0 &- p.cpu_ticks.0), s = Double(info.cpu_ticks.1 &- p.cpu_ticks.1)
        let i = Double(info.cpu_ticks.2 &- p.cpu_ticks.2), n = Double(info.cpu_ticks.3 &- p.cpu_ticks.3)
        let total = u + s + i + n
        return total > 0 ? (u + s + n) / total : 0
    }

    /// "Memory Used" the way Activity Monitor counts it: app + wired + compressed.
    public func memory() -> (used: Double, total: Double) {
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        let total = Double(ProcessInfo.processInfo.physicalMemory)
        guard kr == KERN_SUCCESS else { return (0, total) }
        let page = Double(getpagesize())
        let app = Double(vm.internal_page_count) - Double(vm.purgeable_count)
        return ((app + Double(vm.wire_count) + Double(vm.compressor_page_count)) * page, total)
    }

    public func battery() -> (pct: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cap = d["Current Capacity"] as? Int, let max = d["Max Capacity"] as? Int, max > 0 else { continue }
            return (cap * 100 / max, d["Is Charging"] as? Bool ?? false)
        }
        return nil
    }
}
