import SwiftUI

struct WindDial: View {
    let windFromDeg: Double
    let windSpeedKmh: Double
    let courseDeg: Double
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2

            ZStack {
                // Compass ring
                Circle()
                    .fill(Color.black.opacity(0.45))
                Circle()
                    .stroke(Color.white.opacity(0.35), lineWidth: 1.5)

                // Cardinal marks
                ForEach(0..<8) { i in
                    let a = Double(i) * 45.0
                    let isMajor = (i % 2 == 0)
                    Rectangle()
                        .fill(Color.white.opacity(isMajor ? 0.8 : 0.4))
                        .frame(width: isMajor ? 2 : 1,
                               height: isMajor ? 10 : 6)
                        .offset(y: -r + 8)
                        .rotationEffect(.degrees(a))
                }
                // N/S/E/W labels
                ForEach(["N","E","S","W"], id: \.self) { label in
                    let idx = ["N","E","S","W"].firstIndex(of: label)!
                    Text(label)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(label == "N" ? .red : .white.opacity(0.75))
                        .offset(y: -r + 22)
                        .rotationEffect(.degrees(Double(idx) * 90))
                }

                // Course / heading triangle (pilot direction, points up)
                Triangle()
                    .fill(Color.cyan.opacity(0.8))
                    .frame(width: 10, height: 14)
                    .offset(y: -r + 2)

                // Wind arrow — arrow points in the direction wind is blowing TO
                // (i.e., 180° opposite of FROM). Traditionally shown pointing away
                // from upwind side. We display an arrow indicating wind flow.
                WindArrow()
                    .fill(LinearGradient(colors: [.orange, .yellow],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: r * 0.30, height: r * 1.35)
                    .rotationEffect(.degrees(windFromDeg + 180))  // TO direction
                    .opacity(0.6 + 0.4 * confidence)

                // Center readouts
                VStack(spacing: 0) {
                    Text(String(format: "%.0f", windSpeedKmh))
                        .font(.system(size: r * 0.42, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text("km/h")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                    Text(cardinal(windFromDeg))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cardinal(_ d: Double) -> String {
        let dirs = ["K","KKD","KD","DKD","D","DGD","GD","GGD",
                    "G","GGB","GB","BGB","B","BKB","KB","KKB"]
        // Turkish cardinals (N=K, S=G, E=D, W=B)
        var norm = d.truncatingRemainder(dividingBy: 360); if norm < 0 { norm += 360 }
        let idx = Int((norm + 11.25) / 22.5) % 16
        return dirs[idx]
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

struct WindArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        // Shaft
        p.addRect(CGRect(x: rect.midX - w*0.15, y: rect.minY + h*0.20, width: w*0.30, height: h*0.55))
        // Head (arrow pointing down in local coords; rotation outside handles direction)
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.midX - w*0.45, y: rect.minY + h*0.55))
        p.addLine(to: CGPoint(x: rect.midX + w*0.45, y: rect.minY + h*0.55))
        p.closeSubpath()
        return p
    }
}
