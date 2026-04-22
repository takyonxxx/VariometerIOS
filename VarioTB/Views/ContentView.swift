import SwiftUI
import MapKit
import CoreLocation

struct ContentView: View {
    @StateObject private var settings = AppSettings()
    @StateObject private var locationMgr = LocationManager()
    @StateObject private var wind = WindEstimator()
    @StateObject private var audio = AudioEngine()
    @StateObject private var vario: VarioManager

    @State private var showSettings = false
    @State private var updateTimer: Timer?
    @State private var autoFollow: Bool = true

    init() {
        let s = AppSettings()
        _settings = StateObject(wrappedValue: s)
        _vario = StateObject(wrappedValue: VarioManager(settings: s))
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if settings.showMapBackground {
                    // Full-screen satellite map background
                    SatelliteMapView(coordinate: locationMgr.coordinate,
                                     heading: locationMgr.courseDeg,
                                     thermals: vario.thermals,
                                     autoFollow: $autoFollow)
                        .ignoresSafeArea()

                    // Dark overlay for readability over map
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0.25), .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                } else {
                    // Theme-based solid background (no map)
                    LinearGradient(colors: settings.backgroundTheme.gradient,
                                   startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea()
                }

                VStack(spacing: 0) {
                    TopBar(locationMgr: locationMgr, settings: settings,
                           showSettings: $showSettings)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)

                    // Main vario reading — HUGE
                    VarioBigReadout(vario: vario.filteredVario,
                                    avg: vario.avgVario30s)
                        .padding(.top, 10)

                    Spacer(minLength: 0)

                    // Middle row: Wind dial + Thermal radar
                    HStack(spacing: 12) {
                        WindDial(windFromDeg: wind.windFromDeg,
                                 windSpeedKmh: wind.windSpeedKmh,
                                 courseDeg: locationMgr.courseDeg,
                                 confidence: wind.confidence)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)

                        ThermalRadar(thermal: vario.lastThermal,
                                     pilotCoord: locationMgr.coordinate,
                                     pilotCourseDeg: locationMgr.courseDeg,
                                     radiusM: settings.thermalMemoryRadiusM)
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                    .padding(.horizontal, 12)

                    Spacer(minLength: 0)

                    // Bottom telemetry strip
                    BottomTelemetry(locationMgr: locationMgr, settings: settings)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }

                // Re-center floating button — only when map is visible
                // and user has panned away from auto-follow
                if settings.showMapBackground && !autoFollow {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
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
                            .padding(.trailing, 18)
                            .padding(.bottom, 180)   // above bottom telemetry
                        }
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: autoFollow)
        }
        .onAppear {
            locationMgr.start()
            vario.attachLocationManager(locationMgr)
            applyAudioSettings()
            startTick()
        }
        .onChange(of: settings.soundEnabled)    { _ in applyAudioSettings() }
        .onChange(of: settings.soundVolume)     { _ in applyAudioSettings() }
        .onChange(of: settings.soundModeRaw)    { _ in applyAudioSettings() }
        .onChange(of: settings.climbThreshold)  { _ in applyAudioSettings() }
        .onChange(of: settings.sinkThreshold)   { _ in applyAudioSettings() }
        .onChange(of: settings.basePitchHz)     { _ in applyAudioSettings() }
        .onChange(of: settings.maxPitchHz)      { _ in applyAudioSettings() }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: settings, audio: audio)
        }
    }

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
            vario.update(rawVerticalSpeed: locationMgr.verticalSpeed,
                         coordinate: locationMgr.coordinate,
                         altitude: locationMgr.fusedAltitude)
            wind.update(groundSpeedKmh: locationMgr.groundSpeedKmh,
                        courseDeg: locationMgr.courseDeg)
            audio.updateVario(vario.filteredVario)
        }
    }
}
