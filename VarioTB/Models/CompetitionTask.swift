import Foundation
import CoreLocation

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
    /// (optimised route through the cylinders), but for pilot-facing display
    /// this is close enough and clearer.
    var totalDistanceM: Double {
        guard turnpoints.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(turnpoints.count - 1) {
            total += Self.haversine(turnpoints[i].coordinate,
                                     turnpoints[i+1].coordinate)
        }
        return total
    }

    // MARK: - Task progress

    /// Given the pilot's current position, return the index of the next
    /// un-reached turnpoint in the task, plus whether the pilot is currently
    /// inside that cylinder.
    func nextTurnpointIndex(pilot: CLLocationCoordinate2D,
                            reachedIDs: Set<UUID>) -> Int? {
        for (i, tp) in turnpoints.enumerated() where !reachedIDs.contains(tp.id) {
            return i
        }
        return nil
    }

    /// Returns true if the pilot is inside the given turnpoint's cylinder.
    func isInsideCylinder(pilot: CLLocationCoordinate2D,
                          tp: Turnpoint) -> Bool {
        return Self.haversine(pilot, tp.coordinate) <= tp.radiusM
    }

    // MARK: - Geometry helpers

    static func haversine(_ a: CLLocationCoordinate2D,
                          _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sa = sin(dLat/2)
        let sb = sin(dLon/2)
        let h = sa*sa + cos(lat1)*cos(lat2)*sb*sb
        return 2 * R * asin(min(1, sqrt(h)))
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
