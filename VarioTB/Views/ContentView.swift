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

    // MARK: - Auto-start flight detection state
    //
    // Flymaster-style single-signal detection: ground speed must stay
    // above the user's threshold (default 5 km/h) continuously for
    // the configured duration (default 3 s) before recording starts.
    // Walking pace (4-5 km/h with frequent pauses) doesn't satisfy the
    // sustained condition; a foot launch (steady acceleration past 5
    // km/h) does, instantly.
    /// Wall-clock timestamp at which the speed-based airborne signal
    /// first went TRUE. Reset to nil whenever the signal goes FALSE.
    @State private var fastSpeedSince: Date? = nil

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
                // PanelView itself reads the available geometry to
                // decide portrait vs landscape and to size its cards
                // accordingly — we don't need an outer GeometryReader.
                //
                // Wrapping rule: ScrollView ONLY in portrait edit mode
                // (so the pilot can reach cards below the fold while
                // dragging). All other times PanelView fills its slot
                // directly so MapWidget keeps a stable identity across
                // ticks — wrapping it in conditional branches makes
                // SwiftUI re-mount the map every render, which causes
                // the visible flicker.
                // PanelView is ALWAYS placed in the same spot in the
                // view tree: inside a ZStack, inside the same ScrollView,
                // with the same modifiers. Edit mode only changes which
                // overlay sits on top (the EditFooter) and whether the
                // ScrollView indicator is visible. This is critical for
                // SwiftUI identity: the embedded MKMapView keeps its
                // tile cache, camera, and Metal drawable across edit
                // mode toggles. Any conditional view-tree branch above
                // PanelView would mount/unmount MKMapView on each
                // re-render — visible to the pilot as a constant
                // flicker (and seen in the log as
                // `setDrawableSize 0×0` followed by
                // `[MAP] update#1` resetting).
                ZStack(alignment: .bottom) {
                    GeometryReader { outerGeo in
                        let isLandscape = outerGeo.size.width > outerGeo.size.height
                        ScrollView(showsIndicators: panelEditMode) {
                            PanelView(settings: settings,
                                      vario: vario,
                                      locationMgr: locationMgr,
                                      wind: wind,
                                      fai: fai,
                                      task: task,
                                      simulator: simulator,
                                      recorder: recorder,
                                      fitTriangleToken: fitTriangleToken,
                                      fitTaskToken: fitTaskToken,
                                      autoFollow: $autoFollow,
                                      editMode: $panelEditMode)
                                // Portrait: fixed reference height so cards
                                // keep their physical size on every device.
                                // Landscape: fill the available height so
                                // PanelView's inner GeometryReader sees a
                                // wider-than-tall geometry and switches to
                                // landscapeTransformed() — instruments left,
                                // map right.
                                .frame(height: isLandscape
                                       ? outerGeo.size.height
                                       : PanelLayout.referenceHeight)
                                .frame(width: isLandscape
                                       ? outerGeo.size.width
                                       : nil)
                                .padding(.horizontal, panelEditMode ? 12 : 8)
                                .padding(.top, 4)
                                .padding(.bottom, panelEditMode ? 100 : 6)
                        }
                        .scrollDisabled(!panelEditMode || isLandscape)
                    }
                    if panelEditMode {
                        PanelView.EditFooter(settings: settings,
                                              editMode: $panelEditMode)
                            .padding(.bottom, 8)
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
                            settings: settings,
                            task: task)
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
        // Task start gate — fires exactly once per task when the
        // wall-clock crosses taskStartTime. Plays the reach chime
        // (same audio cue used when tagging a turnpoint, so the pilot
        // recognises "something competition-relevant just happened")
        // and a success haptic. taskPhase is also published — UI
        // surfaces (e.g. tinted start-time card) can react to the
        // phase directly without listening to this event.
        .onChange(of: task.startGateOpenEvent) { token in
            guard token != nil else { return }
            ChimePlayer.shared.playTaskAlarm()
            // Three success haptics spaced 300ms apart — noticeable
            // through glove and harness when flying.
            DispatchQueue.main.async {
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.success)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    gen.notificationOccurred(.success)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    gen.notificationOccurred(.success)
                }
            }
        }
        // Deadline — fires once when Date() crosses taskDeadline.
        // Uses a warning haptic rather than success to signal "race
        // closed". We reuse the same alarm sound; the distinct haptic
        // pattern is enough for the pilot to tell them apart in the
        // air without needing a dedicated sound asset.
        .onChange(of: task.deadlineReachedEvent) { token in
            guard token != nil else { return }
            ChimePlayer.shared.playTaskAlarm()
            DispatchQueue.main.async {
                let gen = UINotificationFeedbackGenerator()
                gen.notificationOccurred(.warning)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    gen.notificationOccurred(.warning)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    gen.notificationOccurred(.warning)
                }
            }
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
            // Wind estimation needs the pilot's actual GPS ground
            // track (which sweeps a full circle while thermalling),
            // not the compass-backed courseDeg (which stays fixed if
            // the phone is strapped to the harness). gpsCourseDeg is
            // updated from raw CLLocation.course on every fix, and
            // by the simulator during sim runs. When it's still -1
            // (no track yet) we skip the update — WindEstimator
            // needs meaningful direction data to fit a sinusoid.
            if locationMgr.gpsCourseDeg >= 0 {
                wind.update(groundSpeedKmh: locationMgr.groundSpeedKmh,
                            courseDeg: locationMgr.gpsCourseDeg)
            }
            audio.updateVario(vario.filteredVario)

            // Feed live tracker (samples at full tick rate; uploads batched @ 30s)
            liveTracker.recordFix()

            // Feed FAI triangle detector (thinned internally, recomputed every 10s)
            fai.recordFix()

            // Task progress: tick reached turnpoints so next-point
            // navigation / course indicator updates in real time.
            // When the simulator is running we bypass timing gates —
            // the user is testing the task geometry, not racing the
            // wall clock. Real flight uses the normal start-gate /
            // deadline checks.
            if !task.turnpoints.isEmpty, let pilot = locationMgr.coordinate {
                task.updateProgress(pilot: pilot,
                                     ignoreTiming: simulator.isRunning)
            }

            // Drive the task clock independently of GPS. Start-gate
            // and deadline alarms must fire even while the pilot is
            // still on takeoff waiting — they have no fix, no
            // movement, and updateProgress won't be called. The
            // updateTaskPhase call below is idempotent; once the event
            // UUID has been posted for this phase transition, the
            // *Notified flag prevents duplicates on later ticks. We
            // still skip this while the simulator is running so sim
            // test flights don't trigger a real-world race alarm.
            if !task.turnpoints.isEmpty, !simulator.isRunning {
                task.updateTaskPhase()
            }

            // Auto-start real flight recording when ground speed is
            // sustained above the user's threshold (default 5 km/h
            // for 3 s — Flymaster's "Start Speed" approach). Slow
            // enough to catch a foot-launch on the first strides,
            // fast enough that walking around the launch with the
            // wing on your back won't trip it. The threshold
            // resetting to nil whenever speed drops below the bar
            // filters single GPS speed glitches — it has to STAY
            // above the bar continuously.
            //
            // The pilot can always hand-start / hand-stop via the
            // panel's Recording Toggle card.
            if !simulator.isRunning,
               !recorder.isRecording,
               locationMgr.hasFix {
                let now = Date()

                if locationMgr.groundSpeedKmh > settings.autoStartSpeedKmh {
                    if fastSpeedSince == nil { fastSpeedSince = now }
                } else {
                    fastSpeedSince = nil
                }

                let speedTriggered = (fastSpeedSince.map {
                    now.timeIntervalSince($0) >= settings.autoStartSpeedSeconds
                } ?? false)

                if speedTriggered {
                    recorder.startFlight()
                    fastSpeedSince = nil
                }
            } else if recorder.isRecording {
                fastSpeedSince = nil
            }
        }
    }
}
