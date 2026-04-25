import SwiftUI
import CoreLocation

/// Top instrument bar. Shows a fixed GPS status pill on the left, then
/// user-configurable action buttons in the order/visibility the pilot has
/// chosen via Settings → "Üst Bar Düzeni". Sound mute is deliberately
/// NOT in this customizable set — volume lives in Settings so pilots can
/// always find it reliably in-flight.
struct TopBar: View {
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var simulator: FlightSimulator
    @ObservedObject var recorder: FlightRecorder
    @ObservedObject var task: CompetitionTask
    @Binding var showSettings: Bool
    @Binding var showTaskEditor: Bool
    @Binding var showWaypoints: Bool
    var onShareTap: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // GPS status pill — fixed, always first (critical info).
            HStack(spacing: 5) {
                Image(systemName: "location.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(locationMgr.hasFix
                     ? String(format: "%.0f m", locationMgr.horizontalAccuracy)
                     : "No fix")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(locationMgr.hasFix ? .green : .orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))

            // Recording status pill — always visible, mirrors the GPS
            // pill's pattern. Idle state is dim gray with a hollow
            // record icon (recording is armed but inactive); active
            // state is solid red with a filled circle that pulses,
            // immediately catching the eye in peripheral vision so
            // the pilot knows an IGC file is being written. Tappable
            // toggle — same action as the panel's Recording Toggle
            // card. Disabled while the simulator is running, since
            // sim data is synthetic and shouldn't be recorded as a
            // real flight.
            RecordingStatusPill(recorder: recorder, simulator: simulator)

            // User-ordered items. We put a Spacer BEFORE the last item so
            // the last one hugs the right edge — mirroring how iOS system
            // toolbars typically anchor the "done" affordance to the right.
            ForEach(Array(settings.toolbarItems.enumerated()), id: \.element) { idx, item in
                if idx == settings.toolbarItems.count - 1 {
                    Spacer()
                }
                itemView(for: item)
            }

