import SwiftUI
import MapKit

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
        private var lastZoomIn = 0
        private var lastZoomOut = 0

        func sync(_ mv: MKMapView, app: AppModel) {
            syncHeatmap(mv, app: app)
            syncRoute(mv, app: app)
            syncZoom(mv, app: app)
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
            let stateChanged = shownState != app.selectedStateName
            let styleChanged = shownStyle != app.heatmapStyle

            guard stateChanged || styleChanged,
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
            // Use first hotspot pointer as a cheap version token
            let newID = app.routeScored.first.map { ObjectIdentifier($0.components as AnyObject) }

            guard newID != drawnRouteID else { return }
            drawnRouteID = newID

            // Remove old route polylines
            mv.removeOverlays(mv.overlays.filter { $0 is MKPolyline })
            // Remove old hotspot annotations
            mv.removeAnnotations(mv.annotations.filter { $0 is HotspotAnnotation })

            guard !app.routeScored.isEmpty else { return }

            mv.addOverlays(app.engine.routeOverlays(app.routeScored), level: .aboveRoads)
            mv.addAnnotations(app.hotspots.map { HotspotAnnotation($0) })

            if let route = app.route {
                mv.setVisibleMapRect(route.polyline.boundingMapRect,
                                     edgePadding: UIEdgeInsets(top: 60, left: 20, bottom: 120, right: 20),
                                     animated: true)
            }
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
            guard let hotspot = annotation as? HotspotAnnotation else { return nil }
            return makeHotspotAnnotationView(for: hotspot, mapView: mv)
        }
    }
}
