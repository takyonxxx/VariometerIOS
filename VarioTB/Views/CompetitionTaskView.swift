import SwiftUI
import CoreLocation

/// Competition task page — builds a task by picking waypoints from the
/// library (Waypoints page). Also supports QR share and QR scan for
/// exchanging XCTrack-compatible tasks between devices.
struct CompetitionTaskView: View {
    @ObservedObject var task: CompetitionTask
    @Binding var isPresented: Bool
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
                        TurnpointRow(index: idx + 1, turnpoint: tp)
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

    var body: some View {
        let _ = language.code
        return NavigationView {
            VStack(spacing: 16) {
                Text(L10n.string("qr_share_hint"))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                if let img = TaskQRCodec.generateQR(for: task, size: 280) {
                    Image(uiImage: img)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color.white)
                                .shadow(color: .black.opacity(0.2), radius: 8)
                        )
                        .padding(.horizontal, 32)
                }

                Text("\(task.turnpoints.count) turnpoint • \(String(format: "%.1f", task.totalDistanceM / 1000.0)) km")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()
            }
            .padding(.top, 24)
            .navigationTitle(L10n.string("task_share_qr"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) { isPresented = false }
                }
            }
        }
    }
}

// MARK: - Turnpoint row

private struct TurnpointRow: View {
    let index: Int
    let turnpoint: Turnpoint

    var typeColor: Color {
        switch turnpoint.type {
        case .takeoff: return .green
        case .sss:     return .cyan
        case .turn:    return .blue
        case .ess:     return Color(red: 1.0, green: 0.65, blue: 0.3)
        case .goal:    return .red
        }
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
