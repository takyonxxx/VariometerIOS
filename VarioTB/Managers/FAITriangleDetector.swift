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
    /// FAI-VALIDATED best triangle (the old `bestTriangle`). This is the
    /// brute-force result that's cleared the 28% min-leg ratio. Drawn in
    /// green on the map and used for the official perimeter / score.
    /// `nil` until the pilot has flown a geometry that satisfies FAI.
    @Published var validTriangle: FAITriangle?

    /// PROVISIONAL "what am I currently flying" triangle. Always defined
    /// once flightStart and at least one keypoint exist. The three
    /// corners are:
    ///   1. flightStart (takeoff)
    ///   2. The farthest point reached so far (the natural "outermost"
    ///      turnpoint of the flight up to now)
    ///   3. The pilot's current location
    /// This is FAI-INDEPENDENT — we don't apply the 28% leg ratio. It's
    /// the visual "shape of the flight right now" so the pilot can
    /// watch the triangle grow as they fly. Drawn dashed yellow.
    /// When validTriangle is set, the map can show both: yellow under,
    /// green on top, so the pilot sees both "current shape" and
    /// "validated FAI". Falls back to nil before any keypoints exist.
    @Published var provisionalTriangle: FAITriangle?

    /// The first GPS fix recorded, used as the triangle's "home" / closing
    /// reference point. Published so views can draw a closing arrow toward it.
    @Published var flightStart: CLLocationCoordinate2D?

    /// Cumulative path length the pilot has actually flown since
    /// `start()`, in metres. Computed by summing the great-circle
    /// distance between every consecutive *raw* fix as they arrive in
    /// `recordFix(...)` — independent of the keypoint thinning, so this
    /// is the real "how far have I flown" number, not the geometric
    /// perimeter of any detected triangle.
    @Published var pathLengthM: Double = 0

    // Thinned key points from the track. Each one is >= `minSpacingM`
    // from all previously kept points.
    private var keyPoints: [CLLocationCoordinate2D] = []
    private let minSpacingM: Double = 200.0
    private let maxKeyPoints: Int = 150

    /// Index of the keypoint that is currently the farthest from
    /// flightStart. Cached so recordFix can update the provisional
    /// triangle in O(1) per fix instead of rescanning keyPoints.
    /// `-1` when no keypoints exist yet.
    private var farthestKeyIdx: Int = -1
    private var farthestKeyDistM: Double = 0

    /// Last raw fix coordinate seen by recordFix(), used as the start
    /// of the next path-length segment. nil before the first fix.
    private var lastRawFix: CLLocationCoordinate2D?

    /// Most recent pilot coordinate (every fix, not just thinned
    /// keypoints). Needed as the third vertex of the provisional
    /// triangle, which must track the pilot in real time rather than
    /// jumping between thinned keypoints.
    private var currentCoord: CLLocationCoordinate2D?

    // How often to recompute.
    private var recomputeTimer: Timer?
    private let recomputeInterval: TimeInterval = 10.0

    /// True while the recompute timer is running — i.e. between
    /// `start()` and `stop()`. Drives lifecycle decisions in
    /// ContentView so we don't reset the detector mid-flight when
    /// the recorder and simulator both transition.
    var isActive: Bool { recomputeTimer != nil }

    weak var locationMgr: LocationManager?

    func attach(locationManager: LocationManager) {
        self.locationMgr = locationManager
    }

    // MARK: - Lifecycle

    /// Start tracking. Clears any previous state.
    func start() {
        flightStart = nil
        keyPoints.removeAll()
        validTriangle = nil
        provisionalTriangle = nil
        pathLengthM = 0
        farthestKeyIdx = -1
        farthestKeyDistM = 0
        lastRawFix = nil
        currentCoord = nil
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
    /// We thin aggressively for the brute-force buffer — points
    /// < minSpacingM from the last key point are dropped, so memory
    /// stays bounded. But path length and the provisional triangle's
    /// "current location" vertex are updated from EVERY fix so the
    /// pilot sees them tracking smoothly in real time.
    func recordFix() {
        guard let lm = locationMgr, lm.hasFix, let c = lm.coordinate else { return }

        // ---- Cumulative path length: add great-circle segment from
        // the previous raw fix to this one. We do this BEFORE updating
        // lastRawFix so the segment uses the previous→current pair.
        if let prev = lastRawFix {
            let seg = Self.distanceM(prev, c)
            // Reject pathological GPS jumps (>2 km between adjacent
            // fixes) to avoid corrupting pathLengthM with bad fixes.
            // Real flight speeds rarely exceed 30 m/s ≈ 30 m per 1 Hz
            // tick, so anything over 2 km is almost certainly noise.
            if seg < 2000 {
                pathLengthM += seg
            }
        }
        lastRawFix = c
        currentCoord = c

        // ---- Flight start anchor (first fix only).
        if flightStart == nil {
            flightStart = c
        }

        // ---- Key-point thinning: only append if far enough from the
        // last keypoint. Most fixes are skipped here, which is fine —
        // the brute-force search needs spread-out points, not raw fixes.
        var addedKeypoint = false
        if let last = keyPoints.last {
            let d = Self.distanceM(last, c)
            if d >= minSpacingM {
                keyPoints.append(c)
                addedKeypoint = true
            }
        } else {
            keyPoints.append(c)
            addedKeypoint = true
        }

        if addedKeypoint && keyPoints.count > maxKeyPoints {
            thinBuffer()
            // After thinning, the cached farthest index may be stale.
            // Rebuild it from scratch — cheap (≤150 points).
            recomputeFarthest()
        }

        // ---- Track the farthest keypoint from flightStart. Used as
        // the "outer" corner of the provisional triangle. We only need
        // to check the new keypoint vs the cached farthest distance —
        // O(1) per fix.
        if addedKeypoint, let start = flightStart {
            let d = Self.distanceM(start, c)
            if d > farthestKeyDistM {
                farthestKeyDistM = d
                farthestKeyIdx = keyPoints.count - 1
            }
        }

        // ---- Update the provisional triangle. Three vertices:
        //   1. flightStart        (takeoff)
        //   2. keyPoints[farthest] (outer turnpoint)
        //   3. currentCoord       (live pilot position)
        // We update on EVERY fix, not just keypoint additions, so the
        // third vertex slides smoothly with the pilot. The triangle is
        // suppressed when the three vertices haven't pulled apart yet
        // (e.g. pilot still right at takeoff) — anything too small to
        // be visually meaningful (< 100 m on its shortest side) is
        // hidden to avoid a flickering speck under the paraglider icon.
        updateProvisional()
    }

    /// Recompute the provisional ("what am I flying right now") triangle
    /// from current state. Called on every fix so the live-position
    /// vertex tracks the pilot smoothly.
    ///
    /// Two gates suppress the triangle when the geometry isn't
    /// meaningfully triangular yet:
    ///
    ///   1. **Min-side gate**: Each leg must be at least 500 m. Below
    ///      that the "triangle" is just a paraglider-sized blob on the
    ///      map — not a useful visual.
    ///
    ///   2. **Turn-angle gate**: The pilot must have actually TURNED
    ///      at the outer vertex. We compute the interior angle at
    ///      `outer` between the takeoff→outer leg and the outer→pilot
    ///      leg. On a straight outbound flight this angle stays close
    ///      to 180° (pilot is still flying outward, no turn yet); on a
    ///      genuine turn it drops well below that. Threshold 150° lets
    ///      the triangle appear once the pilot has clearly committed
    ///      to a new heading. Until then we hide the dashed yellow
    ///      outline so it doesn't suggest a triangle that doesn't
    ///      really exist yet.
    private static let provisionalMinLegM: Double = 500.0
    private static let provisionalMaxAngleDeg: Double = 150.0

    private func updateProvisional() {
        guard let start = flightStart,
              let cur = currentCoord,
              farthestKeyIdx >= 0,
              farthestKeyIdx < keyPoints.count else {
            provisionalTriangle = nil
            return
        }
        let outer = keyPoints[farthestKeyIdx]
        let a = Self.distanceM(start, outer)   // takeoff → outer
        let b = Self.distanceM(outer, cur)     // outer → pilot
        let c = Self.distanceM(cur, start)     // pilot → takeoff

        // Min-side gate.
        if min(a, min(b, c)) < Self.provisionalMinLegM {
            provisionalTriangle = nil
            return
        }

        // Turn-angle gate: interior angle at `outer`. Use the law of
        // cosines on the triangle's sides — given sides a (takeoff↔
        // outer) and b (outer↔pilot) meeting at outer, with c being
        // the opposite side (takeoff↔pilot):
        //   cos(angle_at_outer) = (a² + b² − c²) / (2 · a · b)
        // angle close to 180° → cos ≈ −1 → pilot is still flying
        // straight outward past the outer point, no real turn yet.
        // angle dropping below 150° → pilot has clearly turned.
        let cosAngle = (a*a + b*b - c*c) / (2 * a * b)
        // Clamp to handle floating-point drift past ±1.
        let clamped = max(-1.0, min(1.0, cosAngle))
        let angleDeg = acos(clamped) * 180 / .pi
        if angleDeg > Self.provisionalMaxAngleDeg {
            provisionalTriangle = nil
            return
        }

        let perim = a + b + c
        let closingDist = Self.distanceM(start, cur)
        // The provisional triangle's "isClosed" doesn't gate FAI
        // validity (that's validTriangle's job), it just reports the
        // current closing geometry to whoever wants to display it.
        let isClosed = closingDist <= perim * 0.20
        provisionalTriangle = FAITriangle(
            tp1: start, tp2: outer, tp3: cur,
            perimeterM: perim,
            closingDistanceM: closingDist,
            isClosed: isClosed)
    }

    /// Rebuild the farthest-keypoint cache after a thin-buffer pass.
    /// O(n) over keyPoints; only invoked when thinBuffer() actually
    /// reshuffled the array, so amortised cost stays low.
    private func recomputeFarthest() {
        guard let start = flightStart else {
            farthestKeyIdx = -1
            farthestKeyDistM = 0
            return
        }
        var bestIdx = -1
        var bestD = 0.0
        for (i, p) in keyPoints.enumerated() {
            let d = Self.distanceM(start, p)
            if d > bestD {
                bestD = d
                bestIdx = i
            }
        }
        farthestKeyIdx = bestIdx
        farthestKeyDistM = bestD
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
            DispatchQueue.main.async { self.validTriangle = nil }
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
                self.validTriangle = result
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
