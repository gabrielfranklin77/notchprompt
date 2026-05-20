//
//  PrompterModel.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import Foundation
import Combine
import CoreGraphics

@MainActor
final class PrompterModel: ObservableObject {
    enum ScrollMode: String, CaseIterable {
        case infinite
        case stopAtEnd
    }

    enum CountdownBehavior: String, CaseIterable {
        case always
        case freshStartOnly
        case never

        var label: String {
            switch self {
            case .always:
                return "Always"
            case .freshStartOnly:
                return "Fresh start only"
            case .never:
                return "Never"
            }
        }
    }

    enum Theme: String, CaseIterable {
        case dark
        case light
        case highContrast
        case readingLine

        var label: String {
            switch self {
            case .dark: return "Dark"
            case .light: return "Light"
            case .highContrast: return "High Contrast"
            case .readingLine: return "Reading Line"
            }
        }
    }

    struct PunctuationStop: Equatable {
        let charOffset: Int
        let pauseMs: Int
    }

    static let shared = PrompterModel()

    @Published var script: String = """
Paste your script here.

Tip: Use the menu bar icon to start/pause or reset the scroll.
"""

    @Published var isRunning: Bool = false
    @Published var manualScrollEnabled: Bool = false
    @Published var isOverlayVisible: Bool = true
    @Published var privacyModeEnabled: Bool = true
    @Published private(set) var hasStartedSession: Bool = false
    @Published private(set) var isCountingDown: Bool = false
    @Published var countdownSeconds: Int = 3
    @Published var countdownBehavior: CountdownBehavior = .freshStartOnly
    @Published private(set) var countdownRemaining: Int = 0
    @Published private(set) var didReachEndInStopMode: Bool = false

    // Visual / behavior tuning
    @Published var speedPointsPerSecond: Double = 80
    @Published var fontSize: Double = 20
    @Published var overlayWidth: Double = 600
    @Published var overlayHeight: Double = 150
    // Deprecated user setting: keep as a fixed constant unless changed explicitly in code.
    @Published var backgroundOpacity: Double = 1.0
    @Published var scrollMode: ScrollMode = .infinite
    /// 0 means "auto" (prefer built-in display)
    @Published var selectedScreenID: CGDirectDisplayID = 0
    // Fraction of the viewport height to fade at top and bottom.
    let edgeFadeFraction: Double = 0.20

    // MARK: - Reading aids (Phase 2)
    @Published var theme: Theme = .dark
    @Published var pauseOnPunctuation: Bool = false
    @Published private(set) var punctuationStops: [PunctuationStop] = []
    @Published private(set) var totalCharCount: Int = 0

    // MARK: - Speech auto-sync (Phase 3)
    /// When true, scroll position is driven by speech recognition instead of a timer.
    @Published var autoSyncEnabled: Bool = false
    /// Locale used by the speech recognizer. Persisted to UserDefaults.
    @Published var speechLocaleIdentifier: String = "pt-BR"
    /// Latest matched script-token index, published by SpeechSyncManager.
    @Published var currentSpeechWordIndex: Int = 0
    /// Confidence of the most recent match (0.0 – 1.0). Drives the UI indicator.
    @Published var currentSpeechConfidence: Double = 0
    /// True when SpeechSyncManager has flagged a sustained low-confidence period.
    @Published var isSpeechLostPlace: Bool = false
    /// Normalized tokenization of the current script — shared with the matcher
    /// so we only tokenize once per script change.
    @Published private(set) var scriptTokensForSpeech: [SpeechSyncMatcher.ScriptToken] = []

    // Used to signal an immediate reset to the scrolling view.
    @Published private(set) var resetToken: UUID = UUID()
    @Published private(set) var jumpBackToken: UUID = UUID()
    @Published private(set) var jumpBackDistancePoints: CGFloat = 0
    @Published private(set) var manualScrollToken: UUID = UUID()
    @Published private(set) var manualScrollDeltaPoints: CGFloat = 0
    private(set) var savedScrollPhaseForResume: CGFloat?

    private var countdownTask: Task<Void, Never>?
    private var shouldUseCountdownOnNextStart: Bool = true

