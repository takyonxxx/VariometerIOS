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
            }
            .foregroundColor(locationMgr.hasFix ? .green : .orange)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Color.black.opacity(0.55)))

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
