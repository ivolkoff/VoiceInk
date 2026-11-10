import Foundation

/// How long recording continues after the stop press: a release often lands while the
/// last word is still sounding (values from anomalyco/hex `POST_RELEASE_TAIL`).
enum ReleaseTailPolicy {
    static let frameDuration: TimeInterval = 0.02
    static let baseFrames = 10
    static let maxFrames = 30
    static let speechFrames = 5
    static let quietFrames = 8
    static let speechGapFrames = 2
    static let speechThresholdDBFS: Float = -40

    /// `frames` are speech flags of 20 ms frames since the stop press, oldest first.
    static func shouldKeepRecording(_ frames: [Bool]) -> Bool {
        if frames.count < baseFrames { return true }
        if frames.count >= maxFrames { return false }
        guard isTalking(atEndOf: frames.prefix(baseFrames)) else { return false }
        return !frames.suffix(quietFrames).allSatisfy { !$0 }
    }

    private static func isTalking(atEndOf window: ArraySlice<Bool>) -> Bool {
        var speech = 0
        var gap = 0
        for flag in window.reversed() {
            if flag {
                speech += 1
                gap = 0
                if speech >= speechFrames { return true }
            } else {
                gap += 1
                if gap > speechGapFrames { return false }
            }
        }
        return false
    }
}
