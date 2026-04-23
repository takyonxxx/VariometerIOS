import SwiftUI

struct TopBar: View {
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var simulator: FlightSimulator
    @ObservedObject var recorder: FlightRecorder
    @Binding var showSettings: Bool
    var onShareTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // GPS status pill
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(locationMgr.hasFix
                     ? String(format: "%.0f m", locationMgr.horizontalAccuracy)
                     : "No fix")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            }
            .foregroundColor(locationMgr.hasFix ? .green : .orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))

            // Sound toggle
            Button {
                settings.soundEnabled.toggle()
            } label: {
                Image(systemName: settings.soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(settings.soundEnabled ? .yellow : .gray)
                    .padding(7)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }

            // Map toggle
            Button {
                settings.showMapBackground.toggle()
            } label: {
                Image(systemName: settings.showMapBackground ? "map.fill" : "map")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(settings.showMapBackground ? .cyan : .white.opacity(0.7))
                    .padding(7)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }

            // Simulation toggle (replaces old damper pill)
            Button {
                if simulator.isRunning {
                    simulator.stop()
                } else {
                    simulator.start()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: simulator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text(simulator.isRunning ? "SIM" : "SIM")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                }
                .foregroundColor(simulator.isRunning ? .orange : .white.opacity(0.7))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .overlay(
                            Capsule()
                                .stroke(simulator.isRunning ? Color.orange : Color.clear, lineWidth: 1.5)
                        )
                )
            }

            Spacer()

            // Share button — exports IGC + waypoints via iOS share sheet
            Button {
                onShareTap()
            } label: {
                Image(systemName: recorder.isRecording
                      ? "square.and.arrow.up.fill"
                      : "square.and.arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(recorder.isRecording
                                     ? Color(red: 0.35, green: 0.95, blue: 0.55)
                                     : .white)
                    .padding(8)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }

            // Settings gear
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
        }
    }
}

struct TimeNowView: View {
    @State private var now = Date()
    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    var body: some View {
        Text(now, style: .time)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundColor(.white.opacity(0.85))
            .monospacedDigit()
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))
            .onReceive(timer) { now = $0 }
    }
}
