import SwiftUI
import CoreLocation

/// Competition task page — builds a task by picking waypoints from the
/// library (Waypoints page). Also supports QR share and QR scan for
/// exchanging XCTrack-compatible tasks between devices.
struct CompetitionTaskView: View {
    @ObservedObject var task: CompetitionTask
    @Binding var isPresented: Bool
    /// Deep-link payload queued by ContentView when the app is opened
    /// via an xctsk:// URL. On appear we process this as if the pilot
    /// had scanned a QR inside the app, then clear it so subsequent
    /// openings of this sheet don't re-import.
    var deepLinkPayload: Binding<String?>? = nil
    @ObservedObject private var language = LanguagePreference.shared
    @ObservedObject private var library: WaypointLibrary = .shared

    @State private var editingTurnpoint: Turnpoint? = nil
    @State private var showWaypointPicker: Bool = false
    @State private var showQRShareSheet: Bool = false
    @State private var showQRScanner: Bool = false
    @State private var scanMessage: String? = nil
    @State private var showScanMessage: Bool = false
    @State private var pendingImport: PendingTaskImport? = nil

    var totalKm: Double { task.totalDistanceM / 1000.0 }

    var body: some View {
        let _ = language.code
        return NavigationView {
            List {
                // Task summary
                Section {
                    HStack {
                        Label(L10n.string("task_distance"),
                              systemImage: "flag.checkered")
                        Spacer()
                        Text(String(format: "%.1f km", totalKm))
                            .fontWeight(.bold)
                            .foregroundColor(.cyan)
                    }
                    HStack {
                        Label(L10n.string("turnpoint_count"),
                              systemImage: "mappin.and.ellipse")
                        Spacer()
                        Text("\(task.turnpoints.count)")
                            .fontWeight(.semibold)
                    }
                }

                // Share / Scan
                Section(header: Text(L10n.string("task_share"))) {
                    Button {
                        showQRScanner = true
                    } label: {
                        Label(L10n.string("task_scan_qr"),
                              systemImage: "qrcode.viewfinder")
                            .fontWeight(.semibold)
                    }
                    if !task.turnpoints.isEmpty {
                        Button {
                            showQRShareSheet = true
                        } label: {
                            Label(L10n.string("task_share_qr"),
                                  systemImage: "qrcode")
                                .fontWeight(.semibold)
                        }
                    }
                }

                // Timing — shown only if task has timing set, or pilot enables it
                Section(header: Text(L10n.string("task_timing"))) {
                    // Start time (SSS window open)
                    if task.taskStartTime != nil {
                        DatePicker(L10n.string("task_start"),
                                   selection: Binding(
                                    get: { task.taskStartTime ?? Date() },
                                    set: { task.taskStartTime = $0 }
                                   ),
                                   displayedComponents: [.hourAndMinute])
                        Button(role: .destructive) {
                            task.taskStartTime = nil
                        } label: {
                            Label(L10n.string("clear_start_time"),
                                  systemImage: "xmark.circle")
                                .font(.caption)
                        }
                    } else {
                        Button {
                            var cal = Calendar(identifier: .gregorian)
                            cal.timeZone = TimeZone(identifier: "UTC")!
                            task.taskStartTime = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date())
                        } label: {
                            Label(L10n.string("set_task_start"),
                                  systemImage: "clock")
                        }
                    }

                    // Deadline (goal close)
                    if task.taskDeadline != nil {
                        DatePicker(L10n.string("task_deadline"),
                                   selection: Binding(
                                    get: { task.taskDeadline ?? Date() },
                                    set: { task.taskDeadline = $0 }
                                   ),
                                   displayedComponents: [.hourAndMinute])
                        Button(role: .destructive) {
                            task.taskDeadline = nil
                        } label: {
                            Label(L10n.string("clear_deadline"),
                                  systemImage: "xmark.circle")
                                .font(.caption)
                        }
                    } else {
                        Button {
                            var cal = Calendar(identifier: .gregorian)
                            cal.timeZone = TimeZone(identifier: "UTC")!
                            task.taskDeadline = cal.date(bySettingHour: 16, minute: 0, second: 0, of: Date())
                        } label: {
                            Label(L10n.string("set_task_deadline"),
                                  systemImage: "flag.checkered")
                        }
                    }
                }

                // Turnpoints
                Section(header: Text(L10n.string("turnpoints"))) {
                    if task.turnpoints.isEmpty {
                        Text(L10n.string("turnpoints_empty"))
                            .foregroundColor(.secondary)
                    }
                    ForEach(Array(task.turnpoints.enumerated()), id: \.element.id) { idx, tp in
                        // Cumulative task distance from TAKEOFF up to
                        // this TP — sabit, GPS'ten bağımsız. Flyskyhy
                        // "Route" list convention: each row shows how
                        // far this TP sits along the planned course.
                        TurnpointRow(index: idx + 1,
                                     turnpoint: tp,
                                     cumulativeM: task.cumulativeOptimumDistanceTo(tpIndex: idx))
                            .contentShape(Rectangle())
                            .onTapGesture { editingTurnpoint = tp }
                    }
                    .onDelete { task.removeTurnpoint(at: $0) }
                    .onMove { task.moveTurnpoint(from: $0, to: $1) }

                    Button {
                        showWaypointPicker = true
                    } label: {
                        Label(L10n.string("add_from_waypoints"),
                              systemImage: "plus.circle.fill")
                            .fontWeight(.semibold)
                    }
                }

                if !task.turnpoints.isEmpty {
                    Section {
                        Button(role: .destructive) {
                            task.turnpoints.removeAll()
                        } label: {
                            Label(L10n.string("clear_task"), systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(L10n.string("competition_task"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) {
                        try? task.saveAsActive()
                        isPresented = false
                    }
                }
            }
            .sheet(item: $editingTurnpoint) { tp in
                TurnpointEditorView(turnpoint: tp) { updated in
                    if let idx = task.turnpoints.firstIndex(where: { $0.id == updated.id }) {
                        task.turnpoints[idx] = updated
                    }
                    editingTurnpoint = nil
                }
            }
            .sheet(isPresented: $showWaypointPicker) {
                WaypointPickerView(
                    onPick: { wp in
                        let type = defaultTypeForNewTurnpoint()
                        let tp = Turnpoint(
                            name: wp.name,
                            type: type,
                            latitude: wp.latitude,
                            longitude: wp.longitude,
                            altitudeM: wp.altitudeM,
                            radiusM: defaultRadius(for: type),
                            direction: type.defaultDirection
                        )
                        task.addTurnpoint(tp)
                    },
                    isPresented: $showWaypointPicker
                )
            }
            .sheet(isPresented: $showQRShareSheet) {
                TaskQRShareView(task: task, isPresented: $showQRShareSheet)
            }
            .fullScreenCover(isPresented: $showQRScanner) {
                QRScannerView(
                    onScan: { code in
                        showQRScanner = false
                        handleScannedCode(code)
                    },
                    onCancel: { showQRScanner = false }
                )
            }
            .alert(L10n.string("task_scan_title"),
                   isPresented: $showScanMessage,
                   presenting: scanMessage) { _ in
                Button("OK", role: .cancel) { }
            } message: { msg in
                Text(msg)
            }
            .taskImportDialog(pending: $pendingImport,
                              task: task,
                              library: library) { action, count in
                let key: String
                switch action {
                case .addToRoute:         key = "task_scan_added"
                case .replaceRoute:       key = "task_scan_replaced"
                case .newWaypointGroup:   key = "task_scan_group"
                }
                scanMessage = String(format: L10n.string(key), count)
                showScanMessage = true
            }
            .onAppear {
                // If ContentView queued a deep-link import, process it
                // as though the pilot had just scanned this QR in-app.
                // Binding write clears the payload so reopening the
                // sheet later doesn't re-import.
                if let payload = deepLinkPayload?.wrappedValue {
                    deepLinkPayload?.wrappedValue = nil
                    handleScannedCode(payload)
                }
            }
        }
    }

    // MARK: - Helpers

    private func defaultTypeForNewTurnpoint() -> TurnpointType {
        switch task.turnpoints.count {
        case 0: return .takeoff
        case 1: return .sss
        default: return .turn
        }
    }

    private func defaultRadius(for type: TurnpointType) -> Double {
        switch type {
        case .takeoff: return 400
        case .sss:     return 2000
        case .turn:    return 400
        case .ess:     return 1000
        case .goal:    return 400
        }
    }

    private func handleScannedCode(_ code: String) {
        guard let imported = TaskQRCodec.decodeTask(from: code) else {
            scanMessage = L10n.string("task_scan_failed")
            showScanMessage = true
            return
        }
        // Show Flyskyhy-style dialog: add to route / replace route / new group
        pendingImport = PendingTaskImport(imported: imported)
    }
}

// MARK: - QR share sheet for a task

private struct TaskQRShareView: View {
    @ObservedObject var task: CompetitionTask
    @Binding var isPresented: Bool
    @ObservedObject private var language = LanguagePreference.shared

    /// TR+UTC human-readable time for the info block. Returns em-dash
    /// when no date is set so the layout doesn't jump.
    private func formattedLocalTime(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    var body: some View {
        let _ = language.code
        return NavigationView {
            ZStack {
                // Gradient backdrop — signals "branded deliverable" and
                // frames the QR card nicely on any device size.
                LinearGradient(
                    colors: [
                        Color(red: 0.05, green: 0.08, blue: 0.14),
                        Color(red: 0.10, green: 0.15, blue: 0.25),
                    ],
                    startPoint: .top, endPoint: .bottom
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 18) {
                        // Header: app brand + task name
                        VStack(spacing: 6) {
                            HStack(spacing: 10) {
                                Image(systemName: "flag.checkered")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(LinearGradient(
                                        colors: [.cyan, .blue],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                                Text("VARIO TB")
                                    .font(.system(size: 18, weight: .heavy, design: .rounded))
                                    .tracking(3)
                                    .foregroundStyle(LinearGradient(
                                        colors: [.cyan, .blue],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                            }
                            Text(task.name.isEmpty ? L10n.string("task_share_qr") : task.name)
                                .font(.system(size: 22, weight: .bold, design: .rounded))
                                .foregroundColor(.white)
                        }
                        .padding(.top, 8)

                        // Info pills row: start • deadline • distance
                        HStack(spacing: 8) {
                            infoPill(
                                icon: "play.circle.fill",
                                label: L10n.string("task_start"),
                                value: formattedLocalTime(task.taskStartTime),
                                tint: .green)
                            infoPill(
                                icon: "clock.badge.exclamationmark.fill",
                                label: L10n.string("task_deadline"),
                                value: formattedLocalTime(task.taskDeadline),
                                tint: .orange)
                        }
                        .padding(.horizontal, 24)

                        HStack(spacing: 8) {
                            infoPill(
                                icon: "mappin.and.ellipse",
                                label: "TP",
                                value: "\(task.turnpoints.count)",
                                tint: .cyan)
                            infoPill(
                                icon: "arrow.triangle.swap",
                                label: L10n.string("task_distance"),
                                value: String(format: "%.1f km", task.totalDistanceM / 1000.0),
                                tint: Color(red: 0.95, green: 0.3, blue: 0.5))
                        }
                        .padding(.horizontal, 24)

                        // QR code — framed in a bright white card with
                        // rounded corners and soft shadow so it reads
                        // clearly on the dark gradient.
                        if let img = TaskQRCodec.generateQR(for: task, size: 320) {
                            Image(uiImage: img)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .padding(18)
                                .background(
                                    RoundedRectangle(cornerRadius: 22)
                                        .fill(Color.white)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 22)
                                        .strokeBorder(
                                            LinearGradient(
                                                colors: [.cyan.opacity(0.7),
                                                         .blue.opacity(0.5)],
                                                startPoint: .topLeading,
                                                endPoint: .bottomTrailing),
                                            lineWidth: 2)
                                )
                                .shadow(color: .cyan.opacity(0.25), radius: 20, y: 6)
                                .padding(.horizontal, 28)
                        }

                        // Scan hint
                        Label {
                            Text(L10n.string("qr_share_hint"))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.7))
                                .multilineTextAlignment(.center)
                        } icon: {
                            Image(systemName: "camera.viewfinder")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.cyan.opacity(0.8))
                        }
                        .padding(.horizontal, 28)

                        // Turnpoint list preview — compact, one line each
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("task_route").uppercased())
                                .font(.system(size: 11, weight: .heavy))
                                .tracking(1.5)
                                .foregroundColor(.white.opacity(0.45))
                                .padding(.leading, 2)
                            ForEach(Array(task.turnpoints.enumerated()), id: \.element.id) { idx, tp in
                                turnpointRowCompact(index: idx + 1, tp: tp)
                            }
                        }
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.06))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)

                        // Footer branding
                        Text("variotb://  •  XCTrack compatible")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.35))
                            .padding(.top, 4)
                            .padding(.bottom, 20)
                    }
                }
            }
            .navigationTitle(L10n.string("task_share_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) { isPresented = false }
                        .foregroundColor(.cyan)
                }
            }
        }
    }

    /// Reusable pill for the SSS / deadline / TP / distance summary row.
    /// Two-line layout: icon + label on top, value below.
    @ViewBuilder
    private func infoPill(icon: String,
                           label: String,
                           value: String,
                           tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(tint)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(0.8)
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
    }

    /// One-line turnpoint row for the preview list. Shows
    /// #index • name • type chip • "r=2.0km".
    @ViewBuilder
    private func turnpointRowCompact(index: Int, tp: Turnpoint) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 20, alignment: .trailing)

            Text(tp.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(tp.type.rawValue)
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.5)
                .foregroundColor(typeColor(for: tp.type))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(typeColor(for: tp.type).opacity(0.15))
                )

            Text(formatRadius(tp.radiusM))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))
                .frame(width: 54, alignment: .trailing)
        }
    }

    private func typeColor(for type: TurnpointType) -> Color {
        switch type {
        case .takeoff: return .green
        case .sss:     return .yellow
        case .turn:    return .cyan
        case .ess:     return .orange
        case .goal:    return Color(red: 0.95, green: 0.3, blue: 0.5)
        }
    }

    private func formatRadius(_ m: Double) -> String {
        if m >= 1000 {
            return String(format: "%.1fkm", m / 1000)
        } else {
            return "\(Int(m))m"
        }
    }
}

