import SwiftUI
import CoreLocation

// MARK: - Location manager (Phase 7)

@Observable
final class LiveLocationManager: NSObject, CLLocationManagerDelegate {
    private let clManager = CLLocationManager()
    var currentLocation: CLLocationCoordinate2D?
    var authStatus: CLAuthorizationStatus = .notDetermined

    override init() {
        super.init()
        clManager.delegate = self
        clManager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    func requestWhenInUse() { clManager.requestWhenInUseAuthorization() }
    func start() { clManager.startUpdatingLocation() }
    func stop()  { clManager.stopUpdatingLocation() }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        currentLocation = locs.last?.coordinate
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authStatus = manager.authorizationStatus
        if authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways { start() }
    }
}

// MARK: - Banner view

/// Shows a coloured strip at the bottom of the map with the current risk band.
/// Wire into MapScreen as: `.safeAreaInset(edge: .bottom) { LocationBannerView(locationManager: liveManager) }`
/// where `liveManager` is a `@State private var liveManager = LiveLocationManager()` on MapScreen.
struct LocationBannerView: View {
    @Environment(AppModel.self) private var app
    let locationManager: LiveLocationManager

    @State private var lastAlertTime: Date = .distantPast
    @State private var lastAlertBand: DVCRiskBand = .low

    private var currentRisk: DVCRiskComponents? {
        guard let loc = locationManager.currentLocation else { return nil }
        return app.engine.risk(at: loc, date: .now)
    }

    private var currentBand: DVCRiskBand? {
        guard let r = currentRisk else { return nil }
        return app.engine.band(for: r)
    }

    var body: some View {
        if let band = currentBand, let risk = currentRisk, risk.covered {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(band.label) deer risk near you")
                        .font(.subheadline).fontWeight(.semibold)
                    Text("Season ×\(risk.seasonFactor, specifier: "%.1f")  ·  Dusk ×\(risk.diurnalFactor, specifier: "%.1f")")
                        .font(.caption).opacity(0.85)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RiskPalette.color(for: band))
            .foregroundStyle(.white)
            .onChange(of: currentBand) { old, new in
                guard let new, let old else { return }
                let now = Date()
                // Alert only when band increases, route is active, and debounce > 90 s
                if new.rawValue > old.rawValue,
                   app.route != nil,
                   now.timeIntervalSince(lastAlertTime) > 90 {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    lastAlertTime = now
                    lastAlertBand = new
                }
            }
        }
    }
}
