import SwiftUI
import MapKit
import CoreLocation

struct SatelliteMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let heading: Double
    let thermals: [ThermalPoint]
    /// FAI-VALIDATED triangle (drawn green/amber depending on isClosed).
    /// nil while the brute-force search hasn't found a triangle that
    /// satisfies the 28% leg ratio.
    let triangle: FAITriangle?
    /// PROVISIONAL "what am I currently flying" triangle. Three corners:
    /// takeoff, the farthest point reached, the live pilot position.
    /// Drawn dashed yellow. Independent of FAI rules — exists as soon
    /// as the pilot has flown a meaningfully-sized shape. May be drawn
    /// alongside `triangle`: the validated green triangle is layered
    /// on top of the dashed yellow one, so both are visible while the
    /// flight grows.
    let provisionalTriangle: FAITriangle?
    let flightStart: CLLocationCoordinate2D?   // for closing arrow
    let task: CompetitionTask?                  // competition task overlay
    /// Changes to this UUID trigger a one-time "zoom to fit the whole
    /// triangle" animation. Set to nil to skip. Used when the user taps
    /// the FAI HUD card.
    let fitTriangleToken: UUID?
    /// Changes to this UUID trigger a one-time "zoom to fit the entire
    /// task" animation — all turnpoint cylinders + pilot in view.
    /// Auto-follow should be disabled before bumping this token so the
    /// user can inspect the task without immediately being snapped back
    /// to their pilot marker.
    let fitTaskToken: UUID?
    @Binding var autoFollow: Bool   // true = follow pilot; false = free pan

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.preferredConfiguration = MKHybridMapConfiguration(elevationStyle: .realistic)
        mv.isRotateEnabled = false
        mv.isPitchEnabled = false
        mv.isZoomEnabled = true
        mv.isScrollEnabled = true
        mv.showsCompass = false
        mv.showsScale = false
        mv.showsUserLocation = false
        mv.delegate = context.coordinator
        context.coordinator.parent = self

        // Initial region: center on the pilot if we already have a fix,
        // otherwise fall back to Ayaş so the user sees something rather
        // than the default world view. We intentionally do NOT update
        // `lastCenter` here — we want updateUIView to still do its
        // "first real centering" pass once the pilot's actual coordinate
        // arrives from the GPS or simulator.
        let initialCenter = coordinate
            ?? CLLocationCoordinate2D(latitude: 40.031450, longitude: 32.328050)  // Ayaş/Kumludoruk
        let initialSpan = MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
        mv.setRegion(MKCoordinateRegion(center: initialCenter, span: initialSpan),
                     animated: false)

        // If coordinate is already available at makeUIView time, drop the
        // pilot annotation now — but still leave lastCenter unset so the
        // next updateUIView properly recenters once real movement happens.
        if let c = coordinate {
            let a = PilotAnnotation()
            a.coordinate = c
            mv.addAnnotation(a)
            context.coordinator.pilotAnnotation = a
        }

        // Observe user pans/pinches to disable auto-follow.
        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.userPanned(_:)))
        pan.delegate = context.coordinator
        mv.addGestureRecognizer(pan)

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.userPinched(_:)))
        pinch.delegate = context.coordinator
        mv.addGestureRecognizer(pinch)

        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.parent = self

        // Detect autoFollow transitioning from false -> true: force immediate recenter
        let followJustTurnedOn = !context.coordinator.lastAutoFollow && autoFollow
        context.coordinator.lastAutoFollow = autoFollow

        // Diagnostic: log first few updates + any autoFollow change
        context.coordinator.updateCount += 1
        if context.coordinator.updateCount <= 5 ||
           followJustTurnedOn ||
           context.coordinator.lastLoggedAutoFollow != autoFollow {
            let coordStr = coordinate.map { String(format: "(%.5f,%.5f)", $0.latitude, $0.longitude) } ?? "nil"
            print("[MAP] update#\(context.coordinator.updateCount) coord=\(coordStr) autoFollow=\(autoFollow) lastCenter=\(context.coordinator.lastCenter == nil ? "nil" : "set")")
            context.coordinator.lastLoggedAutoFollow = autoFollow
        }

        if let c = coordinate {
            if autoFollow {
                let needsInitialCenter = context.coordinator.lastCenter == nil || followJustTurnedOn
                let movedEnough: Bool = {
                    guard let last = context.coordinator.lastCenter else { return true }
                    let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    let b = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    return a.distance(from: b) > 30
                }()

                if needsInitialCenter || movedEnough {
                    print("[MAP] RECENTER reason=\(needsInitialCenter ? "initial" : "moved")")
                    context.coordinator.programmaticChange = true
                    if context.coordinator.lastCenter == nil {
                        let span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        mv.setRegion(MKCoordinateRegion(center: c, span: span), animated: false)
                    } else {
                        mv.setCenter(c, animated: true)
                    }
                    context.coordinator.lastCenter = c
                }
            }

            if let pilot = context.coordinator.pilotAnnotation {
                pilot.coordinate = c
            } else {
                let a = PilotAnnotation()
                a.coordinate = c
                mv.addAnnotation(a)
                context.coordinator.pilotAnnotation = a
            }
        }

        // Sync thermal annotations
        let existing = mv.annotations.compactMap { $0 as? ThermalAnnotation }
        let existingIDs = Set(existing.map { $0.id })
        let newIDs = Set(thermals.map { $0.id })
        for ann in existing where !newIDs.contains(ann.id) {
            mv.removeAnnotation(ann)
        }
        for t in thermals where !existingIDs.contains(t.id) {
            let a = ThermalAnnotation(thermal: t)
            mv.addAnnotation(a)
        }

        // Sync FAI triangle overlays. We track two independently:
        // - ProvisionalTriangleOverlay (always dashed amber): the
        //   "shape I'm flying right now" triangle, present whenever
        //   the detector emits one.
        // - TriangleOverlay (green/amber by isClosed): the FAI-valid
        //   triangle once brute-force has found one. Drawn ON TOP of
        //   the provisional so the validated geometry wins visually
        //   when both exist.
        for overlay in mv.overlays where overlay is ProvisionalTriangleOverlay {
            mv.removeOverlay(overlay)
        }
        if let prov = provisionalTriangle {
            // Add the provisional first so the valid triangle (added
            // below) renders on top of it via MapKit's overlay order.
            mv.addOverlay(ProvisionalTriangleOverlay(triangle: prov),
                          level: .aboveLabels)
        }
        for overlay in mv.overlays where overlay is TriangleOverlay {
            mv.removeOverlay(overlay)
        }
        if let tri = triangle {
            let ov = TriangleOverlay(triangle: tri)
            mv.addOverlay(ov, level: .aboveLabels)
        }

        // Sync closing arrow overlay — drawn only while the triangle is
        // detected but NOT yet closed. Shows the pilot which direction to
        // glide to close the FAI triangle.
        for overlay in mv.overlays where overlay is ClosingArrowOverlay {
            mv.removeOverlay(overlay)
        }
        if let tri = triangle,
           !tri.isClosed,
           let pilot = coordinate,
           let start = flightStart {
            let ov = ClosingArrowOverlay(from: pilot, to: start)
            mv.addOverlay(ov)
        }

        // Sync competition task overlays: turnpoint cylinders (blue circles)
        // + connecting route line. To avoid flicker during high-frequency
        // GPS updates, we only tear down and rebuild when the task's
        // turnpoint signature (count, IDs, coords, radii) actually
        // changes — see Coordinator.lastTaskSignature.
        let sig = Self.taskSignature(task)
        if sig != context.coordinator.lastTaskSignature {
            context.coordinator.lastTaskSignature = sig
            for overlay in mv.overlays
                where overlay is TurnpointCylinderOverlay
                   || overlay is TaskRouteOverlay {
                mv.removeOverlay(overlay)
            }
            for ann in mv.annotations.compactMap({ $0 as? TurnpointAnnotation }) {
                mv.removeAnnotation(ann)
            }
            if let task = task, !task.turnpoints.isEmpty {
                for (idx, tp) in task.turnpoints.enumerated() {
                    let cyl = TurnpointCylinderOverlay(turnpoint: tp)
                    mv.addOverlay(cyl)
                    let ann = TurnpointAnnotation(turnpoint: tp, index: idx + 1)
                    mv.addAnnotation(ann)
                }
                if task.turnpoints.count >= 2 {
                    let optimal = Self.optimalRoutePoints(for: task.turnpoints)
                    for i in 0..<(optimal.count - 1) {
                        let leg = TaskRouteOverlay(fromPoint: optimal[i],
                                                    toPoint: optimal[i + 1])
                        mv.addOverlay(leg)
                    }
                }
            }
        }

        // "Zoom to triangle" — only runs when the token changes (user
        // tapped the FAI HUD card). Fits all 3 turnpoints + pilot + home
        // into view with padding, animated.
        if let token = fitTriangleToken,
           token != context.coordinator.lastFitToken,
           let tri = triangle {
            context.coordinator.lastFitToken = token
            context.coordinator.programmaticChange = true
            var coords: [CLLocationCoordinate2D] = [tri.tp1, tri.tp2, tri.tp3]
            if let pilot = coordinate { coords.append(pilot) }
            if let home = flightStart { coords.append(home) }
            let rect = Self.boundingRect(for: coords)
            let padded = rect.insetBy(dx: -rect.size.width * 0.25,
                                      dy: -rect.size.height * 0.25)
            mv.setVisibleMapRect(padded,
                                 edgePadding: UIEdgeInsets(top: 40, left: 30,
                                                            bottom: 30, right: 30),
                                 animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                context.coordinator.programmaticChange = false
            }
        }

        // "Zoom to fit task" — triggered when the user loads a task via
        // QR scan. Frames ALL task turnpoints (their cylinder edges,
        // not just the center) plus the pilot into view so the whole
        // task is visible at a glance without any panning.
        if let token = fitTaskToken,
           token != context.coordinator.lastFitTaskToken,
           let t = task,
           !t.turnpoints.isEmpty {
            context.coordinator.lastFitTaskToken = token
            context.coordinator.programmaticChange = true
            // Sample each turnpoint's cylinder at the 4 cardinal edge
            // points so the framing includes the full cylinder footprint
            // rather than just the center.
            var coords: [CLLocationCoordinate2D] = []
            let metersPerDegLat = 111_000.0
            for tp in t.turnpoints {
                let metersPerDegLon = 111_000.0 * cos(tp.latitude * .pi / 180)
                let dLat = tp.radiusM / metersPerDegLat
                let dLon = tp.radiusM / metersPerDegLon
                coords.append(CLLocationCoordinate2D(latitude: tp.latitude + dLat,
                                                      longitude: tp.longitude))
                coords.append(CLLocationCoordinate2D(latitude: tp.latitude - dLat,
                                                      longitude: tp.longitude))
                coords.append(CLLocationCoordinate2D(latitude: tp.latitude,
                                                      longitude: tp.longitude + dLon))
                coords.append(CLLocationCoordinate2D(latitude: tp.latitude,
                                                      longitude: tp.longitude - dLon))
            }
            if let pilot = coordinate { coords.append(pilot) }
            let rect = Self.boundingRect(for: coords)
            // Less aggressive padding than triangle — the task itself is
            // already well-distributed so we just need a small inset.
            let padded = rect.insetBy(dx: -rect.size.width * 0.10,
                                      dy: -rect.size.height * 0.10)
            mv.setVisibleMapRect(padded,
                                 edgePadding: UIEdgeInsets(top: 30, left: 20,
                                                            bottom: 20, right: 20),
                                 animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                context.coordinator.programmaticChange = false
            }
        }
    }

    /// Compute the bounding MKMapRect covering a set of coordinates.
    private static func boundingRect(for coords: [CLLocationCoordinate2D]) -> MKMapRect {
        guard !coords.isEmpty else { return MKMapRect.world }
        var rect = MKMapRect.null
        for c in coords {
            let p = MKMapPoint(c)
            let r = MKMapRect(x: p.x, y: p.y, width: 0.1, height: 0.1)
            rect = rect.union(r)
        }
        return rect
    }

    /// Cheap stable signature of a task used to detect "did the set of
    /// turnpoints change" without deep equality checks. If any turnpoint
    /// is added/removed/moved/resized, the string changes, so the map's
    /// overlay cache knows to rebuild.
    private static func taskSignature(_ task: CompetitionTask?) -> String {
        guard let t = task else { return "" }
        var s = ""
        for tp in t.turnpoints {
            s += String(format: "%@/%.5f,%.5f,%.0f|",
                        tp.id.uuidString, tp.latitude, tp.longitude, tp.radiusM)
        }
        return s
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Optimal route computation
    //
    // Each turnpoint is a cylinder. The optimal task route threads between
    // cylinders, touching each one tangentially at the point that minimizes
    // total path length. For competition tasks this is the distance pilots
    // are actually scored on ("through cylinders"). Flyskyhy and XCTrack
    // both render this optimized route.
    //
    // The first/last points are just the turnpoint centers (they anchor the
    // path). Interior turnpoints get optimized. For each interior TP:
    //
    //   optimal_i = center_i + radius_i * unit_vector(
    //                 (optimal_{i-1} - center_i).normalized
    //               + (optimal_{i+1} - center_i).normalized
    //               )
    //
    // i.e. on the cylinder edge in the direction of the angle bisector
    // pointing AWAY from both neighbors. We iterate 8 passes which converges
    // well for typical competition tasks (6-12 turnpoints).

    /// Compute the optimal tangent route through the given turnpoints.
    /// Returns a polyline the pilot should fly to visit every turnpoint
    /// in order. One point per turnpoint, plus optional "exit" points
    /// inserted when consecutive turnpoints are same-center concentric
    /// cylinders that would otherwise be collapsed.
    ///
    /// Algorithm:
    ///
    ///   1. Initialize each point at its cylinder's center.
    ///   2. Run 8 iterations of bisector relaxation — each interior
    ///      point moves to the point on its cylinder edge along the
    ///      bisector of the angle formed by its neighbors. This is
    ///      the classic competition-optimum tangent construction.
    ///   3. Degenerate case: if bisector collapses (all three consecutive
    ///      TPs share the same center → bisector = 0, perpendicular
    ///      fallback = 0), place the point on the goal-side radial
    ///      instead. Keeps concentric laps on one side of the center
    ///      rather than ping-ponging through it.
    ///   4. Shift non-SSS tag points 30 m INWARD so the sim/pilot
    ///      actually crosses the cylinder boundary (reach detection
    ///      needs an interior fix with the 15 m tolerance).
    ///   5. Insert an extra OUTSIDE point (radius + 100 m) before any
    ///      entry cylinder whose predecessor point is already inside
    ///      its boundary. This handles concentric laps where the pilot
    ///      is coming from a smaller sibling — they have to exit the
    ///      larger cylinder before re-entering.
    ///   6. SSS (exit gate): move the point OUTSIDE the cylinder so
    ///      the pilot tags on outward crossing, not entry.
    static func optimalRoutePoints(for turnpoints: [Turnpoint]) -> [CLLocationCoordinate2D] {
        guard turnpoints.count >= 2 else {
            return turnpoints.map { $0.coordinate }
        }

        let centerLatRad = turnpoints[0].latitude * .pi / 180
        let lonScale = cos(centerLatRad)
        let metersPerDeg = 111_000.0

        func toXY(_ c: CLLocationCoordinate2D) -> (x: Double, y: Double) {
            (c.longitude * lonScale, c.latitude)
        }
        func fromXY(_ p: (x: Double, y: Double)) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: p.y, longitude: p.x / lonScale)
        }

        var pts: [(x: Double, y: Double)] = turnpoints.map { toXY($0.coordinate) }
        let centers = pts
        let radii = turnpoints.map { $0.radiusM / metersPerDeg }

        // Goal-side radial direction for each cylinder, used as
        // fallback when the bisector is degenerate.
        let goalXY = toXY(turnpoints.last!.coordinate)
        var goalRadial: [(dx: Double, dy: Double)] = centers.map { c in
            let dx = goalXY.x - c.x
            let dy = goalXY.y - c.y
            let len = sqrt(dx*dx + dy*dy)
            if len < 1e-12 { return (1, 0) }   // goal itself — arbitrary
            return (dx / len, dy / len)
        }

        // Bisector relaxation — 8 iterations converges for typical
        // competition-scale tasks.
        let iterations = 8
        for _ in 0..<iterations {
            var next = pts
            for i in 1..<(pts.count - 1) {
                let c = centers[i]
                let prev = pts[i - 1]
                let after = pts[i + 1]
                let vPrev = normalized(dx: prev.x - c.x, dy: prev.y - c.y)
                let vNext = normalized(dx: after.x - c.x, dy: after.y - c.y)
                var bx = vPrev.dx + vNext.dx
                var by = vPrev.dy + vNext.dy
                var blen = sqrt(bx*bx + by*by)
                if blen < 1e-9 {
                    // Try perpendicular to (next - prev)
                    let dx = after.x - prev.x
                    let dy = after.y - prev.y
                    let perp = normalized(dx: -dy, dy: dx)
                    bx = perp.dx; by = perp.dy
                    blen = sqrt(bx*bx + by*by)
                }
                if blen < 1e-9 {
                    // Fully degenerate (all three coincident centers —
                    // concentric lap case). Use goal-side radial so
                    // laps progress toward goal instead of oscillating.
                    bx = goalRadial[i].dx
                    by = goalRadial[i].dy
                } else {
                    bx /= blen; by /= blen
                }
                next[i] = (c.x + bx * radii[i], c.y + by * radii[i])
            }
            pts = next
        }

        // Convert to coordinates and apply type-aware shifts so the
        // pilot crosses each boundary correctly.
        var out: [CLLocationCoordinate2D] = []
        out.reserveCapacity(pts.count * 2)
        out.append(fromXY(pts[0]))   // start point — unchanged

        for i in 1..<pts.count {
            let tp = turnpoints[i]
            let tpCoord = turnpoints[i].coordinate
            let rawEdge = fromXY(pts[i])

            switch tp.type {
            case .takeoff:
                out.append(rawEdge)   // unused in practice

            case .sss:
                // Exit gate — move point OUTSIDE the cylinder by 100 m
                // along the radial from center through rawEdge. If the
                // raw edge happens to be the center (degenerate SSS at
                // launch), use the goal-side radial.
                let shifted = shiftOutward(
                    point: rawEdge, center: tpCoord,
                    radius: tp.radiusM, extraM: 100,
                    fallbackRadial: goalRadial[i],
                    lonScale: lonScale)
                out.append(shifted)

            case .turn, .ess:
                // Check whether the previous path point is INSIDE this
                // cylinder — if so, we need an explicit exit point
                // first so the pilot can leave before re-entering.
                let prevPt = out.last!
                if metersBetween(prevPt, tpCoord) < tp.radiusM {
                    let outPt = shiftOutward(
                        point: rawEdge, center: tpCoord,
                        radius: tp.radiusM, extraM: 100,
                        fallbackRadial: goalRadial[i],
                        lonScale: lonScale)
                    out.append(outPt)
                }
                // Tag point — 30 m inside boundary along the bisector
                // direction (i.e. pull rawEdge toward center by 30 m).
                let shifted = shiftInward(
                    point: rawEdge, center: tpCoord, byM: 30)
                out.append(shifted)

            case .goal:
                let prevPt = out.last!
                if metersBetween(prevPt, tpCoord) < tp.radiusM {
                    let outPt = shiftOutward(
                        point: rawEdge, center: tpCoord,
                        radius: tp.radiusM, extraM: 100,
                        fallbackRadial: goalRadial[i],
                        lonScale: lonScale)
                    out.append(outPt)
                }
                out.append(tpCoord)   // land at goal center
            }
        }

        return out
    }

    private static func normalized(dx: Double, dy: Double) -> (dx: Double, dy: Double) {
        let len = sqrt(dx*dx + dy*dy)
        if len < 1e-12 { return (0, 0) }
        return (dx / len, dy / len)
    }

    /// Distance in meters between two coordinates.
    private static func metersBetween(_ a: CLLocationCoordinate2D,
                                       _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let sa = sin(dLat/2), sb = sin(dLon/2)
        let h = sa*sa + cos(lat1)*cos(lat2)*sb*sb
        return 2 * R * asin(min(1, sqrt(h)))
    }

    /// Move `point` 30 m toward `center`. Used to nudge tag points
    /// inside their cylinder so reach detection fires reliably.
    private static func shiftInward(point: CLLocationCoordinate2D,
                                     center: CLLocationCoordinate2D,
                                     byM: Double) -> CLLocationCoordinate2D {
        let d = metersBetween(point, center)
        if d <= byM { return center }   // already at/near center
        let frac = byM / d
        return CLLocationCoordinate2D(
            latitude: point.latitude + (center.latitude - point.latitude) * frac,
            longitude: point.longitude + (center.longitude - point.longitude) * frac)
    }

    /// Move `point` outward so it sits `radius + extraM` from `center`.
    /// If `point` is at the center (degenerate), use `fallbackRadial`
    /// for direction.
    private static func shiftOutward(point: CLLocationCoordinate2D,
                                      center: CLLocationCoordinate2D,
                                      radius: Double,
                                      extraM: Double,
                                      fallbackRadial: (dx: Double, dy: Double),
                                      lonScale: Double) -> CLLocationCoordinate2D {
        let metersPerDeg = 111_000.0
        let d = metersBetween(point, center)
        let targetM = radius + extraM
        if d < 1 {
            // Point at center — use fallback radial.
            return CLLocationCoordinate2D(
                latitude: center.latitude + fallbackRadial.dy * targetM / metersPerDeg,
                longitude: center.longitude + fallbackRadial.dx * targetM / (metersPerDeg * lonScale))
        }
        let scale = targetM / d
        return CLLocationCoordinate2D(
            latitude: center.latitude + (point.latitude - center.latitude) * scale,
            longitude: center.longitude + (point.longitude - center.longitude) * scale)
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SatelliteMapView?
        var pilotAnnotation: PilotAnnotation?
        var lastCenter: CLLocationCoordinate2D?
        var lastAutoFollow: Bool = true
        /// For diagnostic logging — counts updateUIView invocations and
        /// remembers last autoFollow value we logged to avoid spam.
        var updateCount: Int = 0
        var lastLoggedAutoFollow: Bool = true
        /// Remembers the last fit-triangle token we handled, so we only
        /// animate the region change when the token actually changes.
        var lastFitToken: UUID?
        var lastFitTaskToken: UUID?
        /// Cached signature of the task's turnpoints — used to skip the
        /// expensive overlay rebuild on every GPS update. Only when the
        /// turnpoints actually change (edit, clear, import) do we tear
        /// down and re-add the cylinder + route overlays. Without this,
        /// task visuals flicker at ~10Hz while the simulator is running.
        var lastTaskSignature: String = ""
        // When we programmatically re-center the map, the regionWillChange
        // callback fires too. This flag tells us to ignore it so we don't
        // accidentally turn off auto-follow.
        var programmaticChange = false

        // MARK: - Gesture handling (observe-only)

        @objc func userPanned(_ g: UIPanGestureRecognizer) {
            // As soon as the user starts panning the map, turn off auto-follow
            if g.state == .began {
                print("[MAP] userPanned → autoFollow=false")
                DispatchQueue.main.async { [weak self] in
                    self?.parent?.autoFollow = false
                }
            }
        }

        @objc func userPinched(_ g: UIPinchGestureRecognizer) {
            // Pinch-to-zoom doesn't turn off follow — user probably still wants
            // to see themselves, just at a different scale. Do nothing.
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Let our observer run alongside MapKit's own gestures
            true
        }

        // MARK: - MKMapViewDelegate

        func mapView(_ mapView: MKMapView,
                     regionWillChangeAnimated animated: Bool) {
            // Reset the flag each time; if this change was programmatic we ignore,
            // otherwise it was the user.
            if programmaticChange {
                programmaticChange = false
            }
            // We don't disable auto-follow here because regionWillChange also
            // fires for programmatic setCenter. Gesture recognizers do that job.
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is PilotAnnotation {
                let id = "pilot"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = Self.pilotImage
                view.centerOffset = .zero
                return view
            }
            if let t = annotation as? ThermalAnnotation {
                let id = "thermal"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = Self.thermalImage(strength: t.thermal.strength)
                view.canShowCallout = true
                // Image is 20×20 with the colored circle inset symmetrically,
                // so image-center == circle-center == thermal coordinate.
                // Reset any offset in case a recycled view carried one over.
                view.centerOffset = .zero
                return view
            }
            if let tp = annotation as? TurnpointAnnotation {
                let id = "turnpoint"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: annotation, reuseIdentifier: id)
                view.annotation = annotation
                view.image = Self.turnpointImage(type: tp.turnpoint.type, index: tp.index)
                view.canShowCallout = true
                // The turnpoint image is fully symmetric (24×24 disc with
                // image-center == disc-center), so .zero offset puts the
                // disc center exactly on the cylinder's center coordinate.
                // Reset explicitly in case a recycled view carried over an
                // offset from a previous configuration.
                view.centerOffset = .zero
                return view
            }
            return nil
        }

        /// Render FAI triangle overlay, closing arrow, and competition task.
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tri = overlay as? TriangleOverlay {
                return TriangleOverlayRenderer(triangleOverlay: tri)
            }
            if let prov = overlay as? ProvisionalTriangleOverlay {
                return ProvisionalTriangleOverlayRenderer(provisionalOverlay: prov)
            }
            if let arrow = overlay as? ClosingArrowOverlay {
                return ClosingArrowRenderer(arrowOverlay: arrow)
            }
            if let cyl = overlay as? TurnpointCylinderOverlay {
                return TurnpointCylinderRenderer(cylinderOverlay: cyl)
            }
            if let route = overlay as? TaskRouteOverlay {
                return TaskLegRenderer(leg: route)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        /// Pilot marker drawn as a stylised paragliding silhouette —
        /// curved wing on top with a pilot figure suspended beneath.
        /// Uses bright yellow with a dark outline so it stays visible
        /// against both green terrain and the blue task route lines.
        /// Size 36×36 in points — slightly larger than the old dot so
        /// the silhouette detail reads clearly on retina screens.
        static let pilotImage: UIImage = {
            let size = CGSize(width: 36, height: 36)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                let fill = UIColor(red: 1.0, green: 0.82, blue: 0.08, alpha: 1.0)   // vivid yellow
                let stroke = UIColor.black
                c.setFillColor(fill.cgColor)
                c.setStrokeColor(stroke.cgColor)
                c.setLineJoin(.round)
                c.setLineCap(.round)
                c.setLineWidth(1.2)

                // Wing — a broad arc like a rainbow cap across the top
                // third of the icon. Drawn as a filled path between
                // two arcs (outer curve + inner curve).
                let wing = UIBezierPath()
                wing.move(to: CGPoint(x: 4, y: 12))
                wing.addCurve(to: CGPoint(x: 32, y: 12),
                              controlPoint1: CGPoint(x: 10, y: 1),
                              controlPoint2: CGPoint(x: 26, y: 1))
                wing.addCurve(to: CGPoint(x: 28, y: 15),
                              controlPoint1: CGPoint(x: 31, y: 14),
                              controlPoint2: CGPoint(x: 29.5, y: 14.5))
                wing.addCurve(to: CGPoint(x: 8, y: 15),
                              controlPoint1: CGPoint(x: 22, y: 6),
                              controlPoint2: CGPoint(x: 14, y: 6))
                wing.addCurve(to: CGPoint(x: 4, y: 12),
                              controlPoint1: CGPoint(x: 6.5, y: 14.5),
                              controlPoint2: CGPoint(x: 5, y: 14))
                wing.close()
                wing.fill()
                wing.stroke()

                // Suspension lines — from the wing's underside to the
                // pilot's shoulders.
                c.setLineWidth(1.0)
                c.setStrokeColor(stroke.cgColor)
                c.move(to: CGPoint(x: 9, y: 14))
                c.addLine(to: CGPoint(x: 16, y: 24))
                c.move(to: CGPoint(x: 27, y: 14))
                c.addLine(to: CGPoint(x: 20, y: 24))
                c.strokePath()

                // Pilot head — small filled circle.
                c.setFillColor(fill.cgColor)
                c.setStrokeColor(stroke.cgColor)
                c.setLineWidth(1.0)
                let head = CGRect(x: 16, y: 20, width: 4, height: 4)
                c.fillEllipse(in: head)
                c.strokeEllipse(in: head)

                // Pilot body — a rounded triangle / capsule below the
                // head, reads as a seated harness silhouette.
                let body = UIBezierPath()
                body.move(to: CGPoint(x: 15, y: 25))
                body.addLine(to: CGPoint(x: 21, y: 25))
                body.addQuadCurve(to: CGPoint(x: 19, y: 33),
                                   controlPoint: CGPoint(x: 22, y: 30))
                body.addLine(to: CGPoint(x: 17, y: 33))
                body.addQuadCurve(to: CGPoint(x: 15, y: 25),
                                   controlPoint: CGPoint(x: 14, y: 30))
                body.close()
                body.fill()
                body.stroke()
            }
        }()

        static func thermalImage(strength: Double) -> UIImage {
            // Red gradient scale — strong red for powerful thermals,
            // softer red/orange for weaker ones. Kept fully symmetric:
            // a 14-pt circle inset by 3 pt inside a 20×20 image so the
            // circle center is the image center, which means the dot
            // lands exactly on the thermal coordinate (no centerOffset
            // is applied to ThermalAnnotation views).
            let color: UIColor
            if strength >= 3.0 { color = UIColor(red: 1.00, green: 0.20, blue: 0.20, alpha: 1) }
            else if strength >= 2.0 { color = UIColor(red: 1.00, green: 0.30, blue: 0.30, alpha: 1) }
            else if strength >= 1.0 { color = UIColor(red: 0.95, green: 0.40, blue: 0.40, alpha: 1) }
            else { color = UIColor(red: 0.85, green: 0.45, blue: 0.45, alpha: 1) }
            let size = CGSize(width: 20, height: 20)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                c.setFillColor(color.cgColor)
                c.fillEllipse(in: CGRect(x: 3, y: 3, width: 14, height: 14))
                c.setStrokeColor(UIColor.white.cgColor)
                c.setLineWidth(2)
                c.strokeEllipse(in: CGRect(x: 3, y: 3, width: 14, height: 14))
            }
        }

        /// Turnpoint marker: a small symmetric color-coded disc with
        /// the index number inside.
        ///
        /// Drawn fully symmetric so the image's geometric center IS the
        /// disc's center. Combined with `centerOffset = .zero` on the
        /// annotation view, this places the disc center exactly on the
        /// turnpoint coordinate — i.e. exactly on the cylinder center —
        /// for every turnpoint type. There is no flag pole and no
        /// asymmetric ornament; any extra decoration would shift the
        /// geometric center and break the alignment.
        ///
        /// Color-coded by type:
        ///   takeoff = green, SSS = cyan, turn = blue,
        ///   ESS = orange, goal = red.
        ///
        /// Layout: 24×24 canvas, disc bounds (2, 2, 20, 20) → disc
        /// center (12, 12) == image center (12, 12).
        static func turnpointImage(type: TurnpointType, index: Int) -> UIImage {
            let color: UIColor
            switch type {
            case .takeoff: color = UIColor(red: 0.35, green: 0.85, blue: 0.40, alpha: 1)
            case .sss:     color = UIColor(red: 0.35, green: 0.80, blue: 1.00, alpha: 1)
            case .turn:    color = UIColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1)
            case .ess:     color = UIColor(red: 1.00, green: 0.65, blue: 0.30, alpha: 1)
            case .goal:    color = UIColor(red: 1.00, green: 0.35, blue: 0.35, alpha: 1)
            }
            let size = CGSize(width: 24, height: 24)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                let discRect = CGRect(x: 2, y: 2, width: 20, height: 20)
                // Filled colored disc.
                c.setFillColor(color.cgColor)
                c.fillEllipse(in: discRect)
                // White outline for contrast over satellite imagery.
                c.setStrokeColor(UIColor.white.cgColor)
                c.setLineWidth(2)
                c.strokeEllipse(in: discRect)
                // Index number, centered on the disc at (12, 12).
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 12, weight: .heavy),
                    .foregroundColor: UIColor.white,
                ]
                let str = NSAttributedString(string: "\(index)", attributes: attrs)
                let strSize = str.size()
                str.draw(at: CGPoint(x: 12 - strSize.width/2,
                                     y: 12 - strSize.height/2))
            }
        }
    }
}

