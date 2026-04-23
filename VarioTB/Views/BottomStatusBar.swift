import SwiftUI

/// Always-visible bottom bar showing the current time and battery level
/// in large, pilot-readable fonts. Battery updates every 30 seconds.
struct BottomStatusBar: View {
    @State private var now = Date()
    @State private var batteryLevel: Float = UIDevice.current.batteryLevel
    @State private var batteryState: UIDevice.BatteryState = UIDevice.current.batteryState

    private let timeTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let batteryTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var batteryPercent: Int {
        batteryLevel < 0 ? 100 : Int((batteryLevel * 100).rounded())
    }

    var batteryColor: Color {
        if batteryState == .charging || batteryState == .full {
            return Color(red: 0.35, green: 0.95, blue: 0.55)
        }
        if batteryPercent >= 50 { return .white }
        if batteryPercent >= 20 { return Color(red: 1.0, green: 0.85, blue: 0.3) }
        return Color(red: 1.0, green: 0.4, blue: 0.4)
    }

    var batteryIconName: String {
        if batteryState == .charging {
            return "battery.100percent.bolt"
        }
        if batteryPercent >= 75 { return "battery.100" }
        if batteryPercent >= 50 { return "battery.75" }
        if batteryPercent >= 25 { return "battery.50" }
        if batteryPercent >= 10 { return "battery.25" }
        return "battery.0"
    }

    var body: some View {
        HStack(spacing: 0) {
            // Clock — big, pilot readable
            HStack(spacing: 6) {
                Image(systemName: "clock.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                Text(now, style: .time)
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Battery — big, pilot readable
            HStack(spacing: 6) {
                Image(systemName: batteryIconName)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(batteryColor)
                Text("\(batteryPercent)%")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .foregroundColor(batteryColor)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.85))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.cyan.opacity(0.22), lineWidth: 1)
                )
        )
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            batteryLevel = UIDevice.current.batteryLevel
            batteryState = UIDevice.current.batteryState
        }
        .onReceive(timeTimer) { now = $0 }
        .onReceive(batteryTimer) { _ in
            batteryLevel = UIDevice.current.batteryLevel
            batteryState = UIDevice.current.batteryState
        }
    }
}
