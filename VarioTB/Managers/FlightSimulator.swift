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
    }
    private var phase: Phase = .launch
    private var phaseStartTime: Date = Date()
    private var phaseStartAltitude: Double = 0

    private var simTimer: Timer?
    private let dt: TimeInterval = 0.1

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

    func start() {
        guard !isRunning else { return }
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
        enterPhase(.launch)
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
        lat = Self.launchLat
        lon = Self.launchLon
        altM = Self.launchAltM
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
