import AVFoundation
import Darwin  // OSMemoryBarrier

/// Unified audio source manager for Vinyl/Filter modes.
/// Wraps SystemAudioCapture, file playback, and microphone recording
/// behind a single buffer interface identical to SystemAudioCapture.
final class AudioSourceManager: NSObject {
    private var _isCapturing = false
    private(set) var currentSource: AudioSource = .system

    /// Live capturing status — proxies to system audio when active
    var isCapturing: Bool {
        if currentSource == .system { return systemAudio.isCapturing }
        return _isCapturing
    }

    // MARK: - Ring buffer for mic (same pattern as SystemAudioCapture)
    private let bufSize = 32768
    private let ringBuf: UnsafeMutablePointer<Float>
    private var writePos: Int = 0
    private var readPos: Int = 0

    // Direct scratch buffer (registered by AudioEngine)
    private var scratchBuf: UnsafeMutablePointer<Float>?
    private var scratchBufSize: Int = 0
    private var _scratchWritePos: Int = 0

    /// Live write position — proxies to active source's counter
    var scratchWritePos: Int {
        switch currentSource {
        case .system: return systemAudio.scratchWritePos
        case .mic:    return _scratchWritePos
        case .file:   return 0
        }
    }

    // MARK: - System audio
    let systemAudio = SystemAudioCapture()

    // MARK: - File playback (direct PCM access)
    private var filePCM: UnsafeMutablePointer<Float>?
    private(set) var filePCMLength: Int = 0
    private var fileReadPos: Int = 0      // for readSamples (filter mode)
    private var fileTimer: DispatchSourceTimer?
    private(set) var loadedFileName: String?

    /// Direct file sample access (for vinyl turntable — any position, any direction)
    func fileSample(at pos: Int) -> Float {
        guard let pcm = filePCM, filePCMLength > 0 else { return 0 }
        let wrapped = ((pos % filePCMLength) + filePCMLength) % filePCMLength
        return pcm[wrapped]
    }

    /// Interpolated file sample for smooth playback at fractional positions
    func fileSampleInterp(at pos: Double) -> Float {
        guard let pcm = filePCM, filePCMLength > 0 else { return 0 }
        let len = filePCMLength
        var p = pos.truncatingRemainder(dividingBy: Double(len))
        if p < 0 { p += Double(len) }
        let idx0 = Int(p) % len
        let idx1 = (idx0 + 1) % len
        let frac = Float(p - floor(p))
        return pcm[idx0] * (1.0 - frac) + pcm[idx1] * frac
    }

    // MARK: - Microphone
    private var micEngine: AVAudioEngine?
    private(set) var isMicRecording = false

    override init() {
        ringBuf = .allocate(capacity: 32768)
        ringBuf.initialize(repeating: 0, count: 32768)
        super.init()
    }

    deinit {
        stopCurrentSource()
        ringBuf.deallocate()
        filePCM?.deallocate()
    }

    // MARK: - Public interface (matches SystemAudioCapture)

    func registerScratchBuffer(_ buf: UnsafeMutablePointer<Float>, size: Int) {
        scratchBufSize = size
        // System audio path: register directly on SystemAudioCapture
        systemAudio.registerScratchBuffer(buf, size: size)
        // Also keep reference for file/mic paths
        scratchBuf = buf
    }

    func readSamples(into buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        if currentSource == .system {
            return systemAudio.readSamples(into: buffer, count: count)
        }
        if currentSource == .file {
            // Direct read from PCM — no ring buffer, no timing issues
            guard let pcm = filePCM, filePCMLength > 0 else {
                for i in 0..<count { buffer[i] = 0 }
                return 0
            }
            for i in 0..<count {
                buffer[i] = pcm[fileReadPos]
                fileReadPos = (fileReadPos + 1) % filePCMLength
            }
            return count
        }
        // Mic: read from ring buffer
        OSMemoryBarrier()
        var read = 0
        while read < count {
            let available = (writePos - readPos + bufSize) % bufSize
            if available == 0 { break }
            buffer[read] = ringBuf[readPos % bufSize]
            readPos = (readPos + 1) % bufSize
            read += 1
        }
        if read < count {
            for i in read..<count { buffer[i] = 0 }
        }
        return read
    }

    // MARK: - Source switching

    func start() async {
        await switchSource(.system)
    }

    func stop() {
        stopCurrentSource()
    }

    func switchSource(_ source: AudioSource) async {
        stopCurrentSource()
        currentSource = source
        clearBuffers()

        switch source {
        case .system:
            await systemAudio.start()
            _isCapturing = systemAudio.isCapturing
        case .file:
            startFilePlayback()
        case .mic:
            await startMicrophone()
        }
    }

    private func stopCurrentSource() {
        switch currentSource {
        case .system:
            systemAudio.stop()
        case .file:
            stopFilePlayback()
        case .mic:
            stopMicrophone()
        }
        _isCapturing = false
    }

    private func clearBuffers() {
        writePos = 0
        readPos = 0
        for i in 0..<bufSize { ringBuf[i] = 0 }
        if let sBuf = scratchBuf {
            for i in 0..<scratchBufSize { sBuf[i] = 0 }
            _scratchWritePos = 0
        }
    }

    // MARK: - Write to buffers (mic only)

