# Vario TB — iOS Variometer

Yamaç paraşütü / planör pilotları için SwiftUI ile yazılmış variometer uygulaması.
Hedef cihaz: iPhone 16 Pro (iOS 17+).

## Özellikler

- **Büyük font vario göstergesi** (m/s, 120pt) — yükselmede yeşil, alçalmada kırmızı.
- **1–10 damper filtresi** (exponential smoothing).
- **Procedural + Sample tabanlı ses motoru** — yükseldikçe sıklaşan ve tizleşen beep.
- **Bluetooth hoparlör desteği** — `AVAudioSession` ile otomatik routing.
- **CMAltimeter barometrik vario** — GPS'e göre çok daha hassas dikey hız.
- **GPS** — irtifa, yer hızı (km/h), rota, konum.
- **Rüzgâr yönü hesabı** — pilotun GPS drift'inden circling tekniğiyle.
- **Uydu haritası arka planı** (MapKit Hybrid + realistic elevation).
- **Termik radarı** — en son tespit edilen termik, merkezinde pilot olan dairede gösterilir.
  Kuvveti m/s cinsinden yazılır, renk kodludur.
- **Koordinat formatları** — DD, DMS, DM, UTM, MGRS.

## Kurulum

1. `VarioTB.xcodeproj` dosyasını Xcode 15+ ile aç.
2. Target → Signing & Capabilities → kendi Team'ini seç.
3. Cihazı bağla ve Run (⌘R).

Gerçek uçuş testi için cihazda çalıştırmanız şart — simülatörde GPS ve barometre yok.

## Dosya yapısı

```
VarioTB/
├── VarioTBApp.swift          App entry + audio session
├── Info.plist                   İzinler ve background modes
├── Models/
│   ├── AppSettings.swift
│   └── ThermalPoint.swift
├── Managers/
│   ├── LocationManager.swift    GPS + CMAltimeter
│   ├── VarioManager.swift       Damper + termik tespiti
│   └── WindEstimator.swift      Circling-based wind estimation
├── Audio/
│   └── AudioEngine.swift        AVAudioEngine vario sound
├── Utils/
│   └── CoordConverter.swift     DMS/DM/UTM/MGRS
└── Views/
    ├── ContentView.swift
    ├── VarioBigReadout.swift
    ├── WindDial.swift
    ├── ThermalRadar.swift
    ├── SatelliteMapView.swift
    ├── TopBar.swift
    ├── BottomTelemetry.swift
    └── SettingsView.swift
```

## Notlar

- Variometer için barometre tercih edilir (`useBarometer` = true). iPhone 16 Pro'da barometre var.
- Termik tespiti: 6 saniyeden uzun, ≥0.5 m/s ortalama tırmanış.
- Rüzgâr hesabı için pilot daire çizmeli (course spread > 90°).
- Tüm birimler metric: m, m/s, km/h.

## Lisans

Kişisel proje — tbiliyor.
