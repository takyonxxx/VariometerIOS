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

    /// Real wall-clock instant captured the moment `start()` was called.
    /// Combined with `Self.timeScale`, this lets the clock card show the
    /// simulated competition time: starting at `taskStartTime` when the
    /// sim begins, and advancing `timeScale` simulated-seconds per real
    /// second so the whole task window plays out at the same compressed
    /// rate as the flight itself. `nil` while the simulator is idle.
    @Published var simStartedAtRealDate: Date? = nil

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

    // Advanced-XC-pilot flight model:
    //   • Average ground speed in cruise ≈ 30 km/h = 8.333 m/s.
    //   • Sustained glide ratio (L/D) = 10:1, so the corresponding
    //     steady sink rate is groundSpeed / glideRatio
    //     = 8.333 / 10 ≈ 0.833 m/s of descent per second.
    // These two numbers drive every gliding phase of the simulator —
    // launch, task legs, the legacy scripted triangle legs, and the
    // final landing approach. Thermal climb phases override
    // horizontalSpeedMs to a slower circling value and use a positive
    // verticalSpeedMs taken from the thermal profile, so they don't
    // use these constants.
    static let xcCruiseGroundSpeedMs: Double = 30.0 / 3.6   // 8.333…
    static let xcGlideRatio: Double = 10.0
    static let xcCruiseSinkMs: Double =
        xcCruiseGroundSpeedMs / xcGlideRatio                // 0.833…

    private var lat: Double = launchLat
    private var lon: Double = launchLon
    private var altM: Double = launchAltM
    private var verticalSpeedMs: Double = 0
    private var horizontalSpeedMs: Double = xcCruiseGroundSpeedMs
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
        /// TP kind — mirrors TurnpointType. Drives the sim path: SSS is
        /// an exit gate (pilot crosses the cylinder boundary OUTWARD to
        /// tag it), turn/ess/goal are entry cylinders (pilot crosses
        /// INWARD). Takeoff is treated as a launch point, no crossing.
        let kind: Kind

        enum Kind { case takeoff, sss, turn, ess, goal }
    }
    /// Distance in meters between two points. Used by the sim for
    /// pilot-position waypoint tracking. Internal helper.
    private func distanceMeters(fromLat: Double, fromLon: Double,
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

    private var taskWaypoints: [TaskWaypoint] = []
    private var taskCurrentIdx: Int = 0
    private var inTaskMode: Bool { !taskWaypoints.isEmpty }
    /// Set to true once the pilot has been verified outside the current
    /// TP's cylinder during this leg. Reach-detection gates on this flag
    /// so concentric laps can't be collapsed into a single frame. Reset
    /// on every `.taskLeg` entry.
    private var legHasExited: Bool = false

    /// Pre-computed polyline the sim flies along — one segment per
    /// action the pilot needs to take to tag every TP in order. Built
    /// once when the task is loaded (see `buildSimPath()`). The sim's
    /// `.taskLeg` phase is now a dead-simple path follower: head to
    /// `simPathPoints[simPathIdx]`, advance when within 50 m, stop
    /// when we run out of points. No tangent re-optimisation at each
    /// step, no thermalling detours — the trajectory is exactly the
    /// line the pilot should see on the map.
    private var simPathPoints: [CLLocationCoordinate2D] = []
    private var simPathIdx: Int = 0

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
    /// Load a task into the simulator. The caller passes both the list
    /// of task waypoints (for metadata — radii, types, altitudes) and
    /// the `routePoints` polyline the sim should physically fly along.
    /// The polyline must be the same one drawn on the map by
    /// `SatelliteMapView.optimalRoutePoints(for:)`: that function has
    /// been updated to emit points already positioned correctly for
    /// reach detection (inside entry cylinders, outside SSS). Passing
    /// the map's points to the sim guarantees a one-to-one match
    /// between the drawn route and the sim's trajectory.
    ///
    /// The first polyline point is the pilot's spawn position. The sim
    /// skips it and begins flying at `routePoints[1]`.
    ///
    /// Pass an empty array to clear task mode.
    func loadTask(_ waypoints: [TaskWaypoint],
                  routePoints: [CLLocationCoordinate2D] = []) {
        self.taskWaypoints = waypoints
        self.taskCurrentIdx = 0
        self.simPathPoints = routePoints
        self.simPathIdx = 0
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
        // Anchor real-time at sim-start. The simulated clock begins at
        // exactly `taskStartTime` and advances `timeScale`× faster than
        // real-time from there. SSS-cross happens whenever the pilot
        // arrives at the SSS gate — its clock value is whatever the
        // simulated time happens to be at that point (e.g. taskStart
        // + a few simulated minutes for the lead-in).
        //
        // Earlier versions tried to back-shift the anchor so SSS-cross
        // landed exactly on `taskStart + 1 s`, but that confused users
        // who saw the clock start in the past (e.g. 12:51 instead of
        // 13:00). Simpler is better: the clock reads the task start
        // time at sim-start, full stop.
        simStartedAtRealDate = Date()
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
        // Route points supplied by the caller are the absolute source
        // of truth for where the sim flies. simPathIdx=1 skips the
        // start point (which is our spawn position).
        simPathIdx = min(1, max(0, simPathPoints.count - 1))
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
        // Drop the simulated-time anchor — the clock card observes this
        // and switches back to real `Date()` once it goes nil.
        simStartedAtRealDate = nil

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

    /// Wall-clock value to display while the simulator is running.
    ///
    /// Returns the wall-clock the simulated competition clock should
    /// display. Two phases:
    ///
    ///   • **Before SSS is reached** (`sssReachedAt == nil`): returns
    ///     `nil` so the caller (ClockCard) falls back to the real
    ///     `Date()`. The pilot is in lead-in flight; no race time has
    ///     started yet, so the clock shows the actual time of day.
    ///   • **After SSS is reached** (`sssReachedAt != nil`): returns
    ///     `taskStartTime + (Date() - sssReachedAt) × timeScale`. The
    ///     clock snaps to `taskStartTime` at the moment SSS was crossed,
    ///     then ticks forward at `timeScale` × real-time so the rest
    ///     of the race plays out compressed.
    ///
    /// Returns `nil` when:
    ///   - the simulator is not running, or
    ///   - the task has no `taskStartTime`, or
    ///   - SSS hasn't been crossed yet (`sssReachedAt == nil`).
    ///
    /// In all `nil` cases the caller renders real wall-clock time.
    func simulatedClockDate(taskStartTime: Date?,
                             sssReachedAt: Date?) -> Date? {
        guard isRunning,
              let start = taskStartTime,
              let sssTime = sssReachedAt else { return nil }
        let elapsedReal = Date().timeIntervalSince(sssTime)
        let elapsedSim = elapsedReal * Self.timeScale
        return start.addingTimeInterval(elapsedSim)
    }

    // MARK: - Scenario setup

    private func setupScenario() {
        // If the user launched simulator with a task loaded, we teleport
        // to the task's TAKEOFF turnpoint instead of the default
        // Kumludoruk coords. Otherwise fall back to the built-in launch.
        if let override = startOverride {
            lat = override.coord.latitude
            lon = override.coord.longitude
            // Task mode: start 1000 m above the takeoff altitude so the
            // pilot has enough height to glide across the first few legs
            // before needing a thermal. The low-altitude guard in
            // `.taskLeg` will fire them into thermal-recovery climbs as
            // they bleed altitude through the task.
            altM = override.altM + 1000
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
        // Reset the "has-exited" gate each time we start a new task leg.
        // See legHasExited docs for why this is needed.
        if p == .taskLeg {
            legHasExited = false
        }
        DispatchQueue.main.async { self.currentPhaseLabel = p.rawValue }
    }

    // MARK: - Step

    private func step() {
        let simDt = dt * Self.timeScale
        let t = Date().timeIntervalSince(phaseStartTime)

        switch phase {
        case .launch:
            // Just-after-takeoff straight glide: same XC cruise model.
            verticalSpeedMs = -Self.xcCruiseSinkMs
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
            headingDeg = bearingTo(lat: Self.tp1Lat, lon: Self.tp1Lon)
            if t >= 2.0 {
                enterPhase(.legToTP1)
            }

        case .legToTP1:
            // Long glide SW to TP1 (~4.8 km) at advanced-XC pace:
            // 30 km/h ground speed, 10:1 glide ratio.
            verticalSpeedMs = -Self.xcCruiseSinkMs
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
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
            // Glide WNW to TP2 (~8.3 km, longest leg) — advanced XC pace.
            verticalSpeedMs = -Self.xcCruiseSinkMs
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
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
            // Glide ESE to TP3 (~5.4 km) — advanced XC pace.
            verticalSpeedMs = -Self.xcCruiseSinkMs
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
            headingDeg = bearingTo(lat: Self.tp3Lat, lon: Self.tp3Lon)
            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: Self.tp3Lat, toLon: Self.tp3Lon)
            if d < 200 {
                lat = Self.tp3Lat
                lon = Self.tp3Lon
                enterPhase(.legBack)
            }

        case .legBack:
            // Very short final glide back to launch (~0.6 km) —
            // same XC cruise model.
            verticalSpeedMs = -Self.xcCruiseSinkMs
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
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
        // taskLeg: follow the pre-computed flight path as a simple
        // polyline. Each `simPathPoints[simPathIdx]` is the next target;
        // when we get within a small tolerance we advance to the next
        // point. No tangent recomputation, no thermal circling, no edge
        // skimming — this produces a clean trajectory that visually
        // overlays the optimum route line on the map. Reach detection
        // is handled entirely by CompetitionTask (which already has the
        // correct exit-then-entry gate for concentric laps).
        case .taskLeg:
            // If the task path has been fully walked, land.
            guard simPathIdx < simPathPoints.count else {
                enterPhase(.taskDone)
                return
            }

            // Low-altitude guard: when the pilot has sunk below 2000 m,
            // pause the leg and climb a thermal back up to 2500 m. This
            // keeps the sim from arriving at goal below ground level on
            // long tasks. Check BEFORE path following so we don't
            // advance the path while climbing.
            if altM < 2000 {
                enterPhase(.taskClimb)
                placeSimulatedThermal(
                    lat: lat, lon: lon,
                    strength: 4.0, altM: altM)
                return
            }

            let target = simPathPoints[simPathIdx]
            // Advanced-XC pilot model: 30 km/h ground speed, 10:1 glide
            // → ~0.83 m/s sink while gliding between turnpoints.
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs
            verticalSpeedMs = -Self.xcCruiseSinkMs

            let d = distanceM(fromLat: lat, fromLon: lon,
                              toLat: target.latitude,
                              toLon: target.longitude)
            headingDeg = bearingTo(lat: target.latitude,
                                    lon: target.longitude)

            // Advance when we're within 10 m of the target polyline
            // point. Tight enough that the sim doesn't push deep into
            // a cylinder before turning for the next leg — route
            // points sit on or very near cylinder edges, so 10 m is
            // plenty of margin to register "reached" while staying
            // within the cylinder boundary.
            if d < 10 {
                simPathIdx += 1
                if simPathIdx >= simPathPoints.count {
                    enterPhase(.taskDone)
                }
            }

        case .taskClimb:
            // Altitude recovery: pilot circles a thermal to regain
            // height. We stay in this phase until we hit 2500 m, then
            // resume task-leg flight where we left off (simPathIdx is
            // untouched). While thermalling we slow down and turn
            // steadily — the rendering layer sees vario > 0 and the
            // audio vario responds, just like in a real climb.
            verticalSpeedMs = 4.0
            horizontalSpeedMs = 3          // slow circling
            headingDeg += 60 * simDt       // ~60°/s = tight thermal turn
            if headingDeg >= 360 { headingDeg -= 360 }
            if altM >= 2500 {
                enterPhase(.taskLeg)
            }

        case .taskDone:
            // Gentle landing approach — pilot bleeds off speed and
            // accepts slightly more sink than cruise. ~70% of cruise
            // speed (~6 m/s) feels right for a final glide; sink stays
            // bounded so the landing is still controlled.
            verticalSpeedMs = -Self.xcCruiseSinkMs * 0.5
            horizontalSpeedMs = Self.xcCruiseGroundSpeedMs * 0.7
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

    /// Bearing from `center` to `point`. Used to pick an outward heading
    /// when the pilot needs to exit a cylinder before re-entering it on
    /// a concentric lap — we push them in the direction they're already
    /// "leaning" so the course change stays smooth.
    private func bearingFromCenter(centerLat: Double, centerLon: Double,
                                    pointLat: Double, pointLon: Double) -> Double {
        let lat1 = centerLat * .pi / 180
        let lat2 = pointLat * .pi / 180
        let dLon = (pointLon - centerLon) * .pi / 180
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
