import MapKit

// MARK: - Route endpoint annotations (Start / End pins)

final class RouteEndpointAnnotation: NSObject, MKAnnotation {
    enum Kind { case start, end }
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let kind: Kind

    init(coordinate: CLLocationCoordinate2D, kind: Kind) {
        self.coordinate = coordinate
        self.kind = kind
        self.title = kind == .start ? "Start" : "End"
        super.init()
    }
}

func makeRouteEndpointAnnotationView(for annotation: RouteEndpointAnnotation,
                                      mapView: MKMapView) -> MKMarkerAnnotationView {
    let reuseID = "routeEndpoint"
    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                as? MKMarkerAnnotationView)
               ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)

    view.annotation = annotation
    switch annotation.kind {
    case .start:
        view.markerTintColor = .systemGreen
        view.glyphImage = UIImage(systemName: "figure.walk")
    case .end:
        view.markerTintColor = .systemRed
        view.glyphImage = UIImage(systemName: "flag.checkered")
    }
    view.canShowCallout = true
    return view
}

// MARK: - Annotation model

final class HotspotAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?
    let band: DVCRiskBand

    init(_ point: DVCRoutePointRisk) {
        coordinate = point.coordinate
        band = point.band
        title = "\(point.band.label) deer risk"
        let minsAhead = max(0, Int(point.eta.timeIntervalSinceNow / 60))
        subtitle = "~\(minsAhead) min ahead · \(point.eta.formatted(date: .omitted, time: .shortened))"
        super.init()
    }
}

// MARK: - Annotation view factory

func makeHotspotAnnotationView(for annotation: HotspotAnnotation,
                                mapView: MKMapView) -> MKMarkerAnnotationView {
    let reuseID = "hotspot"
    let view = (mapView.dequeueReusableAnnotationView(withIdentifier: reuseID)
                as? MKMarkerAnnotationView)
               ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: reuseID)

    view.annotation = annotation
    let c = annotation.band.rgba
    view.markerTintColor = UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    view.glyphImage = UIImage(systemName: "exclamationmark.triangle.fill")
    view.canShowCallout = true
    return view
}
