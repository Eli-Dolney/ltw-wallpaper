import AppKit
import IOKit
import IOKit.ps

/// System readings for the menu, the menu bar readout, the Stats tab, `./ltw stats` and scenes that
/// declare `stats: true` (the Monitor scene). Everything comes from public APIs: Mach host statistics,
/// libproc, IOKit registry properties (GPU, disks, battery) and sysctl. A plain sample costs well under
/// a millisecond; `detailed` adds the per-process scan (a few ms) and is only taken when something shows it.
final class SystemStats {
    struct Process {
        var pid: pid_t
        var name: String
        var cpu: Double      // fraction of one core (can exceed 1)
        var mem: Double      // resident bytes
    }

    /// An app and all its helper processes ("Google Chrome" + 15 renderers).
    struct AppGroup {
        var name: String
        var cpu: Double
        var mem: Double
        var count: Int
    }

    struct Sample {
        var cpu = 0.0, cpuUser = 0.0, cpuSystem = 0.0     // 0..1 of all cores
        var cores: [Double] = []                           // 0..1 per core
        var loadAvg: [Double] = [0, 0, 0]
        var memUsed = 0.0, memTotal = 0.0                  // bytes
        var memApp = 0.0, memWired = 0.0, memCompressed = 0.0, memCached = 0.0
        var swapUsed = 0.0, swapTotal = 0.0
        var battery: Double?                               // 0..1, nil without a battery
        var charging = false, pluggedIn = false
        var timeRemaining: Int?                            // minutes to empty (or to full while charging)
        var cycles: Int?
        var health: Double?                                // 0..1 of design capacity
        var watts: Double?                                 // + charging, − discharging
        var batteryTemp: Double?                           // °C
        var gpu: Double?                                   // 0..1
        var diskRead = 0.0, diskWrite = 0.0                // bytes/s
        var diskFree = 0.0, diskTotal = 0.0
        var netIn = 0.0, netOut = 0.0                      // bytes/s
        var netTotalIn = 0.0, netTotalOut = 0.0            // bytes since boot
        var netInterface = ""
        var thermal = "nominal"
        var uptime = 0.0
        var processes = 0
        var selfCpu = 0.0, selfMem = 0.0                   // this app
        var top: [Process]?                                // detailed samples only: by CPU
        var topMem: [Process]?                             // by memory
        var topApps: [AppGroup]?                           // helpers folded into their app, by memory

