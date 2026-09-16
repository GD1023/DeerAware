//
//  VoiceAssistant.swift
//  DeerAware
//
//  An embedded, fully on-device voice assistant: Apple's `Speech` framework
//  for speech-to-text, Apple's on-device `FoundationModels` framework
//  (iOS 26+, Apple Intelligence) as the "embedded foundational model" that
//  generates conversational answers, and `AVSpeechSynthesizer` for
//  text-to-speech. Nothing here calls the network - audio, transcripts, and
//  model inference all stay on the device, matching the rest of the app.
//
//  ============================================================================
//  REQUIRED Info.plist entries - this repo has no committed Info.plist (the
//  Xcode project file isn't checked in), so add these keys in Xcode's
//  target -> Info tab (or directly in Info.plist) before running:
//
//    NSSpeechRecognitionUsageDescription
//        e.g. "DeerAware uses speech recognition so you can ask about deer
//        collision risk on your route by voice."
//    NSMicrophoneUsageDescription
//        e.g. "DeerAware needs the microphone to hear your questions."
//    NSLocationWhenInUseUsageDescription
//        Almost certainly already present for the existing map / current-
//        conditions features - just confirm it's there. The voice
//        assistant's "risk near me" tool reuses it for a one-shot location
//        fetch (see `OneShotLocationFetcher` in DeerAwareTools.swift).
//  ============================================================================
//

import Foundation
import SwiftUI
import Speech
import AVFoundation
import CoreLocation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Chat transcript

struct VoiceChatMessage: Identifiable, Equatable {
    enum Role { case user, assistant }
    let id = UUID()
    let role: Role
    let text: String
}

// MARK: - Voice state machine

enum VoiceState: Equatable {
    case idle
    case listening
    case thinking
    case speaking
    case error(String)
}

enum VoicePermissionState {
    case notDetermined, authorized, denied
}

/// The voice assistant engine: owns speech recognition, the on-device
/// language model session (when available), the rule-based fallback, and
/// speech synthesis. `VoiceAssistantView` drives this and renders `state` /
/// `messages`. Kept on the main actor since it directly touches UI-observed
/// `@Observable` state from async callbacks.
@MainActor
@Observable
final class VoiceAssistant: NSObject {

    // MARK: Observable state
    var state: VoiceState = .idle
    var messages: [VoiceChatMessage] = []
    var liveTranscript: String = ""
    var permissionState: VoicePermissionState = .notDetermined
    /// Whether FoundationModels + Apple Intelligence are available on this device right now.
    var isModelAvailable: Bool = false
    /// True while the *last* answer came from the on-device LLM; false when the
    /// rule-based fallback produced it (surfaced in the UI as "quick-answer mode").
    var usingLanguageModel: Bool = false

    /// Plain-data snapshot of AppModel-derived state, refreshed by the view each turn
    /// so tools/rules can answer about the active route without this file touching
    /// AppModel's source files directly.
    var context = DeerAwareContext.empty {
        didSet { contextStore.context = context }
    }

    let contextStore = DeerAwareContextStore()

    func configureEngine(_ engine: DVCRiskModel) {
        contextStore.engine = engine
    }

    // MARK: Speech recognition
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?

    // MARK: Speech synthesis
    private let synthesizer = AVSpeechSynthesizer()

    // MARK: FoundationModels session, created lazily once the model is known to be available.
    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private var languageSession: LanguageModelSession? {
        get { _languageSessionBox as? LanguageModelSession }
        set { _languageSessionBox = newValue }
    }
    #endif
    private var _languageSessionBox: Any?

    override init() {
        super.init()
        synthesizer.delegate = self
        evaluateModelAvailability()
    }

    // MARK: - Availability

