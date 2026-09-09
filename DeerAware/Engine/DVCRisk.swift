//
//  DVCRisk.swift
//
//  Deer-vehicle-collision risk scoring for a Swift / MapKit app.
//
//  Pairs with the files written by export_for_swift.py:
//      model_export/manifest.json
//      model_export/grid_<State>.bin      (uint8, row-major, row 0 = north edge)
//
//  Add that folder to your target as a *folder reference* (blue) so the bundle keeps
//  the "model_export" subdirectory, then:
//
//      let model = try DVCRiskModel(bundle: .main)
//      let r = model.risk(at: coord, date: Date())
//      print(r.risk, model.band(for: r))
//
//  No ML runtime, no dependencies beyond Foundation + CoreLocation.
//

import Foundation
import CoreLocation

// MARK: - Public types

public struct DVCRiskComponents {
    /// Decoded KDE intensity at the location (relative units, comparable across states).
    public let spatialIntensity: Double
    /// 0...1 version of the spatial layer - handy for heatmap alpha / colour ramps.
    public let spatialRelative: Double
    /// Day-of-year multiplier. 1.0 = yearly average, ~2.2 in November.
    public let seasonFactor: Double
    /// Time-of-day multiplier relative to sunset. 1.0 = daily average, ~2.3 just after dusk.
    public let diurnalFactor: Double
    /// spatialIntensity * seasonFactor * diurnalFactor
    public let risk: Double
    /// false when the location is outside every state grid (risk falls back to temporal-only).
    public let covered: Bool
}

public enum DVCRiskBand: Int, CaseIterable {
    case low = 0, moderate, high, severe

    /// RGBA in 0...1 - feed straight into UIColor / CGColor for MKPolylineRenderer.
    public var rgba: (r: Double, g: Double, b: Double, a: Double) {
        switch self {
        case .low:      return (0.20, 0.70, 0.32, 0.85)
        case .moderate: return (0.96, 0.79, 0.22, 0.90)
        case .high:     return (0.95, 0.51, 0.12, 0.95)
        case .severe:   return (0.86, 0.16, 0.16, 1.00)
        }
    }

    public var label: String {
        switch self {
        case .low: return "Low"; case .moderate: return "Moderate"
        case .high: return "High"; case .severe: return "Severe"
        }
    }
}

public struct DVCRoutePointRisk {
    public let coordinate: CLLocationCoordinate2D
    public let eta: Date
    public let components: DVCRiskComponents
    public let band: DVCRiskBand
}

// MARK: - Model

public final class DVCRiskModel {

    public enum LoadError: Error { case manifestNotFound, gridSizeMismatch(String) }

    struct StateGrid {
        let name: String
        let rows, cols: Int
        let latTop, latBottom, lonLeft, lonRight: Double
        let bytes: [UInt8]
        var area: Double { (latTop - latBottom) * (lonRight - lonLeft) }
    }

    let season: [Double]      // length 366, indexed by dayOfYear % 366
    let diurnal: [Double]     // length 96,  indexed by floor(((h mod 24)/24)*96)
    let logLo, logHi, eps: Double
    let bandP80, bandP95, bandP99: Double
    let grids: [StateGrid]

    /// Sensitivity for `band(for:)`. >1 makes the map redder sooner, <1 calmer. Default 1.
    public var bandSensitivity: Double = 1.0

    // MARK: Loading

    private struct Manifest: Decodable {
        struct Decode: Decodable { let log_lo, log_hi, eps: Double }
        struct Bands: Decodable { let p80, p95, p99: Double }
        struct State: Decodable {
            let name, file: String
            let rows, cols: Int
            let lat_top, lat_bottom, lon_left, lon_right: Double
        }
        let decode: Decode
        let season_profile: [Double]
        let diurnal_profile: [Double]
        let bands: Bands
        let states: [State]
    }

