# Vario TB — iOS Paragliding Variometer

Yamaç paraşütü ve planör pilotları için SwiftUI ile yazılmış, tek-ekran odaklı variometer uygulaması. Türkçe/İngilizce arayüz, uydu haritası, barometrik vario, rüzgâr hesabı, termik radarı, IGC uçuş kaydı, CUP waypoint dosyası ve LiveTrack24 canlı takip içerir.

**Hedef cihaz:** iPhone 16 Pro (iOS 17+) — barometre ve yüksek-hassasiyetli GPS gerekir.

---

## Ekran Görüntüleri

<p align="center">
  <img src="docs/screenshots/01-map-view.png" alt="Harita açıkken ana ekran" width="280">
  &nbsp;&nbsp;
  <img src="docs/screenshots/02-instrument-view.png" alt="Sadece enstrüman görünümü" width="280">
  &nbsp;&nbsp;
  <img src="docs/screenshots/03-settings.png" alt="Ayarlar — İngilizce" width="280">
</p>

<p align="center">
  <i>Sol: uydu haritalı uçuş ekranı — vario, telemetry, rüzgâr göstergesi, termik radarı, saat & pil</i><br>
  <i>Orta: full-screen enstrüman görünümü — büyük vario + yatay windsock + termik radarı</i><br>
  <i>Sağ: ayarlar — TR/EN dil seçici, pilot bilgileri, LiveTrack24 entegrasyonu</i>
</p>

---

## Özellikler

### Ana ekran
- **Büyük vario göstergesi** — tırmanışta yeşil, alçalmada kırmızı, sıfır civarında beyaz. "+" işareti sıfıra yakınken gizlenir.
- **Barometrik + GPS fusion** — iOS `CMAltimeter` ile basınç-tabanlı dikey hız, GPS fallback.
- **Telemetry şeridi** — irtifa, yer hızı, rota, koordinat. Koordinat formatları: DD, DMS, DM, UTM, MGRS.
- **Rüzgâr göstergesi** — yatay "windsock" widget'ı, pole rüzgârın GELDIĞİ yönde ring kenarında. 16-nokta kompas (N/NE/ENE/E/...) merkez altında.
- **Termik radarı** — tespit edilen tüm termikleri mesafe+kuvvete göre gösterir. Renk kodlu (aqua-green en güçlüsü, lavender en zayıfı). Simülatör termikleri ayrı kategori.
- **Uydu harita arka planı** — MapKit Hybrid mode, 3D elevation. Opsiyonel. Gerçek termikler harita üzerinde işaretlenir.
- **Alt durum çubuğu** — büyük saat + pil yüzdesi, pilot havada kolayca görebilsin diye.

### Ses motoru
- **Procedural DSP** — AVAudioSourceNode ile 4-harmonik buzzer. Base 500Hz → max 1600Hz pitch scaling. 2.5→8 Hz arası cadence — tırmanış arttıkça sıklaşır.
- **Bluetooth otomatik routing** — AVAudioSession Bluetooth-A2DP.
- **Ses test simülasyonu** — ayarlar ekranında 0→5 m/s rampa, elle slider.
- **Eşik ayarlanabilir** — tırmanış eşiği, alçalma alarmı, base/max frekans.

### Uçuş kaydı & paylaşım
- **IGC formatı** — FAI standardı, B-record (GPS fix) + H-record (pilot/glider/datum). Dosya: `Documents/Flights/YYYY-MM-DD_HHMMSS[_SIM].igc`. XCSoar / XCTrack / SeeYou / XContest açar.
- **CUP waypoint dosyası** — SeeYou formatı, tespit edilen termikler thermal name + climb rate + timestamp ile. Dosya: `Documents/Waypoints/thermals_....cup`.
- **Otomatik başlatma** — GPS fix var + (hız >5 km/h veya climb >1 m/s) olduğunda kayıt başlar. Simülatör başlayınca simülatör kaydı (tag: `_SIM`) başlar.
- **Paylaş butonu** — tüm dosyalar listelenir. Her dosya tek tek paylaşılabilir (iOS native share sheet: WhatsApp, AirDrop, Mail, Files). Toplu paylaşım "Hepsini Paylaş" ile. Swipe-to-delete.
- **Pilot/glider bilgisi IGC header'a yazılır** — ad, soyad, kanat marka/model, sertifika (EN A/B/C/D, CCC), tip (Paraglider/Hang Glider/Glider/Paramotor).

### LiveTrack24 canlı takip
- **Açık protokol** — native session-aware HTTP API (client.php login → sessionID → track.php fixleri).
- **Ayarlardan aç/kapat** — kullanıcı adı (AppStorage), şifre (iOS Keychain).
- **5 saniyede bir pozisyon** — batch upload, XCTrack'e benzer veri tüketimi (~100KB/saat).
- **Pilot/glider bilgisi** — IGC ile aynı ayarlardan vtype (Paraglider=1, Hang=2, Glider=8, Paramotor=16) ve vname otomatik dolar.
- **Sadece pozisyon sayısı görünür** — UI sade, "247 pozisyon gönderildi" + hata mesajları.

### Simülatör (geliştirme/demo)
- **Kumludoruk Ayaş senaryosu** — 40.0318°N, 32.3282°E, 1030m launch.
- **Scripted akış** — launch → 1. termik (1.5-4.5 m/s, 200m güney) → NW glide 500m → 2. termik (0.8-2.5 m/s, +400m) → NW glide → auto-stop.
- **Hakim rüzgâr 315°** (NW), 2.8 m/s.
- **4× fast-forward** — ~90 saniyede tam bir uçuş.
- **Simülatör thermal'ları ayrı** — real termiklerle karışmaz, bitince temizlenir.
- **Dosyalar `_SIM` etiketli** — uçuş kayıtları karışmasın.

