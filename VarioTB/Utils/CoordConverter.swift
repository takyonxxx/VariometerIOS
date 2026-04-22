import Foundation
import CoreLocation

enum CoordConverter {

    static func format(_ coord: CLLocationCoordinate2D, as fmt: CoordinateFormat) -> String {
        switch fmt {
        case .decimal:
            return String(format: "%.5f°, %.5f°", coord.latitude, coord.longitude)
        case .dms:
            return "\(dms(coord.latitude, isLat: true))  \(dms(coord.longitude, isLat: false))"
        case .dm:
            return "\(dm(coord.latitude, isLat: true))  \(dm(coord.longitude, isLat: false))"
        case .utm:
            return utmString(coord)
        case .mgrs:
            return mgrsString(coord)
        }
    }

    static func dms(_ d: Double, isLat: Bool) -> String {
        let hemi = isLat ? (d >= 0 ? "N" : "S") : (d >= 0 ? "E" : "W")
        let v = abs(d)
        let deg = Int(v)
        let mf = (v - Double(deg)) * 60
        let m = Int(mf)
        let s = (mf - Double(m)) * 60
        return String(format: "%d°%02d'%04.1f\"%@", deg, m, s, hemi)
    }

    static func dm(_ d: Double, isLat: Bool) -> String {
        let hemi = isLat ? (d >= 0 ? "N" : "S") : (d >= 0 ? "E" : "W")
        let v = abs(d)
        let deg = Int(v)
        let m = (v - Double(deg)) * 60
        return String(format: "%d°%06.3f'%@", deg, m, hemi)
    }

    // MARK: - UTM

    static func utmString(_ c: CLLocationCoordinate2D) -> String {
        let (zone, letter, e, n) = toUTM(lat: c.latitude, lon: c.longitude)
        return String(format: "%d%@ %.0fE %.0fN", zone, letter, e, n)
    }

    /// WGS84 -> UTM
    static func toUTM(lat: Double, lon: Double) -> (zone: Int, letter: String, easting: Double, northing: Double) {
        let a = 6378137.0
        let f = 1.0 / 298.257223563
        let k0 = 0.9996

        let zone = Int(floor((lon + 180.0) / 6.0)) + 1
        let lon0 = Double((zone - 1) * 6 - 180 + 3)   // central meridian
        let latRad = lat * .pi / 180.0
        let lonRad = lon * .pi / 180.0
        let lon0Rad = lon0 * .pi / 180.0

        let eSq = 2*f - f*f
        let ePrimeSq = eSq / (1 - eSq)
        let N = a / sqrt(1 - eSq * sin(latRad) * sin(latRad))
        let T = tan(latRad) * tan(latRad)
        let C = ePrimeSq * cos(latRad) * cos(latRad)
        let A = cos(latRad) * (lonRad - lon0Rad)

        let M = a * ((1 - eSq/4 - 3*eSq*eSq/64 - 5*eSq*eSq*eSq/256) * latRad
                   - (3*eSq/8 + 3*eSq*eSq/32 + 45*eSq*eSq*eSq/1024) * sin(2*latRad)
                   + (15*eSq*eSq/256 + 45*eSq*eSq*eSq/1024) * sin(4*latRad)
                   - (35*eSq*eSq*eSq/3072) * sin(6*latRad))

        var easting = k0 * N * (A + (1 - T + C) * pow(A,3)/6
                                  + (5 - 18*T + T*T + 72*C - 58*ePrimeSq) * pow(A,5)/120) + 500000.0
        var northing = k0 * (M + N * tan(latRad) * (A*A/2
                                  + (5 - T + 9*C + 4*C*C) * pow(A,4)/24
                                  + (61 - 58*T + T*T + 600*C - 330*ePrimeSq) * pow(A,6)/720))
        if lat < 0 { northing += 10000000.0 }

        let letter = utmLetter(lat: lat)
        _ = easting; _ = northing
        return (zone, letter, easting, northing)
    }

    static func utmLetter(lat: Double) -> String {
        let letters = "CDEFGHJKLMNPQRSTUVWXX"
        if lat < -80 || lat > 84 { return "Z" }
        let idx = Int(floor((lat + 80.0) / 8.0))
        let i = idx.clamped(to: 0...(letters.count - 1))
        let c = letters[letters.index(letters.startIndex, offsetBy: i)]
        return String(c)
    }

    // MARK: - MGRS (simplified)

    static func mgrsString(_ c: CLLocationCoordinate2D) -> String {
        let (zone, letter, e, n) = toUTM(lat: c.latitude, lon: c.longitude)
        // 100km square letters
        let eID = Int(floor(e / 100000.0))
        let nID = Int(floor(n / 100000.0)) % 20

        let colSet = ((zone - 1) % 3)
        let colLetters = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"][colSet]
        let rowLetters = ((zone % 2) == 1) ? "ABCDEFGHJKLMNPQRSTUV" : "FGHJKLMNPQRSTUVABCDE"

        let colIdx = (eID - 1).clamped(to: 0...(colLetters.count - 1))
        let rowIdx = nID.clamped(to: 0...(rowLetters.count - 1))
        let col = colLetters[colLetters.index(colLetters.startIndex, offsetBy: colIdx)]
        let row = rowLetters[rowLetters.index(rowLetters.startIndex, offsetBy: rowIdx)]

        let eRem = Int(e.truncatingRemainder(dividingBy: 100000))
        let nRem = Int(n.truncatingRemainder(dividingBy: 100000))
        return String(format: "%d%@ %@%@ %05d %05d", zone, letter, String(col), String(row), eRem, nRem)
    }
}
