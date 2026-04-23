import SwiftUI

/// Editor for a single turnpoint — name, coordinates, type, radius,
/// direction (enter/exit/line), optional flag, start time, description.
struct TurnpointEditorView: View {
    @State private var draft: Turnpoint
    let onSave: (Turnpoint) -> Void
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var language = LanguagePreference.shared
    @State private var hasStartTime: Bool

    init(turnpoint: Turnpoint, onSave: @escaping (Turnpoint) -> Void) {
        _draft = State(initialValue: turnpoint)
        self.onSave = onSave
        _hasStartTime = State(initialValue: turnpoint.startTime != nil)
    }

    var body: some View {
        let _ = language.code
        return NavigationView {
            Form {
                // Name + description
                Section(header: Text(L10n.string("tp_identity"))) {
                    TextField(L10n.string("tp_name"), text: $draft.name)
                    TextField(L10n.string("tp_description"), text: $draft.description)
                }

                // Type
                Section(header: Text(L10n.string("tp_type"))) {
                    Picker(L10n.string("tp_type"), selection: $draft.type) {
                        ForEach(TurnpointType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: draft.type) { newType in
                        // Auto-adjust direction when type changes
                        draft.direction = newType.defaultDirection
                    }
                }

                // Coordinates
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

                // Cylinder
                Section(header: Text(L10n.string("tp_cylinder"))) {
                    HStack {
                        Text(L10n.string("tp_radius"))
                        Spacer()
                        Text("\(Int(draft.radiusM)) m")
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $draft.radiusM, in: 50...10000, step: 50)

                    // Common radius shortcuts
                    HStack(spacing: 8) {
                        ForEach([400.0, 1000.0, 2000.0, 4000.0], id: \.self) { r in
                            Button("\(Int(r))m") { draft.radiusM = r }
                                .buttonStyle(.bordered)
                                .font(.system(size: 12))
                        }
                    }

                    Picker(L10n.string("tp_reached_on"), selection: $draft.direction) {
                        Text(L10n.string("tp_enter")).tag(TurnpointDirection.enter)
                        Text(L10n.string("tp_exit")).tag(TurnpointDirection.exit)
                        Text(L10n.string("tp_line")).tag(TurnpointDirection.line)
                    }
                    .pickerStyle(.segmented)
                }

                // Start time (only for SSS)
                if draft.type == .sss {
                    Section(header: Text(L10n.string("tp_start_time"))) {
                        Toggle(L10n.string("tp_has_start_time"), isOn: $hasStartTime)
                            .onChange(of: hasStartTime) { enabled in
                                draft.startTime = enabled ? (draft.startTime ?? Date()) : nil
                            }
                        if hasStartTime {
                            DatePicker(L10n.string("tp_start_time"),
                                       selection: Binding(
                                        get: { draft.startTime ?? Date() },
                                        set: { draft.startTime = $0 }
                                       ),
                                       displayedComponents: [.hourAndMinute])
                        }
                    }
                }

                // Optional flag
                Section {
                    Toggle(L10n.string("tp_optional"), isOn: $draft.optional)
                    Text(L10n.string("tp_optional_hint"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle(L10n.string("edit_turnpoint"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("save")) {
                        if !hasStartTime { draft.startTime = nil }
                        onSave(draft)
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
