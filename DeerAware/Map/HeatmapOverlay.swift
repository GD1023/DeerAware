import MapKit

final class HeatmapOverlay: NSObject, MKOverlay {
    let coordinate: CLLocationCoordinate2D
    let boundingMapRect: MKMapRect
    let image: CGImage

    init(_ g: DVCStateGridInfo, image: CGImage) {
        self.image = image
        let tl = MKMapPoint(CLLocationCoordinate2D(latitude: g.latTop, longitude: g.lonLeft))
        let br = MKMapPoint(CLLocationCoordinate2D(latitude: g.latBottom, longitude: g.lonRight))
        boundingMapRect = MKMapRect(
            x: min(tl.x, br.x), y: min(tl.y, br.y),
            width: abs(br.x - tl.x), height: abs(br.y - tl.y))
        coordinate = g.centerCoordinate
        super.init()
    }
}

final class HeatmapOverlayRenderer: MKOverlayRenderer {
    private let image: CGImage

    init(_ overlay: HeatmapOverlay) {
        image = overlay.image
        super.init(overlay: overlay)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in ctx: CGContext) {
        let rect = self.rect(for: overlay.boundingMapRect)
        ctx.interpolationQuality = .high
        // CGImage draws y-up; flip so grid row 0 lands on the north edge.
        ctx.translateBy(x: 0, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: rect.minX, y: 0, width: rect.width, height: rect.height))
    }
}
