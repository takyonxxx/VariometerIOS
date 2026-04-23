import Foundation
import CoreLocation

/// A pure waypoint — just a geographic point with a name, altitude, and
/// optional description. Independent of any task; waypoints are reusable
/// across multiple tasks. Identified by `id` (UUID) so the same waypoint
/// can be referenced safely even after rename.
struct Waypoint: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var altitudeM: Double = 0
    var description: String = ""

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A named list of waypoints. E.g. "Kiwi Open 2016", "St Andre PWC",
/// "My favorites". Pilots keep separate lists per competition / region
/// so waypoints don't mix.
final class WaypointList: ObservableObject, Codable, Identifiable {
    var id = UUID()
    @Published var name: String
    @Published var waypoints: [Waypoint] = []

    enum CodingKeys: String, CodingKey { case id, name, waypoints }

    init(name: String) {
        self.name = name
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        waypoints = try c.decode([Waypoint].self, forKey: .waypoints)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(waypoints, forKey: .waypoints)
    }
}

/// The waypoint library manages all lists. Singleton, auto-persists to disk.
final class WaypointLibrary: ObservableObject {
    static let shared = WaypointLibrary()

    @Published var lists: [WaypointList] = []

    private var saveTimer: Timer?

    private init() {
        load()
        // Watch individual list edits (via NotificationCenter-like mechanism)
        // We use Combine's objectWillChange to auto-save.
    }

    // MARK: - Library operations

    func addList(named name: String) -> WaypointList {
        let list = WaypointList(name: name)
        lists.append(list)
        scheduleSave()
        return list
    }

    func removeList(at offsets: IndexSet) {
        lists.remove(atOffsets: offsets)
        scheduleSave()
    }

    func renameList(_ list: WaypointList, to newName: String) {
        list.name = newName
        scheduleSave()
    }

    func list(withID id: UUID) -> WaypointList? {
        lists.first { $0.id == id }
    }

    /// Flat lookup: find a waypoint by ID across all lists.
    func findWaypoint(id: UUID) -> Waypoint? {
        for list in lists {
            if let wp = list.waypoints.first(where: { $0.id == id }) {
                return wp
            }
        }
        return nil
    }

    // MARK: - Waypoint operations within a list

    func addWaypoint(_ wp: Waypoint, to list: WaypointList) {
        list.waypoints.append(wp)
        scheduleSave()
    }

    func removeWaypoints(at offsets: IndexSet, from list: WaypointList) {
        list.waypoints.remove(atOffsets: offsets)
        scheduleSave()
    }

    func updateWaypoint(_ wp: Waypoint, in list: WaypointList) {
        if let idx = list.waypoints.firstIndex(where: { $0.id == wp.id }) {
            list.waypoints[idx] = wp
            scheduleSave()
        }
    }

    /// Bulk append — used by import.
    func appendWaypoints(_ wps: [Waypoint], to list: WaypointList) {
        list.waypoints.append(contentsOf: wps)
        scheduleSave()
    }

    // MARK: - Persistence

    private static var storageURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory,
                                            in: .userDomainMask).first!
        return docs.appendingPathComponent("waypoint_library.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL),
              let decoded = try? JSONDecoder().decode([WaypointList].self, from: data)
        else {
            // Seed with an empty "Others" list so user has somewhere to add
            lists = [WaypointList(name: "Others")]
            return
        }
        lists = decoded
    }

    /// Debounced save — avoid hammering disk on every small edit.
    private func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.saveNow()
        }
        // Also notify observers that something changed
        objectWillChange.send()
    }

    /// Force immediate save (call before app backgrounds).
    func saveNow() {
        do {
            let data = try JSONEncoder().encode(lists)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            // Silent — we'll retry on next edit
        }
    }
}
