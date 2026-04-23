import SwiftUI

struct VarioBigReadout: View {
    let vario: Double   // m/s filtered
    var compact: Bool = false

    var tint: Color {
        if vario >= 0.3 { return Color(red: 0.35, green: 0.95, blue: 0.55) }  // fresh green
        if vario <= -1.5 { return Color(red: 1.0, green: 0.40, blue: 0.40) }   // soft red
        return .white
    }

    /// Show "+" only when meaningfully positive; omit when near zero so it
    /// doesn't clutter the display.
    var formatted: String {
        if abs(vario) < 0.05 {
            return "0.0"
        }
        return String(format: "%+.1f", vario)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 6 : 8) {
            Text(formatted)
                .font(.system(size: compact ? 76 : 120, weight: .black, design: .rounded))
                .foregroundColor(tint)
                .monospacedDigit()
                .shadow(color: .black.opacity(0.85), radius: 6)
            Text("m/s")
                .font(.system(size: compact ? 20 : 28, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .offset(y: compact ? -14 : -22)
        }
    }
}
