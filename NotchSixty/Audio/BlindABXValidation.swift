import Foundation

/// Offline exploratory A/B/X trial record. A and B are explicitly selected
/// comparable audio files; the X assignment is hidden until test completion.
/// No relationship to live DSP correctness or PR112 hardware acceptance.
struct BlindABXTrial: Codable, Equatable, Sendable {
    var number: Int
    var hiddenXWasB: Bool
    var selectedB: Bool
    var correct: Bool { hiddenXWasB == selectedB }
}

enum BlindABXError: Error, Equatable, LocalizedError {
    case invalidCount
    case sessionComplete
    case incompleteSession
    case invalidTrial

    var errorDescription: String? {
        switch self {
        case .invalidCount:
            return "Select 12, 16, or 24 independent ABX trials."
        case .sessionComplete:
            return "This ABX session has already been completed."
        case .incompleteSession:
            return "Finish all trials before revealing the outcome."
        case .invalidTrial:
            return "An ABX trial must be heard before recording the choice."
        }
    }
}

struct BlindABXSession: Sendable {
    var totalTrials: Int
    private(set) var completedTrials: [BlindABXTrial] = []
    private(set) var currentHiddenXWasB: Bool
    private(set) var heardCurrentX: Bool = false

    init(trialCount: Int = 16, initialAssignment: Bool = Bool.random()) throws {
        guard [12, 16, 24].contains(trialCount) else {
            throw BlindABXError.invalidCount
        }
        totalTrials = trialCount
        currentHiddenXWasB = initialAssignment
    }

    var isComplete: Bool { completedTrials.count == totalTrials }
    var currentTrialNumber: Int { min(totalTrials, completedTrials.count + 1) }
    var correctCount: Int { completedTrials.filter(\.correct).count }
    var maySubmitChoice: Bool { !isComplete && heardCurrentX }

    mutating func recordXPlayback() throws {
        guard !isComplete else { throw BlindABXError.sessionComplete }
        heardCurrentX = true
    }

    /// X bits are independently drawn from SystemRandomNumberGenerator
    /// between submissions; deliberately NOT balanced without replacement.
    /// Prebalanced assignments become predictable late in the session.
    mutating func submit(_ chooseB: Bool, nextAssignment: Bool = Bool.random()) throws {
        guard !isComplete else { throw BlindABXError.sessionComplete }
        guard heardCurrentX else { throw BlindABXError.invalidTrial }
        completedTrials.append(
            BlindABXTrial(number: currentTrialNumber,
                          hiddenXWasB: currentHiddenXWasB,
                          selectedB: chooseB)
        )
        heardCurrentX = false
        if !isComplete {
            currentHiddenXWasB = nextAssignment
        }
    }

    /// Exact one-sided P(X>=k) for the fair-guess null hypothesis.
    /// The calculation is fully offline; no inference is made about
    /// physical speaker/room correction, device safety or every listener.
    static func exactOneSidedPValue(correct: Int, total: Int) -> Double? {
        guard total >= 1, total <= 128, (0...total).contains(correct) else {
            return nil
        }
        var term = pow(0.5, Double(total))
        var tail = 0.0
        for k in 0...total {
            if k >= correct { tail += term }
            if k < total {
                term *= Double(total - k) / Double(k + 1)
            }
        }
        return min(1.0, max(0.0, tail))
    }

    func exportEvidence() throws -> BlindABXEvidence {
        guard isComplete else { throw BlindABXError.incompleteSession }
        let p = Self.exactOneSidedPValue(correct: correctCount,
                                         total: totalTrials) ?? 1
        return BlindABXEvidence(
            schemaVersion: 1,
            trialCount: totalTrials,
            correctCount: correctCount,
            oneSidedExactPValue: p,
            trials: completedTrials,
            evidenceAuthority: "userExploratoryOfflineListening",
            realHardwareMeasured: false,
            physicalAcceptanceComplete: false,
            releaseAcceptanceComplete: false,
            mayMergeIntoMain: false,
            liveFeedForwardANCAuthorized: false
        )
    }
}

struct BlindABXEvidence: Codable, Sendable {
    var schemaVersion: Int
    var trialCount: Int
    var correctCount: Int
    var oneSidedExactPValue: Double
    var trials: [BlindABXTrial]
    var evidenceAuthority: String
    var realHardwareMeasured: Bool
    var physicalAcceptanceComplete: Bool
    var releaseAcceptanceComplete: Bool
    var mayMergeIntoMain: Bool
    var liveFeedForwardANCAuthorized: Bool
}

/// Preflight object representing two independently analyzed local files.
/// File RMS is NOT perceptual LUFS; pass does not prove identical alignment,
/// mastering, channel phase, or other factors confounding an ABX experiment.
struct BlindABXFileMetrics: Equatable, Sendable {
    var sampleRate: Double
    var channels: Int
    var frameCount: Int64
    var rmsDBFS: Double
    var samplePeakDBFS: Double
}

struct BlindABXPreflight: Sendable {
    static func reasons(a: BlindABXFileMetrics,
                        b: BlindABXFileMetrics) -> [String] {
        var reasons: [String] = []
        for item in [a, b] {
            if !item.sampleRate.isFinite
                || !(8_000...384_000).contains(item.sampleRate)
                || item.channels != 2
                || item.frameCount <= 0
                || item.frameCount > Int64(item.sampleRate * 90)
                || !item.rmsDBFS.isFinite
                || !item.samplePeakDBFS.isFinite {
                reasons.append("Both sources must be valid stereo PCM, at a supported rate and no longer than 90 seconds.")
                return reasons
            }
            if item.samplePeakDBFS > -1 {
                reasons.append("Source sample peak must stay below -1 dBFS; reduce gain and re-export both excerpts.")
            }
        }
        if abs(a.sampleRate - b.sampleRate) >= 0.5
            || a.frameCount != b.frameCount {
            reasons.append("Both sources need identical sample rate and sample count; align and re-export the excerpts.")
        }
        if abs(a.rmsDBFS - b.rmsDBFS) > 0.10 {
            reasons.append("Measured file RMS differs by more than 0.10 dB; loudness-match and re-export before testing.")
        }
        return reasons
    }
}
