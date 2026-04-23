import Foundation
import CoreLocation
import Combine

/// Scripted paragliding simulator at Kumludoruk, Ayaş.
///
/// Draws a real FAI triangle based on the 2025-06-06 Ayaş flight log:
///
/// ```
///         TP2 (WNW, 7.7 km)
///         /|
///        / |
///       /  |
///      /   |
///   TP1    |
///   (SW   Launch ---- TP3
///    4.8km)          (E, 0.6 km)
/// ```
///
/// Perimeter 19.2 km, legs 5.6 / 8.3 / 5.4 km — a real FAI-valid triangle
/// flown from Kumludoruk in June 2025.
///
/// FAI validity: min leg / perimeter = 5.4 / 19.2 = 0.281 ≥ 0.28 ✓
/// Closing: 0.6 km ≤ 19.2 × 0.20 = 3.8 km ✓
///
/// Completes in ~120 seconds of real time (timeScale 18×).
final class FlightSimulator: ObservableObject {
    /// Shared instance for App Intents access.
    static weak var shared: FlightSimulator?

    @Published var isRunning: Bool = false
    @Published var currentPhaseLabel: String = ""

    // Launch site: Kumludoruk, Ayaş (from the real IGC)
    static let launchLat: Double = 40.031450
    static let launchLon: Double = 32.328050
    static let launchAltM: Double = 1068

    // Turnpoints from the real Ayaş 2025-06-06 flight
    // TP1: southwest (bearing 250°, 4.8 km) — first thermal, highest climb (2778 m)
    static let tp1Lat: Double = 40.016417
    static let tp1Lon: Double = 32.275100
    static let tp1AltM: Double = 2778

    // TP2: west-northwest (bearing 295°, 7.7 km) — mid climb
    static let tp2Lat: Double = 40.061100
    static let tp2Lon: Double = 32.245950
    static let tp2AltM: Double = 2087

    // TP3: just east of launch (bearing 86°, 0.6 km)
    static let tp3Lat: Double = 40.031783
    static let tp3Lon: Double = 32.335067
    static let tp3AltM: Double = 1219

    // ~19.2 km perimeter at 10 m/s ≈ 1920s of simulated time. 
    // timeScale 18× compresses the whole triangle into ~120 seconds real time.
    static let timeScale: Double = 18.0

    private var lat: Double = launchLat
    private var lon: Double = launchLon
    private var altM: Double = launchAltM
    private var verticalSpeedMs: Double = 0
    private var horizontalSpeedMs: Double = 10
    private var headingDeg: Double = 0

    // Ayaş prevailing wind
    private let windFromDeg: Double = 315   // NW
    private let windSpeedMs: Double = 2.8

    private enum Phase: String {
        case launch      = "Kalkış"
        case legToTP1    = "1. kenar → GB (TP1)"
        case climbAtTP1  = "1. termik (TP1 2778m)"
        case legToTP2    = "2. kenar → BKB (TP2)"
        case climbAtTP2  = "2. termik (TP2 2087m)"
        case legToTP3    = "3. kenar → DKG (TP3)"
        case legBack     = "Kapanış → launch"
        case done        = "Üçgen tamamlandı"

        // Task-mode phases (one leg and optional climb per TP, in sequence)
        case taskLeg     = "Task kenarı"     // flying toward current TP
        case taskClimb   = "Task termik"     // climbing under TP
        case taskDone    = "Task tamamlandı"
    }
    private var phase: Phase = .launch
    private var phaseStartTime: Date = Date()
    private var phaseStartAltitude: Double = 0

    private var simTimer: Timer?
    private let dt: TimeInterval = 0.1

    // MARK: - Task-aware simulation state
    //
    // When the user starts the sim with a CompetitionTask loaded, the
    // scripted Kumludoruk triangle is replaced by a dynamically generated
    // flight plan that visits each task turnpoint in order. The pilot
    // flies straight at each cylinder's center, enters it (reached),
    // optionally climbs a few seconds under that TP, then heads for the
    // next one. When the goal cylinder is reached, the sim lands.
    struct TaskWaypoint {
        let coord: CLLocationCoordinate2D
        let radiusM: Double
        let altM: Double       // target altitude when reaching the TP
        let climbAtTP: Bool    // simulate a thermal climb here before next leg
    }
    private var taskWaypoints: [TaskWaypoint] = []
    private var taskCurrentIdx: Int = 0
    private var inTaskMode: Bool { !taskWaypoints.isEmpty }

