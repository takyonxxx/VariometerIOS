import SwiftUI

/// Wind direction + speed dial — HEADING-UP layout.
///
/// The dial is pilot-centric: the top of the ring is always the pilot's
/// direction of travel. The whole "world layer" (ring fill, tick marks,
/// N/E/S/W letters and the windsock) rotates by -courseDeg, so a pilot
/// flying east sees N on the LEFT side of the ring and S on the right.
/// The windsock then sits at windFromDeg within that world frame, which
/// places its pole at the wind-FROM bearing *relative to the pilot's
/// body*. Reading examples:
///
///   • Pole at top    → wind hitting the pilot from in front
///   • Pole at bottom → wind from behind (tailwind)
///   • Pole on left   → wind from the pilot's left
///   • Pole on right  → wind from the pilot's right
///
/// This is what paraglider pilots actually want in flight: wind read
/// against the body axis is faster to interpret than absolute compass
/// cardinals like "WNW".
///
/// Layout, from outer to inner:
///   - Static cyan triangle at the very top: pilot heading marker.
///     It does NOT rotate — it's a visual anchor reminding the pilot
///     that the top of the dial is "where I'm going". Sits OUTSIDE
///     the world layer so the world rotates underneath it.
///   - World layer (rotates by -courseDeg):
///       • Ring fill + cyan stroke
///       • 16 tick marks
///       • N/E/S/W letters — positions rotate with the world, but each
///         glyph is counter-rotated (+courseDeg) so the letter shapes
///         themselves stay visually upright at every heading.
///       • Windsock — drawn at windFromDeg within the world frame, so
///         its pole lands at the wind-FROM bearing relative to the
///         pilot, with the sock streaming toward the pilot's body.
///   - Big center readout: speed, unit, cardinal text (e.g. "25 km/h NW").
///     Does NOT rotate. The cardinal text is the ABSOLUTE compass point
///     of the wind source — useful when calling wind on the radio or
///     comparing with windgrams. The dial is heading-up but the spoken
///     name is still north-referenced.
struct WindDial: View {
    let windFromDeg: Double
    let windSpeedKmh: Double
    let courseDeg: Double
    let confidence: Double

    /// Continuously-unwrapped dial rotation in degrees. The dial rotates
    /// by -courseDeg, but we route it through AngleUnwrap (defined in
    /// PanelView.swift) so it never spins a full turn at the 0/360 wrap
    /// point — same trick as the arrow cards.
    @State private var dialRotationDeg: Double = 0

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let r = size / 2

            ZStack {
                // ============================================================
                // WORLD LAYER — rotates by -courseDeg (heading-up).
                // Everything inside here lives in the world's reference
                // frame. The pilot is implicit: always at the top of the
                // dial, looking up.
                // ============================================================
                ZStack {
                    // Compass ring — deep navy with cyan stroke
                    Circle()
                        .fill(Color(red: 0.06, green: 0.10, blue: 0.18).opacity(0.7))
                    Circle()
                        .stroke(Color.cyan.opacity(0.35), lineWidth: 1.5)

                    // Tick marks — 16 around the dial (every 22.5°).
                    // Kept short and pushed to the very outer edge so they
                    // don't reach the cardinal letters.
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

                    // Cardinal letters N/E/S/W — positioned INSIDE the major
                    // ticks. Each label sits at its compass position within
                    // the world frame (so the parent's -courseDeg rotation
                    // sweeps the position around the ring), but the glyph
                    // itself is counter-rotated by +courseDeg so the letter
                    // never appears upside-down or sideways.
                    CardinalLabel(text: "N", radius: r, placement: .north,
                                  isPrimary: true, counterRotateDeg: courseDeg)
                    CardinalLabel(text: "E", radius: r, placement: .east,
                                  counterRotateDeg: courseDeg)
                    CardinalLabel(text: "S", radius: r, placement: .south,
                                  counterRotateDeg: courseDeg)
                    CardinalLabel(text: "W", radius: r, placement: .west,
                                  counterRotateDeg: courseDeg)

                    // Windsock — pole on the wind-FROM bearing within the
                    // world frame. Combined with the world's -courseDeg
                    // rotation, this puts the pole at the wind-FROM bearing
                    // *relative to the pilot* (e.g. "wind from my left").
                    WindsockContainer(sockHeight: r * 0.30,
                                      sockWidth: r * 0.55,
                                      ringRadius: r,
                                      confidence: confidence)
                        .frame(width: size, height: size)
                        .rotationEffect(.degrees(windFromDeg))
                }
                .rotationEffect(.degrees(dialRotationDeg))
                .animation(.easeOut(duration: 0.25), value: dialRotationDeg)

                // ============================================================
                // STATIC OVERLAY — does NOT rotate.
                // The cyan pilot-direction triangle and the center readout
                // sit on top of the world layer.
                // ============================================================

                // Pilot heading marker — small cyan triangle at the very top
                // of the ring, pointing up. Never rotates: top of card is
                // always "ahead". Visual anchor.
                Triangle()
                    .fill(Color.cyan.opacity(0.8))
                    .frame(width: 10, height: 14)
                    .offset(y: -r + 2)

                // Center readouts: wind speed + unit + cardinal text.
                // Cardinal is the ABSOLUTE English compass direction of
                // the wind source (e.g. "NW" = wind from the north-west),
                // unaffected by the pilot's heading.
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
            .onAppear {
                // Initialise so the first frame doesn't animate from 0.
                dialRotationDeg = -courseDeg
            }
            .onChange(of: courseDeg) { newCourse in
                dialRotationDeg = AngleUnwrap.next(
                    current: dialRotationDeg, target: -newCourse)
            }
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
    /// How many degrees to counter-rotate the glyph by. The parent dial
    /// rotates the whole world by -courseDeg; passing +courseDeg here
    /// makes the letter shape stay upright at every heading. Pass 0 (or
    /// omit) for a non-rotating dial.
    var counterRotateDeg: Double = 0

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
            .rotationEffect(.degrees(counterRotateDeg))
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
