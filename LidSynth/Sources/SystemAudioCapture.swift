import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Async timeout helper
private func withTimeout<T>(seconds: Double, operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}

/// macOS 시스템 오디오를 ScreenCaptureKit으로 캡처.
/// 캡처된 PCM 샘플을 링버퍼에 저장, AudioEngine에서 읽어감.
@available(macOS 13.0, *)
final class SystemAudioCapture: NSObject, SCStreamOutput {
    private var stream: SCStream?
    private(set) var isCapturing = false

    // Ring buffer (audio thread safe - fixed C buffer)
    private let bufSize = 32768
    private let ringBuf: UnsafeMutablePointer<Float>
    private var writePos: Int = 0
    private var readPos: Int = 0

    override init() {
        ringBuf = .allocate(capacity: 32768)
        ringBuf.initialize(repeating: 0, count: 32768)
        super.init()
    }

    deinit {
        stop()
        ringBuf.deallocate()
    }

    // MARK: - Start / Stop

    func start() async {
        // Check screen capture permission
        let hasAccess = CGPreflightScreenCaptureAccess()
        if !hasAccess {
            fputs("[Audio] No screen capture permission — requesting...\n", stderr)
            CGRequestScreenCaptureAccess()
            // Give user time to grant, then re-check
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard CGPreflightScreenCaptureAccess() else {
                fputs("[Audio] Permission denied — system audio unavailable (vinyl will use wavetable fallback)\n", stderr)
                fputs("[Audio] Grant permission in: System Settings > Privacy & Security > Screen Recording\n", stderr)
                isCapturing = false
                return
            }
        }
        fputs("[Audio] Starting system audio capture...\n", stderr)

        // Use a timeout to prevent hanging when ScreenCaptureKit blocks
        do {
            let content = try await withTimeout(seconds: 5) {
                try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
            }

            let filter = SCContentFilter(
                display: content.displays.first!,
                excludingApplications: [],
                exceptingWindows: []
            )

            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 44100
            config.channelCount = 1
            config.width = 2
            config.height = 2
            config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
            try await newStream.startCapture()

            stream = newStream
            isCapturing = true
            fputs("[Audio] System audio capture started — vinyl will scratch system audio\n", stderr)
        } catch {
            fputs("[Audio] Capture failed: \(error) — vinyl will use wavetable fallback\n", stderr)
            isCapturing = false
        }
    }

    func stop() {
        guard let s = stream else { return }
        Task {
            try? await s.stopCapture()
        }
        stream = nil
        isCapturing = false
    }

    // MARK: - Read samples (called from AudioEngine render thread)

    /// Read up to `count` samples from the ring buffer. Returns actual count read.
    func readSamples(into buffer: UnsafeMutablePointer<Float>, count: Int) -> Int {
        var read = 0
        while read < count {
            let available = (writePos - readPos + bufSize) % bufSize
            if available == 0 { break }
            buffer[read] = ringBuf[readPos % bufSize]
            readPos = (readPos + 1) % bufSize
            read += 1
        }
        // Zero-fill remainder
        if read < count {
            for i in read..<count {
                buffer[i] = 0
            }
        }
        return read
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset = 0

        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: nil, dataPointerOut: &dataPointer
        )
        guard status == noErr, let ptr = dataPointer else { return }

        // ScreenCaptureKit delivers Float32 PCM
        let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float.self)
        let sampleCount = length / MemoryLayout<Float>.size

        for i in 0..<sampleCount {
            ringBuf[writePos % bufSize] = floatPtr[i]
            writePos = (writePos + 1) % bufSize
        }
    }
}