final class PilotAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D = CLLocationCoordinate2D()
}

final class ThermalAnnotation: NSObject, MKAnnotation {
    let id: UUID
    let thermal: ThermalPoint
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { String(format: "Termik %+.1f m/s", thermal.strength) }
    var subtitle: String? { String(format: "%.0f m", thermal.altitude) }
    init(thermal: ThermalPoint) {
        self.id = thermal.id
        self.thermal = thermal
        self.coordinate = thermal.coordinate
    }
}

/// MapKit polygon overlay for the FAI triangle. Three turnpoints connected
/// as a closed polygon, drawn with a colored stroke and translucent fill.
final class TriangleOverlay: NSObject, MKOverlay {
    let triangle: FAITriangle
    let polygon: MKPolygon

    var coordinate: CLLocationCoordinate2D { polygon.coordinate }
    var boundingMapRect: MKMapRect { polygon.boundingMapRect }

    init(triangle: FAITriangle) {
        self.triangle = triangle
        var coords = [triangle.tp1, triangle.tp2, triangle.tp3]
        self.polygon = MKPolygon(coordinates: &coords, count: 3)
        super.init()
    }
}

/// Renderer for the triangle overlay — color reflects closed (green) vs
/// open (amber) status.
final class TriangleOverlayRenderer: MKPolygonRenderer {
    init(triangleOverlay: TriangleOverlay) {
        super.init(polygon: triangleOverlay.polygon)
        let isClosed = triangleOverlay.triangle.isClosed
        let stroke = isClosed
            ? UIColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)
            : UIColor(red: 1.0,  green: 0.80, blue: 0.30, alpha: 1.0)
        strokeColor = stroke
        fillColor = stroke.withAlphaComponent(0.10)
        // Slimmer stroke than before (was 2.5) — the FAI triangle is
        // a fairly large polygon spanning the map, a 2.5pt edge ends
        // up reading as a heavy yellow band that competes with the
        // pilot trail and city labels.
        lineWidth = 1.8
        lineDashPattern = isClosed ? nil : [8, 6]
    }
}

