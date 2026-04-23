import Foundation
import CoreLocation
import Combine

/// FAI Flat Triangle detector.
///
/// While recording a flight, this class buffers GPS fixes and periodically
/// computes the largest FAI-valid triangle achievable from any 3 points in
/// the track. The result is published for the map and a dedicated HUD to
/// show in real time.
///
/// ## FAI Flat Triangle rules (simplified)
///
/// Given 3 turnpoints TP1, TP2, TP3 chosen from the track in time order:
///   - Let a, b, c be the great-circle distances between consecutive TPs.
///   - Total perimeter: P = a + b + c.
///   - Each leg must be at least 28% of P:  min(a,b,c) / P >= 0.28
///   - Closing distance: distance between the start point (before TP1) and
///     the end point (after TP3) must be <= 20% of P (= 0.20 * P). For a
///     live partial flight we use the current fix as "end point" and the
///     first recorded fix as "start point".
///
/// The SCORE is `P` if the triangle is fully closed (closing distance is
/// within the 20% limit). Otherwise we show `P` but mark the triangle as
/// "open" — the pilot still needs to return close to start to validate.
///
/// ## Performance
///
/// Brute-force O(n³) over all fixes is too expensive for a multi-hour
/// flight (n = thousands). We reduce the buffer to at most ~120 key points
/// using a distance-based thinning filter (keep points > 200m apart), then
/// run O(n³) on ~120 points (~1.7M combinations). On a modern iPhone this
/// runs in well under 100ms, and we only re-run every 10 seconds.
final class FAITriangleDetector: ObservableObject {
    // Published best triangle found so far.
    @Published var bestTriangle: FAITriangle?
    /// The first GPS fix recorded, used as the triangle's "home" / closing
    /// reference point. Published so views can draw a closing arrow toward it.
    @Published var flightStart: CLLocationCoordinate2D?

    // Thinned key points from the track. Each one is >= `minSpacingM`
    // from all previously kept points.
    private var keyPoints: [CLLocationCoordinate2D] = []
    private let minSpacingM: Double = 200.0
    private let maxKeyPoints: Int = 150

    // How often to recompute.
    private var recomputeTimer: Timer?
    private let recomputeInterval: TimeInterval = 10.0

    weak var locationMgr: LocationManager?

    func attach(locationManager: LocationManager) {
        self.locationMgr = locationManager
    }

    // MARK: - Lifecycle

    /// Start tracking. Clears any previous state.
    func start() {
        flightStart = nil
        keyPoints.removeAll()
        bestTriangle = nil
        recomputeTimer?.invalidate()
        recomputeTimer = Timer.scheduledTimer(withTimeInterval: recomputeInterval,
                                              repeats: true) { [weak self] _ in
            self?.recompute()
        }
    }

    func stop() {
        recomputeTimer?.invalidate()
        recomputeTimer = nil
    }

    /// Call from the main app tick to feed new fixes.
    /// We thin aggressively — points < minSpacingM from the last key point
    /// are dropped, so memory stays bounded.
    func recordFix() {
        guard let lm = locationMgr, lm.hasFix, let c = lm.coordinate else { return }

        if flightStart == nil {
            flightStart = c
        }

        if let last = keyPoints.last {
            let d = distanceM(last, c)
            if d < minSpacingM { return }
        }

        keyPoints.append(c)

        // Cap the buffer
        if keyPoints.count > maxKeyPoints {
            thinBuffer()
        }
    }

    private func thinBuffer() {
        var thinned: [CLLocationCoordinate2D] = []
        thinned.reserveCapacity(keyPoints.count / 2 + 1)
        for (i, p) in keyPoints.enumerated() {
            if i % 2 == 0 || i == keyPoints.count - 1 {
                thinned.append(p)
            }
        }
        keyPoints = thinned
    }

    // MARK: - Computation

    private func recompute() {
        guard keyPoints.count >= 3, let start = flightStart else {
            DispatchQueue.main.async { self.bestTriangle = nil }
            return
        }

        // Copy buffer to avoid threading issues; run heavy work off-main.
        let pts = keyPoints
        let current = pts.last ?? start
        DispatchQueue.global(qos: .utility).async {
            let result = Self.findBestTriangle(points: pts,
                                               flightStart: start,
                                               flightEnd: current)
            DispatchQueue.main.async {
                self.bestTriangle = result
            }
        }
    }

