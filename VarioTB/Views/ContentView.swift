import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var locationMgr = LocationManager()
    @StateObject private var wind = WindEstimator()
    @StateObject private var audio = AudioEngine()
    @StateObject private var vario: VarioManager
    @StateObject private var simulator = FlightSimulator()
    @StateObject private var recorder = FlightRecorder()
    @StateObject private var liveTracker = LiveTrack24Tracker()
    @StateObject private var fai = FAITriangleDetector()
    @StateObject private var task = CompetitionTask.loadActive() ?? CompetitionTask()

    @State private var showSettings = false
    @State private var showFilesList = false
    @State private var showTaskEditor = false
    @State private var showWaypoints = false
    @State private var updateTimer: Timer?
    @State private var autoFollow: Bool = true
    /// Bumped whenever the user taps the FAI HUD — triggers the map to
    /// zoom out and fit the whole triangle.
    @State private var fitTriangleToken: UUID?
    /// Bumped whenever a task is loaded (e.g. QR scan) so the map
    /// auto-frames the full task on screen. We also flip autoFollow off
    /// at the same moment so the pilot can inspect the task before the
    /// map snaps back to their position.
    @State private var fitTaskToken: UUID?
    /// Tracks task turnpoint count to detect when a task gets loaded —
    /// simplest signal to trigger the fit animation.
    @State private var lastSeenTaskTPCount: Int = 0
    /// Panel edit mode. Owned here so we can disable outer scroll while
    /// editing — without this, vertical drag fights the ScrollView and
    /// cards snap back as you try to move them.
    @State private var panelEditMode: Bool = false

    /// Deep-link task payload drained from DeepLink.pendingPayload or
    /// the taskImportNotification. When non-nil, ContentView opens the
    /// task editor with this payload queued for import. Cleared once
    /// the editor finishes handling the import.
    @State private var deepLinkTaskPayload: String? = nil

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _vario = StateObject(wrappedValue: VarioManager(settings: s))
    }

    var body: some View {
        ZStack {
            // Solid theme background behind the entire grid (visible in
            // gaps between cards).
            LinearGradient(colors: settings.backgroundTheme.gradient,
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(locationMgr: locationMgr, settings: settings,
                       simulator: simulator,
                       recorder: recorder,
                       task: task,
                       showSettings: $showSettings,
                       showTaskEditor: $showTaskEditor,
                       showWaypoints: $showWaypoints,
                       onShareTap: { prepareAndShowShare() })
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 6)

                // Everything else is customizable cards on a grid.
                // In edit mode we wrap in a ScrollView so the pilot can
                // reach cards below the fold to reposition them. Outside
                // edit mode we skip the ScrollView entirely so the panel
                // is a fixed layout (no accidental drift while flying).
                if panelEditMode {
                    // Grid goes inside a ScrollView so long layouts can be
                    // scrolled through during edit, but the reset/confirm
                    // footer sits OUTSIDE the scroll view as a fixed
                    // overlay at the bottom — otherwise the pilot has to
                    // scroll all the way down to reach "Tamam" / "Yarışma"
                    // / "Serbest". showsIndicators:true keeps the native
                    // scroll indicator visible so the pilot knows there's
                    // content below.
                    ZStack(alignment: .bottom) {
                        ScrollView(showsIndicators: true) {
                            PanelView(settings: settings,
                                      vario: vario,
                                      locationMgr: locationMgr,
                                      wind: wind,
                                      fai: fai,
                                      task: task,
                                      fitTriangleToken: fitTriangleToken,
                                      fitTaskToken: fitTaskToken,
                                      autoFollow: $autoFollow,
                                      editMode: $panelEditMode)
                                .padding(.horizontal, 12)   // extra room for scroll indicator
                                .padding(.top, 4)
                                .padding(.bottom, 100)      // clear the fixed footer
                        }
                        PanelView.EditFooter(settings: settings,
                                              editMode: $panelEditMode)
                            .padding(.bottom, 8)
                    }
                } else {
                    // Non-edit: the panel uses a fixed reference height
                    // (PanelLayout.referenceHeight) so cards retain their
                    // physical size across device sizes. Wrap in a
                    // ScrollView with scroll disabled — contents don't
                    // move, but anything below the viewport is still
                    // reachable by long-pressing into edit mode first.
                    // Most phones fit the full panel comfortably; this
                    // is the safety net for the compact ones.
                    ScrollView(showsIndicators: false) {
                        PanelView(settings: settings,
                                  vario: vario,
                                  locationMgr: locationMgr,
                                  wind: wind,
                                  fai: fai,
                                  task: task,
                                  fitTriangleToken: fitTriangleToken,
                                  fitTaskToken: fitTaskToken,
                                  autoFollow: $autoFollow,
                                  editMode: $panelEditMode)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                    }
                }
            }
        }
        .onAppear {
            locationMgr.start()
            vario.attachLocationManager(locationMgr)
            simulator.attach(locationManager: locationMgr,
                             varioManager: vario,
                             windEstimator: wind)
            recorder.attach(locationManager: locationMgr,
                            varioManager: vario,
                            simulator: simulator,
                            settings: settings)
            liveTracker.attach(settings: settings, locationManager: locationMgr)
            fai.attach(locationManager: locationMgr)
            if settings.liveTrackEnabled { liveTracker.start() }
            applyAudioSettings()
            startTick()
            // If the app re-launches with a task already persisted,
            // frame it on the map once so the pilot sees the whole
            // task immediately instead of being centered on their
            // current GPS position alone.
            lastSeenTaskTPCount = task.turnpoints.count
            if !task.turnpoints.isEmpty {
                autoFollow = false
                // Delay slightly so the map's makeUIView has completed
                // and the subsequent updateUIView can observe the token.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    fitTaskToken = UUID()
                }
            }
            // Cold-launch deep link drain. If the app was opened from
            // an xctsk:// URL, VarioTBApp's onOpenURL stashed the
            // payload in DeepLink.pendingPayload before any view could
            // observe a notification. Pick it up here on first mount.
            if let pending = DeepLink.pendingPayload {
                DeepLink.pendingPayload = nil
                deepLinkTaskPayload = pending
                showTaskEditor = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(
                    for: DeepLink.taskImportNotification)) { note in
            // Warm-launch deep link. App was already running when the
            // URL arrived — present the task editor with the payload
            // queued for import.
            guard let payload = note.userInfo?["payload"] as? String else { return }
            deepLinkTaskPayload = payload
            showTaskEditor = true
        }
        .onChange(of: recorder.isRecording) { recording in
            // FAI triangle detector follows the recorder lifecycle
            if recording { fai.start() } else { fai.stop() }
        }
        .onChange(of: recorder.currentIGCURL) { _ in
            // Every new IGC file = new flight → reset the FAI detector so
            // stale flightStart/triangle from the previous flight doesn't
            // leak into the new one (e.g. real→sim switch, or sim restart).
            if recorder.isRecording {
                fai.start()
            }
        }
        .onChange(of: settings.soundEnabled)    { _ in applyAudioSettings() }
        .onChange(of: settings.soundVolume)     { _ in applyAudioSettings() }
        .onChange(of: settings.soundModeRaw)    { _ in applyAudioSettings() }
        .onChange(of: settings.climbThreshold)  { _ in applyAudioSettings() }
        .onChange(of: settings.sinkThreshold)   { _ in applyAudioSettings() }
        .onChange(of: settings.basePitchHz)     { _ in applyAudioSettings() }
        .onChange(of: settings.maxPitchHz)      { _ in applyAudioSettings() }
        // Detect task loading/clearing. When the turnpoint count changes
        // from zero to non-zero (task just loaded), disable auto-follow
        // and bump the fit-task token so the map auto-frames the whole
        // task. Going from non-zero to zero (cleared) doesn't fit, just
        // resets the counter so a later reload triggers again.
        .onChange(of: task.turnpoints.count) { newCount in
            if newCount > 0 && lastSeenTaskTPCount == 0 {
                autoFollow = false
                fitTaskToken = UUID()
            }
            lastSeenTaskTPCount = newCount
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, audio: audio, liveTracker: liveTracker)
        }
        .sheet(isPresented: $showFilesList) {
            FilesListView(recorder: recorder, isPresented: $showFilesList)
        }
        .sheet(isPresented: $showTaskEditor) {
            CompetitionTaskView(task: task,
                                 isPresented: $showTaskEditor,
                                 deepLinkPayload: $deepLinkTaskPayload)
        }
        .sheet(isPresented: $showWaypoints) {
            WaypointsView(task: task, isPresented: $showWaypoints)
        }
    }

    /// Called when share button is tapped. Exports fresh waypoints and
    /// opens the files list so user can review, delete, or share.
    private func prepareAndShowShare() {
        _ = recorder.exportCurrentThermalsAsWaypoints()
        showFilesList = true
    }

    // MARK: - (instrumentPanel removed — body now composes TopBar + PanelView directly)

    // MARK: - Audio wiring

    private func applyAudioSettings() {
        audio.updateSettings(enabled: settings.soundEnabled,
                             volume: settings.soundVolume,
                             mode: settings.soundMode,
                             climbThreshold: settings.climbThreshold,
                             sinkThreshold: settings.sinkThreshold,
                             basePitchHz: settings.basePitchHz,
                             maxPitchHz: settings.maxPitchHz)
    }

    private func startTick() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            // Always drive vario from locationMgr.verticalSpeed. When the
            // simulator is running, it pushes its vertical speed through
            // locationMgr.injectSimulatedData, so the same path works for
            // both real and simulated flight. VarioManager itself skips
            // real-thermal detection when simulatedMode is on.
            vario.update(rawVerticalSpeed: locationMgr.verticalSpeed,
                         coordinate: locationMgr.coordinate,
                         altitude: locationMgr.fusedAltitude)
            wind.update(groundSpeedKmh: locationMgr.groundSpeedKmh,
                        courseDeg: locationMgr.courseDeg)
            audio.updateVario(vario.filteredVario)

            // Feed live tracker (samples at full tick rate; uploads batched @ 30s)
            liveTracker.recordFix()

            // Feed FAI triangle detector (thinned internally, recomputed every 10s)
            fai.recordFix()

            // Task progress: tick reached turnpoints so next-point
            // navigation / course indicator updates in real time.
            if !task.turnpoints.isEmpty, let pilot = locationMgr.coordinate {
                task.updateProgress(pilot: pilot)
            }

            // Auto-start real flight recording when:
            //   - simulator is NOT running
            //   - we have a GPS fix
            //   - the user is moving (>5 km/h) or climbing (>1 m/s)
            if !simulator.isRunning,
               !recorder.isRecording,
               locationMgr.hasFix,
               (locationMgr.groundSpeedKmh > 5 || vario.filteredVario > 1) {
                recorder.startFlight()
            }
        }
    }
}
