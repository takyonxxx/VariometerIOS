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

    @State private var showSettings = false
    @State private var showFilesList = false
    @State private var updateTimer: Timer?
    @State private var autoFollow: Bool = true
    /// Bumped whenever the user taps the FAI HUD — triggers the map to
    /// zoom out and fit the whole triangle.
    @State private var fitTriangleToken: UUID?

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _vario = StateObject(wrappedValue: VarioManager(settings: s))
    }

    var body: some View {
        GeometryReader { geo in
            // When map is on: upper 55% = instruments, lower 45% = map
            // When map is off: full screen = instruments, more breathing room
            let mapOn = settings.showMapBackground
            // Map ON: 60% instruments / 40% map — gives wind+thermal more room
            // Map OFF: full screen instruments
            let topFraction: CGFloat = mapOn ? 0.60 : 1.0

            ZStack {
                // Solid theme background behind everything (visible when map is off)
                LinearGradient(colors: settings.backgroundTheme.gradient,
                               startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // ===== UPPER SECTION (instruments) =====
                    instrumentPanel
                        .frame(height: geo.size.height * topFraction)

                    // ===== LOWER SECTION (map, conditional) =====
                    if mapOn {
                        ZStack(alignment: .bottomTrailing) {
                            SatelliteMapView(coordinate: locationMgr.coordinate,
                                             heading: locationMgr.courseDeg,
                                             thermals: vario.thermals,
                                             triangle: fai.bestTriangle,
                                             flightStart: fai.flightStart,
                                             fitTriangleToken: fitTriangleToken,
                                             autoFollow: $autoFollow)

                            // FAI triangle HUD — only shown when a valid
                            // triangle exists. Placed top-leading so it
                            // doesn't overlap the re-center button.
                            // Tapping the HUD disables auto-follow and
                            // zooms the map to show the whole triangle.
                            if let tri = fai.bestTriangle {
                                VStack {
                                    HStack {
                                        FAITriangleHUD(triangle: tri,
                                                       pilotCoord: locationMgr.coordinate,
                                                       homeCoord: fai.flightStart,
                                                       pilotHeadingDeg: locationMgr.courseDeg,
                                                       onTap: {
                                                           autoFollow = false
                                                           fitTriangleToken = UUID()
                                                       })
                                            .padding(.leading, 12)
                                            .padding(.top, 12)
                                        Spacer()
                                    }
                                    Spacer()
                                }
                            }

                            // Re-center button floats inside the map area
                            if !autoFollow {
                                Button {
                                    autoFollow = true
                                } label: {
                                    Image(systemName: "location.north.line.fill")
                                        .font(.system(size: 18, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(14)
                                        .background(
                                            Circle()
                                                .fill(Color.black.opacity(0.65))
                                                .overlay(
                                                    Circle()
                                                        .stroke(Color.cyan.opacity(0.8), lineWidth: 2)
                                                )
                                        )
                                }
                                .padding(14)
                                .transition(.opacity.combined(with: .scale))
                            }

                            // Thin border/shadow between instruments and map
                            VStack { Spacer() }   // just for alignment
                        }
                        .overlay(alignment: .top) {
                            // Subtle top divider line so instruments/map feel like panes
                            Rectangle()
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: mapOn)
            .animation(.easeInOut(duration: 0.2), value: autoFollow)
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
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, audio: audio, liveTracker: liveTracker)
        }
        .sheet(isPresented: $showFilesList) {
            FilesListView(recorder: recorder, isPresented: $showFilesList)
        }
    }

    /// Called when share button is tapped. Exports fresh waypoints and
    /// opens the files list so user can review, delete, or share.
    private func prepareAndShowShare() {
        _ = recorder.exportCurrentThermalsAsWaypoints()
        showFilesList = true
    }

    // MARK: - Instrument panel (everything except the map)

    @ViewBuilder
    private var instrumentPanel: some View {
        VStack(spacing: 0) {
            TopBar(locationMgr: locationMgr, settings: settings,
                   simulator: simulator,
                   recorder: recorder,
                   showSettings: $showSettings,
                   onShareTap: { prepareAndShowShare() })
                .padding(.horizontal, 12)
                .padding(.top, 8)

            // Main vario reading — compact on map-on, full size on map-off
            VarioBigReadout(vario: vario.filteredVario,
                            compact: settings.showMapBackground)
                .padding(.top, settings.showMapBackground ? 2 : 12)

            if !settings.showMapBackground {
                Spacer(minLength: 0)
            }

            // Telemetry strip (ALT / SPEED / COURSE + coords)
            BottomTelemetry(locationMgr: locationMgr, settings: settings)
                .padding(.horizontal, 12)
                .padding(.top, settings.showMapBackground ? 6 : 0)
                .padding(.bottom, settings.showMapBackground ? 8 : 18)

            // Wind + Thermal indicators
            if settings.showMapBackground {
                // Map ON: horizontal layout, fills available space
                HStack(spacing: 12) {
                    WindDial(windFromDeg: wind.windFromDeg,
                             windSpeedKmh: wind.windSpeedKmh,
                             courseDeg: locationMgr.courseDeg,
                             confidence: wind.confidence)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)

                    ThermalRadar(thermals: vario.thermals,
                                 pilotCoord: locationMgr.coordinate,
                                 pilotCourseDeg: locationMgr.courseDeg,
                                 radiusM: settings.thermalMemoryRadiusM)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            } else {
                // Map OFF: vertical stack — wind on top, thermal below (2x size)
                VStack(spacing: 12) {
                    WindDial(windFromDeg: wind.windFromDeg,
                             windSpeedKmh: wind.windSpeedKmh,
                             courseDeg: locationMgr.courseDeg,
                             confidence: wind.confidence)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 170)

                    ThermalRadar(thermals: vario.thermals,
                                 pilotCoord: locationMgr.coordinate,
                                 pilotCourseDeg: locationMgr.courseDeg,
                                 radiusM: settings.thermalMemoryRadiusM)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 340)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            // Bottom status bar — big clock + battery, always at the bottom
            BottomStatusBar()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
        }
    }

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
