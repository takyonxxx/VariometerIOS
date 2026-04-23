import SwiftUI
import MapKit
import CoreLocation

/// Full-screen customizable instrument panel. Every visible element —
/// vario, altitude, speed, coords, wind dial, thermal radar, clock,
/// battery, AND the satellite map — is a card on a 4-column grid.
///
/// Pilot interaction:
///   • Long-press (0.6s) anywhere on the panel → edit mode
///   • In edit mode: drag a card to move, drag the bottom-right corner
///     to resize, tap × to remove, tap "+" in the footer to add hidden
///     cards back
///   • Long-press again (or "Tamam") to exit edit mode
///
/// The grid has 4 fixed columns but unbounded rows — taller grids just
/// scroll. Every card's position (col, row) and size (width, height) is
/// persisted to AppSettings as JSON.
struct PanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var vario: VarioManager
    @ObservedObject var locationMgr: LocationManager
    @ObservedObject var wind: WindEstimator
    // Map-related bindings passed through to the MapCard
    @ObservedObject var fai: FAITriangleDetector
    @ObservedObject var task: CompetitionTask
    let fitTriangleToken: UUID?
    let fitTaskToken: UUID?
    @Binding var autoFollow: Bool
    /// Exposed so ContentView can disable outer ScrollView when we're
    /// not in edit mode — otherwise dragging a card fights the scroll.
    @Binding var editMode: Bool

    @State private var draggingCardID: UUID? = nil
    @State private var dragOffset: CGSize = .zero
    @State private var resizingCardID: UUID? = nil
    @State private var resizeDelta: CGSize = .zero

    var body: some View {
        let layout = settings.panelLayout
        let hSpacing: CGFloat = 5
        let vSpacing: CGFloat = 5
        let rowH: CGFloat = 52
        let rowCount = totalRows(layout: layout)
        let totalH = rowH * CGFloat(max(1, rowCount)) +
                     vSpacing * CGFloat(max(0, rowCount - 1))

        return GeometryReader { geo in
            let cols = PanelLayout.columns
            let colW = max(1, (geo.size.width - CGFloat(cols - 1) * hSpacing) / CGFloat(cols))

            ZStack(alignment: .topLeading) {
                if editMode {
                    gridBackground(colW: colW, rowH: rowH,
                                   hSpacing: hSpacing, vSpacing: vSpacing,
                                   rowCount: rowCount + 2)
                }

                ForEach(layout.cards) { card in
                    let (x, y) = position(card, colW: colW, rowH: rowH,
                                          hSpacing: hSpacing, vSpacing: vSpacing)
                    let (w, h) = size(card, colW: colW, rowH: rowH,
                                      hSpacing: hSpacing, vSpacing: vSpacing)
                    // Live-preview resize delta
                    let previewW: CGFloat = (resizingCardID == card.id)
                        ? max(colW, w + resizeDelta.width) : w
                    let previewH: CGFloat = (resizingCardID == card.id)
                        ? max(rowH, h + resizeDelta.height) : h

                    cardView(for: card)
                        .frame(width: previewW, height: previewH)
                        .overlay(editOverlay(for: card, w: previewW, h: previewH,
                                              colW: colW, rowH: rowH,
                                              hSpacing: hSpacing, vSpacing: vSpacing))
                        .offset(x: x, y: y)
                        .offset(draggingCardID == card.id ? dragOffset : .zero)
                        .gesture(
                            editMode ? dragGesture(for: card, colW: colW, rowH: rowH,
                                                    hSpacing: hSpacing, vSpacing: vSpacing)
                                     : nil
                        )
                        .animation(.spring(response: 0.25, dampingFraction: 0.85),
                                   value: layout.cards.map(\.id))
                        .zIndex(draggingCardID == card.id || resizingCardID == card.id ? 10 : 0)
                }
            }
            .frame(width: geo.size.width, height: totalH,
                   alignment: .topLeading)
            .onLongPressGesture(minimumDuration: 0.6) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    editMode.toggle()
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
        .frame(height: totalH)
    }

    // MARK: - Positioning

    private func position(_ card: PanelCard,
                          colW: CGFloat, rowH: CGFloat,
                          hSpacing: CGFloat, vSpacing: CGFloat) -> (CGFloat, CGFloat) {
        (CGFloat(card.col) * (colW + hSpacing),
         CGFloat(card.row) * (rowH + vSpacing))
    }

    private func size(_ card: PanelCard,
                      colW: CGFloat, rowH: CGFloat,
                      hSpacing: CGFloat, vSpacing: CGFloat) -> (CGFloat, CGFloat) {
        let w = CGFloat(card.width) * colW + CGFloat(max(0, card.width - 1)) * hSpacing
        let h = CGFloat(card.height) * rowH + CGFloat(max(0, card.height - 1)) * vSpacing
        return (w, h)
    }

    private func totalRows(layout: PanelLayout) -> Int {
        layout.cards.map { $0.row + $0.height }.max() ?? 1
    }

    // MARK: - Grid background

    private func gridBackground(colW: CGFloat, rowH: CGFloat,
                                hSpacing: CGFloat, vSpacing: CGFloat,
                                rowCount: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0..<rowCount, id: \.self) { row in
                ForEach(0..<PanelLayout.columns, id: \.self) { col in
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.cyan.opacity(0.12), style: StrokeStyle(
                            lineWidth: 1, dash: [3, 3]))
                        .frame(width: colW, height: rowH)
                        .offset(x: CGFloat(col) * (colW + hSpacing),
                                y: CGFloat(row) * (rowH + vSpacing))
                }
            }
        }
    }

    // MARK: - Edit overlay: delete badge + resize handle

    @ViewBuilder
    private func editOverlay(for card: PanelCard,
                             w: CGFloat, h: CGFloat,
                             colW: CGFloat, rowH: CGFloat,
                             hSpacing: CGFloat, vSpacing: CGFloat) -> some View {
        if editMode {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.cyan.opacity(0.7), lineWidth: 1.5)
                    .allowsHitTesting(false)

                // Delete (×) in top-right
                Button {
                    var layout = settings.panelLayout
                    layout = layout.removing(card.id)
                    settings.panelLayout = layout
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.white)
                        .background(Circle().fill(Color.red))
                }
                .offset(x: 8, y: -8)

                // Resize handle in bottom-right (styled like image editors)
                VStack { Spacer() ; HStack { Spacer() ; resizeHandle(for: card,
                                                                      colW: colW, rowH: rowH,
                                                                      hSpacing: hSpacing,
                                                                      vSpacing: vSpacing) } }
            }
        }
    }

    private func resizeHandle(for card: PanelCard,
                              colW: CGFloat, rowH: CGFloat,
                              hSpacing: CGFloat, vSpacing: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Color.cyan)
                .frame(width: 28, height: 28)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 12, weight: .heavy))
                .foregroundColor(.black)
        }
        .offset(x: 6, y: 6)
        .gesture(
            DragGesture()
                .onChanged { value in
                    resizingCardID = card.id
                    resizeDelta = value.translation
                }
                .onEnded { value in
                    let dCol = Int((value.translation.width / (colW + hSpacing)).rounded())
                    let dRow = Int((value.translation.height / (rowH + vSpacing)).rounded())
                    var newW = card.width + dCol
                    var newH = card.height + dRow
                    newW = max(1, min(PanelLayout.columns - card.col, newW))
                    newH = max(1, min(20, newH))

                    // Collision check: only commit resize if the larger
                    // rectangle wouldn't overlap any other card. If it
                    // would, shrink back until it fits — try decreasing
                    // width first, then height, until a valid size is
                    // found (or we fall back to the original size).
                    let layout = settings.panelLayout
                    var candidateW = newW
                    var candidateH = newH
                    while candidateW > card.width || candidateH > card.height {
                        if !layout.wouldCollide(excluding: card.id,
                                                col: card.col, row: card.row,
                                                width: candidateW,
                                                height: candidateH) {
                            break
                        }
                        // Shrink the bigger delta first
                        if candidateW - card.width >= candidateH - card.height,
                           candidateW > 1 {
                            candidateW -= 1
                        } else if candidateH > 1 {
                            candidateH -= 1
                        } else {
                            candidateW = card.width
                            candidateH = card.height
                            break
                        }
                    }

                    var nextLayout = layout
                    if let idx = nextLayout.cards.firstIndex(where: { $0.id == card.id }) {
                        nextLayout.cards[idx].width = candidateW
                        nextLayout.cards[idx].height = candidateH
                        settings.panelLayout = nextLayout
                    }
                    if candidateW != newW || candidateH != newH {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    }
                    resizingCardID = nil
                    resizeDelta = .zero
                }
        )
    }

    // MARK: - Drag gesture

    private func dragGesture(for card: PanelCard,
                             colW: CGFloat, rowH: CGFloat,
                             hSpacing: CGFloat, vSpacing: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingCardID = card.id
                dragOffset = value.translation
            }
            .onEnded { value in
                let dCol = Int((value.translation.width / (colW + hSpacing)).rounded())
                let dRow = Int((value.translation.height / (rowH + vSpacing)).rounded())
                var newCol = card.col + dCol
                var newRow = card.row + dRow
                newCol = max(0, min(PanelLayout.columns - card.width, newCol))
                newRow = max(0, newRow)

                // If the drop target's top-left slot is occupied by a
                // DIFFERENT card (and same-size), swap them directly —
                // this is what the pilot expects when dragging onto an
                // existing card. The target ends up where `card` started,
                // and `card` takes the target's slot.
                //
                // If the slot is empty OR the target is a different
                // size, fall back to placing() which cascade-pushes to
                // make room.
                let targetID = settings.panelLayout.cardAt(col: newCol, row: newRow)
                if let targetID = targetID,
                   targetID != card.id,
                   let swapped = settings.panelLayout.swapping(card.id, with: targetID) {
                    settings.panelLayout = swapped
                } else {
                    settings.panelLayout = settings.panelLayout.placing(
                        card.id, col: newCol, row: newRow)
                }

                draggingCardID = nil
                dragOffset = .zero
            }
    }

    // MARK: - Edit footer

    /// Floating footer shown while the panel is in edit mode. Contains
    /// the layout reset buttons (competition/free-flight), confirm, and
    /// an "Ekle" button that opens a sheet listing every hidden card.
    /// Kept as a nested struct so ContentView can pin it to the bottom
    /// of the screen as a fixed overlay outside the scroll view.
    struct EditFooter: View {
        @ObservedObject var settings: AppSettings
        @Binding var editMode: Bool
        @State private var showAddSheet = false

        var body: some View {
            VStack(spacing: 8) {
                // Row 1: Ekle (add card) + Tamam (confirm/exit edit).
                // Primary actions — adding content and finishing the
                // edit session — so they sit on top.
                HStack(spacing: 10) {
                    let canAdd = !settings.panelLayout.hiddenKinds.isEmpty
                    Button {
                        showAddSheet = true
                    } label: {
                        Label("Ekle", systemImage: "plus.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.75))
                            )
                            .foregroundColor(canAdd ? .green : .white.opacity(0.25))
                    }
                    .disabled(!canAdd)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { editMode = false }
                    } label: {
                        Label("Tamam", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.cyan)
                            )
                            .foregroundColor(.black)
                    }
                }

                // Row 2: Layout presets. Secondary actions — useful
                // but not every-session taps.
                HStack(spacing: 10) {
                    Button(role: .destructive) {
                        settings.panelLayout = PanelLayout.competitionLayout
                    } label: {
                        Label("Yarışma", systemImage: "flag.checkered")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.75))
                            )
                            .foregroundColor(.orange)
                    }
                    Button(role: .destructive) {
                        settings.panelLayout = PanelLayout.freeFlightLayout
                    } label: {
                        Label("Serbest", systemImage: "paperplane.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.black.opacity(0.75))
                            )
                            .foregroundColor(.green)
                    }
                }
            }
            .padding(.bottom, 8)
            .sheet(isPresented: $showAddSheet) {
                AddCardSheet(settings: settings, isPresented: $showAddSheet)
            }
        }
    }

    /// Sheet that presents every hidden card type as a tappable list row.
    /// Tapping a row inserts the card into the panel at the top and
    /// dismisses the sheet. The list is scrollable for when lots of
    /// cards are hidden, and each row shows the icon + name for easy
    /// recognition.
    struct AddCardSheet: View {
        @ObservedObject var settings: AppSettings
        @Binding var isPresented: Bool

        var body: some View {
            NavigationStack {
                List {
                    let hidden = settings.panelLayout.hiddenKinds
                    if hidden.isEmpty {
                        Text("Tüm kartlar zaten panelde.")
                            .foregroundColor(.secondary)
                    } else {
                        Section {
                            ForEach(hidden) { kind in
                                Button {
                                    settings.panelLayout =
                                        settings.panelLayout.adding(kind)
                                    isPresented = false
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: kind.iconName)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(.green)
                                            .frame(width: 28)
                                        Text(kind.displayName)
                                            .font(.system(size: 16, weight: .medium))
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: "plus.circle.fill")
                                            .foregroundColor(.green)
                                    }
                                    .contentShape(Rectangle())
                                    .padding(.vertical, 4)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            Text("Eklenebilir Kartlar")
                        } footer: {
                            Text("Eklenen kart panelin en üstüne yerleşir, mevcut kartlar bir satır aşağı kayar.")
                        }
                    }
                }
                .navigationTitle("Kart Ekle")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Kapat") { isPresented = false }
                    }
                }
            }
        }
    }

    // MARK: - Card view dispatch

    @ViewBuilder
    // MARK: - Distance helpers
    //
    // Each distance card is driven by these computed properties. Task-
    // relative distances (next TP, goal) go via the optimal tangent
    // route — the shortest legal path a pilot can fly through the
    // cylinders — so the numbers match competition scoring rather than
    // naive crow-flies estimates. Takeoff is a simple great-circle
    // distance since the pilot isn't required to fly back through
    // cylinders to "reach" the launch point.

    private var distanceToNextTP: Double? {
        guard let p = locationMgr.coordinate else { return nil }
        guard !task.turnpoints.isEmpty else { return nil }
        return task.distanceToNextTurnpoint(from: p)
    }

    private var distanceToGoal: Double? {
        guard let p = locationMgr.coordinate else { return nil }
        guard !task.turnpoints.isEmpty else { return nil }
        return task.distanceToGoal(from: p)
    }

    private var distanceToTakeoff: Double? {
        guard let p = locationMgr.coordinate else { return nil }
        // Straight-line distance to launch: takeoff is "where home is",
        // not a scored turnpoint, so the crow-flies measurement is the
        // useful one here (pilots want to know how far from base they
        // are, not how far they'd have to fly via the course).
        let origin: CLLocationCoordinate2D? = {
            if let takeoff = task.turnpoints.first(where: { $0.type == .takeoff }) {
                return CLLocationCoordinate2D(latitude: takeoff.latitude,
                                                longitude: takeoff.longitude)
            }
            return fai.flightStart
        }()
        guard let origin else { return nil }
        return CompetitionTask.haversine(p, origin)
    }

    @ViewBuilder
    private func cardView(for card: PanelCard) -> some View {
        switch card.kind {
        case .vario:
            VarioCard(vario: vario.filteredVario)
        case .altitude:
            TelemetryCard(label: "RAKIM",
                          value: String(format: "%.0f", locationMgr.fusedAltitude),
                          unit: "m", color: .orange)
        case .groundSpeed:
            TelemetryCard(label: "YER HIZI",
                          value: String(format: "%.0f", locationMgr.groundSpeedKmh),
                          unit: "km/h", color: .orange)
        case .course:
            // Smart course card: if a task is loaded, shows bearing to next
            // turnpoint; otherwise shows current GPS course. An arrow
            // graphic makes the direction visually obvious at a glance.
            CourseCard(isTaskActive: !task.turnpoints.isEmpty,
                       courseDeg: locationMgr.courseDeg,
                       pilotCoord: locationMgr.coordinate,
                       task: task)
        case .trueHeading:
            // Always-raw GPS course, never modulated by the task. Useful
            // for pilots who want to know which way they're physically
            // pointing independent of navigation.
            TrueHeadingCard(courseDeg: locationMgr.courseDeg)
        case .coordinates:
            CoordsCard(lat: locationMgr.coordinate?.latitude,
                       lon: locationMgr.coordinate?.longitude)
        case .windDial:
            WindDial(windFromDeg: wind.windFromDeg,
                     windSpeedKmh: wind.windSpeedKmh,
                     courseDeg: locationMgr.courseDeg,
                     confidence: wind.confidence)
        case .thermalRadar:
            ThermalRadar(thermals: vario.thermals,
                         pilotCoord: locationMgr.coordinate,
                         pilotCourseDeg: locationMgr.courseDeg,
                         radiusM: settings.thermalMemoryRadiusM)
        case .clock:
            ClockCard()
        case .battery:
            BatteryCard()
        case .distToNext:
            DistanceCard(label: "SONRAKİ TP",
                         meters: distanceToNextTP,
                         color: .cyan,
                         systemIcon: "arrow.forward.to.line")
        case .distToGoal:
            DistanceCard(label: "GOAL",
                         meters: distanceToGoal,
                         color: Color(red: 0.95, green: 0.3, blue: 0.5),
                         systemIcon: "flag.checkered")
        case .distToTakeoff:
            DistanceCard(label: "TAKEOFF",
                         meters: distanceToTakeoff,
                         color: .green,
                         systemIcon: "house.fill")
        case .map:
            ZStack(alignment: .bottomTrailing) {
                SatelliteMapView(coordinate: locationMgr.coordinate,
                                 heading: locationMgr.courseDeg,
                                 thermals: vario.thermals,
                                 // Task loaded → pilot is flying waypoints,
                                 // not a free triangle. Hide FAI overlay
                                 // so the map isn't cluttered.
                                 triangle: task.turnpoints.isEmpty ? fai.bestTriangle : nil,
                                 flightStart: task.turnpoints.isEmpty ? fai.flightStart : nil,
                                 task: task.turnpoints.isEmpty ? nil : task,
                                 fitTriangleToken: fitTriangleToken,
                                 fitTaskToken: fitTaskToken,
                                 autoFollow: $autoFollow)
                    .allowsHitTesting(!editMode)

                // Recenter floating button — appears when the pilot has
                // panned the map away from their position (autoFollow
                // is off). Tapping recenters and re-enables follow.
                if !autoFollow && !editMode {
                    Button {
                        autoFollow = true
                    } label: {
                        Image(systemName: "location.north.line.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(.white)
                            .padding(12)
                            .background(
                                Circle()
                                    .fill(Color.black.opacity(0.7))
                                    .overlay(Circle()
                                        .stroke(Color.cyan.opacity(0.8), lineWidth: 2))
                            )
                    }
                    .padding(10)
                    .transition(.opacity.combined(with: .scale))
                }

                // Transparent hit-testable layer that sits on top when
                // editing. Catches drag gestures and forwards them to
                // the PanelView drag handler via a tinted visual cue.
                if editMode {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.25))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

// MARK: - Individual card views

private struct VarioCard: View {
    let vario: Double

    var color: Color {
        if vario >= 0.1 { return .green }
        if vario <= -0.5 { return .red }
        return .white
    }

    var displayValue: String {
        let v = abs(vario) < 0.05 ? 0.0 : vario
        return String(format: "%.1f", v)
    }

    var body: some View {
        GeometryReader { geo in
            // Base: 64pt font fits comfortably in a 2-row (52*2+5=109pt) card.
            // Scale by the smaller of the two axes so the number stays inside
            // the card when it's stretched in one direction only.
            let scale = min(geo.size.width / 180.0, geo.size.height / 110.0)
            let numSize = max(28.0, min(140.0, 64.0 * scale))
            let unitSize = max(10.0, min(26.0, 16.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                VStack(spacing: -4) {
                    Text(displayValue)
                        .font(.system(size: numSize, weight: .heavy, design: .rounded))
                        .foregroundColor(color)
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("m/s")
                        .font(.system(size: unitSize, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
    }
}

private struct TelemetryCard: View {
    let label: String
    let value: String
    let unit: String
    let color: Color

    var body: some View {
        GeometryReader { geo in
            // Base 75×50 (was 90×55) → values scale ~20% bigger at the
            // default 2×1 card size. The minimumScaleFactor still protects
            // against clipping if the card is shrunk during edit.
            let scale = min(geo.size.width / 75.0, geo.size.height / 50.0)
            let labelSize = max(8.0, min(20.0, 10.0 * scale))
            let valueSize = max(16.0, min(64.0, 28.0 * scale))
            let unitSize = max(8.0, min(24.0, 12.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                VStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: labelSize, weight: .bold))
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: valueSize, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(unit)
                            .font(.system(size: unitSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
            }
        }
    }
}

private struct CoordsCard: View {
    let lat: Double?
    let lon: Double?

    var body: some View {
        GeometryReader { geo in
            // Match other numeric cards' visual weight — base 260×50
            // (was 300×52) so fonts scale ~15% bigger at the default
            // 4×1 card width.
            let scale = min(geo.size.width / 260.0, geo.size.height / 50.0)
            let fontSize = max(11.0, min(36.0, 16.0 * scale))
            let iconSize = max(13.0, min(32.0, 16.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                HStack(spacing: 6) {
                    Image(systemName: "location.fill")
                        .font(.system(size: iconSize))
                        .foregroundColor(.cyan)
                    if let lat = lat, let lon = lon {
                        Text(String(format: "%.5f°,  %.5f°", lat, lon))
                            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    } else {
                        Text("GPS bekleniyor…")
                            .font(.system(size: fontSize, weight: .semibold))
                            .foregroundColor(.orange)
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
            }
        }
    }
}

private struct ClockCard: View {
    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 150.0, geo.size.height / 52.0)
            let fontSize = max(14.0, min(56.0, 24.0 * scale))
            let iconSize = max(12.0, min(40.0, 16.0 * scale))

            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.black.opacity(0.55))
                    HStack(spacing: 6) {
                        Image(systemName: "clock.fill")
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                        Text(Self.timeString(for: ctx.date))
                            .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
    private static func timeString(for date: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

/// Direction indicator card. Draws an orange arrow pointing in the
/// relevant direction + the numeric bearing below. "Relevant direction"
/// is either:
///   - Task active: bearing from pilot → next un-reached turnpoint
///   - No task: the pilot's current GPS course (direction of movement)
///
/// The arrow always points "up" in its own frame; the whole card visually
/// communicates a direction without the user needing to compare numbers.
/// Rotation is computed by subtracting the pilot's current course from
/// the target bearing — so when you're already flying toward the next
/// point the arrow points straight up.
private struct CourseCard: View {
    let isTaskActive: Bool
    let courseDeg: Double
    let pilotCoord: CLLocationCoordinate2D?
    @ObservedObject var task: CompetitionTask

    /// Flash state: when a turnpoint is reached the card briefly tints
    /// green and scales up slightly, then eases back. Triggered by
    /// observing task.lastReachEvent.
    @State private var isFlashing: Bool = false

    private var arrowRotation: Angle {
        if isTaskActive, let p = pilotCoord,
           let bearing = task.bearingToNextTurnpoint(from: p) {
            return .degrees(bearing - courseDeg)
        }
        return .degrees(-courseDeg)
    }

    /// Gradient used to fill the arrow. Normally orange→red; during the
    /// reach flash we swap to green→mint for ~0.7s so the colour change
    /// is obvious even in peripheral vision.
    private var arrowColors: [Color] {
        isFlashing
            ? [Color.green, Color(red: 0.4, green: 1.0, blue: 0.6)]
            : [Color.orange, Color.red]
    }

    var body: some View {
        GeometryReader { geo in
            let arrowSize = min(geo.size.width, geo.size.height) * 0.75

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isFlashing
                          ? Color.green.opacity(0.35)
                          : Color.black.opacity(0.55))
                    .animation(.easeInOut(duration: 0.25), value: isFlashing)

                ArrowShape()
                    .fill(
                        LinearGradient(
                            colors: arrowColors,
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: arrowSize, height: arrowSize)
                    .scaleEffect(isFlashing ? 1.15 : 1.0)
                    .rotationEffect(arrowRotation)
                    .animation(.easeOut(duration: 0.25), value: arrowRotation)
                    .animation(.spring(response: 0.3, dampingFraction: 0.55), value: isFlashing)
            }
            .onChange(of: task.lastReachEvent) { _ in
                // Fire the flash. We don't care which TP was reached —
                // every reach triggers the same feedback.
                flash()
            }
        }
    }

    /// Trigger a brief colour+scale flash. Re-entry safe: a new reach
    /// during an ongoing flash re-runs the animation from its peak,
    /// which reads as continuous reach-to-reach feedback.
    private func flash() {
        isFlashing = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            isFlashing = false
        }
    }
}

/// Raw true heading card — always shows the pilot's physical GPS course,
/// never the task navigation target. Intended as a secondary card that
/// pilots can add alongside Rota when they want both numbers.
private struct TrueHeadingCard: View {
    let courseDeg: Double

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 120.0, geo.size.height / 110.0)
            let degSize = max(9.0, min(16.0, 10.0 * scale))
            let arrowSize = min(geo.size.width, geo.size.height) * 0.70

            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))

                ArrowShape()
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan, Color.blue],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .frame(width: arrowSize, height: arrowSize)
                    .rotationEffect(.degrees(courseDeg))
                    .animation(.easeOut(duration: 0.25), value: courseDeg)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Text(String(format: "%.0f°", courseDeg))
                    .font(.system(size: degSize, weight: .bold, design: .rounded))
                    .foregroundColor(.cyan)
                    .monospacedDigit()
                    .padding(.trailing, 8)
                    .padding(.bottom, 6)
            }
        }
    }
}

/// Upward-pointing arrowhead, modelled on the Apple Maps / Watch
/// navigation arrow: two triangular sides meeting at a tip, no inner
/// shading (that's added by the caller's gradient). Drawn in a 100×100
/// canvas so the caller can apply any frame.
private struct ArrowShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let w = rect.width
        let h = rect.height
        // Tip at top-center, base at bottom corners, notch at bottom center
        p.move(to: CGPoint(x: w * 0.5, y: 0))                 // tip
        p.addLine(to: CGPoint(x: w, y: h))                    // bottom-right
        p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.75))       // bottom-center notch
        p.addLine(to: CGPoint(x: 0, y: h))                    // bottom-left
        p.closeSubpath()
        return p
    }
}

/// Distance-to-point card. Displays a great-circle distance in meters
/// or kilometers, with a small icon and label. Used by:
///   - distToNext:    distance to the next un-reached task turnpoint
///   - distToGoal:    distance to the task's goal turnpoint
///   - distToTakeoff: distance back to the task takeoff (or flight start
///                    when no task is loaded)
///
/// Formatting switches automatically between "842 m" (below 1 km) and
/// "14.3 km" (≥1 km) so the reading stays compact at any range.
private struct DistanceCard: View {
    let label: String
    let meters: Double?
    let color: Color
    let systemIcon: String

    private var valueString: String {
        guard let m = meters else { return "—" }
        if m < 1000 {
            return String(format: "%.0f", m)
        } else if m < 10_000 {
            return String(format: "%.2f", m / 1000)
        } else {
            return String(format: "%.1f", m / 1000)
        }
    }

    private var unitString: String {
        guard let m = meters else { return "" }
        return m < 1000 ? "m" : "km"
    }

    var body: some View {
        GeometryReader { geo in
            // Match TelemetryCard scale base (75×50) so distance values
            // read at the same size as the other numeric cards.
            let scale = min(geo.size.width / 140.0, geo.size.height / 50.0)
            let labelSize = max(8.0, min(20.0, 10.0 * scale))
            let valueSize = max(16.0, min(64.0, 28.0 * scale))
            let unitSize  = max(8.0, min(24.0, 12.0 * scale))
            let iconSize  = max(12.0, min(32.0, 14.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: systemIcon)
                            .font(.system(size: iconSize, weight: .bold))
                            .foregroundColor(color)
                        Text(label)
                            .font(.system(size: labelSize, weight: .bold))
                            .foregroundColor(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(valueString)
                            .font(.system(size: valueSize, weight: .bold, design: .rounded))
                            .foregroundColor(color)
                            .monospacedDigit()
                            .lineLimit(1)
                        Text(unitString)
                            .font(.system(size: unitSize, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 4)
            }
        }
    }
}

/// Battery level card — polls UIDevice at 30s intervals, large pilot-
/// readable text, colored by remaining charge (green=charging, white>=50%,
/// yellow>=20%, red below).
private struct BatteryCard: View {
    @State private var level: Float = UIDevice.current.batteryLevel
    @State private var state: UIDevice.BatteryState = UIDevice.current.batteryState
    private let poll = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var percent: Int {
        level < 0 ? 100 : Int((level * 100).rounded())
    }

    private var color: Color {
        if state == .charging || state == .full {
            return Color(red: 0.35, green: 0.95, blue: 0.55)
        }
        if percent >= 50 { return .white }
        if percent >= 20 { return Color(red: 1.0, green: 0.85, blue: 0.3) }
        return Color(red: 1.0, green: 0.4, blue: 0.4)
    }

    private var iconName: String {
        if state == .charging { return "battery.100percent.bolt" }
        if percent >= 75 { return "battery.100" }
        if percent >= 50 { return "battery.75" }
        if percent >= 25 { return "battery.50" }
        if percent >= 10 { return "battery.25" }
        return "battery.0"
    }

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / 150.0, geo.size.height / 52.0)
            let fontSize = max(14.0, min(56.0, 26.0 * scale))
            let iconSize = max(14.0, min(44.0, 22.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.system(size: iconSize, weight: .bold))
                        .foregroundColor(color)
                    Text("\(percent)%")
                        .font(.system(size: fontSize, weight: .heavy, design: .rounded))
                        .foregroundColor(color)
                        .monospacedDigit()
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                }
            }
        }
        .onAppear {
            UIDevice.current.isBatteryMonitoringEnabled = true
            level = UIDevice.current.batteryLevel
            state = UIDevice.current.batteryState
        }
        .onReceive(poll) { _ in
            level = UIDevice.current.batteryLevel
            state = UIDevice.current.batteryState
        }
    }
}
