import Foundation
import MapKit

// MARK: - Best-time-to-leave advisor
extension AppModel {

    /// Departure offsets scanned for the advisor: now out to +6h in 30-min steps.
    /// 6h caps the scan to a same-trip planning window (beyond that "now" stops being
    /// a meaningful baseline); 30-min steps keep the sample count (13) cheap enough to
    /// score synchronously without noticeably blocking the UI.
    private static let departureScanOffsets: [TimeInterval] =
        stride(from: 0.0, through: 21_600.0, by: 1_800.0).map { $0 }

    /// Re-scans the active route across `departureScanOffsets`, scoring each candidate
    /// departure time and picking the safest one. Cheap enough (13 samples x 48 points)
    /// to run synchronously on the main actor - no background threading needed since
    /// `engine.scoreRoute` is just bilinear grid lookups + array math.
    func recomputeDepartureOptions() {
        guard let route else {
            resetDepartureOptions()
            return
        }

        isComputingDepartureOptions = true

        let coordinates = route.polyline.coordinates()
        let travelTime = route.expectedTravelTime
        let now = Date()

        let options: [DepartureOption] = Self.departureScanOffsets.map { offset in
            let departure = now.addingTimeInterval(offset)
            let scored = engine.scoreRoute(coordinates, departure: departure,
                                           expectedTravelTime: travelTime, samples: 48)
            let worstBand = scored.map(\.band).max(by: { $0.rawValue < $1.rawValue }) ?? .low
            let severe = scored.reduce(0) { $1.band == .severe ? $0 + 1 : $0 }
            let high = scored.reduce(0) { $1.band == .high ? $0 + 1 : $0 }
            let meanRisk = scored.isEmpty ? 0
                : scored.reduce(0.0) { $0 + $1.components.risk } / Double(scored.count)
            return DepartureOption(offset: offset, date: departure, overallBand: worstBand,
                                    severeCount: severe, highCount: high, meanRisk: meanRisk)
        }

        departureOptions = options

        // Safest option: lowest overall band first, then fewest severe/high points, then
        // earliest offset - among equally-safe choices, prefer leaving sooner.
        recommendedDepartureOffset = options.min { a, b in
            if a.overallBand.rawValue != b.overallBand.rawValue {
                return a.overallBand.rawValue < b.overallBand.rawValue
            }
            let aBad = a.severeCount + a.highCount
            let bBad = b.severeCount + b.highCount
            if aBad != bBad { return aBad < bBad }
            return a.offset < b.offset
        }?.offset

        isComputingDepartureOptions = false
    }

    func resetDepartureOptions() {
        departureOptions = []
        recommendedDepartureOffset = nil
        isComputingDepartureOptions = false
    }
}
