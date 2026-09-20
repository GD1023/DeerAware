//
//  DeerAwareTools.swift
//  DeerAware
//
//  Plain-data context bridging AppModel's route/departure state into the
//  voice assistant (both the FoundationModels tools and the rule-based
//  fallback read from it), plus the `Tool` implementations themselves.
//
//  This file deliberately never imports or reads from AppModel.swift /
//  AppModel+Routing.swift internals beyond the documented public properties
//  listed in `DeerAwareContext.build(from:)` below - those files are owned
//  by another part of the project.
//

import Foundation
import CoreLocation
import MapKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Plain-data snapshot of AppModel

/// A read-only summary of the active route/risk state, rebuilt by the view
/// each turn from `AppModel`'s already-existing properties. Kept as plain
/// value types (no `MKRoute`, no `AppModel` reference) so it's trivially
/// `Sendable` and safe to hand to tools that may run off the main actor.
struct DeerAwareContext: Equatable, Sendable {
    struct HotspotInfo: Equatable, Sendable {
        let bandLabel: String
        let minutesFromNow: Double
    }

    struct DepartureInfo: Equatable, Sendable {
        let offsetMinutes: Double
        let bandLabel: String
        let severeCount: Int
        let highCount: Int
        let isNow: Bool
        let isRecommended: Bool
    }

    var selectedStateName: String = ""
    var hasActiveRoute: Bool = false
    var routeDistanceMiles: Double?
    var routeTravelTimeMinutes: Double?
    var worstBandLabel: String?
    var hotspots: [HotspotInfo] = []
    var departureOptions: [DepartureInfo] = []

    static let empty = DeerAwareContext()
}

extension DeerAwareContext {
    /// Builds the snapshot from `AppModel`'s existing, already-populated
    /// properties: `selectedStateName`, `route` (MKRoute), `routeScored`,
    /// `hotspots`, `departureOptions`, and `recommendedDepartureOffset`.
    static func build(from app: AppModel) -> DeerAwareContext {
        var ctx = DeerAwareContext()
        ctx.selectedStateName = app.selectedStateName
        ctx.hasActiveRoute = app.route != nil
        ctx.routeDistanceMiles = app.route.map { $0.distance / 1609.344 }
        ctx.routeTravelTimeMinutes = app.route.map { $0.expectedTravelTime / 60 }

        if let worstRaw = app.routeScored.map({ $0.band.rawValue }).max(),
           let worstBand = DVCRiskBand(rawValue: worstRaw) {
            ctx.worstBandLabel = worstBand.label
        }

        let now = Date()
        ctx.hotspots = app.hotspots.map { hp in
            HotspotInfo(bandLabel: hp.band.label, minutesFromNow: hp.eta.timeIntervalSince(now) / 60)
        }

        ctx.departureOptions = app.departureOptions.map { option in
            DepartureInfo(
                offsetMinutes: option.offset / 60,
                bandLabel: option.overallBand.label,
                severeCount: option.severeCount,
                highCount: option.highCount,
                isNow: option.isNow,
                isRecommended: app.recommendedDepartureOffset == option.offset
            )
        }
        return ctx
    }
}

// MARK: - Fallback / tool-facing text summaries

extension DeerAwareContext {
    var routeSummary: String {
        guard hasActiveRoute else {
            return "There's no active route right now. Set a destination on the map to get route-specific risk."
        }
        var parts: [String] = []
        if let miles = routeDistanceMiles { parts.append(String(format: "%.1f miles", miles)) }
        if let minutes = routeTravelTimeMinutes { parts.append(String(format: "about %.0f minutes", minutes)) }
        var summary = "Your route in \(selectedStateName) is " + parts.joined(separator: ", ") + "."
        if let worst = worstBandLabel { summary += " Worst risk band along the way: \(worst)." }
        return summary
    }

    var riskSummary: String {
        guard hasActiveRoute else {
            return "There's no active route to score. Ask me about risk near you, or set a destination on the map first."
        }
        guard let worst = worstBandLabel else {
            return "I don't have a risk score for the current route yet."
        }
        if hotspots.isEmpty {
            return "Your route's worst stretch is rated \(worst) risk."
        }
        return "Your route's worst stretch is rated \(worst) risk, with \(hotspots.count) flagged hotspot\(hotspots.count == 1 ? "" : "s")."
    }

    var hotspotSummary: String {
        guard hasActiveRoute else {
            return "There's no active route, so there are no hotspots to report."
        }
        // `hotspots` preserves AppModel's ordering (worst risk first, see
        // `DVCRiskModel.hotspots`), so the first element is the worst.
        guard let worst = hotspots.first else {
            return "No high-risk hotspots on your current route."
        }
        return "Your route has \(hotspots.count) hotspot\(hotspots.count == 1 ? "" : "s") flagged, the worst rated \(worst.bandLabel)."
    }

    var departureSummary: String {
        guard hasActiveRoute else {
            return "There's no active route, so I can't suggest a departure time yet."
        }
        guard !departureOptions.isEmpty else {
            return "I don't have departure options computed yet - give it a moment after setting your route."
        }
        if let best = departureOptions.first(where: { $0.isRecommended }) {
            if best.isNow {
                return "Now looks like the best time to leave in the next six hours, rated \(best.bandLabel)."
            }
            return "Leaving in about \(Int(best.offsetMinutes)) minutes looks best in the next six hours, rated \(best.bandLabel)."
        }
        let nowOption = departureOptions.first(where: { $0.isNow })
        return "Leaving now is rated \(nowOption?.bandLabel ?? "unknown")."
    }

