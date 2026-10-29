import Foundation

/// E4 S18b: why a supervised re-solve after a microphone move ended in a disarm. Every failure
/// is the same disarm (`microphoneMoved`); the S17 recorder logs which one fired.
enum MicrophoneMoveFailure: String, Equatable, Sendable {
    /// Before the new baseline: a tone or band more than 1 dB above the arming baseline for 1 s.
    case aboveArmingBaseline
    /// After the new baseline: a tone or band more than 0.5 dB above it for 1 s.
    case aboveNewBaseline
    /// The anti-noise rose more than 3 dB within 1 s without at least 1 dB less at the seat.
    case antiNoiseRoseWithoutBenefit
    /// The anti-noise sat at the attempt cap for 1 s without the tone dropping by 3 dB.
    case cappedWithoutBenefit
    /// The path estimate was still moving more than 10 degrees between estimates after 3 s.
    case pathNotConverged
    /// The path was still moving faster than 5 degrees per second after 3 s.
    case pathStillMoving
    /// 20 s passed since the trigger without success.
    case timeLimit
    /// A second move within 60 s of a success.
    case secondMoveSoon
    /// A fourth re-solve in one arm.
    case tooManyResolves

    var explanation: String {
        switch self {
        case .aboveArmingBaseline:
            return "a tone got louder than before arming while re-solving"
        case .aboveNewBaseline:
            return "a tone got louder than the new baseline while re-solving"
        case .antiNoiseRoseWithoutBenefit:
            return "the anti-noise rose without making the seat quieter"
        case .cappedWithoutBenefit:
            return "the anti-noise reached its limit without enough cancellation"
        case .pathNotConverged:
            return "the speaker-to-microphone path did not settle in time"
        case .pathStillMoving:
            return "the speaker-to-microphone path kept changing"
        case .timeLimit:
            return "the re-solve did not finish within 20 seconds"
        case .secondMoveSoon:
            return "the microphone moved again soon after a re-solve"
        case .tooManyResolves:
            return "the microphone moved too many times in one session"
        }
    }
}

/// What the controller must do next, decided by the resolver and executed by the controller.
enum MicrophoneMoveAction: Equatable, Sendable {
    case none
    /// Drop the gains 10 dB over 250 ms and set the attempt cap 10 dB below the cap in force.
    case reduceGains
    /// Restart the path fit from the tracked estimate with the raised dither.
    case beginReidentify
    /// Ramp the anti-noise out over 1 s and have S16 capture a new baseline over 2 s.
    case rampOutAndBaseline
    /// Re-seed the weights (W Sold / Snew), ramp back in over 3 s, supervised adaptation begins.
    case reseedAndRampIn
    /// Success: new path becomes the reference, new baseline becomes S16's, the cap steps back.
    case succeeded
    /// Disarm with `microphoneMoved`.
    case disarm(MicrophoneMoveFailure)
}

enum MicrophoneMovePhase: String, Equatable, Sendable {
    case idle
    case reducing
    case reidentifying
    case rebaselining
    case rampingIn
    case adapting
}

/// One poll's measurements for the resolver. All values are control-plane summaries; times are in
/// seconds on any monotonic clock.
struct MicrophoneMoveObservation: Equatable, Sendable {
    var now: TimeInterval
    /// The core's mic-moved detector has latched (beyond 30 degrees / 3 dB for 1 s, or a fast
    /// change on two or more tones).
    var moveLatched: Bool
    /// Worst tone or band, in dB above the baseline now in force (the arming baseline before the
    /// new one is captured, the new one after). Negative or zero when nothing is louder.
    var seatOverBaselineDB: Double
    /// Smallest reduction over the tones against the baseline in force, dB (positive is quieter).
    var seatMinimumReductionDB: Double
    /// Rise of the anti-noise level over the last second, dB.
    var antiNoiseRiseDB: Double
    /// Improvement of the seat reduction over the last second, dB (positive is quieter).
    var seatDropDB: Double
    /// The anti-noise sits at the attempt cap.
    var atAttemptCap: Bool
    /// Largest difference between the two latest path estimates, degrees.
    var pathStepDegrees: Double
    /// Largest rate of change of the path phase, degrees per second.
    var pathRateDegreesPerSecond: Double
    /// S16 has captured the new baseline.
    var newBaselineReady: Bool
}

/// The supervised re-solve after the microphone moved (owner decision of 28 Oct 2026; design
/// decision 6 in `docs/epics/E4.md`). A pure, deterministic state machine driven once per poll:
/// no clocks, no engine, no I/O. The controller executes the returned action.
///
/// Timeline from the trigger: reduce 0.25 s, re-identify 3 s, ramp out 1 s with a 2 s new
/// baseline, ramp in 3 s, then supervised adaptation for the rest of 20 s. Success needs every
/// tone at least 3 dB below the new baseline and nothing above it.
struct MicrophoneMoveResolver: Equatable, Sendable {
    static let reduceSeconds = 0.25
    static let reidentifySeconds = 3.0
    static let rampOutSeconds = 1.0
    static let baselineSeconds = 2.0
    static let rampInSeconds = 3.0
    static let timeLimitSeconds = 20.0
    static let attemptCapReductionDB = 10.0
    static let aboveArmingBaselineDB = 1.0
    static let aboveNewBaselineDB = 0.5
    static let sustainSeconds = 1.0
    static let antiNoiseRiseLimitDB = 3.0
    static let seatBenefitDB = 1.0
    static let cappedBenefitDB = 3.0
    static let successReductionDB = 3.0
    static let pathStepLimitDegrees = 10.0
    static let pathRateLimitDegreesPerSecond = 5.0
    static let secondMoveWindowSeconds = 60.0
    static let maximumResolves = 3

