import Foundation
import CoreImage.CIFilterBuiltins
import UIKit
import Compression

/// QR code encode/decode for XCTrack-compatible tasks.
///
/// Supports all XCTrack QR formats per https://xctrack.org/Competition_Interfaces.html :
///   • `XCTSK:` + v1 JSON (long format, turnpoints with waypoint.lat/lon/altSmoothed)
///   • `XCTSK:` + v2 JSON (compact — polyline-encoded coordinates in "z")
///   • `XCTSKZ:` + zlib-compressed base64 payload (any of the above)
///   • XC/Waypoints v2: {"T":"W","V":2,"t":[{"z":..,"n":..}]}  (no cylinders)
///
/// Flyskyhy iOS and XCTrack Android exchange tasks via the compact v2 form,
/// which is why this codec MUST decode v2 even though it encodes v1 (simpler
/// to produce and broadly compatible for scanners).
enum TaskQRCodec {

    // MARK: - Encoding (v2 compact — matches Flyskyhy/XCTrack preferred format)

    /// Generate a UIImage QR code containing the given task in XCTrack v2
    /// format (polyline-encoded, compact — same format Flyskyhy produces).
    /// Cross-compatible with XCTrack Android, Flyskyhy iOS, SeeYou Navigator.
    /// Build a QR image for `task` in the standard XCTrack v2 text
    /// format (`XCTSK:<json>`) — exactly what Flyskyhy and XCTrack
    /// produce. Plain text, not a URL: iOS Camera shows the raw
    /// payload and offers no app handler, so the pilot scans from
    /// inside whichever flight app they want to import into.
    ///
    /// The encoded JSON includes all task fields per the XCTrack v2
    /// spec:
    ///   - `version: 2`
    ///   - `t[]`: turnpoints with `n` (name), `z` (polyline-encoded
    ///     coordinate + altitude + radius), optional `t` (2=SSS,
    ///     3=ESS), optional `d` (description)
    ///   - `s`: start gate timing — `g[]` (HH:MM:SSZ open times),
    ///     `d` (direction: 1=exit), `t` (type: 1=race)
    ///   - `g`: goal — `d` (deadline HH:MM:SSZ), `t` (type: 0=cylinder)
    ///   - `taskType: "CLASSIC"`
    static func generateQR(for task: CompetitionTask,
                            size: CGFloat = 300) -> UIImage? {
        let payload = encodeXCTrackV2(task: task)
        guard let data = payload.data(using: .utf8) else { return nil }

        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImg = context.createCGImage(scaled, from: scaled.extent) else {
            return nil
        }
        return UIImage(cgImage: cgImg)
    }

    /// Encode task in XCTrack v2 format: "XCTSK:" + JSON with polyline-encoded
    /// turnpoints. Per XCTrack spec, v2 puts all coordinate data in compact
    /// string "z" fields, matching what Flyskyhy produces. Timing info
    /// (SSS open / goal deadline) is also included so a round-trip
    /// export → scan preserves it — without this, importing your own
    /// shared QR drops the start and deadline clocks.
    private static func encodeXCTrackV2(task: CompetitionTask) -> String {
        var turnpointsV2: [[String: Any]] = []
        for tp in task.turnpoints {
            var tpObj: [String: Any] = [
                "z": encodePolyline(lon: tp.longitude,
                                    lat: tp.latitude,
                                    alt: Int(tp.altitudeM),
                                    radius: Int(tp.radiusM)),
                "n": tp.name,
            ]
            // "t" = 2 for SSS, 3 for ESS (per v2 spec)
            // TAKEOFF/GOAL are implicit (first TP / last TP)
            switch tp.type {
            case .sss: tpObj["t"] = 2
            case .ess: tpObj["t"] = 3
            default:   break
            }
            if !tp.description.isEmpty {
                tpObj["d"] = tp.description
            }
            turnpointsV2.append(tpObj)
        }
        var root: [String: Any] = [
            "taskType": "CLASSIC",
            "version":  2,
            "t":        turnpointsV2,
        ]
        // SSS timing — v2 stores the first (and only) open time in
        // root.s.g[]. We also set s.d=1 (multi-start disabled) and
        // s.t=1 (RACE type) to keep the payload interpretable by
        // other XCTrack readers.
        if let start = task.taskStartTime {
            root["s"] = [
                "g": [formatXCTrackTime(start)],
                "d": 1,
                "t": 1,
            ] as [String: Any]
        }
        // Goal deadline — v2 root.g.d.
        if let deadline = task.taskDeadline {
            root["g"] = [
                "d": formatXCTrackTime(deadline),
                "t": 0,
            ] as [String: Any]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: root,
                options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "XCTSK:{}"
        }
        return "XCTSK:" + json
    }

