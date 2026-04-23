import SwiftUI

/// Wind direction + speed dial.
///
/// Layout, from outer to inner:
///   - Ring with 16 tick marks (major/minor)
///   - N/E/S/W letters JUST INSIDE the ticks (non-rotating, always English)
///   - Windsock on the ring edge, pointing in the direction the wind is
///     *going* (so its pole is on the wind-FROM side, sock trails downwind).
///     This reads more naturally than a vertical sock: if the windsock is
///     to the NW of center with its tail trailing SE, the wind is FROM NW.
///   - Big center readout: speed, unit, cardinal text (e.g. "25  km/h  NW")
///
/// The cardinal labels are English (N/E/S/W + NE/SE/SW/NW intercardinals in
/// the center text), matching the international aviation convention used in
/// XCTrack and similar tools.
struct WindDial: View {
    let windFromDeg: Double
    let windSpeedKmh: Double
    let courseDeg: Double
    let confidence: Double

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2

            ZStack {
                // Compass ring — deep navy with cyan stroke
                Circle()
                    .fill(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.7))
                Circle()
                    .stroke(Color.cyan.opacity(0.35), lineWidth: 1.5)

                // Tick marks — 16 around the dial (every 22.5°).
                // Kept short and pushed to the very outer edge so they don't
                // reach the cardinal letters. Sizes reduced from 12/8/5 to
                // 7/5/3 and offset pushed outward.
                ForEach(0..<16) { i in
                    let a = Double(i) * 22.5
                    let isMajor = (i % 4 == 0)       // N/E/S/W get major ticks
                    let isMinor = (i % 2 == 0)       // NE/SE/SW/NW get medium
                    let tickLen: CGFloat = isMajor ? 7 : (isMinor ? 5 : 3)
                    let tickWidth: CGFloat = isMajor ? 2.5 : (isMinor ? 1.5 : 1)
                    let opacity: Double = isMajor ? 0.85 : (isMinor ? 0.55 : 0.30)
                    Rectangle()
                        .fill(Color.cyan.opacity(opacity))
                        .frame(width: tickWidth, height: tickLen)
                        // Pin to the outer edge: tick's outer end is almost
                        // touching the ring stroke, inner end well clear of
                        // the cardinal label.
                        .offset(y: -r + tickLen / 2 + 2)
                        .rotationEffect(.degrees(a))
                }

                // Cardinal letters N/E/S/W — positioned INSIDE the major ticks,
                // with enough inset that they never touch the tick rectangles.
                // Each label is placed using an offset within a rotated frame,
                // but the TEXT itself does NOT rotate (so N/E/S/W stay upright).
                CardinalLabel(text: "N", radius: r, placement: .north, isPrimary: true)
                CardinalLabel(text: "E", radius: r, placement: .east)
                CardinalLabel(text: "S", radius: r, placement: .south)
                CardinalLabel(text: "W", radius: r, placement: .west)

                // Course / heading triangle (pilot direction, points up)
                Triangle()
                    .fill(Color.cyan.opacity(0.8))
                    .frame(width: 10, height: 14)
                    .offset(y: -r + 2)

                // Windsock — horizontal layout, pole on the ring's outer edge.
                //
                // Trick: we size the container to span the FULL diameter of
                // the ring, and draw the sock at the TOP of that container.
                // The container's geometric center coincides with the ring's
                // center, so `rotationEffect(.degrees(windFromDeg))` rotates
                // the entire container (and the sock within it) around the
                // ring center. The pole stays exactly on the ring edge for
                // every wind direction.
                WindsockContainer(sockHeight: r * 0.30,
                                  sockWidth: r * 0.55,
                                  ringRadius: r,
                                  confidence: confidence)
                    .frame(width: size, height: size)
                    .rotationEffect(.degrees(windFromDeg))

