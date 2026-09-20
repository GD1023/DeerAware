import SwiftUI
import CoreLocation

/// Transient top-of-screen banner for direction-aware simulation alerts —
/// same colour-strip styling as `LocationBannerView`, shown while
/// `app.activeSimulationAlert` is non-nil.
struct SimulationAlertBanner: View {
    @Environment(AppModel.self) private var app

    private var distanceAheadText: String? {
        guard let here = app.simulatedCoordinate, let alert = app.activeSimulationAlert else { return nil }
        let a = CLLocation(latitude: here.latitude, longitude: here.longitude)
        let b = CLLocation(latitude: alert.coordinate.latitude, longitude: alert.coordinate.longitude)
        let miles = a.distance(from: b) / 1609.34
        return String(format: "%.1f mi", miles)
    }

    var body: some View {
        if let alert = app.activeSimulationAlert {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(alert.band.label) deer risk ahead")
                        .font(.subheadline).fontWeight(.semibold)
                    if let distance = distanceAheadText {
                        Text("\(distance) ahead on the simulated route")
                            .font(.caption).opacity(0.85)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(RiskPalette.color(for: alert.band))
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .transition(.move(edge: .top).combined(with: .opacity))
            .animation(.easeInOut(duration: 0.25), value: app.activeSimulationAlert == nil)
        }
    }
}
