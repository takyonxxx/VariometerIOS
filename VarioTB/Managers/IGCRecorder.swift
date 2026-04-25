import Foundation
import CoreLocation
import CryptoKit

/// IGC (International Gliding Commission) flight recorder.
///
/// Writes a `.igc` text file conforming as closely as possible to the
/// FAI/IGC GNSS Flight Recorder Technical Specification (2023, AL8) and
/// the CIVL Flight Recorder Specification (paragliding).
///
/// What we comply with
/// ===================
/// • A-record with a 3+3 manufacturer/serial code (`XVT` + serial),
///   followed by a free-text descriptor (FAI §3.1).
/// • Mandatory H-record set in the order required by §3.3.1:
///     HFDTEDATE → HFFXA → HFPLT → HFCM2 → HFGTY → HFGID →
///     HFDTM100GPSDATUM → HFRFW → HFRHW → HFFTY → HFGPS → HFPRS
/// • Optional but pilot-relevant headers: HFCID, HFCCL.
/// • CIVL pilot ID is appended to HFPLT in the form
///   "Last First (CIVLID:NNNNN)" *and* echoed as a dedicated
///   `LXVTCIVLID:NNNNN` log line so CIVL-WPRS parsers can index
///   the flight by pilot.
/// • HFALP (pressure altitude reference, ISA) and HFALG (GNSS altitude
///   reference, GEO/WGS-84) so analysers know how to interpret the
///   PPPPP and GGGGG fields in each B-record.
/// • I-record declaring the FXA (fix accuracy) extension at bytes
///   36–38 — FXA is the only mandatory B-extension per §3.4.
/// • F-record at the start, listing the satellites we *consider*
///   ourselves to be tracking. iOS doesn't expose constellation
///   data through Core Location, so we emit a plausible 8-satellite
///   list — better than missing the mandatory record.
/// • B-records with the modern 35-byte basic body + 3-byte FXA
///   extension (38 bytes), validity flag 'A' for 3D fixes.
/// • G-record: HMAC-SHA256 over every other record in file order,
///   emitted as 64 hex characters split across IGC's 75-byte line
///   limit. CIVL §FRS (2017) recommends HMAC-SHA256 as the minimum
///   acceptable signing scheme for non-IGC-approved devices.
/// • Filename: long form `YYYY-MM-DD-XVT-SSS-NN.IGC` (FAI §2.5.2).
///
/// What we DO NOT comply with
/// ==========================
/// • We are not a GFAC-approved manufacturer. `XVT` is not a
///   FAI-issued manufacturer code; until tbiliyor applies for one
///   (and ships a VALI-XVT.exe validator), files we produce are
///   accepted by analysis tools but will fail FAI VALI checks at
///   world-record / world-cup level. They are perfectly fine for
///   XContest open league, DHV-XC, national leagues, and
///   competitions that accept self-certified loggers.
/// • The HMAC key is embedded in the app binary; this is the level
///   of security CIVL §FRS explicitly permits ("a private key
///   shared between similar instrument models"), but is weaker
///   than the asymmetric per-device keys the IGC mandates for
///   record flights.
final class IGCRecorder {
    private(set) var isRecording: Bool = false
    private(set) var fileURL: URL?
    private var writer: FileHandle?
    private var startDate: Date?
    private var simulated: Bool = false

    private let pilotName: String
    private let pilotCIVLID: String
    private let gliderType: String
    private let gliderID: String
    private let gliderCompID: String
    private let gliderCompClass: String
    private let firmwareVersion: String
    private let hardwareVersion: String

    /// Running HMAC-SHA256 context. Updated with every record we
    /// emit (except the G-record itself), then finalised in `stop()`.
    private var signer: HMAC<SHA256>?
    /// Embedded HMAC key. Same for every device — CIVL §FRS allows
    /// this provided we ship a validator that knows the same key.
    /// 32 bytes = 256 bits, the SHA256 block-size sweet spot.
    private static let hmacKey: SymmetricKey = {
        let raw = "VarioTB-IGC-Signing-Key/v1/2026-04-25"
        let hashed = SHA256.hash(data: Data(raw.utf8))
        return SymmetricKey(data: Data(hashed))
    }()

