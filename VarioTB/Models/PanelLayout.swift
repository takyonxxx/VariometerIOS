import Foundation
import SwiftUI

/// Which instrument a panel card shows. Each case defines both the data
/// being displayed and the visual style (some cards are big numeric
/// readouts, others are compasses / radars / gauges).
enum InstrumentKind: String, Codable, CaseIterable, Identifiable {
    case vario         = "vario"
    case altitude      = "altitude"
    case groundSpeed   = "groundSpeed"
    case course        = "course"           // smart: task-aware if task loaded
    case trueHeading   = "trueHeading"      // always physical GPS course
    case coordinates   = "coordinates"
    case windDial      = "windDial"
    case thermalRadar  = "thermalRadar"
    case clock         = "clock"
    case battery       = "battery"
    case map           = "map"
    case distToNext    = "distToNext"       // km to next un-reached TP
    case distToGoal    = "distToGoal"       // km to task goal
    case distToTakeoff = "distToTakeoff"    // km back to takeoff / flight start

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .vario:         return "Vario"
        case .altitude:      return "Rakım"
        case .groundSpeed:   return "Yer Hızı"
        case .course:        return "Rota"
        case .trueHeading:   return "Yön (Gerçek)"
        case .coordinates:   return "Koordinatlar"
        case .windDial:      return "Rüzgar Gülü"
        case .thermalRadar:  return "Termik Radarı"
        case .clock:         return "Saat"
        case .battery:       return "Pil"
        case .map:           return "Harita"
        case .distToNext:    return "Sonraki TP Mesafe"
        case .distToGoal:    return "Goal Mesafe"
        case .distToTakeoff: return "Takeoff Mesafe"
        }
    }

    var iconName: String {
        switch self {
        case .vario:         return "arrow.up.arrow.down"
        case .altitude:      return "mountain.2.fill"
        case .groundSpeed:   return "speedometer"
        case .course:        return "safari"
        case .trueHeading:   return "location.north.fill"
        case .coordinates:   return "location.fill"
        case .windDial:      return "tornado"
        case .thermalRadar:  return "dot.radiowaves.left.and.right"
        case .clock:         return "clock"
        case .battery:       return "battery.100"
        case .map:           return "map.fill"
        case .distToNext:    return "arrow.forward.to.line"
        case .distToGoal:    return "flag.checkered"
        case .distToTakeoff: return "house.fill"
        }
    }
}

