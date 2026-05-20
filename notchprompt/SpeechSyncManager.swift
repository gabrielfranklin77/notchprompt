//
//  SpeechSyncManager.swift
//  notchprompt
//
//  Glue between SFSpeechRecognizer / AVAudioEngine and SpeechSyncMatcher.
//  Publishes `currentWordIndex`, `matchConfidence`, and `state` so the
//  teleprompter UI can follow along and surface "lost place" warnings.
//
//  Key behaviors:
//  - On-device recognition only (audio never leaves the Mac)
//  - Auto-refreshes the SFSpeech session every ~50s to dodge the 60s cap
//  - Pinned to the built-in mic when available (avoids the mic that Zoom/Meet uses)
//

import AVFoundation
import Combine
import Foundation
import Speech

@MainActor
final class SpeechSyncManager: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case denied(reason: String)
        case unavailable(reason: String)
        case active
        case lostPlace
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentWordIndex: Int = 0
    @Published private(set) var matchConfidence: Double = 0
    @Published private(set) var isAvailable: Bool = false

    /// Locale used by SFSpeechRecognizer. Defaults to the user's preferred app
    /// language with pt-BR / en-US fallback.
    var locale: Locale {
        didSet {
            if state == .active {
                Task { await restart() }
            }
        }
    }

    private var recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sessionRefreshTimer: Timer?
    private var lostPlaceTimer: Timer?

    private var scriptTokens: [SpeechSyncMatcher.ScriptToken] = []
    private var lastConfidentMatchAt: Date = .distantPast

    private static let sessionRefreshInterval: TimeInterval = 50  // SFSpeech hard cap is 60s
    private static let lostPlaceThreshold: TimeInterval = 3       // seconds of low-confidence before warning
    private static let confidenceFloor: Double = 0.55

    init(locale: Locale = Locale(identifier: "pt-BR")) {
        self.locale = locale
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.isAvailable = (recognizer?.isAvailable ?? false) && SFSpeechRecognizer.authorizationStatus() != .denied
    }

    // MARK: - Permissions

    /// Returns `true` if both Speech and Microphone permissions are granted.
    func requestPermissions() async -> Bool {
        state = .requestingPermission

        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            state = .denied(reason: speechReason(for: speechStatus))
            return false
        }

        let micGranted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }

        guard micGranted else {
            state = .denied(reason: "Microphone access not granted")
            return false
        }

        state = .idle
        return true
    }

    private func speechReason(for status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .denied:        return "Speech recognition denied in System Settings"
        case .restricted:    return "Speech recognition restricted (parental controls?)"
        case .notDetermined: return "Speech recognition permission not yet granted"
        case .authorized:    return "Authorized"
        @unknown default:    return "Unknown authorization state"
        }
    }

    // MARK: - Lifecycle

    /// Starts the speech recognition loop. Caller should `await requestPermissions()`
    /// first; calling start without permissions transitions to `.denied`.
    func start(scriptTokens tokens: [SpeechSyncMatcher.ScriptToken], startIndex: Int = 0) async {
        guard !tokens.isEmpty else {
            state = .unavailable(reason: "Empty script")
            return
        }

        // Re-check permissions and availability.
        if SFSpeechRecognizer.authorizationStatus() != .authorized {
            let ok = await requestPermissions()
            guard ok else { return }
        }

        guard let recognizer, recognizer.isAvailable else {
            state = .unavailable(reason: "Speech recognizer not available for \(locale.identifier)")
            return
        }
        guard recognizer.supportsOnDeviceRecognition else {
            state = .unavailable(reason: "On-device recognition unsupported for \(locale.identifier). Try a different locale.")
            return
        }

        scriptTokens = tokens
        currentWordIndex = max(0, min(startIndex, tokens.count - 1))
        matchConfidence = 0
        lastConfidentMatchAt = Date()

        do {
            try startSession()
            state = .active
            scheduleSessionRefresh()
            scheduleLostPlaceCheck()
        } catch {
            state = .unavailable(reason: "Audio engine failed: \(error.localizedDescription)")
        }
    }

    func stop() {
        sessionRefreshTimer?.invalidate()
        sessionRefreshTimer = nil
        lostPlaceTimer?.invalidate()
        lostPlaceTimer = nil

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        state = .idle
        matchConfidence = 0
    }

    private func restart() async {
        let previousIndex = currentWordIndex
        let previousTokens = scriptTokens
        stop()
        await start(scriptTokens: previousTokens, startIndex: previousIndex)
    }

    // MARK: - SFSpeech session

    private func startSession() throws {
        guard let recognizer else {
            throw NSError(domain: "SpeechSyncManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No recognizer for locale"])
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        if #available(macOS 13.0, *) {
            request.addsPunctuation = false
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                Task { @MainActor in
                    self.handlePartial(transcript: result.bestTranscription.formattedString)
                }
            }
            if error != nil || (result?.isFinal ?? false) {
                Task { @MainActor in
                    // Either the session expired or hit an error — the refresh
                    // timer will rebuild the session.
                    self.recognitionTask = nil
                }
            }
        }
    }

    private func scheduleSessionRefresh() {
        sessionRefreshTimer?.invalidate()
        sessionRefreshTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .active else { return }
                self.recognitionTask?.finish()
                self.recognitionTask = nil
                self.audioEngine.inputNode.removeTap(onBus: 0)
                self.audioEngine.stop()
                self.recognitionRequest?.endAudio()
                self.recognitionRequest = nil
                do {
                    try self.startSession()
                } catch {
                    self.state = .unavailable(reason: "Session refresh failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func scheduleLostPlaceCheck() {
        lostPlaceTimer?.invalidate()
        lostPlaceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .active || self.state == .lostPlace else { return }
                let elapsed = Date().timeIntervalSince(self.lastConfidentMatchAt)
                if elapsed > Self.lostPlaceThreshold {
                    if self.state != .lostPlace {
                        self.state = .lostPlace
                    }
                } else if self.state == .lostPlace {
                    self.state = .active
                }
            }
        }
    }

    // MARK: - Matching

    private func handlePartial(transcript: String) {
        guard !scriptTokens.isEmpty else { return }
        let tail = SpeechSyncMatcher.tokenizeTranscript(transcript)
        guard !tail.isEmpty else { return }

        let match = SpeechSyncMatcher.bestAlignment(
            scriptTokens: scriptTokens,
            transcriptTail: tail,
            cursor: currentWordIndex
        )

        guard let match else { return }
        matchConfidence = match.confidence

        // Only advance the cursor when confidence is comfortably above the floor.
        // Below it, hold the current position and let lostPlaceTimer flip state.
        if match.confidence >= Self.confidenceFloor && match.scriptTokenIndex > currentWordIndex {
            currentWordIndex = match.scriptTokenIndex
            lastConfidentMatchAt = Date()
            if state == .lostPlace {
                state = .active
            }
        } else if match.confidence >= Self.confidenceFloor {
            // Confident but didn't advance — still resets the lost-place clock.
            lastConfidentMatchAt = Date()
        }
    }
}