    /// Compute the optimal tangent point on waypoint `idx` that the
    /// simulator should fly toward given its current position. Mirrors
    /// CompetitionTask.optimalRemainingPoints but uses the sim's own
    /// lat/lon and the cached taskWaypoints list. Returns the waypoint
    /// center unchanged for the final waypoint (goal — pilot must enter
    /// it, not just touch the edge).
    private func currentOptimalTarget() -> CLLocationCoordinate2D? {
        guard taskCurrentIdx < taskWaypoints.count else { return nil }

        // Pilot is fixed anchor; all remaining TPs up through goal are
        // cylinders we optimise against.
        let pilotXY = (lon * cos(lat * .pi / 180), lat)
        let lonScale = cos(lat * .pi / 180)
        let metersPerDeg = 111_000.0

        // Indexing: path[0] = pilot, path[1..<] = remaining wpts in order.
        // We care about path[1] — the next tangent point we fly toward.
        let remaining = Array(taskWaypoints[taskCurrentIdx..<taskWaypoints.count])
        if remaining.isEmpty { return nil }

        var path: [(x: Double, y: Double)] = [pilotXY]
        var radii: [Double] = [0]
        for wp in remaining {
            path.append((wp.coord.longitude * lonScale, wp.coord.latitude))
            radii.append(wp.radiusM / metersPerDeg)
        }
        let centers = path
        let lastIdx = path.count - 1

        // 6 iterations is enough convergence for typical tasks.
        for _ in 0..<6 {
            var next = path
            for i in 1..<lastIdx {
                let c = centers[i]
                let prev = path[i - 1]
                let after = path[i + 1]
                let v1 = Self.unitVec(dx: prev.x - c.x, dy: prev.y - c.y)
                let v2 = Self.unitVec(dx: after.x - c.x, dy: after.y - c.y)
                var bx = v1.dx + v2.dx
                var by = v1.dy + v2.dy
                let blen = sqrt(bx*bx + by*by)
                if blen < 1e-9 {
                    let dx = after.x - prev.x
                    let dy = after.y - prev.y
                    let perp = Self.unitVec(dx: -dy, dy: dx)
                    bx = perp.dx; by = perp.dy
                } else {
                    bx /= blen; by /= blen
                }
                next[i] = (c.x + bx * radii[i], c.y + by * radii[i])
            }
            path = next
        }

        // The target we're flying toward is path[1]. Back to lat/lon:
        let tangent = path[1]
        return CLLocationCoordinate2D(latitude: tangent.y,
                                        longitude: tangent.x / lonScale)
    }

    private static func unitVec(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        let len = sqrt(dx*dx + dy*dy)
        if len < 1e-12 { return (0, 0) }
        return (dx / len, dy / len)
    }

    weak var locationMgr: LocationManager?
    weak var varioMgr: VarioManager?
    weak var windEstimator: WindEstimator?

    func attach(locationManager: LocationManager,
                varioManager: VarioManager,
                windEstimator: WindEstimator) {
        self.locationMgr = locationManager
        self.varioMgr = varioManager
        self.windEstimator = windEstimator
        FlightSimulator.shared = self
    }

    // MARK: - Lifecycle

    /// Optional override: if set, simulator will start at this coordinate
    /// instead of the hard-coded Kumludoruk launch. Used by "Task Sim"
    /// to teleport the pilot to the task's TAKEOFF turnpoint.
    var startOverride: (coord: CLLocationCoordinate2D, altM: Double)? = nil

    /// Tell the simulator to fly a competition task instead of the
    /// scripted Kumludoruk triangle. Call BEFORE `start()`. The sim will
    /// teleport to the first turnpoint's coordinate, then fly straight
    /// toward each subsequent turnpoint's center, entering its cylinder
    /// (which marks it as reached), optionally thermalling a few seconds,
    /// and moving on — all the way through to goal.
    ///
    /// Pass an empty array to clear task mode and return to the default
    /// triangle scenario.
    func loadTask(_ waypoints: [TaskWaypoint]) {
        self.taskWaypoints = waypoints
        self.taskCurrentIdx = 0
        // If the caller set both startOverride and a task, the task's
        // first waypoint wins (they should match — comp takeoff).
        if let first = waypoints.first {
            self.startOverride = (first.coord, first.altM)
        }
    }

