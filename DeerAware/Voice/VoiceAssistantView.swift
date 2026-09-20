import SwiftUI

struct VoiceAssistantView: View {
    @Environment(AppModel.self) private var app
    @Binding var isPresented: Bool
    @State private var assistant = VoiceAssistant()

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DeerAware Assistant")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(stateLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                        .animation(.default, value: assistant.state)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Text(displayText)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.default, value: displayText)

            Button { micTapped() } label: {
                Image(systemName: micIconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(micColor)
                    .clipShape(Circle())
                    .shadow(color: micColor.opacity(0.45), radius: assistant.state == .listening ? 10 : 3)
            }
            .animation(.easeInOut(duration: 0.2), value: assistant.state)
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .onAppear {
            assistant.configureEngine(app.engine)
            assistant.context = .build(from: app)
            if assistant.permissionState == .notDetermined {
                Task {
                    await assistant.requestPermissions()
                    if assistant.permissionState == .authorized {
                        assistant.startListening()
                    }
                }
            } else if assistant.permissionState == .authorized {
                assistant.startListening()
            }
        }
        .onDisappear { assistant.cancel() }
    }

    private var displayText: String {
        if case .listening = assistant.state, !assistant.liveTranscript.isEmpty {
            return assistant.liveTranscript
        }
        return assistant.messages.last?.text ?? ""
    }

    private var stateLabel: String {
        switch assistant.state {
        case .idle:           return "Tap mic to speak"
        case .listening:      return "Listening…"
        case .thinking:       return "Thinking…"
        case .speaking:       return "Speaking…"
        case .error:          return "Tap mic to try again"
        }
    }

    private var micIconName: String {
        switch assistant.state {
        case .listening:      return "waveform"
        case .thinking:       return "ellipsis"
        case .speaking:       return "speaker.wave.2.fill"
        case .idle, .error:   return "mic.fill"
        }
    }

    private var micColor: Color {
        switch assistant.state {
        case .listening:      return .red
        case .thinking:       return .orange
        case .speaking:       return .blue
        case .idle, .error:   return .blue
        }
    }

    private func micTapped() {
        assistant.context = .build(from: app)
        switch assistant.state {
        case .listening:
            assistant.stopListening()
        case .speaking:
            // Interrupt: stop speaking and immediately listen for next question
            assistant.stopSpeaking()
            assistant.startListening()
            return
        case .thinking:
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
