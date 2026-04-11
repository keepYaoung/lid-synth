import AVFoundation
import Darwin  // OSMemoryBarrier
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
    private var mode: SynthMode = .vinyl
    private var bpm: Double = 120
    private var muted = true

    // Percussion state
    private var percType: InstrumentType = .theremin
    private var percSamplePos: Int = 0      // position in one-shot percussion
    private var percTriggered: Bool = false  // new hit triggered

    // Rhythm
    private var rhythmPhase: Double = 0

    // Waveform: fixed-size C buffer
    private let waveBufSize = 2048
    private let waveBuf: UnsafeMutablePointer<Float>
    private var waveBufPos: Int = 0

    // Beat flash
    private(set) var beatFlash = false

    // ── Audio source ──
    var audioSource: AudioSourceManager?
    private var mixSystemAudio = false
    private var filterAngle: Double = 90  // 0~180, controls lowpass cutoff

    // Biquad lowpass filter state
    private var lpX1: Double = 0, lpX2: Double = 0
    private var lpY1: Double = 0, lpY2: Double = 0
    private var lpB0: Double = 1, lpB1: Double = 0, lpB2: Double = 0
    private var lpA1: Double = 0, lpA2: Double = 0

    // ── Filter Sweep state ──
    private var filterType: FilterType = .lowPass
    private var fsB0: Double = 1, fsB1: Double = 0, fsB2: Double = 0
    private var fsA1: Double = 0, fsA2: Double = 0
    private var fsX1: Double = 0, fsX2: Double = 0
    private var fsY1: Double = 0, fsY2: Double = 0
    private var compressorEnabled: Bool = false

    // ── Vinyl scratch state ──
    // Wavetable fallback (when no system audio)
    private let scratchWaveLen = 2048
    private let scratchWave: UnsafeMutablePointer<Double>
    private var scratchPhase: Double = 0
    // System audio scratch buffer (~2 seconds)
    private let scratchBufSize = 132300  // ~3 seconds at 44100
    private let scratchBuf: UnsafeMutablePointer<Float>
    private var scratchWritePos: Int = 0
    private var scratchReadPos: Double = 0
    // Shared scratch state
    private var scratchRateTarget: Double = 0  // set from main thread
    private var scratchRate: Double = 0
    private var scratchDebugCount: Int = 0
    private var scratchEnvLevel: Double = 0
    // CDJ state machine
    private var scratchState: ScratchState = .scratching
    private var scratchAdvance: Double = 0  // samples/sample during scratch
    // File direct playback position (fractional for interpolation)
    private var filePlayPos: Double = 0

    // Temp buffer for system audio read
    private let sysBuf: UnsafeMutablePointer<Float>

    init() {
        waveBuf = .allocate(capacity: 2048)
        waveBuf.initialize(repeating: 0, count: 2048)

        sysBuf = .allocate(capacity: 1024)
        sysBuf.initialize(repeating: 0, count: 1024)

        scratchWave = .allocate(capacity: 2048)
        scratchWave.initialize(repeating: 0, count: 2048)

        scratchBuf = .allocate(capacity: 132300)
        scratchBuf.initialize(repeating: 0, count: 132300)

        harmonicsBuf = .allocate(capacity: 16)
        harmonicsBuf.initialize(repeating: 0, count: 16)

        let h = InstrumentType.theremin.harmonics
        for (i, v) in h.enumerated() { harmonicsBuf[i] = v }
        harmonicsCount = h.count

        rebuildScratchWave()
        updateFilter(cutoff: 20000)
    }

    deinit {
        waveBuf.deallocate()
        sysBuf.deallocate()
        scratchWave.deallocate()
        scratchBuf.deallocate()
        harmonicsBuf.deallocate()
    }

    // MARK: - Public setters (main thread)

    func setTargetFreq(_ f: Double)  { targetFreq = f }
    func setVolume(_ v: Double)      { volume = v }
    func setMuted(_ m: Bool) {
        muted = m
        if !m {
            smoothFreq = targetFreq  // unmute → sync freq immediately
            phase = 0                // reset phase for clean start
        }
    }
    func setBpm(_ b: Double)         { bpm = b }
    func triggerNote()               { noteTrigger = true }
    func releaseNote()               { noteRelease = true }

    func setMixSystemAudio(_ on: Bool) { mixSystemAudio = on }
    func setScratchRate(_ rate: Double) { scratchRateTarget = rate }
    func setScratchState(_ state: ScratchState) { scratchState = state }
    func setScratchAdvance(_ advance: Double) { scratchAdvance = advance }
    func resetPlayPosition() {
        filePlayPos = 0
        scratchReadPos = 0
        scratchEnvLevel = 0
    }

    /// 힌지 각도로 필터 cutoff 설정 (0°=200Hz, 180°=20kHz, 로그 스케일)
    func setFilterAngle(_ angle: Double) {
        filterAngle = angle
        let r = max(0, min(angle, 180)) / 180.0
        let cutoff = 200.0 * pow(100.0, r)  // 200Hz ~ 20000Hz log scale
        updateFilter(cutoff: min(cutoff, 20000))
        if mode == .filter {
            updateFilterSweep(cutoff: min(cutoff, 20000))
        }
    }

    func setHarmonics(_ h: [Double]) {
        let count = min(h.count, maxHarmonics)
        for i in 0..<count { harmonicsBuf[i] = h[i] }
        for i in count..<maxHarmonics { harmonicsBuf[i] = 0 }
        OSMemoryBarrier()
        harmonicsCount = count
        rebuildScratchWave()
    }

    func setPercType(_ type: InstrumentType) {
        percType = type
    }

    func setFilterType(_ type: FilterType) {
        filterType = type
        // Reset filter state to avoid clicks on type switch
        fsX1 = 0; fsX2 = 0; fsY1 = 0; fsY2 = 0
    }

    func setCompressorEnabled(_ on: Bool) {
        compressorEnabled = on
    }

    /// Pre-render one cycle of current harmonics into scratch wavetable.
    private func rebuildScratchWave() {
        let n = scratchWaveLen
        let hCount = harmonicsCount
        for i in 0..<n {
            let p = 2.0 * Double.pi * Double(i) / Double(n)
            var sample: Double = 0
            for h in 0..<hCount {
                sample += harmonicsBuf[h] * sin(Double(h + 1) * p)
            }
            scratchWave[i] = sample
        }
    }

    func setMode(_ m: SynthMode) {
        mode = m
        rhythmPhase = 0
        envLevel = 0
        envPhase = .idle
        noteTrigger = false
        noteRelease = false
        // Reset scratch state
        scratchRateTarget = 0
        scratchRate = 0
        scratchEnvLevel = 0
        scratchPhase = 0
        scratchState = .scratching
        scratchAdvance = 0
        filePlayPos = 0
        scratchReadPos = 0
        // Reset percussion
        percTriggered = false
        percSamplePos = 0
        if m == .filter {
            // Reset filter sweep state
            fsX1 = 0; fsX2 = 0; fsY1 = 0; fsY2 = 0
            updateFilterSweep(cutoff: 1000)
        }
        if m == .glide {
            // Sync smoothFreq so sound starts immediately
            smoothFreq = targetFreq
            phase = 0
        }
        if m == .vinyl {
            // Start reading ~1s behind write position (middle of 3s buffer)
            let wPos = audioSource?.scratchWritePos ?? 0
            scratchReadPos = Double((wPos + scratchBufSize - 44100) % scratchBufSize)
        }
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

    /// Generate one sample of percussion at given sample position.
    /// Returns 0 when the one-shot is done.
    private func percSample(pos: Int, type: InstrumentType, vol: Double) -> Double {
        let t = Double(pos) / kSampleRate  // time in seconds

        switch type {
        case .kick:
            // Kick: pitch-dropping sine + click transient
            // Frequency sweeps from 150Hz down to 50Hz
            let pitchEnv = 150.0 * exp(-20.0 * t) + 50.0
            let ampEnv = exp(-5.0 * t)
            let click = pos < 30 ? exp(-Double(pos) / 5.0) * 0.6 : 0.0
            let phase = 2.0 * .pi * pitchEnv * t
            return (sin(phase) * ampEnv + click) * vol
        case .snare:
            // Snare: short tone body + noise
            let toneEnv = exp(-20.0 * t)
            let noiseEnv = exp(-8.0 * t)
            let tone = sin(2.0 * .pi * 180.0 * t) * toneEnv * 0.5
            let noise = Double.random(in: -1...1) * noiseEnv * 0.7
            return (tone + noise) * vol
        case .hihat:
            // Hi-hat: filtered noise, very short
            let env = exp(-30.0 * t)
            let noise = Double.random(in: -1...1)
            // Simple highpass feel: subtract low freq
            return noise * env * vol * 0.6
        default:
            return 0
        }
    }

    // MARK: - Filter Sweep (LP/BP/HP)

    private func updateFilterSweep(cutoff: Double) {
        let clamped = max(20, min(cutoff, 20000))
        let w0 = 2.0 * Double.pi * clamped / kSampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)

        let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double

        switch filterType {
        case .lowPass:
            let alpha = sinW0 / (2.0 * 0.707)  // Q=0.707 Butterworth
            b0 = (1.0 - cosW0) / 2.0
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .bandPass:
            let alpha = sinW0 / (2.0 * 3.0)  // Q=3.0 narrow band
            b0 = alpha
            b1 = 0
            b2 = -alpha
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        case .highPass:
            let alpha = sinW0 / (2.0 * 0.707)
            b0 = (1.0 + cosW0) / 2.0
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) / 2.0
            a0 = 1.0 + alpha
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha
        }

        fsB0 = b0 / a0; fsB1 = b1 / a0; fsB2 = b2 / a0
        fsA1 = a1 / a0; fsA2 = a2 / a0
    }

    private func applyFilterSweep(_ x: Double) -> Double {
        let y = fsB0 * x + fsB1 * fsX1 + fsB2 * fsX2 - fsA1 * fsY1 - fsA2 * fsY2
        fsX2 = fsX1; fsX1 = x
        fsY2 = fsY1; fsY1 = y
        return y
    }

    private func applyCompressor(_ x: Double) -> Double {
        let threshold = 0.3
        let ratio = 4.0
        let abs_x = abs(x)
        guard abs_x > threshold else { return x }
        let over = abs_x - threshold
        let compressed = threshold + over / ratio
        return x > 0 ? compressed : -compressed
    }

    private func applyFilter(_ x: Double) -> Double {
        let y = lpB0 * x + lpB1 * lpX1 + lpB2 * lpX2 - lpA1 * lpY1 - lpA2 * lpY2
        lpX2 = lpX1; lpX1 = x
        lpY2 = lpY1; lpY1 = y
        return y
    }

    // MARK: - Start / Stop

    func start() {
        // Register scratch buffer with audio source for direct writes
        audioSource?.registerScratchBuffer(scratchBuf, size: scratchBufSize)

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

        // ── Vinyl mode: CDJ-style turntable ──
        // PLAYING = normal 1x forward, SCRATCHING = playhead follows hinge
        if currentMode == .vinyl {
            let state = scratchState
            let src = audioSource
            let isFileSource = src?.currentSource == .file && src?.filePCMLength ?? 0 > 0
            let hasStreamAudio = src?.isCapturing ?? false
            // Rate: playing = 1.0, scratching = hand-driven (0 when finger rests)
            let rate: Double = (state == .playing) ? 1.0 : scratchAdvance
            let isActive = abs(rate) > 0.001

            if isFileSource {
                // ── File: direct PCM read (full song, no buffer limit) ──
                for i in 0..<frames {
                    let targetEnv: Double = isActive ? 1.0 : 0.0
                    let envCoeff = isActive ? 0.3 : 0.01
                    scratchEnvLevel += (targetEnv - scratchEnvLevel) * envCoeff

                    filePlayPos += rate
                    let sample = Double(src!.fileSampleInterp(at: filePlayPos))
                    let out = sample * scratchEnvLevel * vol * 4.0
                    data[i] = Float(max(-1.0, min(1.0, out)))
                    waveBuf[(waveBufPos + i) % waveBufSize] = data[i]
                }
            } else if hasStreamAudio {
                // ── Stream (system audio / mic): scratchBuf ──
                for i in 0..<frames {
                    let targetEnv: Double = isActive ? 1.0 : 0.0
                    let envCoeff = isActive ? 0.3 : 0.01
                    scratchEnvLevel += (targetEnv - scratchEnvLevel) * envCoeff

                    scratchReadPos += rate
                    while scratchReadPos < 0 { scratchReadPos += Double(scratchBufSize) }
                    while scratchReadPos >= Double(scratchBufSize) { scratchReadPos -= Double(scratchBufSize) }

                    let idx0 = Int(scratchReadPos) % scratchBufSize
                    let idx1 = (idx0 + 1) % scratchBufSize
                    let frac = scratchReadPos - floor(scratchReadPos)
                    let sample = Double(scratchBuf[idx0]) * (1.0 - frac) + Double(scratchBuf[idx1]) * frac
                    let out = sample * scratchEnvLevel * vol * 4.0
                    data[i] = Float(max(-1.0, min(1.0, out)))
                    waveBuf[(waveBufPos + i) % waveBufSize] = data[i]
                }
            } else {
                // ── Wavetable fallback ──
                let baseAdvance = 220.0 * Double(scratchWaveLen) / kSampleRate
                let wRate = baseAdvance * rate
                let wLen = scratchWaveLen
                for i in 0..<frames {
                    let targetEnv: Double = isActive ? 1.0 : 0.0
                    let envCoeff = isActive ? 0.3 : 0.015
                    scratchEnvLevel += (targetEnv - scratchEnvLevel) * envCoeff

                    scratchPhase += wRate
                    while scratchPhase < 0 { scratchPhase += Double(wLen) }
                    while scratchPhase >= Double(wLen) { scratchPhase -= Double(wLen) }

                    let idx0 = Int(scratchPhase) % wLen
                    let idx1 = (idx0 + 1) % wLen
                    let frac = scratchPhase - floor(scratchPhase)
                    let sample = scratchWave[idx0] * (1.0 - frac) + scratchWave[idx1] * frac
                    let out = sample * scratchEnvLevel * vol
                    data[i] = Float(max(-1.0, min(1.0, out)))
                    waveBuf[(waveBufPos + i) % waveBufSize] = data[i]
                }
            }
            waveBufPos = (waveBufPos + frames) % waveBufSize
            return
        }

        // ── Filter Sweep mode: system audio passthrough with filter ──
        if currentMode == .filter {
            if let src = audioSource, src.isCapturing {
                _ = src.readSamples(into: sysBuf, count: frames)
            } else {
                for i in 0..<frames { sysBuf[i] = 0 }
            }

            let useComp = compressorEnabled

            for i in 0..<frames {
                var sample = applyFilterSweep(Double(sysBuf[i]))
                if useComp { sample = applyCompressor(sample) }
                let out = Float(max(-1.0, min(1.0, sample)))
                data[i] = out
                waveBuf[(waveBufPos + i) % waveBufSize] = out
            }
            waveBufPos = (waveBufPos + frames) % waveBufSize
            return
        }

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
                if percType.isPercussion {
                    // Percussion: reset one-shot position
                    percSamplePos = 0
                    percTriggered = true
                } else {
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
        }

        // ── Frequency smoothing ──
        if currentMode == .glide {
            // Fast catch-up when far from target (cold start), smooth when close
            let diff = abs(targetFreq - smoothFreq)
            let coeff = diff > 50 ? 0.5 : 0.08
            smoothFreq += (targetFreq - smoothFreq) * coeff
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

        // ── Read system audio for scratch overlay (Command key held) ──
        let shouldMixSys = doMix && currentMode != .vinyl
        if shouldMixSys, let src = audioSource, src.isCapturing {
            _ = src.readSamples(into: sysBuf, count: frames)
            // Feed into scratch ring buffer for scrubbing
            for i in 0..<frames {
                scratchBuf[scratchWritePos] = sysBuf[i]
                scratchWritePos = (scratchWritePos + 1) % scratchBufSize
            }
        } else if !shouldMixSys {
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
            if percType.isPercussion {
                // Percussion: one-shot synthesis (no pitch/envelope, self-contained)
                if percTriggered {
                    let maxLen = Int(kSampleRate * 0.5)  // max 500ms
                    if percSamplePos < maxLen {
                        synthSample = percSample(pos: percSamplePos, type: percType, vol: vol)
                        percSamplePos += 1
                    } else {
                        percTriggered = false
                    }
                }
            } else if active {
                let p = phase + 2.0 * .pi * freq * t / kSampleRate
                for idx in 0..<hCount {
                    synthSample += hBuf[idx] * sin(Double(idx + 1) * p)
                }
                synthSample *= envVal * vol

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
            }

            // Scratch overlay (Command key held): mix scratched system audio on top
            var scratchSample: Double = 0
            if shouldMixSys {
                // Smooth scratch rate: fast attack, moderate decay
                let rCoeff = abs(scratchRateTarget) > abs(scratchRate) ? 0.5 : 0.08
                scratchRate += (scratchRateTarget - scratchRate) * rCoeff

                if abs(scratchRate) > 0.001 || abs(scratchRateTarget) > 0.001 {
                    let overlayRate = scratchRate  // pure scratch
                    scratchReadPos += overlayRate
                    while scratchReadPos < 0 { scratchReadPos += Double(scratchBufSize) }
                    while scratchReadPos >= Double(scratchBufSize) { scratchReadPos -= Double(scratchBufSize) }

                    // Gradually decelerate as readPos approaches writePos to avoid hard jump
                    let dist = Double((scratchWritePos - Int(scratchReadPos) + scratchBufSize) % scratchBufSize)
                    if dist < 1024 && overlayRate > 0 {
                        let fade = max(0, (dist - 256) / 768.0)  // 1.0 at 1024, 0.0 at 256
                        scratchReadPos -= overlayRate  // undo the advance above
                        scratchReadPos += overlayRate * fade  // re-advance with deceleration
                        while scratchReadPos < 0 { scratchReadPos += Double(scratchBufSize) }
                        while scratchReadPos >= Double(scratchBufSize) { scratchReadPos -= Double(scratchBufSize) }
                    }

                    let si0 = Int(scratchReadPos) % scratchBufSize
                    let si1 = (si0 + 1) % scratchBufSize
                    let sf = scratchReadPos - floor(scratchReadPos)
                    scratchSample = (Double(scratchBuf[si0]) * (1.0 - sf) + Double(scratchBuf[si1]) * sf) * vol
                }
            }

            // Mix synth + scratch overlay
            let mixed = (isMuted ? 0 : synthSample) + scratchSample
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