    var travelTimeSummary: String {
        guard let minutes = routeTravelTimeMinutes else {
            return "There's no active route, so I don't have a travel time."
        }
        return "Your route should take about \(Int(minutes)) minutes."
    }

    /// One combined briefing - used by the `RouteSummaryTool` so the language
    /// model gets everything in one call instead of guessing at numbers.
    var fullRouteBriefing: String {
        guard hasActiveRoute else {
            return "No route is currently active in DeerAware."
        }
        var lines = [routeSummary, riskSummary]
        if !hotspots.isEmpty { lines.append(hotspotSummary) }
        if !departureOptions.isEmpty { lines.append(departureSummary) }
        return lines.joined(separator: " ")
    }
}

// MARK: - Thread-safe holder shared between VoiceAssistant and the tools

/// Tool `call(arguments:)` methods may run off the main actor, while
/// `VoiceAssistant` updates `context` on the main actor each turn - this
/// holder guards both with a lock rather than assuming either side's
/// thread. `@unchecked Sendable` is safe here because every access goes
/// through the lock.
final class DeerAwareContextStore: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var _context = DeerAwareContext.empty
    nonisolated(unsafe) private var _engine: DVCRiskModel?

    nonisolated var context: DeerAwareContext {
        get { lock.lock(); defer { lock.unlock() }; return _context }
        set { lock.lock(); _context = newValue; lock.unlock() }
    }

    nonisolated var engine: DVCRiskModel? {
        get { lock.lock(); defer { lock.unlock() }; return _engine }
        set { lock.lock(); _engine = newValue; lock.unlock() }
    }
}

// MARK: - One-shot current location (intentionally independent of AppModel)

/// A standalone, one-shot location fetch used only by `CurrentRiskTool`. This
/// is deliberately its own `CLLocationManager` - separate from any location
/// handling elsewhere in the app - so the voice assistant never assumes
/// unverified AppModel internals for location.
final class OneShotLocationFetcher: NSObject, CLLocationManagerDelegate, @unchecked Sendable {
    static let shared = OneShotLocationFetcher()

    enum FetchError: Error { case denied, failed }

    private let manager = CLLocationManager()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private var awaitingAuthorization = false

    private override init() {
        super.init()
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.delegate = self
    }

    func currentLocation() async throws -> CLLocationCoordinate2D {
        try await withCheckedThrowingContinuation { cont in
            self.lock.lock()
            self.continuation = cont
            self.lock.unlock()
            DispatchQueue.main.async {
                switch self.manager.authorizationStatus {
                case .denied, .restricted:
                    self.finish(.failure(FetchError.denied))
                case .notDetermined:
                    self.awaitingAuthorization = true
                    self.manager.requestWhenInUseAuthorization()
                default:
                    self.manager.requestLocation()
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        finish(.success(coordinate))
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(.failure(error))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard awaitingAuthorization else { return }
        awaitingAuthorization = false
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finish(.failure(FetchError.denied))
        default:
            break
        }
    }

    private func finish(_ result: Result<CLLocationCoordinate2D, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success(let coordinate): cont.resume(returning: coordinate)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}

// MARK: - FoundationModels tools

#if canImport(FoundationModels)

/// Reports live deer-collision risk at the user's current GPS location,
/// right now - grounds the model in the same `DVCRiskModel` used everywhere
/// else in the app instead of letting it invent numbers.
@available(iOS 26.0, *)
struct CurrentRiskTool: Tool {
    let name = "currentRiskHere"
    let description = "Looks up the live deer-vehicle-collision risk at the user's current GPS location, right now, using the on-device risk model. Use this whenever the user asks about risk 'here', 'near me', or 'right now'."

    @Generable
    struct Arguments {}

    let store: DeerAwareContextStore

    func call(arguments: Arguments) async throws -> String {
        guard let engine = store.engine else {
            return "The risk model isn't loaded yet."
        }
        let coordinate: CLLocationCoordinate2D
        do {
            coordinate = try await OneShotLocationFetcher.shared.currentLocation()
        } catch {
            return "I couldn't get your current location, so I can't check risk there right now."
        }

        let components = engine.risk(at: coordinate, date: Date())
        guard components.covered else {
            return "You're currently outside DeerAware's nine covered states, so there's no fine-grained spatial data here - only general season and time-of-day factors apply."
        }
        let band = engine.band(for: components)
        let season = String(format: "%.1f", components.seasonFactor)
        let dusk = String(format: "%.1f", components.diurnalFactor)
        return "Current risk band here: \(band.label). Season multiplier \u{d7}\(season), dusk multiplier \u{d7}\(dusk)."
    }
}

/// Reports a summary of the currently active route: distance, travel time,
/// worst risk band, hotspots, and the recommended departure time in the
/// next six hours - all pulled from the plain-data context the view
/// refreshes from AppModel each turn, never guessed by the model.
@available(iOS 26.0, *)
struct RouteSummaryTool: Tool {
    let name = "activeRouteSummary"
    let description = "Reports a summary of the user's currently active route in the DeerAware app: distance, travel time, worst risk band, hotspots, and the recommended departure time within the next 6 hours. Use this whenever the user asks about their route, trip, hotspots, or the best time to leave. If no route is active, says so."

    @Generable
    struct Arguments {}

    let store: DeerAwareContextStore

    func call(arguments: Arguments) async throws -> String {
        store.context.fullRouteBriefing
    }
}

#endif