    private func evaluateModelAvailability() {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            isModelAvailable = SystemLanguageModel.default.availability == .available
        } else {
            isModelAvailable = false
        }
        #else
        isModelAvailable = false
        #endif
    }

    // MARK: - Permissions

    func requestPermissions() async {
        let speechOK = await requestSpeechAuthorization()
        let micOK = await requestMicrophoneAuthorization()
        permissionState = (speechOK && micOK) ? .authorized : .denied
    }

    private func requestSpeechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
        @unknown default: return false
        }
    }

    private func requestMicrophoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { cont in
                session.requestRecordPermission { granted in
                    cont.resume(returning: granted)
                }
            }
        @unknown default: return false
        }
    }

    // MARK: - Listening

    func startListening() {
        stopSpeaking()
        guard permissionState == .authorized else {
            state = .error("Microphone and speech recognition access are needed. Enable them in Settings > Privacy.")
            return
        }
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            state = .error("Speech recognition isn't available right now.")
            return
        }

        do {
            try configureAudioSession()
        } catch {
            state = .error("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Force on-device recognition when the recognizer supports it, so no
        // audio or transcript ever leaves the phone - matches the app's
        // fully-offline philosophy, not just a nice-to-have.
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            state = .error("Couldn't start the microphone: \(error.localizedDescription)")
            return
        }

        liveTranscript = ""
        state = .listening

        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.state == .listening else { return }
                if let result {
                    self.liveTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finishListening(transcript: result.bestTranscription.formattedString)
                    }
                } else if error != nil {
                    // Recognition errors (including routine "no speech detected") end the
                    // turn using whatever partial transcript we already have.
                    self.stopAudioEngine()
                    if !self.liveTranscript.isEmpty {
                        self.finishListening(transcript: self.liveTranscript)
                    } else {
                        self.state = .idle
                    }
                }
            }
        }
    }

    func stopListening() {
        guard state == .listening else { return }
        recognitionRequest?.endAudio()
        stopAudioEngine()
        if !liveTranscript.isEmpty {
            finishListening(transcript: liveTranscript)
        } else {
            state = .idle
        }
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func finishListening(transcript: String) {
        stopAudioEngine()
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { state = .idle; return }
        messages.append(VoiceChatMessage(role: .user, text: text))
        Task { await respond(to: text) }
    }

    /// Stops listening/speaking and resets to idle - used by the mic button
    /// (tap again to cancel) and when the assistant sheet is dismissed.
    func cancel() {
        stopAudioEngine()
        stopSpeaking()
        state = .idle
        liveTranscript = ""
    }

    // MARK: - Responding

    private func respond(to question: String) async {
        state = .thinking
        let answer: String
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *), isModelAvailable {
            answer = await respondUsingLanguageModel(question: question)
        } else {
            answer = respondUsingRules(question: question)
        }
        #else
        answer = respondUsingRules(question: question)
        #endif
        messages.append(VoiceChatMessage(role: .assistant, text: answer))
        speak(answer)
    }

    #if canImport(FoundationModels)
    @available(iOS 26.0, *)
    private func respondUsingLanguageModel(question: String) async -> String {
        usingLanguageModel = true
        do {
            let session = currentLanguageSession()
            let response = try await session.respond(to: question)
            return response.content
        } catch {
            // Model call failed at runtime (e.g. guardrail refusal, context
            // window exceeded) - degrade to the deterministic path rather
            // than surfacing an error mid-conversation.
            return respondUsingRules(question: question)
        }
    }

    @available(iOS 26.0, *)
    private func currentLanguageSession() -> LanguageModelSession {
        if let existing = languageSession { return existing }
        // `Instructions` conforms to ExpressibleByStringInterpolation, so a
        // plain string literal is the most stable way to construct one -
        // avoids depending on the exact shape of its result-builder API.
        let instructions: Instructions = """
            You are the DeerAware voice assistant, embedded in an iOS app that estimates \
            deer-vehicle collision (DVC) risk from historical collision data, season, and \
            time of day, for nine US states: Connecticut, Georgia, Iowa, Kansas, Maryland, \
            Massachusetts, South Carolina, Texas, and Wyoming.

            Only answer questions about deer-vehicle collision risk, driving routes, timing \
            (season and dusk effects, best time to leave), hotspots on the active route, and \
            how the app itself works. If asked about anything else, briefly decline and steer \
            back to what you can help with.

            Keep answers to two or three short sentences - they are spoken aloud. Use the \
            provided tools to look up live risk and route data instead of guessing numbers. \
            Never claim certainty that a deer is actually present; this is a statistical risk \
            estimate from historical data, not a live detector.
            """
        let tools: [any Tool] = [
            CurrentRiskTool(store: contextStore),
            RouteSummaryTool(store: contextStore)
        ]
        let session = LanguageModelSession(tools: tools, instructions: instructions)
        languageSession = session
        return session
    }
    #endif

    /// Non-LLM fallback: deterministic keyword matching over the transcript,
    /// answered from the same AppModel-derived `context` the tools use. This
    /// keeps voice interaction functional on any device - just without
    /// free-form conversation - when FoundationModels/Apple Intelligence
    /// isn't available (pre-iOS 26, ineligible hardware, or the feature
    /// disabled in Settings).
    private func respondUsingRules(question: String) -> String {
        usingLanguageModel = false
        let q = question.lowercased()
        let ctx = context

        if q.contains("hotspot") {
            return ctx.hotspotSummary
        }
        if q.contains("when") || q.contains("leave") || q.contains("depart") || q.contains("best time") {
            return ctx.departureSummary
        }
        if q.contains("how long") || q.contains("travel time") || q.contains("duration") {
            return ctx.travelTimeSummary
        }
        if q.contains("route") || q.contains("trip") || q.contains("distance") {
            return ctx.routeSummary
        }
        if q.contains("safe") || q.contains("risk") || q.contains("deer") {
            return ctx.riskSummary
        }
        return "I can tell you about deer collision risk, your route's hotspots, or the best time to leave. Try asking \"how risky is my route\" or \"when should I leave.\""
    }

    // MARK: - Speaking

    private func speak(_ text: String) {
        guard !text.isEmpty else { state = .idle; return }
        state = .speaking
        do {
            try configureAudioSession()
        } catch {
            state = .idle
            return
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Audio session
    // Shared by both recording and playback (one category, `.playAndRecord`)
    // so starting TTS never fights an in-progress microphone session, per
    // Apple's guidance for apps that both listen and speak.

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .allowBluetooth, .defaultToSpeaker])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - AVSpeechSynthesizerDelegate

extension VoiceAssistant: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
        }
    }
}