    static let speedRange: ClosedRange<Double> = 10...300
    static let speedStep: Double = 5
    static let speedPresetSlow: Double = 55
    static let speedPresetNormal: Double = 85
    static let speedPresetFast: Double = 125

    private enum DefaultsKey {
        static let hasSavedSession = "hasSavedSession"
        static let script = "script"
        static let isRunning = "isRunning"
        static let isOverlayVisible = "isOverlayVisible"
        static let privacyModeEnabled = "privacyModeEnabled"
        static let speed = "speedPointsPerSecond"
        static let fontSize = "fontSize"
        static let overlayWidth = "overlayWidth"
        static let overlayHeight = "overlayHeight"
        static let countdownSeconds = "countdownSeconds"
        static let countdownBehavior = "countdownBehavior"
        static let scrollMode = "scrollMode"
        static let selectedScreenID = "selectedScreenID"
        static let theme = "theme"
        static let pauseOnPunctuation = "pauseOnPunctuation"
        static let speechLocaleIdentifier = "speechLocaleIdentifier"
    }

    private var scriptObserver: AnyCancellable?

    private init() {
        recomputePunctuationStops()
        // Debounced recompute so typing/pasting large scripts doesn't tokenize on every keystroke.
        scriptObserver = $script
            .debounce(for: .milliseconds(120), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.recomputePunctuationStops()
            }
    }

    deinit {
        countdownTask?.cancel()
    }

    func pasteScript(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let wasEmpty = script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        script = text
        if wasEmpty {
            hasStartedSession = true
        }
    }

    func resetScroll() {
        didReachEndInStopMode = false
        shouldUseCountdownOnNextStart = true
        savedScrollPhaseForResume = nil
        resetToken = UUID()
    }

    func saveScrollPhaseForResume(_ phase: CGFloat) {
        savedScrollPhaseForResume = phase
    }

    func jumpBack(seconds: Double = 5) {
        guard seconds > 0 else { return }
        didReachEndInStopMode = false
        jumpBackDistancePoints = CGFloat(speedPointsPerSecond * seconds)
        jumpBackToken = UUID()
    }

    func switchPlaybackModeFromOverlayControl() {
        if isRunning || isCountingDown {
            stop()
            manualScrollEnabled = true
            didReachEndInStopMode = false
            hasStartedSession = true
            shouldUseCountdownOnNextStart = false
            return
        }

        manualScrollEnabled = false
        start()
    }

    func handleManualScroll(deltaPoints: CGFloat) {
        guard abs(deltaPoints) > 0.01 else { return }

        if !manualScrollEnabled {
            manualScrollEnabled = true
        }

        if isRunning || isCountingDown {
            stop()
        }

        didReachEndInStopMode = false
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        manualScrollDeltaPoints = deltaPoints
        manualScrollToken = UUID()
    }

    func toggleRunning() {
        if isRunning || isCountingDown {
            stop()
        } else {
            start()
        }
    }

    func start() {
        if isRunning || isCountingDown {
            return
        }

        manualScrollEnabled = false

        if scrollMode == .stopAtEnd, didReachEndInStopMode {
            // Keyboard "start" from end should restart from the top without requiring manual reset.
            resetScroll()
        }

        let delay = max(0, countdownSeconds)
        let shouldRunCountdown: Bool
        switch countdownBehavior {
        case .always:
            shouldRunCountdown = delay > 0
        case .freshStartOnly:
            shouldRunCountdown = delay > 0 && shouldUseCountdownOnNextStart
        case .never:
            shouldRunCountdown = false
        }
        
        guard shouldRunCountdown else {
            beginRunningNow()
            return
        }
        
        beginCountdown(seconds: delay)
    }

    func markReachedEndInStopMode() {
        guard scrollMode == .stopAtEnd else { return }
        didReachEndInStopMode = true
        stop()
    }