/// MapKit polygon overlay for the PROVISIONAL "currently flying"
/// triangle. Always drawn dashed amber — this overlay only exists to
/// show the pilot the shape they're flying right now, not to claim
/// FAI validity. When a real FAI-validated triangle also exists, that
/// other (green/solid) overlay is drawn on top of this one.
final class ProvisionalTriangleOverlay: NSObject, MKOverlay {
    let triangle: FAITriangle
    let polygon: MKPolygon

    var coordinate: CLLocationCoordinate2D { polygon.coordinate }
    var boundingMapRect: MKMapRect { polygon.boundingMapRect }

    init(triangle: FAITriangle) {
        self.triangle = triangle
        var coords = [triangle.tp1, triangle.tp2, triangle.tp3]
        self.polygon = MKPolygon(coordinates: &coords, count: 3)
        super.init()
    }
}

/// Renderer for the provisional triangle. Drawn in a different color
/// from the validated FAI triangle (cyan vs amber) so the two never
/// get visually confused when the validated one appears alongside the
/// provisional one at the same instant. Also slimmer and more
/// translucent — this overlay is a "hint" of the current shape, not
/// a primary scoring readout, so it shouldn't compete visually with
/// the validated triangle once that exists.
final class ProvisionalTriangleOverlayRenderer: MKPolygonRenderer {
    init(provisionalOverlay: ProvisionalTriangleOverlay) {
        super.init(polygon: provisionalOverlay.polygon)
        // Cyan tone — matches the cyan accents used elsewhere in the
        // app (north markers, pilot heading triangle in WindDial),
        // signalling "live / current" rather than "scored".
        let cyan = UIColor(red: 0.45, green: 0.85, blue: 1.0, alpha: 1.0)
        strokeColor = cyan.withAlphaComponent(0.65)
        fillColor   = cyan.withAlphaComponent(0.05)
        lineWidth = 1.4
        lineDashPattern = [6, 5]
    }
}