    func start() {
        guard !isRunning else { return }
        // Task-only simulator: if no task waypoints are loaded there's
        // nothing meaningful to simulate. Silently no-op rather than
        // spawning the old scripted Kumludoruk triangle.
        guard !taskWaypoints.isEmpty else { return }

        setupScenario()
        locationMgr?.simulatedMode = true
        isRunning = true
        // Inject initial launch fix BEFORE the timer fires, so the
        // FAI detector's flightStart captures the true launch coordinate.
        locationMgr?.injectSimulatedData(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altM,
            groundSpeedKmh: 0,
            courseDeg: 250,
            headingDeg: 250,
            verticalSpeed: 0
        )
        // Skip the scripted launch phase — the sim starts already
        // airborne and begins flying toward the first remaining TP.
        taskCurrentIdx = 1   // index 0 was the takeoff we spawned at
        if taskCurrentIdx < taskWaypoints.count {
            enterPhase(.taskLeg)
        } else {
            enterPhase(.taskDone)
        }
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] _ in
            self?.step()
        }
    }

    func stop() {
        isRunning = false
        locationMgr?.simulatedMode = false
        simTimer?.invalidate()
        simTimer = nil
        currentPhaseLabel = ""

        let vm = varioMgr
        let lm = locationMgr
        let we = windEstimator
        DispatchQueue.main.async {
            vm?.thermals.removeAll { $0.source == .simulated }
            if let last = vm?.lastThermal, last.source == .simulated {
                vm?.lastThermal = vm?.thermals.last
            }
            lm?.resetForSimulatorStop()
            vm?.resetLive()
            we?.reset()
        }
    }

    // MARK: - Scenario setup

    private func setupScenario() {
        // If the user launched simulator with a task loaded, we teleport
        // to the task's TAKEOFF turnpoint instead of the default
        // Kumludoruk coords. Otherwise fall back to the built-in launch.
        if let override = startOverride {
            lat = override.coord.latitude
            lon = override.coord.longitude
            altM = override.altM
        } else {
            lat = Self.launchLat
            lon = Self.launchLon
            altM = Self.launchAltM
        }
        verticalSpeedMs = 0

        DispatchQueue.main.async {
            self.varioMgr?.thermals.removeAll { $0.source == .simulated }
            if let last = self.varioMgr?.lastThermal, last.source == .simulated {
                self.varioMgr?.lastThermal = self.varioMgr?.thermals.last
            }
        }
    }

    private func enterPhase(_ p: Phase) {
        phase = p
        phaseStartTime = Date()
        phaseStartAltitude = altM
        DispatchQueue.main.async { self.currentPhaseLabel = p.rawValue }
    }

    // MARK: - Step

    private func step() {
        let simDt = dt * Self.timeScale
        let t = Date().timeIntervalSince(phaseStartTime)

        switch phase {
        case .launch:
            verticalSpeedMs = -0.6
            horizontalSpeedMs = 10
            headingDeg = bearingTo(lat: Self.tp1Lat, lon: Self.tp1Lon)
            if t >= 2.0 {
                enterPhase(.legToTP1)
            }

        case .legToTP1:
            // Long glide SW to TP1 (~4.8 km)
            verticalSpeedMs = -0.8
            horizontalSpeedMs = 10
            headingDeg = bearingTo(lat: Self.tp1Lat, lon: Self.tp1Lon)
            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: Self.tp1Lat, toLon: Self.tp1Lon)
            if d < 200 {
                lat = Self.tp1Lat
                lon = Self.tp1Lon
                enterPhase(.climbAtTP1)
                placeSimulatedThermal(lat: Self.tp1Lat, lon: Self.tp1Lon,
                                      strength: 4.5, altM: altM)
            }

        case .climbAtTP1:
            // Biggest climb of the flight — from 1068 to 2778 m = 1710 m gain.
            // We only need to gain enough to glide onward (~800 m).
            verticalSpeedMs = 4.5
            horizontalSpeedMs = 4
            headingDeg += 40 * simDt
            if headingDeg >= 360 { headingDeg -= 360 }
            if altM - phaseStartAltitude >= 800 || t > 8.0 {
                enterPhase(.legToTP2)
            }

        case .legToTP2:
            // Glide WNW to TP2 (~8.3 km, longest leg)
            verticalSpeedMs = -0.9
            horizontalSpeedMs = 10
            headingDeg = bearingTo(lat: Self.tp2Lat, lon: Self.tp2Lon)
            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: Self.tp2Lat, toLon: Self.tp2Lon)
            if d < 200 {
                lat = Self.tp2Lat
                lon = Self.tp2Lon
                enterPhase(.climbAtTP2)
                placeSimulatedThermal(lat: Self.tp2Lat, lon: Self.tp2Lon,
                                      strength: 2.8, altM: altM)
            }

        case .climbAtTP2:
            verticalSpeedMs = 2.8
            horizontalSpeedMs = 4
            headingDeg += 40 * simDt
            if headingDeg >= 360 { headingDeg -= 360 }
            if altM - phaseStartAltitude >= 400 || t > 5.0 {
                enterPhase(.legToTP3)
            }

        case .legToTP3:
            // Glide ESE to TP3 (~5.4 km)
            verticalSpeedMs = -0.9
            horizontalSpeedMs = 10
            headingDeg = bearingTo(lat: Self.tp3Lat, lon: Self.tp3Lon)
            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: Self.tp3Lat, toLon: Self.tp3Lon)
            if d < 200 {
                lat = Self.tp3Lat
                lon = Self.tp3Lon
                enterPhase(.legBack)
            }

        case .legBack:
            // Very short final glide back to launch (~0.6 km)
            verticalSpeedMs = -0.5
            horizontalSpeedMs = 10
            headingDeg = bearingTo(lat: Self.launchLat, lon: Self.launchLon)
            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: Self.launchLat, toLon: Self.launchLon)
            if d < 80 {
                lat = Self.launchLat
                lon = Self.launchLon
                enterPhase(.done)
            }

        case .done:
            if t >= 2.0 {
                stop()
            }
            return

        // MARK: Task-aware phases
        //
        // taskLeg: fly straight toward taskWaypoints[taskCurrentIdx].
        // When we get within (radius + small margin), mark "reached" by
        // actually snapping inside the cylinder, then either climb
        // briefly or advance to the next TP. At the end we stop.
        case .taskLeg:
            guard taskCurrentIdx < taskWaypoints.count else {
                enterPhase(.taskDone)
                return
            }
            let target = taskWaypoints[taskCurrentIdx]
            horizontalSpeedMs = 10
            // Sink a little while gliding, gain a little while above TP
            // altitude (keeps sim-altitude bounded around each TP's altM).
            if altM < target.altM - 50 {
                verticalSpeedMs = 0.8   // climbing to TP altitude
            } else if altM > target.altM + 200 {
                verticalSpeedMs = -1.0  // descending to TP altitude
            } else {
                verticalSpeedMs = -0.5
            }
            // Fly toward the OPTIMAL TANGENT POINT on this cylinder so
            // the trajectory matches the blue optimum-route overlay on
            // the map. Tangent is recomputed each step (6 bisector
            // iterations) from the current pilot position and remaining
            // cylinders, so the heading naturally curves through each
            // leg the way a racing pilot flies.
            //
            // To guarantee the pilot physically enters the cylinder
            // (reach detection needs an interior fix), we only switch to
            // center-steering when the pilot is within a small buffer of
            // the tangent POINT itself — not the center. This keeps the
            // trajectory glued to the optimum line until the last moment.
            let dCenter = distanceM(fromLat: lat, fromLon: lon,
                                    toLat: target.coord.latitude,
                                    toLon: target.coord.longitude)
            let tangent = currentOptimalTarget() ?? target.coord
            let dTangent = distanceM(fromLat: lat, fromLon: lon,
                                     toLat: tangent.latitude,
                                     toLon: tangent.longitude)
            // Switch to center-steering only when pilot is <80m from
            // the tangent crossing point. This is close enough that the
            // deflection into the cylinder is a gentle course change,
            // and well before the old "1.2 × radius" cut-off that pulled
            // the trajectory away from the optimum line.
            let steerTarget: CLLocationCoordinate2D
            if dTangent < 80 {
                steerTarget = target.coord
            } else {
                steerTarget = tangent
            }
            headingDeg = bearingTo(lat: steerTarget.latitude,
                                    lon: steerTarget.longitude)
            let d = dCenter
            // Reach: pilot is inside the cylinder. Use a tiny negative
            // margin (5m) so we commit the reach only AFTER the pilot has
            // clearly crossed the boundary, not just grazing the edge.
            if d < target.radiusM - 5 {
                if target.climbAtTP {
                    enterPhase(.taskClimb)
                    placeSimulatedThermal(lat: target.coord.latitude,
                                           lon: target.coord.longitude,
                                           strength: 3.5,
                                           altM: altM)
                } else {
                    // Advance to next TP immediately
                    taskCurrentIdx += 1
                    if taskCurrentIdx < taskWaypoints.count {
                        enterPhase(.taskLeg)
                    } else {
                        enterPhase(.taskDone)
                    }
                }
            }

        case .taskClimb:
            // Short thermal at each interior TP — gain ~400m then move on.
            // Gives realism (pilots don't fly dead-straight; they climb
            // at each TP) and tests the app's thermal detection path.
            verticalSpeedMs = 3.8
            horizontalSpeedMs = 4
            headingDeg += 40 * simDt
            if headingDeg >= 360 { headingDeg -= 360 }
            if altM - phaseStartAltitude >= 400 || t > 5.0 {
                taskCurrentIdx += 1
                if taskCurrentIdx < taskWaypoints.count {
                    enterPhase(.taskLeg)
                } else {
                    enterPhase(.taskDone)
                }
            }

        case .taskDone:
            // Land gently — level flight for 2s then stop.
            verticalSpeedMs = -0.4
            horizontalSpeedMs = 6
            if t >= 2.0 {
                stop()
            }
            return
        }

        // Advance position
        let headingRad = headingDeg * .pi / 180
        let windToRad = (windFromDeg + 180) * .pi / 180
        let vx = horizontalSpeedMs * sin(headingRad) + windSpeedMs * sin(windToRad)
        let vy = horizontalSpeedMs * cos(headingRad) + windSpeedMs * cos(windToRad)

        let metersPerDegLat = 111_000.0
        let metersPerDegLon = 111_000.0 * cos(Self.launchLat * .pi / 180)
        lat += (vy * simDt) / metersPerDegLat
        lon += (vx * simDt) / metersPerDegLon
        altM += verticalSpeedMs * simDt

        let course = atan2(vx, vy) * 180 / .pi
        let courseNorm = course < 0 ? course + 360 : course
        let groundSpeedKmh = sqrt(vx*vx + vy*vy) * 3.6

        locationMgr?.injectSimulatedData(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altM,
            groundSpeedKmh: groundSpeedKmh,
            courseDeg: courseNorm,
            headingDeg: headingDeg,
            verticalSpeed: verticalSpeedMs
        )
    }

    // MARK: - Thermal placement

    private func placeSimulatedThermal(lat: Double, lon: Double,
                                       strength: Double, altM: Double) {
        let tp = ThermalPoint(
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            altitude: altM,
            strength: strength,
            timestamp: Date(),
            source: .simulated)
        let vm = varioMgr
        DispatchQueue.main.async {
            vm?.thermals.append(tp)
            vm?.lastThermal = tp
        }
    }

    // MARK: - Geometry helpers

    private func bearingTo(lat toLat: Double, lon toLon: Double) -> Double {
        let lat1 = lat * .pi / 180
        let lat2 = toLat * .pi / 180
        let dLon = (toLon - lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let b = atan2(y, x) * 180 / .pi
        return b < 0 ? b + 360 : b
    }

    private func distanceM(fromLat: Double, fromLon: Double,
                           toLat: Double, toLon: Double) -> Double {
        let R = 6371000.0
        let phi1 = fromLat * .pi / 180
        let phi2 = toLat * .pi / 180
        let dPhi = (toLat - fromLat) * .pi / 180
        let dLam = (toLon - fromLon) * .pi / 180
        let sa = sin(dPhi/2)
        let sb = sin(dLam/2)
        let h = sa*sa + cos(phi1)*cos(phi2)*sb*sb
        return 2 * R * asin(min(1, sqrt(h)))
    }
}
