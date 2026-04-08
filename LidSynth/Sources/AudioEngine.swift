import AVFoundation
import Foundation

final class AudioEngine {
    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?

    // ── Synth state (audio thread r/w) ──
    private var targetFreq: Double = 0
    private var smoothFreq: Double = 0
    private var phase: Double = 0
    private var volume: Double = 0.22

    // Harmonics: fixed-size C buffer for thread safety
    private let maxHarmonics = 16
    private let harmonicsBuf: UnsafeMutablePointer<Double>
    private var harmonicsCount: Int = 0

    // ADSR
    private let spb = Double(kBlockSize) / kSampleRate
    private var envLevel: Double = 0
    private var envPhase: EnvPhase = .idle
    private lazy var attackRate:  Double = { spb / 0.04 }()
    private lazy var decayRate:   Double = { spb / 0.15 }()
    private let sustainLvl: Double = 0.72
    private lazy var releaseRate: Double = { spb / 0.10 }()

    // Crossfade
    private let xfadeN = 256
    private var xfadePos = 256
    private var xfadeOldPhase: Double = 0
    private var xfadeOldFreq: Double = 0
    private var xfadeOldEnv: Double = 0

    // Note events
    private var noteTrigger = false
    private var noteRelease = false

    // Mode / config
    private var mode: SynthMode = .glide
    private var bpm: Double = 120
    private var muted = true

    // Rhythm
    private var rhythmPhase: Double = 0

    // Waveform: fixed-size C buffer
    private let waveBufSize = 2048
    private let waveBuf: UnsafeMutablePointer<Float>
    private var waveBufPos: Int = 0

    // Beat flash
    private(set) var beatFlash = false

    // ── System audio mixing ──
    var systemAudio: SystemAudioCapture?
    private var mixSystemAudio = false
    private var filterAngle: Double = 90  // 0~180, controls lowpass cutoff

    // Biquad lowpass filter state
    private var lpX1: Double = 0, lpX2: Double = 0
    private var lpY1: Double = 0, lpY2: Double = 0
    private var lpB0: Double = 1, lpB1: Double = 0, lpB2: Double = 0
    private var lpA1: Double = 0, lpA2: Double = 0

    // Temp buffer for system audio read
    private let sysBuf: UnsafeMutablePointer<Float>

    init() {
        waveBuf = .allocate(capacity: 2048)
        waveBuf.initialize(repeating: 0, count: 2048)

        sysBuf = .allocate(capacity: 1024)
        sysBuf.initialize(repeating: 0, count: 1024)

        harmonicsBuf = .allocate(capacity: 16)
        harmonicsBuf.initialize(repeating: 0, count: 16)

        let h = InstrumentType.theremin.harmonics
        for (i, v) in h.enumerated() { harmonicsBuf[i] = v }
        harmonicsCount = h.count

        updateFilter(cutoff: 20000)
    }

    deinit {
        waveBuf.deallocate()
        sysBuf.deallocate()
        harmonicsBuf.deallocate()
    }

    // MARK: - Public setters (main thread)

    func setTargetFreq(_ f: Double)  { targetFreq = f }
    func setVolume(_ v: Double)      { volume = v }
    func setMuted(_ m: Bool)         { muted = m }
    func setBpm(_ b: Double)         { bpm = b }
    func triggerNote()               { noteTrigger = true }
    func releaseNote()               { noteRelease = true }

    func setMixSystemAudio(_ on: Bool) { mixSystemAudio = on }

    /// 힌지 각도로 필터 cutoff 설정 (0°=200Hz, 180°=20kHz, 로그 스케일)
    func setFilterAngle(_ angle: Double) {
        filterAngle = angle
        let r = max(0, min(angle, 180)) / 180.0
        let cutoff = 200.0 * pow(100.0, r)  // 200Hz ~ 20000Hz log scale
        updateFilter(cutoff: min(cutoff, 20000))
    }

    func setHarmonics(_ h: [Double]) {
        let count = min(h.count, maxHarmonics)
        for i in 0..<count { harmonicsBuf[i] = h[i] }
        for i in count..<maxHarmonics { harmonicsBuf[i] = 0 }
        harmonicsCount = count
    }

    func setMode(_ m: SynthMode) {
        mode = m
        rhythmPhase = 0
        envLevel = 0
        envPhase = .idle
        noteTrigger = false
        noteRelease = false
    }

    func copyWaveform() -> [Float] {
        let pos = waveBufPos
        var out = [Float](repeating: 0, count: waveBufSize)
        for i in 0..<waveBufSize {
            out[i] = waveBuf[(pos + i) % waveBufSize]
        }
        return out
    }

    func consumeBeatFlash() -> Bool {
        guard beatFlash else { return false }
        beatFlash = false
        return true
    }

    // MARK: - Biquad Lowpass Filter

    private func updateFilter(cutoff: Double) {
        let w0 = 2.0 * Double.pi * cutoff / kSampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * 0.707)  // Q = 0.707 (Butterworth)

        let b0 = (1.0 - cosW0) / 2.0
        let b1 = 1.0 - cosW0
        let b2 = (1.0 - cosW0) / 2.0
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha

