import Foundation
import CoreLocation
import MapKit

@Observable
final class AppModel {
    let engine: DVCRiskModel
    var loadError: String?
    var selectedTab: Int = 0
    var selectedStateName: String = "Iowa"

    // Phase 4: Route state
    var route: MKRoute?
    var routeScored: [DVCRoutePointRisk] = []
    var hotspots: [DVCRoutePointRisk] = []
    var departureOffset: TimeInterval = 0   // 0 = now, 3600 = +1h, 10800 = +3h
    var isRouting: Bool = false
    var routeError: String?

    // Phase 6: Map display
    var heatmapStyle: HeatmapStyle = .smooth

    // Zoom controls
    var zoomInCount: Int = 0
    var zoomOutCount: Int = 0

    init() {
        do { engine = try DVCRiskModel(bundle: .main) }
        catch { fatalError("Failed to load model_export: \(error)") }
    }
}
