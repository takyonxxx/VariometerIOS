import SwiftUI

struct VarioBigReadout: View {
    let vario: Double   // m/s filtered
    let avg: Double     // m/s 30s average

    var tint: Color {
        if vario >= 0.3 { return .green }
        if vario <= -1.5 { return .red }
        return .white
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%+.1f", vario))
                    .font(.system(size: 120, weight: .black, design: .rounded))
                    .foregroundColor(tint)
                    .monospacedDigit()
                    .shadow(color: .black.opacity(0.85), radius: 6)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.15), value: vario)
                Text("m/s")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .offset(y: -22)
            }

            HStack(spacing: 14) {
                Label(String(format: "%+.1f m/s 30s", avg),
                      systemImage: "waveform.path.ecg")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
            }

            // Vertical bar indicator
            VarioBar(vario: vario)
                .frame(height: 10)
                .padding(.horizontal, 30)
                .padding(.top, 6)
        }
    }
}

struct VarioBar: View {
    let vario: Double
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let center = w / 2
            let norm = max(-1, min(1, vario / 5.0))   // ±5 m/s full scale
            let barW = abs(CGFloat(norm)) * (w/2)

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.15))
                if norm >= 0 {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.green.opacity(0.8), .green],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: barW)
                        .offset(x: center)
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.red, .red.opacity(0.8)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: barW)
                        .offset(x: center - barW)
                }
                // Center tick
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .offset(x: center - 1)
            }
        }
    }
}
