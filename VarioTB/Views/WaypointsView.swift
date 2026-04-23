import SwiftUI
import UniformTypeIdentifiers

/// The main Waypoints page — shows all waypoint lists the pilot has
/// collected. Each list can be opened to view its waypoints, edit them,
/// or share them. New lists can be added via:
///   - Manual add (name the list, then add waypoints one by one)
///   - File import (.xctsk, .gpx, .wpt)
///   - QR code scan (XCTrack-compatible tasks)
struct WaypointsView: View {
    @ObservedObject var library: WaypointLibrary = .shared
    @ObservedObject var task: CompetitionTask
    @Binding var isPresented: Bool
    @ObservedObject private var language = LanguagePreference.shared

    @State private var showAddListAlert = false
    @State private var newListName = ""
    @State private var showFileImporter = false
    @State private var showQRScanner = false
    @State private var importMessage: String? = nil
    @State private var selectedList: WaypointList? = nil
    @State private var pendingImport: PendingTaskImport? = nil

    var body: some View {
        let _ = language.code
        return NavigationView {
            List {
                if library.lists.isEmpty {
                    Section {
                        Text(L10n.string("waypoint_lists_empty"))
                            .foregroundColor(.secondary)
                    }
                }
                Section(header: Text(L10n.string("waypoint_lists"))) {
                    ForEach(library.lists) { list in
                        Button {
                            selectedList = list
                        } label: {
                            HStack {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(.cyan)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(list.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(.primary)
                                    Text("\(list.waypoints.count) waypoint")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundColor(.gray.opacity(0.5))
                                    .font(.system(size: 12))
                            }
                        }
                    }
                    .onDelete { library.removeList(at: $0) }
                }

                // Add actions
                Section(header: Text(L10n.string("add_waypoints"))) {
                    Button {
                        newListName = ""
                        showAddListAlert = true
                    } label: {
                        Label(L10n.string("new_list"),
                              systemImage: "plus.rectangle.on.rectangle")
                    }
                    Button {
                        showFileImporter = true
                    } label: {
                        Label(L10n.string("import_file"),
                              systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showQRScanner = true
                    } label: {
                        Label(L10n.string("scan_qr"),
                              systemImage: "qrcode.viewfinder")
                    }
                }
            }
            .navigationTitle(L10n.string("waypoints"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) {
                        library.saveNow()
                        isPresented = false
                    }
                }
            }
            .alert(L10n.string("new_list"), isPresented: $showAddListAlert) {
                TextField(L10n.string("list_name"), text: $newListName)
                Button(L10n.string("cancel"), role: .cancel) { }
                Button(L10n.string("create")) {
                    let name = newListName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        _ = library.addList(named: name)
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: Self.importableTypes,
                          allowsMultipleSelection: false) { result in
                handleFileImport(result: result)
            }
            .fullScreenCover(isPresented: $showQRScanner) {
                QRScannerView(
                    onScan: { payload in
                        showQRScanner = false
                        handleQRScan(payload: payload)
                    },
                    onCancel: { showQRScanner = false }
                )
            }
            .sheet(item: $selectedList) { list in
                WaypointListDetailView(list: list, isPresented: Binding(
                    get: { selectedList != nil },
                    set: { if !$0 { selectedList = nil } }
                ))
            }
            .overlay(alignment: .bottom) {
                if let msg = importMessage {
                    ImportToast(message: msg)
                        .padding(.bottom, 30)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                                withAnimation { importMessage = nil }
                            }
                        }
                }
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
                show(String(format: L10n.string(key), count))
            }
        }
    }

    private static var importableTypes: [UTType] {
        var types: [UTType] = [.json, .xml, .plainText]
        if let xctsk = UTType(filenameExtension: "xctsk") { types.append(xctsk) }
        if let gpx = UTType(filenameExtension: "gpx") { types.append(gpx) }
        if let wpt = UTType(filenameExtension: "wpt") { types.append(wpt) }
        return types
    }

    // MARK: - Import handlers

    private func handleFileImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        // Security-scoped resource for files outside the sandbox
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else {
            show("import_failed")
            return
        }
        let waypoints = WaypointFileParser.parse(data: data,
                                                  filename: url.lastPathComponent)
        guard !waypoints.isEmpty else {
            show("import_no_waypoints")
            return
        }
        // Create a new list from the filename (without extension)
        let listName = (url.deletingPathExtension().lastPathComponent)
        let list = library.addList(named: listName)
        library.appendWaypoints(waypoints, to: list)
        show(String(format: L10n.string("import_success"), waypoints.count))
    }

    private func handleQRScan(payload: String) {
        guard let imported = TaskQRCodec.decodeTask(from: payload) else {
            show("qr_invalid")
            return
        }
        // Show Flyskyhy-style 3-option dialog instead of silently creating
        // a list. Lets the pilot choose: add to current task route, replace
        // the active task, or just add as a new waypoint group.
        pendingImport = PendingTaskImport(imported: imported)
    }

    private func show(_ message: String) {
        withAnimation {
            importMessage = L10n.string(message).contains("%") ? message : L10n.string(message)
        }
    }
}

private struct ImportToast: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(
                Capsule().fill(Color.black.opacity(0.85))
            )
    }
}
