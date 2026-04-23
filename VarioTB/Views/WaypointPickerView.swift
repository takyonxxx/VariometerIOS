import SwiftUI

/// Modal picker that lets the user browse waypoint lists and pick a
/// waypoint to use. Used when adding a turnpoint to a task.
///
/// Two-level drill-down:
///   Level 1: list of WaypointLists
///   Level 2: waypoints inside the selected list
struct WaypointPickerView: View {
    let onPick: (Waypoint) -> Void
    @Binding var isPresented: Bool
    @ObservedObject private var library: WaypointLibrary = .shared
    @ObservedObject private var language = LanguagePreference.shared
    @State private var selectedList: WaypointList? = nil

    var body: some View {
        let _ = language.code
        return NavigationView {
            Group {
                if let list = selectedList {
                    // Level 2: waypoints in the selected list
                    List {
                        ForEach(list.waypoints) { wp in
                            Button {
                                onPick(wp)
                                isPresented = false
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill")
                                        .foregroundColor(.cyan)
                                        .font(.system(size: 22))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(wp.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                        Text(String(format: "%.4f°, %.4f°",
                                                    wp.latitude, wp.longitude))
                                            .font(.system(size: 11, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "plus.circle")
                                        .foregroundColor(.cyan)
                                        .font(.system(size: 18))
                                }
                            }
                        }
                    }
                    .navigationTitle(list.name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .navigationBarLeading) {
                            Button(L10n.string("back")) {
                                selectedList = nil
                            }
                        }
                    }
                } else {
                    // Level 1: list of WaypointLists
                    List {
                        if library.lists.isEmpty || library.lists.allSatisfy({ $0.waypoints.isEmpty }) {
                            Section {
                                Text(L10n.string("waypoint_picker_empty"))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Section(header: Text(L10n.string("select_from_list"))) {
                            ForEach(library.lists.filter { !$0.waypoints.isEmpty }) { list in
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
                        }
                    }
                    .navigationTitle(L10n.string("pick_waypoint"))
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("cancel")) { isPresented = false }
                }
            }
        }
    }
}
