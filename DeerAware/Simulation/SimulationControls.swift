import SwiftUI

/// Play/stop control for the sped-up trip simulation, styled to match the
/// zoom controls it sits above in `MapScreen`'s bottom-right floating stack.
struct SimulationControls: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if app.route != nil {
            VStack(spacing: 6) {
                Button {
                    app.togglePlayback()
                } label: {
                    Image(systemName: app.isSimulating ? "stop.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 32)
                        .foregroundStyle(.primary)
                }

                ProgressView(value: app.simulationProgress)
                    .progressViewStyle(.linear)
                    .frame(width: 34)
                    .padding(.bottom, 8)
            }
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
        }
    }
}