    func setScrollMode(_ newMode: ScrollMode) {
        // Entire transition is deferred to avoid publishing inside SwiftUI view updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let oldMode = self.scrollMode
            guard oldMode != newMode else { return }
            let wasTerminalStopState = (oldMode == .stopAtEnd && self.didReachEndInStopMode)

            self.scrollMode = newMode

            if newMode == .infinite {
                self.didReachEndInStopMode = false
                if wasTerminalStopState {
                    self.hasStartedSession = true
                    self.isCountingDown = false
                    self.countdownRemaining = 0
                    self.countdownTask?.cancel()
                    self.countdownTask = nil
                    self.shouldUseCountdownOnNextStart = false
                    self.isRunning = true
                }
            }
        }
    }

    func stop() {
        countdownTask?.cancel()
        countdownTask = nil
        isCountingDown = false
        countdownRemaining = 0
        isRunning = false
    }

    func setSpeed(_ value: Double) {
        speedPointsPerSecond = clampedSpeed(value)
    }

    func adjustSpeed(delta: Double) {
        let newValue = speedPointsPerSecond + delta
        setSpeed(newValue)
    }

    func applySpeedPreset(_ preset: Double) {
        setSpeed(preset)
    }

    var estimatedReadDuration: TimeInterval {
        let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }

        let words = max(1, trimmed.split(whereSeparator: \.isWhitespace).count)
        // Approximation: 160 words/minute baseline adjusted by current speed.
        let baselineWPM = 160.0
        let speedFactor = speedPointsPerSecond / Self.speedPresetNormal
        let adjustedWPM = max(60, baselineWPM * speedFactor)
        let minutes = Double(words) / adjustedWPM
        return minutes * 60
    }

    func formattedEstimatedReadDuration() -> String {
        let duration = Int(round(estimatedReadDuration))
        guard duration > 0 else { return "~0s" }
        if duration < 60 {
            return "~\(duration)s"
        }
        let minutes = duration / 60
        let seconds = duration % 60
        return String(format: "~%dm %02ds", minutes, seconds)
    }

    func loadFromDefaults() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: DefaultsKey.hasSavedSession) else {
            return
        }

        if let savedScript = defaults.string(forKey: DefaultsKey.script) {
            script = savedScript
        }

        privacyModeEnabled = defaults.object(forKey: DefaultsKey.privacyModeEnabled) as? Bool ?? privacyModeEnabled
        isOverlayVisible = defaults.object(forKey: DefaultsKey.isOverlayVisible) as? Bool ?? true
        // Never auto-start on launch; require explicit user start each session.
        isRunning = false
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = false
        shouldUseCountdownOnNextStart = true
        speedPointsPerSecond = clampedSpeed(defaults.object(forKey: DefaultsKey.speed) as? Double ?? speedPointsPerSecond)
        fontSize = clamp(defaults.object(forKey: DefaultsKey.fontSize) as? Double ?? fontSize, lower: 12, upper: 40)
        overlayWidth = clamp(defaults.object(forKey: DefaultsKey.overlayWidth) as? Double ?? overlayWidth, lower: 400, upper: 1200)
        overlayHeight = clamp(defaults.object(forKey: DefaultsKey.overlayHeight) as? Double ?? overlayHeight, lower: 120, upper: 300)
        // Opacity UI has been removed; always render fully opaque by default.
        backgroundOpacity = 1.0
        defaults.removeObject(forKey: "backgroundOpacity")
        countdownSeconds = Int(clamp(Double(defaults.object(forKey: DefaultsKey.countdownSeconds) as? Int ?? countdownSeconds), lower: 0, upper: 10))
        if let rawValue = defaults.string(forKey: DefaultsKey.countdownBehavior),
           let savedBehavior = CountdownBehavior(rawValue: rawValue) {
            countdownBehavior = savedBehavior
        } else {
            countdownBehavior = .freshStartOnly
        }
        if let rawValue = defaults.string(forKey: DefaultsKey.scrollMode),
           let savedMode = ScrollMode(rawValue: rawValue) {
            scrollMode = savedMode
        } else {
            scrollMode = .infinite
        }
        selectedScreenID = CGDirectDisplayID(defaults.object(forKey: DefaultsKey.selectedScreenID) as? UInt32 ?? 0)
        if let rawTheme = defaults.string(forKey: DefaultsKey.theme),
           let savedTheme = Theme(rawValue: rawTheme) {
            theme = savedTheme
        }
        pauseOnPunctuation = defaults.object(forKey: DefaultsKey.pauseOnPunctuation) as? Bool ?? false
        if let savedLocale = defaults.string(forKey: DefaultsKey.speechLocaleIdentifier) {
            speechLocaleIdentifier = savedLocale
        }
        recomputePunctuationStops()
    }

    func saveToDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: DefaultsKey.hasSavedSession)
        defaults.set(script, forKey: DefaultsKey.script)
        defaults.set(isRunning, forKey: DefaultsKey.isRunning)
        defaults.set(isOverlayVisible, forKey: DefaultsKey.isOverlayVisible)
        defaults.set(privacyModeEnabled, forKey: DefaultsKey.privacyModeEnabled)
        defaults.set(speedPointsPerSecond, forKey: DefaultsKey.speed)
        defaults.set(fontSize, forKey: DefaultsKey.fontSize)
        defaults.set(overlayWidth, forKey: DefaultsKey.overlayWidth)
        defaults.set(overlayHeight, forKey: DefaultsKey.overlayHeight)
        defaults.set(countdownSeconds, forKey: DefaultsKey.countdownSeconds)
        defaults.set(countdownBehavior.rawValue, forKey: DefaultsKey.countdownBehavior)
        defaults.set(scrollMode.rawValue, forKey: DefaultsKey.scrollMode)
        defaults.set(selectedScreenID, forKey: DefaultsKey.selectedScreenID)
        defaults.set(theme.rawValue, forKey: DefaultsKey.theme)
        defaults.set(pauseOnPunctuation, forKey: DefaultsKey.pauseOnPunctuation)
        defaults.set(speechLocaleIdentifier, forKey: DefaultsKey.speechLocaleIdentifier)
    }

    private func beginCountdown(seconds: Int) {
        countdownTask?.cancel()
        isCountingDown = true
        countdownRemaining = seconds

        countdownTask = Task { @MainActor in
            var remaining = seconds
            while remaining > 0 {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    isCountingDown = false
                    countdownRemaining = 0
                    countdownTask = nil
                    return
                }
                remaining -= 1
                countdownRemaining = remaining
            }

            guard !Task.isCancelled else { return }
            beginRunningNow()
            countdownTask = nil
        }
    }
    
    private func beginRunningNow() {
        isCountingDown = false
        countdownRemaining = 0
        hasStartedSession = true
        shouldUseCountdownOnNextStart = false
        isRunning = true
    }

    private func clampedSpeed(_ value: Double) -> Double {
        let clamped = clamp(value, lower: Self.speedRange.lowerBound, upper: Self.speedRange.upperBound)
        let step = Self.speedStep
        return (clamped / step).rounded() * step
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    /// Scans the current script for sentence/clause boundaries that should
    /// trigger a brief pause during auto-scroll. Called once on init and on
    /// every debounced change to `script` via the Combine observer. The
    /// `charOffset` is a Unicode-scalar index because the rendering text
    /// uses a monospaced font and we map scroll phase → offset linearly.
    private func recomputePunctuationStops() {
        let scalars = Array(script.unicodeScalars)
        var stops: [PunctuationStop] = []
        stops.reserveCapacity(scalars.count / 8)

        let period: Unicode.Scalar = "."
        let exclamation: Unicode.Scalar = "!"
        let question: Unicode.Scalar = "?"
        let comma: Unicode.Scalar = ","
        let semicolon: Unicode.Scalar = ";"
        let colon: Unicode.Scalar = ":"
        let newline: Unicode.Scalar = "\n"
        let emDash = Unicode.Scalar(0x2014)! // —

        for (idx, c) in scalars.enumerated() {
            let pauseMs: Int
            switch c {
            case period, exclamation, question:
                pauseMs = 400
            case comma, semicolon, colon:
                pauseMs = 150
            case emDash:
                pauseMs = 200
            case newline:
                pauseMs = (idx + 1 < scalars.count && scalars[idx + 1] == newline) ? 600 : 0
            default:
                pauseMs = 0
            }
            if pauseMs > 0 {
                stops.append(.init(charOffset: idx, pauseMs: pauseMs))
            }
        }

        punctuationStops = stops
        totalCharCount = scalars.count

        // Recompute the speech-sync token list whenever the script changes so the
        // SpeechSyncManager always sees the freshest tokenization without us
        // having to wire a second debounce path.
        scriptTokensForSpeech = SpeechSyncMatcher.tokenizeScript(script)
    }
}
