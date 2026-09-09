import SwiftUI

struct MapScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showLegend = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // ── 1. Full map ────────────────────────────────────────
                RiskMapView()
                    .ignoresSafeArea()

                // ── 2. Floating top column (state list + route card) ───
                VStack(spacing: 6) {
                    // State switcher — floating pill strip
                    StateSwitcher()
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                        .padding(.horizontal, 12)

                    // Route from/to card
                    RouteControls()
                }
                .safeAreaPadding(.top)

                // ── 3. Legend + zoom — bottom-right ───────────────────
                VStack(alignment: .trailing, spacing: 10) {
                    Spacer()
                    LegendView(
                        isVisible: $showLegend,
                        heatmapStyle: Binding(
                            get: { app.heatmapStyle },
                            set: { app.heatmapStyle = $0 }
                        )
                    )
                    LegendToggleButton(showLegend: $showLegend)
                    zoomControls
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Zoom controls

    private var zoomControls: some View {
        VStack(spacing: 0) {
            Button {
                app.zoomInCount += 1
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.primary)
            }
            Divider().frame(width: 42)
            Button {
                app.zoomOutCount += 1
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .foregroundStyle(.primary)
            }
        }
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
    }
}