                // Center readouts: wind speed + unit + cardinal text.
                // Cardinal is an English compass direction, shown next to the
                // number so the pilot gets all wind info in one glance.
                VStack(spacing: 0) {
                    Text(String(format: "%.0f", windSpeedKmh))
                        .font(.system(size: r * 0.58, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()
                    HStack(spacing: 6) {
                        Text("km/h")
                            .font(.system(size: r * 0.18, weight: .heavy, design: .rounded))
                            .foregroundColor(.white.opacity(0.85))
                        Text(englishCardinal(windFromDeg))
                            .font(.system(size: r * 0.22, weight: .heavy, design: .rounded))
                            .foregroundColor(Color(red: 0.45, green: 0.85, blue: 1.0))
                            .monospacedDigit()
                    }
                }
                .offset(y: r * 0.08)
            }
            .frame(width: size, height: size)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// English 16-wind compass point from bearing (0 = N, 90 = E, …).
    private func englishCardinal(_ d: Double) -> String {
        let dirs = ["N","NNE","NE","ENE","E","ESE","SE","SSE",
                    "S","SSW","SW","WSW","W","WNW","NW","NNW"]
        var norm = d.truncatingRemainder(dividingBy: 360)
        if norm < 0 { norm += 360 }
        let idx = Int((norm + 11.25) / 22.5) % 16
        return dirs[idx]
    }
}

// MARK: - Windsock container (pivots around ring center)

/// A full-ring-diameter container that draws a horizontal windsock at the
/// TOP of the ring. When the parent applies `rotationEffect(windFromDeg)`,
/// this container rotates around the ring center — so the pole (at the top
/// of the container) sweeps around the ring edge as wind direction changes.
///
/// At wind-from=0 (N), the sock is at top with pole on the outer edge and
/// tail trailing to the WEST (visually: "pole is on the N edge, sock waves
/// to the side"). Pilots read this as "wind is coming from the pole's side".
struct WindsockContainer: View {
    let sockHeight: CGFloat
    let sockWidth: CGFloat
    let ringRadius: CGFloat
    let confidence: Double

    var body: some View {
        ZStack {
            HorizontalWindsock()
                .frame(width: sockWidth, height: sockHeight)
                // Position so the pole (right edge of the widget) sits at
                // x=0 (vertical center line of the ring) and y=-ringRadius
                // (top of the ring). The sock then extends LEFT from there.
                //
                // Widget's own geometric center is offset (-sockWidth/2, 0)
                // from the pole position. Adding a small inset (4 px) keeps
                // the pole just inside the ring edge so it's clearly visible.
                .offset(x: -sockWidth / 2,
                        y: -ringRadius + sockHeight / 2 + 6)
                .opacity(0.85 + 0.15 * confidence)
                .shadow(color: .black.opacity(0.4), radius: 3)
        }
    }
}

// MARK: - Cardinal letter label (non-rotating)

private struct CardinalLabel: View {
    let text: String
    let radius: CGFloat
    let placement: Placement
    var isPrimary: Bool = false

    enum Placement { case north, east, south, west }

    var body: some View {
        // Inset from outer edge so we clear the tick marks (which extend ~15pt
        // inward from the edge for the major ticks including padding).
        let inset = radius * 0.22
        let offset: (dx: CGFloat, dy: CGFloat) = {
            switch placement {
            case .north:  return (0, -(radius - inset))
            case .east:   return (radius - inset, 0)
            case .south:  return (0, radius - inset)
            case .west:   return (-(radius - inset), 0)
            }
        }()

        return Text(text)
            .font(.system(size: radius * 0.16, weight: .heavy, design: .rounded))
            .foregroundColor(isPrimary
                             ? Color(red: 0.45, green: 0.85, blue: 1.0)
                             : .white.opacity(0.82))
            .offset(x: offset.dx, y: offset.dy)
    }
}

// MARK: - Horizontal windsock

/// Airport-style windsock drawn horizontally.
///
/// Layout within its own frame:
///   - POLE is on the RIGHT edge (vertical rod)
///   - SOCK body extends LEFT from the pole, tapering to the tail on the far left
///
/// When the parent view places this widget at offset (x: r - halfWidth, y: 0)
/// and applies `rotationEffect(.degrees(windFromDeg))`, the pole ends up at
/// the wind-FROM bearing on the ring edge, and the sock trails inward toward
/// the center. At rotation 0 (wind from N), the pole is at N (top) and the
/// sock trails down into the ring interior.
///
/// Visually this reads: "the wind is coming FROM the pole's side".
struct HorizontalWindsock: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let poleWidth: CGFloat = 2.5
            let poleHeight: CGFloat = h * 0.95

