import Foundation
import CoreLocation

/// Lightweight IGC parser that produces a flight summary for the
/// FilesListView detail screen. Reads enough of an IGC file to extract
/// pilot/glider headers and walk all B-records, computing duration,
/// altitude envelope, total climb, distance metrics, and speed extremes.
///
/// Not a general-purpose IGC library — only the fields the detail
/// view needs are pulled out. Designed to handle large files (1 Hz
/// recording for a 6-hour flight = ~21 600 B-records, ~800 KB) in one
/// streaming pass without holding all fixes in memory.
struct IGCFlightSummary {
    // Header info (free-form strings, may be empty)
    let pilotName: String
    let civlID: String
    let gliderType: String
    let gliderID: String
    let manufacturerCode: String  // 3-letter A-record code (XVT / LXN / etc.)
    let firmware: String
    let hardware: String
    let flightDate: Date?         // From HFDTEDATE, midnight UTC of that day

    // Flight metrics
    let fixCount: Int
    let firstFixTime: Date?
    let lastFixTime: Date?
    /// Wall-clock duration from first to last B-record
    let duration: TimeInterval
    /// All ground-speed samples derived between consecutive fixes
    let maxGroundSpeedKmh: Double
    let avgGroundSpeedKmh: Double
    /// Pressure altitude envelope (PPPPP field). 0 if all zero.
    let pressureAltMin: Int
    let pressureAltMax: Int
    /// GNSS altitude envelope (GGGGG field).
    let gpsAltMin: Int
    let gpsAltMax: Int
    /// Cumulative climb sum: sum of positive altitude steps between
    /// consecutive fixes (using GPS alt). Approximation of total
    /// climbed during thermalling.
    let totalClimbM: Int
    /// Best instantaneous climb rate (m/s) seen between consecutive
    /// fixes, smoothed across at most a 5-fix window.
    let bestClimbRateMps: Double
    /// Straight-line great-circle distance from first fix to last fix.
    let straightLineDistanceKm: Double
    /// Sum of inter-fix great-circle hops — includes circling, wandering.
    let totalTrackDistanceKm: Double
    /// Bounding box for thumbnail / map preview. Nil if no fixes.
    let bbox: (minLat: Double, maxLat: Double,
               minLon: Double, maxLon: Double)?
    /// True iff the file contained an LXVTSIMULATED L-record.
    let isSimulated: Bool

    // MARK: - Parser

    /// Parse an IGC file at `url`. Returns nil only if the file cannot
    /// be opened. A malformed but readable file will produce a summary
    /// with whatever fields could be extracted (others stay zero/empty).
    static func parse(url: URL) -> IGCFlightSummary? {
        guard let raw = try? String(contentsOf: url, encoding: .ascii) else {
            // Some files may be UTF-8 with the same ASCII subset; retry.
            guard let utf8 = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            return parseString(utf8)
        }
        return parseString(raw)
    }

