import SwiftUI

struct MapScreen: View {
    @Environment(AppModel.self) private var app
    @State private var showLegend = false
    @State private var showVoiceAssistant = false
    @State private var showHelp = false
    @AppStorage("hasLaunchedBefore") private var hasLaunchedBefore = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                // ── 1. Full map ────────────────────────────────────────
                RiskMapView()
                    .ignoresSafeArea()

                // ── 2. Floating top column (state list + route card) ───
                if !app.isSimulating {
                    VStack(spacing: 6) {
                        // State switcher — hidden during navigation
                        if !app.isNavigating {
                            StateSwitcher()
                                .padding(.vertical, 6)
                                .background(.ultraThinMaterial)
                                .environment(\.colorScheme, .dark)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
                                .padding(.horizontal, 12)
                        }

                        // Route controls (condensed during navigation)
                        RouteControls()
                    }
                    .safeAreaPadding(.top)
                    .padding(.top, 8)
                }

                // ── 2b. Simulation alert — always a fixed top layer ────
                VStack {
                    SimulationAlertBanner()
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                    Spacer()
                }
                .safeAreaPadding(.top)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, alignment: .top)
                .allowsHitTesting(false)

                // ── 3. Legend + zoom — bottom-right ───────────────────
                VStack(alignment: .trailing, spacing: 10) {
                    Spacer()
                    SimulationControls()
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

                // ── 4. Bottom-left buttons ────────────────────────────
                VStack {
                    Spacer()
                    HStack(alignment: .bottom) {
                        VStack(spacing: 10) {
                            if app.route != nil && !showVoiceAssistant {
                                Button { showVoiceAssistant = true } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "waveform.and.mic")
                                        Text("Ask")
                                    }
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                    .background(Color.blue)
                                    .clipShape(Capsule())
                                }
                            }
                            Button {
                                showHelp = true
                            } label: {
                                Image(systemName: "questionmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.3), radius: 6, y: 3)
                            }
                            .accessibilityLabel("Help")
                        }
                        Spacer()
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 40)
                }

                // ── 5. Inline voice assistant overlay ─────────────────
                if showVoiceAssistant {
                    VStack {
                        Spacer()
                        VoiceAssistantView(isPresented: $showVoiceAssistant)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 110)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if !hasLaunchedBefore {
                hasLaunchedBefore = true
                showHelp = true
            }
        }
        .sheet(isPresented: $showHelp) {
            HelpView()
        }
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
