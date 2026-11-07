import Foundation

// E26 S5: readiness for Quiet Zone with a subwoofer in the anti-noise path (design 8). Under the flag it replaces the
// blanket subwoofer refusal. Pure control-plane value: no engine access, nothing realtime. Readiness is a precondition
// only; an armed state still needs the user's Turn On through `LiveTreatmentArm`, and nothing here arms anything.

struct SubAwareAncReadiness: Equatable, Sendable {
    /// What is being armed. Feed-forward also needs per-band eligibility; tonal is predictive and has no latency gate.
    enum Mode: Equatable, Sendable { case tonal, feedForward }

    /// The first failing reason, in this order (`Reason.allCases`).
    enum Reason: Int, CaseIterable, Equatable, Sendable {
        case receiverUndeclared, plantMissing, recordStale, sweepsNotAnalysed, openPreoutMismatch, notConditioned
        case renderUnverified, safetyUnavailable, noFeedForwardBand
        /// E26 S7b2 (G37): class A feed-forward only. The host-fed graph's `BASS_MGMT` splits Linkwitz-Riley 4 only.
        case unsupportedBassFilter
    }

    struct Inputs: Equatable, Sendable {
        var mode: Mode
        var path: AncBassPathState
        /// The measured 2x2 plant (seat and reference point) and the fingerprint it was measured under.
        var plant: BassPlantMap
        var plantFingerprint: AncBassPathFingerprint?
        /// nil: the open-preout check has not run. Otherwise the refusal text from `OpenPreoutCheck`, or "" when passed.
        var openPreoutRefusal: String?
        /// The excursion limits for the declared path are available (caps can be built).
        var safetyAvailable: Bool
        /// Feed-forward only: bands that pass per-band eligibility. nil when not evaluated (the whole-feed lead gate still
        /// applies in `FeedForwardLiveArmGate`).
        var feedForwardBandCount: Int?
        /// E26 S6b: a fresh `SubSweepReport` exists. Defaults to true so callers that do not model the sweep report
        /// (the S5 tests) are unchanged; the controller passes the real answer.
        var sweepsAnalysed: Bool = true
        /// E26 S6b: the splitter render could not be verified (G2); the text to show, or nil.
        var renderUnverified: String?
        /// E26 S7b2 (G37): the app's split is one the graph's `BASS_MGMT` reproduces (`bassFilterSupportedByGraph`).
        /// Only feed-forward on class A (a sub on its own output) reads it. Defaults to true.
        var bassFilterSupported: Bool = true
    }

    let reason: Reason?
    let message: String?
    var isReady: Bool { reason == nil }

    static let sweepsNotAnalysedMessage = "Measure with your subwoofer, so Quiet Zone can check the bass path."
    static let plantMissingMessage = "Measure with your subwoofer first, so Quiet Zone knows how the bass reaches you."
    static let notConditionedMessage = "The bass measurement is not usable. Measure with your subwoofer again."
    static let safetyMessage = "Quiet Zone cannot set safe bass limits for this setup yet."
    static let unsupportedBassFilterMessage = "This bass filter is not supported for Quiet Zone with a separate subwoofer output."

    /// The graph's `BASS_MGMT` runs a Linkwitz-Riley 4 split; the app's other topology (48 dB per octave) is refused by
    /// the translator (`nonLR4Crossover`), so feed-forward, which needs the graph split to equal the measured one,
    /// refuses it on class A. A splitter that is off has nothing to disagree.
    static func bassFilterSupportedByGraph(_ bass: BassManagementConfiguration) -> Bool {
        !bass.enabled || bass.topology == .linkwitzRiley24
    }

    static let noFeedForwardBandMessage = "No frequency band has enough lead for feed-forward. Tonal Quiet Zone can still run."

    static func evaluate(_ i: Inputs) -> SubAwareAncReadiness {
        func fail(_ r: Reason, _ m: String) -> SubAwareAncReadiness { SubAwareAncReadiness(reason: r, message: m) }
        if let receiver = i.path.path.receiverBass, !receiver.isDeclared {
            return fail(.receiverUndeclared, TwoChannelAncArming.undeclaredReceiverRefusal)
        }
        guard !i.plant.isEmpty else { return fail(.plantMissing, plantMissingMessage) }
        guard let stamp = i.plantFingerprint else { return fail(.plantMissing, plantMissingMessage) }
        if case .stale(let message) = i.path.freshness(of: stamp) { return fail(.recordStale, message) }
        guard i.sweepsAnalysed else { return fail(.sweepsNotAnalysed, sweepsNotAnalysedMessage) }
        if let refusal = i.openPreoutRefusal, !refusal.isEmpty, i.path.path.receiverBass == .openPreout {
            return fail(.openPreoutMismatch, refusal)
        }
        // A well-conditioned or constrained design: every band must be assessable (a singular plant is constrained to
        // common mode, which is fine, but non-finite data is not).
        let usable = i.plant.bands.allSatisfy {
            $0.leftSecondaryAtListener.magnitude.isFinite && $0.rightSecondaryAtListener.magnitude.isFinite
                && $0.leftLeakageAtReference.magnitude.isFinite && $0.rightLeakageAtReference.magnitude.isFinite
        }
        guard usable else { return fail(.notConditioned, notConditionedMessage) }
        if let unverified = i.renderUnverified { return fail(.renderUnverified, unverified) }
        guard i.safetyAvailable else { return fail(.safetyUnavailable, safetyMessage) }
        if i.mode == .feedForward, i.path.path == .subOutput, !i.bassFilterSupported {
            return fail(.unsupportedBassFilter, unsupportedBassFilterMessage)
        }
        if i.mode == .feedForward, let bands = i.feedForwardBandCount, bands == 0 {
            return fail(.noFeedForwardBand, noFeedForwardBandMessage)
        }
        return SubAwareAncReadiness(reason: nil, message: nil)
    }
}

/// Plain-language text for the Quiet Zone setup card (E26 S5). Pure, so the wording is tested.
enum SubAwareQuietZoneText {
    static let question = "How does bass reach the room?"

    /// The answer, from the arrangement's bass path.
    static func pathSummary(_ path: AncBassPath) -> String {
        switch path {
        case .none: return "Both speakers play the whole range. There is no separate subwoofer."
        case .monoBassOnPair: return "Notch Sixty shares the bass between your two speakers. No subwoofer is involved."
        case .downstream(.undeclared): return "Through your receiver or powered subwoofer. Tell Notch Sixty how it handles bass."
        case .downstream(.openPreout): return "Through your receiver's subwoofer pre-out, with Notch Sixty making the bass split."
        case .downstream(.calibratedLFE(let hz)):
            return "Through your receiver's LFE out, which splits the bass at \(Int(hz)) Hz."
        case .appSplitter: return "Notch Sixty splits the bass for your subwoofer."
        case .subOutput: return "Through a subwoofer on its own output."
        }
    }

    /// Advice shown beside "Measure with your subwoofer".
    static let advice = "Switch off your receiver's room EQ and dynamic bass while you measure, and keep them off while "
        + "Quiet Zone is on. They change the bass after Notch Sixty measures it."
}