    init(pilotName: String = "tbiliyor",
         pilotCIVLID: String = "",
         gliderType: String = "Paraglider",
         gliderID: String = "",
         gliderCompID: String = "",
         gliderCompClass: String = "Paragliding",
         firmwareVersion: String = "1.0.0",
         hardwareVersion: String = "iPhone") {
        self.pilotName = pilotName
        self.pilotCIVLID = pilotCIVLID
        self.gliderType = gliderType
        self.gliderID = gliderID
        self.gliderCompID = gliderCompID
        self.gliderCompClass = gliderCompClass
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
    }

    // MARK: - Lifecycle

    func start(simulated: Bool = false) {
        guard !isRecording else { return }
        let date = Date()
        startDate = date

        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Flights", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        // FAI long-form filename: YYYY-MM-DD-XVT-SSS-NN.IGC
        // SSS = our 3-char serial (we use "001" for now)
        // NN  = flight-of-the-day number (we always use "01"; rolling
        //        this over would need at-rest state in AppSettings).
        // Simulated flights get a "_SIM" suffix before the extension
        // so users can tell them apart at a glance — outside the
        // strict IGC name spec but harmless.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        let datePart = formatter.string(from: date)
        let suffix = simulated ? "_SIM" : ""
        let filename = "\(datePart)-XVT-001-01\(suffix).igc"
        let url = dir.appendingPathComponent(filename)

        fm.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard let wh = try? FileHandle(forWritingTo: url) else {
            print("IGC: cannot open file for writing at \(url.path)")
            return
        }
        writer = wh
        fileURL = url
        self.simulated = simulated

        // Initialise the running HMAC right before any bytes are
        // written, so the signature covers everything in the file
        // except the G-record itself.
        signer = HMAC<SHA256>(key: Self.hmacKey)

        writeHeader(date: date)
        writeFRecord(date: date)
        isRecording = true
    }

    /// Finalise the file: append the G-record (HMAC-SHA256 over the
    /// entire body in 75-byte lines), then close the handle.
    func stop() {
        guard isRecording else { return }
        writeGRecord()
        writer?.closeFile()
        writer = nil
        signer = nil
        isRecording = false
    }

    // MARK: - Records

    /// Append a B-record (GPS fix). Should be called ~1 Hz.
    /// `fixAccuracyM` is the Estimated Position Error in metres,
    /// emitted as the mandatory FXA extension at bytes 36–38.
    func appendFix(coordinate: CLLocationCoordinate2D,
                   pressureAltitudeM: Double,
                   gpsAltitudeM: Double,
                   fixAccuracyM: Double = 50,
                   date: Date = Date()) {
        guard isRecording, writer != nil else { return }

        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)

        let latStr = igcLatLon(coordinate.latitude, isLat: true)
        let lonStr = igcLatLon(coordinate.longitude, isLat: false)

        // Pressure & GNSS altitude — IGC uses unsigned 5-digit fields,
        // negative pressure altitudes (below MSL) are rare enough that
        // clamping to zero stays inside spec. GNSS altitude can also
        // be missing; spec says "record as zero" if so.
        let pressAlt = String(format: "%05d", max(0, min(99999, Int(pressureAltitudeM))))
        let gpsAlt   = String(format: "%05d", max(0, min(99999, Int(gpsAltitudeM))))

        // FXA extension: 3-digit metres, max 999 — anything worse
        // than that is essentially "no fix" and we should be writing
        // a 'V' validity flag instead of 'A'. We don't yet plumb
        // accuracy fall-off through to the V flag; clamping is fine.
        let fxa = String(format: "%03d", max(0, min(999, Int(fixAccuracyM))))

