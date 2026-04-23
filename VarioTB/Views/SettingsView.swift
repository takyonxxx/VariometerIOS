import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var audio: AudioEngine
    @ObservedObject var liveTracker: LiveTrack24Tracker
    @ObservedObject private var language = LanguagePreference.shared
    @Environment(\.dismiss) var dismiss

    // Sound test state
    @State private var testRunning = false
    @State private var testVario: Double = 0
    @State private var testDirection: Double = 0.1
    @State private var testTimer: Timer?
    @State private var testStepInterval: Double = 0.6

    // XContest/LiveTrack24 password (not @AppStorage — loaded from Keychain)
    @State private var livePassword: String = ""

    var body: some View {
        // Read language.code at the top so SwiftUI tracks the dependency and
        // re-renders THIS view when the user flips the picker.
        let _ = language.code

        return NavigationStack {
            Form {
                languageSection
                pilotSection
                liveTrackSection
                soundSection
                soundTestSection
                displaySection
                toolbarSection
                gpsSection
                thermalSection
                sensorsSection
                aboutSection
            }
            .navigationTitle(L10n.string("settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) {
                        stopTest()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            livePassword = KeychainStore.get("xcontestPassword") ?? ""
        }
        .onDisappear { stopTest() }
    }

    // MARK: - Sections

    private var languageSection: some View {
        Section(L10n.string("language")) {
            Picker(L10n.string("language"), selection: $language.code) {
                Text("🇹🇷  " + L10n.string("turkish")).tag("tr")
                Text("🇬🇧  " + L10n.string("english")).tag("en")
            }
            .pickerStyle(.segmented)
        }
    }

    private var pilotSection: some View {
        Section(L10n.string("pilot_info")) {
            TextField(L10n.string("first_name"), text: $settings.pilotFirstName)
                .textContentType(.givenName)
            TextField(L10n.string("last_name"), text: $settings.pilotLastName)
                .textContentType(.familyName)
            TextField(L10n.string("glider_brand"), text: $settings.gliderBrandModel)
            Picker(L10n.string("glider_cert"), selection: Binding(
                get: { settings.gliderCertification },
                set: { settings.gliderCertification = $0 }
            )) {
                ForEach(GliderCertification.allCases) { c in
                    Text(c.rawValue).tag(c)
                }
            }
            Picker(L10n.string("glider_type"), selection: Binding(
                get: { settings.gliderType },
                set: { settings.gliderType = $0 }
            )) {
                ForEach(GliderType.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            Text(L10n.string("pilot_info_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var liveTrackSection: some View {
        Section {
            Toggle(L10n.string("live_active"), isOn: Binding(
                get: { settings.liveTrackEnabled },
                set: { newVal in
                    settings.liveTrackEnabled = newVal
                    if newVal { liveTracker.start() } else { liveTracker.stop() }
                }
            ))
            TextField(L10n.string("live_username"), text: $settings.liveTrackUsername)
                .textContentType(.username)
                .autocapitalization(.none)
                .disableAutocorrection(true)
            SecureField(L10n.string("live_password"), text: $livePassword)
                .textContentType(.password)
                .onChange(of: livePassword) { newVal in
                    KeychainStore.set(newVal, for: "xcontestPassword")
                }

            if liveTracker.isActive {
                HStack {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .foregroundColor(.green)
                    Text("\(liveTracker.totalFixesSent) \(L10n.string("live_positions"))")
                        .font(.subheadline)
                        .monospacedDigit()
                }
                if !liveTracker.lastUploadStatus.isEmpty {
                    Text(liveTracker.lastUploadStatus)
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else if !liveTracker.lastUploadStatus.isEmpty {
                Text(liveTracker.lastUploadStatus)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 14) {
                Link("livetrack24.com",
                     destination: URL(string: "https://www.livetrack24.com")!)
                Link(L10n.string("live_register"),
                     destination: URL(string: "https://www.livetrack24.com/user/register")!)
            }
            .font(.caption)
        } header: {
            Text(L10n.string("live_tracking"))
        } footer: {
            Text(L10n.string("live_footer"))
                .font(.caption2)
        }
    }

    private var soundSection: some View {
        Section(L10n.string("sound")) {
            Toggle(L10n.string("sound_enabled"), isOn: $settings.soundEnabled)
            HStack {
                Text(L10n.string("volume"))
                Spacer()
                Text("\(Int(settings.soundVolume * 100))%")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.soundVolume, in: 0...1)

            Picker(L10n.string("sound_type"), selection: Binding(
                get: { settings.soundMode },
                set: { settings.soundMode = $0 }
            )) {
                ForEach(SoundMode.allCases) { Text($0.rawValue).tag($0) }
            }

            HStack {
                Text(L10n.string("climb_threshold"))
                Spacer()
                Text(String(format: "%+.1f m/s", settings.climbThreshold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.climbThreshold, in: -0.5...2.0, step: 0.1)

            HStack {
                Text(L10n.string("sink_threshold"))
                Spacer()
                Text(String(format: "%+.1f m/s", settings.sinkThreshold))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.sinkThreshold, in: -6.0...0, step: 0.1)

            HStack {
                Text(L10n.string("base_pitch"))
                Spacer()
                Text("\(Int(settings.basePitchHz)) Hz")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.basePitchHz, in: 300...800, step: 25)
            Text(L10n.string("base_pitch_hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Text(L10n.string("max_pitch"))
                Spacer()
                Text("\(Int(settings.maxPitchHz)) Hz")
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $settings.maxPitchHz, in: 900...2400, step: 25)
            Text(L10n.string("max_pitch_hint"))
                .font(.caption)
                .foregroundColor(.secondary)

            Text(L10n.string("bluetooth_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var soundTestSection: some View {
        Section(L10n.string("sound_test")) {
            if testRunning {
                HStack {
                    Text(L10n.string("test_vario"))
                    Spacer()
                    Text(String(format: "%+.1f m/s", testVario))
                        .foregroundColor(.cyan)
                        .monospacedDigit()
                }
            }

            HStack {
                Text(L10n.string("step_speed"))
                Spacer()
                Text(String(format: "%.1fs", testStepInterval))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: $testStepInterval, in: 0.2...1.5, step: 0.1)

            Button {
                toggleTest()
            } label: {
                HStack {
                    Image(systemName: testRunning ? "stop.circle.fill" : "play.circle.fill")
                    Text(testRunning ? L10n.string("stop_test") : L10n.string("start_test"))
                }
            }

            HStack {
                Text(L10n.string("manual_test"))
                Spacer()
                Text(String(format: "%+.1f m/s", audio.testOverride ?? 0))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Slider(value: Binding(
                get: { audio.testOverride ?? 0 },
                set: { audio.testOverride = $0 }
            ), in: -5...6, step: 0.1)
            .disabled(testRunning)

            if testRunning {
                Text(L10n.string("test_active_hint"))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private var displaySection: some View {
        Section(L10n.string("display")) {
            Toggle(L10n.string("map_background"), isOn: $settings.showMapBackground)

            if !settings.showMapBackground {
                Picker(L10n.string("background_color"), selection: Binding(
                    get: { settings.backgroundTheme },
                    set: { settings.backgroundTheme = $0 }
                )) {
                    ForEach(BackgroundTheme.allCases) { theme in
                        HStack {
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

                LinearGradient(colors: settings.backgroundTheme.gradient,
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            }
        }
    }

    // MARK: - Toolbar customization

    /// Lets the user reorder / hide / show the customizable TopBar buttons.
    /// Sound mute is intentionally absent — it lives in the Sound section
    /// above so it's always easy to find in-flight.
    private var toolbarSection: some View {
        Section {
            // Visible items — reorderable, removable
            if settings.toolbarItems.isEmpty {
                Text(L10n.string("toolbar_empty"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(settings.toolbarItems, id: \.self) { item in
                    HStack {
                        Image(systemName: item.iconName)
                            .foregroundColor(.cyan)
                            .frame(width: 26)
                        Text(item.displayName)
                        Spacer()
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.gray.opacity(0.4))
                    }
                }
                .onMove { from, to in
                    var list = settings.toolbarItems
                    list.move(fromOffsets: from, toOffset: to)
                    settings.toolbarItems = list
                }
                .onDelete { indices in
                    var list = settings.toolbarItems
                    list.remove(atOffsets: indices)
                    settings.toolbarItems = list
                }
            }

            // Available (hidden) items — tappable to add to the bar
            let hidden = ToolbarItemKind.allCases
                .filter { !settings.toolbarItems.contains($0) }
            if !hidden.isEmpty {
                ForEach(hidden, id: \.self) { item in
                    Button {
                        settings.toolbarItems.append(item)
                    } label: {
                        HStack {
                            Image(systemName: item.iconName)
                                .foregroundColor(.gray)
                                .frame(width: 26)
                            Text(item.displayName)
                                .foregroundColor(.secondary)
                            Spacer()
                            Image(systemName: "plus.circle")
                                .foregroundColor(.green)
                        }
                    }
                }
            }

            // Reset to default
            Button(role: .destructive) {
                settings.toolbarItems = ToolbarItemKind.defaultOrder
            } label: {
                Label(L10n.string("toolbar_reset"), systemImage: "arrow.counterclockwise")
            }
        } header: {
            HStack {
                Text(L10n.string("toolbar_section"))
                Spacer()
                EditButton().font(.caption)
            }
        } footer: {
            Text(L10n.string("toolbar_hint"))
                .font(.caption2)
        }
    }

    private var gpsSection: some View {
        Section(L10n.string("gps_coord")) {
            Picker(L10n.string("format"), selection: Binding(
                get: { settings.coordFormat },
                set: { settings.coordFormat = $0 }
            )) {
                ForEach(CoordinateFormat.allCases) { Text($0.rawValue).tag($0) }
            }
        }
    }

    private var thermalSection: some View {
        Section(L10n.string("thermal_radar")) {
            HStack {
                Text(L10n.string("coverage"))
                Spacer()
                Text("\(Int(settings.thermalMemoryRadiusM)) m")
                    .foregroundColor(.secondary)
            }
            Slider(value: $settings.thermalMemoryRadiusM, in: 300...5000, step: 100)
            Text(L10n.string("coverage_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var sensorsSection: some View {
        Section(L10n.string("sensors")) {
            Toggle(L10n.string("use_barometer"), isOn: $settings.useBarometer)
            Text(L10n.string("barometer_hint"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var aboutSection: some View {
        Section(L10n.string("about")) {
            LabeledContent(L10n.string("version"), value: "1.0.0")
            Text(L10n.string("about_text"))
                .font(.caption)
                .foregroundColor(.secondary)
        }
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
