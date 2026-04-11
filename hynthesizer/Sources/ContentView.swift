import SwiftUI
import QuartzCore

struct ContentView: View {
    @State private var mode: SynthMode = .vinyl
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

    // Filter mode
    @State private var filterType: FilterType = .lowPass
    @State private var compressorEnabled = false
    @State private var filterCutoffDisplay: Double = 1000

    // Audio source
    @State private var audioSource: AudioSource = .system
    @State private var loadedFileName: String? = nil
    @State private var isPlaying = false

    // Vinyl mode (CDJ state machine)
    @State private var prevVinylAngle: Double = 90
    @State private var currentVelocity: Double = 0
    @State private var sourceActive: Bool = false
    @State private var vinylState: ScratchState = .scratching
    @State private var stillTickCount: Int = 0
    private let kScratchReleaseTicks = 3  // 120ms debounce
    @State private var eventMonitor: Any? = nil

    private let audioEngine = AudioEngine()
    private let midiEngine = MIDIEngine()
    private let sensor = LidSensor()
    private let audioSourceManager = AudioSourceManager()
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
            audioEngine.audioSource = audioSourceManager
            audioEngine.setHarmonics(instrument.harmonics)
            audioEngine.setPercType(instrument)
            audioEngine.start()
            Task { await audioSourceManager.start() }

