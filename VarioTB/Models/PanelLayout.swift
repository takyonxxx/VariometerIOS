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

    var defaultWidth: Int {
        switch self {
        case .vario:         return 2
        case .altitude:      return 2
        case .groundSpeed:   return 2
        case .course:        return 2
        case .trueHeading:   return 2
        case .coordinates:   return 4
        case .windDial:      return 2
        case .thermalRadar:  return 2
        case .clock:         return 2
        case .battery:       return 2
        case .map:           return 4
        case .distToNext:    return 2
        case .distToGoal:    return 2
        case .distToTakeoff: return 2
        }
    }

    var defaultHeight: Int {
        switch self {
        case .vario:        return 2
        case .course:       return 2
        case .trueHeading:  return 2
        case .windDial:     return 3
        case .thermalRadar: return 3
        case .map:          return 6
        default:            return 1
        }
    }
}

/// One placed card on the panel. Position is row×col in a 4-column grid;
/// size in rows×cols. The UI owns "snap-to-grid" during edit.
struct PanelCard: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    var kind: InstrumentKind
    var col: Int           // 0..3
    var row: Int           // 0..N
    var width: Int         // 1..4
    var height: Int        // 1..3

    init(id: UUID = UUID(), kind: InstrumentKind, col: Int, row: Int,
         width: Int? = nil, height: Int? = nil) {
        self.id = id
        self.kind = kind
        self.col = col
        self.row = row
        self.width = width ?? kind.defaultWidth
        self.height = height ?? kind.defaultHeight
    }
}

/// The full panel layout — ordered list of cards. Persisted to UserDefaults
/// as JSON via AppSettings.panelLayoutRaw.
struct PanelLayout: Codable {
    var cards: [PanelCard]

    static let columns = 4

    /// Default factory layout — top shows the classic instruments (vario,
    /// altitude/speed/course row, coords, wind+radar, clock+battery),
    /// then the satellite map takes the bottom half of the screen by
    /// default. All cards are individually resizable and relocatable.
    /// Competition-style layout — designed around the task QR flow:
    /// vario + task-aware course indicator top, hız/rakım beneath,
    /// wind + thermal radar, big map, clock/battery, coordinates,
    /// plus dist-to-takeoff and dist-to-next-TP at the bottom.
    static var competitionLayout: PanelLayout {
        PanelLayout(cards: [
            PanelCard(kind: .vario,         col: 0, row: 0,  width: 2, height: 2),
            PanelCard(kind: .course,        col: 2, row: 0,  width: 2, height: 2),
            PanelCard(kind: .groundSpeed,   col: 0, row: 2,  width: 2, height: 1),
            PanelCard(kind: .altitude,      col: 2, row: 2,  width: 2, height: 1),
            PanelCard(kind: .distToNext,    col: 0, row: 3,  width: 2, height: 1),
            PanelCard(kind: .distToGoal,    col: 2, row: 3,  width: 2, height: 1),
            PanelCard(kind: .windDial,      col: 0, row: 4,  width: 2, height: 3),
            PanelCard(kind: .thermalRadar,  col: 2, row: 4,  width: 2, height: 3),
            PanelCard(kind: .map,           col: 0, row: 7,  width: 4, height: 5),
            PanelCard(kind: .clock,         col: 0, row: 12, width: 2, height: 1),
            PanelCard(kind: .battery,       col: 2, row: 12, width: 2, height: 1),
        ])
    }

    /// Free-flight layout — pared down for XC and recreational flying:
    /// big vario on the left, speed / altitude stacked on the right,
    /// wind + radar, big map, clock + battery. No course card, no
    /// coordinates pill, no task-related distance cards — these only
    /// make sense when a task is loaded. Matches the reference
    /// screenshot the pilot provided.
    static var freeFlightLayout: PanelLayout {
        PanelLayout(cards: [
            PanelCard(kind: .vario,         col: 0, row: 0,  width: 2, height: 2),
            PanelCard(kind: .groundSpeed,   col: 2, row: 0,  width: 2, height: 1),
            PanelCard(kind: .altitude,      col: 2, row: 1,  width: 2, height: 1),
            PanelCard(kind: .windDial,      col: 0, row: 2,  width: 2, height: 4),
            PanelCard(kind: .thermalRadar,  col: 2, row: 2,  width: 2, height: 4),
            PanelCard(kind: .map,           col: 0, row: 6,  width: 4, height: 7),
            PanelCard(kind: .clock,         col: 0, row: 13, width: 2, height: 1),
            PanelCard(kind: .battery,       col: 2, row: 13, width: 2, height: 1),
        ])
    }

    /// Default layout used when the app has no stored layout yet.
    /// The UI exposes BOTH competition and free-flight defaults via
    /// separate buttons in edit mode so the pilot picks the one that
    /// matches what they're doing.
    static var defaultLayout: PanelLayout {
        competitionLayout
    }

    /// Return layout with given card kind removed.
    func removing(_ id: UUID) -> PanelLayout {
        PanelLayout(cards: cards.filter { $0.id != id })
    }

