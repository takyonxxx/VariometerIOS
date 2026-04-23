import SwiftUI

/// Holds a pending import (from QR scan or file) and the user's chosen
/// action. Used by both CompetitionTaskView and WaypointsView so the
/// user sees the same 3-way Flyskyhy-style dialog regardless of where
/// they scanned the QR code.
///
/// Usage:
///   @State var pending: PendingTaskImport?
///   ...
///   .taskImportDialog(pending: $pending,
///                     task: task,
///                     library: library)
struct PendingTaskImport: Identifiable {
    let id = UUID()
    let imported: ImportedTask
}

/// Actions the user can take with an imported task.
enum TaskImportAction {
    /// Append the imported turnpoints to the end of the active task.
    case addToRoute
    /// Replace the active task's turnpoints with the imported ones.
    case replaceRoute
    /// Create a new waypoint group in the library (doesn't touch the task).
    case newWaypointGroup
}

extension View {
    /// Attach a Flyskyhy-style 3-option import dialog to this view.
    /// The dialog is shown whenever `pending` is non-nil; the user's
    /// selection is applied to the given task / library, then `pending`
    /// is cleared.
    func taskImportDialog(pending: Binding<PendingTaskImport?>,
                          task: CompetitionTask,
                          library: WaypointLibrary,
                          onResult: ((TaskImportAction, Int) -> Void)? = nil) -> some View {
        self.confirmationDialog(
            L10n.string("import_waypoints_title"),
            isPresented: Binding(
                get: { pending.wrappedValue != nil },
                set: { if !$0 { pending.wrappedValue = nil } }
            ),
            titleVisibility: .visible,
            presenting: pending.wrappedValue
        ) { item in
            Button(L10n.string("add_to_route")) {
                apply(.addToRoute, imported: item.imported,
                      task: task, library: library, onResult: onResult)
                pending.wrappedValue = nil
            }
            Button(L10n.string("replace_route")) {
                apply(.replaceRoute, imported: item.imported,
                      task: task, library: library, onResult: onResult)
                pending.wrappedValue = nil
            }
            Button(L10n.string("new_waypoint_group")) {
                apply(.newWaypointGroup, imported: item.imported,
                      task: task, library: library, onResult: onResult)
                pending.wrappedValue = nil
            }
            Button(L10n.string("cancel"), role: .cancel) {
                pending.wrappedValue = nil
            }
        } message: { item in
            Text(String(format: L10n.string("import_waypoints_count"),
                        item.imported.waypoints.count))
        }
    }
}

/// Apply the chosen action. Always adds waypoints to the library too, so
/// that the pilot has them for later task-building — a "saves to WPs"
/// behaviour pilots expect in comps.
private func apply(_ action: TaskImportAction,
                   imported: ImportedTask,
                   task: CompetitionTask,
                   library: WaypointLibrary,
                   onResult: ((TaskImportAction, Int) -> Void)?) {
    switch action {
    case .addToRoute:
        // Append turnpoints with their task-specific settings (type/radius).
        for spec in imported.turnpointSpecs {
            let wp = imported.waypoints[spec.waypointIndex]
            let tp = Turnpoint(
                name: wp.name,
                type: spec.type,
                latitude: wp.latitude,
                longitude: wp.longitude,
                altitudeM: wp.altitudeM,
                radiusM: spec.radiusM,
                direction: spec.type.defaultDirection
            )
            task.addTurnpoint(tp)
        }
        // Also save waypoints to library so they're reusable later.
        mergeIntoLibrary(imported.waypoints,
                         library: library,
                         listName: imported.name)
        try? task.saveAsActive()

    case .replaceRoute:
        task.applyImported(imported)
        mergeIntoLibrary(imported.waypoints,
                         library: library,
                         listName: imported.name)
        try? task.saveAsActive()

    case .newWaypointGroup:
        // Just create a library list — don't touch the task.
        let list = library.addList(named: imported.name)
        library.appendWaypoints(imported.waypoints, to: list)
    }
    onResult?(action, imported.waypoints.count)
}

/// Merge waypoints into a list matching `listName`, creating it if missing.
/// Skips exact duplicates (same name + coord within 10 m).
private func mergeIntoLibrary(_ waypoints: [Waypoint],
                              library: WaypointLibrary,
                              listName: String) {
    // Find or create the target list.
    let list: WaypointList
    if let existing = library.lists.first(where: { $0.name == listName }) {
        list = existing
    } else {
        list = library.addList(named: listName)
    }
    // Duplicate detection within that list.
    var toAdd: [Waypoint] = []
    for wp in waypoints {
        let dup = list.waypoints.contains { other in
            other.name == wp.name &&
            CompetitionTask.haversine(other.coordinate, wp.coordinate) < 10
        }
        if !dup {
            toAdd.append(wp)
        }
    }
    if !toAdd.isEmpty {
        library.appendWaypoints(toAdd, to: list)
    }
}
