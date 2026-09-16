import Foundation
import CoreLocation
import MapKit

// MARK: - Routing methods
extension AppModel {

    func buildRoute(to dest: CLLocationCoordinate2D, from origin: CLLocationCoordinate2D) async {
        isRouting = true
        routeError = nil
        defer { isRouting = false }

        let req = MKDirections.Request()
        req.source = MKMapItem(placemark: .init(coordinate: origin))
        req.destination = MKMapItem(placemark: .init(coordinate: dest))
        req.transportType = .automobile

        guard let mkRoute = try? await MKDirections(request: req).calculate().routes.first else {
            routeError = "No route found."
            return
        }
        route = mkRoute
        rescoreRoute()
        recomputeDepartureOptions()
    }

    func rescoreRoute() {
        guard let route else { return }
        let departure = Date().addingTimeInterval(departureOffset)
        routeScored = engine.scoreRoute(
            route.polyline.coordinates(),
            departure: departure,
            expectedTravelTime: route.expectedTravelTime)
        hotspots = engine.hotspots(routeScored, minBand: .high, limit: 3)
    }

    func clearRoute() {
        route = nil
        routeScored = []
        hotspots = []
        routeError = nil
        resetDepartureOptions()
        stopSimulation()
    }
}
