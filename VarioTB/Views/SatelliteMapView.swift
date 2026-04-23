import SwiftUI
import MapKit
import CoreLocation

struct SatelliteMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let heading: Double
    let thermals: [ThermalPoint]
    let triangle: FAITriangle?
    let flightStart: CLLocationCoordinate2D?   // for closing arrow
    /// Changes to this UUID trigger a one-time "zoom to fit the whole
    /// triangle" animation. Set to nil to skip. Used when the user taps
    /// the FAI HUD card.
    let fitTriangleToken: UUID?
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

        // Detect user-initiated pan so we can disable auto-follow.
        // We attach a pan gesture recognizer that doesn't cancel Map's own,
        // it just observes.
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

        if let c = coordinate {
            // Auto-follow only if enabled and pilot has moved meaningfully
            if autoFollow {
                let needsInitialCenter = context.coordinator.lastCenter == nil || followJustTurnedOn
                let movedEnough: Bool = {
                    guard let last = context.coordinator.lastCenter else { return true }
                    let a = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    let b = CLLocation(latitude: c.latitude, longitude: c.longitude)
                    return a.distance(from: b) > 80   // only re-center after 80m drift
                }()

                if needsInitialCenter || movedEnough {
                    context.coordinator.programmaticChange = true
                    if context.coordinator.lastCenter == nil {
                        let span = MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                        mv.setRegion(MKCoordinateRegion(center: c, span: span), animated: false)
                    } else {
                        // Preserve current zoom — just re-center
                        mv.setCenter(c, animated: true)
                    }
                    context.coordinator.lastCenter = c
                }
            }

            // Pilot annotation always updates position (regardless of follow state)
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

        // Sync FAI triangle overlay.
        for overlay in mv.overlays where overlay is TriangleOverlay {
            mv.removeOverlay(overlay)
        }
        if let tri = triangle {
            let ov = TriangleOverlay(triangle: tri)
            mv.addOverlay(ov)
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SatelliteMapView?
        var pilotAnnotation: PilotAnnotation?
        var lastCenter: CLLocationCoordinate2D?
        var lastAutoFollow: Bool = true
        /// Remembers the last fit-triangle token we handled, so we only
        /// animate the region change when the token actually changes.
        var lastFitToken: UUID?
        // When we programmatically re-center the map, the regionWillChange
        // callback fires too. This flag tells us to ignore it so we don't
        // accidentally turn off auto-follow.
        var programmaticChange = false

        // MARK: - Gesture handling (observe-only)

        @objc func userPanned(_ g: UIPanGestureRecognizer) {
            // As soon as the user starts panning the map, turn off auto-follow
            if g.state == .began {
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
                return view
            }
            return nil
        }

        /// Render FAI triangle overlay and closing arrow.
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tri = overlay as? TriangleOverlay {
                return TriangleOverlayRenderer(triangleOverlay: tri)
            }
            if let arrow = overlay as? ClosingArrowOverlay {
                return ClosingArrowRenderer(arrowOverlay: arrow)
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        static let pilotImage: UIImage = {
            let size = CGSize(width: 22, height: 22)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let c = ctx.cgContext
                c.setFillColor(UIColor.cyan.cgColor)
                c.fillEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
                c.setStrokeColor(UIColor.white.cgColor)
                c.setLineWidth(2)
                c.strokeEllipse(in: CGRect(x: 4, y: 4, width: 14, height: 14))
            }
        }()

        static func thermalImage(strength: Double) -> UIImage {
            // Blue gradient scale — strong cyan to deep indigo
            let color: UIColor
            if strength >= 3.0 { color = UIColor(red: 0.40, green: 0.90, blue: 1.00, alpha: 1) }
            else if strength >= 2.0 { color = UIColor(red: 0.45, green: 0.70, blue: 1.00, alpha: 1) }
            else if strength >= 1.0 { color = UIColor(red: 0.55, green: 0.60, blue: 0.95, alpha: 1) }
            else { color = UIColor(red: 0.60, green: 0.65, blue: 0.85, alpha: 1) }
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
        fillColor = stroke.withAlphaComponent(0.12)
        lineWidth = 2.5
        lineDashPattern = isClosed ? nil : [8, 6]   // dashed when not yet closed
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
