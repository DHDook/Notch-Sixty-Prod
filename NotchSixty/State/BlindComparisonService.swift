import Foundation

// E12 S26 (behind `e12.blind-listening`): one comparison service for any two configurations of the app.
//
// Control plane, main actor. Nothing here runs on an audio thread. A side is switched in through the normal
// rebuild-with-fade path of the engine (the caller's `activate` closure republishes the live graph; there is never a
// second running graph). The hidden X assignment lives in the `BlindABXSession`; published state never says which side
// X is. Level matching is computed from each side's response over 500 Hz to 2 kHz: the louder side is trimmed down and
// the quieter one is never raised (decision 27). Allocation: allocates (offline). Synchronisation: none. Latency: the
// caller delays the earlier side by the declared-latency difference. Sample rate: any rate to 384 kHz (the response is
// evaluated by the caller at the session rate). Reset: `close()` restores the applied configuration.

/// Level matching of two sides (decision 27). The room-correction test uses the same maths.
struct ComparisonLevelMatch: Equatable, Sendable {
    /// Matching tolerance recorded at the eight rates (E12 S26, G55); `ComparisonLevelMatchTests` measures it at
    /// 44.1 to 384 kHz on reference configurations.
    static let toleranceDB = 0.1
    /// Above this per-lane difference after the trim the page shows a warning (E24 Q16).
    static let laneResidualWarningDB = 0.5

    var levelADB: Double
    var levelBDB: Double
    /// Linear trim for each side, at most 1: the louder side is below 1, the quieter side is exactly 1.
    var gainA: Double
    var gainB: Double
    /// The largest per-lane level difference left after the trim.
    var remainingDifferenceDB: Double
    /// True when either side has active dynamics: its level then depends on the program, so the match is a guess.
    var isApproximate: Bool

    enum Side: Equatable, Sendable { case a, b }

    var trimADB: Double { 20 * log10(gainA) }
    var trimBDB: Double { 20 * log10(gainB) }
    /// Which side was turned down, or nil when they already matched.
    var trimmedSide: Side? {
        if gainA < 1 { return .a }
        if gainB < 1 { return .b }
        return nil
    }

    /// The 1/12-octave grid over 500 Hz to 2 kHz the callers evaluate responses on.
    static func gridFrequencies() -> [Double] {
        var out: [Double] = []
        var f = 500.0
        let step = pow(2.0, 1.0 / 12.0)
        while f <= 2_000.0 * 1.0000001 {
            out.append(f)
            f *= step
        }
        return out
    }

    /// Mean power (linear) of a magnitude response in dB.
    static func meanPower(magnitudeDB: [Double]) -> Double {
        guard !magnitudeDB.isEmpty else { return 0 }
        return magnitudeDB.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(magnitudeDB.count)
    }

    /// One global trim from the power mean over the lanes; per-lane powers are linear. Throws when a power is not
    /// positive and finite, or the lane lists differ in length or are empty.
    static func make(
        lanePowersA: [Double], lanePowersB: [Double], hasActiveDynamicsA: Bool = false, hasActiveDynamicsB: Bool = false
    ) throws -> ComparisonLevelMatch {
        guard !lanePowersA.isEmpty, lanePowersA.count == lanePowersB.count,
              lanePowersA.allSatisfy({ $0 > 0 && $0.isFinite }), lanePowersB.allSatisfy({ $0 > 0 && $0.isFinite })
        else { throw BlindABXError.invalidTrial }
        func db(_ x: Double) -> Double { 10 * log10(x) }
        let levelA = db(lanePowersA.reduce(0, +) / Double(lanePowersA.count))
        let levelB = db(lanePowersB.reduce(0, +) / Double(lanePowersB.count))
        let target = min(levelA, levelB)
        let trimA = target - levelA, trimB = target - levelB
        var residual = 0.0
        for index in lanePowersA.indices {
            residual = max(residual, abs((db(lanePowersA[index]) + trimA) - (db(lanePowersB[index]) + trimB)))
        }
        return ComparisonLevelMatch(
            levelADB: levelA, levelBDB: levelB, gainA: pow(10, trimA / 20), gainB: pow(10, trimB / 20),
            remainingDifferenceDB: residual, isApproximate: hasActiveDynamicsA || hasActiveDynamicsB)
    }

    /// Sentence for the page: what was turned down and what difference remains.
    var summary: String {
        let trim = max(abs(trimADB), abs(trimBDB))
        var text = String(format: "Level matched within %.2f dB (the louder side is turned down by %.1f dB).", remainingDifferenceDB, trim)
        if isApproximate { text += " Approximate: dynamics processing makes the level depend on the music." }
        return text
    }
}

/// The fixed switch time (decision 24): a switch takes this long in either direction, so its duration gives no clue.
enum ComparisonSwitchTiming {
    /// Covers the core's silent warm-up and 20 ms equal-power crossfade; the switch time for the largest correction
    /// filter is a bench measurement (E22 holds it, G55).
    static let fixedSeconds: TimeInterval = 0.30
}

