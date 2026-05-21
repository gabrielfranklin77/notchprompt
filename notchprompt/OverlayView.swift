//
//  OverlayView.swift
//  notchprompt
//
//  Created by Saif on 2026-02-08.
//

import AppKit
import SwiftUI

private extension Color {
    /// `#000000` (darkest black for seamless notch blending)
    static let notchBlack = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1.0)
}

/// MacBook-style notch contour:
/// - flat top edge with square top corners
/// - straight side walls
/// - rounded lower corners
private struct AppleNotchShape: InsettableShape {
    /// Lower corner radius relative to height.
    var bottomCornerRadiusRatio: CGFloat = 0.18
    /// Portion of total height used by the straight side wall.
    var sideWallDepthRatio: CGFloat = 0.82
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        let w = r.width
        let h = r.height

        // sideWallDepthRatio controls how much vertical wall exists before lower arcs.
        let depthRatio = max(0.60, min(sideWallDepthRatio, 0.95))
        let lowerArcStartY = r.minY + (h * depthRatio)
        let maxBottomRadiusFromDepth = max(0, r.maxY - lowerArcStartY)
        let maxBottomRadiusFromWidth = w * 0.5
        let targetBottomRadius = h * bottomCornerRadiusRatio
        let bottomRadius = max(
            0,
            min(targetBottomRadius, min(maxBottomRadiusFromDepth, maxBottomRadiusFromWidth))
        )

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))

        // Right side wall into large lower corner.
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - bottomRadius))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.maxX - bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(0),
                endAngle: .degrees(90),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX + bottomRadius, y: r.maxY))
        if bottomRadius > 0 {
            p.addArc(
                center: CGPoint(x: r.minX + bottomRadius, y: r.maxY - bottomRadius),
                radius: bottomRadius,
                startAngle: .degrees(90),
                endAngle: .degrees(180),
                clockwise: false
            )
        } else {
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        }

        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()

        return p
    }

    func inset(by amount: CGFloat) -> some InsettableShape {
        var s = self
        s.insetAmount += amount
        return s
    }
}

struct OverlayView: View {
    @ObservedObject var model: PrompterModel

