import SwiftUI
import MapKit
import CoreLocation

struct SatelliteMapView: UIViewRepresentable {
    let coordinate: CLLocationCoordinate2D?
    let heading: Double
    let thermals: [ThermalPoint]
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
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var parent: SatelliteMapView?
        var pilotAnnotation: PilotAnnotation?
        var lastCenter: CLLocationCoordinate2D?
        var lastAutoFollow: Bool = true
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
