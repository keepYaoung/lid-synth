import SwiftUI
import QuartzCore

struct ContentView: View {
    @State private var mode: SynthMode = .glide
    @State private var scaleType: ScaleType = .pentatonic
    @State private var instrument: InstrumentType = .theremin
    @State private var volume: Double = 0.22
    @State private var bpm: Double = 120
    @State private var beatFlash = false

    // Display
    @State private var currentAngle: Double = 0
    @State private var currentFreq: Double = 0
    @State private var currentNote: String = "---"
    @State private var waveform: [Float] = []

    // Demo slider
    @State private var demoAngle: Double = 90

    // Output toggles
    @State private var synthEnabled = false
    @State private var midiEnabled = false
    @State private var midiCC: UInt8 = 1

    @State private var prevMidi: Int? = nil
    @State private var showVinylTip = true

    // Vinyl mode
    @State private var prevVinylAngle: Double = 90
    @State private var currentVelocity: Double = 0
    @State private var sysAudioActive: Bool = false
    @State private var commandHeld = false
    @State private var modeBeforeCommand: SynthMode? = nil
    @State private var eventMonitor: Any? = nil

    private let audioEngine = AudioEngine()
    private let midiEngine = MIDIEngine()
    private let sensor = LidSensor()
    private let systemAudio = SystemAudioCapture()
    private let timer = Timer.publish(every: 0.04, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            let discSize = geo.size.height * 0.96
            let panelWidth = discSize * 0.52

            HStack(spacing: 0) {
                vinylPanel(discSize: discSize, panelWidth: panelWidth, height: geo.size.height)
                controlPanel
            }
        }
        .frame(minWidth: 800, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity)
        .background(Color(white: 0.04))
        .onAppear {
            audioEngine.systemAudio = systemAudio
            audioEngine.start()
            Task { await systemAudio.start() }

            // Command key hold → overlay vinyl scratch on top of current mode
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                let cmdDown = event.modifierFlags.contains(.command)
                if cmdDown && !commandHeld {
                    commandHeld = true
                    modeBeforeCommand = mode
                    prevVinylAngle = currentAngle  // sync so first delta isn't huge
                    // Enable scratch overlay (system audio mix) without changing mode
                    audioEngine.setMixSystemAudio(true)
                    audioEngine.setScratchRate(0)
                    fputs("[CMD] Vinyl overlay ON (mode=\(mode.rawValue))\n", stderr)
                } else if !cmdDown && commandHeld {
                    commandHeld = false
                    // Disable scratch overlay, restore previous state
                    if let prev = modeBeforeCommand {
                        audioEngine.setMixSystemAudio(prev == .vinyl)
                        modeBeforeCommand = nil
                    }
                }
                return event
            }
        }
        .onDisappear {
            audioEngine.stop()
            systemAudio.stop()
            midiEngine.allNotesOff()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        .onReceive(timer) { _ in tick() }
        .onChange(of: mode) { _, val in
            audioEngine.setMode(val)
            midiEngine.allNotesOff()
            prevMidi = nil
            prevVinylAngle = currentAngle
            // Only vinyl mode uses system audio mixing
            audioEngine.setMixSystemAudio(val == .vinyl)
        }
        .onChange(of: instrument) { _, val in
            audioEngine.setHarmonics(val.harmonics)
            audioEngine.setPercType(val)
        }
        .onChange(of: bpm) { _, val in audioEngine.setBpm(val) }
        .onChange(of: volume) { _, val in audioEngine.setVolume(val) }
        .onChange(of: synthEnabled) { _, val in
            if val {
                // Immediately set freq from current angle so sound starts instantly
                let freq = angleToFreqGlide(currentAngle)
                audioEngine.setTargetFreq(freq)
            }
            audioEngine.setMuted(!val)
        }
        .onChange(of: midiEnabled) { _, val in
            midiEngine.setEnabled(val)
        }
    }

    // MARK: - Vinyl Panel

    private func vinylPanel(discSize: CGFloat, panelWidth: CGFloat, height: CGFloat) -> some View {
        ZStack {
            VinylView(
                angle: currentAngle,
                freq: currentFreq,
                note: currentNote,
                isPlaying: currentFreq > 20,
                instrument: instrument,
                vinylSize: discSize,
                labelSize: discSize * 0.32,
                mode: mode,
                velocity: currentVelocity,
                scaleType: scaleType
            )
            .position(x: 0, y: height / 2)
        }
        .frame(width: panelWidth)
        .clipped()
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 0) {
                headerSection
                songInfoSection
                waveformSection
                angleSliderSection
                divider
                modeSection
                scaleSection
                bpmSection
                velocitySection
                instrumentSection
                volumeSection
                outputSection
                midiSection
                Spacer(minLength: 16)
            }
            .padding(.horizontal, 36)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Control Sections

    private var headerSection: some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: "asterisk")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white)
            Text(L10n.appName)
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundColor(.white)
            Spacer()
        }
        .padding(.top, 28)
        .padding(.bottom, 20)
    }

    private var songInfoSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentNote)
                    .font(.system(size: 36, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("\(instrument.rawValue) · \(mode.rawValue)")
                    .font(.system(size: 14))
                    .foregroundColor(.gray)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(String(format: "%.1f Hz", currentFreq))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.secondary)
                Text(String(format: "%.1f°", currentAngle))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.gray)
            }
            if mode == .rhythm {
                Circle()
                    .fill(beatFlash ? Color.red : Color.white.opacity(0.1))
                    .frame(width: 12, height: 12)
                    .padding(.leading, 8)
            }
        }
        .padding(.bottom, 12)
    }

    private var waveformSection: some View {
        WaveformView(samples: waveform, freq: currentFreq, isActive: currentFreq > 20)
            .frame(height: 64)
            .padding(.bottom, 12)
    }

    @ViewBuilder
    private var angleSliderSection: some View {
        if !sensor.sensorAvailable {
            VStack(spacing: 4) {
                Slider(value: $demoAngle, in: 0...180, step: 0.5)
                    .tint(.red.opacity(0.8))
                HStack {
                    Text(String(format: "%.0f°", demoAngle))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("180°")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            .padding(.bottom, 16)
    }

    private var modeSection: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                modeButton(L10n.modeVinyl, icon: "opticaldisc", mode: .vinyl)
                modeButton(L10n.modeGlide, icon: "waveform.path", mode: .glide)
                modeButton(L10n.modeScale, icon: "pianokeys", mode: .scale)
                modeButton(L10n.modeFader, icon: "slider.vertical.3", mode: .pitchFader)
                modeButton(L10n.modeRhythm, icon: "metronome", mode: .rhythm)
            }

            // Tip: show vinyl overlay hint when in non-vinyl modes
            if mode != .vinyl && showVinylTip {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.cyan.opacity(0.7))
                    Text(L10n.vinylOverlayTip)
                        .font(.system(size: 9))
                        .foregroundColor(.cyan.opacity(0.6))
                    Spacer()
                    Button {
                        showVinylTip = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8))
                            .foregroundColor(.gray)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4).fill(.cyan.opacity(0.06)))
            }
        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var scaleSection: some View {
        if mode == .scale || mode == .rhythm || mode == .pitchFader {
            HStack(spacing: 6) {
                ForEach(ScaleType.allCases) { s in
                    Button(s.rawValue) { scaleType = s }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: s == scaleType ? .bold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(s == scaleType ? Color.red.opacity(0.8) : Color.white.opacity(0.06))
                        )
                        .foregroundColor(s == scaleType ? .white : .gray)
                }
                Spacer()
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var bpmSection: some View {
        if mode == .rhythm {
            HStack {
                Image(systemName: "metronome")
                    .font(.system(size: 11))
                    .foregroundColor(.gray)
                Slider(value: $bpm, in: 40...240, step: 1)
                    .tint(.red.opacity(0.8))
                Text("\(Int(bpm))")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                    .frame(width: 32)
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var velocitySection: some View {
        if mode == .vinyl {
            VStack(spacing: 6) {
                HStack {
                    Image(systemName: "gauge.with.needle")
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Text(String(format: "%.0f°/s", currentVelocity))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(abs(currentVelocity) > kVinylVelocityThreshold ? .orange : .gray)
                        .frame(width: 80)
                    Spacer()
                    Text(currentVelocity > 0 ? "▶" : currentVelocity < 0 ? "◀" : "■")
                        .font(.system(size: 14))
                        .foregroundColor(abs(currentVelocity) > kVinylVelocityThreshold ? .orange : .gray.opacity(0.4))
                    Text(L10n.cmdHold)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray.opacity(0.4))
                }

                // System audio status (updated every tick)
                if !sysAudioActive {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.yellow)
                        Text(L10n.sysAudioWarning)
                            .font(.system(size: 9))
                            .foregroundColor(.yellow.opacity(0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.yellow.opacity(0.08)))
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(.green).frame(width: 6, height: 6)
                        Text(L10n.sysAudioActive)
                            .font(.system(size: 9))
                            .foregroundColor(.green.opacity(0.7))
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private var instrumentSection: some View {
        HStack(spacing: 6) {
            ForEach(InstrumentType.allCases) { inst in
                Button(inst.rawValue) { instrument = inst }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: inst == instrument ? .bold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule().fill(inst == instrument ? Color.white.opacity(0.15) : Color.white.opacity(0.04))
                    )
                    .foregroundColor(inst == instrument ? .white : .gray)
            }
            Spacer()
        }
        .padding(.bottom, 12)
    }

    private var volumeSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.system(size: 10))
                .foregroundColor(.gray)
            Slider(value: $volume, in: 0...0.6)
                .tint(.white.opacity(0.4))
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 10))
                .foregroundColor(.gray)
        }
        .padding(.bottom, 16)
    }

    private var outputSection: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)

            HStack(spacing: 20) {
                outputToggle(icon: "speaker.wave.2.fill", label: "Synth", isOn: $synthEnabled, color: .mint)
                outputToggle(icon: "cable.connector", label: "MIDI", isOn: $midiEnabled, color: .green)
                Spacer()

                if midiEnabled {
                    Picker("", selection: $midiCC) {
                        Text("Mod").tag(UInt8(1))
                        Text("Vol").tag(UInt8(7))
                        Text("Expr").tag(UInt8(11))
                        Text("Filt").tag(UInt8(74))
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                }
            }
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private var midiSection: some View {
        if midiEnabled {
            HStack(spacing: 14) {
                midiBadge("Note", value: currentNote)
                midiBadge("CC\(midiCC)", value: "\(Int(currentAngle / 180 * 127))")
                midiBadge("Ch", value: "1")
                Spacer()
            }
            .padding(.bottom, 12)
        }
    }

    // MARK: - Components

    private func modeButton(_ label: String, icon: String, mode: SynthMode) -> some View {
        Button {
            self.mode = mode
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                Text(label)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(self.mode == mode ? .white : .gray.opacity(0.5))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(self.mode == mode ? Color.white.opacity(0.1) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func outputToggle(icon: String, label: String, isOn: Binding<Bool>, color: Color) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundColor(isOn.wrappedValue ? color : .gray.opacity(0.4))
        }
        .toggleStyle(.switch)
        .tint(color)
    }

    private func midiBadge(_ label: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4).fill(.green.opacity(0.06)))
    }

    // MARK: - Tick

    private func tick() {
        let angle: Double
        if sensor.sensorAvailable {
            sensor.poll()
            angle = sensor.angle
        } else {
            angle = demoAngle
        }
        currentAngle = angle

        audioEngine.setFilterAngle(angle)

        switch mode {
        case .glide:
            let freq = angleToFreqGlide(angle)
            audioEngine.setTargetFreq(freq)
            currentFreq = freq
            midiEngine.sendAngleAsCC(angle, controller: midiCC)

        case .scale, .rhythm:
            if let midi = angleToMidi(angle, scale: scaleType) {
                let freq = midiToFreq(midi)
                audioEngine.setTargetFreq(freq)
                currentFreq = freq
                if midi != prevMidi {
                    if mode == .scale { audioEngine.triggerNote() }
                    midiEngine.sendNoteOn(UInt8(clamping: midi))
                }
                prevMidi = midi
            } else {
                audioEngine.setTargetFreq(0)
                audioEngine.releaseNote()
                midiEngine.sendNoteOff()
                currentFreq = 0
                prevMidi = nil
            }
            midiEngine.sendAngleAsCC(angle, controller: midiCC)

        case .pitchFader:
            if let midi = angleToMidiFader(angle, scale: scaleType, prevMidi: prevMidi) {
                let freq = midiToFreq(midi)
                audioEngine.setTargetFreq(freq)
                currentFreq = freq
                if midi != prevMidi {
                    audioEngine.triggerNote()
                    midiEngine.sendNoteOn(UInt8(clamping: midi))
                }
                prevMidi = midi
            } else {
                audioEngine.setTargetFreq(0)
                audioEngine.releaseNote()
                midiEngine.sendNoteOff()
                currentFreq = 0
                prevMidi = nil
            }
            midiEngine.sendAngleAsCC(angle, controller: midiCC)

        case .vinyl:
            // Delta-based scratch with dead zone for tremor prevention
            let delta = angle - prevVinylAngle
            prevVinylAngle = angle
            currentVelocity = delta / 0.04  // approximate deg/s for display

            // Dead zone: ignore changes < 0.8° per tick (tremor filter)
            if abs(delta) > 0.8 {
                // Map delta to scratch rate: 1° → 1.5x speed shift
                let rate = delta * 1.5
                audioEngine.setScratchRate(rate)
            } else {
                audioEngine.setScratchRate(0)
            }

            // Send as MIDI CC
            let ccVal = UInt8(min(127, abs(delta) / 5.0 * 127.0))
            midiEngine.sendCC(controller: midiCC, value: ccVal)
        }

        // Command held overlay: scratch on top of current mode
        if commandHeld && mode != .vinyl {
            let delta = angle - prevVinylAngle
            prevVinylAngle = angle
            if abs(delta) > 0.5 {
                audioEngine.setScratchRate(delta * 2.0)
            } else {
                audioEngine.setScratchRate(0)
            }
        }

        currentNote = freqToNote(currentFreq)
        waveform = audioEngine.copyWaveform()
        sysAudioActive = systemAudio.isCapturing

        if audioEngine.consumeBeatFlash() {
            beatFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { beatFlash = false }
        }
    }
}
