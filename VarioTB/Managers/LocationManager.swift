import Foundation
import CoreLocation
import CoreMotion
import Combine

final class LocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    // Public published state
    @Published var coordinate: CLLocationCoordinate2D?
    @Published var gpsAltitude: Double = 0          // m (ellipsoidal from GPS)
    @Published var baroAltitude: Double = 0         // m (relative from barometer)
    @Published var fusedAltitude: Double = 0        // m (preferred for display)
    @Published var groundSpeedKmh: Double = 0       // km/h
    @Published var courseDeg: Double = 0            // ° true (course over ground)
    @Published var headingDeg: Double = 0           // ° magnetic heading
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

    override init() {
        super.init()
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
        coordinate = loc.coordinate
        gpsAltitude = loc.altitude
        horizontalAccuracy = loc.horizontalAccuracy
        groundSpeedKmh = max(0, loc.speed) * 3.6
        if loc.course >= 0 { courseDeg = loc.course }
        hasFix = loc.horizontalAccuracy > 0 && loc.horizontalAccuracy < 50
        updateFusedAltitude()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        if newHeading.trueHeading >= 0 {
            headingDeg = newHeading.trueHeading
        } else {
            headingDeg = newHeading.magneticHeading
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Ignore; transient
    }
}
