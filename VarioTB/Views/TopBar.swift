import SwiftUI

struct TopBar: View {
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var settings: AppSettings
    @Binding var showSettings: Bool

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

            // Damper pill
            Text("Damper \(settings.damperLevel)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.85))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.55)))

            Spacer()

            // Clock
            TimeNowView()

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