    /// Load from a directory that contains manifest.json + the grid_*.bin files.
    public init(directoryURL dir: URL) throws {
        let manifestURL = dir.appendingPathComponent("manifest.json")
        let mf = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))

        season = mf.season_profile
        diurnal = mf.diurnal_profile
        logLo = mf.decode.log_lo
        logHi = mf.decode.log_hi
        eps = mf.decode.eps
        bandP80 = mf.bands.p80
        bandP95 = mf.bands.p95
        bandP99 = mf.bands.p99

        grids = try mf.states.map { s in
            let data = try Data(contentsOf: dir.appendingPathComponent(s.file))
            guard data.count == s.rows * s.cols else { throw LoadError.gridSizeMismatch(s.name) }
            return StateGrid(name: s.name, rows: s.rows, cols: s.cols,
                             latTop: s.lat_top, latBottom: s.lat_bottom,
                             lonLeft: s.lon_left, lonRight: s.lon_right,
                             bytes: [UInt8](data))
        }
    }

    /// Convenience: find `model_export/` inside an app bundle (folder reference or flat group).
    public convenience init(bundle: Bundle = .main, subdirectory: String? = "model_export") throws {
        if let sub = subdirectory,
           let url = bundle.url(forResource: "manifest", withExtension: "json", subdirectory: sub) {
            try self.init(directoryURL: url.deletingLastPathComponent()); return
        }
        if let url = bundle.url(forResource: "manifest", withExtension: "json") {
            try self.init(directoryURL: url.deletingLastPathComponent()); return
        }
        throw LoadError.manifestNotFound
    }

    // MARK: Components

    public func seasonFactor(dayOfYear: Int) -> Double {
        season[((dayOfYear % 366) + 366) % 366]
    }

    public func diurnalFactor(hoursAfterSunset h: Double) -> Double {
        let m = (h.truncatingRemainder(dividingBy: 24) + 24).truncatingRemainder(dividingBy: 24)
        let i = min(diurnal.count - 1, max(0, Int(m / 24.0 * Double(diurnal.count))))
        return diurnal[i]
    }

    /// Approximate local decimal hour of sunset (NOAA low-accuracy algorithm, ~10-15 min).
    /// `tzOffsetHours` MUST match the convention of the local clock time you compare against.
    /// `risk(at:date:)` passes `timeZone.secondsFromGMT(for:date)/3600`, which is DST-aware -
    /// and the model was trained on DST-aware wall-clock sunset, so that is correct.
    /// For better accuracy drop in the `Solar` Swift package and call it here instead.
    public static func sunsetHourDecimal(latitude: Double, longitude: Double,
                                         dayOfYear: Int, tzOffsetHours: Double) -> Double {
        let d = Double(dayOfYear)
        let g = 2.0 * .pi / 365.0 * (d - 1.0)
        let eqTime = 229.18 * (0.000075 + 0.001868 * cos(g) - 0.032077 * sin(g)
                               - 0.014615 * cos(2 * g) - 0.040849 * sin(2 * g))
        let decl = 0.006918 - 0.399912 * cos(g) + 0.070257 * sin(g)
                 - 0.006758 * cos(2 * g) + 0.000907 * sin(2 * g)
                 - 0.002697 * cos(3 * g) + 0.00148 * sin(3 * g)
        let latR = latitude * .pi / 180.0
        let cosHA = cos(90.833 * .pi / 180.0) / (cos(latR) * cos(decl)) - tan(latR) * tan(decl)
        let ha = acos(min(1.0, max(-1.0, cosHA))) * 180.0 / .pi     // sunset hour angle, degrees
        let solarNoonMinutes = 720.0 - 4.0 * longitude - eqTime + tzOffsetHours * 60.0
        return (solarNoonMinutes + 4.0 * ha) / 60.0
    }

    // MARK: Scoring

    public func risk(at c: CLLocationCoordinate2D, date: Date,
                     calendar: Calendar = .current, timeZone: TimeZone = .current) -> DVCRiskComponents {
        var cal = calendar
        cal.timeZone = timeZone
        let doy = cal.ordinality(of: .day, in: .year, for: date) ?? 1
        let t = cal.dateComponents([.hour, .minute, .second], from: date)
        let localHour = Double(t.hour ?? 0) + Double(t.minute ?? 0) / 60.0 + Double(t.second ?? 0) / 3600.0
        let tzOffset = Double(timeZone.secondsFromGMT(for: date)) / 3600.0

        let sunset = Self.sunsetHourDecimal(latitude: c.latitude, longitude: c.longitude,
                                            dayOfYear: doy, tzOffsetHours: tzOffset)
        let sFactor = seasonFactor(dayOfYear: doy)
        let dFactor = diurnalFactor(hoursAfterSunset: localHour - sunset)

        if let g = grid(containing: c) {
            let rel = sample(g, c)
            let intensity = decode(rel)
            return DVCRiskComponents(spatialIntensity: intensity, spatialRelative: rel,
                                     seasonFactor: sFactor, diurnalFactor: dFactor,
                                     risk: intensity * sFactor * dFactor, covered: true)
        } else {
            let baseline = bandP80 * 0.5            // "quiet populated road" stand-in
            return DVCRiskComponents(spatialIntensity: baseline, spatialRelative: 0,
                                     seasonFactor: sFactor, diurnalFactor: dFactor,
                                     risk: baseline * sFactor * dFactor, covered: false)
        }
    }

    public func band(for k: DVCRiskComponents) -> DVCRiskBand {
        let effective = k.spatialIntensity * k.seasonFactor * k.diurnalFactor / bandSensitivity
        if effective >= bandP99 { return .severe }
        if effective >= bandP95 { return .high }
        if effective >= bandP80 { return .moderate }
        return .low
    }

    /// Score a route. `coordinates` is the ordered polyline (e.g. `MKRoute.polyline` points);
    /// each sample is timestamped by its share of `expectedTravelTime` so dusk/season are
    /// evaluated at the time the driver will actually be there.
    public func scoreRoute(_ coordinates: [CLLocationCoordinate2D],
                           departure: Date,
                           expectedTravelTime: TimeInterval,
                           samples: Int = 120) -> [DVCRoutePointRisk] {
        guard coordinates.count >= 2 else {
            return coordinates.map {
                let k = risk(at: $0, date: departure)
                return DVCRoutePointRisk(coordinate: $0, eta: departure, components: k, band: band(for: k))
            }
        }

        var cumulative: [Double] = [0]
        cumulative.reserveCapacity(coordinates.count)
        for i in 1..<coordinates.count {
            let a = CLLocation(latitude: coordinates[i - 1].latitude, longitude: coordinates[i - 1].longitude)
            let b = CLLocation(latitude: coordinates[i].latitude, longitude: coordinates[i].longitude)
            cumulative.append(cumulative[i - 1] + a.distance(from: b))
        }
        let total = cumulative.last ?? 0
        guard total > 0 else {
            let k = risk(at: coordinates[0], date: departure)
            return [DVCRoutePointRisk(coordinate: coordinates[0], eta: departure, components: k, band: band(for: k))]
        }

        let n = max(2, samples)
        var out: [DVCRoutePointRisk] = []
        out.reserveCapacity(n)
        var seg = 1
        for k in 0..<n {
            let s = total * Double(k) / Double(n - 1)
            while seg < cumulative.count - 1 && cumulative[seg] < s { seg += 1 }
            let f = (s - cumulative[seg - 1]) / max(cumulative[seg] - cumulative[seg - 1], 1e-9)
            let c = CLLocationCoordinate2D(
                latitude: coordinates[seg - 1].latitude + f * (coordinates[seg].latitude - coordinates[seg - 1].latitude),
                longitude: coordinates[seg - 1].longitude + f * (coordinates[seg].longitude - coordinates[seg - 1].longitude))
            let eta = departure.addingTimeInterval(expectedTravelTime * (s / total))
            let comp = risk(at: c, date: eta)
            out.append(DVCRoutePointRisk(coordinate: c, eta: eta, components: comp, band: band(for: comp)))
        }
        return out
    }

    // MARK: Spatial internals

    private func grid(containing c: CLLocationCoordinate2D) -> StateGrid? {
        grids.filter {
            c.latitude <= $0.latTop && c.latitude >= $0.latBottom &&
            c.longitude >= $0.lonLeft && c.longitude <= $0.lonRight
        }.min { $0.area < $1.area }
    }

    /// Bilinear sample of the 0...1 relative surface. Row 0 is the north edge.
    private func sample(_ g: StateGrid, _ c: CLLocationCoordinate2D) -> Double {
        let fy = (g.latTop - c.latitude) / (g.latTop - g.latBottom) * Double(g.rows - 1)
        let fx = (c.longitude - g.lonLeft) / (g.lonRight - g.lonLeft) * Double(g.cols - 1)
        let y0 = min(max(Int(fy.rounded(.down)), 0), g.rows - 1)
        let x0 = min(max(Int(fx.rounded(.down)), 0), g.cols - 1)
        let y1 = min(y0 + 1, g.rows - 1)
        let x1 = min(x0 + 1, g.cols - 1)
        let ty = fy - Double(y0)
        let tx = fx - Double(x0)
        func px(_ y: Int, _ x: Int) -> Double { Double(g.bytes[y * g.cols + x]) / 255.0 }
        let top = px(y0, x0) * (1 - tx) + px(y0, x1) * tx
        let bot = px(y1, x0) * (1 - tx) + px(y1, x1) * tx
        return top * (1 - ty) + bot * ty
    }

    private func decode(_ relative: Double) -> Double {
        max(0, pow(10.0, logLo + relative * (logHi - logLo)) - eps)
    }
}

