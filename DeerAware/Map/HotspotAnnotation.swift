import MapKit

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