/// The engine boundary a comparison plays through (tests inject a fake; production is `AudioIOEngine`).
@MainActor
protocol ComparisonEngine: AnyObject {
    /// Why the comparison cannot play right now, or nil.
    var unavailableReason: String? { get }
    /// True while the core is still warming or fading to a republished graph.
    var isSwitching: Bool { get }
    /// Back to the applied configuration.
    func restoreApplied() throws
}

/// One side of a comparison. `activate` moves the running graph to this side through the normal faded republish.
struct ComparisonSide {
    var name: String
    var activate: @MainActor () throws -> Void
}

@MainActor
final class BlindComparisonService: ObservableObject {
    enum Selection: Equatable { case a, b, x }

    enum Phase: Equatable {
        case trials
        /// All trials are in; the preference question comes before the names are shown.
        case askingPreference
        case finished
        /// Playback stopped, the output changed or the engine failed: the applied configuration is back (or being restored).
        case ended(String)
    }

    private let engine: ComparisonEngine
    private let sideA: ComparisonSide
    private let sideB: ComparisonSide
    private let nextAssignment: () -> Bool
    private let clock: () -> Date
    private let switchHold: TimeInterval
    private var holdUntil: Date?
    private(set) var session: BlindABXSession

    let match: ComparisonLevelMatch
    @Published private(set) var selection: Selection?
    @Published private(set) var phase: Phase = .trials
    @Published private(set) var completedTrials = 0
    @Published private(set) var heardX = false
    @Published private(set) var message: String?
    @Published private(set) var isSwitching = false

    init(
        engine: ComparisonEngine, a: ComparisonSide, b: ComparisonSide, match: ComparisonLevelMatch,
        trialCount: Int = 16, initialAssignment: Bool = Bool.random(),
        nextAssignment: @escaping () -> Bool = { Bool.random() },
        switchHold: TimeInterval = ComparisonSwitchTiming.fixedSeconds, clock: @escaping () -> Date = { Date() }
    ) throws {
        self.engine = engine
        sideA = a
        sideB = b
        self.match = match
        self.nextAssignment = nextAssignment
        self.switchHold = switchHold
        self.clock = clock
        session = try BlindABXSession(trialCount: trialCount, initialAssignment: initialAssignment)
    }

    var totalTrials: Int { session.totalTrials }
    var currentTrialNumber: Int { session.currentTrialNumber }
    var canAnswer: Bool { phase == .trials && session.maySubmitChoice && !isSwitching }
    var canSwitch: Bool { phase == .trials && !isSwitching }
    var revealedNames: (a: String, b: String)? { phase == .finished ? (sideA.name, sideB.name) : nil }

    /// A, B or X. X plays the hidden side and counts as heard; the published selection is `.x`.
    func select(_ choice: Selection) {
        guard phase == .trials else { return }
        refreshSwitching()
        guard !isSwitching else { message = "Wait for the switch to finish."; return }
        let target: ComparisonSide
        switch choice {
        case .a: target = sideA
        case .b: target = sideB
        case .x: target = session.currentHiddenXWasB ? sideB : sideA
        }
        do {
            try target.activate()
            if choice == .x {
                try session.recordXPlayback()
                heardX = true
            }
            selection = choice
            message = nil
            holdUntil = clock().addingTimeInterval(switchHold)
            refreshSwitching()
        } catch {
            message = error.localizedDescription
        }
    }

    /// "X is A" or "X is B". Refused until X has played.
    func answer(xIsB: Bool) {
        guard phase == .trials else { return }
        guard session.maySubmitChoice else {
            message = "Listen to X before answering."
            return
        }
        do {
            try session.submit(xIsB, nextAssignment: nextAssignment())
            completedTrials = session.completedTrials.count
            heardX = false
            selection = nil
            message = nil
            if session.isComplete { phase = .askingPreference }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Moves to `.finished` once the caller has stored the result; the names are then shown.
    func finish() {
        guard phase == .askingPreference else { return }
        phase = .finished
        message = nil
    }

    func setMessage(_ text: String?) { message = text }

    /// Back to the applied configuration, on Close, Keep, stop, reconfiguration or device loss.
    func close() {
        if case .ended = phase { return }
        do { try engine.restoreApplied() } catch { message = error.localizedDescription }
    }

    /// Polled by the page: ends the run when playback stopped or the output changed (the engine has already dropped
    /// the override) and tracks the switching state.
    func refreshReadiness() {
        refreshSwitching()
        guard phase != .finished, !isEnded else { return }
        if let reason = engine.unavailableReason {
            phase = .ended(reason)
            selection = nil
            try? engine.restoreApplied()
        }
    }

    private var isEnded: Bool { if case .ended = phase { return true } else { return false } }

    private func refreshSwitching() {
        var hold = false
        if let until = holdUntil {
            if clock() < until { hold = true } else { holdUntil = nil }
        }
        isSwitching = engine.isSwitching || hold
    }
}