    /// Format a `Date` as XCTrack's "HH:MM:SSZ" UTC time-of-day string.
    /// Inverse of `parseXCTrackTime` in the decoder.
    private static func formatXCTrackTime(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let comps = cal.dateComponents([.hour, .minute, .second], from: date)
        let hh = comps.hour ?? 0
        let mm = comps.minute ?? 0
        let ss = comps.second ?? 0
        return String(format: "%02d:%02d:%02dZ", hh, mm, ss)
    }

    /// Encode a single turnpoint's 4 values as a polyline string.
    /// Order: longitude, latitude, altitude, radius — per go-xctrack reference.
    private static func encodePolyline(lon: Double, lat: Double,
                                        alt: Int, radius: Int) -> String {
        var out = ""
        out += encodeSignedInt(Int((lon * 1e5).rounded()))
        out += encodeSignedInt(Int((lat * 1e5).rounded()))
        out += encodeSignedInt(alt)
        out += encodeSignedInt(radius)
        return out
    }

    /// Google polyline signed-int encoding (zigzag + base64-ish varint).
    private static func encodeSignedInt(_ value: Int) -> String {
        var v = value << 1
        if value < 0 {
            v = ~v
        }
        var bytes: [UInt8] = []
        while v >= 0x20 {
            bytes.append(UInt8((0x20 | (v & 0x1F)) + 63))
            v >>= 5
        }
        bytes.append(UInt8(v + 63))
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    // MARK: - Decoding (all formats)

    /// Decode a scanned QR payload into an `ImportedTask`.
    /// Handles:
    ///   - "XCTSK:" prefix → v1 (.turnpoints[]) or v2 (.t[] with polyline "z")
    ///   - "XCTSKZ:" prefix → zlib+base64 decompress first, then dispatch
    ///   - XC/Waypoints v2 ({"T":"W","V":2,"t":[...]})
    ///   - Bare JSON without prefix (some implementations)
    static func decodeTask(from scanned: String) -> ImportedTask? {
        var payload = scanned.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unwrap URL-shaped QR payloads. Three cases handled:
        //
        //   1. xctsk://<url-safe-base64(XCTSK:<json>)>  ← what we
        //      emit now. Standard scheme that XCTrack and Flyskyhy
        //      also register, so iOS Camera offers a chooser sheet.
        //
        //   2. xctsk://<raw-payload>  ← what other XCTrack-compatible
        //      apps may emit (some encode straight-to-base64 without
        //      the inner XCTSK: prefix; others use compressed forms).
        //
        //   3. variotb://task?data=<url-safe-base64(XCTSK:<json>)>
        //      ← legacy from earlier builds. Kept so old QR codes
        //      pilots have around still scan successfully.
        //
        // After unwrapping, `payload` is either an `XCTSK:` / `XCTSKZ:`
        // string or a bare JSON document, and the rest of decodeTask
        // continues from there.
        let lower = payload.lowercased()
        if lower.hasPrefix("xctsk://") {
            let body = String(payload.dropFirst("xctsk://".count))
            payload = unwrapURLSafeBase64XCTSK(body) ?? body
        } else if lower.hasPrefix("xctsk:") && !lower.hasPrefix("xctskz:") {
            // `xctsk:<body>` — colon form (no slashes). Some apps emit
            // this. Treat the body as either base64-wrapped XCTSK or a
            // raw payload depending on what decodes.
            let body = String(payload.dropFirst("xctsk:".count))
            payload = unwrapURLSafeBase64XCTSK(body) ?? ("XCTSK:" + body)
        } else if lower.hasPrefix("variotb://task?data=") {
            let body = String(payload.dropFirst("variotb://task?data=".count))
            payload = unwrapURLSafeBase64XCTSK(body) ?? body
        }

        // XCTSKZ: zlib+base64 decompression
        if payload.hasPrefix("XCTSKZ:") {
            let b64 = String(payload.dropFirst("XCTSKZ:".count))
            guard let decompressed = decompressBase64Zlib(b64) else { return nil }
            payload = decompressed
            // The inner payload may still have an "XCTSK:" prefix or be raw JSON
            if payload.hasPrefix("XCTSK:") {
                payload = String(payload.dropFirst("XCTSK:".count))
            }
        } else if payload.hasPrefix("XCTSK:") {
            payload = String(payload.dropFirst("XCTSK:".count))
        }

        guard let data = payload.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Detect format
        // v1: {"taskType":"CLASSIC","version":1,"turnpoints":[...]}
        // v2: {"taskType":"CLASSIC","version":2,"t":[{"z":...}]}
        // XC Waypoints v2: {"T":"W","V":2,"t":[{"z":...,"n":...}]}

        // Extract timing (sss start / goal deadline) — applies to both v1 and v2
        let sssTime = parseSSSTime(from: root)
        let deadline = parseDeadline(from: root)

        // XC Waypoints v2
        if let T = root["T"] as? String, T == "W",
           let tpsV2 = root["t"] as? [[String: Any]] {
            return decodeV2Turnpoints(tpsV2,
                                      isWaypointsOnly: true,
                                      rootName: "Waypoints",
                                      sssStartTime: nil,
                                      taskDeadline: nil)
        }

        // Competition v2
        if let version = root["version"] as? Int, version == 2,
           let tpsV2 = root["t"] as? [[String: Any]] {
            return decodeV2Turnpoints(tpsV2,
                                      isWaypointsOnly: false,
                                      rootName: "XCTrack Task",
                                      sssStartTime: sssTime,
                                      taskDeadline: deadline)
        }

        // Competition v1 (long form)
        if let tps = root["turnpoints"] as? [[String: Any]] {
            return decodeV1Turnpoints(tps,
                                      rootName: "XCTrack Task",
                                      sssStartTime: sssTime,
                                      taskDeadline: deadline)
        }

        return nil
    }

    // MARK: - Timing parsers

    /// Extracts the SSS open time from either v1 or v2 root object.
    /// v1: root["sss"]["timeGates"][0] as "HH:MM:SSZ"
    /// v2: root["s"]["g"][0] as "HH:MM:SSZ"
    private static func parseSSSTime(from root: [String: Any]) -> Date? {
        // v1
        if let sss = root["sss"] as? [String: Any],
           let gates = sss["timeGates"] as? [String],
           let first = gates.first {
            return parseXCTrackTime(first)
        }
        // v2
        if let s = root["s"] as? [String: Any],
           let gates = s["g"] as? [String],
           let first = gates.first {
            return parseXCTrackTime(first)
        }
        return nil
    }

    /// Extracts the task deadline from either v1 or v2 root object.
    private static func parseDeadline(from root: [String: Any]) -> Date? {
        if let goal = root["goal"] as? [String: Any],
           let dl = goal["deadline"] as? String {
            return parseXCTrackTime(dl)
        }
        if let g = root["g"] as? [String: Any],
           let dl = g["d"] as? String {
            return parseXCTrackTime(dl)
        }
        return nil
    }

    /// Parse a "HH:MM:SSZ" UTC time into a Date on *today's* date.
    /// XCTrack stores only time-of-day because the task date is implicit
    /// (today). We combine with today's UTC date so the resulting Date is
    /// meaningful for SwiftUI's DatePicker.
    private static func parseXCTrackTime(_ str: String) -> Date? {
        let clean = str.hasSuffix("Z") ? String(str.dropLast()) : str
        let parts = clean.split(separator: ":").map(String.init)
        guard parts.count >= 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]) else { return nil }
        let ss = parts.count >= 3 ? Int(parts[2]) ?? 0 : 0

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let todayUTC = cal.dateComponents([.year, .month, .day], from: Date())
        var comp = DateComponents()
        comp.year = todayUTC.year
        comp.month = todayUTC.month
        comp.day = todayUTC.day
        comp.hour = hh
        comp.minute = mm
        comp.second = ss
        comp.timeZone = TimeZone(identifier: "UTC")
        return cal.date(from: comp)
    }

    // MARK: - V1 decoder

    private static func decodeV1Turnpoints(_ tps: [[String: Any]],
                                           rootName: String,
                                           sssStartTime: Date?,
                                           taskDeadline: Date?) -> ImportedTask? {
        var waypoints: [Waypoint] = []
        var specs: [ImportedTurnpointSpec] = []
        for tp in tps {
            guard let wp = tp["waypoint"] as? [String: Any],
                  let name = wp["name"] as? String,
                  let lat = (wp["lat"] as? Double) ?? (wp["lat"] as? Int).map(Double.init),
                  let lon = (wp["lon"] as? Double) ?? (wp["lon"] as? Int).map(Double.init)
            else { continue }
            let alt = (wp["altSmoothed"] as? Double)
                   ?? (wp["altitude"] as? Double)
                   ?? (wp["alt"] as? Double)
                   ?? 0
            waypoints.append(Waypoint(name: name,
                                      latitude: lat,
                                      longitude: lon,
                                      altitudeM: alt))
            let typeRaw = (tp["type"] as? String) ?? ""
            let tpType: TurnpointType
            switch typeRaw.uppercased() {
            case "TAKEOFF": tpType = .takeoff
            case "SSS":     tpType = .sss
            case "ESS":     tpType = .ess
            case "GOAL":    tpType = .goal
            default:        tpType = .turn
            }
            let radius = (tp["radius"] as? Double)
                      ?? Double((tp["radius"] as? Int) ?? 400)
            specs.append(ImportedTurnpointSpec(
                waypointIndex: waypoints.count - 1,
                type: tpType,
                radiusM: radius))
        }
        guard !waypoints.isEmpty else { return nil }
        return ImportedTask(name: rootName,
                            waypoints: waypoints,
                            turnpointSpecs: specs,
                            sssStartTime: sssStartTime,
                            taskDeadline: taskDeadline)
    }

    // MARK: - V2 decoder

    /// V2 format stores each turnpoint as {"z": <polyline>, "n": "name", "t": 2|3, ...}
    /// where "z" encodes (lon, lat, altitude, radius) using Google polyline algorithm.
    /// For XC Waypoints tasks, only (lon, lat, altitude) is encoded and there's no radius.
    ///
    /// XCTrack's actual encoding is ambiguous from spec alone. Reading XCTrack sources
    /// and empirical decoding, the value order in the polyline is:
    ///   longitude, latitude, altitude, radius
    /// with precision 1e5 for lon/lat (standard Google polyline) and 1e0 for alt/radius.
    private static func decodeV2Turnpoints(_ tps: [[String: Any]],
                                           isWaypointsOnly: Bool,
                                           rootName: String,
                                           sssStartTime: Date?,
                                           taskDeadline: Date?) -> ImportedTask? {
        var waypoints: [Waypoint] = []
        var specs: [ImportedTurnpointSpec] = []
        let defaultRadius: Double = isWaypointsOnly ? 400 : 400

        for (idx, tp) in tps.enumerated() {
            guard let z = tp["z"] as? String else { continue }
            let decoded = decodePolyline(z)
            guard decoded.count >= 2 else { continue }
            let lon = decoded[0]
            let lat = decoded[1]
            let alt = decoded.count > 2 ? decoded[2] : 0
            let radius: Double
            if isWaypointsOnly {
                radius = defaultRadius
            } else {
                radius = decoded.count > 3 ? decoded[3] : defaultRadius
            }
            let name = (tp["n"] as? String) ?? "TP\(waypoints.count + 1)"
            waypoints.append(Waypoint(name: name,
                                      latitude: lat,
                                      longitude: lon,
                                      altitudeM: alt))
            // Type mapping for v2: "t":2 = SSS, "t":3 = ESS.
            // Otherwise infer from position: first TP = takeoff (convention),
            // last TP = goal, middle = turn. Post-processing below fixes the
            // "last is goal" rule for cases where ESS is actually the final TP.
            let tpType: TurnpointType
            if isWaypointsOnly {
                tpType = .turn
            } else {
                let tNum = (tp["t"] as? Int) ?? 0
                switch tNum {
                case 2: tpType = .sss
                case 3: tpType = .ess
                default:
                    if idx == 0 { tpType = .takeoff }
                    else if idx == tps.count - 1 { tpType = .goal }
                    else { tpType = .turn }
                }
            }
            specs.append(ImportedTurnpointSpec(
                waypointIndex: waypoints.count - 1,
                type: tpType,
                radiusM: radius))
        }

        // V2 "last turnpoint is always goal" rule — mark final TP as .goal if
        // it wasn't tagged as ESS. Keeps parity with the spec.
        if !isWaypointsOnly, !specs.isEmpty {
            let lastIdx = specs.count - 1
            if specs[lastIdx].type == .turn {
                specs[lastIdx] = ImportedTurnpointSpec(
                    waypointIndex: specs[lastIdx].waypointIndex,
                    type: .goal,
                    radiusM: specs[lastIdx].radiusM)
            }
        }

        guard !waypoints.isEmpty else { return nil }
        return ImportedTask(name: rootName,
                            waypoints: waypoints,
                            turnpointSpecs: specs,
                            sssStartTime: sssStartTime,
                            taskDeadline: taskDeadline)
    }

    // MARK: - Polyline decoder (XCTrack flavor)
    //
    // Per go-xctrack reference implementation
    // (https://github.com/twpayne/go-xctrack/blob/master/qrcodetask.go):
    //
    //   MarshalJSON encodes 4 integers for each turnpoint using
    //   polyline.EncodeInt (from twpayne/go-polyline), appended sequentially:
    //       round(1e5 * lon), round(1e5 * lat), alt (meters), radius (meters)
    //
    // Crucially, polyline.EncodeInt encodes ONE signed integer with the
    // Google polyline varint + zigzag scheme — there is NO delta-chaining,
    // no accumulator. The 4 integers are simply concatenated as independent
    // varints. Our decoder walks through varints one at a time.
    //
    // Scaling after decode:
    //   • index 0 (lon) and 1 (lat): divide by 1e5 to get degrees
    //   • index 2 (alt) and 3 (radius): use as-is (integer meters)
    //
    // For XC Waypoints (3-value form): lon, lat, alt. Radius defaults to 400m.

    private static func decodePolyline(_ encoded: String) -> [Double] {
        let bytes = Array(encoded.utf8)
        var index = 0
        var result: [Double] = []
        var valueIndex = 0

        while index < bytes.count {
            var shift = 0
            var acc: Int = 0
            var completed = false
            while index < bytes.count {
                let b = Int(bytes[index]) - 63
                index += 1
                guard b >= 0 else { return result }
                acc |= (b & 0x1F) << shift
                if b < 0x20 {
                    completed = true
                    break
                }
                shift += 5
                if shift > 60 { break } // safety
            }
            guard completed else { break }
            // Zigzag decode
            let signed = (acc & 1) != 0 ? ~(acc >> 1) : (acc >> 1)
            // Scale by position: 0=lon, 1=lat get /1e5; 2=alt, 3=radius raw
            let scaled: Double
            switch valueIndex {
            case 0, 1: scaled = Double(signed) / 1e5
            default:   scaled = Double(signed)
            }
            result.append(scaled)
            valueIndex += 1
        }
        return result
    }

    // MARK: - Zlib decompression for XCTSKZ

    /// Decode a URL-safe base64 string into the original UTF-8 text it
    /// was encoded from. Returns nil if the input doesn't decode to
    /// valid UTF-8 — caller falls back to treating the body as a
    /// pre-decoded payload.
    ///
    /// Used to unwrap our own QR emit format (`xctsk://<b64>` and
    /// the legacy `variotb://task?data=<b64>`) where the body is a
    /// URL-safe base64 of an `XCTSK:<json>` string.
    private static func unwrapURLSafeBase64XCTSK(_ body: String) -> String? {
        let standard = body
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = standard + String(repeating: "=",
                                       count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: padded),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Decompress a base64-encoded zlib stream into a UTF-8 string.
    /// Uses the Compression framework with the `.zlib` algorithm, which
    /// corresponds to RFC 1950 (zlib wrapper around raw deflate).
    private static func decompressBase64Zlib(_ b64: String) -> String? {
        guard let data = Data(base64Encoded: b64) else { return nil }

        // Compression.zlib in Apple's framework is raw DEFLATE (RFC 1951),
        // not the 2-byte-header zlib wrapper. So we need to strip the zlib
        // wrapper ourselves: first 2 bytes are zlib header, last 4 bytes are
        // Adler32 checksum.
        guard data.count >= 6 else { return nil }
        let raw = data.subdata(in: 2..<(data.count - 4))

        // Allocate a decompression buffer. Start at 16× the input size (reasonable
        // upper bound for JSON text), grow if needed. Max 1 MB is more than
        // enough for any paragliding task QR.
        let bufferSize = max(4096, raw.count * 16)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        let decompressedSize = raw.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> Int in
            guard let base = ptr.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_decode_buffer(buffer, bufferSize,
                                             base, raw.count,
                                             nil,
                                             COMPRESSION_ZLIB)
        }
        guard decompressedSize > 0 else { return nil }
        return String(bytes: UnsafeBufferPointer(start: buffer,
                                                 count: decompressedSize),
                      encoding: .utf8)
    }
}
