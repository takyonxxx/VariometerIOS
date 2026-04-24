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

            // Competition task
            "competition_task":    "Yarışma Görevi",
            "task_distance":       "Görev Mesafesi",
            "task_route":          "Rota",
            "qr_format":           "QR Formatı",
            "qr_format_url":       "URL (xctsk://)",
            "qr_format_standard":  "Düz Metin (XCTSK:)",
            "qr_format_url_hint":  "iOS kamerasıyla okuyunca Vario TB doğrudan açılır.",
            "qr_format_standard_hint": "Kamera açmaz; başka uygulamalar (XCTrack/Flyskyhy) kendi tarayıcılarıyla okur.",
            "turnpoint_count":     "Turnpoint Sayısı",
            "task_timing":         "Zamanlama",
            "task_start":          "Görev Başlangıcı",
            "clear_start_time":    "Zamanı Temizle",
            "set_task_start":      "Başlangıç Saati Ayarla (13:00 UTC)",
            "task_deadline":       "Görev Bitiş Saati",
            "clear_deadline":      "Bitiş Saatini Temizle",
            "set_task_deadline":   "Bitiş Saati Ayarla (16:00 UTC)",
            "turnpoints":          "Turnpoint'ler",
            "turnpoints_empty":    "Henüz turnpoint eklenmemiş.",
            "add_turnpoint":       "Turnpoint Ekle",
            "clear_task":          "Görevi Temizle",
            "edit_turnpoint":      "Turnpoint Düzenle",
            "tp_identity":         "Kimlik",
            "tp_name":             "Ad",
            "tp_description":      "Açıklama",
            "tp_type":             "Tip",
            "tp_location":         "Konum",
            "latitude":            "Enlem",
            "longitude":           "Boylam",
            "altitude_m":          "Yükseklik (m)",
            "tp_cylinder":         "Silindir",
            "tp_radius":           "Yarıçap",
            "tp_reached_on":       "Geçiş Tipi",
            "tp_enter":            "Giriş",
            "tp_exit":             "Çıkış",
            "tp_line":             "Çizgi",
            "tp_start_time":       "Başlangıç Saati",
            "tp_has_start_time":   "Saatli Başlangıç",
            "tp_optional":         "Opsiyonel",
            "tp_optional_hint":    "Opsiyonel turnpoint atlanırsa görev geçersiz olmaz.",
            "save":                "Kaydet",
            "back":                "Geri",

            // Task sharing (QR)
            "task_share":          "Paylaşım",
            "task_scan_qr":        "QR Kod Tara",
            "task_share_qr":       "QR Kod ile Paylaş",
            "task_scan_title":     "İçe Aktarma",
            "task_scan_loaded":    "Görev yüklendi: %d turnpoint",
            "task_scan_failed":    "QR kod tanınmadı.",
            "qr_share_hint":       "Bu QR kodu diğer cihazdan tarat.",
            "add_from_waypoints":  "Waypoint'ten Ekle",

            // Toolbar customization
            "toolbar_section":     "Üst Bar Düzeni",
            "toolbar_empty":       "Üst barda buton yok. Aşağıdan ekleyebilirsin.",
            "toolbar_reset":       "Varsayılana Döndür",
            "toolbar_hint":        "Sürükleyip yeniden sırala veya sola kaydırıp kaldır. Eklemek için alttaki + işaretine bas. Ses açma/kapama Ses bölümünde kalır.",

            // Flyskyhy-style import dialog
            "import_waypoints_title":  "Waypoint'leri İçe Aktar",
            "import_waypoints_count":  "%d waypoint içe aktarılsın mı?",
            "add_to_route":            "Rotaya Ekle",
            "replace_route":           "Rotayı Değiştir",
            "new_waypoint_group":      "Yeni Waypoint Grubu",
            "task_scan_added":         "%d turnpoint rotaya eklendi",
            "task_scan_replaced":      "Rota değiştirildi: %d turnpoint",
            "task_scan_group":         "%d waypoint yeni gruba eklendi",

            // Waypoint library
            "waypoints":            "Waypointler",
            "waypoint":             "Waypoint",
            "waypoint_lists":       "Listeler",
            "waypoint_lists_empty": "Henüz liste yok. Yeni liste oluştur, dosya içe aktar veya QR tara.",
            "waypoints_empty_list": "Bu listede waypoint yok.",
            "add_waypoint":         "Waypoint Ekle",
            "add_waypoints":        "Ekle",
            "new_list":             "Yeni Liste",
            "list_name":            "Liste Adı",
            "create":               "Oluştur",
            "import_file":          "Dosyadan İçe Aktar",
            "scan_qr":              "QR Kod Tara",
            "import_success":       "%d waypoint içe aktarıldı",
            "qr_import_success":    "QR'dan %d turnpoint yüklendi",
            "select_from_list":     "Listeden Seç",
            "pick_waypoint":        "Waypoint Seç",
            "waypoint_picker_empty": "Önce Waypointler sayfasından liste ekleyin.",
            "qr_invalid":            "QR kodu tanınmadı.",
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

            // Competition task
            "competition_task":    "Competition Task",
            "task_distance":       "Task Distance",
            "task_route":          "Route",
            "qr_format":           "QR Format",
            "qr_format_url":       "URL (xctsk://)",
            "qr_format_standard":  "Plain Text (XCTSK:)",
            "qr_format_url_hint":  "iOS Camera opens Vario TB directly when scanned.",
            "qr_format_standard_hint": "Camera won't open it; other apps (XCTrack/Flyskyhy) read it with their own scanner.",
            "turnpoint_count":     "Turnpoint Count",
            "task_timing":         "Timing",
            "task_start":          "Task Start",
            "clear_start_time":    "Clear Start Time",
            "set_task_start":      "Set Start Time (13:00 UTC)",
            "task_deadline":       "Task Deadline",
            "clear_deadline":      "Clear Deadline",
            "set_task_deadline":   "Set Deadline (16:00 UTC)",
            "turnpoints":          "Turnpoints",
            "turnpoints_empty":    "No turnpoints yet.",
            "add_turnpoint":       "Add Turnpoint",
            "clear_task":          "Clear Task",
            "edit_turnpoint":      "Edit Turnpoint",
            "tp_identity":         "Identity",
            "tp_name":             "Name",
            "tp_description":      "Description",
            "tp_type":             "Type",
            "tp_location":         "Location",
            "latitude":            "Latitude",
            "longitude":           "Longitude",
            "altitude_m":          "Altitude (m)",
            "tp_cylinder":         "Cylinder",
            "tp_radius":           "Radius",
            "tp_reached_on":       "Reached On",
            "tp_enter":            "Enter",
            "tp_exit":             "Exit",
            "tp_line":             "Line",
            "tp_start_time":       "Start Time",
            "tp_has_start_time":   "Has Start Time",
            "tp_optional":         "Optional",
            "tp_optional_hint":    "Optional turnpoints can be skipped without invalidating the task.",
            "save":                "Save",
            "back":                "Back",

            // Task sharing (QR)
            "task_share":          "Sharing",
            "task_scan_qr":        "Scan QR Code",
            "task_share_qr":       "Share via QR Code",
            "task_scan_title":     "Import",
            "task_scan_loaded":    "Task loaded: %d turnpoints",
            "task_scan_failed":    "QR code not recognized.",
            "qr_share_hint":       "Scan this code from another device.",
            "add_from_waypoints":  "Add from Waypoints",

            // Toolbar customization
            "toolbar_section":     "Toolbar Layout",
            "toolbar_empty":       "No buttons in the top bar. Add some from below.",
            "toolbar_reset":       "Reset to Default",
            "toolbar_hint":        "Drag to reorder or swipe left to remove. Tap + to add. Sound mute stays in the Sound section.",

            // Flyskyhy-style import dialog
            "import_waypoints_title":  "Import Waypoints",
            "import_waypoints_count":  "Import %d waypoints?",
            "add_to_route":            "Add to Route",
            "replace_route":           "Replace Route",
            "new_waypoint_group":      "New Waypoint Group",
            "task_scan_added":         "%d turnpoints added to route",
            "task_scan_replaced":      "Route replaced: %d turnpoints",
            "task_scan_group":         "%d waypoints added to new group",

            // Waypoint library
            "waypoints":            "Waypoints",
            "waypoint":             "Waypoint",
            "waypoint_lists":       "Lists",
            "waypoint_lists_empty": "No lists yet. Create a new list, import a file, or scan a QR.",
            "waypoints_empty_list": "No waypoints in this list.",
            "add_waypoint":         "Add Waypoint",
            "add_waypoints":        "Add",
            "new_list":             "New List",
            "list_name":            "List Name",
            "create":               "Create",
            "import_file":          "Import from File",
            "scan_qr":              "Scan QR Code",
            "import_success":       "%d waypoints imported",
            "qr_import_success":    "%d turnpoints loaded from QR",
            "select_from_list":     "Select from List",
            "pick_waypoint":        "Pick Waypoint",
            "waypoint_picker_empty": "Create a waypoint list on the Waypoints page first.",
            "qr_invalid":            "QR code not recognized.",
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