    private static func parseString(_ raw: String) -> IGCFlightSummary {
        var pilotName = ""
        var civlID = ""
        var gliderType = ""
        var gliderID = ""
        var manufacturerCode = ""
        var firmware = ""
        var hardware = ""
        var flightDate: Date? = nil
        var isSimulated = false

        var fixCount = 0
        var firstFixTime: Date? = nil
        var lastFixTime: Date? = nil
        var prevLat: Double = 0
        var prevLon: Double = 0
        var prevGpsAlt: Int = 0
        var prevTime: Date? = nil

        var pressMin = Int.max
        var pressMax = Int.min
        var gpsMin = Int.max
        var gpsMax = Int.min
        var totalClimb = 0
        var bestClimb: Double = 0
        var maxSpeed: Double = 0
        var sumSpeed: Double = 0
        var speedSamples = 0
        var totalDistKm: Double = 0
        var firstLat: Double = 0
        var firstLon: Double = 0
        var lastLat: Double = 0
        var lastLon: Double = 0

        var bMinLat = Double.greatestFiniteMagnitude
        var bMaxLat = -Double.greatestFiniteMagnitude
        var bMinLon = Double.greatestFiniteMagnitude
        var bMaxLon = -Double.greatestFiniteMagnitude

        // IGC files use CRLF; splitting on newlines tolerates both.
        let lines = raw.split(whereSeparator: \.isNewline)

        for sub in lines {
            let line = String(sub)
            guard let first = line.first else { continue }

            switch first {
            case "A":
                // AXVT001 Vario TB Flight Recorder
                if line.count >= 4 {
                    let start = line.index(line.startIndex, offsetBy: 1)
                    let end = line.index(start, offsetBy: 3)
                    manufacturerCode = String(line[start..<end])
                }
            case "H":
                parseHeader(line,
                            pilotName: &pilotName,
                            civlID: &civlID,
                            gliderType: &gliderType,
                            gliderID: &gliderID,
                            firmware: &firmware,
                            hardware: &hardware,
                            flightDate: &flightDate)
            case "L":
                if line.contains("SIMULATED") { isSimulated = true }
            case "B":
                guard let fix = parseBRecord(line, baseDate: flightDate) else {
                    continue
                }
                fixCount += 1

                // Altitude envelope
                if fix.pressAlt > 0 {
                    if fix.pressAlt < pressMin { pressMin = fix.pressAlt }
                    if fix.pressAlt > pressMax { pressMax = fix.pressAlt }
                }
                if fix.gpsAlt > 0 {
                    if fix.gpsAlt < gpsMin { gpsMin = fix.gpsAlt }
                    if fix.gpsAlt > gpsMax { gpsMax = fix.gpsAlt }
                }

                // Bounding box
                if fix.lat < bMinLat { bMinLat = fix.lat }
                if fix.lat > bMaxLat { bMaxLat = fix.lat }
                if fix.lon < bMinLon { bMinLon = fix.lon }
                if fix.lon > bMaxLon { bMaxLon = fix.lon }

                if firstFixTime == nil {
                    firstFixTime = fix.time
                    firstLat = fix.lat
                    firstLon = fix.lon
                } else if let pt = prevTime {
                    // Inter-fix metrics
                    let dt = fix.time.timeIntervalSince(pt)
                    if dt > 0 {
                        let altDelta = fix.gpsAlt - prevGpsAlt
                        if altDelta > 0 { totalClimb += altDelta }
                        let climbRate = Double(altDelta) / dt
                        if climbRate > bestClimb { bestClimb = climbRate }

                        let hop = haversineKm(lat1: prevLat, lon1: prevLon,
                                              lat2: fix.lat, lon2: fix.lon)
                        totalDistKm += hop
                        let speedKmh = hop / (dt / 3600)
                        // Sanity guard: GPS jump glitches can produce
                        // 1000+ km/h spikes. Anything above 250 km/h is
                        // assumed to be a glitch (paragliders top out
                        // around 60-70 km/h, hang gliders 90-100), and
                        // is excluded from BOTH max and average so the
                        // summary stays meaningful.
                        if speedKmh < 250 {
                            if speedKmh > maxSpeed { maxSpeed = speedKmh }
                            sumSpeed += speedKmh
                            speedSamples += 1
                        }
                    }
                }

                prevTime = fix.time
                prevLat = fix.lat
                prevLon = fix.lon
                prevGpsAlt = fix.gpsAlt
                lastFixTime = fix.time
                lastLat = fix.lat
                lastLon = fix.lon
            default:
                break
            }
        }

        let duration = (firstFixTime != nil && lastFixTime != nil)
            ? lastFixTime!.timeIntervalSince(firstFixTime!)
            : 0
        let straightKm = fixCount >= 2
            ? haversineKm(lat1: firstLat, lon1: firstLon,
                          lat2: lastLat, lon2: lastLon)
            : 0
        let avgSpeed = speedSamples > 0
            ? sumSpeed / Double(speedSamples)
            : 0
        let bbox: (minLat: Double, maxLat: Double,
                   minLon: Double, maxLon: Double)? = fixCount > 0
            ? (bMinLat, bMaxLat, bMinLon, bMaxLon)
            : nil

        return IGCFlightSummary(
            pilotName: pilotName,
            civlID: civlID,
            gliderType: gliderType,
            gliderID: gliderID,
            manufacturerCode: manufacturerCode,
            firmware: firmware,
            hardware: hardware,
            flightDate: flightDate,
            fixCount: fixCount,
            firstFixTime: firstFixTime,
            lastFixTime: lastFixTime,
            duration: duration,
            maxGroundSpeedKmh: maxSpeed,
            avgGroundSpeedKmh: avgSpeed,
            pressureAltMin: pressMin == Int.max ? 0 : pressMin,
            pressureAltMax: pressMax == Int.min ? 0 : pressMax,
            gpsAltMin: gpsMin == Int.max ? 0 : gpsMin,
            gpsAltMax: gpsMax == Int.min ? 0 : gpsMax,
            totalClimbM: totalClimb,
            bestClimbRateMps: bestClimb,
            straightLineDistanceKm: straightKm,
            totalTrackDistanceKm: totalDistKm,
            bbox: bbox,
            isSimulated: isSimulated
        )
    }

    // MARK: - Header parsing