/// Overlay that draws a directional arrow from the pilot's current
/// position toward the flight start, to guide the pilot back to close
/// the FAI triangle. Only shown while the triangle is open.
final class ClosingArrowOverlay: NSObject, MKOverlay {
    let fromCoord: CLLocationCoordinate2D
    let toCoord: CLLocationCoordinate2D
    let _boundingMapRect: MKMapRect

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude:  (fromCoord.latitude  + toCoord.latitude)  / 2,
            longitude: (fromCoord.longitude + toCoord.longitude) / 2
        )
    }
    var boundingMapRect: MKMapRect { _boundingMapRect }

    init(from: CLLocationCoordinate2D, to: CLLocationCoordinate2D) {
        self.fromCoord = from
        self.toCoord = to
        // Bounding rect that includes both endpoints with some padding
        let p1 = MKMapPoint(from)
        let p2 = MKMapPoint(to)
        let minX = min(p1.x, p2.x), maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y), maxY = max(p1.y, p2.y)
        let pad = max(maxX - minX, maxY - minY) * 0.3 + 1000
        self._boundingMapRect = MKMapRect(x: minX - pad, y: minY - pad,
                                          width: (maxX - minX) + 2 * pad,
                                          height: (maxY - minY) + 2 * pad)
        super.init()
    }
}

