import Foundation
import CoreLocation

/// Parses waypoint files in the formats commonly used by paragliding
/// competitions. Returns the extracted waypoints or nil if parsing fails.
///
/// Supported formats:
///   - XCTrack .xctsk (JSON)       — full task with turnpoints
///   - GPX (.gpx, XML)             — <wpt> nodes
///   - CompeGPS / OziExplorer .wpt — tab/whitespace separated text
enum WaypointFileParser {

    /// Parse waypoints from any supported format. Returns empty array if
    /// no recognizable waypoints found.
    static func parse(data: Data, filename: String) -> [Waypoint] {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "xctsk":
            return parseXCTSK(data: data)
        case "gpx":
            return parseGPX(data: data)
        case "wpt":
            return parseWPT(data: data)
        default:
            // Try to sniff by content
            if let text = String(data: data, encoding: .utf8) {
                if text.hasPrefix("<?xml") && text.contains("<wpt") {
                    return parseGPX(data: data)
                }
                if text.hasPrefix("{") && text.contains("\"turnpoints\"") {
                    return parseXCTSK(data: data)
                }
                if text.contains("$FormatGEO") || text.contains("$FormatUTM") {
                    return parseWPT(data: data)
                }
            }
            return []
        }
    }

    /// Parse entire task (turnpoints + metadata) from an XCTrack file.
    /// Returns nil if not a valid xctsk.
    static func parseTask(from data: Data, filename: String) -> ImportedTask? {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "xctsk" || (String(data: data, encoding: .utf8)?.contains("\"turnpoints\"") ?? false) {
            return parseXCTSKTask(data: data)
        }
        return nil
    }

    // MARK: - XCTrack .xctsk (JSON)

    /// XCTrack task format — see http://xctrack.org/Competition_Interfaces.html
    /// Minimal schema: {"taskType":"CLASSIC","turnpoints":[{"waypoint":{"name":"...","lat":0,"lon":0,"altSmoothed":0},"radius":400,"type":"SSS"|"ESS"}], ...}
    private static func parseXCTSK(data: Data) -> [Waypoint] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tps = root["turnpoints"] as? [[String: Any]]
        else { return [] }
        var result: [Waypoint] = []
        for tp in tps {
            if let wp = tp["waypoint"] as? [String: Any],
               let name = wp["name"] as? String,
               let lat = wp["lat"] as? Double,
               let lon = wp["lon"] as? Double {
                let alt = (wp["altSmoothed"] as? Double)
                       ?? (wp["altitude"] as? Double)
                       ?? 0
                result.append(Waypoint(name: name,
                                        latitude: lat,
                                        longitude: lon,
                                        altitudeM: alt))
            }
        }
        return result
    }

    /// Parse a full task (including turnpoint radii and types) from XCTrack JSON.
    private static func parseXCTSKTask(data: Data) -> ImportedTask? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tps = root["turnpoints"] as? [[String: Any]]
        else { return nil }
        var waypoints: [Waypoint] = []
        var turnpointSpecs: [ImportedTurnpointSpec] = []
        for tp in tps {
            guard let wp = tp["waypoint"] as? [String: Any],
                  let name = wp["name"] as? String,
                  let lat = wp["lat"] as? Double,
                  let lon = wp["lon"] as? Double else { continue }
            let alt = (wp["altSmoothed"] as? Double)
                   ?? (wp["altitude"] as? Double)
                   ?? 0
            let waypoint = Waypoint(name: name,
                                     latitude: lat,
                                     longitude: lon,
                                     altitudeM: alt)
            waypoints.append(waypoint)

            // Type mapping
            let typeRaw = (tp["type"] as? String) ?? ""
            let tpType: TurnpointType
            switch typeRaw.uppercased() {
            case "TAKEOFF":     tpType = .takeoff
            case "SSS":         tpType = .sss
            case "ESS":         tpType = .ess
            case "GOAL":        tpType = .goal
            default:            tpType = .turn
            }
            let radius = (tp["radius"] as? Double) ?? 400

            turnpointSpecs.append(ImportedTurnpointSpec(
                waypointIndex: waypoints.count - 1,
                type: tpType,
                radiusM: radius
            ))
        }
        let taskName = (root["taskType"] as? String) ?? "Imported Task"
        return ImportedTask(name: taskName,
                             waypoints: waypoints,
                             turnpointSpecs: turnpointSpecs)
    }

    // MARK: - GPX

    /// GPX is XML with <wpt lat="..." lon="..."><name>...</name></wpt> nodes.
    /// We use a tiny regex-based parser rather than XMLParser to keep things
    /// simple — this is fine for well-formed GPX from competition tools.
    private static func parseGPX(data: Data) -> [Waypoint] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [Waypoint] = []

        // Find all <wpt ...>...</wpt> blocks
        let wptPattern = #"<wpt[^>]*lat\s*=\s*"([-\d.]+)"[^>]*lon\s*=\s*"([-\d.]+)"[^>]*>([\s\S]*?)</wpt>"#
        let altPattern = #"<ele>([-\d.]+)</ele>"#
        let namePattern = #"<name>([^<]+)</name>"#
        guard let wptRe = try? NSRegularExpression(pattern: wptPattern) else { return [] }
        let altRe = try? NSRegularExpression(pattern: altPattern)
        let nameRe = try? NSRegularExpression(pattern: namePattern)

        let nsText = text as NSString
        let matches = wptRe.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        for m in matches {
            let latStr = nsText.substring(with: m.range(at: 1))
            let lonStr = nsText.substring(with: m.range(at: 2))
            let inner = nsText.substring(with: m.range(at: 3))
            guard let lat = Double(latStr), let lon = Double(lonStr) else { continue }

            var name = "WP\(result.count + 1)"
            if let nameRe = nameRe {
                let inNS = inner as NSString
                if let nm = nameRe.firstMatch(in: inner, range: NSRange(location: 0, length: inNS.length)) {
                    name = inNS.substring(with: nm.range(at: 1))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            var alt: Double = 0
            if let altRe = altRe {
                let inNS = inner as NSString
                if let am = altRe.firstMatch(in: inner, range: NSRange(location: 0, length: inNS.length)) {
                    alt = Double(inNS.substring(with: am.range(at: 1))) ?? 0
                }
            }
            result.append(Waypoint(name: name, latitude: lat, longitude: lon, altitudeM: alt))
        }
        return result
    }

    // MARK: - CompeGPS / OziExplorer / GpsDump .wpt

    /// GEO format sample:
    ///   $FormatGEO
    ///   LAUNCH    N 40 01.887  E 032 19.683   1068  Launch site
    ///   TP01      N 40 01.001  E 032 16.850   2778  Turnpoint 1
    ///
    /// OziExplorer format sample:
    ///   OziExplorer Waypoint File Version 1.1
    ///   WGS 84
    ///   Reserved 2
    ///   Reserved 3
    ///   1,LAUNCH,40.031450,32.328050,12345.5, 0, 1, 3, 0, 65535,,0, 0, 0, -777,6,0,17
    private static func parseWPT(data: Data) -> [Waypoint] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var result: [Waypoint] = []
        let lines = text.components(separatedBy: .newlines)

        // Detect format
        let isGeo = lines.contains(where: { $0.contains("$FormatGEO") })
        let isOziLike = lines.first?.contains("OziExplorer") == true
                     || lines.contains(where: { $0.contains("WGS 84") })

        if isGeo {
            // GEO: name, "N dd mm.mmm", "E ddd mm.mmm", alt, desc
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("$") || t.hasPrefix("#") { continue }
                // Regex: capture name, hemisphere+lat, hemisphere+lon, alt
                let pattern = #"^(\S+)\s+([NS])\s*(\d{1,3})\s+([\d.]+)\s+([EW])\s*(\d{1,3})\s+([\d.]+)\s*([\d.-]*)"#
                guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
                let ns = t as NSString
                guard let m = re.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) else { continue }
                let name = ns.substring(with: m.range(at: 1))
                let latSign = ns.substring(with: m.range(at: 2)) == "S" ? -1.0 : 1.0
                let latDeg = Double(ns.substring(with: m.range(at: 3))) ?? 0
                let latMin = Double(ns.substring(with: m.range(at: 4))) ?? 0
                let lonSign = ns.substring(with: m.range(at: 5)) == "W" ? -1.0 : 1.0
                let lonDeg = Double(ns.substring(with: m.range(at: 6))) ?? 0
                let lonMin = Double(ns.substring(with: m.range(at: 7))) ?? 0
                let altStr = ns.substring(with: m.range(at: 8))
                let alt = Double(altStr) ?? 0
                let lat = latSign * (latDeg + latMin / 60.0)
                let lon = lonSign * (lonDeg + lonMin / 60.0)
                result.append(Waypoint(name: name, latitude: lat, longitude: lon, altitudeM: alt))
            }
        } else if isOziLike {
            // OziExplorer CSV: skip first 4 header lines
            for (idx, line) in lines.enumerated() {
                if idx < 4 { continue }
                let parts = line.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if parts.count < 5 { continue }
                let name = String(parts[1])
                guard let lat = Double(parts[2]),
                      let lon = Double(parts[3]) else { continue }
                let alt = parts.count > 4 ? (Double(parts[14]) ?? 0) : 0
                result.append(Waypoint(name: name, latitude: lat, longitude: lon, altitudeM: alt))
            }
        }
        return result
    }
}

/// Spec for a single turnpoint extracted from an imported task — references
/// an imported waypoint by index, carries task-specific type and radius.
struct ImportedTurnpointSpec {
    let waypointIndex: Int
    let type: TurnpointType
    let radiusM: Double
}

/// Full task extracted from an XCTrack .xctsk file or QR code.
struct ImportedTask {
    let name: String
    let waypoints: [Waypoint]
    let turnpointSpecs: [ImportedTurnpointSpec]
    /// SSS open time — the earliest time pilots may cross the start cylinder.
    /// Parsed from "sss.timeGates[0]" (v1) or "s.g[0]" (v2) in the XCTrack payload.
    let sssStartTime: Date?
    /// Task deadline (goal close). Parsed from "goal.deadline" (v1) or "g.d" (v2).
    let taskDeadline: Date?

    init(name: String,
         waypoints: [Waypoint],
         turnpointSpecs: [ImportedTurnpointSpec],
         sssStartTime: Date? = nil,
         taskDeadline: Date? = nil) {
        self.name = name
        self.waypoints = waypoints
        self.turnpointSpecs = turnpointSpecs
        self.sssStartTime = sssStartTime
        self.taskDeadline = taskDeadline
    }
}