            ZStack(alignment: .trailing) {
                // Sock body (takes the left portion of the frame)
                ZStack {
                    HorizontalWindsockShape()
                        .fill(Color.white)
                    HorizontalWindsockStripes()
                        .fill(Color(red: 0.90, green: 0.20, blue: 0.20))
                }
                .frame(width: w - poleWidth - 3, height: h * 0.82)
                .offset(x: -(poleWidth + 3) / 2, y: 0)

                // Pole (right edge)
                Rectangle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: poleWidth, height: poleHeight)
                    .overlay(
                        // A small knob at the top of the pole for visual anchor
                        Circle()
                            .fill(Color.white)
                            .frame(width: poleWidth * 2.2, height: poleWidth * 2.2)
                            .offset(y: -poleHeight / 2)
                    )
            }
            .frame(width: w, height: h, alignment: .trailing)
        }
    }
}

/// Sock outline — rectangle tapering from RIGHT (wide, next to the pole) to
/// LEFT (narrow, at the tail tip).
private struct HorizontalWindsockShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tailInset = rect.height * 0.28   // taper amount on the tail (left) side
        // Right edge — full height (attached to pole side)
        p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        // Bottom edge going left — narrows
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - tailInset))
        // Left edge (tail) — shorter
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tailInset))
        p.closeSubpath()
        return p
    }
}

/// Red stripes inside the horizontal sock — alternating bands along its length.
/// Paints 2 red vertical stripes. Note: xFrac=0 is the TAIL (left), xFrac=1 is
/// the POLE (right), so the stripes are positioned using fractions along the
/// sock's length.
private struct HorizontalWindsockStripes: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let tailInset = rect.height * 0.28

        // At fraction f along the length (0 = tail, 1 = pole), the inset from
        // top/bottom is tailInset * (1 - f). So at f=1, inset=0 (full height);
        // at f=0, inset=tailInset (narrow tail).
        func edges(at f: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
            let inset = tailInset * (1 - f)
            return (rect.minY + inset, rect.maxY - inset)
        }

        func xAt(_ f: CGFloat) -> CGFloat {
            return rect.minX + f * rect.width
        }

        // Stripe 1: fractions 0.20 → 0.40 (near the tail)
        let f1a: CGFloat = 0.20, f1b: CGFloat = 0.40
        let e1a = edges(at: f1a), e1b = edges(at: f1b)
        p.move(to:    CGPoint(x: xAt(f1a), y: e1a.top))
        p.addLine(to: CGPoint(x: xAt(f1b), y: e1b.top))
        p.addLine(to: CGPoint(x: xAt(f1b), y: e1b.bottom))
        p.addLine(to: CGPoint(x: xAt(f1a), y: e1a.bottom))
        p.closeSubpath()

        // Stripe 2: fractions 0.60 → 0.80 (toward the pole)
        let f2a: CGFloat = 0.60, f2b: CGFloat = 0.80
        let e2a = edges(at: f2a), e2b = edges(at: f2b)
        p.move(to:    CGPoint(x: xAt(f2a), y: e2a.top))
        p.addLine(to: CGPoint(x: xAt(f2b), y: e2b.top))
        p.addLine(to: CGPoint(x: xAt(f2b), y: e2b.bottom))
        p.addLine(to: CGPoint(x: xAt(f2a), y: e2a.bottom))
        p.closeSubpath()

        return p
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
