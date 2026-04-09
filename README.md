# hyn*thesizer

A synthesizer you play by opening and closing your MacBook lid.

Tilt the hinge to change pitch, spin a virtual vinyl record, scratch system audio, and apply filters — all controlled by the lid angle.

<img src="src/hynthesizer.png" width="480">

## Features

### 5 Performance Modes
- **Vinyl** — Scratch system audio or a wavetable by opening/closing the lid. Hold Command to overlay scratch on any other mode.
- **Glide** — Continuous pitch change like a theremin
- **Scale** — Quantized scale steps with ADSR envelope (Pentatonic / Major / Minor / Blues)
- **Pitch Fader** — Snap-to-note fader with hysteresis for stable transitions
- **Rhythm** — Auto-trigger notes synced to a BPM clock (40–240 BPM)

### 8 Instruments
- **Melodic:** Theremin, Flute, Organ, String, Brass (additive synthesis with harmonics)
- **Percussion:** Kick, Snare, Hi-Hat (one-shot synthesis)

### Vinyl Record UI
- LP disc rotates in real time based on hinge angle
- Tone arm follows the angle position
- Red label displays current note, instrument, and frequency
- Real-time waveform visualization
- Velocity indicator with direction and spark effects

### MIDI Output
Creates a virtual MIDI port "LidSynth" recognized by any DAW (Ableton, Logic, GarageBand, etc.).
- Note On/Off (Scale / Rhythm / Pitch Fader modes)
- CC messages (Mod Wheel / Volume / Expression / Filter) with deduplication
- Hinge angle mapped to MIDI CC values (0–127)

### System Audio Mixing
Captures audio playing on your Mac via ScreenCaptureKit.
- Lowpass filter controlled by hinge angle (closed = muffled, open = bright)
- Mix synth sound on top of system audio
- Vinyl mode scratches the captured system audio directly

### Output Combinations

| Synth | MIDI | Behavior |
|-------|------|----------|
| ON | ON | Synth + system audio mix |
| OFF | ON | Hinge filter applied to system audio |
| ON | OFF | Synth only |
| OFF | OFF | Silent (default on launch) |

## Requirements

- macOS 14.0+
- Swift 5.9+

### macOS Permissions
- **Screen Recording** — Required for system audio capture (System Settings > Privacy & Security > Screen Recording)

## Build & Run

```bash
cd LidSynth
swift build
.build/debug/LidSynth
```

## Project Structure

```
hynthesizer/
├── lid_synth.py                     # Original Python prototype (tkinter)
├── LidSynth/                        # Swift macOS app
│   ├── Package.swift
│   └── Sources/
│       ├── LidSynthApp.swift        # App entry point
│       ├── ContentView.swift        # Main UI + mode logic
│       ├── VinylView.swift          # Vinyl disc + tone arm animation
│       ├── WaveformView.swift       # Real-time waveform display
│       ├── AudioEngine.swift        # Additive synthesis + ADSR + mixing
│       ├── MIDIEngine.swift         # CoreMIDI virtual port
│       ├── LidSensor.swift          # IOKit HID hinge sensor driver
│       ├── SystemAudioCapture.swift # ScreenCaptureKit audio capture
│       ├── Models.swift             # Constants, scales, instruments, helpers
│       └── L10n.swift               # Localization (Ko / En / Ja)
└── README.md
```

## License

MIT
