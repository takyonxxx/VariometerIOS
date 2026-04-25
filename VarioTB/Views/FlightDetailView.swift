import SwiftUI
import MapKit

/// Detail screen pushed from FilesListView when the user taps a row.
/// Parses the IGC file on appear and shows a structured summary:
/// header info (pilot/glider/manufacturer), timing, altitude envelope,
/// distance/speed metrics, and a small bounding-box map preview of
/// the track. Designed to give the pilot enough at-a-glance context
/// to decide whether to share / re-upload / delete a file without
/// opening it in another app.
struct FlightDetailView: View {
    let url: URL
    @ObservedObject private var language = LanguagePreference.shared

    @State private var summary: IGCFlightSummary? = nil
    @State private var isLoading: Bool = true

    var body: some View {
        let _ = language.code  // re-render on language toggle
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                } else if let s = summary {
                    headerCard(s)
                    if s.bbox != nil {
                        mapCard(s)
                    }
                    timingCard(s)
                    altitudeCard(s)
                    distanceCard(s)
                    pilotCard(s)
                    deviceCard(s)
                } else {
                    Text(L10n.string("flight_parse_error"))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                }
            }
            .padding(16)
        }
        .navigationTitle(url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Parse off-main so a 6-hour flight (~21k B-records) doesn't
            // freeze the UI while the screen pushes in.
            DispatchQueue.global(qos: .userInitiated).async {
                let result = IGCFlightSummary.parse(url: url)
                DispatchQueue.main.async {
                    self.summary = result
                    self.isLoading = false
                }
            }
        }
    }

    // MARK: - Cards

    private func headerCard(_ s: IGCFlightSummary) -> some View {
        // Big top card: flight date + duration + simulated badge
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: s.isSimulated ? "play.tv.fill" : "airplane")
                    .foregroundColor(s.isSimulated ? .orange : .cyan)
                    .font(.system(size: 22))
                VStack(alignment: .leading) {
                    Text(formattedDate(s.flightDate ?? s.firstFixTime))
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                    Text(formattedDuration(s.duration))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if s.isSimulated {
                    Text("SIM")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundColor(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func mapCard(_ s: IGCFlightSummary) -> some View {
        // Mini map showing the bounding box of the track. Doesn't draw
        // the full polyline (we'd need to keep all fixes for that — a
        // future improvement); instead drops a centered region marker
        // so the pilot can recognise where the flight happened.
        Group {
            if let bb = s.bbox {
                let center = CLLocationCoordinate2D(
                    latitude: (bb.minLat + bb.maxLat) / 2,
                    longitude: (bb.minLon + bb.maxLon) / 2)
                // Span padded a bit so the bbox isn't flush to edges
                let span = MKCoordinateSpan(
                    latitudeDelta: max(0.01, (bb.maxLat - bb.minLat) * 1.4),
                    longitudeDelta: max(0.01, (bb.maxLon - bb.minLon) * 1.4))
                Map(initialPosition: .region(
                    MKCoordinateRegion(center: center, span: span)))
                {
                    Marker(coordinate: center) {
                        Image(systemName: "mappin.circle.fill")
                    }
                }
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func timingCard(_ s: IGCFlightSummary) -> some View {
        sectionCard(title: L10n.string("flight_timing")) {
            row(L10n.string("flight_start"),
                formattedTime(s.firstFixTime))
            row(L10n.string("flight_end"),
                formattedTime(s.lastFixTime))
            row(L10n.string("flight_duration"),
                formattedDuration(s.duration))
            row(L10n.string("flight_fixes"),
                "\(s.fixCount)")
        }
    }

    private func altitudeCard(_ s: IGCFlightSummary) -> some View {
        sectionCard(title: L10n.string("flight_altitude")) {
            // Prefer GPS altitude (more reliable across devices) but
            // fall back to pressure altitude if GPS field was zero.
            let useGps = s.gpsAltMax > 0
            let mn = useGps ? s.gpsAltMin : s.pressureAltMin
            let mx = useGps ? s.gpsAltMax : s.pressureAltMax
            let label = useGps ? "GPS" : "Press"
            row("\(L10n.string("flight_alt_min")) (\(label))", "\(mn) m")
            row("\(L10n.string("flight_alt_max")) (\(label))", "\(mx) m")
            row(L10n.string("flight_alt_gain"),
                "\(max(0, mx - mn)) m")
            row(L10n.string("flight_total_climb"),
                "\(s.totalClimbM) m")
            row(L10n.string("flight_best_climb"),
                String(format: "%+.1f m/s", s.bestClimbRateMps))
        }
    }

    private func distanceCard(_ s: IGCFlightSummary) -> some View {
        sectionCard(title: L10n.string("flight_distance")) {
            row(L10n.string("flight_straight_line"),
                String(format: "%.1f km", s.straightLineDistanceKm))
            row(L10n.string("flight_total_track"),
                String(format: "%.1f km", s.totalTrackDistanceKm))
            row(L10n.string("flight_max_speed"),
                String(format: "%.0f km/h", s.maxGroundSpeedKmh))
            row(L10n.string("flight_avg_speed"),
                String(format: "%.0f km/h", s.avgGroundSpeedKmh))
        }
    }

    private func pilotCard(_ s: IGCFlightSummary) -> some View {
        sectionCard(title: L10n.string("pilot_info")) {
            if !s.pilotName.isEmpty {
                row(L10n.string("flight_pilot"), s.pilotName)
            }
            if !s.civlID.isEmpty {
                row(L10n.string("civl_id"), s.civlID)
            }
            if !s.gliderType.isEmpty {
                row(L10n.string("flight_glider"), s.gliderType)
            }
            if !s.gliderID.isEmpty, s.gliderID != s.gliderType {
                row(L10n.string("flight_glider_id"), s.gliderID)
            }
        }
    }

    private func deviceCard(_ s: IGCFlightSummary) -> some View {
        sectionCard(title: L10n.string("flight_device")) {
            row(L10n.string("flight_manufacturer"),
                s.manufacturerCode.isEmpty ? "—" : s.manufacturerCode)
            if !s.firmware.isEmpty {
                row(L10n.string("flight_firmware"), s.firmware)
            }
            if !s.hardware.isEmpty {
                row(L10n.string("flight_hardware"), s.hardware)
            }
        }
    }

    // MARK: - Building blocks

    @ViewBuilder
    private func sectionCard<Content: View>(title: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundColor(.secondary)
                .tracking(0.5)
            VStack(spacing: 6) {
                content()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(card)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundColor(.primary)
                .multilineTextAlignment(.trailing)
        }
    }

    private var card: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color(.secondarySystemBackground))
    }

    // MARK: - Formatting

    private func formattedDate(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy"
        f.timeZone = TimeZone.current
        return f.string(from: d)
    }

    private func formattedTime(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: d) + " UTC"
    }

    private func formattedDuration(_ s: TimeInterval) -> String {
        let total = Int(s)
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, sec)
        }
        return String(format: "%dm %02ds", m, sec)
    }
}
