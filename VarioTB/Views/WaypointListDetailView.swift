import SwiftUI

/// Detail view for a single waypoint list — shows all waypoints,
/// lets the pilot add new ones manually, edit existing, reorder or delete.
struct WaypointListDetailView: View {
    @ObservedObject var list: WaypointList
    @Binding var isPresented: Bool
    @ObservedObject private var language = LanguagePreference.shared
    private let library = WaypointLibrary.shared

    @State private var editing: Waypoint? = nil
    @State private var showAddSheet = false

    var body: some View {
        let _ = language.code
        return NavigationView {
            List {
                if list.waypoints.isEmpty {
                    Section {
                        Text(L10n.string("waypoints_empty_list"))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Section(header: Text("\(list.waypoints.count) " + L10n.string("waypoints"))) {
                        ForEach(list.waypoints) { wp in
                            WaypointRow(waypoint: wp)
                                .contentShape(Rectangle())
                                .onTapGesture { editing = wp }
                        }
                        .onDelete { indexSet in
                            library.removeWaypoints(at: indexSet, from: list)
                        }
                    }
                }

                Section {
                    Button {
                        showAddSheet = true
                    } label: {
                        Label(L10n.string("add_waypoint"), systemImage: "plus.circle.fill")
                            .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle(list.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("close")) {
                        library.saveNow()
                        isPresented = false
                    }
                }
            }
            .sheet(item: $editing) { wp in
                WaypointEditorView(waypoint: wp) { updated in
                    library.updateWaypoint(updated, in: list)
                    editing = nil
                }
            }
            .sheet(isPresented: $showAddSheet) {
                WaypointEditorView(waypoint: Waypoint(
                    name: "WP\(list.waypoints.count + 1)",
                    latitude: 40.0318,
                    longitude: 32.3282,
                    altitudeM: 0
                )) { newWP in
                    library.addWaypoint(newWP, to: list)
                    showAddSheet = false
                }
            }
        }
    }
}

private struct WaypointRow: View {
    let waypoint: Waypoint

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "mappin.circle.fill")
                .foregroundColor(.cyan)
                .font(.system(size: 22))
            VStack(alignment: .leading, spacing: 2) {
                Text(waypoint.name)
                    .font(.system(size: 14, weight: .semibold))
                HStack(spacing: 8) {
                    Text(String(format: "%.4f°, %.4f°",
                                waypoint.latitude, waypoint.longitude))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    if waypoint.altitudeM > 0 {
                        Text(String(format: "%.0f m", waypoint.altitudeM))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .foregroundColor(.gray.opacity(0.5))
                .font(.system(size: 12))
        }
        .padding(.vertical, 4)
    }
}

/// Edit a single waypoint (name, lat, lon, altitude, description).
struct WaypointEditorView: View {
    @State private var draft: Waypoint
    let onSave: (Waypoint) -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var language = LanguagePreference.shared

    init(waypoint: Waypoint, onSave: @escaping (Waypoint) -> Void) {
        _draft = State(initialValue: waypoint)
        self.onSave = onSave
    }

    var body: some View {
        let _ = language.code
        return NavigationView {
            Form {
                Section(header: Text(L10n.string("tp_identity"))) {
                    TextField(L10n.string("tp_name"), text: $draft.name)
                    TextField(L10n.string("tp_description"), text: $draft.description)
                }
                Section(header: Text(L10n.string("tp_location"))) {
                    HStack {
                        Text(L10n.string("latitude"))
                        Spacer()
                        TextField("40.0318", value: $draft.latitude,
                                  format: .number.precision(.fractionLength(6)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text(L10n.string("longitude"))
                        Spacer()
                        TextField("32.3282", value: $draft.longitude,
                                  format: .number.precision(.fractionLength(6)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numbersAndPunctuation)
                    }
                    HStack {
                        Text(L10n.string("altitude_m"))
                        Spacer()
                        TextField("0", value: $draft.altitudeM,
                                  format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }
                }
            }
            .navigationTitle(L10n.string("waypoint"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("save")) {
                        onSave(draft)
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