        lpB0 = b0 / a0
        lpB1 = b1 / a0
        lpB2 = b2 / a0
        lpA1 = a1 / a0
        lpA2 = a2 / a0
    }

    private func applyFilter(_ x: Double) -> Double {
        let y = lpB0 * x + lpB1 * lpX1 + lpB2 * lpX2 - lpA1 * lpY1 - lpA2 * lpY2
        lpX2 = lpX1; lpX1 = x
        lpY2 = lpY1; lpY1 = y
        return y
    }

    // MARK: - Start / Stop

    func start() {
        let format = AVAudioFormat(standardFormatWithSampleRate: kSampleRate, channels: 1)!

        sourceNode = AVAudioSourceNode { [unowned self] _, _, frameCount, bufferList -> OSStatus in
            let frames = Int(frameCount)
            let buf = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buf[0].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            self.render(into: data, frames: frames)
            return noErr
        }

        engine.attach(sourceNode!)
        engine.connect(sourceNode!, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 1.0

        do {
            try engine.start()
        } catch {
            fputs("AudioEngine start failed: \(error)\n", stderr)
        }
    }

    func stop() {
        engine.stop()
    }

    // MARK: - Render (audio thread)

    private func render(into data: UnsafeMutablePointer<Float>, frames: Int) {
        let currentMode = mode
        let hCount = harmonicsCount
        let vol = volume
        let isMuted = muted
        let doMix = mixSystemAudio

        // ── Rhythm clock ──
        if currentMode == .rhythm {
            rhythmPhase += bpm / 60.0 * Double(frames) / kSampleRate
            if rhythmPhase >= 1.0 {
                rhythmPhase -= 1.0
                if targetFreq > 20 {
                    noteTrigger = true
                    beatFlash = true
                }
            }
        }

        // ── Note events ──
        if currentMode != .glide {
            if noteRelease {
                noteRelease = false
                envPhase = .release
            }
            if noteTrigger {
                noteTrigger = false
                if envLevel > 0.001 && smoothFreq > 20 {
                    xfadeOldPhase = phase
                    xfadeOldFreq = smoothFreq
                    xfadeOldEnv = envLevel
                    xfadePos = 0
                }
                smoothFreq = targetFreq
                phase = 0
                envLevel = 0
                envPhase = .attack
            }
        }

        // ── Frequency smoothing ──
        if currentMode == .glide {
            smoothFreq += (targetFreq - smoothFreq) * 0.04
        } else {
            smoothFreq = targetFreq
        }

        // ── ADSR ──
        let envStart = envLevel
        if currentMode != .glide {
            switch envPhase {
            case .attack:
                envLevel = min(1.0, envLevel + attackRate)
                if envLevel >= 1.0 { envPhase = .decay }
            case .decay:
                envLevel = max(sustainLvl, envLevel - decayRate)
                if envLevel <= sustainLvl { envPhase = .sustain }
            case .release:
                envLevel = max(0.0, envLevel - releaseRate)
                if envLevel <= 0.0 { envPhase = .idle }
            default:
                break
            }
        }

        // ── Read system audio ──
        if doMix, let sysCapture = systemAudio, sysCapture.isCapturing {
            _ = sysCapture.readSamples(into: sysBuf, count: frames)
        } else {
            for i in 0..<frames { sysBuf[i] = 0 }
        }

        // ── Generate samples ──
        let active = smoothFreq >= 20 && (
            currentMode == .glide || !(envStart < 0.001 && envLevel < 0.001)
        )

        let freq = smoothFreq
        let hBuf = harmonicsBuf

        for i in 0..<frames {
            let t = Double(i)
            let envVal: Double
            if currentMode != .glide {
                let frac = Double(i) / Double(max(frames - 1, 1))
                envVal = envStart + (envLevel - envStart) * frac
            } else {
                envVal = 1.0
            }

            // Synth sample
            var synthSample: Double = 0
            if active {
                let p = phase + 2.0 * .pi * freq * t / kSampleRate
                for idx in 0..<hCount {
                    synthSample += hBuf[idx] * sin(Double(idx + 1) * p)
                }
                synthSample *= envVal * vol
            }

            // Crossfade old note
            if xfadePos < xfadeN {
                let px = xfadeOldPhase + 2.0 * .pi * xfadeOldFreq * Double(i) / kSampleRate
                var old: Double = 0
                for idx in 0..<hCount {
                    old += hBuf[idx] * sin(Double(idx + 1) * px)
                }
                let fade = xfadeOldEnv * (1.0 - Double(xfadePos) / Double(xfadeN))
                synthSample += old * fade * vol
                if i == frames - 1 { xfadePos += frames }
            }

            // System audio with lowpass filter
            let sysSample = doMix ? applyFilter(Double(sysBuf[i])) : 0

            // Mix
            let mixed = (isMuted ? 0 : synthSample) + sysSample
            let clipped = Float(max(-1.0, min(1.0, mixed)))
            data[i] = clipped

            // Waveform ring buffer (always write mixed output)
            waveBuf[(waveBufPos + i) % waveBufSize] = clipped
        }
        waveBufPos = (waveBufPos + frames) % waveBufSize

        // Update phase
        if active {
            phase += 2.0 * .pi * freq * Double(frames) / kSampleRate
            phase = phase.truncatingRemainder(dividingBy: 2.0 * .pi)
        } else if currentMode == .glide {
            phase = 0
        }

        if xfadePos < xfadeN {
            xfadeOldPhase += 2.0 * .pi * xfadeOldFreq * Double(frames) / kSampleRate
            xfadeOldPhase = xfadeOldPhase.truncatingRemainder(dividingBy: 2.0 * .pi)
        }
    }
}
