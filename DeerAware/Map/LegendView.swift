import SwiftUI

// MARK: - Legend panel

struct LegendView: View {
    @Binding var isVisible: Bool
    @Binding var heatmapStyle: HeatmapStyle

    var body: some View {
        if isVisible {
            VStack(alignment: .leading, spacing: 10) {
                densityGradient
                Divider()
                routeBands
                Divider()
                stylePicker
            }
            .padding(12)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.15), radius: 6)
            .frame(width: 190)
            .transition(.scale(scale: 0.85, anchor: .bottomTrailing).combined(with: .opacity))
        }
    }

    // MARK: Sections

    private var densityGradient: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Collision density")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            LinearGradient(
                stops: [
                    .init(color: Color(hue: 0.33, saturation: 0.9, brightness: 0.95), location: 0),
                    .init(color: Color(hue: 0.17, saturation: 0.9, brightness: 0.95), location: 0.33),
                    .init(color: Color(hue: 0.08, saturation: 0.9, brightness: 0.95), location: 0.67),
                    .init(color: Color(hue: 0.00, saturation: 0.9, brightness: 0.95), location: 1),
                ],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(height: 8)
            .clipShape(Capsule())
            HStack {
                Text("Fewer").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("More").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var routeBands: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Route risk")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            ForEach(DVCRiskBand.allCases, id: \.rawValue) { band in
                HStack(spacing: 6) {
                    Circle()
                        .fill(RiskPalette.color(for: band))
                        .frame(width: 10, height: 10)
                    Text(band.label).font(.caption2)
                }
            }
        }
    }

    private var stylePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Heatmap style")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            Picker("Style", selection: $heatmapStyle) {
                Text("Smooth").tag(HeatmapStyle.smooth)
                Text("Banded").tag(HeatmapStyle.banded)
            }
            .pickerStyle(.segmented)
        }
    }
}

// MARK: - Toggle button

struct LegendToggleButton: View {
    @Binding var showLegend: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                showLegend.toggle()
            }
        } label: {
            Image(systemName: showLegend ? "info.circle.fill" : "info.circle")
                .font(.title2)
                .padding(8)
                .background(.regularMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.15), radius: 3)
        }
    }
}