/// Custom renderer that draws a bold dashed line from pilot to flight
/// start, with a large "home" target marker at the destination. Bright
/// green with black outline for maximum visibility over satellite imagery.
final class ClosingArrowRenderer: MKOverlayRenderer {
    let arrow: ClosingArrowOverlay

    init(arrowOverlay: ClosingArrowOverlay) {
        self.arrow = arrowOverlay
        super.init(overlay: arrowOverlay)
    }

    override func draw(_ mapRect: MKMapRect,
                       zoomScale: MKZoomScale,
                       in context: CGContext) {
        let fromMap = MKMapPoint(arrow.fromCoord)
        let toMap   = MKMapPoint(arrow.toCoord)
        let p1 = point(for: fromMap)
        let p2 = point(for: toMap)

        // Scale strokes so they render clearly at all zoom levels.
        let strokeWidth = max(4.0 / zoomScale, 3.5)
        let homeRadius = max(22.0 / zoomScale, 18.0)

        // Bright green (same as "closed triangle" color for consistency) +
        // subtle black outline so it pops over satellite imagery.
        let greenColor = UIColor(red: 0.35, green: 0.95, blue: 0.55, alpha: 1.0)

        // --- Dashed line from pilot to home ---
        context.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
        context.setLineWidth(strokeWidth + 2)
        context.setLineCap(.round)
        context.setLineDash(phase: 0,
                            lengths: [14 / zoomScale, 9 / zoomScale])
        context.move(to: p1)
        context.addLine(to: p2)
        context.strokePath()

        context.setStrokeColor(greenColor.cgColor)
        context.setLineWidth(strokeWidth)
        context.setLineDash(phase: 0,
                            lengths: [14 / zoomScale, 9 / zoomScale])
        context.move(to: p1)
        context.addLine(to: p2)
        context.strokePath()

        // --- Home target at destination ---
        // Outer ring (black outline)
        context.setFillColor(UIColor.black.withAlphaComponent(0.75).cgColor)
        context.fillEllipse(in: CGRect(
            x: p2.x - homeRadius * 1.15,
            y: p2.y - homeRadius * 1.15,
            width: homeRadius * 2.3,
            height: homeRadius * 2.3
        ))
        // Green outer ring
        context.setFillColor(greenColor.cgColor)
        context.fillEllipse(in: CGRect(
            x: p2.x - homeRadius,
            y: p2.y - homeRadius,
            width: homeRadius * 2,
            height: homeRadius * 2
        ))
        // White inner ring
        context.setFillColor(UIColor.white.cgColor)
        context.fillEllipse(in: CGRect(
            x: p2.x - homeRadius * 0.55,
            y: p2.y - homeRadius * 0.55,
            width: homeRadius * 1.1,
            height: homeRadius * 1.1
        ))
        // Green center dot
        context.setFillColor(greenColor.cgColor)
        context.fillEllipse(in: CGRect(
            x: p2.x - homeRadius * 0.25,
            y: p2.y - homeRadius * 0.25,
            width: homeRadius * 0.5,
            height: homeRadius * 0.5
        ))

        // --- Arrowhead just before the home marker, pointing from p1→p2 ---
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let len = max(sqrt(dx*dx + dy*dy), 0.001)
        let ux = dx / len
        let uy = dy / len
        // Place the arrowhead tip just outside the home circle
        let tipX = p2.x - ux * (homeRadius * 1.4)
        let tipY = p2.y - uy * (homeRadius * 1.4)
        let tip = CGPoint(x: tipX, y: tipY)
        // Perpendicular
        let px = -uy
        let py = ux
        let headSize = max(18.0 / zoomScale, 14.0)
        let base1 = CGPoint(
            x: tip.x - ux * headSize + px * headSize * 0.6,
            y: tip.y - uy * headSize + py * headSize * 0.6
        )
        let base2 = CGPoint(
            x: tip.x - ux * headSize - px * headSize * 0.6,
            y: tip.y - uy * headSize - py * headSize * 0.6
        )
        // Black outline
        context.setFillColor(UIColor.black.withAlphaComponent(0.7).cgColor)
        context.move(to: CGPoint(x: tip.x + ux * 3, y: tip.y + uy * 3))
        context.addLine(to: CGPoint(x: base1.x + px * 2, y: base1.y + py * 2))
        context.addLine(to: CGPoint(x: base2.x - px * 2, y: base2.y - py * 2))
        context.closePath()
        context.fillPath()
        // Green fill
        context.setFillColor(greenColor.cgColor)
        context.move(to: tip)
        context.addLine(to: base1)
        context.addLine(to: base2)
        context.closePath()
        context.fillPath()
    }
}