// MARK: - MapKit helpers

#if canImport(MapKit)
import MapKit

public extension DVCRiskModel {

    /// Group a scored route into one polyline per contiguous run of the same band.
    /// Each polyline's `title` is the band's rawValue ("0"..."3") so the renderer can colour it.
    func routeOverlays(_ scored: [DVCRoutePointRisk]) -> [MKPolyline] {
        guard scored.count >= 2 else { return [] }
        var lines: [MKPolyline] = []
        var run: [CLLocationCoordinate2D] = [scored[0].coordinate]
        var runBand = scored[0].band
        for p in scored.dropFirst() {
            run.append(p.coordinate)
            if p.band != runBand {
                let pl = MKPolyline(coordinates: run, count: run.count)
                pl.title = String(runBand.rawValue)
                lines.append(pl)
                run = [p.coordinate]
                runBand = p.band
            }
        }
        if run.count >= 2 {
            let pl = MKPolyline(coordinates: run, count: run.count)
            pl.title = String(runBand.rawValue)
            lines.append(pl)
        }
        return lines
    }

    /// The worst stretches, most dangerous first - good for dropping a few warning annotations.
    func hotspots(_ scored: [DVCRoutePointRisk], minBand: DVCRiskBand = .high, limit: Int = 3) -> [DVCRoutePointRisk] {
        scored.filter { $0.band.rawValue >= minBand.rawValue }
              .sorted { $0.components.risk > $1.components.risk }
              .prefix(limit)
              .map { $0 }
    }
}

