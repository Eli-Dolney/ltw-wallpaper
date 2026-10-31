import Foundation
import IOKit.ps

/// Cheap system readings (CPU, memory, battery, network) for the menu, the menu bar readout and the Stats tab.
final class SystemStats {
    struct Sample {
        var cpu = 0.0            // 0..1
        var memUsed = 0.0        // bytes
        var memTotal = 0.0
        var battery: Double?     // 0..1, nil without a battery
        var charging = false
        var netIn = 0.0          // bytes/s
        var netOut = 0.0
        var uptime = 0.0

        var json: [String: Any] {
            var d: [String: Any] = ["cpu": cpu, "memUsed": memUsed, "memTotal": memTotal, "charging": charging,
                                    "netIn": netIn, "netOut": netOut, "uptime": uptime]
            d["battery"] = battery.map { $0 } ?? NSNull()
            return d
        }
    }

    private(set) var last = Sample()
    private var cpuBusy: UInt64 = 0, cpuTotal: UInt64 = 0
    private var netBytesIn: UInt64 = 0, netBytesOut: UInt64 = 0
    private var lastTime = Date()

    init() { _ = sample() }

    @discardableResult
    func sample() -> Sample {
        var s = Sample()
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastTime))

        // CPU
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let cr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if cr == KERN_SUCCESS {
            let t = info.cpu_ticks
            let busy = UInt64(t.0) + UInt64(t.1) + UInt64(t.3)   // user, system, nice
            let total = busy + UInt64(t.2)                       // + idle
            if cpuTotal > 0, total > cpuTotal { s.cpu = Double(busy - cpuBusy) / Double(total - cpuTotal) }
            cpuBusy = busy; cpuTotal = total
        }

        // Memory: wired + active + compressed, the way Activity Monitor's "Memory Used" roughly reads.
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            s.memUsed = (Double(vm.wire_count) + Double(vm.active_count) + Double(vm.compressor_page_count)) * page
        }
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory)

        // Battery
        if let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let cur = d[kIOPSCurrentCapacityKey] as? Double ?? 0, max = d[kIOPSMaxCapacityKey] as? Double ?? 100
                s.battery = max > 0 ? cur / max : nil
                s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
            }
        }

        // Network: all non-loopback link-level interfaces
        var inB: UInt64 = 0, outB: UInt64 = 0
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                if let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                   let data = i.pointee.ifa_data, String(cString: i.pointee.ifa_name) != "lo0" {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    inB += UInt64(d.ifi_ibytes); outB += UInt64(d.ifi_obytes)
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }
        if netBytesIn > 0, inB >= netBytesIn { s.netIn = Double(inB - netBytesIn) / dt }
        if netBytesOut > 0, outB >= netBytesOut { s.netOut = Double(outB - netBytesOut) / dt }
        netBytesIn = inB; netBytesOut = outB

        s.uptime = ProcessInfo.processInfo.systemUptime
        lastTime = now
        last = s
        return s
    }

    static func bytes(_ b: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        let num = i == 0 ? String(format: "%.0f", v) : (v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v))
        return num + " " + units[i] + (perSecond ? "/s" : "")
    }

    /// Two short lines for the menu.
    var menuLines: [String] {
        let s = last
        var a = String(format: "CPU %.0f%%  ·  Memory %@ / %@", s.cpu * 100, Self.bytes(s.memUsed), Self.bytes(s.memTotal))
        if let b = s.battery { a += String(format: "  ·  Battery %.0f%%%@", b * 100, s.charging ? " ⚡︎" : "") }
        let n = "Network ↓ \(Self.bytes(s.netIn, perSecond: true))   ↑ \(Self.bytes(s.netOut, perSecond: true))"
        return [a, n]
    }

    /// Compact text for next to the menu bar icon.
    func readout(_ kind: String) -> String {
        let s = last
        switch kind {
        case "cpu": return String(format: "%.0f%%", s.cpu * 100)
        case "mem": return Self.bytes(s.memUsed)
        case "cpu+mem": return String(format: "%.0f%% · %@", s.cpu * 100, Self.bytes(s.memUsed))
        case "battery": return s.battery.map { String(format: "%.0f%%", $0 * 100) } ?? ""
        case "net": return "↓\(Self.bytes(s.netIn, perSecond: true))"
        default: return ""
        }
    }
}
