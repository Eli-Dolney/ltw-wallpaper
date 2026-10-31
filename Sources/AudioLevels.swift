import Cocoa
import CoreAudio
import AudioToolbox
import Accelerate

/// Listens to everything the Mac is playing (a global process tap, macOS 14.2+) and turns it into a few
/// numbers scenes can react to: overall level, bass/mid/treble, 16 log-spaced bands and a beat flag.
/// Nothing is recorded or kept; the tap is torn down whenever no visible scene asks for audio.
final class AudioLevels {
    struct Frame {
        var level: Float = 0, bass: Float = 0, mid: Float = 0, treble: Float = 0, beat: Bool = false
        var bands = [Float](repeating: 0, count: 16)
        var json: [String: Any] {
            ["level": level, "bass": bass, "mid": mid, "treble": treble, "beat": beat ? 1 : 0, "bands": bands]
        }
    }

    private(set) var running = false
    private(set) var error: String?
    var onFrame: ((Frame) -> Void)?

    private let ioQueue = DispatchQueue(label: "com.ltw.wallpaper.levels.io")
    private let engineQueue = DispatchQueue(label: "com.ltw.wallpaper.levels.engine")
    private var tapID = AudioObjectID(0), aggregateID = AudioObjectID(0)
    private var ioProc: AudioDeviceIOProcID?
    private var sampleRate: Double = 48000

    // Mono ring buffer filled by the IO proc, read by the analysis timer.
    private let N = 1024
    private var ring = [Float](repeating: 0, count: 4096)
    private var ringPos = 0
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var dft: vDSP.DFT<Float>?
    private var window = [Float]()
    private var smooth = [Float](repeating: 0, count: 16)
    private var bassAvg: Float = 0, lastBeat = Date.distantPast
    private var levelSmooth: Float = 0

    func setEnabled(_ on: Bool) {
        if on == running { return }
        running = on
        if on { start() } else { stop() }
    }

    private func start() {
        log.notice("levels: starting system audio tap")
        engineQueue.async { [self] in self.build() }
    }

    private func stop() {
        timer?.cancel(); timer = nil
        engineQueue.async { [self] in self.teardown() }
    }

    private func build() {
        error = nil
        guard #available(macOS 14.2, *) else { error = "Audio-reactive scenes need macOS 14.2 or newer."; return }
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var out = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &out) == noErr, out != 0 else { return }
        var uidAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var uidRef: CFString? = nil; size = UInt32(MemoryLayout<CFString?>.size)
        let uidSt = withUnsafeMutablePointer(to: &uidRef) { AudioObjectGetPropertyData(out, &uidAddr, 0, nil, &size, $0) }
        guard uidSt == noErr, let outUID = uidRef as String? else { return }

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true; desc.name = "Ltw Wallpaper levels"
        var tap = AudioObjectID(0)
        let st = AudioHardwareCreateProcessTap(desc, &tap)
        guard st == noErr else {
            log.notice("levels: tap failed \(st)")
            error = "Allow “System Audio Recording” for Ltw Wallpaper in System Settings → Privacy & Security."
            return
        }
        tapID = tap
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Ltw Levels",
            kAudioAggregateDeviceUIDKey: "com.ltw.wallpaper.levels",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(0)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr else {
            error = "Could not create the audio tap device."; teardown(); return
        }
        aggregateID = agg
        var srAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sr = 0.0; size = UInt32(MemoryLayout<Double>.size)
        if AudioObjectGetPropertyData(agg, &srAddr, 0, nil, &size, &sr) == noErr, sr > 0 { sampleRate = sr }

