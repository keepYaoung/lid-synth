import SwiftUI

struct VinylView: View {
    let angle: Double
    let freq: Double
    let note: String
    let isPlaying: Bool
    let instrument: InstrumentType
    var vinylSize: CGFloat = 380
    var labelSize: CGFloat = 120
    var mode: SynthMode = .glide
    var velocity: Double = 0
    var scaleType: ScaleType = .pentatonic

    @State private var rotation: Double = 0
    @State private var prevAngle: Double = 0
    @State private var sparks: [(angle: Double, life: Double)] = []

    var body: some View {
        ZStack {
            // Vinyl shadow (afterimage for vinyl mode)
            if mode == .vinyl && abs(velocity) > kVinylVelocityThreshold {
                Circle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: vinylSize, height: vinylSize)
                    .rotationEffect(.degrees(rotation - (velocity > 0 ? 8 : -8)))
                    .blur(radius: 4)
            }

            // Base circle
            Circle()
                .fill(Color.white)
                .frame(width: vinylSize, height: vinylSize)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)

            // Grooves (concentric lines) + vinyl shimmer
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let innerR = labelSize / 2 + 8
                let outerR = vinylSize / 2 - 4
                let count = Int(vinylSize / 8)
                let speed = abs(velocity)
                let shimmer = mode == .vinyl ? min(speed / 200.0, 1.0) : 0

                for i in 0..<count {
                    let t = CGFloat(i) / CGFloat(count - 1)
                    let r = innerR + t * (outerR - innerR)
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    let path = Path(ellipseIn: rect)
                    let baseAlpha = (i % 4 == 0) ? 0.07 : 0.03
                    let alpha = baseAlpha + shimmer * 0.08
                    let color: Color = shimmer > 0.1
                        ? .white.opacity(alpha)
                        : .black.opacity(baseAlpha)
                    context.stroke(path, with: .color(color), lineWidth: 0.5)
                }

                // Vinyl sparks at outer edge
                if mode == .vinyl && speed > kVinylVelocityThreshold * 2 {
                    let intensity = min(speed / 200.0, 1.0)
                    let sparkCount = Int(intensity * 8)
                    for _ in 0..<sparkCount {
                        let sparkAngle = Double.random(in: 0...360) * .pi / 180
                        let r = outerR - CGFloat.random(in: 0...6)
                        let x = cx + r * cos(sparkAngle)
                        let y = cy + r * sin(sparkAngle)
                        let sz: CGFloat = CGFloat.random(in: 2...4)
                        let rect = CGRect(x: x - sz/2, y: y - sz/2, width: sz, height: sz)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.orange.opacity(intensity * 0.7))
                        )
                    }
                }
            }
            .frame(width: vinylSize, height: vinylSize)

            // Pitch Fader: scale graduation marks
            if mode == .pitchFader {
                Canvas { context, size in
                    let cx = size.width / 2
                    let cy = size.height / 2
                    let innerR = labelSize / 2 + 12
                    let outerR = vinylSize / 2 - 8
                    let tickR = outerR - 4

                    let intervals = scaleType.intervals
                    let total = intervals.count * 3  // 3 octaves
                    let bandAngle = 360.0 / Double(total)

                    for i in 0..<total {
                        let midi = kBaseMidi + (i / intervals.count) * 12 + intervals[i % intervals.count]
                        let noteAngle = Double(i) * bandAngle - 90  // start from top
                        let rad = noteAngle * .pi / 180

                        // Tick mark at boundary
                        let boundaryRad = (noteAngle - bandAngle / 2) * .pi / 180
                        let x1 = cx + tickR * cos(boundaryRad)
                        let y1 = cy + tickR * sin(boundaryRad)
                        let x2 = cx + outerR * cos(boundaryRad)
                        let y2 = cy + outerR * sin(boundaryRad)
                        context.stroke(
                            Path { p in p.move(to: CGPoint(x: x1, y: y1)); p.addLine(to: CGPoint(x: x2, y: y2)) },
                            with: .color(.white.opacity(0.15)),
                            lineWidth: 0.5
                        )

                        // Note name at center of band
                        let labelR = (innerR + tickR) / 2
                        let lx = cx + labelR * cos(rad)
                        let ly = cy + labelR * sin(rad)
                        let noteName = midiToNoteName(midi)
                        let isActive = (freq > 20 && noteName == note)
                        context.draw(
                            Text(noteName)
                                .font(.system(size: max(7, vinylSize * 0.015), weight: isActive ? .bold : .regular, design: .monospaced))
                                .foregroundColor(isActive ? .white : .white.opacity(0.35)),
                            at: CGPoint(x: lx, y: ly)
                        )
                    }
                }
                .frame(width: vinylSize, height: vinylSize)
            }

            // Red Center Label
            ZStack {
                Circle()
                    .fill(Color(red: 0.88, green: 0.18, blue: 0.15))
                    .frame(width: labelSize, height: labelSize)

                VStack(spacing: 3) {
                    Text(note)
                        .font(.system(size: max(11, labelSize * 0.1), weight: .medium, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85))

                    HStack(spacing: 10) {
                        Text(instrument.rawValue)
                            .font(.system(size: max(8, labelSize * 0.065), weight: .regular, design: .monospaced))
                        Circle()
                            .fill(.white)
                            .frame(width: 3, height: 3)
                        Text(mode == .vinyl
                            ? String(format: "%.0f°/s", velocity)
                            : String(format: "%.0f", freq))
                            .font(.system(size: max(8, labelSize * 0.065), weight: .regular, design: .monospaced))
                    }
                    .foregroundColor(.white.opacity(0.6))

                    Image(systemName: "asterisk")
                        .font(.system(size: max(9, labelSize * 0.075), weight: .light))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 1)
                }

                // Spindle hole
                Circle()
                    .fill(Color(white: 0.04))
                    .frame(width: 6, height: 6)
                    .offset(y: -1)
            }

            // Outer edge ring
            Circle()
                .stroke(
                    mode == .vinyl && abs(velocity) > kVinylVelocityThreshold
                        ? Color.orange.opacity(0.3)
                        : Color.black.opacity(0.06),
                    lineWidth: 1.5
                )
                .frame(width: vinylSize - 1, height: vinylSize - 1)
        }
        .rotationEffect(.degrees(rotation))
        .onChange(of: angle) { _, newAngle in
            let delta = newAngle - prevAngle
            switch mode {
            case .pitchFader:
                // Snap to note position
                let intervals = scaleType.intervals
                let total = intervals.count * 3
                let r = min(max((newAngle - kAngleMin) / (kAngleMax - kAngleMin), 0), 1)
                let step = Int((r * Double(total - 1)).rounded())
                let targetRot = Double(step) / Double(total) * 360.0
                rotation = targetRot
            case .vinyl:
                // 1:1 tracking, no amplification
                rotation += delta * 1.0
                rotation = rotation.truncatingRemainder(dividingBy: 360)
            default:
                // Glide, Scale, Rhythm: 3x amplification
                rotation += delta * 3.0
                rotation = rotation.truncatingRemainder(dividingBy: 360)
            }
            prevAngle = newAngle
        }
        .animation(
            mode == .pitchFader
                ? .easeOut(duration: 0.25)
                : mode == .vinyl
                    ? .easeOut(duration: 0.08)
                    : .easeOut(duration: 0.15),
            value: rotation
        )
    }
}

/// Convert MIDI note number to note name (without octave for compact display)
private func midiToNoteName(_ midi: Int) -> String {
    let notes = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]
    let octave = midi / 12 - 1
    return "\(notes[((midi % 12) + 12) % 12])\(octave)"
}
