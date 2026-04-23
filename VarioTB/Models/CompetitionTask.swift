import Foundation
import CoreLocation
import UIKit

/// Type of turnpoint in a paragliding competition task.
enum TurnpointType: String, Codable, CaseIterable, Identifiable {
    case takeoff  = "Takeoff"    // Kalkış
    case sss      = "SSS"        // Start of Speed Section (start time + exit cylinder)
    case turn     = "Turn"       // Standart turnpoint (cylinder)
    case ess      = "ESS"        // End of Speed Section (hızlı bölüm sonu)
    case goal     = "Goal"       // Final — varış noktası (line veya cylinder)

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .takeoff: return "Kalkış"
        case .sss:     return "Start (SSS)"
        case .turn:    return "Turnpoint"
        case .ess:     return "ESS"
        case .goal:    return "Goal"
        }
    }

    /// Default direction (how the cylinder is "crossed") for each type.
    var defaultDirection: TurnpointDirection {
        switch self {
        case .takeoff:    return .exit    // kalkış sonrası çıkmalısın
        case .sss:        return .exit    // SSS = start gate, içeriden dışarı
        case .turn:       return .enter
        case .ess:        return .enter
        case .goal:       return .enter
        }
    }
}

/// How a turnpoint's cylinder is crossed to count as "reached".
enum TurnpointDirection: String, Codable {
    case enter          // Dışarıdan içeri (silindirin içine gir)
    case exit           // İçeriden dışarı (silindirin içindeyken dışarı çık)
    case line           // Line crossing (goal için genellikle)
}

/// A single turnpoint in a paragliding task.
struct Turnpoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var type: TurnpointType
    var latitude: Double
    var longitude: Double
    var altitudeM: Double = 0          // optional elevation
    var radiusM: Double                 // cylinder radius in meters
    var direction: TurnpointDirection   // enter / exit / line
    var optional: Bool = false          // if true, skipping doesn't invalidate the route
    var description: String = ""        // free-form note
    /// Start time (UTC) — set for SSS. Only meaningful if type == .sss.
    var startTime: Date? = nil

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Convenience: single-line summary
    var summary: String {
        let dirText: String = {
            switch direction {
            case .enter: return "IN"
            case .exit:  return "OUT"
            case .line:  return "LINE"
            }
        }()
        return "\(type.rawValue) • \(Int(radiusM)) m • \(dirText)"
    }
}

/// A competition task — ordered list of turnpoints, plus metadata.
final class CompetitionTask: ObservableObject, Codable {
    @Published var name: String = "Task"
    @Published var turnpoints: [Turnpoint] = []
    /// When the task window opens (task start — no flight before this)
    @Published var taskStartTime: Date? = nil
    /// When the goal must be reached by (optional cut-off)
    @Published var taskDeadline: Date? = nil

