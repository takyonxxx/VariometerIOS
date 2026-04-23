import Foundation
import CoreLocation
import Combine

/// Scripted paragliding simulator at Kumludoruk, Ayaş (40.0318°N, 32.3282°E, 1030m).
///
/// Senaryo:
///  - Launch: 10 sn yumuşak sink
///  - 1. Termik: kalkışın 200 m GÜNEYİNDE, 1.5→4.5 m/s'ye çıkar, 2000 m'e kadar
///  - NW süzülüş 1: 500 m yatay mesafe
///  - 2. Termik: 0.8→2.5 m/s, ~400 m tırmanış
///  - NW süzülüş 2: 500 m daha
///  - Toplam 1000 m süzülüş sonunda simülatör OTOMATİK durur
///  - İki thermal VarioManager.thermals listesinde KALIR, radar + haritada görünür
final class FlightSimulator: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var currentPhaseLabel: String = ""

    static let launchLat: Double = 40.0318
    static let launchLon: Double = 32.3282
    static let launchAltM: Double = 1030
    static let glideDirectionDeg: Double = 315       // NW
    static let maxClimbTopM: Double = 1500

    /// How many simulated seconds pass per real second.
    /// 4.0 = 4× fast-forward — the whole scenario fits in ~1.5 min.
    static let timeScale: Double = 4.0

    private var lat: Double = launchLat
    private var lon: Double = launchLon
    private var altM: Double = launchAltM
    private var verticalSpeedMs: Double = 0
    private var horizontalSpeedMs: Double = 10
    private var headingDeg: Double = 0

    private var thermal1Lat: Double = 0
    private var thermal1Lon: Double = 0
    private var thermal2Lat: Double = 0
    private var thermal2Lon: Double = 0

    // Ayaş bölgesinde hakim rüzgar kuzeybatıdan gelir
    private let windFromDeg: Double = 315   // NW
    private let windSpeedMs: Double = 2.8

    private enum Phase: String {
        case launch         = "Kalkış"
        case firstThermal   = "1. Termik (4-5 m/s)"
        case glide1         = "Süzülüş 1 (NW 500m)"
        case secondThermal  = "2. Termik (2-3 m/s)"
        case glide2         = "Süzülüş 2 (NW 500m)"
        case done           = "Tamamlandı"
    }
    private var phase: Phase = .launch
    private var phaseStartTime: Date = Date()
    private var phaseStartAltitude: Double = 0
    private var phaseStartLat: Double = 0
    private var phaseStartLon: Double = 0

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
    }

    func start() {
        guard !isRunning else { return }
        setupScenario()
        locationMgr?.simulatedMode = true
        isRunning = true
        enterPhase(.launch)
        simTimer?.invalidate()
        simTimer = Timer.scheduledTimer(withTimeInterval: dt, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    /// Simulator durur: üretilen tüm SIMULATED thermal'ları siler,
    /// location ve vario değerlerini sıfırlar. Real thermal'lar ve
    /// real-flight geçmişine dokunmaz.
    func stop() {
        isRunning = false
        locationMgr?.simulatedMode = false
        simTimer?.invalidate()
        simTimer = nil
        currentPhaseLabel = ""

        // Clean up: remove simulated thermals from vario, reset live readings
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

    private func setupScenario() {
        lat = Self.launchLat
        lon = Self.launchLon
        altM = Self.launchAltM
        verticalSpeedMs = 0
        horizontalSpeedMs = 10
        headingDeg = 180

        let (t1Lat, t1Lon) = offsetCoordinate(lat: Self.launchLat, lon: Self.launchLon,
                                              bearingDeg: 180, distanceM: 200)
        thermal1Lat = t1Lat
        thermal1Lon = t1Lon

        let (t2Lat, t2Lon) = offsetCoordinate(lat: t1Lat, lon: t1Lon,
                                              bearingDeg: Self.glideDirectionDeg,
                                              distanceM: 500)
        thermal2Lat = t2Lat
        thermal2Lon = t2Lon

        // Senaryo başında eski SIMULATED termikleri temizle — real'ları koru
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
        phaseStartLat = lat
        phaseStartLon = lon
        currentPhaseLabel = p.rawValue
    }

    private func tick() {
        // Accelerated simulation: every real tick represents `timeScale` seconds
        // of simulated time. All physics integration and phase timers use the
        // scaled dt so the whole scenario finishes faster.
        let dt = self.dt * Self.timeScale
        let t = Date().timeIntervalSince(phaseStartTime) * Self.timeScale

        switch phase {
        case .launch:
            verticalSpeedMs = -0.8 + Double.random(in: -0.15...0.15)
            horizontalSpeedMs = 10
            let b = bearingDeg(fromLat: lat, fromLon: lon,
                               toLat: thermal1Lat, toLon: thermal1Lon)
            headingDeg = angularLerp(headingDeg, b, 0.15)
            let d = haversineDistance(lat1: lat, lon1: lon,
                                      lat2: thermal1Lat, lon2: thermal1Lon)
            if d < 60 || t > 25 {
                let startOrbitBearing = normalizeDeg(Self.glideDirectionDeg + 180)
                let (oLat, oLon) = offsetCoordinate(lat: thermal1Lat, lon: thermal1Lon,
                                                    bearingDeg: startOrbitBearing, distanceM: 35)
                lat = oLat
                lon = oLon
                enterPhase(.firstThermal)
            }

        case .firstThermal:
            let rampT = min(1.0, t / 40.0)
            let targetClimb = 1.5 + 3.0 * rampT
            verticalSpeedMs = targetClimb + Double.random(in: -0.35...0.35)
            horizontalSpeedMs = 9

            let turnRate: Double = 20.0
            let curBearingFromCore = bearingDeg(fromLat: thermal1Lat, fromLon: thermal1Lon,
                                                toLat: lat, toLon: lon)
            let newBearing = normalizeDeg(curBearingFromCore + turnRate * dt)
            let (nLat, nLon) = offsetCoordinate(lat: thermal1Lat, lon: thermal1Lon,
                                                bearingDeg: newBearing, distanceM: 35)
            lat = nLat
            lon = nLon
            headingDeg = normalizeDeg(newBearing + 90)

            if t > 5 {
                let vm = varioMgr
                let hasFirstSim = (vm?.thermals.contains { $0.source == .simulated }) ?? false
                if !hasFirstSim {
                    let tp = ThermalPoint(
                        coordinate: CLLocationCoordinate2D(latitude: thermal1Lat, longitude: thermal1Lon),
                        altitude: altM, strength: 4.5,
                        timestamp: Date(),
                        source: .simulated)
                    DispatchQueue.main.async {
                        vm?.thermals.append(tp)
                        vm?.lastThermal = tp
                    }
                }
            }

            if altM >= Self.maxClimbTopM {
                headingDeg = Self.glideDirectionDeg
                enterPhase(.glide1)
            }

        case .glide1:
            verticalSpeedMs = -1.2 + Double.random(in: -0.15...0.15)
            horizontalSpeedMs = 11
            headingDeg = Self.glideDirectionDeg
            let d = haversineDistance(lat1: phaseStartLat, lon1: phaseStartLon,
                                      lat2: lat, lon2: lon)
            if d >= 500 {
                let startOrbit = normalizeDeg(Self.glideDirectionDeg + 180)
                let (oLat, oLon) = offsetCoordinate(lat: thermal2Lat, lon: thermal2Lon,
                                                    bearingDeg: startOrbit, distanceM: 28)
                lat = oLat
                lon = oLon
                enterPhase(.secondThermal)
            }

        case .secondThermal:
            let rampT = min(1.0, t / 20.0)
            let targetClimb = 0.8 + 1.7 * rampT
            verticalSpeedMs = targetClimb + Double.random(in: -0.3...0.3)
            horizontalSpeedMs = 9

            let turnRate: Double = 22.0
            let curBearingFromCore = bearingDeg(fromLat: thermal2Lat, fromLon: thermal2Lon,
                                                toLat: lat, toLon: lon)
            let newBearing = normalizeDeg(curBearingFromCore + turnRate * dt)
            let (nLat, nLon) = offsetCoordinate(lat: thermal2Lat, lon: thermal2Lon,
                                                bearingDeg: newBearing, distanceM: 28)
            lat = nLat
            lon = nLon
            headingDeg = normalizeDeg(newBearing + 90)

            let simThermalCount = (varioMgr?.thermals.filter { $0.source == .simulated }.count) ?? 0
            if t > 5 && simThermalCount < 2 {
                let vm = varioMgr
                let tp = ThermalPoint(
                    coordinate: CLLocationCoordinate2D(latitude: thermal2Lat, longitude: thermal2Lon),
                    altitude: altM, strength: 2.5,
                    timestamp: Date(),
                    source: .simulated)
                DispatchQueue.main.async {
                    vm?.thermals.append(tp)
                    vm?.lastThermal = tp
                }
            }

            let climbedM = altM - phaseStartAltitude
            if climbedM >= 400 || t > 100 {
                headingDeg = Self.glideDirectionDeg
                enterPhase(.glide2)
            }

        case .glide2:
            verticalSpeedMs = -1.2 + Double.random(in: -0.15...0.15)
            horizontalSpeedMs = 11
            headingDeg = Self.glideDirectionDeg
            let d = haversineDistance(lat1: phaseStartLat, lon1: phaseStartLon,
                                      lat2: lat, lon2: lon)
            if d >= 500 {
                enterPhase(.done)
            }

        case .done:
            verticalSpeedMs = 0
            horizontalSpeedMs = 0
            stop()
            return
        }

        altM += verticalSpeedMs * dt
        altM = max(400, min(Self.maxClimbTopM + 50, altM))

        // Only apply wind drift during glides — orbits already position pilot explicitly
        if phase == .launch || phase == .glide1 || phase == .glide2 {
            let headingRad = headingDeg * .pi / 180
            let windToRad = (windFromDeg + 180) * .pi / 180
            let vx = horizontalSpeedMs * sin(headingRad) + windSpeedMs * sin(windToRad)
            let vy = horizontalSpeedMs * cos(headingRad) + windSpeedMs * cos(windToRad)
            let dLat = (vy * dt) / 110_540.0
            let dLon = (vx * dt) / (111_320.0 * cos(lat * .pi / 180))
            lat += dLat
            lon += dLon
        }

        let headingRad = headingDeg * .pi / 180
        let windToRad = (windFromDeg + 180) * .pi / 180
        let vx = horizontalSpeedMs * sin(headingRad) + windSpeedMs * sin(windToRad)
        let vy = horizontalSpeedMs * cos(headingRad) + windSpeedMs * cos(windToRad)
        let groundSpeedKmh = sqrt(vx*vx + vy*vy) * 3.6
        var cogDeg = atan2(vx, vy) * 180 / .pi
        if cogDeg < 0 { cogDeg += 360 }

        let pubLat = lat, pubLon = lon, pubAlt = altM, pubVS = verticalSpeedMs, pubH = headingDeg
        DispatchQueue.main.async {
            guard let lm = self.locationMgr, let vm = self.varioMgr else { return }
            lm.injectSimulatedData(coordinate: CLLocationCoordinate2D(latitude: pubLat, longitude: pubLon),
                                   altitude: pubAlt,
                                   groundSpeedKmh: groundSpeedKmh,
                                   courseDeg: cogDeg,
                                   headingDeg: pubH,
                                   verticalSpeed: pubVS)
            vm.update(rawVerticalSpeed: pubVS,
                      coordinate: CLLocationCoordinate2D(latitude: pubLat, longitude: pubLon),
                      altitude: pubAlt)
        }
    }

    // MARK: - Math helpers

    private func haversineDistance(lat1: Double, lon1: Double,
                                   lat2: Double, lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat/2) * sin(dLat/2) +
                cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) *
                sin(dLon/2) * sin(dLon/2)
        let c = 2 * atan2(sqrt(a), sqrt(1-a))
        return r * c
    }

    private func bearingDeg(fromLat: Double, fromLon: Double,
                            toLat: Double, toLon: Double) -> Double {
        let dLon = (toLon - fromLon) * .pi / 180
        let lat1 = fromLat * .pi / 180
        let lat2 = toLat * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        var b = atan2(y, x) * 180 / .pi
        if b < 0 { b += 360 }
        return b
    }

    private func offsetCoordinate(lat: Double, lon: Double,
                                  bearingDeg: Double, distanceM: Double) -> (Double, Double) {
        let r = 6_371_000.0
        let latRad = lat * .pi / 180
        let lonRad = lon * .pi / 180
        let bRad = bearingDeg * .pi / 180
        let d = distanceM / r
        let newLat = asin(sin(latRad) * cos(d) + cos(latRad) * sin(d) * cos(bRad))
        let newLon = lonRad + atan2(sin(bRad) * sin(d) * cos(latRad),
                                    cos(d) - sin(latRad) * sin(newLat))
        return (newLat * 180 / .pi, newLon * 180 / .pi)
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