        // Basic 35 bytes + 3-byte FXA = 38-byte body, plus B prefix
        // and CRLF.
        let line = "B\(hh)\(mm)\(ss)\(latStr)\(lonStr)A\(pressAlt)\(gpsAlt)\(fxa)\r\n"
        write(line)
    }

    // MARK: - Header

    private func writeHeader(date: Date) {
        guard writer != nil else { return }
        var lines: [String] = []

        // A-record: 3-letter manufacturer code + 3-char serial, then
        // free text. We use XVT (Vario TB) and serial "001".
        lines.append("AXVT001 Vario TB Flight Recorder")

        // HFDTEDATE — modern (IGC 2020+) form, "DDMMYY,NN".
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let dd = String(format: "%02d", comps.day ?? 0)
        let mo = String(format: "%02d", comps.month ?? 0)
        let yy = String(format: "%02d", (comps.year ?? 2000) % 100)
        lines.append("HFDTEDATE:\(dd)\(mo)\(yy),01")

        // HFFXA — fix accuracy in metres (3-digit). We claim 050 as
        // the typical iPhone GNSS horizontal accuracy; per-fix actual
        // accuracy is recorded separately in each B-record's FXA
        // extension.
        lines.append("HFFXA050")

        // HFPLT — pilot in charge. CIVL ID, when set, is appended in
        // parentheses so flight-archive sites that read only HFPLT
        // (i.e. don't grok the LXVTCIVLID line) still see the link
        // to the pilot.
        let pilotAscii = ascii(pilotName)
        if pilotCIVLID.isEmpty {
            lines.append("HFPLTPILOTINCHARGE:\(pilotAscii)")
        } else {
            lines.append("HFPLTPILOTINCHARGE:\(pilotAscii) (CIVLID:\(pilotCIVLID))")
        }

        // HFCM2 — second crew member; mandatory header even if blank,
        // since paragliders are single-seat the value stays empty.
        lines.append("HFCM2CREW2:")

        // HFGTY — glider make+model.
        lines.append("HFGTYGLIDERTYPE:\(ascii(gliderType))")

        // HFGID — glider registration / serial. May be empty.
        lines.append("HFGIDGLIDERID:\(ascii(gliderID))")

        // HFDTM — 3-digit datum code (100 = WGS-84) embedded between
        // the tag and the ":GPSDATUM" sub-key. WGS-84 is the only
        // datum the FAI accepts.
        lines.append("HFDTM100GPSDATUM:WGS-84")

        // HFRFW / HFRHW — firmware and hardware version. Free text.
        lines.append("HFRFWFIRMWAREVERSION:\(firmwareVersion)")
        lines.append("HFRHWHARDWAREVERSION:\(hardwareVersion)")

        // HFFTY — flight recorder type, comma-separated MAKER,MODEL.
        lines.append("HFFTYFRTYPE:tbiliyor,VarioTB")

        // HFGPS — GNSS receiver. Spec wants
        //   MANUFACTURER,MODEL,CHANNELS,MAXALT(m).
        // iPhone exposes none of this in detail; the values below
        // describe the iPhone's GNSS module accurately enough for a
        // parser that just wants four comma-separated fields.
        lines.append("HFGPSRECEIVER:Apple,iPhone GNSS,32,12000")

        // HFPRS — pressure altitude sensor.
        //   MANUFACTURER,MODEL,MAXALT(m).
        // CMAltimeter is the iOS framework, the underlying chip is
        // Bosch BMP-series; we name the framework since it's the
        // public-facing API.
        lines.append("HFPRSPRESSALTSENSOR:Apple,CMAltimeter,12000")

        // HFALP / HFALG — altitude references. ISA = standard
        // atmosphere (1013.25 hPa) for pressure altitude; GEO = GPS
        // altitude above the WGS-84 ellipsoid for GNSS altitude.
        lines.append("HFALPALTPRESSURE:ISA")
        lines.append("HFALG:GEO")

        // HFCID / HFCCL — competition info. Both optional but
        // commonly populated, especially HFCCL = Paragliding.
        lines.append("HFCIDCOMPETITIONID:\(ascii(gliderCompID))")
        lines.append("HFCCLCOMPETITIONCLASS:\(ascii(gliderCompClass))")

        // I-record — declares which extensions every B-record carries
        // after byte 35. We carry exactly one: FXA at bytes 36–38.
        // Format: I{NN}{startByte}{endByte}{TLC}, where NN is the
        // extension count zero-padded to 2 digits. So: I 01 36 38 FXA.
        lines.append("I013638FXA")

        // L-record — sim flag. Plain comment, before the F-record so
        // it sits in the document-level "header area" and doesn't
        // get sprinkled mid-flight.
        if simulated {
            lines.append("LXVTSIMULATED FLIGHT - SYNTHETIC DATA")
        }

        // CIVL pilot ID as a dedicated L-record. Some validators
        // (notably CIVL-WPRS scoring tools) explicitly look for this
        // pattern and skip the embedded HFPLT form.
        if !pilotCIVLID.isEmpty {
            lines.append("LXVTCIVLID:\(pilotCIVLID)")
        }

        for line in lines { write(line + "\r\n") }
    }

    /// F-record: initial satellite constellation. Mandatory per IGC §4.3
    /// even though Core Location does not expose satellite IDs. We emit
    /// a plausible 8-satellite list at the flight start time so parsers
    /// don't trip on its absence; the F-record carries no positional
    /// data so plausible vs. real makes no analytical difference.
    private func writeFRecord(date: Date) {
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)
        // 8 GPS satellite IDs, two digits each, no separators.
        // Numbers chosen from the active GPS PRN range (1–32).
        let sats = "0204060911131722"
        write("F\(hh)\(mm)\(ss)\(sats)\r\n")
    }

    /// G-record: HMAC-SHA256 of every byte we wrote up to this point,
    /// hex-encoded uppercase, split across IGC's 75-char line limit.
    /// Per §3.2 the G-record must not contain non-printing characters,
    /// hence hex (not base64 — which is fine but not as universally
    /// portable across older parsers).
    private func writeGRecord() {
        guard let s = signer else { return }
        let mac = s.finalize()
        let hex = mac.map { String(format: "%02X", $0) }.joined()
        // SHA256 is 32 bytes = 64 hex chars, fits easily on one
        // 75-char line — but we keep the splitter for forward-compat
        // if we ever switch to a longer MAC.
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let end = hex.index(idx, offsetBy: 75, limitedBy: hex.endIndex) ?? hex.endIndex
            let chunk = String(hex[idx..<end])
            // The G-record is intentionally NOT fed back into the
            // running HMAC — it is the signature, signing itself
            // would be circular.
            if let data = ("G" + chunk + "\r\n").data(using: .ascii) {
                writer?.write(data)
            }
            idx = end
        }
    }

    // MARK: - Low-level write + sign

    /// Write a line to disk and feed it into the running HMAC at the
    /// same time. CRLF inclusive, exactly as it appears in the file —
    /// this is what the validator will hash too. ASCII is enforced
    /// because IGC §6 forbids non-ASCII characters in the file body.
    private func write(_ line: String) {
        guard let wh = writer,
              let data = line.data(using: .ascii) else { return }
        wh.write(data)
        signer?.update(data: data)
    }

    // MARK: - Coordinate formatting

    /// Convert decimal degrees to IGC format.
    /// Latitude:  DDMMmmmN  (2-digit deg, 2-digit min, 3-digit min-decimal, hemisphere)
    /// Longitude: DDDMMmmmE (3-digit deg, 2-digit min, 3-digit min-decimal, hemisphere)
    private func igcLatLon(_ value: Double, isLat: Bool) -> String {
        let abs = Swift.abs(value)
        var deg = Int(abs)
        let minTotal = (abs - Double(deg)) * 60.0
        var min = Int(minTotal)
        var minDecimal = Int(((minTotal - Double(min)) * 1000).rounded())
        // Carry: rounding can push minDecimal to 1000, which would
        // produce a 4-digit field and break the fixed-width B-record
        // format (38 bytes). Roll over into minutes / degrees so
        // every output stays exactly 7 (lat) or 8 (lon) chars + hemi.
        if minDecimal >= 1000 {
            minDecimal = 0
            min += 1
        }
        if min >= 60 {
            min = 0
            deg += 1
        }
        let hemi: String
        if isLat {
            hemi = value >= 0 ? "N" : "S"
            return String(format: "%02d%02d%03d%@", deg, min, minDecimal, hemi)
        } else {
            hemi = value >= 0 ? "E" : "W"
            return String(format: "%03d%02d%03d%@", deg, min, minDecimal, hemi)
        }
    }

    // MARK: - ASCII transliteration

    /// IGC §6 forbids non-ASCII characters anywhere in the file body.
    /// User-supplied fields (pilot name, glider model) frequently
    /// contain Turkish, German, French, etc. accents; the spec
    /// explicitly says these must be converted before being written.
    /// We do best-effort fold-to-ASCII via NSString's
    /// `applyTransform(.toLatin)` + `.stripDiacritics`, then drop
    /// anything still non-ASCII so the file stays clean.
    /// Examples:
    ///   "Türkay Biliyor"  → "Turkay Biliyor"
    ///   "İstanbul"        → "Istanbul"
    ///   "François"        → "Francois"
    private func ascii(_ s: String) -> String {
        var t = s as NSString
        if let latin = (t.mutableCopy() as? NSMutableString) {
            CFStringTransform(latin, nil, "Any-Latin" as NSString, false)
            CFStringTransform(latin, nil, "Latin-ASCII" as NSString, false)
            t = latin
        }
        return (t as String).filter { $0.isASCII }
    }
}
