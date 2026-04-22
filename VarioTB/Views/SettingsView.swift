import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var audio: AudioEngine
    @Environment(\.dismiss) var dismiss

    // Sound test state
    @State private var testRunning = false
    @State private var testVario: Double = 0
    @State private var testDirection: Double = 0.1    // +0.1 per step
    @State private var testTimer: Timer?
    @State private var testStepInterval: Double = 0.6  // seconds at each step

    var body: some View {
        NavigationStack {
            Form {
                Section("Variometer") {
                    HStack {
                        Text("Damper")
                        Spacer()
                        Text("\(settings.damperLevel)")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                            get: { Double(settings.damperLevel) },
                            set: { settings.damperLevel = Int($0.rounded()) }
                        ), in: 1...10, step: 1) {
                        Text("Damper")
                    } minimumValueLabel: {
                        Text("1").font(.caption)
                    } maximumValueLabel: {
                        Text("10").font(.caption)
                    }
                    Text("1 = bypass (ham veri) • 2+ = yumuşatma. iOS zaten barometre verisini filtreliyor.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Ses") {
                    Toggle("Ses açık", isOn: $settings.soundEnabled)

                    HStack {
                        Text("Seviye")
                        Spacer()
                        Text("\(Int(settings.soundVolume * 100))%")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.soundVolume, in: 0...1)

                    Picker("Ses Türü", selection: Binding(
                        get: { settings.soundMode },
                        set: { settings.soundMode = $0 }
                    )) {
                        ForEach(SoundMode.allCases) { Text($0.rawValue).tag($0) }
                    }

                    HStack {
                        Text("Yükselme eşiği")
                        Spacer()
                        Text(String(format: "%+.1f m/s", settings.climbThreshold))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.climbThreshold, in: 0.0...1.5, step: 0.05)

                    HStack {
                        Text("Alçalma alarmı")
                        Spacer()
                        Text(String(format: "%+.1f m/s", settings.sinkThreshold))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.sinkThreshold, in: -5.0...(-0.5), step: 0.1)

                    // Pitch range
                    HStack {
                        Text("Baz frekans")
                        Spacer()
                        Text("\(Int(settings.basePitchHz)) Hz")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.basePitchHz, in: 300...1200, step: 10)
                    Text("Eşik climb'da duyulan ton (düşük climb)")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("Maks frekans")
                        Spacer()
                        Text("\(Int(settings.maxPitchHz)) Hz")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $settings.maxPitchHz,
                           in: max(settings.basePitchHz + 100, 800)...2500,
                           step: 10)
                    Text("En yüksek climb'da (+6 m/s) ulaşılacak tiz ton")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("Bluetooth hoparlör cihazınıza bağlıysa ses oraya gider.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // MARK: - Sound test simulator
                Section {
                    // Live test display
                    HStack {
                        Image(systemName: testRunning ? "waveform.circle.fill" : "waveform.circle")
                            .font(.title2)
                            .foregroundColor(testRunning ? .green : .secondary)
                            .symbolEffect(.pulse, isActive: testRunning)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Test Vario")
                                .font(.caption).foregroundColor(.secondary)
                            Text(String(format: "%+.1f m/s", testVario))
                                .font(.system(size: 22, weight: .heavy, design: .rounded))
                                .monospacedDigit()
                                .foregroundColor(testRunning ? .green : .primary)
                                .contentTransition(.numericText())
                                .animation(.easeOut(duration: 0.1), value: testVario)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("0 → 5 m/s")
                                .font(.caption).foregroundColor(.secondary)
                            ProgressView(value: min(5.0, max(0, testVario)), total: 5.0)
                                .frame(width: 120)
                                .tint(.green)
                        }
                    }
                    .padding(.vertical, 4)

                    // Step speed
                    HStack {
                        Text("Adım hızı")
                        Spacer()
                        Text(String(format: "%.1f sn", testStepInterval))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $testStepInterval, in: 0.2...1.5, step: 0.1)

                    // Start/Stop
                    Button(action: toggleTest) {
                        HStack {
                            Image(systemName: testRunning ? "stop.fill" : "play.fill")
                            Text(testRunning ? "Testi Durdur" : "Test Başlat (0 → 5 m/s, 0.1 adım)")
                        }
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(testRunning ? .red : .green)

                    // Manual scrub
                    HStack {
                        Text("Elle test")
                        Spacer()
                        Text(String(format: "%+.1f", testVario))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: Binding(
                        get: { testVario },
                        set: { newVal in
                            testVario = (newVal * 10).rounded() / 10
                            if !testRunning { audio.testOverride = testVario }
                        }
                    ), in: -3.0...5.0, step: 0.1)

                    Text("Test çalışırken gerçek vario devre dışıdır. Testi durdur veya ayarları kapat.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("Ses Test Simülasyonu")
                } footer: {
                    Text("0'dan 5 m/s'ye 0.1 adımlarla çıkar, sonra geri iner. Her değerdeki beep cadence'ını ve pitch'i duyabilirsin. Bluetooth hoparlör bağlıysa oraya yönlenir.")
                        .font(.caption)
                }

                Section("Ekran") {
                    Toggle("Uydu haritası arka planı", isOn: $settings.showMapBackground)

                    if !settings.showMapBackground {
                        Picker("Arka plan rengi", selection: Binding(
                            get: { settings.backgroundTheme },
                            set: { settings.backgroundTheme = $0 }
                        )) {
                            ForEach(BackgroundTheme.allCases) { theme in
                                HStack {
                                    // Live color swatch
                                    LinearGradient(colors: theme.gradient,
                                                   startPoint: .top, endPoint: .bottom)
                                        .frame(width: 28, height: 28)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                                        )
                                    Text(theme.rawValue)
                                }
                                .tag(theme)
                            }
                        }
                        .pickerStyle(.navigationLink)

                        // Big live preview
                        LinearGradient(colors: settings.backgroundTheme.gradient,
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 70)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
                            )
                            .overlay(
                                Text("Önizleme")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.white.opacity(0.7))
                            )
                    } else {
                        Text("Uydu haritası ekranın tamamında arka plan olarak gösterilir.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("GPS / Koordinat") {
                    Picker("Format", selection: Binding(
                        get: { settings.coordFormat },
                        set: { settings.coordFormat = $0 }
                    )) {
                        ForEach(CoordinateFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                }

                Section("Termik Radarı") {
                    HStack {
                        Text("Kapsama")
                        Spacer()
                        Text("\(Int(settings.thermalMemoryRadiusM)) m")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.thermalMemoryRadiusM, in: 300...5000, step: 100)
                    Text("Yuvarlak göstergedeki en son termiğin uzaklık ölçeği")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Sensörler") {
                    Toggle("Barometre kullan (CMAltimeter)", isOn: $settings.useBarometer)
                    Text("iPhone 16 Pro'da barometre vario için çok daha hassas sonuç verir.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Hakkında") {
                    LabeledContent("Uygulama", value: "Vario TB")
                    LabeledContent("Sürüm", value: "1.0.0")
                    Text("Yamaç paraşütü / planör için variometer, termik radar, rüzgâr yönü ve GPS göstergesi.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("Ayarlar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Kapat") {
                        stopTest()
                        dismiss()
                    }
                }
            }
        }
        .onDisappear { stopTest() }
    }

    // MARK: - Sound test helpers

    private func toggleTest() {
        if testRunning { stopTest() } else { startTest() }
    }

    private func startTest() {
        testRunning = true
        testVario = 0
        testDirection = 0.1
        audio.testOverride = 0
        testTimer?.invalidate()
        testTimer = Timer.scheduledTimer(withTimeInterval: testStepInterval, repeats: true) { _ in
            advanceTest()
        }
    }

    private func advanceTest() {
        testVario += testDirection
        if testVario >= 5.0 {
            testVario = 5.0
            testDirection = -0.1
        } else if testVario <= 0.0 {
            testVario = 0.0
            testDirection = 0.1
        }
        testVario = (testVario * 10).rounded() / 10
        audio.testOverride = testVario
    }

    private func stopTest() {
        testTimer?.invalidate()
        testTimer = nil
        testRunning = false
        audio.testOverride = nil
    }
}