/// One placed card on the panel. Position and size are NORMALIZED
/// fractions of the panel's reference dimensions:
///
///   - `x`, `y`: top-left corner, 0..1
///   - `w`, `h`: width / height, 0..1
///
/// Fractions instead of pixels let the same layout scale proportionally
/// across phone sizes. The panel's scroll area accommodates content
/// extending beyond the viewport.
///
/// Grid has been replaced with free positioning: cards can sit anywhere,
/// overlap anything, and be any size at or above a small minimum. Map
/// cards render UNDERNEATH other cards (see PanelView's zIndex logic)
/// so the map can be stretched to any size without hiding instruments.
struct PanelCard: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var kind: InstrumentKind
    var x: CGFloat
    var y: CGFloat
    var w: CGFloat
    var h: CGFloat

    init(id: UUID = UUID(), kind: InstrumentKind,
         x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        self.id = id
        self.kind = kind
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    // MARK: - Codable with back-compat for old grid-based layouts
    //
    // Layouts saved to UserDefaults before the pixel rewrite used
    // integer col/row/width/height fields in a 4-column grid. We detect
    // those on decode and convert them to fractional x/y/w/h using the
    // legacy 4×15 cell layout.
    enum CodingKeys: String, CodingKey {
        case id, kind
        case x, y, w, h
        case col, row, width, height   // legacy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.kind = try c.decode(InstrumentKind.self, forKey: .kind)
        if let fx = try c.decodeIfPresent(CGFloat.self, forKey: .x),
           let fy = try c.decodeIfPresent(CGFloat.self, forKey: .y),
           let fw = try c.decodeIfPresent(CGFloat.self, forKey: .w),
           let fh = try c.decodeIfPresent(CGFloat.self, forKey: .h) {
            self.x = fx; self.y = fy; self.w = fw; self.h = fh
        } else {
            let col = try c.decodeIfPresent(Int.self, forKey: .col) ?? 0
            let row = try c.decodeIfPresent(Int.self, forKey: .row) ?? 0
            let width = try c.decodeIfPresent(Int.self, forKey: .width) ?? 2
            let height = try c.decodeIfPresent(Int.self, forKey: .height) ?? 1
            self.x = CGFloat(col) / CGFloat(PanelLayout.legacyColumns)
            self.w = CGFloat(width) / CGFloat(PanelLayout.legacyColumns)
            self.y = CGFloat(row) / CGFloat(PanelLayout.legacyRowsReference)
            self.h = CGFloat(height) / CGFloat(PanelLayout.legacyRowsReference)
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
    }
}

/// The full panel layout — ordered list of cards. Persisted to
/// UserDefaults as JSON via AppSettings.panelLayoutRaw.
struct PanelLayout: Codable {
    var cards: [PanelCard]

    /// Reference total panel height. The panel multiplies fractional y/h
    /// values by this constant (not by the actual view height) so cards
    /// have a consistent physical size across devices; a ScrollView
    /// wraps the panel so the user can reach content below the viewport.
    static let referenceHeight: CGFloat = 780

    /// Minimum card width/height — keeps cards tappable and prevents
    /// accidentally shrinking them to zero.
    static let minW: CGFloat = 0.15   // ≈ 15% of panel width
    static let minH: CGFloat = 0.04   // ≈ 31 pt at reference height

    /// Legacy grid divisors — only used while decoding old saved layouts.
    static let legacyColumns: Int = 4
    static let legacyRowsReference: Int = 15

    /// Factory competition layout — matches the reference screenshot:
    ///   - Vario (left) + Course (right) at the top, both 2×2.
    ///   - Ground speed (left) + altitude (right), each 1.5 rows — same
    ///     split as free-flight so the big readouts share weight
    ///     equally.
    ///   - DistToNext (SSS label) + DistToGoal, also 1.5 rows each,
    ///     stacked below the speed/alt pair.
    ///   - Full-width map from row 5 down, with wind+radar overlaying
    ///     the upper region (two-pass zIndex in PanelView keeps the
    ///     map underneath).
    ///   - Clock + battery on the final row.
    static var competitionLayout: PanelLayout {
        let cols = 4, rows = 15
        func x(_ c: Int) -> CGFloat { CGFloat(c) / CGFloat(cols) }
        func y(_ r: Int) -> CGFloat { CGFloat(r) / CGFloat(rows) }
        func w(_ s: Int) -> CGFloat { CGFloat(s) / CGFloat(cols) }
        func h(_ s: Int) -> CGFloat { CGFloat(s) / CGFloat(rows) }
        // 1.5-row constants for the mid-band readouts. y positions are
        // cumulative so speed/alt sit at row 2, dist cards at row 3.5.
        let halfRowH: CGFloat = 1.5 / CGFloat(rows)
        let speedRowY: CGFloat = 2.0 / CGFloat(rows)
        let distRowY: CGFloat  = 3.5 / CGFloat(rows)
        return PanelLayout(cards: [
            PanelCard(kind: .vario,        x: x(0), y: y(0),      w: w(2), h: h(2)),
            PanelCard(kind: .course,       x: x(2), y: y(0),      w: w(2), h: h(2)),
            PanelCard(kind: .groundSpeed,  x: x(0), y: speedRowY, w: w(2), h: halfRowH),
            PanelCard(kind: .altitude,     x: x(2), y: speedRowY, w: w(2), h: halfRowH),
            PanelCard(kind: .distToNext,   x: x(0), y: distRowY,  w: w(2), h: halfRowH),
            PanelCard(kind: .distToGoal,   x: x(2), y: distRowY,  w: w(2), h: halfRowH),
            // Map spans from row 5 down to row 13 (8 rows tall).
            // Wind + radar overlay the upper region.
            PanelCard(kind: .map,          x: x(0), y: y(5),      w: w(4), h: h(8)),
            PanelCard(kind: .windDial,     x: x(0), y: y(5),      w: w(2), h: h(3)),
            PanelCard(kind: .thermalRadar, x: x(2), y: y(5),      w: w(2), h: h(3)),
            PanelCard(kind: .clock,        x: x(0), y: y(13),     w: w(2), h: h(1)),
            PanelCard(kind: .battery,      x: x(2), y: y(13),     w: w(2), h: h(1)),
        ])
    }

    /// Free-flight layout — matches the reference screenshot:
    ///   - Big vario top-left (2×3).
    ///   - Altitude (top) + GroundSpeed (bottom) on the right, each
    ///     exactly HALF the vario's height (1.5 rows each — specified
    ///     as fractions rather than integer rows so they split evenly).
    ///   - Full-width map fills the middle-and-bottom. WindDial (left)
    ///     + ThermalRadar (right) overlay the upper region of the map
    ///     (two-pass zIndex in PanelView puts the map underneath).
    ///   - Clock + battery on the final row. No task cards.
    static var freeFlightLayout: PanelLayout {
        let cols = 4, rows = 15
        func x(_ c: Int) -> CGFloat { CGFloat(c) / CGFloat(cols) }
        func y(_ r: Int) -> CGFloat { CGFloat(r) / CGFloat(rows) }
        func w(_ s: Int) -> CGFloat { CGFloat(s) / CGFloat(cols) }
        func h(_ s: Int) -> CGFloat { CGFloat(s) / CGFloat(rows) }
        // Altitude and groundSpeed split vario's height equally — they
        // sit at rows 0 and 1.5 respectively, each 1.5 rows tall.
        let halfRowH: CGFloat = 1.5 / CGFloat(rows)
        let halfRowY: CGFloat = 1.5 / CGFloat(rows)
        return PanelLayout(cards: [
            PanelCard(kind: .vario,        x: x(0), y: y(0),    w: w(2), h: h(3)),
            PanelCard(kind: .altitude,     x: x(2), y: y(0),    w: w(2), h: halfRowH),
            PanelCard(kind: .groundSpeed,  x: x(2), y: halfRowY, w: w(2), h: halfRowH),
            // Map spans from row 3 down to row 13 (10 rows tall).
            PanelCard(kind: .map,          x: x(0), y: y(3),  w: w(4), h: h(10)),
            PanelCard(kind: .windDial,     x: x(0), y: y(3),  w: w(2), h: h(3)),
            PanelCard(kind: .thermalRadar, x: x(2), y: y(3),  w: w(2), h: h(3)),
            PanelCard(kind: .clock,        x: x(0), y: y(13), w: w(2), h: h(1)),
            PanelCard(kind: .battery,      x: x(2), y: y(13), w: w(2), h: h(1)),
        ])
    }

    static var defaultLayout: PanelLayout { competitionLayout }

    func removing(_ id: UUID) -> PanelLayout {
        PanelLayout(cards: cards.filter { $0.id != id })
    }

    /// Add a card at top-left with a default size for its kind. No
    /// collision avoidance — with free positioning the user places it
    /// wherever they want.
    func adding(_ kind: InstrumentKind) -> PanelLayout {
        let (dw, dh): (CGFloat, CGFloat) = {
            switch kind {
            case .map:                           return (1.0, 5.0 / 15)
            case .vario, .course, .trueHeading:  return (0.5, 2.0 / 15)
            case .windDial, .thermalRadar:       return (0.5, 3.0 / 15)
            case .coordinates:                   return (1.0, 1.0 / 15)
            default:                             return (0.5, 1.0 / 15)
            }
        }()
        let newCard = PanelCard(kind: kind, x: 0, y: 0, w: dw, h: dh)
        return PanelLayout(cards: cards + [newCard])
    }

    var hiddenKinds: [InstrumentKind] {
        let present = Set(cards.map { $0.kind })
        return InstrumentKind.allCases.filter { !present.contains($0) }
    }

    /// Update a card's position/size with clamping to keep it on-panel
    /// and above the minimum footprint.
    func updating(_ id: UUID,
                  x: CGFloat? = nil,
                  y: CGFloat? = nil,
                  w: CGFloat? = nil,
                  h: CGFloat? = nil) -> PanelLayout {
        var result = cards
        guard let i = result.firstIndex(where: { $0.id == id }) else {
            return self
        }
        if let newW = w {
            result[i].w = max(Self.minW, min(1 - result[i].x, newW))
        }
        if let newH = h {
            result[i].h = max(Self.minH, newH)
        }
        if let newX = x {
            result[i].x = max(0, min(1 - result[i].w, newX))
        }
        if let newY = y {
            result[i].y = max(0, newY)
        }
        return PanelLayout(cards: result)
    }

    // MARK: - JSON round-trip

    func toJSON() -> String {
        (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? ""
    }

    static func fromJSON(_ s: String) -> PanelLayout? {
        guard !s.isEmpty, let data = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(PanelLayout.self, from: data)
    }
}