    /// Add a card at the TOP of the grid (row 0, col 0) and push every
    /// existing card downward to make room. This makes newly-added
    /// cards immediately visible — the pilot can see their new card
    /// without having to scroll. It's the same cascade-push logic that
    /// drag-and-drop uses, just kicked off by a synthetic insertion.
    func adding(_ kind: InstrumentKind) -> PanelLayout {
        var newList = cards
        let newCard = PanelCard(kind: kind, col: 0, row: 0)
        newList.append(newCard)
        // Let placing() run the cascade: newCard at (0, 0), anything it
        // collides with gets pushed down. Result: newCard on top,
        // original cards shifted by exactly enough rows to clear it.
        return PanelLayout(cards: newList).placing(newCard.id, col: 0, row: 0)
    }

    /// Kinds not currently present — candidates for adding.
    var hiddenKinds: [InstrumentKind] {
        let present = Set(cards.map { $0.kind })
        return InstrumentKind.allCases.filter { !present.contains($0) }
    }

    // MARK: - Collision detection
    //
    // Grid slots are addressed as [col, row] pairs. A card occupies the
    // rectangle [col..<col+width] × [row..<row+height]. Two rectangles
    // overlap iff they overlap on BOTH axes simultaneously.

    /// Returns true if placing a card at (col, row) with (width, height)
    /// would overlap any *other* existing card. Pass the id being moved
    /// so it doesn't collide with itself.
    func wouldCollide(excluding movingID: UUID,
                      col: Int, row: Int,
                      width: Int, height: Int) -> Bool {
        for c in cards where c.id != movingID {
            let hOverlap = col < c.col + c.width && c.col < col + width
            let vOverlap = row < c.row + c.height && c.row < row + height
            if hOverlap && vOverlap { return true }
        }
        return false
    }

    /// Swap two cards' grid positions and sizes. Used when the pilot
    /// drags card A directly onto card B in edit mode — instead of
    /// cascade-pushing, we just exchange their slots. This matches the
    /// intuitive "grab this, put it where that one was" gesture, and
    /// the other card conveniently ends up where the first one started.
    ///
    /// Only swaps if the two cards have compatible footprints; if their
    /// dimensions differ, swapping would leave holes in the grid, so
    /// we fall back to `placing` (cascade push) instead.
    func swapping(_ aID: UUID, with bID: UUID) -> PanelLayout? {
        guard let ai = cards.firstIndex(where: { $0.id == aID }),
              let bi = cards.firstIndex(where: { $0.id == bID }),
              ai != bi else { return nil }
        // Different sized cards can't cleanly swap — caller should
        // fall back to placing() for those cases.
        if cards[ai].width != cards[bi].width ||
           cards[ai].height != cards[bi].height { return nil }
        var result = cards
        let aCol = result[ai].col, aRow = result[ai].row
        result[ai].col = result[bi].col; result[ai].row = result[bi].row
        result[bi].col = aCol;           result[bi].row = aRow
        return PanelLayout(cards: result)
    }

    /// Returns the ID of the card that occupies slot (col, row), if any.
    /// Used by drag-end to decide whether the drop target lands on an
    /// existing card (→ swap) or an empty slot (→ placing cascade).
    func cardAt(col: Int, row: Int) -> UUID? {
        for c in cards {
            let inCol = col >= c.col && col < c.col + c.width
            let inRow = row >= c.row && row < c.row + c.height
            if inCol && inRow { return c.id }
        }
        return nil
    }

    /// Drop a card at (targetCol, targetRow) and push any colliding cards
    /// downward to make room. The push cascades — if a pushed card would
    /// land on a third card, that one is pushed too. Because the grid is
    /// unbounded downward, this always terminates.
    ///
    /// This is what gives the layout an "iOS home screen" feel: drag a
    /// card into a crowded area and the others shuffle out of the way
    /// rather than rejecting the drop.
    func placing(_ movingID: UUID,
                 col: Int,
                 row: Int) -> PanelLayout {
        guard let movingIdx = cards.firstIndex(where: { $0.id == movingID }) else {
            return self
        }
        var result = cards
        // Put the moving card at its new slot first so collision tests
        // include its new rectangle.
        result[movingIdx].col = col
        result[movingIdx].row = row

        // Repeatedly find any collider and push it below the moving card.
        // Cap iterations to avoid pathological infinite loops.
        for _ in 0..<200 {
            let ids = result.map(\.id)
            var moved = false
            for i in ids.indices {
                let a = result[i]
                for j in ids.indices where j != i {
                    let b = result[j]
                    let hOv = a.col < b.col + b.width && b.col < a.col + a.width
                    let vOv = a.row < b.row + b.height && b.row < a.row + a.height
                    if hOv && vOv {
                        // Decide which one to move: always push the non-
                        // moving card (b if a is the moving one, else a).
                        let pushIdx: Int
                        if a.id == movingID { pushIdx = j }
                        else if b.id == movingID { pushIdx = i }
                        else {
                            // Two non-moving cards overlap (shouldn't
                            // normally happen — push the later one).
                            pushIdx = max(i, j)
                        }
                        let other = (pushIdx == i) ? b : a
                        // Push pushed-card to other.row + other.height
                        // so they stack vertically.
                        result[pushIdx].row = other.row + other.height
                        moved = true
                    }
                }
            }
            if !moved { break }
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
