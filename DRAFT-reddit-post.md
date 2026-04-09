# I turned my MacBook's lid into a musical instrument. Yes, the lid. The thing you close when your boss walks by.

It started when I stumbled on some random Python script that reads MacBook lid angle from the hinge sensor. Most people would go "huh, neat" and move on. I went "what if I made a synthesizer out of this?"

3 weeks and 2,000 lines of Swift later, here's **hynthesizer** — a macOS synthesizer you play with the MacBook lid hinge angle. No MIDI controller, no keyboard, no talent required. Just vibes and a hinge.

## What does it actually do?

The app reads the MacBook's built-in hinge sensor at 25Hz via IOKit. Tilt = sound. That's it. That's the instrument.

## 5 modes of questionable life choices:

- **Vinyl** — Scratch system audio by opening/closing the lid. You look absolutely unhinged doing this. Pun intended.
- **Glide** — Theremin mode. Wave your lid, make spooky sounds. Perfect for scaring coworkers.
- **Scale** — Actual musical notes (Pentatonic, Major, Minor, Blues). Closest you'll get to "real music" with this thing.
- **Pitch Fader** — Snap-to-note with hysteresis, for people who want precision from a laptop hinge.
- **Rhythm** — Auto-triggers beats at 40–240 BPM. Open the lid on beat and pretend you're a producer.

**Vinyl mode is where it gets dumb fun.** You're literally scratching Spotify by flapping your MacBook like a book. Hold Command to scratch on top of any other mode. It's stupid. I love it.

It also outputs MIDI — so you can control Ableton or Logic with your lid angle. Your expensive DAW, controlled by a hinge. I'm sorry.

## Tech stuff for the nerds:

- Swift/SwiftUI native macOS app, ~2,000 lines
- Real-time additive synthesis with harmonic profiles per instrument
- ScreenCaptureKit for system audio capture
- CoreMIDI virtual port for DAW integration
- Biquad filters, ADSR envelopes, ring buffers — all audio-thread safe
- Zero dependencies. `swift build` and go.

## What's next:

Working on a Filter Sweep mode — lowpass/bandpass/highpass filters on system audio controlled by lid angle. Close the lid = underwater club effect. Open it = EDM drop. Basically turning my MacBook into a DJ filter knob.

GitHub: [link]

If this inspires you to make something equally useless and fun, my work here is done.
