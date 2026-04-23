import SwiftUI
import CoreLocation

/// Radar-style widget. Pilot is always at center.
/// Shows ALL thermals (not just the last one) so the pilot can see behind him.
struct ThermalRadar: View {
    let thermals: [ThermalPoint]
    let pilotCoord: CLLocationCoordinate2D?
    let pilotCourseDeg: Double
    let radiusM: Double

    /// Count of thermals within the current radar range. Used to show the
    /// "out of range" label when thermals exist but none are visible.
    private var inRangeCount: Int {
        guard let p = pilotCoord else { return 0 }
        return thermals.filter { distance(pilot: p, thermal: $0.coordinate) <= radiusM }.count
    }

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2

            ZStack {
                // Soft navy backdrop
                Circle().fill(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.7))
                Circle().stroke(Color.cyan.opacity(0.35), lineWidth: 1.5)

                // Range rings
                ForEach(1..<4) { i in
                    Circle()
                        .stroke(Color.cyan.opacity(0.15), lineWidth: 1)
                        .frame(width: size * CGFloat(i) / 4,
                               height: size * CGFloat(i) / 4)
                }

                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: size, y: r))
                    p.move(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: r, y: size))
                }
                .stroke(Color.cyan.opacity(0.18), lineWidth: 1)

                // Pilot marker (center)
                Circle()
                    .fill(Color(red: 0.4, green: 0.85, blue: 1.0))
                    .frame(width: 12, height: 12)
                    .shadow(color: Color.cyan.opacity(0.9), radius: 6)

                // Pilot heading tick
                Rectangle()
                    .fill(Color(red: 0.4, green: 0.85, blue: 1.0).opacity(0.8))
                    .frame(width: 2, height: 20)
                    .offset(y: -10)
                    .rotationEffect(.degrees(pilotCourseDeg))

                // Thermals WITHIN RANGE only. The radar's coverage (radiusM)
                // comes from settings; thermals farther than that are hidden
                // so the radar stays meaningful — the pilot sees only
                // thermals they could realistically fly to. (The map still
                // shows every detected thermal regardless of range.)
                if let pilot = pilotCoord {
                    let inRange = thermals.filter { t in
                        distance(pilot: pilot, thermal: t.coordinate) <= radiusM
                    }
                    ForEach(Array(inRange.enumerated()), id: \.element.id) { idx, t in
                        ThermalMark(
                            offset: relativePosition(pilot: pilot, thermal: t, radius: r),
                            strength: t.strength,
                            distanceM: distance(pilot: pilot, thermal: t.coordinate),
                            isLatest: idx == inRange.count - 1
                        )
                    }
                }

                // Empty message — shown when no thermals exist OR when all
                // detected thermals are outside the current radar range.
                if pilotCoord == nil || inRangeCount == 0 {
                    VStack {
                        Spacer()
                        Text(thermals.isEmpty
                             ? "Termik bekleniyor"
                             : "Menzil dışında")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.bottom, 8)
                    }
                }

                // Scale label top-right
                VStack {
                    HStack {
                        Spacer()
                        Text("\(Int(radiusM)) m")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.cyan.opacity(0.7))
                            .padding(4)
                    }
                    Spacer()
                }
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func relativePosition(pilot: CLLocationCoordinate2D,
                                  thermal: ThermalPoint,
                                  radius: CGFloat) -> CGSize {
        let dLat = thermal.coordinate.latitude - pilot.latitude
        let dLon = thermal.coordinate.longitude - pilot.longitude
        let meanLat = (pilot.latitude + thermal.coordinate.latitude) / 2 * .pi / 180
        let xMeters = dLon * 111_320 * cos(meanLat)
        let yMeters = dLat * 110_540
        // Thermals have already been filtered by range before being drawn,
        // so a clamp here is unnecessary. Just scale proportionally.
        let dx = CGFloat(xMeters / radiusM) * (radius - 18)
        let dy = -CGFloat(yMeters / radiusM) * (radius - 18)
        return CGSize(width: dx, height: dy)
    }

    private func distance(pilot: CLLocationCoordinate2D,
                          thermal: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: pilot.latitude, longitude: pilot.longitude)
        let b = CLLocation(latitude: thermal.latitude, longitude: thermal.longitude)
        return a.distance(from: b)
    }
}

/// A single thermal marker on the radar. Shows an icon + strength label.
/// Label placement is smart — placed to the side of the marker based on
/// the marker's screen position, so labels don't collide with each other.
private struct ThermalMark: View {
    let offset: CGSize
    let strength: Double
    let distanceM: Double
    let isLatest: Bool

    /// Distinct color per strength tier — easy to tell apart at a glance.
    var color: Color {
        if strength >= 4.0 { return Color(red: 0.30, green: 0.95, blue: 0.70) }  // bright aqua-green (strong)
        if strength >= 3.0 { return Color(red: 0.40, green: 0.85, blue: 1.00) }  // bright cyan
        if strength >= 2.0 { return Color(red: 0.55, green: 0.65, blue: 1.00) }  // soft blue-violet
        if strength >= 1.0 { return Color(red: 0.75, green: 0.55, blue: 0.95) }  // lavender
        return Color(red: 0.70, green: 0.70, blue: 0.85)                         // muted
    }

    /// Place label to the RIGHT of the marker if it's on the left side of
    /// the radar, LEFT otherwise. Avoids vertical stacking collisions.
    var labelOffset: CGSize {
        let dx: CGFloat = offset.width < 0 ? 32 : -32
        // Keep it on the same vertical level as the marker
        return CGSize(width: offset.width + dx, height: offset.height)
    }

    var body: some View {
        ZStack {
            // Marker
            ZStack {
                Circle()
                    .fill(color)
                    .frame(width: isLatest ? 24 : 20, height: isLatest ? 24 : 20)
                    .shadow(color: color.opacity(0.9), radius: isLatest ? 9 : 6)
                Image(systemName: "tornado")
                    .font(.system(size: isLatest ? 13 : 11, weight: .bold))
                    .foregroundColor(.white)
            }
            .offset(offset)

            // Strength label — placed to side (no vertical overlap)
            Text(String(format: "%+.1f", strength))
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundColor(.black)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(color)
                        .shadow(color: color.opacity(0.7), radius: 3)
                )
                .offset(labelOffset)
        }
    }
}
