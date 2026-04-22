import SwiftUI
import CoreLocation

/// Radar-style widget. Pilot is always at center. As the pilot moves away from
/// the last thermal, the dot drifts outward proportional to distance, capped
/// at the ring radius. The ring label shows the scale (e.g. "1500 m").
struct ThermalRadar: View {
    let thermal: ThermalPoint?
    let pilotCoord: CLLocationCoordinate2D?
    let pilotCourseDeg: Double
    let radiusM: Double  // max scale in meters

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2

            ZStack {
                // Backdrop
                Circle().fill(Color.black.opacity(0.45))
                Circle().stroke(Color.white.opacity(0.35), lineWidth: 1.5)

                // Range rings
                ForEach(1..<4) { i in
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                        .frame(width: size * CGFloat(i) / 4,
                               height: size * CGFloat(i) / 4)
                }

                // Crosshair
                Path { p in
                    p.move(to: CGPoint(x: 0, y: r)); p.addLine(to: CGPoint(x: size, y: r))
                    p.move(to: CGPoint(x: r, y: 0)); p.addLine(to: CGPoint(x: r, y: size))
                }
                .stroke(Color.white.opacity(0.15), lineWidth: 1)

                // Pilot marker (center)
                Circle()
                    .fill(Color.cyan)
                    .frame(width: 10, height: 10)
                    .shadow(color: .cyan.opacity(0.8), radius: 6)

                // Pilot heading tick
                Rectangle()
                    .fill(Color.cyan.opacity(0.7))
                    .frame(width: 2, height: 18)
                    .offset(y: -9)
                    .rotationEffect(.degrees(pilotCourseDeg))

                // Thermal dot + strength label
                if let t = thermal, let pilot = pilotCoord {
                    let (dx, dy) = relativePosition(pilot: pilot, thermal: t, radius: r)
                    let strengthColor = thermalColor(t.strength)

                    // Line from pilot to thermal
                    Path { p in
                        p.move(to: CGPoint(x: r, y: r))
                        p.addLine(to: CGPoint(x: r + dx, y: r + dy))
                    }
                    .stroke(strengthColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4,3]))

                    // Thermal marker
                    ZStack {
                        Circle()
                            .fill(strengthColor)
                            .frame(width: 18, height: 18)
                            .shadow(color: strengthColor, radius: 6)
                        Image(systemName: "tornado")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .offset(x: dx, y: dy)

                    Text(String(format: "%+.1f m/s", t.strength))
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(strengthColor.opacity(0.85)))
                        .offset(x: dx, y: dy + 22)

                    // Distance label
                    let dist = distance(pilot: pilot, thermal: t.coordinate)
                    VStack {
                        Spacer()
                        Text(distanceText(dist))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.bottom, 6)
                    }
                } else {
                    VStack {
                        Spacer()
                        Text("Termik bekleniyor")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
                            .padding(.bottom, 6)
                    }
                }

                // Scale label top-right
                VStack {
                    HStack {
                        Spacer()
                        Text("\(Int(radiusM)) m")
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundColor(.white.opacity(0.55))
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
                                  radius: CGFloat) -> (CGFloat, CGFloat) {
        let dLat = thermal.coordinate.latitude - pilot.latitude
        let dLon = thermal.coordinate.longitude - pilot.longitude
        let meanLat = (pilot.latitude + thermal.coordinate.latitude) / 2 * .pi / 180
        let xMeters = dLon * 111_320 * cos(meanLat)
        let yMeters = dLat * 110_540
        let distM = sqrt(xMeters*xMeters + yMeters*yMeters)

        // Scale so that radius corresponds to radiusM. Clamp.
        let scale = distM > radiusM ? (radiusM / distM) : 1.0
        let scaled = (xMeters * scale, yMeters * scale)
        // Map coordinates (north is -y on screen)
        let dx = CGFloat(scaled.0 / radiusM) * (radius - 14)
        let dy = -CGFloat(scaled.1 / radiusM) * (radius - 14)
        return (dx, dy)
    }

    private func distance(pilot: CLLocationCoordinate2D,
                          thermal: CLLocationCoordinate2D) -> Double {
        let a = CLLocation(latitude: pilot.latitude, longitude: pilot.longitude)
        let b = CLLocation(latitude: thermal.latitude, longitude: thermal.longitude)
        return a.distance(from: b)
    }

    private func distanceText(_ m: Double) -> String {
        if m >= 1000 { return String(format: "%.1f km", m/1000) }
        return String(format: "%.0f m", m)
    }

    private func thermalColor(_ strength: Double) -> Color {
        if strength >= 3.0 { return .red }
        if strength >= 2.0 { return .orange }
        if strength >= 1.0 { return .yellow }
        return .green
    }
}