        var json: [String: Any] {
            func opt(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
            func opt(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
            var d: [String: Any] = [
                "cpu": cpu, "cpuUser": cpuUser, "cpuSystem": cpuSystem, "cores": cores, "loadAvg": loadAvg,
                "memUsed": memUsed, "memTotal": memTotal, "memApp": memApp, "memWired": memWired,
                "memCompressed": memCompressed, "memCached": memCached, "swapUsed": swapUsed, "swapTotal": swapTotal,
                "battery": opt(battery), "charging": charging, "pluggedIn": pluggedIn, "timeRemaining": opt(timeRemaining),
                "cycles": opt(cycles), "health": opt(health), "watts": opt(watts), "batteryTemp": opt(batteryTemp),
                "gpu": opt(gpu), "diskRead": diskRead, "diskWrite": diskWrite, "diskFree": diskFree, "diskTotal": diskTotal,
                "netIn": netIn, "netOut": netOut, "netTotalIn": netTotalIn, "netTotalOut": netTotalOut, "netInterface": netInterface,
                "thermal": thermal, "uptime": uptime, "processes": processes,
                "self": ["cpu": selfCpu, "mem": selfMem],
            ]
            let proc = { (p: Process) -> [String: Any] in ["pid": Int(p.pid), "name": p.name, "cpu": p.cpu, "mem": p.mem] }
            if let t = top { d["top"] = t.map(proc) }
            if let t = topMem { d["topMem"] = t.map(proc) }
            if let t = topApps { d["topApps"] = t.map { ["name": $0.name, "cpu": $0.cpu, "mem": $0.mem, "count": $0.count] } }
            return d
        }
    }

    private(set) var last = Sample()
    private var cpuBusy: UInt64 = 0, cpuTotal: UInt64 = 0, cpuUserT: UInt64 = 0, cpuSysT: UInt64 = 0
    private var coreBusy: [UInt64] = [], coreTotal: [UInt64] = []
    private var netBytesIn: UInt64 = 0, netBytesOut: UInt64 = 0
    private var diskBytesRead: UInt64 = 0, diskBytesWrite: UInt64 = 0
    private var procTime: [pid_t: UInt64] = [:]        // nanoseconds of CPU time per pid at the last detailed sample
    private var procNames: [pid_t: String] = [:]
    private var lastTime = Date(), lastDetailed = Date.distantPast
    private let timebase: Double = {
        var tb = mach_timebase_info(); mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()
    private let coreCount = Int(ProcessInfo.processInfo.activeProcessorCount)
    /// Set while a scene or the Stats tab wants the per-process list.
    var wantsDetail = false

    init() { _ = sample() }

    @discardableResult
    func sample() -> Sample {
        var s = Sample()
        let now = Date()
        let dt = max(0.001, now.timeIntervalSince(lastTime))

        sampleCPU(&s)
        sampleMemory(&s)
        sampleBattery(&s)
        s.gpu = Self.gpuUtilization()
        sampleDisk(&s, dt: dt)
        sampleNetwork(&s, dt: dt)

        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = "nominal"
        case .fair: s.thermal = "fair"
        case .serious: s.thermal = "serious"
        case .critical: s.thermal = "critical"
        @unknown default: s.thermal = "nominal"
        }
        s.uptime = ProcessInfo.processInfo.systemUptime
        var la = [Double](repeating: 0, count: 3)
        if getloadavg(&la, 3) == 3 { s.loadAvg = la }

        if wantsDetail || now.timeIntervalSince(lastDetailed) > 30 {
            sampleProcesses(&s, dt: now.timeIntervalSince(lastDetailed))
            lastDetailed = now
        } else {
            s.processes = last.processes
            s.selfCpu = last.selfCpu; s.selfMem = last.selfMem
        }

        lastTime = now
        last = s
        return s
    }

    // MARK: CPU

    private func sampleCPU(_ s: inout Sample) {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info_data_t()
        let cr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count) }
        }
        if cr == KERN_SUCCESS {
            let t = info.cpu_ticks
            let user = UInt64(t.0) + UInt64(t.3), sys = UInt64(t.1)     // user + nice, system
            let busy = user + sys
            let total = busy + UInt64(t.2)                               // + idle
            if cpuTotal > 0, total > cpuTotal {
                let d = Double(total - cpuTotal)
                s.cpu = Double(busy - cpuBusy) / d
                s.cpuUser = Double(user - cpuUserT) / d
                s.cpuSystem = Double(sys - cpuSysT) / d
            }
            cpuBusy = busy; cpuTotal = total; cpuUserT = user; cpuSysT = sys
        }
        // Per core.
        var n: natural_t = 0
        var arr: processor_info_array_t?
        var cnt: mach_msg_type_number_t = 0
        if host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &arr, &cnt) == KERN_SUCCESS, let arr = arr {
            let stride = Int(CPU_STATE_MAX)
            var busyNow: [UInt64] = [], totalNow: [UInt64] = []
            for i in 0..<Int(n) {
                let base = i * stride
                let u = UInt64(arr[base + Int(CPU_STATE_USER)]), sy = UInt64(arr[base + Int(CPU_STATE_SYSTEM)])
                let ni = UInt64(arr[base + Int(CPU_STATE_NICE)]), idle = UInt64(arr[base + Int(CPU_STATE_IDLE)])
                busyNow.append(u + sy + ni); totalNow.append(u + sy + ni + idle)
            }
            if coreBusy.count == busyNow.count {
                s.cores = (0..<busyNow.count).map { i in
                    let dt = totalNow[i] &- coreTotal[i]
                    return dt > 0 ? Double(busyNow[i] &- coreBusy[i]) / Double(dt) : 0
                }
            } else {
                s.cores = [Double](repeating: 0, count: busyNow.count)
            }
            coreBusy = busyNow; coreTotal = totalNow
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: arr), vm_size_t(cnt) * vm_size_t(MemoryLayout<integer_t>.size))
        }
    }

    // MARK: Memory

    private func sampleMemory(_ s: inout Sample) {
        var vmCount = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let vr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(vmCount)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &vmCount) }
        }
        if vr == KERN_SUCCESS {
            let page = Double(vm_kernel_page_size)
            // Activity Monitor: App memory ≈ internal − purgeable; wired; compressed; cached files = external + purgeable.
            s.memApp = max(0, Double(vm.internal_page_count) - Double(vm.purgeable_count)) * page
            s.memWired = Double(vm.wire_count) * page
            s.memCompressed = Double(vm.compressor_page_count) * page
            s.memCached = (Double(vm.external_page_count) + Double(vm.purgeable_count)) * page
            s.memUsed = s.memApp + s.memWired + s.memCompressed
        }
        s.memTotal = Double(ProcessInfo.processInfo.physicalMemory)
        var sw = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &sw, &size, nil, 0) == 0 {
            s.swapUsed = Double(sw.xsu_used); s.swapTotal = Double(sw.xsu_total)
        }
    }

    // MARK: Battery

    private func sampleBattery(_ s: inout Sample) {
        if let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] {
            for src in list {
                guard let d = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                let cur = d[kIOPSCurrentCapacityKey] as? Double ?? 0, max = d[kIOPSMaxCapacityKey] as? Double ?? 100
                s.battery = max > 0 ? cur / max : nil
                s.charging = d[kIOPSIsChargingKey] as? Bool ?? false
                s.pluggedIn = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
                let te = d[kIOPSTimeToEmptyKey] as? Int ?? -1, tf = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
                if s.charging, tf > 0 { s.timeRemaining = tf } else if !s.pluggedIn, te > 0 { s.timeRemaining = te }
            }
        }
        guard s.battery != nil else { return }
        let b = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard b != 0 else { return }
        defer { IOObjectRelease(b) }
        var props: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(b, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = props?.takeRetainedValue() as? [String: Any] else { return }
        s.cycles = d["CycleCount"] as? Int
        if let design = d["DesignCapacity"] as? Double, design > 0,
           let maxRaw = (d["AppleRawMaxCapacity"] ?? d["MaxCapacity"]) as? Double, maxRaw > 100 {
            s.health = min(1.2, maxRaw / design)
        }
        if let mA = (d["InstantAmperage"] ?? d["Amperage"]) as? Int64, let mV = d["Voltage"] as? Double {
            // Amperage is a signed 64-bit value stored in an unsigned slot on some models.
            let amps = mA > Int64(Int32.max) ? Double(Int32(truncatingIfNeeded: mA)) : Double(mA)
            s.watts = amps / 1000 * mV / 1000
        }
        if let t = d["Temperature"] as? Double { s.batteryTemp = t / 100 }
    }

    // MARK: GPU

    /// "Device Utilization %" of the first accelerator that reports it (Apple GPUs do).
    static func gpuUtilization() -> Double? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var result: Double?
        var e = IOIteratorNext(it)
        while e != 0 {
            if result == nil,
               let p = IORegistryEntryCreateCFProperty(e, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any],
               let u = (p["Device Utilization %"] ?? p["GPU Activity(%)"]) as? Double {
                result = min(1, max(0, u / 100))
            }
            IOObjectRelease(e); e = IOIteratorNext(it)
        }
        return result
    }

    // MARK: Disk

    private func sampleDisk(_ s: inout Sample, dt: TimeInterval) {
        var it: io_iterator_t = 0
        var read: UInt64 = 0, write: UInt64 = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS {
            var e = IOIteratorNext(it)
            while e != 0 {
                if let p = IORegistryEntryCreateCFProperty(e, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                    read += (p["Bytes (Read)"] as? UInt64) ?? 0
                    write += (p["Bytes (Write)"] as? UInt64) ?? 0
                }
                IOObjectRelease(e); e = IOIteratorNext(it)
            }
            IOObjectRelease(it)
        }
        if diskBytesRead > 0, read >= diskBytesRead { s.diskRead = Double(read - diskBytesRead) / dt }
        if diskBytesWrite > 0, write >= diskBytesWrite { s.diskWrite = Double(write - diskBytesWrite) / dt }
        diskBytesRead = read; diskBytesWrite = write
        if let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
            s.diskFree = Double(v.volumeAvailableCapacityForImportantUsage ?? 0)
            s.diskTotal = Double(v.volumeTotalCapacity ?? 0)
        }
    }

    // MARK: Network

    private func sampleNetwork(_ s: inout Sample, dt: TimeInterval) {
        var inB: UInt64 = 0, outB: UInt64 = 0
        var busiest = ("", UInt64(0))
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0, let first = ifap {
            var p: UnsafeMutablePointer<ifaddrs>? = first
            while let i = p {
                let name = String(cString: i.pointee.ifa_name)
                if let addr = i.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK), let data = i.pointee.ifa_data,
                   name != "lo0", !name.hasPrefix("utun"), !name.hasPrefix("awdl"), !name.hasPrefix("llw"), !name.hasPrefix("bridge") {
                    let d = data.assumingMemoryBound(to: if_data.self).pointee
                    let total = UInt64(d.ifi_ibytes) + UInt64(d.ifi_obytes)
                    inB += UInt64(d.ifi_ibytes); outB += UInt64(d.ifi_obytes)
                    if total > busiest.1 { busiest = (name, total) }
                }
                p = i.pointee.ifa_next
            }
            freeifaddrs(ifap)
        }
        if netBytesIn > 0, inB >= netBytesIn { s.netIn = Double(inB - netBytesIn) / dt }
        if netBytesOut > 0, outB >= netBytesOut { s.netOut = Double(outB - netBytesOut) / dt }
        netBytesIn = inB; netBytesOut = outB
        s.netTotalIn = Double(inB); s.netTotalOut = Double(outB)
        s.netInterface = busiest.0
    }

    // MARK: Processes

    private func sampleProcesses(_ s: inout Sample, dt: TimeInterval) {
        var n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return }
        s.processes = Int(n)
        let me = getpid()
        var times: [pid_t: UInt64] = [:]
        var procs: [Process] = []
        var ti = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.size)
        let apps = Dictionary(NSWorkspace.shared.runningApplications.compactMap { a in a.localizedName.map { (a.processIdentifier, $0) } },
                              uniquingKeysWith: { a, _ in a })
        for pid in pids.prefix(Int(n)) where pid > 0 {
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
            let ns = UInt64(Double(ti.pti_total_user + ti.pti_total_system) * timebase)
            times[pid] = ns
            let mem = Double(ti.pti_resident_size)
            if pid == me { s.selfMem = mem }
            var cpu = 0.0
            if dt > 0, dt < 600, let prev = procTime[pid], ns >= prev { cpu = Double(ns - prev) / 1e9 / dt }
            if pid == me { s.selfCpu = cpu }
            if cpu < 0.005, mem < 50e6 { continue }   // tiny and idle: not worth a name lookup
            var name = procNames[pid] ?? apps[pid] ?? ""
            if name.isEmpty {
                var buf = [CChar](repeating: 0, count: 256)
                proc_name(pid, &buf, 256)
                name = String(cString: buf)
                if name.utf8.count >= 31 {   // proc_name truncates at 32 bytes; the executable's name is complete
                    var path = [CChar](repeating: 0, count: 4096)
                    if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
                        let full = String(cString: path)
                        if let last = full.split(separator: "/").last, !last.isEmpty { name = String(last) }
                    }
                }
                if name.hasPrefix("com.apple.WebKit.") { name = String(name.dropFirst("com.apple.WebKit.".count)) }
                procNames[pid] = name
            }
            procs.append(Process(pid: pid, name: name, cpu: cpu, mem: mem))
        }
        procTime = times
        procNames = procNames.filter { times[$0.key] != nil }
        s.top = Array(procs.filter { $0.cpu >= 0.005 }.sorted { $0.cpu > $1.cpu }.prefix(8))
        s.topMem = Array(procs.sorted { $0.mem > $1.mem }.prefix(8))
        var groups: [String: AppGroup] = [:]
        for p in procs {
            let f = Self.family(p.name)
            var g = groups[f] ?? AppGroup(name: f, cpu: 0, mem: 0, count: 0)
            g.cpu += p.cpu; g.mem += p.mem; g.count += 1
            groups[f] = g
        }
        s.topApps = Array(groups.values.sorted { $0.mem > $1.mem }.prefix(8))
    }

    /// "Google Chrome Helper (Renderer)" → "Google Chrome", "Ltw Wallpaper Web Content" → "Ltw Wallpaper".
    static func family(_ name: String) -> String {
        var n = name
        if let r = n.range(of: #" Helper\b.*$"#, options: .regularExpression) { n.removeSubrange(r) }
        if let r = n.range(of: #" \((Renderer|Service|GPU|Plugin|Plug-in|Utility|Network)[^)]*\)$"#, options: .regularExpression) { n.removeSubrange(r) }
        for suffix in [" Web Content", " Graphics and Media", " Networking", "WebContent", "GPU", "Networking"] where n.hasSuffix(suffix) && n != suffix {
            n = String(n.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return n.isEmpty ? name : n
    }

    // MARK: Formatting

    static func bytes(_ b: Double, perSecond: Bool = false) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = b, i = 0
        while v >= 1000, i < units.count - 1 { v /= 1000; i += 1 }
        let num = i == 0 ? String(format: "%.0f", v) : (v < 10 ? String(format: "%.1f", v) : String(format: "%.0f", v))
        return num + " " + units[i] + (perSecond ? "/s" : "")
    }

    static func minutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }

    /// Three short lines for the top of the menu.
    var menuLines: [String] {
        let s = last
        var a = String(format: "CPU %.0f%%", s.cpu * 100)
        if let g = s.gpu { a += String(format: "  ·  GPU %.0f%%", g * 100) }
        a += "  ·  Memory \(Self.bytes(s.memUsed)) / \(Self.bytes(s.memTotal))"
        var lines = [a]
        if let b = s.battery {
            var l = String(format: "Battery %.0f%%", b * 100)
            if s.charging { l += " ⚡︎" }
            if let t = s.timeRemaining { l += s.charging ? "  ·  \(Self.minutes(t)) to full" : "  ·  \(Self.minutes(t)) left" }
            if let w = s.watts { l += String(format: "  ·  %.1f W", abs(w)) }
            if s.thermal != "nominal" { l += "  ·  thermal: \(s.thermal)" }
            lines.append(l)
        } else if s.thermal != "nominal" {
            lines.append("Thermal state: \(s.thermal)")
        }
        lines.append("Network ↓ \(Self.bytes(s.netIn, perSecond: true))  ↑ \(Self.bytes(s.netOut, perSecond: true))   ·   Disk R \(Self.bytes(s.diskRead, perSecond: true))  W \(Self.bytes(s.diskWrite, perSecond: true))")
        return lines
    }

    /// Compact text for next to the menu bar icon.
    func readout(_ kind: String) -> String {
        let s = last
        switch kind {
        case "cpu": return String(format: "%.0f%%", s.cpu * 100)
        case "gpu": return s.gpu.map { String(format: "GPU %.0f%%", $0 * 100) } ?? ""
        case "mem": return Self.bytes(s.memUsed)
        case "cpu+mem": return String(format: "%.0f%% · %@", s.cpu * 100, Self.bytes(s.memUsed))
        case "cpu+gpu": return String(format: "%.0f%% · %@", s.cpu * 100, s.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "–")
        case "battery": return s.battery.map { String(format: "%.0f%%", $0 * 100) } ?? ""
        case "battery+time":
            guard let b = s.battery else { return "" }
            return String(format: "%.0f%%", b * 100) + (s.timeRemaining.map { " · \(Self.minutes($0))" } ?? "")
        case "watts": return s.watts.map { String(format: "%.1f W", abs($0)) } ?? ""
        case "net": return "↓\(Self.bytes(s.netIn, perSecond: true))"
        case "net2": return "↓\(Self.bytes(s.netIn, perSecond: true)) ↑\(Self.bytes(s.netOut, perSecond: true))"
        case "disk": return "R \(Self.bytes(s.diskRead, perSecond: true)) W \(Self.bytes(s.diskWrite, perSecond: true))"
        case "load": return String(format: "%.2f", s.loadAvg[0])
        case "temp": return s.batteryTemp.map { String(format: "%.0f°", $0) } ?? ""
        default: return ""
        }
    }

    /// Plain-text report for `./ltw stats`.
    var report: String {
        let s = last
        var out: [String] = []
        out.append(String(format: "CPU      %3.0f%%  (user %.0f%%, system %.0f%%)   load %.2f %.2f %.2f   %d cores", s.cpu * 100, s.cpuUser * 100, s.cpuSystem * 100, s.loadAvg[0], s.loadAvg[1], s.loadAvg[2], s.cores.count))
        if let g = s.gpu { out.append(String(format: "GPU      %3.0f%%", g * 100)) }
        out.append("Memory   \(Self.bytes(s.memUsed)) / \(Self.bytes(s.memTotal))  (app \(Self.bytes(s.memApp)), wired \(Self.bytes(s.memWired)), compressed \(Self.bytes(s.memCompressed)), cached \(Self.bytes(s.memCached)))" + (s.swapUsed > 0 ? "  swap \(Self.bytes(s.swapUsed))" : ""))
        if let b = s.battery {
            var l = String(format: "Battery  %3.0f%%  %@", b * 100, s.charging ? "charging" : (s.pluggedIn ? "plugged in" : "discharging"))
            if let t = s.timeRemaining { l += "  \(Self.minutes(t)) " + (s.charging ? "to full" : "left") }
            if let w = s.watts { l += String(format: "  %.1f W", abs(w)) }
            if let h = s.health { l += String(format: "  health %.0f%%", h * 100) }
            if let c = s.cycles { l += "  \(c) cycles" }
            if let t = s.batteryTemp { l += String(format: "  %.1f °C", t) }
            out.append(l)
        }
        out.append("Network  ↓ \(Self.bytes(s.netIn, perSecond: true))  ↑ \(Self.bytes(s.netOut, perSecond: true))  (\(s.netInterface.isEmpty ? "–" : s.netInterface); \(Self.bytes(s.netTotalIn)) in, \(Self.bytes(s.netTotalOut)) out since boot)")
        out.append("Disk     R \(Self.bytes(s.diskRead, perSecond: true))  W \(Self.bytes(s.diskWrite, perSecond: true))   \(Self.bytes(s.diskFree)) free of \(Self.bytes(s.diskTotal))")
        let up = Int(s.uptime)
        out.append("System   up \(up / 86400)d \(up % 86400 / 3600)h \(up % 3600 / 60)m   \(s.processes) processes   thermal \(s.thermal)   wallpaper \(String(format: "%.1f%%", s.selfCpu * 100)) / \(Self.bytes(s.selfMem))")
        if let top = s.top, !top.isEmpty {
            out.append("Top CPU  " + top.prefix(6).map { String(format: "%@ %.0f%%", $0.name, $0.cpu * 100) }.joined(separator: ", "))
        }
        if let top = s.topMem, !top.isEmpty {
            out.append("Top mem  " + top.prefix(6).map { "\($0.name) \(Self.bytes($0.mem))" }.joined(separator: ", "))
        }
        if let apps = s.topApps, !apps.isEmpty {
            out.append("By app   " + apps.prefix(6).map { "\($0.name)\($0.count > 1 ? " ×\($0.count)" : "") \(Self.bytes($0.mem))" }.joined(separator: ", "))
        }
        return out.joined(separator: "\n")
    }
}
