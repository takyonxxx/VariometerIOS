import Foundation
import CoreLocation

/// Exports thermal points as a SeeYou .cup waypoint file.
/// CUP format is the de-facto standard: readable by XCTrack, XCSoar, SeeYou, etc.
enum WaypointExporter {

    /// Writes a .cup file containing all given thermals. Returns the file URL.
    /// If `simulated` is true, "_SIM" is appended to the filename.
    static func exportThermals(_ thermals: [ThermalPoint],
                               filenameBase: String = "thermals",
                               simulated: Bool = false) -> URL? {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Waypoints", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd_HHmmss"
        let suffix = simulated ? "_SIM" : ""
        let filename = "\(filenameBase)_\(df.string(from: Date()))\(suffix).cup"
        let url = dir.appendingPathComponent(filename)

        var cup = ""
        // CUP header row (SeeYou format)
        cup += "name,code,country,lat,lon,elev,style,rwdir,rwlen,freq,desc\r\n"

        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "yyyy-MM-dd HH:mm"

        for (idx, t) in thermals.enumerated() {
            let name = String(format: "THX%02d_%.1fms", idx + 1, t.strength)
            let code = String(format: "TH%02d", idx + 1)
            let lat = cupLat(t.coordinate.latitude)
            let lon = cupLon(t.coordinate.longitude)
            let elev = String(format: "%.0fm", t.altitude)
            // style 1 = waypoint
            let style = "1"
            let desc = String(format: "Termik %+.1f m/s - %@",
                              t.strength, tf.string(from: t.timestamp))
            // Quote name and desc
            cup += "\"\(name)\",\"\(code)\",,\(lat),\(lon),\(elev),\(style),,,,\"\(desc)\"\r\n"
        }

        do {
            try cup.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            print("Waypoint export failed: \(error)")
            return nil
        }
    }

    // CUP format: DDMM.mmmN or DDDMM.mmmE
    private static func cupLat(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let deg = Int(abs)
        let min = (abs - Double(deg)) * 60
        let hemi = v >= 0 ? "N" : "S"
        return String(format: "%02d%06.3f%@", deg, min, hemi)
    }
    private static func cupLon(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let deg = Int(abs)
        let min = (abs - Double(deg)) * 60
        let hemi = v >= 0 ? "E" : "W"
        return String(format: "%03d%06.3f%@", deg, min, hemi)
    }
}
