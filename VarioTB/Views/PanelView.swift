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
    /// Offset applied to a card's origin while resizing — currently zero
    /// (bottom-right handle anchors the top-left), but kept as state so
    /// other corner handles can be added later without changing the
    /// drawing code.
    @State private var resizeOffset: CGSize = .zero

    var body: some View {
        return GeometryReader { geo in
            // Landscape detection — when the device is rotated, GeometryReader
            // hands us a wider-than-tall geometry. We switch into a different
            // layout strategy:
            //   - portrait : panel uses the fixed 780pt reference height and
            //                ScrollView wraps it (existing behaviour).
            //   - landscape: panel fits the actual screen height (no scroll),
            //                and the cards are re-mapped via
            //                landscapeTransformed() so the top half of the
            //                portrait layout becomes the LEFT half and the
            //                bottom half becomes the RIGHT half.
            // Edit mode is disabled in landscape — drag/resize math assumes
            // the static fraction grid, which would clash with the dynamic
            // re-mapping. Pilots edit in portrait, fly in either.
            let isLandscape = geo.size.width > geo.size.height
            let panelW = geo.size.width
            let panelH: CGFloat = isLandscape
                ? geo.size.height
                : PanelLayout.referenceHeight
            let activeLayout: PanelLayout = isLandscape
                ? settings.panelLayout.landscapeTransformed()
                : settings.panelLayout

            ZStack(alignment: .topLeading) {
                if editMode && !isLandscape {
                    editBackdrop(panelW: panelW, panelH: panelH)
                }

                // Two-pass render so map cards sit UNDERNEATH all
                // other cards. Pass 1: maps (zIndex 0). Pass 2:
                // everything else (zIndex 10). The actively-dragged
                // or resized card jumps to zIndex 100 so its preview
                // stays on top of neighbours.
                ForEach(activeLayout.cards) { card in
                    if card.kind == .map {
                        cardContainer(for: card, panelW: panelW, panelH: panelH,
                                       allowEdit: !isLandscape)
                            .zIndex(zIndex(for: card, base: 0))
                    }
                }
                ForEach(activeLayout.cards) { card in
                    if card.kind != .map {
                        cardContainer(for: card, panelW: panelW, panelH: panelH,
                                       allowEdit: !isLandscape)
                            .zIndex(zIndex(for: card, base: 10))
                    }
                }
            }
            .frame(width: panelW, height: panelH, alignment: .topLeading)
            .onLongPressGesture(minimumDuration: 0.6) {
                guard !isLandscape else { return }
                withAnimation(.easeInOut(duration: 0.2)) { editMode.toggle() }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    // MARK: - Card container (positions, sizes, applies edit affordances)

    private func zIndex(for card: PanelCard, base: Double) -> Double {
        if draggingCardID == card.id || resizingCardID == card.id { return 100 }
        return base
    }

    @ViewBuilder
    private func cardContainer(for card: PanelCard,
                                panelW: CGFloat, panelH: CGFloat,
                                allowEdit: Bool = true) -> some View {
        let baseX = card.x * panelW
        let baseY = card.y * panelH
        let baseW = card.w * panelW
        let baseH = card.h * panelH

        let dragging = allowEdit && draggingCardID == card.id
        let resizing = allowEdit && resizingCardID == card.id
        let frameW: CGFloat = resizing ? max(40, baseW + resizeDelta.width) : baseW
        let frameH: CGFloat = resizing ? max(40, baseH + resizeDelta.height) : baseH
        let offsetX: CGFloat = dragging ? dragOffset.width : 0
        let offsetY: CGFloat = dragging ? dragOffset.height : 0

        cardView(for: card)
            .frame(width: frameW, height: frameH)
            .overlay(allowEdit
                     ? editOverlay(for: card, panelW: panelW, panelH: panelH)
                     : nil)
            .offset(x: baseX + offsetX, y: baseY + offsetY)
            .gesture((allowEdit && editMode)
                     ? dragGesture(for: card, panelW: panelW, panelH: panelH)
                     : nil)
            .animation(.spring(response: 0.25, dampingFraction: 0.85),
                       value: settings.panelLayout.cards.map(\.id))
    }

    // MARK: - Edit backdrop (cosmetic only — no snap grid)

    private func editBackdrop(panelW: CGFloat, panelH: CGFloat) -> some View {
        // Faint wash so the edit surface reads as "different mode"
        // without imposing a grid visually. Positioning is entirely
        // free-form now.
        Rectangle()
            .fill(Color.cyan.opacity(0.04))
            .frame(width: panelW, height: panelH)
    }

    // MARK: - Edit overlay: delete + resize handle

    @ViewBuilder
    private func editOverlay(for card: PanelCard,
                              panelW: CGFloat, panelH: CGFloat) -> some View {
        if editMode {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.cyan.opacity(0.75), lineWidth: 1.5)
                    .allowsHitTesting(false)

                // Delete (×) — top-right, 44pt tap target
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            settings.panelLayout = settings.panelLayout.removing(card.id)
                        } label: {
                            ZStack {
                                Circle().fill(Color.red).frame(width: 26, height: 26)
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                        }
                        .offset(x: 10, y: -10)
                    }
                    Spacer()
                }

                // Resize handle — bottom-right, 48pt tap target
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        resizeHandle(for: card, panelW: panelW, panelH: panelH)
                    }
                }
            }
        }
    }

    private func resizeHandle(for card: PanelCard,
                              panelW: CGFloat, panelH: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.cyan).frame(width: 32, height: 32)
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .heavy))
                .foregroundColor(.black)
        }
        .frame(width: 48, height: 48)
        .contentShape(Rectangle())
        .offset(x: 8, y: 8)
        .gesture(
            DragGesture()
                .onChanged { value in
                    resizingCardID = card.id
                    resizeDelta = value.translation
                }
                .onEnded { value in
                    let dw = value.translation.width / panelW
                    let dh = value.translation.height / panelH
                    let rawW = card.w + dw
                    let rawH = card.h + dh
                    let (snappedW, snappedH) = snapSize(
                        cardID: card.id, x: card.x, y: card.y,
                        rawW: rawW, rawH: rawH)
                    settings.panelLayout = settings.panelLayout.updating(
                        card.id,
                        w: snappedW,
                        h: snappedH)
                    resizingCardID = nil
                    resizeDelta = .zero
                }
        )
    }

    // MARK: - Drag gesture (free pixel movement, no grid snap)

    private func dragGesture(for card: PanelCard,
                              panelW: CGFloat, panelH: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingCardID = card.id
                dragOffset = value.translation
            }
            .onEnded { value in
                let dx = value.translation.width / panelW
                let dy = value.translation.height / panelH
                let rawX = card.x + dx
                let rawY = card.y + dy
                let (snappedX, snappedY) = snapPosition(
                    cardID: card.id, w: card.w, h: card.h,
                    rawX: rawX, rawY: rawY)
                settings.panelLayout = settings.panelLayout.updating(
                    card.id,
                    x: snappedX,
                    y: snappedY)
                draggingCardID = nil
                dragOffset = .zero
            }
    }

    // MARK: - Snapping
    //
    // When the pilot drops a card near another card's edge or near the
    // panel's left/right boundary, nudge it to perfect alignment. This
    // absorbs the small hand-jitter that makes free-positioning layouts
    // look crooked without committing to a rigid grid.

    /// Snap thresholds in fraction-of-panel units. "near" means within
    /// this distance from a target line.
    private static let snapThresholdX: CGFloat = 0.03   // ~3% of panel width
    private static let snapThresholdY: CGFloat = 0.02   // ~2% of reference height

    /// Snap both axes. Candidates are:
    ///   - Panel left edge (0) and right edge (1 - cardW)
    ///   - Panel center line (0.5 - cardW/2)
    ///   - Other cards' left (card.x), right (card.x + card.w)
    ///   - Other cards' top (card.y), bottom (card.y + card.h)
    /// The card also snaps to match another card's y or h so aligned
    /// rows stay aligned after drags.
    private func snapPosition(cardID: UUID,
                              w: CGFloat, h: CGFloat,
                              rawX: CGFloat, rawY: CGFloat)
    -> (CGFloat, CGFloat) {
        let others = settings.panelLayout.cards.filter { $0.id != cardID }

        // X-axis targets: both for the card's LEFT edge
        var xTargets: [CGFloat] = [0, 1 - w, 0.5 - w / 2]
        for o in others {
            xTargets.append(o.x)              // align left edges
            xTargets.append(o.x + o.w - w)    // align right edges
            xTargets.append(o.x + o.w)        // sit flush to the right of o
            xTargets.append(o.x - w)          // sit flush to the left of o
        }

        // Y-axis targets
        var yTargets: [CGFloat] = [0]
        for o in others {
            yTargets.append(o.y)              // align top edges
            yTargets.append(o.y + o.h - h)    // align bottom edges
            yTargets.append(o.y + o.h)        // sit directly below o
            yTargets.append(o.y - h)          // sit directly above o
        }

        let snappedX = nearestWithin(rawX, targets: xTargets, threshold: Self.snapThresholdX)
        let snappedY = nearestWithin(rawY, targets: yTargets, threshold: Self.snapThresholdY)
        return (snappedX, snappedY)
    }

    /// Snap a resize operation. The handle is on the bottom-right, so
    /// we snap the card's RIGHT edge (x + w) and BOTTOM edge (y + h) —
    /// this gives the natural "drag to hit the next card's edge"
    /// behavior. Candidates mirror snapPosition's targets.
    private func snapSize(cardID: UUID,
                          x: CGFloat, y: CGFloat,
                          rawW: CGFloat, rawH: CGFloat)
    -> (CGFloat, CGFloat) {
        let others = settings.panelLayout.cards.filter { $0.id != cardID }

        // Right-edge candidates (the card's x + w should equal one)
        var rightTargets: [CGFloat] = [1, 0.5]
        for o in others {
            rightTargets.append(o.x)            // card's right flush with o's left
            rightTargets.append(o.x + o.w)      // card's right flush with o's right
        }
        // Bottom-edge candidates
        var bottomTargets: [CGFloat] = []
        for o in others {
            bottomTargets.append(o.y)
            bottomTargets.append(o.y + o.h)
        }

        let desiredRight = x + rawW
        let desiredBottom = y + rawH
        let snappedRight = nearestWithin(desiredRight, targets: rightTargets,
                                          threshold: Self.snapThresholdX)
        let snappedBottom = nearestWithin(desiredBottom, targets: bottomTargets,
                                           threshold: Self.snapThresholdY)
        return (snappedRight - x, snappedBottom - y)
    }

    /// Pick whichever target is closest to `v` and within `threshold`.
    /// If no target qualifies, return `v` unchanged.
    private func nearestWithin(_ v: CGFloat,
                                targets: [CGFloat],
                                threshold: CGFloat) -> CGFloat {
        var best: CGFloat? = nil
        var bestDist: CGFloat = threshold
        for t in targets {
            let d = abs(t - v)
            if d <= bestDist {
                bestDist = d
                best = t
            }
        }
        return best ?? v
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

    /// 1-based index of the next unreached turnpoint. Used in the
    /// "SONRAKİ TP" card label so the pilot knows which TP number is
    /// being navigated to. Returns nil if there's no task or every TP
    /// is already tagged.
    private var nextTPIndex: Int? {
        guard let p = locationMgr.coordinate else { return nil }
        guard let next = task.nextTurnpoint(pilot: p) else { return nil }
        guard let idx = task.turnpoints.firstIndex(where: { $0.id == next.id })
        else { return nil }
        return idx + 1   // 1-based for display
    }

    /// Name of the next unreached turnpoint — shown directly on the
    /// dist-to-next card label instead of "SONRAKİ TP N". Keeps the
    /// readout grounded in the task's own naming (e.g. "TP-10km-a",
    /// "SSS", "ESS") so the pilot doesn't have to mentally map
    /// numbers back to TP identities mid-flight. Returns nil when no
    /// pilot fix or no unreached TP is available.
    private var nextTPName: String? {
        guard let p = locationMgr.coordinate else { return nil }
        return task.nextTurnpoint(pilot: p)?.name
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
        case .maxAltitude:
            // Session peak altitude. Reset on app launch and on
            // simulator stop. Uses a magenta tint to distinguish
            // visually from the live altitude readout.
            TelemetryCard(label: "MAX RAKIM",
                          value: String(format: "%.0f", locationMgr.maxAltitude),
                          unit: "m",
                          color: Color(red: 0.95, green: 0.3, blue: 0.5))
        case .groundSpeed:
            TelemetryCard(label: "YER HIZI",
                          value: String(format: "%.0f", locationMgr.groundSpeedKmh),
                          unit: "km/h", color: .orange)
        case .course:
            // Smart course card: if a task is loaded, shows bearing to next
            // turnpoint; otherwise shows current GPS course. An arrow
            // graphic makes the direction visually obvious at a glance.
            CourseCard(isTaskActive: !task.turnpoints.isEmpty,
                       courseDeg: locationMgr.bestHeadingDeg,
                       pilotCoord: locationMgr.coordinate,
                       task: task)
        case .trueHeading:
            // Always-raw GPS course, never modulated by the task. Useful
            // for pilots who want to know which way they're physically
            // pointing independent of navigation.
            TrueHeadingCard(courseDeg: locationMgr.bestHeadingDeg)
        case .coordinates:
            CoordsCard(lat: locationMgr.coordinate?.latitude,
                       lon: locationMgr.coordinate?.longitude)
        case .windDial:
            WindDial(windFromDeg: wind.windFromDeg,
                     windSpeedKmh: wind.windSpeedKmh,
                     courseDeg: locationMgr.bestHeadingDeg,
                     confidence: wind.confidence)
        case .thermalRadar:
            ThermalRadar(thermals: vario.thermals,
                         pilotCoord: locationMgr.coordinate,
                         pilotCourseDeg: locationMgr.bestHeadingDeg,
                         radiusM: settings.thermalMemoryRadiusM)
        case .clock:
            ClockCard()
        case .battery:
            BatteryCard()
        case .distToNext:
            // Label is the next unreached TP's name (e.g. "NW",
            // "SSS", "ESS"). When there's no GPS fix yet or every TP
            // is already tagged, fall back to an empty label rather
            // than a generic "SONRAKİ TP" placeholder — that generic
            // text confused the user by appearing briefly every time
            // the sim stopped and the coordinate temporarily went nil
            // before the card reset.
            let label = nextTPName ?? ""
            DistanceCard(label: label,
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
                                 heading: locationMgr.bestHeadingDeg,
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
                // Value + unit side-by-side, aligned to the firstTextBaseline
                // so the unit sits next to the bottom of the digits — same
                // pattern as TelemetryCard (altitude/speed) for a consistent
                // look across the panel.
                HStack(alignment: .firstTextBaseline, spacing: 4) {
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
            // Label is metadata, not the primary readout — kept small
            // so the eye locks onto the value first. Scale floor at 7,
            // ceiling at 12 (was 8/20). Faded opacity helps too.
            let labelSize = max(7.0, min(12.0, 7.0 * scale))
            let valueSize = max(16.0, min(64.0, 28.0 * scale))
            let unitSize = max(8.0, min(24.0, 12.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                VStack(spacing: 2) {
                    Text(label)
                        .font(.system(size: labelSize, weight: .semibold))
                        .tracking(0.5)
                        .foregroundColor(.white.opacity(0.45))
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
            // Arrow sizing. The arrow is a solid shape that occupies
            // its full frame — tip at top center (y=0), base corners
            // at bottom corners. When rotated 180° the tip swings to
            // the bottom edge of the frame. If we make the frame
            // exactly as wide/tall as the card, the rotated tip kisses
            // the card's rounded-rect border. Multiply by 0.55 to
            // leave a clear margin on all sides — enough that the
            // arrow never touches the frame at any rotation angle.
            let arrowSize = min(geo.size.width, geo.size.height) * 0.55

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
            // Leave consistent margin so the rotated arrow tip never
            // touches the card's rounded-rect border (see CourseCard
            // for the geometry explanation).
            let arrowSize = min(geo.size.width, geo.size.height) * 0.55

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
            // Label is metadata — same fade + small font as TelemetryCard.
            let labelSize = max(7.0, min(12.0, 7.0 * scale))
            let valueSize = max(16.0, min(64.0, 28.0 * scale))
            let unitSize  = max(8.0, min(24.0, 12.0 * scale))
            let iconSize  = max(10.0, min(16.0, 9.0 * scale))

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.55))
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: systemIcon)
                            .font(.system(size: iconSize, weight: .semibold))
                            .foregroundColor(color.opacity(0.65))
                        Text(label)
                            .font(.system(size: labelSize, weight: .semibold))
                            .tracking(0.5)
                            .foregroundColor(.white.opacity(0.45))
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
