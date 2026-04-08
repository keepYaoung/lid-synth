import CoreAudio
import Foundation

/// System volume control — mute/restore for Vinyl mode
enum SystemVolume {
    private static var wasMuted: Bool = false
    private static var savedVolume: Float = 0.5

    /// Mute system output
    static func mute() {
        let device = getDefaultOutputDevice()
        wasMuted = getMute(device)
        savedVolume = getVolume(device)
        setMute(device, true)
        fputs("[Volume] System muted (was vol=\(String(format: "%.2f", savedVolume)) muted=\(wasMuted))\n", stderr)
    }

    /// Restore previous mute state
    static func restore() {
        let device = getDefaultOutputDevice()
        setMute(device, wasMuted)
        fputs("[Volume] System restored (muted=\(wasMuted))\n", stderr)
    }

    // MARK: - Core Audio

    private static func getDefaultOutputDevice() -> AudioDeviceID {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return deviceID
    }

    private static func getVolume(_ device: AudioDeviceID) -> Float {
        var volume: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume)
        return volume
    }

    private static func getMute(_ device: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted)
        return muted != 0
    }

    private static func setMute(_ device: AudioDeviceID, _ muted: Bool) {
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: 0
        )
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &value)
    }
}