    private func writeSamplesToBuffers(_ samples: UnsafePointer<Float>, count: Int) {
        // Write to ring buffer
        var wp = writePos
        for i in 0..<count {
            ringBuf[wp % bufSize] = samples[i]
            wp = (wp + 1) % bufSize
        }
        OSMemoryBarrier()
        writePos = wp

        // Write to scratch buffer
        if let sBuf = scratchBuf, scratchBufSize > 0 {
            var sp = _scratchWritePos
            for i in 0..<count {
                sBuf[sp] = samples[i]
                sp = (sp + 1) % scratchBufSize
            }
            OSMemoryBarrier()
            _scratchWritePos = sp
        }
    }

    // MARK: - File playback

    func loadFile(url: URL) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let srcFormat = audioFile.processingFormat
        let dstFormat = AVAudioFormat(standardFormatWithSampleRate: kSampleRate, channels: 1)!

        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0 else {
            throw NSError(domain: "AudioSourceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty audio file"])
        }
        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioSourceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot create source buffer"])
        }
        try audioFile.read(into: srcBuffer)

        // Same format? Skip conversion
        if srcFormat.sampleRate == kSampleRate && srcFormat.channelCount == 1 {
            let length = Int(srcBuffer.frameLength)
            guard length > 0, let channelData = srcBuffer.floatChannelData?[0] else {
                throw NSError(domain: "AudioSourceManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "No audio data"])
            }
            filePCM?.deallocate()
            filePCM = .allocate(capacity: length)
            filePCM!.initialize(from: channelData, count: length)
            filePCMLength = length
            fileReadPos = 0

            loadedFileName = url.lastPathComponent
            fputs("[File] Loaded \(url.lastPathComponent): \(length) samples (\(String(format: "%.1f", Double(length) / kSampleRate))s) — no conversion needed\n", stderr)
            return
        }

        // Convert to mono 44100 Float32
        let ratio = kSampleRate / srcFormat.sampleRate
        let dstFrames = AVAudioFrameCount(Double(frameCount) * ratio) + 1024  // extra headroom
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames) else {
            throw NSError(domain: "AudioSourceManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Cannot create destination buffer"])
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw NSError(domain: "AudioSourceManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Cannot create converter"])
        }

        var isDone = false
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus -> AVAudioBuffer? in
            if isDone {
                outStatus.pointee = .endOfStream
                return nil
            }
            isDone = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        var error: NSError?
        let status = converter.convert(to: dstBuffer, error: &error, withInputFrom: inputBlock)
        if let error { throw error }

        let length = Int(dstBuffer.frameLength)
        guard length > 0 else {
            throw NSError(domain: "AudioSourceManager", code: 6,
                          userInfo: [NSLocalizedDescriptionKey: "Conversion produced 0 frames (status: \(status.rawValue))"])
        }
        guard let channelData = dstBuffer.floatChannelData?[0] else {
            throw NSError(domain: "AudioSourceManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "No channel data after conversion"])
        }

        filePCM?.deallocate()
        filePCM = .allocate(capacity: length)
        filePCM!.initialize(from: channelData, count: length)
        filePCMLength = length
        fileReadPos = 0
        loadedFileName = url.lastPathComponent

        fputs("[File] Loaded \(url.lastPathComponent): \(length) samples (\(String(format: "%.1f", Double(length) / kSampleRate))s)\n", stderr)
    }

    private func startFilePlayback() {
        guard filePCMLength > 0 else {
            fputs("[File] No file loaded\n", stderr)
            _isCapturing = false
            return
        }
        fileReadPos = 0
        _isCapturing = true
        fputs("[File] Playback started: \(loadedFileName ?? "?") (\(filePCMLength) samples)\n", stderr)
    }

    private func stopFilePlayback() {
        // No timer to stop — file reads are direct from PCM
    }

    // MARK: - Microphone

    private func startMicrophone() async {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)

        guard hwFormat.sampleRate > 0 else {
            fputs("[Mic] No audio input available\n", stderr)
            _isCapturing = false
            return
        }

        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: kSampleRate, channels: 1)!

        // Create converter once (not inside callback)
        let needsConversion = !(hwFormat.sampleRate == kSampleRate && hwFormat.channelCount == 1)
        let micConverter = needsConversion ? AVAudioConverter(from: hwFormat, to: monoFormat) : nil
        let ratio = kSampleRate / hwFormat.sampleRate
        let maxOutFrames = AVAudioFrameCount(Double(1024) * ratio) + 64

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if !needsConversion {
                if let data = buffer.floatChannelData?[0] {
                    self.writeSamplesToBuffers(data, count: Int(buffer.frameLength))
                }
            } else if let converter = micConverter {
                guard let outBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: maxOutFrames) else { return }
                let isDone = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
                isDone.initialize(to: false)
                defer {
                    isDone.deinitialize(count: 1)
                    isDone.deallocate()
                }
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus -> AVAudioBuffer? in
                    if isDone.pointee {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    isDone.pointee = true
                    outStatus.pointee = .haveData
                    return buffer
                }
                var error: NSError?
                converter.convert(to: outBuf, error: &error, withInputFrom: inputBlock)
                if let data = outBuf.floatChannelData?[0] {
                    self.writeSamplesToBuffers(data, count: Int(outBuf.frameLength))
                }
            }
        }

        do {
            try engine.start()
            micEngine = engine
            isMicRecording = true
            _isCapturing = true
            fputs("[Mic] Recording started (format: \(hwFormat))\n", stderr)
        } catch {
            fputs("[Mic] Failed to start: \(error)\n", stderr)
            _isCapturing = false
        }
    }

    private func stopMicrophone() {
        micEngine?.inputNode.removeTap(onBus: 0)
        micEngine?.stop()
        micEngine = nil
        isMicRecording = false
    }
}
