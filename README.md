# Vario TB — iOS Paragliding Variometer

Yamaç paraşütü ve planör pilotları için SwiftUI ile yazılmış, tek-ekran odaklı variometer uygulaması. Türkçe/İngilizce arayüz, uydu haritası, barometrik vario, rüzgâr hesabı, termik radarı, **FAI üçgen tespiti**, IGC uçuş kaydı, CUP waypoint dosyası, LiveTrack24 canlı takip ve **Siri Shortcuts** içerir.

**Hedef cihaz:** iPhone 16 Pro (iOS 17+) — barometre ve yüksek-hassasiyetli GPS gerekir.

---

## Ekran Görüntüleri

<p align="center">
  <img src="docs/screenshots/01-map-view.png" alt="Harita + FAI üçgen + kapatma oku" width="280">
  &nbsp;&nbsp;
  <img src="docs/screenshots/02-instrument-view.png" alt="Sadece enstrüman görünümü" width="280">
  &nbsp;&nbsp;
  <img src="docs/screenshots/03-settings.png" alt="Ayarlar — İngilizce" width="280">
</p>

<p align="center">
  <i>Sol: uydu haritası + canlı FAI üçgeni, HUD'da bearing oku ve kapanış mesafesi, yeşil "home" hedef işaretçisi</i><br>
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
- **Alt durum çubuğu** — büyük saat (saniye dahil) + pil yüzdesi, pilot havada kolayca görebilsin diye.

