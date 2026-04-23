import SwiftUI
import CoreLocation

/// Compact card showing the current best FAI triangle.
/// When the triangle is open and pilot/home coords are known, shows a
/// small bearing arrow and distance to the home (closing) point.
struct FAITriangleHUD: View {
    let triangle: FAITriangle
    let pilotCoord: CLLocationCoordinate2D?
    let homeCoord: CLLocationCoordinate2D?
    let pilotHeadingDeg: Double
    /// Called when the user taps the HUD — typically to zoom the map to fit
    /// the whole triangle and disable auto-follow.
    var onTap: (() -> Void)? = nil
    @ObservedObject private var language = LanguagePreference.shared

    var perimeterKm: Double { triangle.perimeterM / 1000.0 }
    var closingKm: Double { triangle.closingDistanceM / 1000.0 }

    var statusColor: Color {
        triangle.isClosed ? Color(red: 0.35, green: 0.95, blue: 0.55)
                          : Color(red: 1.0, green: 0.85, blue: 0.3)
    }

    /// Bearing from pilot to home, relative to the pilot's own course.
    /// 0° = straight ahead, 90° = right, -90° = left, 180° = behind.
    var relativeBearingDeg: Double? {
        guard let p = pilotCoord, let h = homeCoord else { return nil }
        let bearing = Self.bearing(from: p, to: h)
        var rel = bearing - pilotHeadingDeg
        while rel > 180  { rel -= 360 }
        while rel < -180 { rel += 360 }
        return rel
    }

    var body: some View {
        let _ = language.code
        return HStack(spacing: 10) {
            // Triangle icon
            Image(systemName: triangle.isClosed ? "triangle.fill" : "triangle")
                .foregroundColor(statusColor)
                .font(.system(size: 20, weight: .bold))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(String(format: "%.1f", perimeterKm))
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    Text("km FAI")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.75))
                }
                if triangle.isClosed {
                    Text(L10n.string("fai_closed"))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                        .foregroundColor(statusColor)
                } else {
                    HStack(spacing: 8) {
                        if let rel = relativeBearingDeg {
                            // Prominent bearing arrow pointing to home
                            // relative to the pilot's current heading.
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.35, green: 0.95, blue: 0.55).opacity(0.2))
                                    .frame(width: 26, height: 26)
                                Image(systemName: "arrow.up")
                                    .font(.system(size: 15, weight: .black))
                                    .foregroundColor(Color(red: 0.35, green: 0.95, blue: 0.55))
                                    .rotationEffect(.degrees(rel))
                            }
                        }
                        VStack(alignment: .leading, spacing: 0) {
                            Text(String(format: "%.1f km", closingKm))
                                .font(.system(size: 13, weight: .heavy, design: .rounded))
                                .foregroundColor(.white.opacity(0.9))
                                .monospacedDigit()
                            Text(L10n.string("fai_closing"))
                                .font(.system(size: 9, weight: .semibold, design: .rounded))
                                .foregroundColor(.white.opacity(0.55))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(statusColor.opacity(0.5), lineWidth: 1.5)
                )
        )
        .shadow(color: .black.opacity(0.35), radius: 4)
        // Make the entire card hit-testable, not just the text/icons.
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            onTap?()
        }
    }

    /// Great-circle initial bearing from a→b in degrees (0 = N, clockwise).
    private static func bearing(from a: CLLocationCoordinate2D,
                                to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let br = atan2(y, x) * 180 / .pi
        return br < 0 ? br + 360 : br
    }
}