            // (Command key overlay removed)
        }
        .onDisappear {
            audioEngine.stop()
            audioSourceManager.stop()
            midiEngine.allNotesOff()
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        .onReceive(timer) { _ in tick() }
        .onChange(of: mode) { _, val in
            // Set freq BEFORE setMode so smoothFreq syncs correctly
            if val == .glide {
                let freq = angleToFreqGlide(currentAngle)
                audioEngine.setTargetFreq(freq)
            }
            audioEngine.setMode(val)
            midiEngine.allNotesOff()
            prevMidi = nil
            prevVinylAngle = currentAngle
            isPlaying = false
            vinylState = .scratching
            stillTickCount = 0
            // Vinyl and Filter modes use system audio
            audioEngine.setMixSystemAudio(val == .vinyl || val == .filter)
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
                let freq: Double
                if mode == .glide {
                    freq = angleToFreqGlide(currentAngle)
                } else if let midi = angleToMidiFader(currentAngle, scale: scaleType, prevMidi: prevMidi) {
                    freq = midiToFreq(midi)
                } else {
                    freq = 0
                }
                audioEngine.setTargetFreq(freq)
                if mode != .glide && freq > 20 {
                    audioEngine.triggerNote()
                }
            }
            audioEngine.setMuted(!val)
        }
        .onChange(of: midiEnabled) { _, val in
            midiEngine.setEnabled(val)
        }
        .onChange(of: filterType) { _, val in
            audioEngine.setFilterType(val)
        }
        .onChange(of: compressorEnabled) { _, val in
            audioEngine.setCompressorEnabled(val)
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
                audioSourceSection
                scaleSection
                bpmSection
                velocitySection
                filterSection
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
                Text(mode == .filter ? "\(filterType.rawValue) · \(mode.rawValue)" : "\(instrument.rawValue) · \(mode.rawValue)")
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
                modeButton(L10n.modeFilter, icon: "line.3.horizontal.decrease", mode: .filter)
                modeButton(L10n.modeGlide, icon: "waveform.path", mode: .glide)
                modeButton(L10n.modeScale, icon: "pianokeys", mode: .scale)
                modeButton(L10n.modeFader, icon: "slider.vertical.3", mode: .pitchFader)
                modeButton(L10n.modeRhythm, icon: "metronome", mode: .rhythm)
            }

        }
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var audioSourceSection: some View {
        if mode == .vinyl || mode == .filter {
            VStack(spacing: 8) {
                // Source selector
                HStack(spacing: 6) {
                    ForEach(AudioSource.allCases) { src in
                        Button {
                            selectAudioSource(src)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: audioSourceIcon(src))
                                    .font(.system(size: 10))
                                Text(audioSourceLabel(src))
                                    .font(.system(size: 11, weight: src == audioSource ? .bold : .regular))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(src == audioSource ? Color.orange.opacity(0.7) : Color.white.opacity(0.06))
                            )
                            .foregroundColor(src == audioSource ? .white : .gray)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                // Source-specific status
                switch audioSource {
                case .system:
                    if sourceActive {
                        HStack(spacing: 6) {
                            Circle().fill(.green).frame(width: 6, height: 6)
                            Text(L10n.sysAudioActive)
                                .font(.system(size: 9))
                                .foregroundColor(.green.opacity(0.7))
                            Spacer()
                        }
                    } else {
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
                    }
                case .file:
                    VStack(spacing: 6) {
                        HStack(spacing: 8) {
                            Button {
                                openFilePicker()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 10))
                                    Text(L10n.loadFile)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.white.opacity(0.08)))
                                .foregroundColor(.white)
                            }
                            .buttonStyle(.plain)

                            if let name = loadedFileName {
                                HStack(spacing: 4) {
                                    Image(systemName: sourceActive ? "waveform" : "waveform.slash")
                                        .font(.system(size: 9))
                                        .foregroundColor(sourceActive ? .orange : .gray)
                                    Text(name)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(.orange.opacity(0.8))
                                        .lineLimit(1)
                                }
                            } else {
                                Text(L10n.noFileLoaded)
                                    .font(.system(size: 10))
                                    .foregroundColor(.gray.opacity(0.5))
                            }
                            Spacer()
                        }

                        // Play/Pause button (turntable control)
                        if loadedFileName != nil && sourceActive {
                            HStack(spacing: 10) {
                                Button {
                                    isPlaying.toggle()
                                    if isPlaying {
                                        vinylState = .playing
                                        audioEngine.setScratchState(.playing)
                                    } else {
                                        vinylState = .scratching
                                        audioEngine.setScratchState(.scratching)
                                        audioEngine.setScratchAdvance(0)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 12))
                                        Text(isPlaying ? L10n.pause : L10n.play)
                                            .font(.system(size: 11, weight: .bold))
                                    }
                                    .foregroundColor(isPlaying ? .orange : .white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(isPlaying ? Color.orange.opacity(0.15) : Color.white.opacity(0.1))
                                    )
                                }
                                .buttonStyle(.plain)

                                if isPlaying && mode == .vinyl {
                                    Text(L10n.turntableHint)
                                        .font(.system(size: 9))
                                        .foregroundColor(.orange.opacity(0.5))
                                }
                                Spacer()
                            }
                        }
                    }
                case .mic:
                    HStack(spacing: 6) {
                        Circle()
                            .fill(sourceActive ? .red : .gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                        Text(sourceActive ? L10n.micRecording : L10n.micInactive)
                            .font(.system(size: 9))
                            .foregroundColor(sourceActive ? .red.opacity(0.8) : .gray.opacity(0.5))
                        Spacer()
                    }
                }
            }
            .padding(.bottom, 8)
        }
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
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var filterSection: some View {
        if mode == .filter {
            VStack(spacing: 8) {
                // Filter type selector
                HStack(spacing: 6) {
                    ForEach(FilterType.allCases) { ft in
                        Button(ft.rawValue) { filterType = ft }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: ft == filterType ? .bold : .regular))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(ft == filterType ? Color.purple.opacity(0.7) : Color.white.opacity(0.06))
                            )
                            .foregroundColor(ft == filterType ? .white : .gray)
                    }
                    Spacer()
                }

                // Cutoff display
                HStack {
                    Image(systemName: "waveform")
                        .font(.system(size: 11))
                        .foregroundColor(.purple.opacity(0.7))
                    Text(L10n.filterCutoff)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                    Spacer()
                    Text(String(format: "%.0f Hz", filterCutoffDisplay))
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .foregroundColor(.purple)
                }

                // Compressor toggle
                HStack {
                    Toggle(isOn: $compressorEnabled) {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .font(.system(size: 10))
                            Text(L10n.compressor)
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(compressorEnabled ? .purple : .gray.opacity(0.4))
                    }
                    .toggleStyle(.switch)
                    .tint(.purple)
                    Spacer()
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

    // MARK: - Audio Source Helpers

    private func audioSourceIcon(_ source: AudioSource) -> String {
        switch source {
        case .system: "display"
        case .file:   "doc.fill"
        case .mic:    "mic.fill"
        }
    }

    private func audioSourceLabel(_ source: AudioSource) -> String {
        switch source {
        case .system: L10n.sourceSystem
        case .file:   L10n.sourceFile
        case .mic:    L10n.sourceMic
        }
    }

    private func selectAudioSource(_ source: AudioSource) {
        audioSource = source
        isPlaying = false
        vinylState = .scratching
        stillTickCount = 0
        audioEngine.setScratchState(.scratching)
        audioEngine.setScratchAdvance(0)
        audioEngine.resetPlayPosition()
        Task { await audioSourceManager.switchSource(source) }
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .audio, .mp3, .wav, .aiff,
            .init(filenameExtension: "m4a")!,
            .init(filenameExtension: "flac")!
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = L10n.filePickerMessage
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try audioSourceManager.loadFile(url: url)
                loadedFileName = url.lastPathComponent
                // Reset playback state for new file
                isPlaying = false
                vinylState = .scratching
                audioEngine.setScratchState(.scratching)
                audioEngine.setScratchAdvance(0)
                audioEngine.resetPlayPosition()
                if audioSource != .file {
                    audioSource = .file
                }
                Task { await audioSourceManager.switchSource(.file) }
            } catch {
                fputs("[File] Load failed: \(error)\n", stderr)
            }
        }
    }

    // MARK: - Tick

    private func tick() {
        let angle: Double
        if sensor.sensorAvailable {
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
            if let midi = angleToMidiFader(angle, scale: scaleType, prevMidi: prevMidi) {
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

        case .filter:
            // Filter mode: display cutoff frequency
            let r = max(0, min(angle, 180)) / 180.0
            let cutoff = 200.0 * pow(100.0, r)
            filterCutoffDisplay = min(cutoff, 20000)
            currentFreq = filterCutoffDisplay
            midiEngine.sendAngleAsCC(angle, controller: midiCC)

        case .vinyl:
            // CDJ jog wheel: two states — PLAYING or SCRATCHING
            let delta = angle - prevVinylAngle
            prevVinylAngle = angle
            currentVelocity = delta / 0.04  // deg/s for display
            currentFreq = 0  // vinyl doesn't use freq display

            if abs(delta) > kVinylDeadZone && isPlaying {
                // Hinge moving + playing → SCRATCHING: playhead follows hand
                stillTickCount = 0
                if vinylState != .scratching {
                    vinylState = .scratching
                    audioEngine.setScratchState(.scratching)
                }
                audioEngine.setScratchAdvance(-delta * kScratchMultiplier)
            } else if isPlaying {
                // Hinge still + playing
                stillTickCount += 1
                if vinylState == .scratching {
                    audioEngine.setScratchAdvance(0)
                    if stillTickCount >= kScratchReleaseTicks {
                        vinylState = .playing
                        audioEngine.setScratchState(.playing)
                    }
                }
            }

            // MIDI CC
            let ccVal = UInt8(min(127, abs(delta) / 5.0 * 127.0))
            midiEngine.sendCC(controller: midiCC, value: ccVal)
        }

        currentNote = freqToNote(currentFreq)
        waveform = audioEngine.copyWaveform()
        sourceActive = audioSourceManager.isCapturing

        if audioEngine.consumeBeatFlash() {
            beatFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { beatFlash = false }
        }
    }
}
