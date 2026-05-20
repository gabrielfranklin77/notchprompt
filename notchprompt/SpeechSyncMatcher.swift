//
//  SpeechSyncMatcher.swift
//  notchprompt
//
//  Pure-function fuzzy matcher that maps the latest speech transcript onto
//  the script the user is reading from. Stateless — the SpeechSyncManager
//  owns the cursor and feeds it back in. Kept in its own file so it can be
//  unit-tested in isolation (zero AppKit/AVFoundation imports).
//

import Foundation

enum SpeechSyncMatcher {
    /// Token of the script: lowercased letters and digits only, plus the
    /// `originalIndex` that lets us map back into the rendered script.
    struct ScriptToken: Equatable {
        let normalized: String
        let originalIndex: Int
    }

    struct MatchResult: Equatable {
        /// Index into the original `scriptTokens` array of the best-aligned word.
        let scriptTokenIndex: Int
        /// 0.0 – 1.0 confidence. Above ~0.6 the cursor advance is safe.
        let confidence: Double
    }

    /// Splits a script into normalized tokens.
    static func tokenizeScript(_ script: String) -> [ScriptToken] {
        var tokens: [ScriptToken] = []
        tokens.reserveCapacity(script.count / 5)

        var buffer = ""
        var indexCursor = 0
        for character in script {
            if character.isLetter || character.isNumber {
                buffer.append(character.lowercased())
            } else {
                if !buffer.isEmpty {
                    tokens.append(.init(normalized: buffer, originalIndex: indexCursor))
                    indexCursor += 1
                    buffer.removeAll(keepingCapacity: true)
                }
            }
        }
        if !buffer.isEmpty {
            tokens.append(.init(normalized: buffer, originalIndex: indexCursor))
        }
        return tokens
    }

    /// Normalizes a partial-result transcript into the same shape as ScriptToken.normalized.
    static func tokenizeTranscript(_ transcript: String, maxTail: Int = 10) -> [String] {
        var tail: [String] = []
        tail.reserveCapacity(maxTail)
        var buffer = ""
        // Iterate in reverse so we can stop as soon as we have `maxTail` tokens
        // — useful for long transcripts.
        let scalars = Array(transcript)
        for character in scalars.reversed() {
            if character.isLetter || character.isNumber {
                buffer.insert(character.lowercased().first ?? "_", at: buffer.startIndex)
            } else if !buffer.isEmpty {
                tail.insert(buffer, at: 0)
                buffer.removeAll(keepingCapacity: true)
                if tail.count >= maxTail { return tail }
            }
        }
        if !buffer.isEmpty, tail.count < maxTail {
            tail.insert(buffer, at: 0)
        }
        return tail
    }

    /// Returns the best alignment of the last few transcript words against a
    /// forward-only sliding window in the script. Forward-only because we
    /// never want auto-sync to scroll *backwards*: that would mean the speaker
    /// re-said something, but the user perceives it as the teleprompter
    /// jumping around.
    ///
    /// - Parameters:
    ///   - scriptTokens: result of `tokenizeScript(:)`, computed once when the script changes
    ///   - transcriptTail: result of `tokenizeTranscript(:maxTail:)` for the latest partial transcript
    ///   - cursor: current best-guess script-token index. Search window starts here.
    ///   - lookahead: how many script tokens ahead of `cursor` to scan
    static func bestAlignment(
        scriptTokens: [ScriptToken],
        transcriptTail: [String],
        cursor: Int,
        lookahead: Int = 16
    ) -> MatchResult? {
        guard !scriptTokens.isEmpty, !transcriptTail.isEmpty else { return nil }
        let startIndex = max(0, min(cursor, scriptTokens.count - 1))
        let endIndex = min(scriptTokens.count, startIndex + lookahead + transcriptTail.count)
        guard startIndex < endIndex else { return nil }

        let windowSize = transcriptTail.count
        guard windowSize > 0 else { return nil }

        var bestIndex = startIndex
        var bestScore = 0.0
        var bestPenalty = Double.greatestFiniteMagnitude

        // Slide a window the same length as the transcript tail. Score each
        // alignment by how many transcript words match script words in the
        // same relative order — a forgiving but order-aware measure.
        for offset in startIndex...(max(startIndex, endIndex - windowSize)) {
            let window = scriptTokens[offset..<min(offset + windowSize, scriptTokens.count)]
                .map(\.normalized)
            let (score, penalty) = orderedSimilarity(window: Array(window), tail: transcriptTail)
            if score > bestScore || (abs(score - bestScore) < 0.0001 && penalty < bestPenalty) {
                bestScore = score
                bestPenalty = penalty
                bestIndex = offset + (window.count - 1) // align cursor to the last matched word
            }
        }

        // Penalize matches that pulled the cursor backwards: we never want to scroll up.
        let forwardness = bestIndex >= cursor ? 1.0 : 0.5
        let confidence = bestScore * forwardness

        return .init(scriptTokenIndex: bestIndex, confidence: confidence)
    }

    /// In-order similarity: counts how many transcript words appear in the
    /// script window in matching relative order. The penalty is the average
    /// "skip distance" — we prefer tight matches over scattered ones.
    private static func orderedSimilarity(window: [String], tail: [String]) -> (score: Double, penalty: Double) {
        guard !window.isEmpty, !tail.isEmpty else { return (0, 0) }
        var matched = 0
        var lastWindowIndex = -1
        var skipDistance = 0

        for tailWord in tail {
            if let foundIndex = window[(lastWindowIndex + 1)...].firstIndex(of: tailWord) {
                skipDistance += foundIndex - (lastWindowIndex + 1)
                lastWindowIndex = foundIndex
                matched += 1
            }
        }

        let score = Double(matched) / Double(tail.count)
        let averageSkip = matched > 0 ? Double(skipDistance) / Double(matched) : Double(window.count)
        return (score, averageSkip)
    }
}

private extension ArraySlice where Element == String {
    /// Convenience overload so we can call `firstIndex(of:)` on a slice with the
    /// same semantics as on the full array — Swift's stdlib does this already
    /// but giving it a named helper makes the call site readable.
    func firstIndex(of element: String) -> Int? {
        for index in self.indices {
            if self[index] == element {
                return index
            }
        }
        return nil
    }
}
