import Foundation
import os

/// Circuit breaker against A→B→A auto flips: if one synthetic event ever leaks back into the
/// buffer, the detector would re-convert its own output in a µs-paced loop. Applies to the
/// auto path only; the manual trigger is the user's decision.
/// Port of keyboop AntiResonanceGuard.swift (MIT, © Keyboop contributors).
final class AntiResonanceGuard {
    private let window: TimeInterval
    private let maxFlips: Int
    private let freezeFor: TimeInterval
    private var recent: [(produced: String, at: TimeInterval)] = []
    private var frozenUntil: TimeInterval = 0
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "AntiResonanceGuard")

    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    init(window: TimeInterval = 0.7, maxFlips: Int = 6, freezeFor: TimeInterval = 2.5) {
        self.window = window
        self.maxFlips = maxFlips
        self.freezeFor = freezeFor
    }

    /// Ask before an auto-conversion `word` → `produced`. false ⇒ skip it and reset the buffer.
    func allow(word: String, produced: String) -> Bool {
        let now = clock()
        if now < frozenUntil { return false }
        recent.removeAll { now - $0.at > window }
        let oscillation = recent.contains { $0.produced == word }
        recent.append((produced: produced, at: now))
        if oscillation || recent.count > maxFlips {
            frozenUntil = now + freezeFor
            recent.removeAll()
            logger.notice("auto-conversion frozen for \(self.freezeFor, privacy: .public)s (\(oscillation ? "oscillation" : "storm", privacy: .public))")
            return false
        }
        return true
    }

    var isFrozen: Bool { clock() < frozenUntil }

    func resetHistory() { recent.removeAll() }
}
