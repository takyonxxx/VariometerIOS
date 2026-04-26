import Foundation
import CoreLocation
import CoreMotion
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// Shared instance for App Intents.
    static weak var shared: LocationManager?

    // Public published state
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var gpsAltitude: Double = 0          // m (ellipsoidal from GPS)
    @Published var baroAltitude: Double = 0         // m (relative from barometer)
    @Published var fusedAltitude: Double = 0        // m (preferred for display)
    /// Highest fusedAltitude observed since this session began (or
    /// since the last reset). Updated monotonically — never decreases
    /// while the app is running. Reset by `resetForSimulatorStop()`
    /// and on a fresh launch (since this is not persisted). Used by
    /// the Max Altitude card.
    @Published var maxAltitude: Double = 0
    @Published var groundSpeedKmh: Double = 0       // km/h
    @Published var courseDeg: Double = 0            // ° true (course over ground)
    /// Raw GPS course-over-ground, independent of the compass selection
    /// logic. Always tracks `CLLocation.course` when available (and
    /// speed is high enough to have a meaningful track). Used by the
    /// WindEstimator, which needs the pilot's actual direction of
    /// travel (dairesel track while thermalling) — if we gave it the
    /// compass-backed `courseDeg`, wind couldn't be computed because
    /// a stationary phone in a harness keeps the compass fixed even
    /// as the pilot circles a thermal.
    ///
    /// -1 when no valid GPS track is available yet.
    @Published var gpsCourseDeg: Double = -1
    @Published var headingDeg: Double = 0            // ° magnetic heading from compass
    /// Compass accuracy in degrees. Negative = compass data invalid
    /// (compass disabled, uncalibrated, or hardware unavailable).
    /// Positive values smaller = better. We treat anything > 0 and
    /// ≤ 30° as "trustworthy" for the bestHeadingDeg selector.
    @Published var headingAccuracyDeg: Double = -1

    /// Speed threshold (m/s) below which GPS course is considered
    /// unreliable. Below this we fall back to the magnetometer.
    /// 1 m/s ≈ 3.6 km/h — well below normal paraglider trim speed
    /// (~30 km/h), so in actual flight we're always above the
    /// threshold and the GPS path dominates. Symmetric with the
    /// gpsCourseDeg gate in didUpdateLocations and the WindEstimator
    /// gate downstream, so all three sources of "is the pilot really
    /// moving?" agree.
    private static let gpsHeadingMinSpeedMps: Double = 1.0

    /// Preferred heading for UI and navigation. Picks the most
    /// physically meaningful source for the current flight state:
    ///
    ///   - GPS course-over-ground (PRIMARY): the direction the pilot
    ///     is actually MOVING, which is what every certified flight
    ///     instrument (XCTrack, Skytraxx, Naviter, Flymaster, Syride)
    ///     uses. Independent of how the phone happens to be oriented
    ///     in the harness, pocket, or kneeboard. Used whenever GPS
    ///     fix is good and the pilot is moving above the speed
    ///     threshold.
    ///   - Magnetic compass (FALLBACK): used while stationary or in
    ///     very slow flight when GPS course is too noisy to be
    ///     meaningful. Also forced as the primary source in
    ///     simulator mode so the pilot can rotate the phone to
    ///     verify the dial behaviour by hand. Compass is gated by
    ///     headingAccuracyDeg ≤ 30° to reject uncalibrated readings.
    ///
    /// gpsCourseDeg is updated independently in didUpdateLocations so
    /// the WindEstimator always sees the raw circular track when the
    /// pilot is thermalling, regardless of which source this selector
    /// picks for the UI.
    var bestHeadingDeg: Double {
        // Sim mode: keep the manual-rotation test path alive so the
        // pilot can sanity-check the dial by physically turning the
        // phone, even though the simulator is feeding pretend speeds.
        if simulatedMode {
            if headingAccuracyDeg > 0 && headingAccuracyDeg <= 30 {
                return headingDeg
            }
            return courseDeg
        }
        // Real flight: GPS course wins as long as it's valid AND the
        // pilot is moving fast enough for the track vector to be
        // physically meaningful.
        if gpsCourseDeg >= 0 && groundSpeedKmh / 3.6 >= Self.gpsHeadingMinSpeedMps {
            return gpsCourseDeg
        }
        // Slow / stationary: fall back to the compass if calibrated.
        if headingAccuracyDeg > 0 && headingAccuracyDeg <= 30 {
            return headingDeg
        }
        // Last resort — return whatever we have. courseDeg holds the
        // most recently chosen source from didUpdateLocations and
        // didUpdateHeading, smoothed.
        return courseDeg
    }
    @Published var horizontalAccuracy: Double = -1  // m
    @Published var verticalSpeed: Double = 0        // m/s (raw, unfiltered)
    @Published var hasFix: Bool = false
    @Published var isAuthorized: Bool = false

    private let manager = CLLocationManager()
    private let altimeter = CMAltimeter()
    private let motionQueue = OperationQueue()

    private var lastAltitudeSample: (t: TimeInterval, alt: Double)?
    private var altWindow: [(t: TimeInterval, alt: Double)] = []
    private var windowSec: Double = 0.25   // default; VarioManager will override
    private var baroBaselineSet = false

    /// When true, all real GPS / barometer data is ignored. Used by FlightSimulator.
    var simulatedMode: Bool = false

    override init() {
        super.init()
        LocationManager.shared = self
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .airborne
        manager.headingFilter = 1
        manager.pausesLocationUpdatesAutomatically = false
        manager.allowsBackgroundLocationUpdates = false
    }

    func start() {
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
        manager.startUpdatingHeading()
        startBarometer()
    }

    private func startBarometer() {
        guard CMAltimeter.isRelativeAltitudeAvailable() else { return }
        altimeter.startRelativeAltitudeUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self = self, let data = data else { return }
            let relAlt = data.relativeAltitude.doubleValue
            DispatchQueue.main.async {
                guard !self.simulatedMode else { return }
                self.baroAltitude = relAlt
                self.computeVerticalSpeed()
                self.updateFusedAltitude()
            }
        }
    }

    private func updateFusedAltitude() {
        // Baseline barometer to first GPS altitude so baroAltitude reads absolute-ish
        if !baroBaselineSet, hasFix, gpsAltitude != 0 {
            baroBaselineSet = true
        }
        // If barometer available, fused = gpsBaseline + baroDelta (stable & high rate)
        if CMAltimeter.isRelativeAltitudeAvailable() {
            fusedAltitude = gpsAltitude + baroAltitude * 0.0 + baroAltitude
            // Note: baroAltitude is relative (delta from start). Simple fusion:
            // Use GPS for absolute reference, barometer for fast deltas.
            // Reset logic: if GPS drifts strongly, renormalize. Simple version below.
        } else {
            fusedAltitude = gpsAltitude
        }
        // Track the session's peak altitude. Only bump when we actually
        // have a fix — without one, fusedAltitude can flap around 0 and
        // maxAltitude would lock at the first noise spike.
        if hasFix && fusedAltitude > maxAltitude {
            maxAltitude = fusedAltitude
        }
    }

    private func computeVerticalSpeed() {
        // Short-window linear regression. Window size is controlled by damper level
        // via setWindowSeconds(). Damper 1 = tiny window (~0.25s = very fast response).
        let now = Date().timeIntervalSince1970
        altWindow.append((now, baroAltitude))
        altWindow.removeAll { now - $0.t > windowSec }
        guard altWindow.count >= 3 else {
            // Fall back to simple diff until we have a window
            if let last = lastAltitudeSample {
                let dt = now - last.t
                if dt > 0.01 {
                    verticalSpeed = (baroAltitude - last.alt) / dt
                }
            }
            lastAltitudeSample = (now, baroAltitude)
            return
        }
        // Least-squares slope
        let n = Double(altWindow.count)
        var sumT = 0.0, sumA = 0.0, sumTT = 0.0, sumTA = 0.0
        let t0 = altWindow.first!.t
        for s in altWindow {
            let t = s.t - t0
            sumT += t
            sumA += s.alt
            sumTT += t * t
            sumTA += t * s.alt
        }
        let denom = n * sumTT - sumT * sumT
        if abs(denom) > 1e-6 {
            verticalSpeed = (n * sumTA - sumT * sumA) / denom
        }
        lastAltitudeSample = (now, baroAltitude)
    }

    /// Set the regression window length in seconds. Smaller = faster response + more noise.
    /// Called by VarioManager based on damper level.
    func setWindowSeconds(_ seconds: Double) {
        windowSec = max(0.15, min(2.0, seconds))
    }

    // MARK: - CLLocationManagerDelegate

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        isAuthorized = (status == .authorizedWhenInUse || status == .authorizedAlways)
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        // While the sim is running, coordinate / altitude / speed come
        // from the simulator's inject call — we don't let real GPS
        // overwrite them.
        if !simulatedMode {
            coordinate = loc.coordinate
            gpsAltitude = loc.altitude
            horizontalAccuracy = loc.horizontalAccuracy
            groundSpeedKmh = max(0, loc.speed) * 3.6
            hasFix = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < 50
            updateFusedAltitude()
        }
        // GPS course is ONLY used as a courseDeg fallback when the
        // device has no usable compass (no magnetometer hardware, or
        // the compass is uncalibrated → headingAccuracyDeg < 0 or
        // > 30°). Normally both courseDeg and headingDeg track the
        // compass — see didUpdateHeading.
        if loc.course >= 0,
           !(headingAccuracyDeg > 0 && headingAccuracyDeg <= 30) {
            courseDeg = Self.smoothAngle(current: courseDeg, target: loc.course, alpha: 0.2)
        }
        // gpsCourseDeg is ALWAYS updated from the raw GPS track
        // (when valid and the pilot is moving fast enough for the
        // track to be meaningful). This bypasses the compass logic
        // above so WindEstimator can see the circular track a pilot
        // makes when thermalling, even if the phone's compass stays
        // pointed the same way in the harness the whole time.
        if loc.course >= 0, loc.speed > 1.0 {
            if gpsCourseDeg < 0 {
                gpsCourseDeg = loc.course
            } else {
                gpsCourseDeg = Self.smoothAngle(current: gpsCourseDeg,
                                                 target: loc.course,
                                                 alpha: 0.3)
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        // Compass is the primary source for BOTH the pilot's heading
        // AND their course — the pilot explicitly asked for direction
        // values to always come from the device sensor (compass),
        // never the GPS, so they can rotate the phone to align the
        // direction arrow. GPS course is only consulted as a fallback
        // in didUpdateLocations when the compass isn't usable.
        let raw = newHeading.trueHeading >= 0
            ? newHeading.trueHeading
            : newHeading.magneticHeading
        // Low-pass filter: raw compass jitters by several degrees even
        // on a stationary phone. alpha = 0.15 → ~300 ms time constant
        // at the compass's ~10 Hz update rate. Fast enough to track
        // deliberate rotation, slow enough to suppress noise.
        let smoothed = Self.smoothAngle(current: headingDeg, target: raw, alpha: 0.15)
        headingDeg = smoothed
        courseDeg = smoothed
        headingAccuracyDeg = newHeading.headingAccuracy
    }

    /// Low-pass filter a bearing-style angle (0..360°). Handles the
    /// wrap-around at 360→0 correctly — without this, a jump from 359°
    /// to 1° would be filtered as a swing through 180° instead of 2°.
    /// `alpha` ∈ (0, 1]: closer to 1 = snappier, closer to 0 = smoother.
    private static func smoothAngle(current: Double,
                                     target: Double,
                                     alpha: Double) -> Double {
        // Shortest-path delta in (-180, 180]
        var delta = target - current
        while delta > 180 { delta -= 360 }
        while delta <= -180 { delta += 360 }
        var result = current + delta * alpha
        // Wrap back into [0, 360)
        while result < 0 { result += 360 }
        while result >= 360 { result -= 360 }
        return result
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore; transient
    }

    /// Called by FlightSimulator to push simulated values into the normal flow.
    func injectSimulatedData(coordinate: CLLocationCoordinate2D,
                             altitude: Double,
                             groundSpeedKmh: Double,
                             courseDeg: Double,
                             headingDeg: Double,
                             verticalSpeed: Double) {
        self.coordinate = coordinate
        self.gpsAltitude = altitude
        self.baroAltitude = altitude
        self.fusedAltitude = altitude
        // Track sim-mode peak altitude same as real flight.
        if altitude > self.maxAltitude {
            self.maxAltitude = altitude
        }
        self.groundSpeedKmh = groundSpeedKmh
        // NOTE: courseDeg and headingDeg are deliberately NOT written
        // here. Both values continue to come from the real device
        // sensors (GPS course-over-ground when the phone moves, compass
        // heading from the magnetometer) even while the sim is running.
        // This is intentional — the user wants to be able to rotate the
        // physical phone and have the direction arrow respond, exactly
        // as it would in a real flight. The synthetic course/heading
        // the sim would otherwise inject are discarded.
        _ = headingDeg
        // gpsCourseDeg IS populated from sim data — the WindEstimator
        // needs a circular ground track to compute wind while the
        // pilot thermals, and during sim the only source of that track
        // is the simulator's synthesized course. UI direction values
        // (courseDeg / bestHeadingDeg) continue to come from the
        // real compass.
        self.gpsCourseDeg = courseDeg
        self.verticalSpeed = verticalSpeed
        self.horizontalAccuracy = 3.0
        self.hasFix = true
    }

    /// Simulator stopped — reset to "no data" state so the screen clearly shows
    /// the app is waiting for real sensor/GPS values (which will populate again
    /// as real updates arrive).
    func resetForSimulatorStop() {
        coordinate = nil
        gpsAltitude = 0
        baroAltitude = 0
        fusedAltitude = 0
        maxAltitude = 0
        groundSpeedKmh = 0
        courseDeg = 0
        gpsCourseDeg = -1
        verticalSpeed = 0
        horizontalAccuracy = -1
        hasFix = false
        // Clear altitude window so vario regression starts fresh
        altWindow.removeAll()
        lastAltitudeSample = nil
    }
}
