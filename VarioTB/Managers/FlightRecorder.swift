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
    /// Shared instance accessible from App Intents (Siri shortcuts,
    /// Shortcuts app, interactive widgets). ContentView still uses its own
    /// `@StateObject` and assigns `FlightRecorder.shared = self` in attach()
    /// so both paths see the same object.
    static weak var shared: FlightRecorder?

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
    /// The currently-loaded competition task. Only used to read
    /// `taskStartTime` when stamping IGC B-records during a simulator
    /// run — so the recorded timestamps line up with the simulated
    /// competition clock instead of real wall-clock. `nil` (or a task
    /// with no start time) falls back to wall-clock.
    weak var task: CompetitionTask?

    func attach(locationManager: LocationManager,
                varioManager: VarioManager,
                simulator: FlightSimulator,
                settings: AppSettings,
                task: CompetitionTask) {
        self.locationMgr = locationManager
        self.varioMgr = varioManager
        self.simulator = simulator
        self.settings = settings
        self.task = task

        // Expose this instance to App Intents
        FlightRecorder.shared = self

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
        // Simulated flights don't produce IGC files or waypoint exports.
        // Recording is reserved for real flights only — a sim run is a
        // training / preview tool, not a record-worthy flight.
        //
        // The only thing we still do here is stop a real recording in
        // the rare case the user kicks off the sim while a real flight
        // is being logged. We don't restart it on sim-stop because the
        // sim can have moved the simulated GPS coordinate far from the
        // real takeoff site; if the pilot resumes real flying afterward
        // the auto-start logic will pick it back up.
        if running, isRecording, !isSimulatedFlight {
            stopFlight()
        }
    }

    // MARK: - Start/stop

    /// Start a new flight recording. If one is already active, no-op.
    /// Pass `simulated: true` when the simulator is producing the data.
    ///
    /// IGC recordings of simulator-driven flights are deliberately
    /// disabled: a sim run is a training / preview tool, the data is
    /// synthetic, and a sim "flight" uploaded to XContest / Leonardo
    /// would be misleading. If a Siri intent or panel button calls
    /// this while the simulator is running, we no-op silently — the
    /// UI dims its REC controls in this state, so the silent failure
    /// matches what the user already sees.
    func startFlight(simulated: Bool = false) {
        guard !isRecording else { return }
        if simulator?.isRunning == true {
            // Sim is producing data — refuse to record. The pilot can
            // start a recording the moment they stop the simulator.
            return
        }
        // Build pilot + glider info from settings
        let pilot = settings?.pilotFullName ?? "tbiliyor"
        let civlID = settings?.pilotCIVLID ?? ""
        let glider = buildGliderString()
        // Use brand+model alone (without certification suffix) as the
        // glider ID line if available — gives parsers something
        // useful in HFGID without leaking the cert string twice.
        let gliderID = settings?.gliderBrandModel ?? ""
        igc = IGCRecorder(pilotName: pilot,
                          pilotCIVLID: civlID,
                          gliderType: glider,
                          gliderID: gliderID,
                          gliderCompID: "",
                          gliderCompClass: "Paragliding",
                          firmwareVersion: "1.0.0",
                          hardwareVersion: "iPhone")
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

        // Export real thermals collected during this flight as a CUP
        // waypoint file. Simulated thermals are never recorded here:
        // the simulator-lifecycle hook prevents `startFlight` from ever
        // being called with simulated=true, so we only see real fixes.
        var wpURL: URL? = nil
        if let thermals = varioMgr?.thermals {
            let realThermals = thermals.filter { $0.source == .real }
            if !realThermals.isEmpty {
                wpURL = WaypointExporter.exportThermals(realThermals, simulated: false)
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
        // During simulated flight we record the simulator's injected
        // values, which flow through locationMgr exactly like real
        // GPS data. For IGC timestamps: if the sim is running, the
        // task has a start time set, AND the pilot has crossed the
        // SSS gate, stamp B-records with the *simulated* competition
        // clock so the resulting .igc reads as a coherent 30 km/h
        // flight beginning at taskStart. Before SSS-cross (lead-in
        // flight) and in any other case, fall back to wall-clock —
        // which IGCRecorder defaults to.
        let stampDate: Date = {
            if let sim = simulator,
               let simDate = sim.simulatedClockDate(
                   taskStartTime: task?.taskStartTime,
                   sssReachedAt: task?.sssReachedAt) {
                return simDate
            }
            return Date()
        }()
        // FXA = horizontal accuracy in metres. Core Location reports
        // -1 when the value is invalid; clamp that to a defensive 99
        // so the field stays well-formed but signals "not great".
        let fxa = lm.horizontalAccuracy > 0 ? lm.horizontalAccuracy : 99.0
        igc.appendFix(coordinate: coord,
                      pressureAltitudeM: lm.fusedAltitude,
                      gpsAltitudeM: lm.gpsAltitude,
                      fixAccuracyM: fxa,
                      date: stampDate)
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

    /// Export thermals on demand (for mid-flight share). Only real
    /// thermals are exported — simulated runs never produce waypoint
    /// files, even mid-flight.
    @discardableResult
    func exportCurrentThermalsAsWaypoints() -> URL? {
        guard let thermals = varioMgr?.thermals else { return nil }
        let realThermals = thermals.filter { $0.source == .real }
        guard !realThermals.isEmpty else { return nil }
        let url = WaypointExporter.exportThermals(realThermals, simulated: false)
        lastExportedWaypointURL = url
        return url
    }
}
