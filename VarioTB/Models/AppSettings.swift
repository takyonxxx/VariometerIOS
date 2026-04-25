import Foundation
import SwiftUI

/// Items that can appear in the top toolbar. The user picks which ones
/// are visible and in what order from the Settings page. Sound toggle is
/// intentionally NOT in this list — volume/mute lives in Settings because
/// pilots need to be able to find it reliably, not accidentally reorder
/// it off the bar during a flight.
enum ToolbarItemKind: String, CaseIterable, Identifiable, Codable {
    case simulator    = "simulator"    // SIM start/stop pill
    case waypoints    = "waypoints"    // pin icon → Waypoints page
    case task         = "task"         // flag icon → CompetitionTask page
    case share        = "share"        // upload icon → share IGC
    case settings     = "settings"     // gear icon → Settings
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .simulator: return "Simülatör"
        case .waypoints: return "Waypointler"
        case .task:      return "Yarışma Görevi"
        case .share:     return "Paylaş"
        case .settings:  return "Ayarlar"
        }
    }

    var iconName: String {
        switch self {
        case .simulator: return "play.circle"
        case .waypoints: return "mappin.and.ellipse"
        case .task:      return "flag.checkered"
        case .share:     return "square.and.arrow.up"
        case .settings:  return "gearshape.fill"
        }
    }

    /// Default order shown to users who haven't customized the
    /// toolbar. Matches the reference screenshot: waypoints first
    /// (pre-flight task building), then Task (for the currently
    /// selected task QR), then Share (outbound to other pilots),
    /// then Simulator (testing), then Settings (configuration). The
    /// map is NOT in the toolbar — it's a panel card the pilot
    /// manages from edit mode (long-press) like any other card.
    static var defaultOrder: [ToolbarItemKind] {
        [.waypoints, .task, .share, .simulator, .settings]
    }
}

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

    /// Set by VarioTBApp's `onOpenURL` handler when the user opens a
    /// task deep link (from iOS Camera, Safari, or another app's share
    /// sheet). Observed by ContentView — when this flips from nil to
    /// a non-nil string, ContentView presents the Competition Task
    /// view with the payload pre-filled for import.
    ///
    /// Not persisted (no @AppStorage) — deep links are one-shot; we
    /// clear the value as soon as the task sheet has consumed it.
    @Published var pendingDeepLinkTaskPayload: String? = nil

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

    /// Auto-start IGC recording threshold: ground speed in km/h that
    /// must be sustained (see autoStartSpeedSeconds) before recording
    /// is started automatically. Below this value (e.g. casually
    /// walking around launch at 4 km/h) auto-start stays armed but
    /// dormant. Default 5 km/h matches Flymaster's industry-standard
    /// "Start Speed" — slow enough to catch the first strides of a
    /// foot launch, fast enough that standing still or shuffling
    /// around with the wing won't start a recording. The pilot can
    /// always hand-start / hand-stop via the panel's Recording
    /// Toggle card.
    @AppStorage("autoStartSpeedKmh")    var autoStartSpeedKmh: Double = 5
    /// How long the speed signal must hold continuously before
    /// auto-start fires, in seconds. 3 s is enough to filter a single
    /// GPS speed glitch but short enough that the run-up is captured
    /// in the IGC almost from the first stride.
    @AppStorage("autoStartSpeedSeconds") var autoStartSpeedSeconds: Double = 3

    // Map & background
    @AppStorage("showMapBackground")  var showMapBackground: Bool = false
    @AppStorage("backgroundTheme")    var backgroundThemeRaw: String = BackgroundTheme.nightAviation.rawValue

    /// Comma-separated raw values of visible toolbar items in order.
    /// Use the `toolbarItems` computed property to read/write as typed.
    @AppStorage("toolbarItemsOrder") var toolbarItemsOrderRaw: String =
        ToolbarItemKind.defaultOrder.map(\.rawValue).joined(separator: ",")

    /// Instrument panel layout (card positions + sizes), JSON-encoded.
    /// Edited by the pilot via a long-press "edit mode" on the panel.
    @AppStorage("panelLayout") var panelLayoutRaw: String = ""

    /// Typed view of the stored panel layout. Returns default factory
    /// layout if the stored JSON is empty or invalid. Also migrates older
    /// saved layouts that predate the introduction of `.map` / `.battery`
    /// cards — they are appended at the bottom of the grid so existing
    /// pilots get the new cards without having to reset their layout.
    var panelLayout: PanelLayout {
        get {
            guard var parsed = PanelLayout.fromJSON(panelLayoutRaw) else {
                // First-launch path: there's no saved layout yet, so
                // we materialise the default and persist it
                // immediately. Without this, every read of
                // `panelLayout` would return a freshly constructed
                // `defaultLayout` whose cards have brand-new UUIDs,
                // making SwiftUI tear down and re-mount the embedded
                // MKMapView on every body re-evaluation (visible to
                // the pilot as a constant flicker, with the log
                // showing `[MAP] update#1` resetting forever).
                let fresh = PanelLayout.defaultLayout
                panelLayoutRaw = fresh.toJSON()
                return fresh
            }
            let presentKinds = Set(parsed.cards.map { $0.kind })
            var migrated = false
            for newKind in [InstrumentKind.battery, InstrumentKind.map] {
                if !presentKinds.contains(newKind) {
                    parsed = parsed.adding(newKind)
                    migrated = true
                }
            }
            if migrated {
                // Persist the migration once so we don't keep re-appending.
                panelLayoutRaw = parsed.toJSON()
            }
            return parsed
        }
        set {
            panelLayoutRaw = newValue.toJSON()
        }
    }

    /// Typed view of the stored toolbar order. Unknown values are skipped.
    var toolbarItems: [ToolbarItemKind] {
        get {
            let raws = toolbarItemsOrderRaw.split(separator: ",").map(String.init)
            return raws.compactMap { ToolbarItemKind(rawValue: $0) }
        }
        set {
            toolbarItemsOrderRaw = newValue.map(\.rawValue).joined(separator: ",")
        }
    }

    // Pilot info (used in IGC header and live-tracking)
    @AppStorage("pilotFirstName")     var pilotFirstName: String = ""
    @AppStorage("pilotLastName")      var pilotLastName: String = ""
    /// CIVL pilot ID. Optional. When set, written to the IGC header
    /// (HFPLT line, "(CIVLID:NNNNN)") and as a dedicated LXVTCIVLID
    /// L-record so CIVL-WPRS scoring tools can index the flight.
    @AppStorage("pilotCIVLID")        var pilotCIVLID: String = ""
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
