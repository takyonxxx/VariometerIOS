import SwiftUI

struct BottomTelemetry: View {
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var settings: AppSettings
    @ObservedObject private var language = LanguagePreference.shared

    var body: some View {
        let _ = language.code     // observe language changes → re-render
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                TelemetryTile(title: L10n.string("altitude"),
                              value: String(format: "%.0f", locationMgr.fusedAltitude),
                              unit: "m")
                TelemetryTile(title: L10n.string("ground_speed"),
                              value: String(format: "%.0f", locationMgr.groundSpeedKmh),
                              unit: "km/h")
                TelemetryTile(title: L10n.string("course"),
                              value: String(format: "%.0f°", locationMgr.bestHeadingDeg),
                              unit: "")
            }

            // Coordinate bar — always visible, shows "---" when no fix
            HStack(spacing: 10) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.75))
                if let c = locationMgr.coordinate {
                    Text(CoordConverter.format(c, as: settings.coordFormat))
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                } else {
                    Text(L10n.string("waiting_gps"))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.85))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.25), lineWidth: 1)
                    )
            )
        }
    }
}

struct TelemetryTile: View {
    let title: String
    let value: String
    let unit: String
    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(Color(red: 0.55, green: 0.75, blue: 0.95))
                .tracking(1)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.08, green: 0.12, blue: 0.22).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
                )
        )
    }
}
