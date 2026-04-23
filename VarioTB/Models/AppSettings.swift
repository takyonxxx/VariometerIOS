import Foundation
import SwiftUI

enum CoordinateFormat: String, CaseIterable, Identifiable {
    case decimal = "DD.DDDDD°"
    case dms     = "DD° MM' SS\""
    case dm      = "DD° MM.MMM'"
    case utm     = "UTM"
    case mgrs    = "MGRS"
    var id: String { rawValue }
}

enum SoundMode: String, CaseIterable, Identifiable {
    case procedural = "Sentez (Procedural)"
    case sample     = "Örnek (Sample)"
    var id: String { rawValue }
}

/// Aviation-appropriate background themes (used when satellite map is off).
/// Named colors evoke aviation instrument panels.
enum BackgroundTheme: String, CaseIterable, Identifiable {
    case cockpitBlack    = "Kokpit Siyahı"
    case instrumentNavy  = "Enstrüman Lacivert"
    case nightAviation   = "Gece Uçuş (Koyu Mavi)"
    case avionicsDark    = "Avionics Koyu Yeşil"
    case dawnSlate       = "Şafak Arduvaz"
    case sunsetCharcoal  = "Gün Batımı Antrasit"

    var id: String { rawValue }

    /// Returns a gradient (top to bottom) for this theme.
    var gradient: [Color] {
        switch self {
        case .cockpitBlack:
            return [Color(red: 0.04, green: 0.04, blue: 0.05),
                    Color(red: 0.02, green: 0.02, blue: 0.03)]
        case .instrumentNavy:
            return [Color(red: 0.06, green: 0.10, blue: 0.18),
                    Color(red: 0.03, green: 0.05, blue: 0.10)]
        case .nightAviation:
            return [Color(red: 0.05, green: 0.08, blue: 0.22),
                    Color(red: 0.02, green: 0.03, blue: 0.10)]
        case .avionicsDark:
            return [Color(red: 0.04, green: 0.09, blue: 0.08),
                    Color(red: 0.01, green: 0.04, blue: 0.03)]
        case .dawnSlate:
            return [Color(red: 0.14, green: 0.16, blue: 0.20),
                    Color(red: 0.06, green: 0.07, blue: 0.10)]
        case .sunsetCharcoal:
            return [Color(red: 0.13, green: 0.11, blue: 0.10),
                    Color(red: 0.05, green: 0.04, blue: 0.04)]
        }
    }
}

enum GliderCertification: String, CaseIterable, Identifiable {
    case none  = "-"
    case enA   = "EN A"
    case enB   = "EN B"
    case enC   = "EN C"
    case enD   = "EN D"
    case cccc  = "CCC"
    var id: String { rawValue }
}

enum GliderType: String, CaseIterable, Identifiable {
    case paraglider = "Paraglider"
    case hangGlider = "Hang Glider"
    case glider     = "Glider / Planör"
    case paramotor  = "Paramotor"
    var id: String { rawValue }
}

final class AppSettings: ObservableObject {
    // Damper is now fixed at 1 (bypass) — removed from UI per design.
    // Regression window handles smoothing.
    var damperLevel: Int { 1 }

    @AppStorage("soundEnabled")       var soundEnabled: Bool = true
    @AppStorage("soundVolume")        var soundVolume: Double = 0.8
    @AppStorage("soundMode")          var soundModeRaw: String = SoundMode.procedural.rawValue
    @AppStorage("climbThreshold")     var climbThreshold: Double = 0.1
    @AppStorage("sinkThreshold")      var sinkThreshold: Double = -2.0
    @AppStorage("basePitchHz")        var basePitchHz: Double = 500
    @AppStorage("maxPitchHz")         var maxPitchHz: Double = 1600
    @AppStorage("coordFormat")        var coordFormatRaw: String = CoordinateFormat.decimal.rawValue
    @AppStorage("useBarometer")       var useBarometer: Bool = true
    @AppStorage("thermalMemoryRadiusM") var thermalMemoryRadiusM: Double = 1500

    // Map & background
    @AppStorage("showMapBackground")  var showMapBackground: Bool = false
    @AppStorage("backgroundTheme")    var backgroundThemeRaw: String = BackgroundTheme.nightAviation.rawValue

    // Pilot info (used in IGC header and live-tracking)
    @AppStorage("pilotFirstName")     var pilotFirstName: String = ""
    @AppStorage("pilotLastName")      var pilotLastName: String = ""
    @AppStorage("gliderBrandModel")   var gliderBrandModel: String = ""
    @AppStorage("gliderCertification") var gliderCertificationRaw: String = GliderCertification.none.rawValue
    @AppStorage("gliderType")          var gliderTypeRaw: String = GliderType.paraglider.rawValue

    // LiveTrack24 live tracking
    // Keep old @AppStorage key names ("xcontestUsername" etc.) so existing
    // installs don't lose saved credentials on upgrade. The values are
    // used as LiveTrack24 credentials now.
    @AppStorage("xcontestUsername")   var liveTrackUsername: String = ""
    @AppStorage("xcontestLiveEnabled") var liveTrackEnabled: Bool = false
    // Password is stored in Keychain (not AppStorage), see KeychainStore.

    var soundMode: SoundMode {
        get { SoundMode(rawValue: soundModeRaw) ?? .procedural }
        set { soundModeRaw = newValue.rawValue }
    }
    var coordFormat: CoordinateFormat {
        get { CoordinateFormat(rawValue: coordFormatRaw) ?? .decimal }
        set { coordFormatRaw = newValue.rawValue }
    }
    var backgroundTheme: BackgroundTheme {
        get { BackgroundTheme(rawValue: backgroundThemeRaw) ?? .instrumentNavy }
        set { backgroundThemeRaw = newValue.rawValue }
    }
    var gliderCertification: GliderCertification {
        get { GliderCertification(rawValue: gliderCertificationRaw) ?? .none }
        set { gliderCertificationRaw = newValue.rawValue }
    }
    var gliderType: GliderType {
        get { GliderType(rawValue: gliderTypeRaw) ?? .paraglider }
        set { gliderTypeRaw = newValue.rawValue }
    }

    /// Convenience: full pilot name for IGC headers.
    var pilotFullName: String {
        let combined = "\(pilotFirstName) \(pilotLastName)".trimmingCharacters(in: .whitespaces)
        return combined.isEmpty ? "tbiliyor" : combined
    }
}
