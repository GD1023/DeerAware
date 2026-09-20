import SwiftUI
import MapKit

// MARK: - Simulation vehicle annotation

/// Marker for the sped-up trip playback driven by `AppModel+Simulation.swift`.
/// `coordinate` is `@objc dynamic` so mutating it in place (rather than
/// remove/re-add) lets MapKit animate the marker smoothly between ticks.
final class SimulationVehicleAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D
    var heading: CLLocationDirection
    var band: DVCRiskBand

    init(coordinate: CLLocationCoordinate2D, heading: CLLocationDirection, band: DVCRiskBand) {
        self.coordinate = coordinate
        self.heading = heading
        self.band = band
        super.init()
    }
}

private func makeSimulationAnnotationView(for annotation: SimulationVehicleAnnotation,
                                           mapView: MKMapView) -> MKAnnotationView {
    let reuseID = "simulationVehicle"
    let view = mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
               ?? MKAnnotationView(annotation: annotation, reuseIdentifier: reuseID)
    view.annotation = annotation
    let symbolConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
    view.image = UIImage(systemName: "location.north.fill", withConfiguration: symbolConfig)?
        .withRenderingMode(.alwaysTemplate)
    view.tintColor = RiskPalette.uiColor(for: annotation.band)
    view.transform = CGAffineTransform(rotationAngle: annotation.heading * .pi / 180)
    view.centerOffset = .zero
    view.canShowCallout = false
    return view
}

struct RiskMapView: UIViewRepresentable {
    @Environment(AppModel.self) private var app

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MKMapView {
        let mv = MKMapView()
        mv.delegate = context.coordinator
        mv.showsUserLocation = true
        mv.pointOfInterestFilter = .excludingAll
        mv.overrideUserInterfaceStyle = .dark
        return mv
    }

    func updateUIView(_ mv: MKMapView, context: Context) {
        context.coordinator.sync(mv, app: app)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, MKMapViewDelegate {
        private var shownState: String?
        private var shownStyle: HeatmapStyle = .smooth
        private var imageCache: [String: [HeatmapStyle: CGImage]] = [:]
        private var drawnRouteID: ObjectIdentifier?
        private var startAnnotation: RouteEndpointAnnotation?
        private var endAnnotation: RouteEndpointAnnotation?
        private var lastZoomIn = 0
        private var lastZoomOut = 0
        private var simulationAnnotation: SimulationVehicleAnnotation?
        private var shownRouteActive: Bool = false
        private var lastIsNavigating = false
        private var lastIsSimulating = false
        private var lastHadRoute = false
        private var fixedHeading: CLLocationDirection = 0
        weak var appModel: AppModel?

        func sync(_ mv: MKMapView, app: AppModel) {
            appModel = app
            syncHeatmap(mv, app: app)
            syncRoute(mv, app: app)
            syncZoom(mv, app: app)
            syncSimulation(mv, app: app)
            syncCamera(mv, app: app)
        }

        // MARK: Camera

        private func syncCamera(_ mv: MKMapView, app: AppModel) {
            // Orient map when navigation starts: start at bottom, end at top
            if app.isNavigating && !lastIsNavigating {
                lastIsNavigating = true
                orientForNavigation(mv, app: app)
            } else if !app.isNavigating {
                lastIsNavigating = false
            }

            // Lock heading to start→end bearing when simulation begins
            if app.isSimulating && !lastIsSimulating {
                fixedHeading = routeHeading(app: app)
            }

            // Follow the simulation arrow while simulating — heading stays fixed
            if app.isSimulating, let coord = app.simulatedCoordinate {
                let camera = MKMapCamera(lookingAtCenter: coord,
                                         fromDistance: 250000,
                                         pitch: 0,
                                         heading: fixedHeading)
                mv.setCamera(camera, animated: false)
            }

            // When simulation stops, restore the full route view
            if !app.isSimulating && lastIsSimulating, let route = app.route {
                mv.setVisibleMapRect(route.polyline.boundingMapRect,
                                     edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 120, right: 20),
                                     animated: true)
            }
            lastIsSimulating = app.isSimulating

            // When route is cleared (Exit tapped), zoom out to state region
            let hasRoute = app.route != nil
            if !hasRoute && lastHadRoute,
               let info = app.engine.gridInfo(for: app.selectedStateName) {
                mv.setRegion(info.region, animated: true)
            }
            lastHadRoute = hasRoute
        }

        private func orientForNavigation(_ mv: MKMapView, app: AppModel) {
            guard let route = app.route else { return }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                  count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: coords.count))
            guard let first = coords.first, let last = coords.last else { return }