// MARK: - Turnpoint row

private struct TurnpointRow: View {
    let index: Int
    let turnpoint: Turnpoint
    /// Cumulative optimum-route distance from task start to THIS TP,
    /// in meters. Pass 0 for the first (takeoff) row. The list callsite
    /// computes this once using `task.cumulativeOptimumDistanceTo`.
    let cumulativeM: Double

    var typeColor: Color {
        switch turnpoint.type {
        case .takeoff: return .green
        case .sss:     return .cyan
        case .turn:    return .blue
        case .ess:     return Color(red: 1.0, green: 0.65, blue: 0.3)
        case .goal:    return .red
        }
    }

    /// Pretty-print the cumulative distance from task start. Meters
    /// when < 1 km, otherwise km with one decimal. Hidden for the
    /// takeoff row (always 0 — redundant to show).
    private var cumulativeText: String? {
        if index == 1 { return nil }
        if cumulativeM < 1 { return "0 m" }
        if cumulativeM < 1000 {
            return String(format: "%.0f m", cumulativeM)
        }
        return String(format: "%.1f km", cumulativeM / 1000)
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(typeColor.opacity(0.2))
                    .frame(width: 30, height: 30)
                Text("\(index)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(typeColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(turnpoint.name)
                        .font(.system(size: 15, weight: .semibold))
                    Text(turnpoint.type.rawValue)
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(typeColor))
                        .foregroundColor(.white)
                    if turnpoint.optional {
                        Text("OPT")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().stroke(Color.gray))
                            .foregroundColor(.gray)
                    }
                }
                Text(turnpoint.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                if let st = turnpoint.startTime {
                    Label(Self.timeFormatter.string(from: st),
                          systemImage: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(.cyan)
                }
            }

            Spacer()

            // Cumulative optimum distance to this TP from task start.
            // Hidden on the takeoff row (always 0 — redundant).
            if let text = cumulativeText {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(text)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundColor(.cyan)
                        .monospacedDigit()
                    Text("opt")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Image(systemName: "chevron.right")
                .foregroundColor(.gray.opacity(0.5))
                .font(.system(size: 12))
        }
        .padding(.vertical, 4)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
}
