import Foundation
import SwiftUI
import Combine

/// Lightweight runtime localization.
///
/// Uses a single shared `LanguagePreference.shared` instance observed by all
/// views. When the language code changes, `objectWillChange` fires and every
/// view referencing it re-renders.
///
/// Default language is Turkish; choice is persisted in UserDefaults.
enum L10n {
    static func string(_ k: String) -> String {
        let lang = LanguagePreference.shared.code
        if let dict = translations[lang], let v = dict[k] {
            return v
        }
        if let v = translations["tr"]?[k] { return v }
        return k
    }

    private static let translations: [String: [String: String]] = [
        "tr": [
            // Top bar / navigation
            "settings":         "Ayarlar",
            "close":            "Kapat",
            "flight_records":   "Uçuş Kayıtları",
            "files":            "Dosyalar",
            "files_empty":      "Henüz uçuş kaydı yok.",
            "share_all":        "Hepsini Paylaş",
            "delete_all":       "Hepsini Sil",
            "delete_all_confirm": "Tüm dosyalar silinsin mi?",
            "delete_all_message": "%d dosya kalıcı olarak silinecek.",
            "cancel":           "İptal",

            // Telemetry
            "waiting_gps":      "GPS bekleniyor…",
            "altitude":         "İRTİFA",
            "ground_speed":     "YER HIZI",
            "course":           "ROTA",

            // Language section
            "language":         "Dil",
            "turkish":          "Türkçe",
            "english":          "English",

            // Pilot info section
            "pilot_info":       "Pilot Bilgileri",
            "first_name":       "Ad",
            "last_name":        "Soyad",
            "glider_brand":     "Kanat Marka / Model",
            "glider_cert":      "Kanat Sertifikası",
            "glider_type":      "Kanat Tipi",
            "pilot_info_hint":  "Bu bilgiler IGC uçuş kaydı dosyalarının başlığında yer alır.",

            // LiveTrack24 section
            "live_tracking":    "LiveTrack24 Live Tracking",
            "live_active":      "Live Tracking Aktif",
            "live_username":    "LiveTrack24 Kullanıcı Adı",
            "live_password":    "LiveTrack24 Şifre",
            "live_positions":   "pozisyon gönderildi",
            "live_register":    "Kayıt ol",
            "live_footer":      "LiveTrack24 hesabı ile uçuşunuzu canlı yayınlayabilirsiniz. Üyelik ücretsizdir. Kimlik bilgileriniz cihazınızda iOS Keychain'de saklanır.",
            "live_login_failed": "Kullanıcı adı/şifre hatalı",

            // Sound section
            "sound":            "Ses",
            "sound_enabled":    "Ses açık",
            "volume":           "Seviye",
            "sound_type":       "Ses Türü",
            "climb_threshold":  "Yükselme eşiği",
            "sink_threshold":   "Alçalma alarmı",
            "base_pitch":       "Baz frekans",
            "max_pitch":        "Maks frekans",
            "base_pitch_hint":  "Eşik climb'da duyulan ton (düşük climb)",
            "max_pitch_hint":   "En yüksek climb'da (+6 m/s) ulaşılacak tiz ton",
            "bluetooth_hint":   "Bluetooth hoparlör bağlıysa ses oraya gider.",

            // Sound test section
            "sound_test":       "Ses Test Simülasyonu",
            "test_vario":       "Test Vario",
            "step_speed":       "Adım hızı",
            "stop_test":        "Testi Durdur",
            "start_test":       "Test Başlat (0 → 5 m/s, 0.1 adım)",
            "manual_test":      "Elle test",
            "test_active_hint": "Test çalışırken gerçek vario devre dışıdır.",

            // Display section
            "display":          "Ekran",
            "map_background":   "Uydu haritası arka planı",
            "background_color": "Arka plan rengi",

            // GPS / coord
            "gps_coord":        "GPS / Koordinat",
            "format":           "Format",

            // Thermal radar
            "thermal_radar":    "Termik Radarı",
            "coverage":         "Kapsama",
            "coverage_hint":    "Termik radarındaki uzaklık ölçeği",

            // Sensors
            "sensors":          "Sensörler",
            "use_barometer":    "Barometre kullan (CMAltimeter)",
            "barometer_hint":   "Barometre vario için çok daha hassas sonuç verir.",

            // About
            "about":            "Hakkında",
            "version":          "Sürüm",
            "about_text":       "Yamaç paraşütü / planör için variometer, termik radar, rüzgâr yönü ve GPS göstergesi.",

            // FAI triangle HUD
            "fai_triangle":     "FAI Üçgeni",
            "fai_closed":       "Kapalı üçgen",
            "fai_closing":      "Kapatma",
        ],
        "en": [
            // Top bar / navigation
            "settings":         "Settings",
            "close":            "Close",
            "flight_records":   "Flight Records",
            "files":            "Files",
            "files_empty":      "No flight records yet.",
            "share_all":        "Share All",
            "delete_all":       "Delete All",
            "delete_all_confirm": "Delete all files?",
            "delete_all_message": "%d files will be permanently deleted.",
            "cancel":           "Cancel",

            // Telemetry
            "waiting_gps":      "Waiting for GPS…",
            "altitude":         "ALT",
            "ground_speed":     "GND SPD",
            "course":           "COURSE",

            // Language section
            "language":         "Language",
            "turkish":          "Türkçe",
            "english":          "English",

            // Pilot info section
            "pilot_info":       "Pilot Information",
            "first_name":       "First Name",
            "last_name":        "Last Name",
            "glider_brand":     "Glider Brand / Model",
            "glider_cert":      "Glider Certification",
            "glider_type":      "Glider Type",
            "pilot_info_hint":  "This information is written to the IGC flight log header.",

            // LiveTrack24 section
            "live_tracking":    "LiveTrack24 Live Tracking",
            "live_active":      "Live Tracking Active",
            "live_username":    "LiveTrack24 Username",
            "live_password":    "LiveTrack24 Password",
            "live_positions":   "positions sent",
            "live_register":    "Register",
            "live_footer":      "Broadcast your flight live via LiveTrack24. Registration is free. Your credentials are stored only on your device, in the iOS Keychain.",
            "live_login_failed": "Invalid username or password",

            // Sound section
            "sound":            "Sound",
            "sound_enabled":    "Sound enabled",
            "volume":           "Volume",
            "sound_type":       "Sound Type",
            "climb_threshold":  "Climb threshold",
            "sink_threshold":   "Sink alarm",
            "base_pitch":       "Base frequency",
            "max_pitch":        "Max frequency",
            "base_pitch_hint":  "Tone heard at threshold climb (low climb)",
            "max_pitch_hint":   "Highest tone reached at max climb (+6 m/s)",
            "bluetooth_hint":   "If a Bluetooth speaker is paired, audio goes there.",

            // Sound test section
            "sound_test":       "Sound Test Simulation",
            "test_vario":       "Test Vario",
            "step_speed":       "Step speed",
            "stop_test":        "Stop Test",
            "start_test":       "Start Test (0 → 5 m/s, 0.1 step)",
            "manual_test":      "Manual test",
            "test_active_hint": "While test is running, the real vario is disabled.",

            // Display section
            "display":          "Display",
            "map_background":   "Satellite map background",
            "background_color": "Background color",

            // GPS / coord
            "gps_coord":        "GPS / Coordinates",
            "format":           "Format",

            // Thermal radar
            "thermal_radar":    "Thermal Radar",
            "coverage":         "Coverage",
            "coverage_hint":    "Distance scale shown on the thermal radar",

            // Sensors
            "sensors":          "Sensors",
            "use_barometer":    "Use barometer (CMAltimeter)",
            "barometer_hint":   "The barometer gives much more accurate vario readings.",

            // About
            "about":            "About",
            "version":          "Version",
            "about_text":       "Variometer, thermal radar, wind direction and GPS indicator for paragliding / gliding.",

            // FAI triangle HUD
            "fai_triangle":     "FAI Triangle",
            "fai_closed":       "Closed triangle",
            "fai_closing":      "Closing",
        ],
    ]
}

/// Single shared language preference. Views access this via
/// `@ObservedObject var language = LanguagePreference.shared`, ensuring that
/// language changes trigger re-render across every consuming view.
final class LanguagePreference: ObservableObject {
    static let shared = LanguagePreference()

    private let defaultsKey = "appLanguage"

    @Published var code: String {
        didSet {
            if code != oldValue {
                UserDefaults.standard.set(code, forKey: defaultsKey)
            }
        }
    }

    private init() {
        self.code = UserDefaults.standard.string(forKey: defaultsKey) ?? "tr"
    }

    func set(_ c: String) { code = c }
}