### Dil desteği
- **Türkçe (varsayılan) + İngilizce** — ayarlarda segmented picker.
- **Singleton + `@Published`** — dil değiştiğinde tüm ekranlar anında re-render.
- **iOS Keychain'de kalıcı** — uygulama yeniden açılınca seçim hatırlanır.

---

## Kurulum

```bash
git clone <bu-repo>
cd VarioTB
open VarioTB.xcodeproj
```

1. Xcode 15+ aç.
2. Target → Signing & Capabilities → **kendi Apple Developer Team'ini seç**. Bundle ID: `com.tbiliyor.VarioTB`.
3. iPhone bağla → Run (⌘R).

**Gerçek uçuş testi için fiziksel cihaz gerekir** — iOS simülatöründe GPS, barometre ve MapKit 3D desteği yok.

---

## Dosya yapısı

```
VarioTB/
├── VarioTBApp.swift               App entry + audio session setup
├── Info.plist                     İzinler, background modes, ATS exception
├── Assets.xcassets/               App icon
├── Models/
│   ├── AppSettings.swift          @AppStorage ayarlar + pilot/glider
│   ├── ThermalPoint.swift         ThermalPoint + ThermalSource(.real/.simulated)
│   └── L10n.swift                 TR/EN çeviri + LanguagePreference singleton
├── Managers/
│   ├── LocationManager.swift      GPS + CMAltimeter + simulator injection
│   ├── VarioManager.swift         Vario filter + termik tespit (6s streak)
│   ├── WindEstimator.swift        Circling-based rüzgâr (course spread >90°)
│   ├── FlightSimulator.swift      Kumludoruk senaryosu
│   ├── IGCRecorder.swift          FAI IGC B-record / H-record yazar
│   ├── WaypointExporter.swift     SeeYou CUP formatı
│   ├── FlightRecorder.swift       IGC + waypoint koordinatör + otomatik start/stop
│   ├── KeychainStore.swift        Keychain wrapper (LiveTrack24 şifresi)
│   └── LiveTrack24Tracker.swift   Session-aware LT24 protocol client
├── Audio/
│   └── AudioEngine.swift          AVAudioSourceNode DSP (4 harmonik, cadence)
├── Utils/
│   └── CoordConverter.swift       DMS/DM/UTM/MGRS dönüşümleri
└── Views/
    ├── ContentView.swift          Split layout (map on/off)
    ├── VarioBigReadout.swift      Büyük m/s göstergesi (compact mode)
    ├── WindDial.swift             Yatay windsock + tick + N/E/S/W
    ├── ThermalRadar.swift         Tüm termiklerin radar ekranı
    ├── SatelliteMapView.swift     MapKit Hybrid + termik marker + auto-follow
    ├── TopBar.swift               GPS/Ses/Harita/SIM/Paylaş/Ayarlar
    ├── BottomTelemetry.swift      ALT/GND SPD/COURSE + koordinat barı
    ├── BottomStatusBar.swift      Saat + pil (ekranın en altı)
    ├── SettingsView.swift         Form — tamamen L10n üzerinden
    ├── FilesListView.swift        IGC/CUP listesi + paylaş/sil
    └── ShareSheet.swift           UIActivityViewController wrapper
```

---

## Önemli teknik notlar

**Vario filter.** `damperLevel` artık sabit 1 (bypass). iOS barometre verisi zaten düşük-gürültülü; ek damper gecikme ekliyordu. Termik tespiti için 0.20s regression window yeterli.

**Rüzgâr tahmini.** Pilotun GPS track'inden circling tekniği: ground-speed min/max rotation → wind vector. Minimum course spread 90° gerekir. İlk bir-iki dakika spiralde "confidence" 0'dan 1'e çıkar.

**IGC dosya yolu.** `Documents/Flights/2026-04-23_105239_SIM.igc`. B-record örneği:
```
B1052404001885N03219697EA0102701027
```
— `10:52:40` UTC, `40°01.885'N 032°19.697'E`, basınç irtifa 1027m, GPS irtifa 1027m.

**LiveTrack24 session ID.** XCTrack ile bire-bir: üst bit 1, sonraki 7 bit random, alt 24 bit userID.
```
sid = (random & 0x7F000000) | (userID & 0x00FFFFFF) | 0x80000000
```

**Kumludoruk koordinatı.** Ayaş, Ankara: `40.0318°N, 32.3282°E, 1030m`. Simülatör buradan başlar.

**Bundle ID.** `com.tbiliyor.VarioTB` — sabit.

---

## Gelecek çalışmalar

- [ ] Airspace gösterimi (TR airspace XML import)
- [ ] Türkiye takeoff/landing sites veritabanı
- [ ] FAI triangle detection ve canlı tracking
- [ ] Apple Watch companion — wrist-variometer
- [ ] Siri shortcut: "Hey Siri, start recording flight"
- [ ] Ötesi: otomatik IGC upload (XContest/LiveTrack24 aynı anda)

---

## Lisans & iletişim

Bu kişisel bir projedir. Pilot: [tbiliyor](https://www.livetrack24.com/user/takyonxxx) — Türkay Biliyor.

Bug raporu ve önerler: GitHub Issues.