// MARK: - Competition task overlays

/// Flag-style annotation for a turnpoint. Shows the index and type-color.
final class TurnpointAnnotation: NSObject, MKAnnotation {
    let turnpoint: Turnpoint
    let index: Int
    dynamic var coordinate: CLLocationCoordinate2D
    var title: String? { "\(index). \(turnpoint.name)" }
    var subtitle: String? { turnpoint.summary }

    init(turnpoint: Turnpoint, index: Int) {
        self.turnpoint = turnpoint
        self.index = index
        self.coordinate = turnpoint.coordinate
    }
}

/// Blue translucent cylinder overlay around a turnpoint, showing the
/// valid radius the pilot must enter/exit. Styled after XCTrack / Flyskyhy.
final class TurnpointCylinderOverlay: NSObject, MKOverlay {
    let turnpoint: Turnpoint
    let circle: MKCircle

    var coordinate: CLLocationCoordinate2D { circle.coordinate }
    var boundingMapRect: MKMapRect { circle.boundingMapRect }

    init(turnpoint: Turnpoint) {
        self.turnpoint = turnpoint
        self.circle = MKCircle(center: turnpoint.coordinate,
                               radius: turnpoint.radiusM)
        super.init()
    }
}

/// Renderer for turnpoint cylinders: blue translucent fill + solid stroke.
/// Stroke color varies by type (start green, goal red, standard blue).
final class TurnpointCylinderRenderer: MKCircleRenderer {
    init(cylinderOverlay: TurnpointCylinderOverlay) {
        super.init(circle: cylinderOverlay.circle)
        let tp = cylinderOverlay.turnpoint
        let color: UIColor
        switch tp.type {
        case .takeoff: color = UIColor(red: 0.35, green: 0.85, blue: 0.40, alpha: 1)
        case .sss:     color = UIColor(red: 0.35, green: 0.80, blue: 1.00, alpha: 1)
        case .turn:    color = UIColor(red: 0.25, green: 0.55, blue: 1.00, alpha: 1)
        case .ess:     color = UIColor(red: 1.00, green: 0.65, blue: 0.30, alpha: 1)
        case .goal:    color = UIColor(red: 1.00, green: 0.35, blue: 0.35, alpha: 1)
        }
        fillColor = color.withAlphaComponent(0.18)
        strokeColor = color.withAlphaComponent(0.85)
        lineWidth = 2
        if tp.optional {
            lineDashPattern = [6, 4]
        }
    }
}

