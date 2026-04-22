import Foundation
import CoreLocation

struct ThermalPoint: Identifiable, Equatable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
    let altitude: Double        // m
    let strength: Double        // m/s average climb
    let timestamp: Date

    static func == (lhs: ThermalPoint, rhs: ThermalPoint) -> Bool {
        lhs.id == rhs.id
    }
}