    var body: some View {
        // Ratio-driven contour tuned to Apple notch geometry and scaled to the
        // current overlay dimensions.
        let shape = AppleNotchShape()
        let hideTopStrokeHeight: CGFloat = 2

        ZStack {
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow)
                .clipShape(shape)
                // Blur can brighten the surface; keep it effectively off for notch matching.
                .opacity(0.0)

            shape
                .fill(themeBackgroundFill)

            shape
                .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                // Hard-cut the stroke off at the very top so the edge blends into the notch.
                .mask(
                    VStack(spacing: 0) {
                        Color.clear.frame(height: hideTopStrokeHeight)
                        Color.white
                    }
                )

            // The scroller is hard-clipped (so text truly "cuts off") and we add
            // subtle blur bands at the top/bottom to soften the exit.
            Group {
                if model.isEditingScript {
                    InlineScriptEditor(
                        text: $model.script,
                        fontSize: CGFloat(model.fontSize),
                        initialCharOffset: model.editEnterCharOffset,
                        onCommit: { model.isEditingScript = false }
                    )
                } else {
                    ScrollingTextView(
                        text: model.script,
                        fontSize: CGFloat(model.fontSize),
                        speedPointsPerSecond: model.speedPointsPerSecond,
                        isRunning: model.isRunning,
                        hasStartedSession: model.hasStartedSession,
                        resetToken: model.resetToken,
                        jumpBackToken: model.jumpBackToken,
                        jumpBackDistancePoints: model.jumpBackDistancePoints,
                        manualScrollToken: model.manualScrollToken,
                        manualScrollDeltaPoints: model.manualScrollDeltaPoints,
                        fadeFraction: CGFloat(model.edgeFadeFraction),
                        backgroundOpacity: model.backgroundOpacity,
                        isHovering: false,
                        scrollMode: model.scrollMode,
                        savedScrollPhaseForResume: model.savedScrollPhaseForResume,
                        onSaveScrollPhaseForResume: { phase in
                            model.saveScrollPhaseForResume(phase)
                        },
                        onReachedEnd: {
                            if model.isRunning {
                                model.markReachedEndInStopMode()
                            }
                        },
                        theme: model.theme,
                        pauseOnPunctuation: model.pauseOnPunctuation,
                        punctuationStops: model.punctuationStops,
                        totalCharCount: model.totalCharCount,
                        autoSyncEnabled: model.autoSyncEnabled,
                        currentSpeechWordIndex: model.currentSpeechWordIndex,
                        totalScriptTokens: model.scriptTokensForSpeech.count,
                        isSpeechSpeaking: model.isSpeechSpeaking,
                        onSaveLiveCharOffset: { offset in
                            model.editEnterCharOffset = offset
                        }
                    )
                    .overlay {
                        TrackpadScrollCaptureView { delta in
                            model.handleManualScroll(deltaPoints: delta)
                        }
                    }
                    // Double-click anywhere on the scrolling text area enters
                    // inline-edit mode at the word currently being read. The
                    // most recent char offset is tracked by ScrollingTextView
                    // via `onSaveLiveCharOffset` and lives in `model.editEnterCharOffset`.
                    .onTapGesture(count: 2) {
                        model.isEditingScript = true
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 58)
            .padding(.bottom, 16)
            .clipShape(Rectangle())

            if model.theme.showsReadingLine {
                readingLineOverlay
                    .clipShape(shape)
                    .allowsHitTesting(false)
            }
            
            if !model.isCountingDown {
                HStack {
                    HStack(spacing: 6) {
                        OverlayControlButton(
                            symbol: (model.isRunning || model.isCountingDown) ? "hand.draw.fill" : "play.fill"
                        ) {
                            model.switchPlaybackModeFromOverlayControl()
                        }
                        .help((model.isRunning || model.isCountingDown) ? "Pause and switch to manual trackpad scroll" : "Start auto scroll")

                        OverlayControlButton(symbol: "gobackward.5") {
                            model.jumpBack(seconds: 5)
                        }
                        .help("Jump back 5 seconds")

                        OverlayControlButton(
                            symbol: model.autoSyncEnabled ? "waveform.circle.fill" : "waveform",
                            isActive: model.autoSyncEnabled
                        ) {
                            model.autoSyncEnabled.toggle()
                        }
                        .help(model.autoSyncEnabled
                              ? "Stop speech auto-sync"
                              : "Start speech auto-sync (scrolls as you talk)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(speechIndicatorStrokeColor, lineWidth: 1)
                    )
                    
                    Spacer(minLength: 8)
                    
                    HStack(spacing: 6) {
                        OverlayControlButton(symbol: "doc.on.clipboard") {
                            if let text = NSPasteboard.general.string(forType: .string) {
                                model.pasteScript(text)
                            }
                        }
                        .help("Paste script from clipboard")

                        OverlayControlButton(symbol: "trash") {
                            model.script = ""
                        }
                        .help("Clear script")

                        OverlayControlButton(
                            symbol: model.isEditingScript ? "checkmark" : "pencil",
                            isActive: model.isEditingScript
                        ) {
                            model.isEditingScript.toggle()
                        }
                        .help(model.isEditingScript ? "Done editing" : "Edit script inline")

                        OverlayControlButton(symbol: "minus", repeatWhilePressed: true) {
                            model.adjustSpeed(delta: -PrompterModel.speedStep)
                        }
                        .help("Decrease speed")

                        Text(speedBadgeText)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(width: 28, alignment: .center)
                            .help("Current speed (points/sec). Shows AUTO when speech sync is on.")

                        OverlayControlButton(symbol: "plus", repeatWhilePressed: true) {
                            model.adjustSpeed(delta: PrompterModel.speedStep)
                        }
                        .help("Increase speed")

                        OverlayControlButton(symbol: "xmark") {
                            NSApp.terminate(nil)
                        }
                        .help("Quit Notchprompt")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.7), in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }

            if model.isCountingDown {
                ZStack {
                    Color.black.opacity(0.92)
                    Text("\(model.countdownRemaining)")
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        }
        .frame(width: model.overlayWidth, height: model.overlayHeight)
    }

    /// Theme-aware background fill. When the theme's `backgroundFill` is nil,
    /// fall back to the legacy notch-blend look (black at the user's selected opacity).
    private var themeBackgroundFill: Color {
        if let fill = model.theme.backgroundFill {
            return fill
        }
        return Color(.sRGB, red: 0, green: 0, blue: 0, opacity: model.backgroundOpacity)
    }

    /// Compact label shown between the −/+ buttons in the right control capsule.
    /// When auto-sync is on the slider value is irrelevant (speech drives scroll),
    /// so we surface "AUTO" instead of a stale number.
    private var speedBadgeText: String {
        model.autoSyncEnabled ? "AUTO" : "\(Int(model.speedPointsPerSecond))"
    }

    /// Tints the left control capsule's stroke based on speech auto-sync state.
    /// - Subtle white when idle (default look)
    /// - Soft green when active and matching confidently
    /// - Soft red when "lost place" (sustained low confidence)
    private var speechIndicatorStrokeColor: Color {
        guard model.autoSyncEnabled else { return Color.white.opacity(0.12) }
        if model.isSpeechLostPlace { return Color.red.opacity(0.65) }
        let conf = max(0, min(1, model.currentSpeechConfidence))
        let alpha = 0.18 + 0.55 * conf
        return Color.green.opacity(alpha)
    }

    /// Faint horizontal guide rendered ~1/3 from the top of the overlay
    /// for the "Reading Line" theme. Helps the eye anchor while text scrolls.
    private var readingLineOverlay: some View {
        GeometryReader { proxy in
            let y = proxy.size.height * 0.36
            Path { p in
                p.move(to: CGPoint(x: 22, y: y))
                p.addLine(to: CGPoint(x: proxy.size.width - 22, y: y))
            }
            .stroke(Color.white.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
    }
}

/// Inline editor that swaps in for `ScrollingTextView` when the user enters
/// edit mode (pencil button OR double-click). Wraps an `NSTextView` so we can
/// programmatically position the caret at the word currently being read
/// (`initialCharOffset`) and scroll that line into view — which the SwiftUI
/// `TextEditor` cannot do reliably. Escape commits and exits via `onCommit`.
private struct InlineScriptEditor: NSViewRepresentable {
    @Binding var text: String
    let fontSize: CGFloat
    let initialCharOffset: Int
    let onCommit: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        textView.delegate = context.coordinator
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.backgroundColor = NSColor.black.withAlphaComponent(0.35)
        textView.drawsBackground = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.usesFindBar = false
        textView.string = text
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        // Place the caret + scroll on the next runloop pass so the view has
        // measured its layout and `scrollRangeToVisible` lands on the right line.
        DispatchQueue.main.async {
            let safe = min(text.count, max(0, initialCharOffset))
            let range = NSRange(location: safe, length: 0)
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Sync external text changes back into the view without nuking the user's
        // selection. We only reassign when the external value diverged (rare —
        // the model is the source of truth and the view writes back in textDidChange).
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let safe = NSRange(
                location: min(selection.location, text.count),
                length: 0
            )
            textView.setSelectedRange(safe)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineScriptEditor

        init(parent: InlineScriptEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
        }

        /// Treat Esc as "commit and exit" — same behavior as the old SwiftUI
        /// implementation that used `.onKeyPress(.escape)`.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onCommit()
                return true
            }
            return false
        }
    }
}

private struct OverlayControlButton: View {
    let symbol: String
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    let action: () -> Void

    var body: some View {
        // Use SwiftUI Button (not onLongPressGesture) so we benefit from
        // the macOS 15 click-through fix for non-activating panels (FB13720950).
        Button {
            if !repeatWhilePressed { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(
            OverlayCircleButtonStyle(
                isActive: isActive,
                repeatWhilePressed: repeatWhilePressed,
                repeatAction: action
            )
        )
    }
}

/// Button style that provides press-highlight and optional repeat-while-held.
private struct OverlayCircleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var repeatWhilePressed: Bool = false
    var repeatAction: (() -> Void)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Circle()
                    .fill(Color.white.opacity(configuration.isPressed || isActive ? 0.18 : 0.10))
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            )
            .background {
                if repeatWhilePressed {
                    RepeatWhileHeldHelper(
                        isPressed: configuration.isPressed,
                        action: repeatAction ?? {}
                    )
                }
            }
    }
}

/// Zero-size helper that fires an action on press-down and repeats while held.
private struct RepeatWhileHeldHelper: View {
    let isPressed: Bool
    let action: () -> Void

    @State private var repeatTask: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: isPressed) { _, pressed in
                if pressed {
                    action()
                    startRepeating()
                } else {
                    stopRepeating()
                }
            }
            .onDisappear { stopRepeating() }
    }

    private func startRepeating() {
        stopRepeating()
        repeatTask = Task {
            try? await Task.sleep(nanoseconds: 280_000_000)
            while !Task.isCancelled {
                await MainActor.run { action() }
                try? await Task.sleep(nanoseconds: 85_000_000)
            }
        }
    }

    private func stopRepeating() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct TrackpadScrollCaptureView: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScroll: onScroll)
    }

    func makeNSView(context: Context) -> ScrollCaptureNSView {
        let view = ScrollCaptureNSView()
        view.onScroll = context.coordinator.handleScroll
        return view
    }

    func updateNSView(_ nsView: ScrollCaptureNSView, context: Context) {
        nsView.onScroll = context.coordinator.handleScroll
    }

    final class Coordinator {
        let onScroll: (CGFloat) -> Void

        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
        }

        func handleScroll(_ event: NSEvent) {
            let rawDelta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * 10
            let semanticDelta = event.isDirectionInvertedFromDevice ? rawDelta : -rawDelta
            onScroll(semanticDelta)
        }
    }
}

final class ScrollCaptureNSView: NSView {
    var onScroll: ((NSEvent) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        onScroll?(event)
    }
}
