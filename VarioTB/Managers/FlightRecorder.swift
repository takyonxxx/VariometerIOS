import Foundation
import CoreLocation
import Combine
import UIKit

/// Coordinates flight recording (IGC + waypoints).
///
/// Handles both:
/// - REAL flights: auto-starts when GPS fix + movement detected
/// - SIMULATED flights: starts when the FlightSimulator starts, filename
///   tagged with "_SIM" so you can tell them apart and delete them later
///
/// Files land in Documents/Flights/*.igc and Documents/Waypoints/*.cup .
final class FlightRecorder: ObservableObject {
    @Published var isRecording: Bool = false
    @Published var currentIGCURL: URL?
    @Published var lastExportedWaypointURL: URL?

    private var igc = IGCRecorder()
    private var fixTimer: Timer?
    private let fixInterval: TimeInterval = 1.0

    private var isSimulatedFlight: Bool = false
    private var simulatorSubs: Set<AnyCancellable> = []

    weak var locationMgr: LocationManager?
    weak var varioMgr: VarioManager?
    weak var simulator: FlightSimulator?
    weak var settings: AppSettings?

    func attach(locationManager: LocationManager,
                varioManager: VarioManager,
                simulator: FlightSimulator,
                settings: AppSettings) {
        self.locationMgr = locationManager
        self.varioMgr = varioManager
        self.simulator = simulator
        self.settings = settings

        // Observe simulator isRunning changes — start/stop recording accordingly
        simulator.$isRunning
            .removeDuplicates()
            .sink { [weak self] running in
                self?.handleSimulatorChange(running: running)
            }
            .store(in: &simulatorSubs)
    }

    // MARK: - Simulator lifecycle hook

    private func handleSimulatorChange(running: Bool) {
        if running {
            // If a real flight was recording, stop and save it first
            if isRecording && !isSimulatedFlight {
                stopFlight()
            }
            // Start simulated recording
            startFlight(simulated: true)
        } else {
            // Simulator ended — stop the simulated recording and export waypoints
            if isRecording && isSimulatedFlight {
                stopFlight()
            }
        }
    }

    // MARK: - Start/stop

    /// Start a new flight recording. If one is already active, no-op.
    /// Pass `simulated: true` when the simulator is producing the data.
    func startFlight(simulated: Bool = false) {
        guard !isRecording else { return }
        // Build pilot + glider info from settings
        let pilot = settings?.pilotFullName ?? "tbiliyor"
        let glider = buildGliderString()
        igc = IGCRecorder(pilotName: pilot,
                          gliderType: glider,
                          gliderID: "VarioTB")
        igc.start(simulated: simulated)
        currentIGCURL = igc.fileURL
        isSimulatedFlight = simulated
        startFixTimer()
        isRecording = true
    }

    /// Build the glider description string for the IGC header.
    /// Format: "Brand Model (EN B)" or "Paraglider" if not set.
    private func buildGliderString() -> String {
        guard let s = settings else { return "Paraglider" }
        var parts: [String] = []
        if !s.gliderBrandModel.isEmpty {
            parts.append(s.gliderBrandModel)
        } else {
            parts.append(s.gliderType.rawValue)
        }
        if s.gliderCertification != .none {
            parts.append("(\(s.gliderCertification.rawValue))")
        }
        return parts.joined(separator: " ")
    }

    /// Stop recording and export current thermals as a waypoint file.
    @discardableResult
    func stopFlight() -> (igc: URL?, waypoints: URL?) {
        guard isRecording else { return (nil, nil) }
        fixTimer?.invalidate()
        fixTimer = nil
        igc.stop()
        isRecording = false

        // Export thermals as waypoint file
        // For simulated flights: export simulated thermals with _SIM tag
        // For real flights: export real thermals only
        var wpURL: URL? = nil
        if let thermals = varioMgr?.thermals {
            if isSimulatedFlight {
                let simThermals = thermals.filter { $0.source == .simulated }
                if !simThermals.isEmpty {
                    wpURL = WaypointExporter.exportThermals(simThermals, simulated: true)
                }
            } else {
                let realThermals = thermals.filter { $0.source == .real }
                if !realThermals.isEmpty {
                    wpURL = WaypointExporter.exportThermals(realThermals, simulated: false)
                }
            }
        }
        lastExportedWaypointURL = wpURL
        isSimulatedFlight = false
        return (currentIGCURL, wpURL)
    }

    // MARK: - Fix polling

    private func startFixTimer() {
        fixTimer?.invalidate()
        fixTimer = Timer.scheduledTimer(withTimeInterval: fixInterval, repeats: true) { [weak self] _ in
            self?.writeFix()
        }
    }

    private func writeFix() {
        guard let lm = locationMgr, let coord = lm.coordinate, lm.hasFix else { return }
        // During simulated flight we record the simulator's injected values,
        // which flow through locationMgr exactly like real GPS data.
        igc.appendFix(coordinate: coord,
                      pressureAltitudeM: lm.fusedAltitude,
                      gpsAltitudeM: lm.gpsAltitude)
    }

    // MARK: - File management

    /// All stored flight and waypoint files, newest first.
    func listStoredFiles() -> [URL] {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        var result: [URL] = []
        for folder in ["Flights", "Waypoints"] {
            let dir = docs.appendingPathComponent(folder, isDirectory: true)
            if let items = try? fm.contentsOfDirectory(at: dir,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: []) {
                result.append(contentsOf: items)
            }
        }
        result.sort { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
        return result
    }

    /// Delete a specific file from disk.
    func deleteFile(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Export thermals on demand (for mid-flight share).
    @discardableResult
    func exportCurrentThermalsAsWaypoints() -> URL? {
        guard let thermals = varioMgr?.thermals else { return nil }
        let filtered = isSimulatedFlight
            ? thermals.filter { $0.source == .simulated }
            : thermals.filter { $0.source == .real }
        guard !filtered.isEmpty else { return nil }
        let url = WaypointExporter.exportThermals(filtered, simulated: isSimulatedFlight)
        lastExportedWaypointURL = url
        return url
    }
}
