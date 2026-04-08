import SwiftUI

struct VinylView: View {
    let angle: Double
    let freq: Double
    let note: String
    let isPlaying: Bool
    let instrument: InstrumentType
    var vinylSize: CGFloat = 380
    var labelSize: CGFloat = 120

    @State private var rotation: Double = 0
    @State private var prevAngle: Double = 0

    var body: some View {
        ZStack {
            // Base circle
            Circle()
                .fill(Color.white)
                .frame(width: vinylSize, height: vinylSize)
                .shadow(color: .black.opacity(0.35), radius: 24, y: 8)

            // Grooves (concentric lines)
            Canvas { context, size in
                let cx = size.width / 2
                let cy = size.height / 2
                let innerR = labelSize / 2 + 8
                let outerR = vinylSize / 2 - 4
                let count = Int(vinylSize / 8)

                for i in 0..<count {
                    let t = CGFloat(i) / CGFloat(count - 1)
                    let r = innerR + t * (outerR - innerR)
                    let rect = CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)
                    let path = Path(ellipseIn: rect)
                    let alpha = (i % 4 == 0) ? 0.07 : 0.03
                    context.stroke(path, with: .color(.black.opacity(alpha)), lineWidth: 0.5)
                }
            }
            .frame(width: vinylSize, height: vinylSize)

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
                        Text(String(format: "%.0f", freq))
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
                .stroke(Color.black.opacity(0.06), lineWidth: 1.5)
                .frame(width: vinylSize - 1, height: vinylSize - 1)
        }
        .rotationEffect(.degrees(rotation))
        .onChange(of: angle) { _, newAngle in
            let delta = newAngle - prevAngle
            rotation += delta * 3.0
            rotation = rotation.truncatingRemainder(dividingBy: 360)
            prevAngle = newAngle
        }
        .animation(.easeOut(duration: 0.15), value: rotation)
    }
}
