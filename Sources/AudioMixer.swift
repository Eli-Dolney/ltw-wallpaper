import Cocoa
import CoreAudio
import AudioToolbox

/// Per-app volume, output device and master volume.
///
/// macOS has no per-app volume API, so apps whose slider leaves 100% (or are muted) get a Core Audio
/// process tap (macOS 14.2+): the tap silences the app's own output and hands us its audio, which we
/// scale and play through a private aggregate device on the chosen output. Apps left at 100% are not
/// touched at all. The first tap asks for the "System Audio Recording" permission.
final class AudioMixer {
    struct Device { let id: AudioObjectID; let uid: String; let name: String }
    struct App {
        let key: String          // bundle id, or "pid:N" for tools without one
        let name: String
        let pid: pid_t
        let objectID: AudioObjectID
        var running: Bool
        var icon: String?
    }

    var onChange: (() -> Void)?
    private(set) var apps: [App] = []
    private(set) var error: String?
    private var levels: [String: Double] {          // key -> gain, 1 = untouched (persisted)
        get { UserDefaults.standard.dictionary(forKey: "mixerLevels") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "mixerLevels") }
    }
    private var mutedKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "mixerMuted") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "mixerMuted") }
    }
    private var lastSeen: [String: Date] = [:]
    private var icons: [String: String] = [:]
    private let ownBundle = Bundle.main.bundleIdentifier ?? ""

    // engine
    private var tapIDs: [AudioObjectID] = []
    private var engineKeys: [String] = []
    private var engineObjects: [AudioObjectID] = []
    private var engineOutput: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private let gains = UnsafeMutablePointer<Float>.allocate(capacity: 64)   // read by the IO thread
    private let ioQueue = DispatchQueue(label: "com.ltw.wallpaper.mixer")
    private let engineQueue = DispatchQueue(label: "com.ltw.wallpaper.mixer.engine")   // CoreAudio calls can block (permission prompt)
    private(set) var busy = false
    private var listenerInstalled = false

    init() {
        for i in 0..<64 { gains[i] = 1 }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            self?.refresh(force: true)
        }
        var addr2 = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr2, .main) { [weak self] _, _ in
            self?.refresh()
        }
        listenerInstalled = true
    }


    // MARK: Property helpers

    private func address(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ initial: T) -> T? {
        var addr = address(sel, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        return st == noErr ? value : nil
    }

    private func getString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var addr = address(sel)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        let st = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
        guard st == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    private func getArray<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ type: T.Type) -> [T] {
        var addr = address(sel, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let n = Int(size) / MemoryLayout<T>.stride
        var out = [T](unsafeUninitializedCapacity: n) { buf, count in
            let st = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, buf.baseAddress!)
            count = st == noErr ? Int(size) / MemoryLayout<T>.stride : 0
        }
        if out.count > n { out.removeLast(out.count - n) }
        return out
    }

    @discardableResult
    private func set<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ value: T) -> Bool {
        var addr = address(sel, scope)
        var v = value
        return AudioObjectSetPropertyData(obj, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v) == noErr
    }

    // MARK: Devices

    var defaultOutput: AudioObjectID {
        return self.get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0)) ?? 0
    }

    func outputDevices() -> [Device] {
        getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, AudioObjectID.self).compactMap { id in
            guard id != aggregateID,
                  !getArray(id, kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput, AudioObjectID.self).isEmpty,
                  let uid = getString(id, kAudioDevicePropertyDeviceUID), let name = getString(id, kAudioObjectPropertyName),
                  !uid.hasPrefix("com.ltw.wallpaper") else { return nil }
            return Device(id: id, uid: uid, name: name)
        }
    }

    func setOutput(uid: String) {
        guard let d = outputDevices().first(where: { $0.uid == uid }) else { return }
        set(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, d.id)
    }

    var masterVolume: Double {
        get { Double(self.get(defaultOutput, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(0)) ?? 0) }
        set { set(defaultOutput, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput, Float32(max(0, min(1, newValue)))) }
    }

    var masterMuted: Bool {
        get { (self.get(defaultOutput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(0)) ?? 0) != 0 }
        set { set(defaultOutput, kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, UInt32(newValue ? 1 : 0)) }
    }

    // MARK: Apps

    func volume(for key: String) -> Double { levels[key] ?? 1 }
    func isMuted(_ key: String) -> Bool { mutedKeys.contains(key) }

    func setVolume(_ key: String, _ v: Double) {
        var l = levels
        let g = max(0, min(2, v))
        if abs(g - 1) < 0.005 { l.removeValue(forKey: key) } else { l[key] = g }
        levels = l
        if let i = engineKeys.firstIndex(of: key) { gains[i] = Float(isMuted(key) ? 0 : g) }
        refresh(force: true)
    }

    func setMuted(_ key: String, _ on: Bool) {
        var m = mutedKeys
        if on { m.insert(key) } else { m.remove(key) }
        mutedKeys = m
        if let i = engineKeys.firstIndex(of: key) { gains[i] = Float(on ? 0 : volume(for: key)) }
        refresh(force: true)
    }

    /// After a failed engine build (e.g. permission just granted), try again.
    func retryEngine() {
        engineKeys = []; engineObjects = []; engineOutput = 0
        error = nil
        refresh(force: true)
    }

    /// Re-reads the audio process list; rebuilds the tap engine when the set of controlled apps changed.
    func refresh(force: Bool = false) {
        let objects = getArray(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, AudioObjectID.self)
        var found: [App] = []
        var seen = Set<String>()
        let now = Date()
        for obj in objects {
            guard let pid = get(obj, kAudioProcessPropertyPID, kAudioObjectPropertyScopeGlobal, pid_t(0)), pid > 0 else { continue }
            let bundle = getString(obj, kAudioProcessPropertyBundleID) ?? ""
            if bundle == ownBundle { continue }
            let key = bundle.isEmpty ? "pid:\(pid)" : bundle
            if seen.contains(key) { continue }
            let running = (get(obj, kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, UInt32(0)) ?? 0) != 0
            let ra = NSRunningApplication(processIdentifier: pid)
            var name = ra?.localizedName ?? bundle.components(separatedBy: ".").last ?? "pid \(pid)"
            if name.isEmpty { name = key }
            if running { lastSeen[key] = now }
            let controlled = levels[key] != nil || mutedKeys.contains(key)
            let recent = (lastSeen[key].map { now.timeIntervalSince($0) } ?? 999) < 120
            guard running || controlled || recent else { continue }
            if ra?.activationPolicy == .prohibited && !running && !controlled { continue }   // background helpers only while audible
            seen.insert(key)
            if icons[key] == nil, let img = ra?.icon { icons[key] = Self.png(img, size: 36) }
            found.append(App(key: key, name: name, pid: pid, objectID: obj, running: running, icon: icons[key]))
        }
        found.sort { ($0.running ? 0 : 1, $0.name.lowercased()) < ($1.running ? 0 : 1, $1.name.lowercased()) }
        // Tools without a bundle id are keyed by pid; forget their levels once the process is gone.
        let live = Set(found.map { $0.key })
        let stale = levels.keys.filter { $0.hasPrefix("pid:") && !live.contains($0) }
        if !stale.isEmpty { var l = levels; stale.forEach { l.removeValue(forKey: $0) }; levels = l }
        let staleMuted = mutedKeys.filter { $0.hasPrefix("pid:") && !live.contains($0) }
        if !staleMuted.isEmpty { mutedKeys = mutedKeys.subtracting(staleMuted) }
        let changed = found.map { "\($0.key)\($0.running)" } != apps.map { "\($0.key)\($0.running)" }
        apps = found
        if changed || force { log.notice("mixer: \(objects.count) audio processes, listed \(found.map { "\($0.key)\($0.running ? "*" : "")" }.joined(separator: " "), privacy: .public)") }
        rebuildEngineIfNeeded()
        if changed || force { onChange?() }
    }

    private static func png(_ img: NSImage, size: CGFloat) -> String? {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size * 2), pixelsHigh: Int(size * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    func state() -> [String: Any] {
        let out = defaultOutput
        let outUID = getString(out, kAudioDevicePropertyDeviceUID) ?? ""
        return [
            "outputs": outputDevices().map { ["uid": $0.uid, "name": $0.name] },
            "output": outUID,
            "master": masterVolume,
            "masterMuted": masterMuted,
            "apps": apps.map { a -> [String: Any] in
                ["key": a.key, "name": a.name, "running": a.running, "volume": volume(for: a.key),
                 "muted": isMuted(a.key), "icon": a.icon ?? NSNull(), "controlled": engineKeys.contains(a.key)]
            },
            "error": error ?? NSNull(),
            "busy": busy,
        ]
    }

    // MARK: Tap engine

    private func rebuildEngineIfNeeded() {
        let wanted = apps.filter { levels[$0.key] != nil || mutedKeys.contains($0.key) }
        let keys = wanted.map { $0.key }, objs = wanted.map { $0.objectID }
        let out = defaultOutput
        if keys == engineKeys, objs == engineObjects, out == engineOutput { return }
        engineKeys = keys; engineObjects = objs; engineOutput = out
        let gains = (0..<keys.count).map { Float(mutedKeys.contains(keys[$0]) ? 0 : (levels[keys[$0]] ?? 1)) }
        busy = true
        engineQueue.async { [self] in
            self.teardownEngineSync()
            if !keys.isEmpty, out != 0 { self.buildEngine(objects: objs, output: out, gains: gains) }
            DispatchQueue.main.async { self.busy = false; self.onChange?() }
        }
    }

    private func ms(_ t0: Date) -> Int { Int(Date().timeIntervalSince(t0) * 1000) }

    private func buildEngine(objects: [AudioObjectID], output: AudioObjectID, gains initialGains: [Float]) {
        error = nil
        let t0 = Date()
        guard #available(macOS 14.2, *) else { error = "Per-app volume needs macOS 14.2 or newer."; return }
        guard let outUID = getString(output, kAudioDevicePropertyDeviceUID) else { return }
        var tapList: [[String: Any]] = []
        for (i, obj) in objects.enumerated() where i < 64 {
            let desc = CATapDescription(stereoMixdownOfProcesses: [obj])
            desc.uuid = UUID()
            desc.muteBehavior = .mutedWhenTapped
            desc.isPrivate = true
            desc.name = "Ltw Mixer tap"
            var tapID = AudioObjectID(0)
            let st = AudioHardwareCreateProcessTap(desc, &tapID)
            log.notice("mixer: tap \(i) created in \(self.ms(t0)) ms (status \(st))")
            guard st == noErr else {
                log.notice("mixer: tap failed \(st)")
                error = "Could not tap app audio (\(st)). Allow “System Audio Recording” for Ltw Wallpaper in System Settings → Privacy & Security."
                teardownEngineSync(keepKeys: true)
                return
            }
            tapIDs.append(tapID)
            tapList.append([kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true])
            gains[i] = initialGains[i]
        }
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ltw Mixer",
            kAudioAggregateDeviceUIDKey: "com.ltw.wallpaper.mixer",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: tapList,
        ]
        var agg = AudioObjectID(0)
        let aggStatus = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        log.notice("mixer: aggregate created at \(self.ms(t0)) ms (status \(aggStatus))")
        guard aggStatus == noErr else {
            error = "Could not create the mixer device."; teardownEngineSync(keepKeys: true); return
        }
        aggregateID = agg
        let gains = self.gains
        let tapCount = objects.count
        let st = AudioDeviceCreateIOProcIDWithBlock(&ioProc, agg, ioQueue) { _, inInput, _, outOutput, _ in
            let outList = UnsafeMutableAudioBufferListPointer(outOutput)
            for b in outList { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            // One interleaved buffer per tap, in tap-list order; output buffers may be interleaved or one per channel.
            for (t, inBuf) in inList.enumerated() where t < tapCount {
                let g = gains[t]
                guard g > 0, let ip = inBuf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let cin = Int(inBuf.mNumberChannels); if cin == 0 { continue }
                let frames = Int(inBuf.mDataByteSize) / (4 * cin)
                var outChan = 0
                for ob in outList {
                    guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                    let cout = Int(ob.mNumberChannels)
                    let oframes = min(frames, Int(ob.mDataByteSize) / (4 * max(1, cout)))
                    for c in 0..<cout {
                        let src = min(outChan + c, cin - 1)
                        var f = 0
                        while f < oframes { op[f * cout + c] += ip[f * cin + src] * g; f += 1 }
                    }
                    outChan += cout
                }
            }
            // keep boosted audio inside the legal range
            for ob in outList {
                guard let op = ob.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let n = Int(ob.mDataByteSize) / 4
                var i = 0
                while i < n { if op[i] > 1 { op[i] = 1 } else if op[i] < -1 { op[i] = -1 }; i += 1 }
            }
        }
        log.notice("mixer: io proc created at \(self.ms(t0)) ms (status \(st))")
        guard st == noErr, let proc = ioProc, AudioDeviceStart(agg, proc) == noErr else {
            error = "Could not start the mixer device."; teardownEngineSync(keepKeys: true); return
        }
        log.notice("mixer: engine up at \(self.ms(t0)) ms, \(objects.count) tap(s), output \(outUID, privacy: .public)")
    }

    /// Stops everything; safe to call from the main thread (e.g. on quit).
    func teardownEngine() {
        engineKeys = []; engineObjects = []; engineOutput = 0
        engineQueue.sync { teardownEngineSync() }
    }

    private func teardownEngineSync(keepKeys: Bool = false) {
        let t0 = Date()
        defer { if aggregateID != 0 || !tapIDs.isEmpty { } else if ms(t0) > 5 { log.notice("mixer: teardown took \(self.ms(t0)) ms") } }
        if let proc = ioProc, aggregateID != 0 {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if #available(macOS 14.2, *) { for t in tapIDs { AudioHardwareDestroyProcessTap(t) } }
        tapIDs = []
        if !keepKeys { engineKeys = []; engineObjects = []; engineOutput = 0 }
    }
}
