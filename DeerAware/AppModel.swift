import Foundation
import CoreLocation
import MapKit

/// One candidate departure time, scored end-to-end against the active route.
/// Populated by `AppModel.recomputeDepartureOptions()` (see `AppModel+Routing.swift`)
/// by re-scoring the same route at several offsets between now and +6h.
struct DepartureOption: Identifiable {
    let id = UUID()
    let offset: TimeInterval        // seconds from now, 0...21600 (0...6h)
    let date: Date
    let overallBand: DVCRiskBand    // worst band any sampled point hits at this departure
    let severeCount: Int
    let highCount: Int
    let meanRisk: Double

    var isNow: Bool { offset == 0 }
}

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

    // Departure advisor: risk for the active route at several offsets over the
    // next 6 hours, so the UI can tell the driver whether now is the best time to leave.
    var departureOptions: [DepartureOption] = []
    var isComputingDepartureOptions: Bool = false
    /// Offset (seconds from now) with the lowest risk among `departureOptions`, once computed.
    var recommendedDepartureOffset: TimeInterval?

    // Trip simulation: a sped-up playback of the active route, driven by a
    // timer in `AppModel+Simulation.swift`. The map/UI observe these to draw a
    // moving marker and surface direction-aware alerts as simulated high/severe
    // segments are approached.
    var isSimulating: Bool = false
    var simulationProgress: Double = 0                    // 0...1 along the route
    var simulatedCoordinate: CLLocationCoordinate2D?
    var simulatedHeading: CLLocationDirection = 0
    var activeSimulationAlert: DVCRoutePointRisk?

    // Navigation started: hides the search island, shows only the route
    var isNavigating: Bool = false


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
