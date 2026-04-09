import Foundation

// MARK: - Constants
let kSampleRate: Double = 44100
let kBlockSize: Int = 512
let kAngleMin: Double = 15
let kAngleMax: Double = 175
let kBaseMidi: Int = 48 // C3

// MARK: - Synth Mode
enum SynthMode: String, CaseIterable, Identifiable {
    case vinyl      = "Vinyl"
    case filter     = "Filter"
    case glide      = "Glide"
    case scale      = "Scale"
    case pitchFader = "Fader"
    case rhythm     = "Rhythm"
    var id: String { rawValue }
}

// MARK: - Audio Source
enum AudioSource: String, CaseIterable, Identifiable {
    case system = "System"
    case file   = "File"
    case mic    = "Mic"
    var id: String { rawValue }
}

// MARK: - Filter Type
enum FilterType: String, CaseIterable, Identifiable {
    case lowPass  = "Low-Pass"
    case bandPass = "Band-Pass"
    case highPass = "High-Pass"
    var id: String { rawValue }
}

// MARK: - Scale
enum ScaleType: String, CaseIterable, Identifiable {
    case pentatonic = "Pentatonic"
    case major      = "Major"
    case minor      = "Minor"
    case blues      = "Blues"
    var id: String { rawValue }

    var intervals: [Int] {
        switch self {
        case .pentatonic: [0, 2, 4, 7, 9]
        case .major:      [0, 2, 4, 5, 7, 9, 11]
        case .minor:      [0, 2, 3, 5, 7, 8, 10]
        case .blues:      [0, 3, 5, 6, 7, 10]
        }
    }
}

// MARK: - Instrument
enum InstrumentType: String, CaseIterable, Identifiable {
    case theremin = "Theremin"
    case flute    = "Flute"
    case organ    = "Organ"
    case string   = "String"
    case brass    = "Brass"
    case kick     = "Kick"
    case snare    = "Snare"
    case hihat    = "HiHat"
    var id: String { rawValue }

    var isPercussion: Bool {
        self == .kick || self == .snare || self == .hihat
    }

    var harmonics: [Double] {
        let raw: [Double]
        switch self {
        case .theremin: raw = [0.55, 0.25, 0.12, 0.06, 0.02]
        case .flute:    raw = [0.85, 0.10, 0.04, 0.01]
        case .organ:    raw = [0.40, 0.38, 0.30, 0.20, 0.12, 0.06, 0.03]
        case .string:   raw = [0.45, 0.35, 0.25, 0.15, 0.08, 0.04]
        case .brass:    raw = [0.35, 0.05, 0.30, 0.05, 0.25, 0.05, 0.15, 0.05, 0.08]
        // Percussion: harmonics unused, but provide dummy so arrays aren't empty
        case .kick:     raw = [1.0]
        case .snare:    raw = [1.0]
        case .hihat:    raw = [1.0]
        }
        let total = raw.reduce(0, +)
        return raw.map { $0 / total }
    }
}

// MARK: - Envelope Phase
enum EnvPhase {
    case idle, attack, decay, sustain, release
}

// MARK: - Scratch State (CDJ jog wheel model)
enum ScratchState {
    case playing    // normal forward playback (platter spinning)
    case scratching // playhead follows hinge movement (hand on platter)
}

let kScratchMultiplier: Double = 0.18  // degrees/tick → playback rate mapping

// MARK: - Fader / Vinyl Constants
let kFaderHysteresis: Double = 2.0        // degrees of dead zone at note boundaries
let kVinylDeadZone: Double = 0.3              // degrees per tick (40ms) — tremor filter
let kVinylVelocityThreshold: Double = 7.5     // deg/s display threshold (= deadZone / 0.04)

// MARK: - Velocity Tracker (for Vinyl mode)

struct VelocityTracker {
    private var history: [(angle: Double, time: Double)] = []
    private let windowSize = 5

    mutating func push(angle: Double, time: Double) {
        history.append((angle, time))
        if history.count > windowSize {
            history.removeFirst()
        }
    }

    /// Signed angular velocity in degrees/second (positive = opening)
    func velocity() -> Double {
        guard history.count >= 2,
              let first = history.first,
              let last = history.last else { return 0 }
        let dt = last.time - first.time
        guard dt > 0.001 else { return 0 }
        return (last.angle - first.angle) / dt
    }

    mutating func reset() {
        history.removeAll()
    }
}

// MARK: - Pitch Helpers
func angleToFreqGlide(_ angle: Double) -> Double {
    guard angle >= kAngleMin else { return 0 }
    let r = min((angle - kAngleMin) / (kAngleMax - kAngleMin), 1.0)
    return 130.81 * pow(1046.50 / 130.81, r)
}

func angleToMidi(_ angle: Double, scale: ScaleType) -> Int? {
    guard angle >= kAngleMin else { return nil }
    let intervals = scale.intervals
    let r = min((angle - kAngleMin) / (kAngleMax - kAngleMin), 1.0)
    let total = intervals.count * 3
    let step = Int((r * Double(total - 1)).rounded())
    return kBaseMidi + (step / intervals.count) * 12 + intervals[step % intervals.count]
}

/// Pitch Fader: angle → MIDI note with hysteresis dead zone at boundaries.
func angleToMidiFader(_ angle: Double, scale: ScaleType, prevMidi: Int?) -> Int? {
    guard angle >= kAngleMin else { return nil }
    let intervals = scale.intervals
    let total = intervals.count * 3  // 3 octaves
    let bandWidth = (kAngleMax - kAngleMin) / Double(total)

    func midiForStep(_ step: Int) -> Int {
        kBaseMidi + (step / intervals.count) * 12 + intervals[step % intervals.count]
    }

    func centerAngle(_ step: Int) -> Double {
        kAngleMin + (Double(step) + 0.5) * bandWidth
    }

    // If we have a previous note, apply hysteresis
    if let prev = prevMidi {
        // Find the step index of the previous note
        for s in 0..<total where midiForStep(s) == prev {
            let center = centerAngle(s)
            // Stay on current note if within band + hysteresis margin
            if abs(angle - center) < bandWidth / 2 + kFaderHysteresis {
                return prev
            }
            break
        }
    }

    // No hysteresis lock — pick the nearest step
    let r = min((angle - kAngleMin) / (kAngleMax - kAngleMin), 1.0)
    let step = Int((r * Double(total - 1)).rounded())
    return midiForStep(min(step, total - 1))
}

func midiToFreq(_ midi: Int) -> Double {
    440.0 * pow(2.0, Double(midi - 69) / 12.0)
}

func freqToNote(_ freq: Double) -> String {
    guard freq >= 20 else { return "---" }
    let notes = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    let n = Int((12.0 * log2(freq / 440.0)).rounded()) + 69
    let octave = n / 12 - 1
    return "\(notes[((n % 12) + 12) % 12])\(octave)"
}