public extension MKPolyline {
    /// Convenience: pull the coordinate list back out of a polyline.
    func coordinates() -> [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
#endif

// MARK: - Phase 3 Public Accessors

public struct DVCDecodeParams {
    public let logLo, logHi, eps: Double
}

public struct DVCStateGridInfo {
    public let name: String
    public let rows, cols: Int
    public let latTop, latBottom, lonLeft, lonRight: Double
    public let bytes: [UInt8]   // rows*cols, row 0 = north

    public var centerCoordinate: CLLocationCoordinate2D {
        .init(latitude: (latTop + latBottom) / 2, longitude: (lonLeft + lonRight) / 2)
    }
}

public extension DVCRiskModel {
    /// Covered state names, alphabetical.
    var stateNames: [String] { grids.map(\.name).sorted() }

    var decodeParams: DVCDecodeParams { .init(logLo: logLo, logHi: logHi, eps: eps) }

    /// Intensity cutoffs for moderate / high / severe bands.
    var bandCutoffs: (p80: Double, p95: Double, p99: Double) { (bandP80, bandP95, bandP99) }

    func gridInfo(for stateName: String) -> DVCStateGridInfo? {
        guard let g = grids.first(where: { $0.name == stateName }) else { return nil }
        return .init(name: g.name, rows: g.rows, cols: g.cols,
                     latTop: g.latTop, latBottom: g.latBottom,
                     lonLeft: g.lonLeft, lonRight: g.lonRight, bytes: g.bytes)
    }

    /// Decoded intensity for a given relative (0…1) value from the grid.
    func intensity(forRelative r: Double) -> Double {
        max(0, pow(10.0, logLo + r * (logHi - logLo)) - eps)
    }
}

#if canImport(MapKit)
public extension DVCStateGridInfo {
    var region: MKCoordinateRegion {
        MKCoordinateRegion(
            center: centerCoordinate,
            span: MKCoordinateSpan(
                latitudeDelta: (latTop - latBottom) * 1.15,
                longitudeDelta: (lonRight - lonLeft) * 1.15))
    }
}
#endif
