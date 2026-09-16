//
//  VoiceAssistantView.swift
//  DeerAware
//
//  Chat-style sheet for the on-device voice assistant. Visual language
//  matches Map/RouteControls.swift and Map/LegendView.swift: dark cards,
//  white text, Capsule/RoundedRectangle shapes, ultraThinMaterial chrome.
//

import SwiftUI

struct VoiceAssistantView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var assistant = VoiceAssistant()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black.opacity(0.94), Color.black.opacity(0.82)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                transcriptScroll
                if let banner = statusBannerText {
                    statusBanner(banner)
                }
                if case .listening = assistant.state, !assistant.liveTranscript.isEmpty {
                    liveTranscriptBubble
                }
                controls
            }
        }
        .onAppear {
            assistant.configureEngine(app.engine)
            assistant.context = .build(from: app)
            if assistant.permissionState == .notDetermined {
                Task { await assistant.requestPermissions() }
            }
        }
        .onDisappear {
            assistant.cancel()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice Assistant")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(assistant.isModelAvailable ? "On-device AI" : "Quick-answer mode")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Transcript

    private var transcriptScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if assistant.messages.isEmpty {
                        emptyState
                    }
                    ForEach(assistant.messages) { message in
                        ChatBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }
            .onChange(of: assistant.messages.count) { _, _ in
                guard let last = assistant.messages.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask about deer risk")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Text("Try \u{201c}how risky is my route\u{201d}, \u{201c}when should I leave\u{201d}, or \u{201c}is it risky here right now\u{201d}.")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var liveTranscriptBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(assistant.liveTranscript)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.blue.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .transition(.opacity)
    }

    // MARK: - Status banner

    private var statusBannerText: String? {
        switch assistant.permissionState {
        case .denied:
            return "Microphone / speech recognition access denied. Enable in Settings > Privacy to talk to DeerAware."
        default:
            break
        }
        if case .error(let message) = assistant.state {
            return message
        }
        if !assistant.isModelAvailable {
            return "Apple Intelligence isn't available on this device - using quick, rule-based answers instead of free-form conversation."
        }
        return nil
    }

    private func statusBanner(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal, 16)
            .padding(.top, 8)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.65))

            HStack(spacing: 24) {
                if assistant.state == .thinking || assistant.state == .speaking {
                    Button {
                        assistant.cancel()
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }

                micButton
            }
        }
        .padding(.top, 10)
        .padding(.bottom, 24)
    }

    private var micButton: some View {
        Button {
            micTapped()
        } label: {
            Image(systemName: micIconName)
                .font(.system(size: 28))
                .foregroundStyle(.white)
                .frame(width: 74, height: 74)
                .background(micColor)
                .clipShape(Circle())
                .shadow(color: micColor.opacity(0.55), radius: assistant.state == .listening ? 14 : 6)
        }
        .animation(.easeInOut(duration: 0.2), value: assistant.state)
    }

    private var micIconName: String {
        switch assistant.state {
        case .listening: return "waveform"
        case .thinking: return "ellipsis"
        case .speaking: return "speaker.wave.2.fill"
        case .idle, .error: return "mic.fill"
        }
    }

    private var micColor: Color {
        switch assistant.state {
        case .listening: return .red
        case .thinking: return .orange
        case .speaking: return .blue
        case .idle, .error: return .accentColor
        }
    }

    private var stateLabel: String {
        switch assistant.state {
        case .idle: return "Tap to speak"
        case .listening: return "Listening\u{2026}"
        case .thinking: return "Thinking\u{2026}"
        case .speaking: return "Speaking\u{2026} (tap stop to interrupt)"
        case .error: return "Tap to try again"
        }
    }

    private func micTapped() {
        assistant.context = .build(from: app)
        switch assistant.state {
        case .listening:
            assistant.stopListening()
        case .thinking, .speaking:
            assistant.cancel()
        case .idle, .error:
            if assistant.permissionState == .authorized {
                assistant.startListening()
            } else {
                Task {
                    await assistant.requestPermissions()
                    if assistant.permissionState == .authorized {
                        assistant.startListening()
                    }
                }
            }
        }
    }
}

// MARK: - Chat bubble

private struct ChatBubble: View {
    let message: VoiceChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            Text(message.text)
                .font(.subheadline)
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(message.role == .user ? Color.blue.opacity(0.55) : Color.black.opacity(0.62))
                .clipShape(RoundedRectangle(cornerRadius: 16))
            if message.role == .assistant { Spacer(minLength: 40) }
        }
    }
}