    /// Brute-force search: iterate all ordered triples (i < j < k) and
    /// keep the triangle with the largest perimeter P that satisfies the
    /// 28% min-leg constraint. Closing distance is computed separately.
    static func findBestTriangle(points: [CLLocationCoordinate2D],
                                 flightStart: CLLocationCoordinate2D,
                                 flightEnd: CLLocationCoordinate2D) -> FAITriangle? {
        let n = points.count
        guard n >= 3 else { return nil }

        // Pre-compute pairwise distances to cut cost (n² pre-calc instead
        // of n³ distance calls inside the triple loop).
        var dist = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in (i+1)..<n {
                let d = distanceM(points[i], points[j])
                dist[i][j] = d
                dist[j][i] = d
            }
        }

        var bestP: Double = 0
        var bestIJK: (Int, Int, Int)?

        for i in 0..<(n - 2) {
            for j in (i + 1)..<(n - 1) {
                let a = dist[i][j]
                // Early pruning: if a*3 < current bestP we can't improve.
                // (each leg is at most P * (1/3 + something); very loose
                // bound, but a tight one that works: if a < bestP*0.28
                // then this i-j pair can never produce a better valid
                // triangle because a is the "first leg".)
                if a < bestP * 0.28 { continue }
                for k in (j + 1)..<n {
                    let b = dist[j][k]
                    let c = dist[k][i]
                    let p = a + b + c
                    if p <= bestP { continue }
                    // 28% min-leg rule
                    let minLeg = min(a, min(b, c))
                    if minLeg / p < 0.28 { continue }
                    bestP = p
                    bestIJK = (i, j, k)
                }
            }
        }

        guard let (i, j, k) = bestIJK else { return nil }

        let tp1 = points[i]
        let tp2 = points[j]
        let tp3 = points[k]
        let closingDist = distanceM(flightStart, flightEnd)
        let isClosed = closingDist <= bestP * 0.20

        return FAITriangle(tp1: tp1, tp2: tp2, tp3: tp3,
                           perimeterM: bestP,
                           closingDistanceM: closingDist,
                           isClosed: isClosed)
    }

    // MARK: - Geometry

    /// Great-circle distance in meters using the haversine formula.
    private static func distanceM(_ a: CLLocationCoordinate2D,
                                  _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sa = sin(dLat/2)
        let sb = sin(dLon/2)
        let h = sa*sa + cos(lat1)*cos(lat2)*sb*sb
        return 2 * R * asin(min(1, sqrt(h)))
    }

    private func distanceM(_ a: CLLocationCoordinate2D,
                           _ b: CLLocationCoordinate2D) -> Double {
        return Self.distanceM(a, b)
    }
}

/// The best FAI-valid triangle found in the track so far.
struct FAITriangle: Equatable {
    let tp1: CLLocationCoordinate2D
    let tp2: CLLocationCoordinate2D
    let tp3: CLLocationCoordinate2D
    let perimeterM: Double
    let closingDistanceM: Double
    /// True if `closingDistanceM / perimeterM <= 0.20` — pilot has returned
    /// close enough to the flight start to claim the triangle.
    let isClosed: Bool

    /// Min leg length / perimeter — must be >= 0.28 for FAI validity.
    /// Always valid here since we only emit triangles that passed the check.
    var minLegRatio: Double {
        let a = distanceM(tp1, tp2)
        let b = distanceM(tp2, tp3)
        let c = distanceM(tp3, tp1)
        return min(a, min(b, c)) / perimeterM
    }

    /// Distance to close required (remaining from current position) as % of perimeter.
    var closingRatio: Double {
        perimeterM > 0 ? closingDistanceM / perimeterM : 0
    }

    static func == (lhs: FAITriangle, rhs: FAITriangle) -> Bool {
        return lhs.perimeterM == rhs.perimeterM &&
               lhs.tp1.latitude == rhs.tp1.latitude &&
               lhs.tp1.longitude == rhs.tp1.longitude &&
               lhs.tp3.latitude == rhs.tp3.latitude &&
               lhs.tp3.longitude == rhs.tp3.longitude
    }

    private func distanceM(_ a: CLLocationCoordinate2D,
                           _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sa = sin(dLat/2)
        let sb = sin(dLon/2)
        let h = sa*sa + cos(lat1)*cos(lat2)*sb*sb
        return 2 * R * asin(min(1, sqrt(h)))
    }
}
