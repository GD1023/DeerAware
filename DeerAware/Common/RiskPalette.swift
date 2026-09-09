import SwiftUI

/// Single source of truth for all risk-band colours in the app.
/// Values match DVCRiskBand.rgba exactly.
enum RiskPalette {

    static func color(for band: DVCRiskBand) -> Color {
        let c = band.rgba
        return Color(red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    static func uiColor(for band: DVCRiskBand) -> UIColor {
        let c = band.rgba
        return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    /// Continuous green→red colour for a relative heatmap value in 0…1.
    static func heatmapColor(relative: Double) -> Color {
        guard relative > 0.02 else { return .clear }
        let t = min(max((relative - 0.15) / 0.75, 0), 1)
        let alpha = min(max((relative - 0.05) / 0.6, 0), 0.65)
        return Color(hue: 0.33 * (1 - t), saturation: 0.9, brightness: 0.95, opacity: alpha)
    }
}