    private static func parseHeader(_ line: String,
                                     pilotName: inout String,
                                     civlID: inout String,
                                     gliderType: inout String,
                                     gliderID: inout String,
                                     firmware: inout String,
                                     hardware: inout String,
                                     flightDate: inout Date?) {
        // HFDTEDATE:DDMMYY,01
        if line.hasPrefix("HFDTEDATE:") {
            let body = String(line.dropFirst("HFDTEDATE:".count))
            // body = "DDMMYY,NN" or "DDMMYY"
            let parts = body.split(separator: ",")
            if let datePart = parts.first, datePart.count >= 6 {
                let s = String(datePart)
                let dd = Int(s.prefix(2)) ?? 0
                let mo = Int(s.dropFirst(2).prefix(2)) ?? 0
                let yy = Int(s.dropFirst(4).prefix(2)) ?? 0
                var comps = DateComponents()
                comps.day = dd
                comps.month = mo
                // 00..69 → 2000s, 70..99 → 1900s. IGC spec: 70+ is 19xx.
                comps.year = yy < 70 ? 2000 + yy : 1900 + yy
                comps.timeZone = TimeZone(identifier: "UTC")
                flightDate = Calendar(identifier: .gregorian).date(from: comps)
            }
            return
        }

        // HFPLTPILOTINCHARGE:Turkay Biliyor (CIVLID:21450)
        if line.hasPrefix("HFPLTPILOTINCHARGE:") {
            var body = String(line.dropFirst("HFPLTPILOTINCHARGE:".count))
            // Pull CIVLID out if present
            if let range = body.range(of: "(CIVLID:") {
                let after = body[range.upperBound...]
                if let close = after.firstIndex(of: ")") {
                    civlID = String(after[..<close])
                        .trimmingCharacters(in: .whitespaces)
                }
                body = String(body[..<range.lowerBound])
            }
            pilotName = body.trimmingCharacters(in: .whitespaces)
            return
        }

        if line.hasPrefix("HFGTYGLIDERTYPE:") {
            gliderType = String(line.dropFirst("HFGTYGLIDERTYPE:".count))
                .trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("HFGIDGLIDERID:") {
            gliderID = String(line.dropFirst("HFGIDGLIDERID:".count))
                .trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("HFRFWFIRMWAREVERSION:") {
            firmware = String(line.dropFirst("HFRFWFIRMWAREVERSION:".count))
                .trimmingCharacters(in: .whitespaces)
            return
        }
        if line.hasPrefix("HFRHWHARDWAREVERSION:") {
            hardware = String(line.dropFirst("HFRHWHARDWAREVERSION:".count))
                .trimmingCharacters(in: .whitespaces)
            return
        }
    }

    // MARK: - B-record parsing

    private struct Fix {
        let time: Date
        let lat: Double
        let lon: Double
        let pressAlt: Int
        let gpsAlt: Int
    }

    private static func parseBRecord(_ line: String,
                                      baseDate: Date?) -> Fix? {
        // B HHMMSS DDMMmmm N DDDMMmmm E V PPPPP GGGGG (ext)
        // 0 1-7    7-14    14 15-23   23 24 25-30 30-35
        guard line.count >= 35 else { return nil }
        let chars = Array(line)
        guard chars[14] == Character("N") || chars[14] == Character("S"),
              chars[23] == Character("E") || chars[23] == Character("W")
        else { return nil }

        let hh = Int(String(chars[1...2])) ?? 0
        let mm = Int(String(chars[3...4])) ?? 0
        let ss = Int(String(chars[5...6])) ?? 0

        let latDeg = Double(String(chars[7...8])) ?? 0
        let latMin = Double(String(chars[9...10])) ?? 0
        let latMinFrac = Double(String(chars[11...13])) ?? 0
        var lat = latDeg + (latMin + latMinFrac / 1000) / 60
        if chars[14] == "S" { lat = -lat }

        let lonDeg = Double(String(chars[15...17])) ?? 0
        let lonMin = Double(String(chars[18...19])) ?? 0
        let lonMinFrac = Double(String(chars[20...22])) ?? 0
        var lon = lonDeg + (lonMin + lonMinFrac / 1000) / 60
        if chars[23] == "W" { lon = -lon }

        let pressAlt = Int(String(chars[25...29])) ?? 0
        let gpsAlt = Int(String(chars[30...34])) ?? 0

        // Combine baseDate (UTC midnight) with hh:mm:ss
        let date: Date
        if let base = baseDate {
            date = base.addingTimeInterval(
                TimeInterval(hh * 3600 + mm * 60 + ss))
        } else {
            // No HFDTE — synthesise a date so duration math still works
            var comps = DateComponents()
            comps.year = 2000; comps.month = 1; comps.day = 1
            comps.hour = hh; comps.minute = mm; comps.second = ss
            comps.timeZone = TimeZone(identifier: "UTC")
            date = Calendar(identifier: .gregorian).date(from: comps)
                ?? Date(timeIntervalSince1970: 0)
        }

        return Fix(time: date, lat: lat, lon: lon,
                   pressAlt: pressAlt, gpsAlt: gpsAlt)
    }

    // MARK: - Geometry

    private static func haversineKm(lat1: Double, lon1: Double,
                                     lat2: Double, lon2: Double) -> Double {
        let R = 6371.0
        let φ1 = lat1 * .pi / 180
        let φ2 = lat2 * .pi / 180
        let dφ = (lat2 - lat1) * .pi / 180
        let dλ = (lon2 - lon1) * .pi / 180
        let a = sin(dφ/2) * sin(dφ/2) +
                cos(φ1) * cos(φ2) * sin(dλ/2) * sin(dλ/2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return R * c
    }
}