            // If the user removed every item, still show the spacer to keep
            // the GPS pill aligned left.
            if settings.toolbarItems.isEmpty {
                Spacer()
            }
        }
    }

    // MARK: - Item rendering

    @ViewBuilder
    private func itemView(for item: ToolbarItemKind) -> some View {
        switch item {

        case .simulator:
            // Simulator is task-only now: without a task there's nothing
            // to simulate. The button shows a disabled/dim state when no
            // task is loaded so the user understands why it's inert.
            let hasTask = !task.turnpoints.isEmpty
            Button {
                if simulator.isRunning {
                    simulator.stop()
                    // Clear task reach-state so the UI cards (next TP
                    // distance, bearing arrow, cumulative distance)
                    // don't keep showing stale values from the run we
                    // just ended. Next sim run or real flight starts
                    // fresh.
                    task.resetProgress()
                } else if hasTask {
                    // Also reset before a fresh sim run so progress
                    // from a previous session / partial run doesn't
                    // leak into this one.
                    task.resetProgress()
                    let waypoints: [FlightSimulator.TaskWaypoint] =
                        task.turnpoints.enumerated().map { (idx, tp) in
                            let isInterior = idx > 0 && idx < task.turnpoints.count - 1
                            let kind: FlightSimulator.TaskWaypoint.Kind
                            switch tp.type {
                            case .takeoff: kind = .takeoff
                            case .sss:     kind = .sss
                            case .turn:    kind = .turn
                            case .ess:     kind = .ess
                            case .goal:    kind = .goal
                            }
                            return FlightSimulator.TaskWaypoint(
                                coord: CLLocationCoordinate2D(
                                    latitude: tp.latitude,
                                    longitude: tp.longitude),
                                radiusM: tp.radiusM,
                                altM: tp.altitudeM,
                                climbAtTP: isInterior,
                                kind: kind
                            )
                        }
                    // Use the exact polyline the map is drawing — this
                    // way the simulator visibly tracks the blue route
                    // line on screen instead of flying its own path.
                    let routePoints = SatelliteMapView.optimalRoutePoints(
                        for: task.turnpoints)
                    simulator.loadTask(waypoints, routePoints: routePoints)
                    simulator.start()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: simulator.isRunning ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                    Text("SIM")
                        .font(.system(size: 11, weight: .heavy, design: .rounded))
                        .lineLimit(1)
                        .fixedSize()
                }
                .foregroundColor(simulator.isRunning
                                 ? .orange
                                 : (hasTask ? .white.opacity(0.7) : .white.opacity(0.25)))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.55))
                        .overlay(Capsule().stroke(
                            simulator.isRunning ? Color.orange : Color.clear,
                            lineWidth: 1.5))
                )
            }
            .disabled(!hasTask && !simulator.isRunning)

        case .waypoints:
            Button { showWaypoints = true } label: {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white.opacity(0.85))
                    .padding(7)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }

        case .task:
            Button { showTaskEditor = true } label: {
                HStack(spacing: 4) {
                    Image(systemName: task.turnpoints.isEmpty ? "flag" : "flag.checkered")
                        .font(.system(size: 13, weight: .bold))
                    if !task.turnpoints.isEmpty {
                        Text("\(task.turnpoints.count)")
                            .font(.system(size: 11, weight: .heavy, design: .rounded))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .foregroundColor(task.turnpoints.isEmpty
                                 ? .white.opacity(0.7)
                                 : Color(red: 0.35, green: 0.80, blue: 1.0))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.55)))
            }

        case .share:
            Button { onShareTap() } label: {
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

        case .settings:
            Button { showSettings = true } label: {
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

/// Compact recording-state indicator next to the GPS pill in the top
/// bar. Always visible — when idle it shows a dim hollow record icon
/// + "REC" text in muted gray, signalling "recording is armed but
/// nothing is being written"; when an IGC file is open it flips to a
/// strong red background with a filled white dot that pulses, the
/// same visual cue as the panel's Recording Toggle card so the two
/// stay in sync. Tapping the pill toggles recording on/off — same
/// action as the panel's Recording Toggle card, so pilots who don't
/// have the panel card placed (or whose panel is currently
/// scrolled/covered) still have a one-tap manual override.
struct RecordingStatusPill: View {
    @ObservedObject var recorder: FlightRecorder
    /// Disables the toggle (and dims the pill) while the simulator
    /// is running. Sim data is synthetic; we deliberately don't let
    /// it stream into an IGC file — a sim "flight" uploaded to
    /// XContest / Leonardo would be misleading.
    @ObservedObject var simulator: FlightSimulator
    /// 0…1 phase used to pulse the red dot while recording.
    @State private var pulse: Double = 0
    private let pulseTimer = Timer.publish(every: 0.05, on: .main, in: .common).autoconnect()

    var body: some View {
        Button {
            if recorder.isRecording {
                _ = recorder.stopFlight()
            } else {
                recorder.startFlight()
            }
        } label: {
            HStack(spacing: 5) {
                // Icon: filled & pulsing while recording, hollow & static
                // when idle. We draw the dot manually (rather than using
                // SF Symbols) so the pulse animation is identical to the
                // panel's Recording Toggle card.
                ZStack {
                    if recorder.isRecording {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 9, height: 9)
                            .scaleEffect(1.0 + 0.20 * pulse)
                            .opacity(0.75 + 0.25 * pulse)
                    } else {
                        Circle()
                            .stroke(Color.white.opacity(0.55), lineWidth: 1.4)
                            .frame(width: 9, height: 9)
                    }
                }
                .frame(width: 11, height: 11)

                Text("REC")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.5)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundColor(recorder.isRecording
                             ? .white
                             : .white.opacity(0.45))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(recorder.isRecording
                          ? Color(red: 0.85, green: 0.15, blue: 0.15)
                          : Color.black.opacity(0.55))
            )
            // Sim-active dim: ghost the whole pill so the pilot sees
            // the control is unavailable in this mode. Active red
            // recordings are already exclusive with sim mode (the
            // simulator-lifecycle hook in FlightRecorder stops a
            // real recording the moment a sim is started), so we
            // never end up dimming a live red pill.
            .opacity(simulator.isRunning ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(simulator.isRunning)
        .onReceive(pulseTimer) { _ in
            // Sine in 0…1 with ~1.2 s period — same cadence as the
            // panel toggle card so the two indicators visibly beat
            // in unison.
            let t = Date().timeIntervalSinceReferenceDate
            pulse = (sin(t * 2 * .pi / 1.2) + 1) / 2
        }
    }
}