/// One leg of the task between two already-computed optimal points on
/// consecutive turnpoint cylinders. Drawn as a straight line from the
/// start point to the end point (both sit on cylinder edges), with an
/// arrowhead mid-segment showing the pilot's direction.
///
/// The caller computes `fromPoint` and `toPoint` via
/// `SatelliteMapView.optimalRoutePoints(for:)`, which iteratively solves
/// for the tangent points minimizing total task distance.
final class TaskRouteOverlay: NSObject, MKOverlay {
    let from: CLLocationCoordinate2D
    let to: CLLocationCoordinate2D

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (from.latitude + to.latitude) / 2,
            longitude: (from.longitude + to.longitude) / 2)
    }
    var boundingMapRect: MKMapRect {
        let pA = MKMapPoint(from)
        let pB = MKMapPoint(to)
        let minX = min(pA.x, pB.x)
        let minY = min(pA.y, pB.y)
        let w = abs(pA.x - pB.x)
        let h = abs(pA.y - pB.y)
        let pad = 2000.0
        return MKMapRect(x: minX - pad, y: minY - pad,
                          width: w + 2*pad, height: h + 2*pad)
    }

    init(fromPoint: CLLocationCoordinate2D, toPoint: CLLocationCoordinate2D) {
        self.from = fromPoint
        self.to = toPoint
        super.init()
    }
}