    enum CodingKeys: String, CodingKey {
        case name, turnpoints, taskStartTime, taskDeadline
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        turnpoints = try c.decode([Turnpoint].self, forKey: .turnpoints)
        taskStartTime = try c.decodeIfPresent(Date.self, forKey: .taskStartTime)
        taskDeadline = try c.decodeIfPresent(Date.self, forKey: .taskDeadline)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name, forKey: .name)
        try c.encode(turnpoints, forKey: .turnpoints)
        try c.encodeIfPresent(taskStartTime, forKey: .taskStartTime)
        try c.encodeIfPresent(taskDeadline, forKey: .taskDeadline)
    }

    // MARK: - CRUD

    func addTurnpoint(_ tp: Turnpoint) {
        turnpoints.append(tp)
    }

    func removeTurnpoint(at offsets: IndexSet) {
        turnpoints.remove(atOffsets: offsets)
    }

    func moveTurnpoint(from source: IndexSet, to destination: Int) {
        turnpoints.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: - Geometry / distance

    /// Optimized task distance: sum of great-circle distances between consecutive
    /// turnpoints. Simplified — real comp scoring also reduces by cylinder radii
    /// Total optimum-route task distance in meters. Matches the "opt"
    /// figure shown for the last turnpoint in the task list — i.e. it's
    /// the sum of all per-leg optimum distances using the same rules
    /// (radial difference for coincident centers, perimeter-to-
    /// perimeter otherwise). This is what competition scoring uses.
    var totalDistanceM: Double {
        guard turnpoints.count >= 2 else { return 0 }
        return cumulativeOptimumDistanceTo(tpIndex: turnpoints.count - 1)
    }

    // MARK: - Task progress

    /// Set of turnpoint IDs the pilot has already touched (entered their
    /// cylinder). Updated via updateProgress(pilot:). Not persisted —
    /// progress resets when the app relaunches, which is the XCTrack
    /// convention (pilots re-enter the pre-start zone at launch).
    @Published var reachedTPIds: Set<UUID> = []

    /// Pumped every time a new turnpoint is reached. Views observe this
    /// to trigger reach-feedback animations (colour flash, haptic, etc).
    /// nil at startup; set to the TP's id inside updateProgress when a
    /// new cylinder is entered. Cleared by subscribers after they've
    /// reacted (or left set — re-reads are idempotent since the id
    /// won't change until the next reach).
    @Published var lastReachEvent: UUID? = nil

    /// GPS tolerance applied to cylinder entry checks. Real pilots don't
    /// get perfect fixes — 10-15m error is normal. We widen each cylinder
    /// by this much when deciding "pilot reached the TP" so a pilot who
    /// physically flew the edge doesn't get cheated by a stray GPS fix.
    /// Matches what XCTrack and FlySkyhy allow for competition scoring.
    static let gpsToleranceM: Double = 15.0

    /// Call this on every GPS update while a task is active. A turnpoint
    /// is considered reached when the pilot's position is inside its
    /// cylinder (with a small GPS-error tolerance added). Tangent
    /// passes don't count — the pilot must physically enter the cylinder,
    /// which is the competition scoring rule.
    ///
    /// Turnpoints are processed in strict order: you can't reach TP3
    /// before TP2. If the pilot skips one (e.g. flies too wide) the task
    /// stays paused on that TP until they go back and tag it.
    func updateProgress(pilot: CLLocationCoordinate2D) {
        for tp in turnpoints {
            guard !reachedTPIds.contains(tp.id) else { continue }
            let d = Self.haversine(pilot, tp.coordinate)
            if d <= tp.radiusM + Self.gpsToleranceM {
                reachedTPIds.insert(tp.id)
                // Broadcast the reach event. Audible chime + haptic
                // fire immediately; any visible flash in the UI (course
                // card, map annotation, etc.) latches onto the
                // published id via its own @Published observer.
                lastReachEvent = tp.id
                ChimePlayer.shared.playReachChime()
                DispatchQueue.main.async {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                continue
            }
            // Not in this cylinder yet — can't look past it.
            break
        }
    }

    /// The next turnpoint the pilot should fly toward. nil if task is
    /// empty or fully completed.
    func nextTurnpoint(pilot: CLLocationCoordinate2D) -> Turnpoint? {
        for tp in turnpoints where !reachedTPIds.contains(tp.id) {
            return tp
        }
        return nil
    }

    /// Great-circle bearing from pilot to next turnpoint, in degrees
    /// (0°=North, clockwise). Returns nil if there is no next point.
    func bearingToNextTurnpoint(from pilot: CLLocationCoordinate2D) -> Double? {
        guard let tp = nextTurnpoint(pilot: pilot) else { return nil }
        return Self.bearing(from: pilot, to: tp.coordinate)
    }

    /// Existing API kept for compatibility.
    func nextTurnpointIndex(pilot: CLLocationCoordinate2D,
                            reachedIDs: Set<UUID>) -> Int? {
        for (i, tp) in turnpoints.enumerated() where !reachedIDs.contains(tp.id) {
            return i
        }
        return nil
    }

    /// Returns true if the pilot is inside the given turnpoint's cylinder,
    /// with GPS tolerance accounted for.
    func isInsideCylinder(pilot: CLLocationCoordinate2D,
                          tp: Turnpoint) -> Bool {
        return Self.haversine(pilot, tp.coordinate) <= tp.radiusM + Self.gpsToleranceM
    }

    // MARK: - Optimal-route distance calculations
    //
    // A competition task is flown by touching each turnpoint's cylinder
    // in sequence. The shortest legal path (the "optimised distance" or
    // "tangent route") threads between cylinders — each interior TP is
    // crossed at the point on its perimeter that minimises total path
    // length. We compute those tangent points via iterative bisector
    // refinement, using the pilot's CURRENT position as the anchor for
    // the first leg.
    //
    // This lets us show the pilot:
    //   - distance to next TP: along the optimal route, to the tangent
    //     point of the next un-reached cylinder
    //   - distance to goal:    sum of remaining optimal-route leg lengths
    //     from the pilot all the way to goal
    //
    // Both numbers match the scored competition distance rather than
    // straight-line "crow flies" estimates.

    /// Compute optimal tangent crossing points for the REMAINING task
    /// (starting from the next un-reached turnpoint through goal), using
    /// the pilot's current position as the path start anchor.
    ///
    /// Returns an array of coordinates [pilot, tp_next_tangent, ..., goal_center].
    /// The first element is always the pilot; the last is the goal
    /// turnpoint's center (we touch goal by entering its cylinder,
    /// which is the classic XCTrack convention for scoring).
    func optimalRemainingPoints(from pilot: CLLocationCoordinate2D,
                                 overrideRemaining: [Turnpoint]? = nil)
        -> [CLLocationCoordinate2D]
    {
        // Collect all turnpoints not yet reached (unless the caller
        // passed an explicit override — used internally to evaluate
        // "optimum distance from a specific TP onward" without the
        // pilot coinciding with a cylinder edge).
        let remaining = overrideRemaining
                         ?? turnpoints.filter { !reachedTPIds.contains($0.id) }
        guard !remaining.isEmpty else { return [pilot] }

        // Work in scaled (lat, lon) space so the bisector math is
        // isotropic over competition-scale distances (<200km).
        let centerLatRad = pilot.latitude * .pi / 180
        let lonScale = cos(centerLatRad)
        let metersPerDeg = 111_000.0

        func toXY(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (c.longitude * lonScale, c.latitude)
        }
        func fromXY(_ p: (x: Double, y: Double)) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: p.y, longitude: p.x / lonScale)
        }

        // Path: [pilot, tp0_center, tp1_center, ..., last_center]
        // Cylinders constrain only the INTERIOR tps (indices 1..N-2 in
        // the path sense — pilot and goal are anchors).
        var path: [(x: Double, y: Double)] = [toXY(pilot)]
        var radii: [Double] = [0]   // pilot has no radius, it's a fixed anchor
        for tp in remaining {
            path.append(toXY(tp.coordinate))
            radii.append(tp.radiusM / metersPerDeg)
        }
        let centers = path

        // Decide which indices are "touchable cylinders" we optimize:
        //   - index 0 is the pilot anchor
        //   - indices 1..<lastIdx are tangent crossings (their optimum
        //     point sits on the cylinder perimeter)
        //   - the last index is the goal — its optimum point is the
        //     CENTER (pilot must enter the goal cylinder, not just touch
        //     it). This matches how competition scoring works.
        let lastIdx = path.count - 1

        // 8 bisector iterations → converges well for typical comp tasks.
        let iterations = 8
        for _ in 0..<iterations {
            var next = path
            for i in 1..<lastIdx {
                let c = centers[i]
                let prev = path[i - 1]
                let after = path[i + 1]
                let vPrev = normalized(dx: prev.x - c.x, dy: prev.y - c.y)
                let vNext = normalized(dx: after.x - c.x, dy: after.y - c.y)
                var bx = vPrev.dx + vNext.dx
                var by = vPrev.dy + vNext.dy
                let blen = sqrt(bx*bx + by*by)
                if blen < 1e-9 {
                    // Three-point colinearity: fall back to perpendicular
                    let dx = after.x - prev.x
                    let dy = after.y - prev.y
                    let perp = normalized(dx: -dy, dy: dx)
                    bx = perp.dx; by = perp.dy
                } else {
                    bx /= blen; by /= blen
                }
                next[i] = (c.x + bx * radii[i], c.y + by * radii[i])
            }
            path = next
        }

        return path.map { fromXY($0) }
    }

    private func normalized(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        let len = sqrt(dx*dx + dy*dy)
        if len < 1e-12 { return (0, 0) }
        return (dx / len, dy / len)
    }

    /// Optimal-route distance from pilot to the tangent crossing of the
    /// next un-reached turnpoint. Accounts for cylinder radii — this is
    /// the shortest legal path to "tag" the next gate. Returns 0 when
    /// pilot is already inside the next TP's cylinder.
    ///
    /// When the pilot is VERY close to the next TP's cylinder edge, the
    /// tangent-point calculation becomes unstable (the bisector swings
    /// around as the pilot moves through the vicinity), which causes
    /// the displayed distance to bounce up and down by tens of metres.
    /// We guard against this by just returning straight-line distance
    /// to the cylinder perimeter whenever the pilot is within 2×radius
    /// of the next TP's center — at that range the tangent refinement
    /// isn't helping anyway.
    func distanceToNextTurnpoint(from pilot: CLLocationCoordinate2D) -> Double? {
        guard let next = nextTurnpoint(pilot: pilot) else { return nil }
        let dCenter = Self.haversine(pilot, next.coordinate)
        if dCenter <= next.radiusM + Self.gpsToleranceM { return 0 }
        if dCenter < next.radiusM * 2 {
            // Close to the cylinder — return the straight-line distance
            // to its perimeter (this is what the pilot perceives and is
            // stable as they approach).
            return max(0, dCenter - next.radiusM)
        }
        let pts = optimalRemainingPoints(from: pilot)
        guard pts.count >= 2 else { return nil }
        return Self.haversine(pts[0], pts[1])
    }

    /// Optimal-route distance from pilot to goal, summed over all
    /// remaining tangent legs. Equals the total remaining task distance
    /// the pilot still has to fly. Returns 0 once the pilot has entered
    /// the goal cylinder (task complete).
    ///
    /// Uses the same "close-to-next" stabilisation as distanceToNext:
    /// when the pilot is within 2×radius of the next TP, we compute
    /// `(straight-line to perimeter) + (optimum distance from TP center
    /// to goal)` rather than running the full bisector refinement with
    /// the pilot as a near-coincident anchor (which oscillates).
    func distanceToGoal(from pilot: CLLocationCoordinate2D) -> Double? {
        guard let goal = turnpoints.last else { return nil }
        if isInsideCylinder(pilot: pilot, tp: goal) { return 0 }

        guard let next = nextTurnpoint(pilot: pilot) else {
            // All TPs reached but pilot not yet in goal cylinder —
            // measure from current position to goal center.
            return Self.haversine(pilot, goal.coordinate)
        }
        let dCenterNext = Self.haversine(pilot, next.coordinate)
        if dCenterNext < next.radiusM * 2 {
            // Stable branch: pilot→perimeter, then the optimum distance
            // from the NEXT TP's center through the remaining task.
            let toPerim = max(0, dCenterNext - next.radiusM)
            let rest = optimumDistanceFrom(tpIndex: turnpointIndex(next),
                                            includingStart: false)
            return toPerim + rest
        }

        let pts = optimalRemainingPoints(from: pilot)
        guard pts.count >= 2 else { return nil }
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            total += Self.haversine(pts[i], pts[i + 1])
        }
        return total
    }

    /// Index of `tp` within the task's turnpoint array, or -1 if not found.
    private func turnpointIndex(_ tp: Turnpoint) -> Int {
        turnpoints.firstIndex(where: { $0.id == tp.id }) ?? -1
    }

    /// Cumulative optimum-route distance from TAKEOFF up to (and
    /// including) the turnpoint at `tpIndex`, in meters. Used for the
    /// task total — a stable, GPS-independent number pinned to the
    /// task definition. Live pilot-relative display uses
    /// `cumulativeOptimumDistanceFromPilot` instead.
    ///
    /// Each leg's optimum distance is:
    ///   - If the two TPs share the same center → `|r₁ − r₂|` (the
    ///     pilot moves radially between the two cylinder edges; e.g.
    ///     entering a 5 km cylinder from a 10 km cylinder means flying
    ///     5 km inward along the shared radial)
    ///   - Otherwise → `max(0, haversine − r₁ − r₂)` (straight-line
    ///     distance between cylinder centers minus the two radii)
    ///
    /// Returns 0 for tpIndex 0 (takeoff — start of task).
    func cumulativeOptimumDistanceTo(tpIndex: Int) -> Double {
        guard tpIndex > 0, tpIndex < turnpoints.count else { return 0 }
        var total = 0.0
        for i in 1...tpIndex {
            total += legOptimumDistance(fromIndex: i - 1, toIndex: i)
        }
        return total
    }

    /// Optimum flight distance for the single leg between two adjacent
    /// turnpoints. See `cumulativeOptimumDistanceTo` for the logic.
    ///
    /// Special case: when the origin TP is the TAKEOFF (index 0), we
    /// treat it as a point rather than a cylinder. The takeoff is the
    /// pilot's physical launch site, not a gate they have to cross —
    /// the task distance is measured from the takeoff point to the
    /// first gate's edge. This matches Flyskyhy / XCTrack scoring.
    private func legOptimumDistance(fromIndex i: Int, toIndex j: Int) -> Double {
        guard i >= 0, j < turnpoints.count else { return 0 }
        let a = turnpoints[i]
        let b = turnpoints[j]

        // TAKEOFF is the pilot's launch point, not a cylinder they
        // cross — flyskyhy/XCTrack convention. Model it as a zero-
        // radius anchor so both concentric and separate-center formulas
        // pick up the full distance to the next TP's edge.
        let aR = (i == 0 && a.type == .takeoff) ? 0 : a.radiusM

        let d = Self.haversine(a.coordinate, b.coordinate)
        if d < 5 {
            return abs(aR - b.radiusM)
        }
        return max(0, d - aR - b.radiusM)
    }

    /// Optimal tangent-route distance from turnpoint at `tpIndex` (its
    /// center) through all subsequent TPs to goal. Used by the stable
    /// branch of distanceToGoal when the pilot is near the next TP.
    private func optimumDistanceFrom(tpIndex: Int,
                                     includingStart: Bool) -> Double {
        guard tpIndex >= 0, tpIndex < turnpoints.count else { return 0 }
        let anchor = turnpoints[tpIndex].coordinate
        let remaining = Array(turnpoints.suffix(from: tpIndex + 1))
        if remaining.isEmpty {
            return includingStart ? 0 : 0   // anchor == goal
        }
        // Reuse the bisector algorithm with the anchor as "pilot".
        let pts = optimalRemainingPoints(from: anchor,
                                          overrideRemaining: remaining)
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            total += Self.haversine(pts[i], pts[i + 1])
        }
        return total
    }

    /// Similarly for next TP — return 0 if pilot is already inside the
    /// next TP's cylinder (they've tagged it, the reading shouldn't
    /// jitter while they're still inside it).
    func distanceToNextInCylinder(from pilot: CLLocationCoordinate2D) -> Bool {
        guard let tp = nextTurnpoint(pilot: pilot) else { return false }
        return isInsideCylinder(pilot: pilot, tp: tp)
    }

    // MARK: - Geometry helpers

    /// Great-circle initial bearing from A to B, degrees clockwise from N.
    static func bearing(from a: CLLocationCoordinate2D,
                        to b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let br = atan2(y, x) * 180 / .pi
        return (br + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Great-circle distance between two coordinates in meters.
    ///
    /// Uses `CLLocation.distance(from:)` which is implemented against
    /// the **WGS-84 ellipsoid** — the same datum GPS hardware reports
    /// in, and the same datum every competition scoring system uses
    /// (Flyskyhy, XCTrack, Airtribune, CIVL scoring). This matters at
    /// competition scale: a spherical haversine with R=6371000 drifts
    /// ~0.1–0.3% at mid-latitudes, i.e. 10–30 m over a 10 km leg and
    /// up to 200 m over a 100 km XC task — enough to disagree with
    /// Flyskyhy's numbers on the second decimal of each leg.
    ///
    /// The name "haversine" is kept for source-level compatibility
    /// with the many call sites that predate this change; the function
    /// is now a thin wrapper over CoreLocation.
    static func haversine(_ a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D) -> Double {
        let la = CLLocation(latitude: a.latitude, longitude: a.longitude)
        let lb = CLLocation(latitude: b.latitude, longitude: b.longitude)
        return la.distance(from: lb)
    }

    // MARK: - Persistence

    /// Save this task to disk at a given URL (uses JSON).
    func save(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: url)
    }

    /// Load a task from a given URL.
    static func load(from url: URL) throws -> CompetitionTask {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(CompetitionTask.self, from: data)
    }

    /// Standard location for the active task file.
    static var activeTaskURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("active_task.json")
    }

    func saveAsActive() throws {
        try save(to: Self.activeTaskURL)
    }

    static func loadActive() -> CompetitionTask? {
        try? load(from: activeTaskURL)
    }

    // MARK: - Import from parsed ImportedTask

    /// Replace this task's contents with those from an ImportedTask
    /// (parsed from .xctsk file or QR scan). Sensible defaults applied
    /// where XCTrack data doesn't cover our richer Turnpoint model
    /// (e.g. direction inferred from type).
    func applyImported(_ imported: ImportedTask) {
        name = imported.name
        turnpoints.removeAll()
        for spec in imported.turnpointSpecs {
            let wp = imported.waypoints[spec.waypointIndex]
            var tp = Turnpoint(
                name: wp.name,
                type: spec.type,
                latitude: wp.latitude,
                longitude: wp.longitude,
                altitudeM: wp.altitudeM,
                radiusM: spec.radiusM,
                direction: spec.type.defaultDirection
            )
            // Attach SSS start time to the SSS turnpoint itself so the
            // TurnpointEditor's "Başlangıç Saati" picker shows it.
            if spec.type == .sss, let sssTime = imported.sssStartTime {
                tp.startTime = sssTime
            }
            turnpoints.append(tp)
        }
        // Task-level timing: start window opens at SSS time, deadline = goal deadline
        taskStartTime = imported.sssStartTime
        taskDeadline = imported.taskDeadline
    }
}
