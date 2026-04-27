# App Store Review Reply — 2026-04-27 (Screen Recording / Guideline 2.1)

**Submission ID:** 14923dde-e56e-4e5b-9762-f3711d07dcbd
**Version:** 1.0.0 (2)
**Reviewer date:** April 25, 2026
**Review device:** MacBook Air (15-inch, M3, 2024)

Reply length: 3967 chars (within App Store Connect 4000-char limit).

---

## Reviewer's Questions (Guideline 2.1 — Information Needed)

1. Describe all app features which use screen recording.
2. What data does the app collect via screen recording?
3. For what purposes are you collecting this information?
4. Will the data be shared with any third parties?
5. Where will this information be stored?
6. Which sections of the privacy policy explain collection, use, disclosure, sharing, and retention of screen recording data?
7. Quote the specific privacy-policy language that concerns screen recording data.

---

## Reply (paste verbatim into App Store Connect)

```
Hello,

Detailed answers below.

Submission ID: 14923dde-e56e-4e5b-9762-f3711d07dcbd
Version: 1.0.0 (2)

1. Features that use screen recording

hynthesizer is a synthesizer controlled by the MacBook lid angle. Two opt-in features rely on macOS Screen Recording, and both are audio-only:

• System Audio Filter (Filter mode) — when the user selects "System" as the audio source, a low-pass filter modulated by the lid angle is applied in real time to whatever audio is already playing on the user's Mac.
• Vinyl Scratch on System Audio (Vinyl mode, source = System) — the same captured audio is fed into a virtual turntable so the user can "scratch" it with the lid.

The default audio source on launch is OFF. Screen Recording permission is requested only after the user explicitly switches the source to "System" in the UI; otherwise SCStream is never created.

2. Data collected via screen recording

Audio samples only — mono, 44.1 kHz, Float32 PCM.

The app does NOT capture screen pixels, screenshots, video frames, window contents, window titles, application names, process information, keystrokes, mouse position, or clipboard.

Although macOS classifies the underlying permission as "Screen Recording," our use of ScreenCaptureKit is restricted to audio in code:
• SCStreamConfiguration.capturesAudio = true; the 2×2 video size and 1 fps minimumFrameInterval are unused placeholders required by the API.
• stream.addStreamOutput(self, type: .audio, ...) — only .audio is subscribed; the delegate explicitly drops anything else (guard type == .audio else { return }).
• excludesCurrentProcessAudio = true — our own output is filtered out of the capture.

3. Purpose

Real-time DSP for the user's own live performance: apply a hinge-controlled low-pass filter to system audio (Filter mode) and let the user scratch that audio in Vinyl mode. No analytics, telemetry, machine learning, diagnostics, or advertising use.

4. Third-party sharing

No. The app contains no analytics, advertising, or crash-reporting SDKs and no networking code at all. It is a fully offline application that establishes no outbound network connections at runtime.

5. Storage

Captured audio exists only in two transient in-memory C buffers on the user's device:
• A 32 KB SPSC ring buffer read by the audio render thread.
• A scratch buffer used by Vinyl mode for variable-rate playback.

Both are continuously overwritten as new samples arrive (typical residency well under one second). Nothing is written to disk, no cache files are created, and no log files containing audio data are produced. When the user disables "System," SCStream.stopCapture() is called and the buffers are deallocated.

6. Relevant privacy-policy sections

Privacy policy: https://www.notion.so/seyyeah311/hynthesizer-Privacy-Policy-33a433f1d6658076a5bdee44e779895b

Sections covering collection, use, disclosure, sharing, and retention of screen-recording-derived data:
• Section 3 — System Audio Access (collection and purpose)
• Section 4 — Network Communication (no transmission)
• Section 5 — Third-Party Sharing (no disclosure)
• Section 6 — Data Storage (no retention; real-time memory only)

7. Exact privacy-policy language

Quoted verbatim from the published policy:

"3. System Audio Access
When the System source is selected, the app captures system audio via macOS Screen Recording permission. Captured audio is used solely for real-time effects processing and is never recorded or transmitted."

"4. Network Communication
hynthesizer does not connect to the internet. It contains no servers, analytics, or advertising SDKs."

"5. Third-Party Sharing
No data is shared with any third party."

"6. Data Storage
The app does not store any personal data on your device. All audio processing occurs in real-time memory and is discarded immediately when the app is closed."

Please let us know if anything further is needed. Thank you.

The hynthesizer team
```

---

## Code references backing the reply

- `hynthesizer/Sources/SystemAudioCapture.swift`
  - L2 — `import ScreenCaptureKit`
  - L54, L57 — `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
  - L83–90 — `SCStreamConfiguration` (`capturesAudio = true`, `excludesCurrentProcessAudio = true`, mono 44.1 kHz, placeholder 2×2 video / 1 fps)
  - L93 — `addStreamOutput(self, type: .audio, ...)`
  - L147–148 — delegate drops anything not `.audio`
- `hynthesizer/Sources/AudioSourceManager.swift` — source switching (`.system` / `.mic` / `.file`); permission only triggered when `.system` is chosen.
- `hynthesizer/Sources/ContentView.swift` — Filter and Vinyl mode UI hooks for source = System.

## Privacy-policy URL

https://www.notion.so/seyyeah311/hynthesizer-Privacy-Policy-33a433f1d6658076a5bdee44e779895b

(Confirmed public; reviewer can open without login.)

## Follow-up suggestions for next build (not required for this reply)

- Consider adding to the privacy policy: a top-level Permissions Summary, an explicit "audio only — no screen pixels/windows/screenshots" sentence in Section 3, and a short Section about File-source local file access. The current Section 3 wording is already sufficient for this review; these are pure improvements for future-proofing.
