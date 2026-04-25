import Foundation
import CoreLocation
import Combine

final class VarioManager: ObservableObject {
    @Published var filteredVario: Double = 0     // m/s after damper
    @Published var avgVario30s: Double = 0       // 30 sec rolling average
    @Published var maxClimb: Double = 0
    @Published var minSink: Double = 0
    @Published var thermals: [ThermalPoint] = []
    @Published var lastThermal: ThermalPoint?

    private let settings: AppSettings
    private var rawSamples: [(t: TimeInterval, v: Double)] = []
    private weak var locationMgr: LocationManager?
    private var lastAppliedDamper: Int = 0

    // Thermal detection state
    private var climbStreakStart: Date?
    private var climbStreakSum: Double = 0
    private var climbStreakCount: Int = 0
    private var climbStreakCoord: CLLocationCoordinate2D?
    private var climbStreakAlt: Double = 0
    // Vario-weighted coordinate accumulators for thermal core estimation.
    // The core of a thermal is approximated as the centroid of all
    // (lat, lon) samples weighted by climb rate: stronger lift means
    // the pilot is closer to the core, so those points pull the
    // marker toward the true center instead of just the entry point.
    private var climbWeightedLatSum: Double = 0
    private var climbWeightedLonSum: Double = 0
    private var climbWeightTotal: Double = 0

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Called once by ContentView to wire up the vario to the location manager.
    func attachLocationManager(_ lm: LocationManager) {
        self.locationMgr = lm
        applyDamperToLocation()
    }

    /// Map damper level 1..10 to regression window in seconds.
    /// 1 = 0.20s (near-instant, very noisy), 10 = 1.8s (very smooth, slow).
    private func windowForDamper(_ d: Int) -> Double {
        let clamped = max(1, min(10, d))
        // Exponential-ish mapping: 1→0.20, 2→0.30, 3→0.45, 5→0.75, 7→1.15, 10→1.8
        return 0.20 * pow(1.265, Double(clamped - 1))
    }

    private func applyDamperToLocation() {
        let d = settings.damperLevel
        locationMgr?.setWindowSeconds(windowForDamper(d))
        lastAppliedDamper = d
    }

    /// Main tick — called ~10Hz from ContentView.
    func update(rawVerticalSpeed: Double,
                coordinate: CLLocationCoordinate2D?,
                altitude: Double) {
        // Re-apply window if user changed damper in settings
        if settings.damperLevel != lastAppliedDamper {
            applyDamperToLocation()
        }

        // Since the regression window already does the heavy smoothing,
        // the EWMA here stays nearly transparent at damper 1 and adds only
        // a very light extra smoothing at higher levels.
        let d = Double(settings.damperLevel.clamped(to: 1...10))
        let alpha: Double
        if d <= 1.0 {
            alpha = 1.0                          // pure pass-through
        } else {
            // Much less aggressive than before — window does the real filtering.
            // 2→0.85, 3→0.70, 5→0.55, 10→0.40
            alpha = max(0.40, 1.0 - (d - 1) * 0.06)
        }
        filteredVario = alpha * rawVerticalSpeed + (1 - alpha) * filteredVario

        // Rolling 30s avg
        let now = Date().timeIntervalSince1970
        rawSamples.append((now, filteredVario))
        rawSamples.removeAll { now - $0.t > 30 }
        if !rawSamples.isEmpty {
            avgVario30s = rawSamples.reduce(0) { $0 + $1.v } / Double(rawSamples.count)
        }

        if filteredVario > maxClimb { maxClimb = filteredVario }
        if filteredVario < minSink { minSink = filteredVario }

        // Thermal detection
        detectThermal(coordinate: coordinate, altitude: altitude)
    }

    private func detectThermal(coordinate: CLLocationCoordinate2D?, altitude: Double) {
        // If simulator is running, don't create real-detected thermals — the
        // simulator is driving the vertical speed and will place its own
        // simulated thermals explicitly.
        if locationMgr?.simulatedMode == true { return }

        let climbing = filteredVario >= 0.5
        if climbing {
            if climbStreakStart == nil {
                climbStreakStart = Date()
                climbStreakSum = 0
                climbStreakCount = 0
                climbStreakCoord = coordinate
                climbStreakAlt = altitude
                climbWeightedLatSum = 0
                climbWeightedLonSum = 0
                climbWeightTotal = 0
            }
            climbStreakSum += filteredVario
            climbStreakCount += 1
            // Vario-weighted centroid: each location sample contributes
            // proportionally to its climb rate. A linear weight on
            // filteredVario already discounts weak lift on the edges
            // and emphasises the core where vario peaks.
            if let c = coordinate {
                let w = max(0, filteredVario)
                climbWeightedLatSum += c.latitude * w
                climbWeightedLonSum += c.longitude * w
                climbWeightTotal += w
            }
        } else {
            if let start = climbStreakStart,
               Date().timeIntervalSince(start) >= 6.0,
               climbStreakCount > 0,
               let entryCoord = climbStreakCoord {
                let avg = climbStreakSum / Double(climbStreakCount)
                // Use weighted centroid when we accumulated enough lift,
                // otherwise fall back to the entry coordinate (avoids
                // divide-by-near-zero on marginal climbs).
                let coreCoord: CLLocationCoordinate2D
                if climbWeightTotal > 0.001 {
                    coreCoord = CLLocationCoordinate2D(
                        latitude: climbWeightedLatSum / climbWeightTotal,
                        longitude: climbWeightedLonSum / climbWeightTotal)
                } else {
                    coreCoord = entryCoord
                }
                let t = ThermalPoint(coordinate: coreCoord,
                                     altitude: climbStreakAlt,
                                     strength: avg,
                                     timestamp: start)
                thermals.append(t)
                lastThermal = t
                // Keep only last 20
                if thermals.count > 20 {
                    thermals.removeFirst(thermals.count - 20)
                }
            }
            climbStreakStart = nil
            climbStreakSum = 0
            climbStreakCount = 0
            climbWeightedLatSum = 0
            climbWeightedLonSum = 0
            climbWeightTotal = 0
        }
    }

    func resetSession() {
        maxClimb = 0
        minSink = 0
        thermals.removeAll()
        lastThermal = nil
        rawSamples.removeAll()
    }

    /// Called when simulator stops — reset live vario readings (but NOT the
    /// thermal list; that's managed by the simulator itself which keeps
    /// real-flight thermals and removes simulated ones).
    func resetLive() {
        filteredVario = 0
        avgVario30s = 0
        rawSamples.removeAll()
        // reset thermal detection state
        climbStreakStart = nil
        climbStreakSum = 0
        climbStreakCount = 0
        climbWeightedLatSum = 0
        climbWeightedLonSum = 0
        climbWeightTotal = 0
    }
}

extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self {
        min(max(self, r.lowerBound), r.upperBound)
    }
}
