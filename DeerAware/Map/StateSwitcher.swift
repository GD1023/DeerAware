import SwiftUI

struct StateSwitcher: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(app.engine.stateNames, id: \.self) { state in
                    Button(state) {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            app.selectedStateName = state
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(
                        app.selectedStateName == state
                            ? Color.accentColor
                            : Color.primary.opacity(0.04)
                    )
                    .foregroundStyle(
                        app.selectedStateName == state ? Color.white : Color.primary
                    )
                    .clipShape(Capsule())
                    .animation(.easeInOut(duration: 0.2), value: app.selectedStateName)
                }
            }
            .padding(.horizontal)
        }
    }
}