        let ioSt = AudioDeviceCreateIOProcIDWithBlock(&ioProc, agg, ioQueue) { [self] _, inInput, _, outOutput, _ in
            // Leave the output silent (zeros add nothing to what the other apps play).
            for b in UnsafeMutableAudioBufferListPointer(outOutput) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            guard let buf = inList.first, let p = buf.mData?.assumingMemoryBound(to: Float.self) else { return }
            let ch = max(1, Int(buf.mNumberChannels)), frames = Int(buf.mDataByteSize) / (4 * ch)
            lock.lock()
            for f in 0..<frames {
                var s: Float = 0
                for c in 0..<ch { s += p[f * ch + c] }
                ring[ringPos] = s / Float(ch); ringPos = (ringPos + 1) % ring.count
            }
            lock.unlock()
        }
        guard ioSt == noErr, let proc = ioProc, AudioDeviceStart(agg, proc) == noErr else {
            error = "Could not start the audio tap."; teardown(); return
        }
        dft = vDSP.DFT(count: N, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: N, isHalfWindow: false)
        let t = DispatchSource.makeTimerSource(queue: engineQueue)
        t.schedule(deadline: .now(), repeating: .milliseconds(33))
        t.setEventHandler { [weak self] in self?.analyze() }
        t.resume(); timer = t
        log.notice("levels: tap up at \(Int(self.sampleRate)) Hz")
    }

    private func teardown() {
        if let proc = ioProc, aggregateID != 0 { AudioDeviceStop(aggregateID, proc); AudioDeviceDestroyIOProcID(aggregateID, proc) }
        ioProc = nil
        if aggregateID != 0 { AudioHardwareDestroyAggregateDevice(aggregateID); aggregateID = 0 }
        if #available(macOS 14.2, *), tapID != 0 { AudioHardwareDestroyProcessTap(tapID) }
        tapID = 0
        smooth = [Float](repeating: 0, count: 16); levelSmooth = 0; bassAvg = 0
        log.notice("levels: tap down")
    }

    private func analyze() {
        guard let dft = dft else { return }
        var real = [Float](repeating: 0, count: N)
        lock.lock()
        var i = (ringPos - N + ring.count) % ring.count
        for k in 0..<N { real[k] = ring[i]; i = (i + 1) % ring.count }
        lock.unlock()
        var rms: Float = 0
        vDSP_rmsqv(real, 1, &rms, vDSP_Length(N))
        vDSP.multiply(real, window, result: &real)
        let imag = [Float](repeating: 0, count: N)
        var outR = [Float](repeating: 0, count: N), outI = [Float](repeating: 0, count: N)
        dft.transform(inputReal: real, inputImaginary: imag, outputReal: &outR, outputImaginary: &outI)
        let half = N / 2
        var mags = [Float](repeating: 0, count: half)
        for k in 0..<half { mags[k] = sqrt(outR[k] * outR[k] + outI[k] * outI[k]) / Float(N) * 2 }

        // 16 log-spaced bands, 40 Hz … 16 kHz, in a loudness-ish scale (dB, floored at -60).
        var f = Frame()
        let binHz = Float(sampleRate) / Float(N)
        let lo: Float = 40, hi: Float = 16000
        var peakBand: Float = 0
        for b in 0..<16 {
            let f0 = lo * pow(hi / lo, Float(b) / 16), f1 = lo * pow(hi / lo, Float(b + 1) / 16)
            let k0 = max(1, Int(f0 / binHz)), k1 = min(half - 1, max(k0, Int(f1 / binHz)))
            var m: Float = 0
            for k in k0...k1 { m = max(m, mags[k]) }
            let db = 20 * log10(max(m, 1e-6))
            let v = max(0, min(1, (db + 60) / 55))         // -60 dB → 0, -5 dB → 1
            // Fast attack, slow release so bars feel punchy but do not flicker.
            smooth[b] = v > smooth[b] ? smooth[b] + (v - smooth[b]) * 0.6 : smooth[b] + (v - smooth[b]) * 0.18
            f.bands[b] = smooth[b]
            peakBand = max(peakBand, smooth[b])
        }
        let avg = { (r: Range<Int>) -> Float in r.reduce(Float(0)) { $0 + f.bands[$1] } / Float(r.count) }
        f.bass = avg(0..<4); f.mid = avg(4..<10); f.treble = avg(10..<16)
        let lvl = max(0, min(1, (20 * log10(max(rms, 1e-6)) + 50) / 45))
        levelSmooth = lvl > levelSmooth ? levelSmooth + (lvl - levelSmooth) * 0.5 : levelSmooth + (lvl - levelSmooth) * 0.15
        f.level = levelSmooth
        // Beat: bass energy jumps well above its running average, at most every 250 ms.
        let bassNow = avg(0..<4)
        bassAvg += (bassNow - bassAvg) * 0.08
        if bassNow > 0.3, bassNow > bassAvg * 1.25, Date().timeIntervalSince(lastBeat) > 0.25 { f.beat = true; lastBeat = Date() }
        let frame = f
        DispatchQueue.main.async { [weak self] in self?.onFrame?(frame) }
    }
}
