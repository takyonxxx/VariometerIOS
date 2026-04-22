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

final class AppSettings: ObservableObject {
    @AppStorage("damperLevel")        var damperLevel: Int = 3          // 1..10
    @AppStorage("soundEnabled")       var soundEnabled: Bool = true
    @AppStorage("soundVolume")        var soundVolume: Double = 0.8
    @AppStorage("soundMode")          var soundModeRaw: String = SoundMode.procedural.rawValue
    @AppStorage("climbThreshold")     var climbThreshold: Double = 0.1   // m/s above = beep
    @AppStorage("sinkThreshold")      var sinkThreshold: Double = -2.0   // m/s below = alarm
    @AppStorage("basePitchHz")        var basePitchHz: Double = 500      // Hz at climb threshold
    @AppStorage("maxPitchHz")         var maxPitchHz: Double = 1600      // Hz at max climb (+6 m/s)
    @AppStorage("coordFormat")        var coordFormatRaw: String = CoordinateFormat.decimal.rawValue
    @AppStorage("useBarometer")       var useBarometer: Bool = true
    @AppStorage("thermalMemoryRadiusM") var thermalMemoryRadiusM: Double = 1500

    // Map & background
    @AppStorage("showMapBackground")  var showMapBackground: Bool = false
    @AppStorage("backgroundTheme")    var backgroundThemeRaw: String = BackgroundTheme.instrumentNavy.rawValue

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
}
