import SwiftUI

struct BottomTelemetry: View {
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                TelemetryTile(title: "İRTİFA",
                              value: String(format: "%.0f", locationMgr.fusedAltitude),
                              unit: "m")
                TelemetryTile(title: "YER HIZI",
                              value: String(format: "%.0f", locationMgr.groundSpeedKmh),
                              unit: "km/h")
                TelemetryTile(title: "ROTA",
                              value: String(format: "%.0f°", locationMgr.courseDeg),
                              unit: "")
            }

            if let c = locationMgr.coordinate {
                HStack(spacing: 6) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                    Text(CoordConverter.format(c, as: settings.coordFormat))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
            }
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
                .foregroundColor(.white.opacity(0.6))
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.55)))
    }
}