/// Custom renderer: draws a thin line from source center to target center
/// (using MapKit's projected coordinates so it follows screen geometry),
/// then a filled arrowhead near the target cylinder boundary.
///
/// The line is intentionally thin (1.5px) because competition maps often
/// have many overlapping elements; arrowheads convey direction without
/// needing a thick line.
final class TaskLegRenderer: MKOverlayRenderer {
    let leg: TaskRouteOverlay

    init(leg: TaskRouteOverlay) {
        self.leg = leg
        super.init(overlay: leg)
    }

    override func draw(_ mapRect: MKMapRect,
                       zoomScale: MKZoomScale,
                       in context: CGContext) {
        let pFrom = point(for: MKMapPoint(leg.from))
        let pTo = point(for: MKMapPoint(leg.to))

        // Line width scales with zoom so it stays readable when zoomed out.
        // Bumped from 3.5 to 5.0 base so the optimum route reads clearly
        // against both terrain and open sky in the satellite view.
        let lineWidth = max(4.5 / zoomScale, 5.0)

        // Lighter, more saturated blue than the old navy. Picks up well
        // against green terrain and dark areas while still feeling
        // "route-like" (compare: Google Maps route blue, Flyskyhy cyan).
        let color = UIColor(red: 0.20, green: 0.55, blue: 1.00, alpha: 1.0).cgColor

        // Draw line: center-to-center
        context.setStrokeColor(color)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.move(to: pFrom)
        context.addLine(to: pTo)
        context.strokePath()

        // Arrowhead in the middle of the leg (segment connects two cylinder
        // edge points now, so midpoint sits cleanly between them).
        let dxMap = leg.to.longitude - leg.from.longitude
        let dyMap = leg.to.latitude - leg.from.latitude
        let lenMeters = distanceMeters(leg.from, leg.to)
        guard lenMeters > 0 else { return }

        let t: Double = 0.5
        let arrowLat = leg.from.latitude + dyMap * t
        let arrowLon = leg.from.longitude + dxMap * t
        let pArrow = point(for: MKMapPoint(
            CLLocationCoordinate2D(latitude: arrowLat, longitude: arrowLon)))

        // Arrow direction = screen bearing from pFrom to pTo
        let dx = pTo.x - pFrom.x
        let dy = pTo.y - pFrom.y
        let angle = atan2(dy, dx)

        // Arrowhead size scales with line width so it stays proportional.
        // Ratio tuned so the head looks balanced against the thicker line.
        let headLen = lineWidth * 4.0
        let headHalfWidth = lineWidth * 2.2

        // Tip is at pArrow; base is behind it along the line
        let tip = pArrow
        let backX = tip.x - cos(angle) * headLen
        let backY = tip.y - sin(angle) * headLen
        // Perpendicular (left/right from the back point)
        let perpX = -sin(angle) * headHalfWidth
        let perpY = cos(angle) * headHalfWidth
        let leftX = backX + perpX
        let leftY = backY + perpY
        let rightX = backX - perpX
        let rightY = backY - perpY

        context.setFillColor(color)
        context.move(to: tip)
        context.addLine(to: CGPoint(x: leftX, y: leftY))
        context.addLine(to: CGPoint(x: rightX, y: rightY))
        context.closePath()
        context.fillPath()
    }

    private func distanceMeters(_ a: CLLocationCoordinate2D,
                                _ b: CLLocationCoordinate2D) -> Double {
        let R = 6371000.0
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat/2) * sin(dLat/2) +
                cos(lat1) * cos(lat2) * sin(dLon/2) * sin(dLon/2)
        return 2 * R * asin(min(1, sqrt(h)))
    }
}