    private(set) var phase: MicrophoneMovePhase = .idle
    private(set) var resolveCount = 0
    private(set) var lastFailure: MicrophoneMoveFailure?
    private var triggeredAt: TimeInterval = 0
    private var phaseStartedAt: TimeInterval = 0
    private var lastSuccessAt: TimeInterval?
    private var overSince: TimeInterval?
    private var antiNoiseRiseSince: TimeInterval?
    private var cappedSince: TimeInterval?

    var isRunning: Bool { phase != .idle }
    /// True while the anti-noise is being held out (ramp-out and baseline capture).
    var holdsOutputSilent: Bool { phase == .rebaselining }

    /// Arms start fresh.
    mutating func reset() { self = MicrophoneMoveResolver() }

    /// Advances by one observation. After a disarm action the resolver is idle and stays so
    /// until `reset` (the next arm).
    mutating func step(_ o: MicrophoneMoveObservation) -> MicrophoneMoveAction {
        if phase == .idle { return idleStep(o) }

        if o.now - triggeredAt >= Self.timeLimitSeconds { return fail(.timeLimit) }

        // Seat supervision runs in every phase. Before the new baseline the arming baseline is the
        // reference at 1 dB; after it, the new baseline at 0.5 dB. During the baseline capture the
        // anti-noise is out and the S16 window is the ANC-off reference, so nothing is compared.
        if phase != .rebaselining {
            let limit = newBaselineInForce ? Self.aboveNewBaselineDB : Self.aboveArmingBaselineDB
            if o.seatOverBaselineDB > limit {
                let since = overSince ?? o.now
                overSince = since
                if o.now - since >= Self.sustainSeconds {
                    return fail(newBaselineInForce ? .aboveNewBaseline : .aboveArmingBaseline)
                }
            } else {
                overSince = nil
            }
        }

        if phase == .reducing || phase == .reidentifying || phase == .rampingIn || phase == .adapting {
            if o.antiNoiseRiseDB > Self.antiNoiseRiseLimitDB, o.seatDropDB < Self.seatBenefitDB {
                let since = antiNoiseRiseSince ?? o.now
                antiNoiseRiseSince = since
                if o.now - since >= Self.sustainSeconds { return fail(.antiNoiseRoseWithoutBenefit) }
            } else {
                antiNoiseRiseSince = nil
            }
            if o.atAttemptCap, o.seatMinimumReductionDB < Self.cappedBenefitDB, phase != .reducing {
                let since = cappedSince ?? o.now
                cappedSince = since
                if o.now - since >= Self.sustainSeconds { return fail(.cappedWithoutBenefit) }
            } else {
                cappedSince = nil
            }
        }

        switch phase {
        case .idle:
            return .none
        case .reducing:
            guard o.now - phaseStartedAt >= Self.reduceSeconds else { return .none }
            enter(.reidentifying, at: o.now)
            return .beginReidentify
        case .reidentifying:
            guard o.now - phaseStartedAt >= Self.reidentifySeconds else { return .none }
            if o.pathStepDegrees > Self.pathStepLimitDegrees { return fail(.pathNotConverged) }
            if o.pathRateDegreesPerSecond > Self.pathRateLimitDegreesPerSecond { return fail(.pathStillMoving) }
            enter(.rebaselining, at: o.now)
            return .rampOutAndBaseline
        case .rebaselining:
            let wait = Self.rampOutSeconds + Self.baselineSeconds
            guard o.now - phaseStartedAt >= wait, o.newBaselineReady else { return .none }
            enter(.rampingIn, at: o.now)
            newBaselineActive = true
            return .reseedAndRampIn
        case .rampingIn:
            if o.now - phaseStartedAt >= Self.rampInSeconds { enter(.adapting, at: o.now) }
            return .none
        case .adapting:
            if o.seatMinimumReductionDB >= Self.successReductionDB, o.seatOverBaselineDB <= 0 {
                lastSuccessAt = o.now
                phase = .idle
                clearTimers()
                return .succeeded
            }
            return .none
        }
    }

    private var newBaselineActive = false
    private var newBaselineInForce: Bool { newBaselineActive }

    private mutating func idleStep(_ o: MicrophoneMoveObservation) -> MicrophoneMoveAction {
        guard o.moveLatched, lastFailure == nil else { return .none }
        if let last = lastSuccessAt, o.now - last < Self.secondMoveWindowSeconds {
            return fail(.secondMoveSoon)
        }
        if resolveCount >= Self.maximumResolves { return fail(.tooManyResolves) }
        resolveCount += 1
        triggeredAt = o.now
        newBaselineActive = false
        clearTimers()
        enter(.reducing, at: o.now)
        return .reduceGains
    }

    private mutating func enter(_ next: MicrophoneMovePhase, at now: TimeInterval) {
        phase = next
        phaseStartedAt = now
        overSince = nil
        antiNoiseRiseSince = nil
        cappedSince = nil
    }

    private mutating func clearTimers() {
        overSince = nil
        antiNoiseRiseSince = nil
        cappedSince = nil
    }

    private mutating func fail(_ failure: MicrophoneMoveFailure) -> MicrophoneMoveAction {
        phase = .idle
        lastFailure = failure
        clearTimers()
        return .disarm(failure)
    }
}
