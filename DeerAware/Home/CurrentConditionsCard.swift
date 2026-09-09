import SwiftUI
import CoreLocation
import Combine

// MARK: - Location helper (private to this file)

@Observable
private final class LocationProvider: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var location: CLLocationCoordinate2D?
    var status: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestIfNeeded() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        location = locs.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        status = manager.authorizationStatus
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            manager.requestLocation()
        }
    }
}

// MARK: - Card

struct CurrentConditionsCard: View {
    @Environment(AppModel.self) private var appModel
    @State private var locationProvider = LocationProvider()
    // Dummy state to trigger re-render on timer tick
    @State private var tick = Date()

    private var riskComponents: DVCRiskComponents? {
        guard let loc = locationProvider.location else { return nil }
        _ = tick   // subscribe to timer-driven updates
        return appModel.engine.risk(at: loc, date: .now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Current Conditions", systemImage: "location.circle")
                .font(.headline)
            conditionContent
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
        .onAppear { locationProvider.requestIfNeeded() }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            tick = date
            locationProvider.requestIfNeeded()
        }
    }

    @ViewBuilder
    private var conditionContent: some View {
        switch locationProvider.status {
        case .denied, .restricted:
            Text("Enable location to see current conditions.")
                .font(.subheadline).foregroundStyle(.secondary)
        default:
            if let r = riskComponents {
                if r.covered {
                    HStack(spacing: 12) {
                        MultiplierChip(label: "Season", value: r.seasonFactor)
                        MultiplierChip(label: "Dusk", value: r.diurnalFactor)
                        Spacer()
                    }
                    Text(verdict(season: r.seasonFactor, diurnal: r.diurnalFactor))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Not in a covered state.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text("Determining location…")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func verdict(season: Double, diurnal: Double) -> String {
        if season > 1.5 && diurnal > 1.5 { return "Elevated — dusk in peak season" }
        if season > 1.5 { return "Elevated — peak deer season" }
        if diurnal > 1.5 { return "Elevated — near dusk" }
        return "Normal conditions"
    }
}

// MARK: - Chip

private struct MultiplierChip: View {
    let label: String
    let value: Double

    private var chipColor: Color {
        if value > 1.8 { return .red }
        if value > 1.2 { return .orange }
        return .green
    }

    var body: some View {
        VStack(spacing: 2) {
            Text("×\(value, specifier: "%.1f")")
                .font(.headline).fontWeight(.bold)
                .foregroundStyle(chipColor)
            Text(label)
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipColor.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