            // Bearing from start → end so the route runs bottom→top on screen
            let heading = routeBearing(from: first, to: last)
            fixedHeading = heading

            // Zoom in on the start position, headed in direction of travel
            let camera = MKMapCamera(lookingAtCenter: first,
                                      fromDistance: 8000,
                                      pitch: 0,
                                      heading: heading)
            mv.setCamera(camera, animated: true)
        }

        private func routeHeading(app: AppModel) -> CLLocationDirection {
            guard let route = app.route, route.polyline.pointCount >= 2 else { return fixedHeading }
            var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid,
                                                  count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: coords.count))
            return routeBearing(from: coords.first!, to: coords.last!)
        }

        private func routeBearing(from a: CLLocationCoordinate2D,
                                   to b: CLLocationCoordinate2D) -> CLLocationDirection {
            let lat1 = a.latitude * .pi / 180
            let lat2 = b.latitude * .pi / 180
            let dLon = (b.longitude - a.longitude) * .pi / 180
            let y = sin(dLon) * cos(lat2)
            let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
            return (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        }

        private func syncZoom(_ mv: MKMapView, app: AppModel) {
            if app.zoomInCount != lastZoomIn {
                lastZoomIn = app.zoomInCount
                let s = mv.region.span
                mv.setRegion(MKCoordinateRegion(
                    center: mv.region.center,
                    span: MKCoordinateSpan(latitudeDelta: s.latitudeDelta / 2,
                                          longitudeDelta: s.longitudeDelta / 2)),
                    animated: true)
            }
            if app.zoomOutCount != lastZoomOut {
                lastZoomOut = app.zoomOutCount
                let s = mv.region.span
                mv.setRegion(MKCoordinateRegion(
                    center: mv.region.center,
                    span: MKCoordinateSpan(latitudeDelta: min(s.latitudeDelta * 2, 90),
                                          longitudeDelta: min(s.longitudeDelta * 2, 180))),
                    animated: true)
            }
        }

        // MARK: Heatmap

        private func syncHeatmap(_ mv: MKMapView, app: AppModel) {
            let routeActive = app.route != nil
            let routeChanged = shownRouteActive != routeActive
            let stateChanged = shownState != app.selectedStateName
            let styleChanged = shownStyle != app.heatmapStyle

            // Hide heatmap while a route is displayed
            if routeActive {
                if routeChanged {
                    mv.removeOverlays(mv.overlays.filter { $0 is HeatmapOverlay })
                    shownRouteActive = true
                    shownState = app.selectedStateName
                    shownStyle = app.heatmapStyle
                }
                return
            }

            shownRouteActive = false

            guard stateChanged || styleChanged || routeChanged,
                  let info = app.engine.gridInfo(for: app.selectedStateName) else { return }

            shownState = app.selectedStateName
            shownStyle = app.heatmapStyle

            mv.removeOverlays(mv.overlays.filter { $0 is HeatmapOverlay })

            let cached = imageCache[info.name]?[app.heatmapStyle]
            let img = cached ?? makeHeatmapImage(info, engine: app.engine, style: app.heatmapStyle)
            if let img {
                imageCache[info.name, default: [:]][app.heatmapStyle] = img
                mv.addOverlay(HeatmapOverlay(info, image: img), level: .aboveRoads)
            }

            if stateChanged {
                mv.setRegion(info.region, animated: true)
            }
        }

        // MARK: Route + pins

        private func syncRoute(_ mv: MKMapView, app: AppModel) {
            // Use the MKRoute reference itself as the identity token — stable across ticks
            let newID = app.route.map { ObjectIdentifier($0) }

            guard newID != drawnRouteID else { return }
            drawnRouteID = newID

            // Remove old route polylines
            mv.removeOverlays(mv.overlays.filter { $0 is MKPolyline })
            // Remove old hotspot + endpoint annotations
            mv.removeAnnotations(mv.annotations.filter { $0 is HotspotAnnotation })
            if let s = startAnnotation { mv.removeAnnotation(s); startAnnotation = nil }
            if let e = endAnnotation   { mv.removeAnnotation(e); endAnnotation = nil }

            guard !app.routeScored.isEmpty, let route = app.route else { return }

            mv.addOverlays(app.engine.routeOverlays(app.routeScored), level: .aboveRoads)
            mv.addAnnotations(app.hotspots.map { HotspotAnnotation($0) })

            // Start / end pins
            var coords = [CLLocationCoordinate2D](
                repeating: kCLLocationCoordinate2DInvalid,
                count: route.polyline.pointCount)
            route.polyline.getCoordinates(&coords, range: NSRange(location: 0, length: coords.count))
            if let first = coords.first, let last = coords.last {
                let start = RouteEndpointAnnotation(coordinate: first, kind: .start)
                let end   = RouteEndpointAnnotation(coordinate: last,  kind: .end)
                startAnnotation = start
                endAnnotation   = end
                mv.addAnnotations([start, end])
            }

            mv.setVisibleMapRect(route.polyline.boundingMapRect,
                                 edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 120, right: 20),
                                 animated: true)
        }

        // MARK: Simulation marker

        /// Diffs against `simulationAnnotation` rather than removing/re-adding
        /// every tick (~30fps) — mutating the existing annotation's coordinate
        /// lets MapKit animate it in place, matching the pattern used by
        /// `syncHeatmap`/`syncRoute` above.
        private func syncSimulation(_ mv: MKMapView, app: AppModel) {
            // Show arrow at start position while navigating (before simulation plays)
            let showAtStart = app.isNavigating && !app.isSimulating && !app.routeScored.isEmpty
            guard app.isSimulating || showAtStart, let coord = showAtStart
                    ? app.routeScored.first?.coordinate
                    : app.simulatedCoordinate else {
                if let existing = simulationAnnotation {
                    mv.removeAnnotation(existing)
                    simulationAnnotation = nil
                }
                return
            }
            let heading: CLLocationDirection = showAtStart
                ? routeBearing(from: app.routeScored[0].coordinate,
                               to: app.routeScored[min(1, app.routeScored.count - 1)].coordinate)
                : app.simulatedHeading

            let band = currentSimulationBand(app)
            if let existing = simulationAnnotation {
                existing.coordinate = coord
                existing.heading = heading
                existing.band = band
                if let view = mv.view(for: existing) {
                    view.transform = CGAffineTransform(rotationAngle: existing.heading * .pi / 180)
                    view.tintColor = RiskPalette.uiColor(for: existing.band)
                }
            } else {
                let annotation = SimulationVehicleAnnotation(coordinate: coord,
                                                              heading: heading,
                                                              band: band)
                simulationAnnotation = annotation
                mv.addAnnotation(annotation)
            }
        }

        private func currentSimulationBand(_ app: AppModel) -> DVCRiskBand {
            guard !app.routeScored.isEmpty else { return .low }
            let i = min(app.routeScored.count - 1,
                        Int(app.simulationProgress * Double(app.routeScored.count - 1)))
            return app.routeScored[i].band
        }

        // MARK: Delegate — overlays

        func mapView(_ mv: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let h = overlay as? HeatmapOverlay {
                return HeatmapOverlayRenderer(h)
            }
            if let line = overlay as? MKPolyline,
               let raw = Int(line.title ?? ""),
               let band = DVCRiskBand(rawValue: raw) {
                let r = MKPolylineRenderer(polyline: line)
                let c = band.rgba
                r.strokeColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
                r.lineWidth = 6
                r.lineCap = .round
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        // MARK: Delegate — annotations

        func mapView(_ mv: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let endpoint = annotation as? RouteEndpointAnnotation {
                return makeRouteEndpointAnnotationView(for: endpoint, mapView: mv)
            }
            if let hotspot = annotation as? HotspotAnnotation {
                return makeHotspotAnnotationView(for: hotspot, mapView: mv)
            }
            if let vehicle = annotation as? SimulationVehicleAnnotation {
                return makeSimulationAnnotationView(for: vehicle, mapView: mv)
            }
            return nil
        }
    }
}
