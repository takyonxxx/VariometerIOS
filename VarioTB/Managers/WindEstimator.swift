import Foundation
import CoreLocation
import Combine

/// Estimates wind using GPS ground-track drift while circling.
/// Classic technique: when airborne and turning, the pilot's GPS track
/// forms an offset circle; the circle's center drifts with the wind.
/// We fit the min/max of ground speed over a rolling window to estimate
/// wind speed and direction.
final class WindEstimator: ObservableObject {
    @Published var windSpeedKmh: Double = 0
    @Published var windFromDeg: Double = 0   // direction wind is coming FROM (meteorological)
    @Published var confidence: Double = 0    // 0..1

    private struct Sample {
        let t: TimeInterval
        let speed: Double  // m/s
        let course: Double // rad
    }
    private var samples: [Sample] = []
    private let window: TimeInterval = 30  // seconds
    private let minTurnRateDegPerSec: Double = 3.0

    func update(groundSpeedKmh: Double, courseDeg: Double) {
        let now = Date().timeIntervalSince1970
        let spd = groundSpeedKmh / 3.6
        let crs = courseDeg * .pi / 180.0
        samples.append(Sample(t: now, speed: spd, course: crs))
        samples.removeAll { now - $0.t > window }
        guard samples.count >= 10 else {
            confidence = 0
            return
        }

        // Require some course variation (turning / circling) for good estimate
        let courseSpread = courseSpreadDeg()
        guard courseSpread > 90 else {
            confidence = max(0, confidence - 0.02)
            return
        }

        // Fit: ground speed vs course direction -> sinusoid
        // V_ground(θ) = V_air + V_wind * cos(θ - θ_wind_to)
        // We find θ where speed is MAX (tailwind direction => wind going TO that heading)
        // and θ where speed is MIN (headwind direction).
        // Wind speed = (V_max - V_min) / 2
        // Wind FROM direction = θ_min (direction pilot was heading when slowest = into the wind)
        var vMax = -Double.infinity
        var vMin = Double.infinity
        var thetaMin: Double = 0
        samples.forEach { s in
            if s.speed > vMax { vMax = s.speed }
            if s.speed < vMin { vMin = s.speed; thetaMin = s.course }
        }
        let ws = max(0, (vMax - vMin) / 2.0) * 3.6  // km/h
        let wfromDeg = normalizeDeg(thetaMin * 180.0 / .pi)

        // Simple low-pass to stabilize
        windSpeedKmh = 0.7 * windSpeedKmh + 0.3 * ws
        windFromDeg = angularLerp(windFromDeg, wfromDeg, 0.3)
        confidence = min(1.0, confidence + 0.05)
    }

    private func courseSpreadDeg() -> Double {
        guard samples.count >= 2 else { return 0 }
        var sumSin = 0.0, sumCos = 0.0
        samples.forEach {
            sumSin += sin($0.course)
            sumCos += cos($0.course)
        }
        let r = sqrt(sumSin*sumSin + sumCos*sumCos) / Double(samples.count)
        // r close to 1 = all same direction; r close to 0 = spread / circling
        return (1 - r) * 360.0
    }

    private func normalizeDeg(_ d: Double) -> Double {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x < 0 { x += 360 }
        return x
    }

    private func angularLerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let diff = ((b - a + 540).truncatingRemainder(dividingBy: 360)) - 180
        return normalizeDeg(a + diff * t)
    }
}
