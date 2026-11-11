import Foundation

/// E4 S30c: turns each poll's planned cuts into the cuts that are actually sent. Control plane only (never in an
/// audio callback); numbers in, numbers out, no audio and no recording.
///
/// Limits (design note, safety limits): up at most 4 dB/s, down at most 1 dB/s (the planner's per-poll steps are
/// defined for the 250 ms poll and scaled by the elapsed time), the overall programme change no more than 3 dB
/// while the cuts move, and release to zero at 1 dB/s when the plan falls back, speech stops, or no analysis has
/// arrived for 2 s. A Lombard voice cannot run the cuts away: the plan is bounded at 6 dB per band and 3 dB
/// overall, and the add-back of the applied cuts (S30b) keeps the planner from chasing its own output.
struct ConversationUnmaskingGovernor: Sendable {
    static let staleSeconds = 2.0
    static let nominalPollSeconds = 0.25

    var planner = ConversationUnmaskingPlanner()
    private(set) var cutsDB = [Double](repeating: 0, count: SpeechIntelligibilityBands.centersHz.count)
    private var secondsSinceAnalysis = 0.0
    /// The latest complete planner input, kept only to bound the overall change while cuts release.
    private var lastInput: ConversationUnmaskingInput?

    var isEngaged: Bool { cutsDB.contains { $0 > 0.000_1 } }

    /// Clears the cuts at once: flag off, mode change, rate change, transport rebuild.
    mutating func reset() {
        cutsDB = [Double](repeating: 0, count: cutsDB.count)
        secondsSinceAnalysis = 0
        lastInput = nil
    }

    /// One poll with a fresh evaluation. `evaluation` nil means the flag is off (cuts clear at once).
    mutating func update(evaluation: ConversationUnmaskingEvaluation?, elapsedSeconds: Double) -> [Double] {
        guard let evaluation else { reset(); return cutsDB }
        secondsSinceAnalysis = 0
        let target: [Double]
        switch evaluation.status {
        case .planned(let plan):
            target = plan.bandCutsDB.count == cutsDB.count ? plan.bandCutsDB : [Double](repeating: 0, count: cutsDB.count)
            if evaluation.input != nil { lastInput = evaluation.input }
        case .fallback:
            target = [Double](repeating: 0, count: cutsDB.count)
        }
        move(toward: target, elapsedSeconds: elapsedSeconds)
        return cutsDB
    }

    /// One poll without a fresh analysis (too few frames, a held poll): the cuts hold for 2 s, then release.
    mutating func noAnalysis(elapsedSeconds: Double) -> [Double] {
        secondsSinceAnalysis += max(elapsedSeconds, 0)
        if secondsSinceAnalysis >= Self.staleSeconds {
            move(toward: [Double](repeating: 0, count: cutsDB.count), elapsedSeconds: elapsedSeconds)
        }
        return cutsDB
    }

    private mutating func move(toward target: [Double], elapsedSeconds: Double) {
        let scale = max(elapsedSeconds, 0) / Self.nominalPollSeconds
        let up = planner.configuration.maximumAttackStepDB * scale
        let down = planner.configuration.maximumReleaseStepDB * scale
        let limit = planner.configuration.maximumBandCutDB
        var next = zip(cutsDB, target).map { current, goal in
            let moved = goal > current ? min(goal, current + up) : max(goal, current - down)
            return min(max(moved, 0), limit)
        }
        // Bands rise faster than they fall, so a plan that shrinks one band while growing another can overshoot
        // the overall limit for a moment: scale the cuts back until the programme change is inside it.
        if let input = lastInput, input.musicBandLevelsDB.count == next.count {
            let allowed = planner.configuration.maximumOverallCutDB
            if -planner.overallChangeDB(input, cuts: next) > allowed + 1e-6 {
                var low = 0.0, high = 1.0
                for _ in 0..<12 {
                    let mid = (low + high) / 2
                    if -planner.overallChangeDB(input, cuts: next.map { $0 * mid }) > allowed { high = mid } else { low = mid }
                }
                next = next.map { $0 * low }
            }
        }
        cutsDB = next
    }
}

/// E4 S30c: what the Conversation Focus card shows, built from the controller's latest evaluation. Numbers and
/// words only; no audio. The SII figures are estimates from the microphone's position, never verified at the seat.
struct ConversationUnmaskingCardModel: Equatable, Sendable {
    var speechDetected: Bool
    var speechConfidencePercent: Int
    var siiBefore: Double?
    var siiAfter: Double?
    var maximumCutDB: Double
    var cutBandCount: Int
    /// Realised response of the cut sections at the session rate (dB), for the curve; empty when nothing is cut.
    var curve: [AmbientCompensationResponsePoint]
    /// Why the broad cut is used instead, nil when per-band unmasking is planning.
    var fallbackReason: String?
    static let estimateNote = "Estimated; not verified at your seat."
    static let microphoneNote = "Keep the microphone near your seat: the plan is made from what it hears."

    init(evaluation: ConversationUnmaskingEvaluation, appliedCutsDB: [Double], sampleRate: Double) {
        speechConfidencePercent = Int((evaluation.speechConfidence * 100).rounded())
        speechDetected = evaluation.speechConfidence >= ConversationUnmaskingConfiguration().minimumSpeechConfidence
        let cuts = appliedCutsDB.count == SpeechIntelligibilityBands.centersHz.count ? appliedCutsDB : []
        maximumCutDB = cuts.max() ?? 0
        cutBandCount = cuts.filter { $0 > 0.05 }.count
        curve = maximumCutDB > 0.05
            ? AmbientUnmaskOverlay.response(plannedCutsDB: cuts, sampleRate: sampleRate) : []
        switch evaluation.status {
        case .planned(let plan):
            siiBefore = plan.siiBefore
            siiAfter = plan.siiAfter
            fallbackReason = nil
        case .fallback(let reason):
            siiBefore = nil
            siiAfter = nil
            fallbackReason = Self.describe(reason)
        }
    }

    static func describe(_ reason: ConversationUnmaskingFallback) -> String {
        switch reason {
        case .notConversationFocus: return "Conversation Focus is not selected."
        case .notPlaying: return "Playback is stopped."
        case .lowSeparationConfidence:
            return "The microphone cannot separate speech from playback well enough yet; using the broad cut."
        case .noPlaybackModel: return "No playback model for this microphone yet; using the broad cut."
        case .noBaseline: return "Capture a quiet baseline to enable per-band unmasking; using the broad cut."
        case .incompleteSpectrum: return "The analysis does not cover the speech bands at this rate; using the broad cut."
        case .invalidAppliedCuts: return "The applied cuts could not be checked; using the broad cut."
        case .shortEnvelope: return "Listening for speech (about 2 seconds); using the broad cut."
        }
    }
}
