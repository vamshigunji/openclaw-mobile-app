import AVFoundation
import Foundation
import Observation
import Speech

/// Pure state machine behind the mic button (design §4.3). The recognizer/audio plumbing
/// lives in `SpeechDictation`; this reducer is what the tests pin.
struct DictationState: Equatable {
    enum Phase: Equatable { case idle, requesting, listening, finishing, denied, failed(String) }
    enum Event: Equatable {
        case tapMic                       // idle → requesting; listening → finishing
        case permission(granted: Bool)    // requesting → listening | denied
        case partial(String)              // listening: replace the dictated span
        case final(String)                // listening | finishing → idle
        case error(String)                // → failed
        case reset                        // denied | failed → idle
    }

    private(set) var phase: Phase = .idle
    /// The draft as it was when dictation started; typed text is never touched.
    private(set) var prefix = ""

    var isActive: Bool { phase == .requesting || phase == .listening || phase == .finishing }

    /// Applies `event` and returns the draft to display.
    mutating func apply(_ event: Event, draft: String) -> String {
        switch (phase, event) {
        case (.idle, .tapMic):
            phase = .requesting
            prefix = draft
            return draft
        case (.requesting, .permission(let granted)):
            phase = granted ? .listening : .denied
            return draft
        case (.listening, .partial(let text)), (.finishing, .partial(let text)):
            return compose(text)
        case (.listening, .tapMic):
            phase = .finishing
            return draft
        case (.listening, .final(let text)), (.finishing, .final(let text)):
            phase = .idle
            return compose(text)
        case (_, .error(let message)):
            phase = .failed(message)
            return draft
        case (.denied, .reset), (.failed, .reset):
            phase = .idle
            return draft
        default:
            return draft
        }
    }

    private func compose(_ transcript: String) -> String {
        guard !prefix.isEmpty else { return transcript }
        let needsSpace = !(prefix.last?.isWhitespace ?? true)
        return prefix + (needsSpace ? " " : "") + transcript
    }
}

/// Mic-button runtime: permissions, audio engine, on-device recognition when available.
/// Every transition goes through `DictationState`; the composer reads `state` and `hint`.
@MainActor
@Observable
final class SpeechDictation {
    static let deniedHint = "Enable microphone & speech in Settings to dictate."

    private(set) var state = DictationState()
    /// Inline hint when permission is denied or recognition fails.
    private(set) var hint: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var update: ((String) -> Void)?
    @ObservationIgnored private var draft = ""
    @ObservationIgnored private var transcript = ""

    var isListening: Bool { state.phase == .listening }

    /// Tap the mic: start (after asking permission) or stop dictation. `update` receives
    /// the draft to display after every recognized partial.
    func toggle(draft current: String, update: @escaping (String) -> Void) {
        self.update = update
        draft = current
        hint = nil
        switch state.phase {
        case .idle, .denied, .failed:
            if state.phase != .idle { push(.reset) }
            transcript = ""
            push(.tapMic)
            Task { await requestPermissionsAndStart() }
        case .listening:
            push(.tapMic) // → finishing; the recognizer's final result (or its end) closes it
            request?.endAudio()
        case .requesting, .finishing:
            break
        }
    }

    private func push(_ event: DictationState.Event) {
        draft = state.apply(event, draft: draft)
        update?(draft)
        switch state.phase {
        case .denied: hint = Self.deniedHint
        case .failed(let message): hint = message
        default: break
        }
    }

    private func requestPermissionsAndStart() async {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        let microphone = await AVAudioApplication.requestRecordPermission()
        let granted = speech == .authorized && microphone
        push(.permission(granted: granted))
        guard granted else { return }
        do {
            try startEngine()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func startEngine() throws {
        guard let recognizer, recognizer.isAvailable else {
            throw NSError(domain: "SpeechDictation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Speech recognition is unavailable on this device."])
        }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        engine.prepare()
        try engine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let result {
                    let text = result.bestTranscription.formattedString
                    transcript = text
                    push(result.isFinal ? .final(text) : .partial(text))
                    if result.isFinal { teardown() }
                } else if error != nil {
                    // Our own stop ends audio; the recognizer may report that as an error.
                    if state.phase == .finishing {
                        push(.final(transcript))
                        teardown()
                    } else {
                        fail(error?.localizedDescription ?? "Speech recognition failed.")
                    }
                }
            }
        }
    }

    private func fail(_ message: String) {
        teardown()
        push(.error(message))
    }

    private func teardown() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request = nil
        task?.cancel()
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
