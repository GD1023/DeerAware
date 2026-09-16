import Foundation
import CoreLocation
import MapKit
import UIKit

/// Holds the state a running simulation needs that can't live as a stored
/// property on `AppModel` itself (this is a class extension — Swift forbids
/// adding instance stored properties to a class from an extension). `AppModel`
/// is effectively a single app-wide instance, so a private static holder is
/// safe and keeps `AppModel.swift` untouched.
private final class SimulationDriver {
    static var task: Task<Void, Never>?
    /// Indices into `routeScored` that have already fired an alert this run,
    /// so a high/severe stretch only warns once as it's approached.
    static var alertedIndices: Set<Int> = []
    /// Index of the point behind the alert currently shown in the banner,
    /// used to know when we've driven far enough past it to clear it.
    static var activeAlertIndex: Int?
}

extension AppModel {

    /// Whole trip compresses into this many real seconds, regardless of the
    /// route's actual length/`expectedTravelTime`, so playback always feels
    /// like a quick preview rather than a real-time drive.
    private static let simulationDuration: TimeInterval = 18
    private static let frameInterval: TimeInterval = 1.0 / 30.0
    /// How many samples ahead of the current position to scan for an
    /// unalerted high/severe stretch each tick.
    private static let lookaheadSamples = 6
    /// How many samples past an alerted point before its banner clears.
    private static let alertClearLag = 2

    // MARK: - Controls

    func startSimulation() {
        guard route != nil, !routeScored.isEmpty else { return }
        stopSimulation()

        isSimulating = true
        simulationProgress = 0
        activeSimulationAlert = nil
        SimulationDriver.alertedIndices.removeAll()
        SimulationDriver.activeAlertIndex = nil

        SimulationDriver.task = Task { @MainActor [weak self] in
            let start = Date()
            while let self, self.isSimulating, !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(start)
                let progress = min(1, elapsed / Self.simulationDuration)
                self.advanceSimulation(to: progress)
                if progress >= 1 { break }
                try? await Task.sleep(nanoseconds: UInt64(Self.frameInterval * 1_000_000_000))
            }
            // If `stopSimulation()` cancelled us, it already reset state —
            // don't stomp on a fresh run that may have started since.
            guard let self, !Task.isCancelled else { return }
            self.isSimulating = false
            self.simulatedCoordinate = nil
            self.activeSimulationAlert = nil
            self.simulationProgress = 0
        }
    }

    /// Convenience for a single play/stop button.
    func togglePlayback() {
        if isSimulating { stopSimulation() } else { startSimulation() }
    }

    func stopSimulation() {
        SimulationDriver.task?.cancel()
        SimulationDriver.task = nil
        SimulationDriver.alertedIndices.removeAll()
        SimulationDriver.activeAlertIndex = nil
        isSimulating = false
        simulatedCoordinate = nil
        activeSimulationAlert = nil
        simulationProgress = 0
    }

    // MARK: - Per-tick update

    private func advanceSimulation(to progress: Double) {
        guard !routeScored.isEmpty else { return }
        simulationProgress = progress

        let lastIndex = routeScored.count - 1
        let i = min(lastIndex, Int(progress * Double(lastIndex)))
        let here = routeScored[i]
        simulatedCoordinate = here.coordinate
        let j = min(lastIndex, i + 1)
        simulatedHeading = Self.bearing(from: here.coordinate, to: routeScored[j].coordinate)

        // Direction-aware alerting: only scan indices >= i (ahead of, or at,
        // the current position in the route's start->end travel order), so a
        // stretch already driven through can never (re-)trigger a warning.
        let end = min(routeScored.count, i + Self.lookaheadSamples)
        if i < end {
            for k in i..<end {
                let point = routeScored[k]
                guard point.band == .high || point.band == .severe else { continue }
                guard !SimulationDriver.alertedIndices.contains(k) else { continue }
                SimulationDriver.alertedIndices.insert(k)
                SimulationDriver.activeAlertIndex = k
                activeSimulationAlert = point
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                break
            }
        }

        // Clear the transient banner once we've driven a few samples past
        // the point it was warning about.
        if let activeIndex = SimulationDriver.activeAlertIndex, i > activeIndex + Self.alertClearLag {
            activeSimulationAlert = nil
            SimulationDriver.activeAlertIndex = nil
        }
    }

    /// Standard great-circle initial bearing, in degrees clockwise from
    /// north (0...360) — used to rotate the simulated vehicle marker.
    private static func bearing(from a: CLLocationCoordinate2D,
                                 to b: CLLocationCoordinate2D) -> CLLocationDirection {
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
