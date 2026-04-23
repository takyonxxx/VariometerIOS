import AppIntents
import Foundation

/// Siri and Shortcuts integration.
///
/// These intents let the pilot trigger common actions hands-free.
/// All phrases are in English for consistent Siri recognition across
/// locales. Users can always rename shortcuts in the Shortcuts app.
///
/// ## Voice commands supported:
///   - "Hey Siri, start flight recording with Vario TB"
///   - "Hey Siri, stop flight recording with Vario TB"
///   - "Hey Siri, start live tracking with Vario TB"
///   - "Hey Siri, stop live tracking with Vario TB"
///   - "Hey Siri, start simulator with Vario TB"
///   - "Hey Siri, stop simulator with Vario TB"
///   - "Hey Siri, what's my altitude in Vario TB"
///   - "Hey Siri, what's my vario in Vario TB"
///
/// Also registered as Shortcuts app items, Lock Screen buttons, and
/// Action Button targets (iPhone 15 Pro+).
///
/// All intents require iOS 16+.

// MARK: - Flight recording

@available(iOS 16.0, *)
struct StartFlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Flight Recording"
    static var description = IntentDescription(
        "Starts an IGC flight recording manually.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            FlightRecorder.shared?.startFlight()
        }
        return .result(dialog: "Flight recording started.")
    }
}

@available(iOS 16.0, *)
struct StopFlightIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Flight Recording"
    static var description = IntentDescription(
        "Stops the active IGC recording and saves the file.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let filename: String = await MainActor.run {
            let result = FlightRecorder.shared?.stopFlight()
            return result?.igc?.lastPathComponent ?? ""
        }
        if filename.isEmpty {
            return .result(dialog: "No active recording to stop.")
        }
        return .result(dialog: "Recording stopped: \(filename)")
    }
}

// MARK: - Live tracking

@available(iOS 16.0, *)
struct StartLiveTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Live Tracking"
    static var description = IntentDescription(
        "Starts a LiveTrack24 live tracking session.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            LiveTrack24Tracker.shared?.start()
        }
        return .result(dialog: "LiveTrack24 live tracking started.")
    }
}

@available(iOS 16.0, *)
struct StopLiveTrackingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Live Tracking"
    static var description = IntentDescription(
        "Stops the active LiveTrack24 live tracking session.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            LiveTrack24Tracker.shared?.stop()
        }
        return .result(dialog: "LiveTrack24 live tracking stopped.")
    }
}

// MARK: - Simulator

@available(iOS 16.0, *)
struct StartSimulatorIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Simulator"
    static var description = IntentDescription(
        "Starts the Kumludoruk Ayaş FAI triangle flight simulation.")

    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            FlightSimulator.shared?.start()
        }
        return .result(dialog: "Simulator started. Flying a nineteen kilometer FAI triangle from Kumludoruk.")
    }
}

@available(iOS 16.0, *)
struct StopSimulatorIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Simulator"
    static var description = IntentDescription(
        "Stops the active flight simulation.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        await MainActor.run {
            FlightSimulator.shared?.stop()
        }
        return .result(dialog: "Simulator stopped.")
    }
}

// MARK: - Query intents

@available(iOS 16.0, *)
struct CurrentAltitudeIntent: AppIntent {
    static var title: LocalizedStringResource = "Current Altitude"
    static var description = IntentDescription("Reports the current altitude.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let hasFix = await MainActor.run { LocationManager.shared?.hasFix ?? false }
        let alt = await MainActor.run { LocationManager.shared?.fusedAltitude ?? 0 }
        if !hasFix {
            return .result(dialog: "Waiting for GPS fix.")
        }
        return .result(dialog: "Altitude \(Int(alt)) meters.")
    }
}

@available(iOS 16.0, *)
struct CurrentVarioIntent: AppIntent {
    static var title: LocalizedStringResource = "Current Vertical Speed"
    static var description = IntentDescription("Reports the current vertical speed.")

    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let vs = await MainActor.run {
            LocationManager.shared?.verticalSpeed ?? 0
        }
        let s = String(format: "%+.1f", vs)
        return .result(dialog: "Vertical speed \(s) meters per second.")
    }
}

// MARK: - Shortcut suggestions

@available(iOS 16.0, *)
struct VarioTBShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartFlightIntent(),
            phrases: [
                "Start flight \(.applicationName)",
                "Record flight \(.applicationName)",
                "\(.applicationName) start flight",
            ],
            shortTitle: "Start Flight",
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: StopFlightIntent(),
            phrases: [
                "Stop flight \(.applicationName)",
                "End flight \(.applicationName)",
                "\(.applicationName) stop flight",
            ],
            shortTitle: "Stop Flight",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: StartLiveTrackingIntent(),
            phrases: [
                "Start tracking \(.applicationName)",
                "\(.applicationName) start tracking",
            ],
            shortTitle: "Start Live Tracking",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: StopLiveTrackingIntent(),
            phrases: [
                "Stop tracking \(.applicationName)",
                "\(.applicationName) stop tracking",
            ],
            shortTitle: "Stop Live Tracking",
            systemImageName: "stop.circle"
        )
        AppShortcut(
            intent: StartSimulatorIntent(),
            phrases: [
                "Start simulator \(.applicationName)",
                "\(.applicationName) simulator",
                "\(.applicationName) start simulator",
            ],
            shortTitle: "Start Simulator",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: StopSimulatorIntent(),
            phrases: [
                "Stop simulator \(.applicationName)",
                "\(.applicationName) stop simulator",
            ],
            shortTitle: "Stop Simulator",
            systemImageName: "stop.circle.fill"
        )
        AppShortcut(
            intent: CurrentAltitudeIntent(),
            phrases: [
                "\(.applicationName) altitude",
                "Altitude \(.applicationName)",
            ],
            shortTitle: "Altitude",
            systemImageName: "mountain.2.fill"
        )
        AppShortcut(
            intent: CurrentVarioIntent(),
            phrases: [
                "\(.applicationName) vario",
                "Vario \(.applicationName)",
                "\(.applicationName) vertical speed",
            ],
            shortTitle: "Vertical Speed",
            systemImageName: "chart.line.uptrend.xyaxis"
        )
    }
}
