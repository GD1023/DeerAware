import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel
    // On-device voice assistant (DeerAware/Voice/) - presented as a sheet from the floating mic button below.
    @State private var showVoiceAssistant = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    howItWorksSection
                    coverageCard
                    CurrentConditionsCard()
                    disclaimerCard
                    openMapButton
                }
                .padding(.bottom)
            }
            .navigationTitle("DeerAware")
            .navigationBarTitleDisplayMode(.large)
            .overlay(alignment: .bottomTrailing) {
                voiceAssistantButton
            }
        }
        .sheet(isPresented: $showVoiceAssistant) {
            VoiceAssistantView()
        }
    }

    private var voiceAssistantButton: some View {
        Button {
            showVoiceAssistant = true
        } label: {
            Image(systemName: "mic.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
        }
        .padding(.trailing, 20)
        .padding(.bottom, 20)
        .accessibilityLabel("Voice assistant")
    }

    // MARK: Sections

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DeerAware")
                .font(.largeTitle).fontWeight(.bold)
            Text("Where deer-vehicle collisions cluster, and when the risk peaks — for 9 US states.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding()
    }

    private var howItWorksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it works")
                .font(.headline)
                .padding(.horizontal)

            InfoCard(symbol: "map.fill", title: "Places") {
                Text("A heatmap built from ~440,000 recorded deer-vehicle collisions (1994–2021). Brighter = more collisions historically.")
            }
            InfoCard(symbol: "calendar", title: "Season") {
                Text("Risk more than doubles in the rut: **October–December**, peaking in **November (~2.2×)**.")
            }
            InfoCard(symbol: "sunset.fill", title: "Time of day") {
                Text("Risk peaks around **dusk and the two hours after** (~2.3×), and is lowest mid-morning.")
            }
        }
    }

    private var coverageCard: some View {
        InfoCard(symbol: "map.circle", title: "Coverage") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connecticut · Georgia · Iowa · Kansas · Maryland · Massachusetts · South Carolina · Texas · Wyoming")
                Text("No data outside these states.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var disclaimerCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Based on historical reports, which also reflect where traffic is heaviest. This is context, not a live deer detector — keep your eyes on the road.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }

    private var openMapButton: some View {
        Button {
            appModel.selectedTab = 1
        } label: {
            Label("Open the map", systemImage: "map")
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.accentColor)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal)
    }
}

// MARK: - Reusable card

private struct InfoCard<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                content().font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal)
    }
}
