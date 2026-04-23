import Foundation
import CoreLocation

/// IGC (International Gliding Commission) flight recorder.
///
/// Records GPS fixes as B-records per the FAI IGC spec. The result is a
/// plain-text `.igc` file that can be opened by XCSoar, SeeYou, XContest,
/// and every paragliding flight analysis tool.
///
/// Reference: https://www.fai.org/sites/default/files/igc_fr_specification_2020-11-25_with_al6.pdf
final class IGCRecorder {
    private(set) var isRecording: Bool = false
    private(set) var fileURL: URL?
    private var writer: FileHandle?
    private var startDate: Date?
    private var simulated: Bool = false

    private let pilotName: String
    private let gliderType: String
    private let gliderID: String

    init(pilotName: String = "tbiliyor",
         gliderType: String = "Paraglider",
         gliderID: String = "VarioTB") {
        self.pilotName = pilotName
        self.gliderType = gliderType
        self.gliderID = gliderID
    }

    // MARK: - Lifecycle

    func start(simulated: Bool = false) {
        guard !isRecording else { return }
        let date = Date()
        startDate = date

        // File: Flights/YYYY-MM-DD_HHMMSS[_SIM].igc
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("Flights", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let suffix = simulated ? "_SIM" : ""
        let filename = "\(formatter.string(from: date))\(suffix).igc"
        let url = dir.appendingPathComponent(filename)

        fm.createFile(atPath: url.path, contents: nil, attributes: nil)
        guard let wh = try? FileHandle(forWritingTo: url) else {
            print("IGC: cannot open file for writing at \(url.path)")
            return
        }
        writer = wh
        fileURL = url
        self.simulated = simulated

        writeHeader(date: date)
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        writer?.closeFile()
        writer = nil
        isRecording = false
    }

    // MARK: - Records

    /// Append a B-record (GPS fix). Should be called ~1 Hz.
    func appendFix(coordinate: CLLocationCoordinate2D,
                   pressureAltitudeM: Double,
                   gpsAltitudeM: Double,
                   date: Date = Date()) {
        guard isRecording, let wh = writer else { return }

        let cal = Calendar(identifier: .gregorian)
        var comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let hh = String(format: "%02d", comps.hour ?? 0)
        let mm = String(format: "%02d", comps.minute ?? 0)
        let ss = String(format: "%02d", comps.second ?? 0)

        // Latitude: DDMMmmmN / DDMMmmmS  (DD degrees, MMmmm = minutes × 1000)
        let latStr = igcLatLon(coordinate.latitude, isLat: true)
        let lonStr = igcLatLon(coordinate.longitude, isLat: false)

        // Pressure altitude (5 digits, signed zero-padded)
        let pressAlt = String(format: "%05d", max(0, min(99999, Int(pressureAltitudeM))))
        let gpsAlt   = String(format: "%05d", max(0, min(99999, Int(gpsAltitudeM))))

        // B record: B HHMMSS DDMMmmmN DDDMMmmmE A PPPPP GGGGG
        let line = "B\(hh)\(mm)\(ss)\(latStr)\(lonStr)A\(pressAlt)\(gpsAlt)\r\n"
        if let data = line.data(using: .ascii) {
            wh.write(data)
        }
    }

    // MARK: - Header

    private func writeHeader(date: Date) {
        guard let wh = writer else { return }
        var header = ""

        // A-record: Manufacturer + logger ID + pilot initials
        // "A" + 3-letter manufacturer code + 3-char unique ID + optional text
        header += "AXVT001 Vario TB Flight Recorder\r\n"

        // H-records (header)
        let cal = Calendar(identifier: .gregorian)
        let comps = cal.dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        let dd = String(format: "%02d", comps.day ?? 0)
        let mo = String(format: "%02d", comps.month ?? 0)
        let yy = String(format: "%02d", (comps.year ?? 2000) % 100)
        header += "HFDTE\(dd)\(mo)\(yy)\r\n"                    // flight date
        header += "HFPLTPILOTINCHARGE:\(pilotName)\r\n"
        header += "HFGTYGLIDERTYPE:\(gliderType)\r\n"
        header += "HFGIDGLIDERID:\(gliderID)\r\n"
        header += "HFDTMGPSDATUM:WGS-1984\r\n"
        header += "HFRFWFIRMWAREVERSION:1.0.0\r\n"
        header += "HFRHWHARDWAREVERSION:iPhone\r\n"
        header += "HFFTYFRTYPE:Vario TB iOS\r\n"
        header += "HFGPSRECEIVER:iPhone GPS\r\n"
        header += "HFPRSPRESSALTSENSOR:CMAltimeter\r\n"
        header += "HFCIDCOMPETITIONID:\r\n"
        header += "HFCCLCOMPETITIONCLASS:Paragliding\r\n"
        if simulated {
            // L-record = free text comment. Clearly marks this as simulated.
            header += "LXVTSIMULATED FLIGHT - SYNTHETIC DATA\r\n"
        }

        if let data = header.data(using: .ascii) {
            wh.write(data)
        }
    }

    // MARK: - Coordinate formatting

    /// Convert decimal degrees to IGC format.
    /// Latitude:  DDMMmmmN  (2-digit deg, 2-digit min, 3-digit min-decimal, hemisphere)
    /// Longitude: DDDMMmmmE (3-digit deg, 2-digit min, 3-digit min-decimal, hemisphere)
    private func igcLatLon(_ value: Double, isLat: Bool) -> String {
        let abs = Swift.abs(value)
        let deg = Int(abs)
        let minTotal = (abs - Double(deg)) * 60.0
        let min = Int(minTotal)
        let minDecimal = Int(((minTotal - Double(min)) * 1000).rounded())
        let hemi: String
        if isLat {
            hemi = value >= 0 ? "N" : "S"
            return String(format: "%02d%02d%03d%@", deg, min, minDecimal, hemi)
        } else {
            hemi = value >= 0 ? "E" : "W"
            return String(format: "%03d%02d%03d%@", deg, min, minDecimal, hemi)
        }
    }
}