### FAI Üçgen Tespiti
- **Canlı üçgen takibi** — kayıt sırasında her 10 saniyede geometrik algoritma çalışır, track history'de **FAI-valid en büyük üçgeni** bulur.
- **FAI kuralları** — min kenar / toplam perimeter ≥ 0.28, kapanış mesafesi / perimeter ≤ 0.20.
- **Harita üzerinde görsel** — 3 turnpoint polygon olarak çizilir. Açıksa sarı kesik kenar, kapanıyorsa yeşil dolu.
- **Canlı kapatma oku** — pilot'un pozisyonundan flight-start'a uzanan yeşil kesik çizgi, ucunda büyük "home" hedef işaretçisi (halkalar + merkez nokta) + ok başı.
- **HUD kartı** — üçgen ikonu + perimeter km + **yukarı-ok bearing** (pilot heading'ine göre hangi yöne uçmalı) + closing mesafesi.
- **Performans** — point thinning (≥200m aralıklı, max 150 nokta) + O(n³) brute force + n² pre-computed distance matrix. ~50ms hesaplama süresi, arka plan thread.

### Siri Shortcuts (App Intents, iOS 16+)
- **6 ses komutu**:
  - "Hey Siri, Vario TB ile uçuş kaydı başlat"
  - "Hey Siri, Vario TB ile uçuş kaydını durdur"
  - "Hey Siri, Vario TB ile live tracking başlat"
  - "Hey Siri, Vario TB ile live tracking durdur"
  - "Hey Siri, Vario TB ile irtifamı söyle" → "İrtifa 1,247 metre"
  - "Hey Siri, Vario TB ile dikey hızımı söyle" → "Dikey hız +2.8 metre bölü saniye"
- **Shortcuts app entegrasyonu** — otomatik görünür, Home Screen'e eklenebilir.
- **Lock Screen widget** desteği — iOS 17 Interactive Widget olarak kullanılabilir.
- **iPhone 15 Pro Action Button** — tek intent bağlanarak hands-free kullanılabilir.
- **Türkçe + İngilizce ifade** — her intent için.

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
- **Native session-aware protokol** — `client.php` login → sessionID → `track.php` fixleri. HTTPS first, HTTP fallback.
- **Ayarlardan aç/kapat** — kullanıcı adı (AppStorage), şifre (iOS Keychain).
- **5 saniyede bir pozisyon** — batch upload, XCTrack'e benzer veri tüketimi (~100KB/saat).
- **Pilot/glider bilgisi** — IGC ile aynı ayarlardan vtype (Paraglider=1, Hang=2, Glider=8, Paramotor=16) ve vname otomatik dolar.
- **Sadece pozisyon sayısı görünür** — UI sade, "247 pozisyon gönderildi" + hata mesajları.

### Simülatör (geliştirme/demo)
- **Kumludoruk Ayaş FAI üçgen senaryosu** — 40.0318°N, 32.3282°E, 1030m launch.
- **3 turnpoint rotası** (scripted):
  1. Launch → TP1 (2.0 km doğu) — glide + 3.5 m/s termik + 150m climb
  2. TP1 → TP2 (1.9 km KKB) — glide + 2.5 m/s termik + 100m climb
  3. TP2 → Launch — glide, üçgeni kapatır
- **Perimeter 5.8 km**, min/total = 0.33 (FAI valid), kapanış ≈ 0 m (tam dönüş).
- **~60 saniye gerçek zamanda** tamamlanır (timeScale 10×).
- **Snap-to-turnpoint** — 150m'e yaklaşınca simülatör turnpoint'e snap eder, kesin geometri sağlar.
- **Hakim rüzgâr 315°** (NW), 2.8 m/s.
- **Simülatör thermal'ları ayrı** — real termiklerle karışmaz.
- **Dosyalar `_SIM` etiketli** — uçuş kayıtları karışmasın.

### Dil desteği
- **Türkçe (varsayılan) + İngilizce** — ayarlarda segmented picker.
- **Singleton + `@Published`** — dil değiştiğinde tüm ekranlar anında re-render.
- **iOS UserDefaults'ta kalıcı** — uygulama yeniden açılınca seçim hatırlanır.

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
├── Intents/
│   └── VarioTBIntents.swift       Siri App Intents + AppShortcutsProvider
├── Managers/
│   ├── LocationManager.swift      GPS + CMAltimeter + simulator injection
│   ├── VarioManager.swift         Vario filter + termik tespit (6s streak)
│   ├── WindEstimator.swift        Circling-based rüzgâr (course spread >90°)
│   ├── FlightSimulator.swift      Kumludoruk FAI triangle senaryosu (~60s)
│   ├── FAITriangleDetector.swift  O(n³) FAI triangle search, flight-start tracking
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
    ├── ContentView.swift          Split layout (map on/off) + FAI reset hooks
    ├── VarioBigReadout.swift      Büyük m/s göstergesi (compact mode)
    ├── WindDial.swift             Yatay windsock + tick + N/E/S/W
    ├── ThermalRadar.swift         Tüm termiklerin radar ekranı
    ├── SatelliteMapView.swift     MapKit Hybrid + triangle overlay + closing arrow
    ├── FAITriangleHUD.swift       Üçgen kartı + bearing oku + closing mesafesi
    ├── TopBar.swift               GPS/Ses/Harita/SIM/Paylaş/Ayarlar
    ├── BottomTelemetry.swift      ALT/GND SPD/COURSE + koordinat barı
    ├── BottomStatusBar.swift      Saat (HH:mm:ss) + pil (ekranın en altı)
    ├── SettingsView.swift         Form — tamamen L10n üzerinden
    ├── FilesListView.swift        IGC/CUP listesi + paylaş/sil
    └── ShareSheet.swift           UIActivityViewController wrapper
```

---

## Önemli teknik notlar

**Vario filter.** `damperLevel` sabit 1 (bypass). iOS barometre verisi zaten düşük-gürültülü; ek damper gecikme ekliyordu. Termik tespiti için 0.20s regression window yeterli.

**Rüzgâr tahmini.** Pilotun GPS track'inden circling tekniği: ground-speed min/max rotation → wind vector. Minimum course spread 90° gerekir. İlk bir-iki dakika spiralde "confidence" 0'dan 1'e çıkar.

**FAI triangle detection.** Kaydedilen her fix thinning filter'ından geçer (≥200m aralık, max 150 nokta). Her 10 saniyede O(n³) brute force arka plan thread'de çalışır — 150 nokta için ~1.7M kombinasyon, 50ms altı. Pre-computed n² distance matrix ile i<j<k triple loop'ta tekrar hesaplama önlenir. Early pruning: `a < bestP * 0.28` olduğunda iç döngüden atla.

**Closing arrow.** Pilot'un mevcut fix'i → `flightStart` (ilk recordFix çağrısıyla yakalanan koordinat). Kesik yeşil polyline + yeşil home target (4-katmanlı halka: siyah kontur → yeşil → beyaz iç → yeşil merkez). Ok başı home'un hemen önünde. `FlightRecorder.currentIGCURL` her değiştiğinde detector sıfırlanır — her yeni uçuş (real veya sim) temiz başlar.

**IGC dosya yolu.** `Documents/Flights/2026-04-23_105239_SIM.igc`. B-record örneği:
```
B1052404001885N03219697EA0102701027
```
— `10:52:40` UTC, `40°01.885'N 032°19.697'E`, basınç irtifa 1027m, GPS irtifa 1027m.

**LiveTrack24 session ID.** XCTrack ile bire-bir: üst bit 1, sonraki 7 bit random, alt 24 bit userID.
```
sid = (random & 0x7F000000) | (userID & 0x00FFFFFF) | 0x80000000
```

**App Intents shared pattern.** `FlightRecorder`, `LiveTrack24Tracker`, `LocationManager`'ın `static weak var shared` property'leri var — `attach()` veya `init()` içinde kendilerini atar. App Intent `perform()` metodları bu shared pointer üzerinden canlı state'e erişir. `@MainActor.run` ile UI thread garantisi.

**Kumludoruk koordinatı.** Ayaş, Ankara: `40.0318°N, 32.3282°E, 1030m`. Simülatör buradan başlar.

**Bundle ID.** `com.tbiliyor.VarioTB` — sabit.

---

## Gelecek çalışmalar

- [ ] Airspace gösterimi (TR airspace XML import)
- [ ] Türkiye takeoff/landing sites veritabanı
- [ ] Apple Watch companion — wrist-variometer (WatchConnectivity + SwiftUI for watchOS)
- [ ] Otomatik IGC upload (landing detection + LiveTrack24 post-flight upload)
- [ ] XContest submit entegrasyonu (LiveTrack24 profile → XContest forward ayarı)
- [ ] Lock Screen widget (iOS 17 Interactive Widget) — Siri intents'le

---

## Lisans & iletişim

Bu kişisel bir projedir. Pilot: [tbiliyor](https://www.livetrack24.com/user/takyonxxx) — Türkay Biliyor.

Bug raporu ve önerler: GitHub Issues.
