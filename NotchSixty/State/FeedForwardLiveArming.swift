import Foundation

// E4 S25 arming (flag `e4.feedforward-live`). Owner approval of 2 Nov 2026, four conditions:
// 1. User-initiated only: one explicit request while Quiet Zone is armed; never on launch, wake,
//    device or rate change.
// 2. Slow fade-in: the engine core ramps the anti-noise in over 3 s (`N60FeedForwardLive`), trips
//    fade out in 10 ms.
// 3. The fade-in starts only after the do-no-harm baseline, the lead gate and the engine lease pass.
// 4. Never persisted: every trip, disarm or environment change returns to off, latched until the
//    user asks again. Nothing here reads or writes stored state.
//
// Realtime impact: none. Everything here is control plane (main actor); the audio thread sees only
// the kernel's own arm flag, which `FeedForwardLiveArmGate` and the kernel's lead gate guard.

/// What the Quiet Zone controller knows at one poll.
struct FeedForwardLiveQuietZoneFacts: Equatable, Sendable {
    /// The Quiet Zone ARM switch is armed (the user's own action, never persisted).
    var armed: Bool
    /// The ANC-off baseline of the do-no-harm verifier has been captured.
    var hasBaseline: Bool
    var verdict: DoNoHarmVerdict
    /// The engine lease is required (`e4.anc-engine-lease`) and whether its renewal is running.
    var leaseRequired: Bool
    var leaseHealthy: Bool
    var outputDeviceUID: String?
    var sampleRate: Double?
    var budget: QuietZoneFeedForwardBudget
    /// A subwoofer or bass management is active: not available yet (owner decision of 3 Nov 2026, question 18).
    var subwooferActive = false
}

/// What the feed-forward shadow and reference driver know.
struct FeedForwardLiveShadowFacts: Equatable, Sendable {
    var stability: FeedForwardLeakageStabilityCheck.Verdict
    /// Echo removal verified in the live stage (E4 S22b3): locked, with at least
    /// `minimumVerifiedProgrammeSeconds` of programme since the lock. Nil until then.
    var verifiedRemovalDecibels: Double?
    /// Programme seconds the live stage has metered since its lock (0 when not locked).
    var removalProgrammeSeconds: Double = 0
    /// The reference pump is running (`FeedForwardLiveDriver.state == .running`).
    var referenceRunning: Bool
    /// `FeedForwardLiveDriver.delaySeconds`; spent from the lead budget.
    var pumpDelaySeconds: Double?

    static let minimumVerifiedProgrammeSeconds = 5.0

    static let none = FeedForwardLiveShadowFacts(
        stability: .notChecked("no feed-forward shadow"), verifiedRemovalDecibels: nil,
        referenceRunning: false, pumpDelaySeconds: nil)
}

/// What the render kernel's filter reports.
struct FeedForwardLiveKernelFacts: Equatable, Sendable {
    enum State: Equatable, Sendable { case idle, armed, tripped(UInt32) }

    var state: State
    /// Current fade, 0 to 1.
    var gain: Float

    init(state: State, gain: Float) {
        self.state = state
        self.gain = gain
    }

    init(_ status: N60RenderKernelFeedForwardLiveStatus) {
        switch status.filter.state {
        case UInt32(N60FeedForwardLiveArmed): state = .armed
        case UInt32(N60FeedForwardLiveTripped): state = .tripped(status.filter.tripReason)
        default: state = .idle
        }
        gain = status.filter.gain
    }
}

enum FeedForwardLiveOffReason: Equatable, Sendable {
    case user
    case quietZoneDisarmed
    case environmentChanged
    case leaseLost
    case baselineLost
    case seatRegression
    case filterTripped(String)
    case filterDisarmed
    case referenceLost
    case stabilityLost
    /// The live echo removal stayed under 10 dB for 10 s of programme: the leakage model is stale.
    case echoRemovalLost
    case waitedTooLong
    case engineRefused(String)

    /// Shown after an automatic return to off. Nil for the user's own action.
    var message: String? {
        switch self {
        case .user: return nil
        case .quietZoneDisarmed: return "Feed-forward is off: Quiet Zone was disarmed. Turn it on again to continue."
        case .environmentChanged: return "Feed-forward is off: the output device or sample rate changed. Turn it on again to continue."
        case .leaseLost: return "Feed-forward is off: the engine safety lease lapsed. Turn it on again to continue."
        case .baselineLost: return "Feed-forward is off: the seat baseline was reset. Turn it on again to continue."
        case .seatRegression: return "Feed-forward is off: the seat got louder than before. Turn it on again to continue."
        case .filterTripped(let why): return "Feed-forward is off: the filter tripped (\(why)). Restart audio processing to turn it on again."
        case .filterDisarmed: return "Feed-forward is off: the engine disarmed the filter. Turn it on again to continue."
        case .referenceLost: return "Feed-forward is off: the upstream reference stopped. Turn it on again to continue."
        case .stabilityLost: return "Feed-forward is off: the leakage stability check no longer passes. Turn it on again to continue."
        case .echoRemovalLost: return "Feed-forward is off: echo removal fell below 10 dB, so measure leakage again. Turn it on again afterwards."
        case .waitedTooLong: return "Feed-forward did not start: its checks did not pass in time. Turn it on again to retry."
        case .engineRefused(let why): return "Feed-forward did not start: \(why)."
        }
    }

    static func tripText(_ code: UInt32) -> String {
        switch code {
        case UInt32(N60FeedForwardLiveTripReferenceLost): return "reference lost"
        case UInt32(N60FeedForwardLiveTripNonFinite): return "non-finite signal"
        case UInt32(N60FeedForwardLiveTripEchoAlignmentLost): return "echo removal lost alignment"
        case UInt32(N60FeedForwardLiveTripEchoDiverged): return "echo removal diverged"
        default: return "trip \(code)"
        }
    }
}

/// The pure state machine. One step per Quiet Zone poll; it returns what the engine must do.
struct FeedForwardLiveArmingPolicy: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case off
        /// Requested; the first unmet precondition.
        case waiting(String)
        /// The kernel armed the filter; the anti-noise is ramping in (3 s).
        case fadingIn
        case live
    }

    enum Decision: Equatable, Sendable {
        case none
        case arm(FeedForwardLiveArmGate.Inputs)
        case disarm
    }

    /// A request that has not passed its checks by now goes back to off.
    static let maximumWaitSeconds = 120.0
    /// The fade counts as complete from here.
    static let fadeCompleteGain: Float = 0.999

    private(set) var phase: Phase = .off
    private(set) var lastOff: FeedForwardLiveOffReason?
    private var anchorUID: String?
    private var anchorRate: Double?
    private var requestedAt: Double?
    private var weakProgramme = 0.0
    private var lastProgramme: Double?

    /// Removal under this for `staleProgrammeSeconds` of programme means the model is stale.
    static let staleRemovalDecibels = 10.0
    static let staleProgrammeSeconds = 10.0

    var isOff: Bool { phase == .off }

    /// The user's request. False (and why) unless Quiet Zone is armed and the filter is off.
    mutating func request(quietZone: FeedForwardLiveQuietZoneFacts, now: Double) -> Bool {
        guard phase == .off, quietZone.armed, quietZone.sampleRate != nil, quietZone.outputDeviceUID != nil,
              !quietZone.subwooferActive
        else {
            return false
        }
        weakProgramme = 0
        lastProgramme = nil
        anchorUID = quietZone.outputDeviceUID
        anchorRate = quietZone.sampleRate
        requestedAt = now
        lastOff = nil
        phase = .waiting("starting")
        return true
    }

    /// Returns to off. `disarm` only when the kernel might hold an armed filter.
    mutating func turnOff(_ reason: FeedForwardLiveOffReason) -> Decision {
        guard phase != .off else { return .none }
        phase = .off
        lastOff = reason
        anchorUID = nil
        anchorRate = nil
        requestedAt = nil
        return .disarm
    }

    mutating func step(
        quietZone: FeedForwardLiveQuietZoneFacts, shadow: FeedForwardLiveShadowFacts,
        kernel: FeedForwardLiveKernelFacts?, now: Double
    ) -> Decision {
        switch phase {
        case .off:
            // Nothing asked for output: an armed filter here is a leak, so back it out.
            if case .armed? = kernel?.state { return .disarm }
            return .none
        case .waiting:
            return stepWaiting(quietZone: quietZone, shadow: shadow, kernel: kernel, now: now)
        case .fadingIn, .live:
            return stepPlaying(quietZone: quietZone, shadow: shadow, kernel: kernel)
        }
    }

    /// The engine's answer to `.arm`: `code` is the kernel's `N60FeedForwardLiveArm*`, nil if the gate or
    /// the transport refused.
    mutating func armResult(_ code: UInt32?) -> Decision {
        guard case .waiting = phase else { return .none }
        switch code {
        case UInt32(N60FeedForwardLiveArmOK)?:
            phase = .fadingIn
            return .none
        case UInt32(N60FeedForwardLiveArmTripped)?:
            return turnOff(.filterTripped("an earlier trip"))
        case UInt32(N60FeedForwardLiveArmShortLead)?:
            phase = .waiting("the reference lead is too short")
        case UInt32(N60FeedForwardLiveArmNoWeights)?:
            phase = .waiting("no feed-forward weights yet")
        default:
            phase = .waiting("the live filter is not available")
        }
        return .none
    }

    // MARK: - Steps

    private mutating func stepWaiting(
        quietZone: FeedForwardLiveQuietZoneFacts, shadow: FeedForwardLiveShadowFacts,
        kernel: FeedForwardLiveKernelFacts?, now: Double
    ) -> Decision {
        if let broken = commonBreak(quietZone) { return turnOff(broken) }
        if let requestedAt, now - requestedAt >= Self.maximumWaitSeconds { return turnOff(.waitedTooLong) }
        if case .tripped(let code)? = kernel?.state { return turnOff(.filterTripped(FeedForwardLiveOffReason.tripText(code))) }

        // Condition 3, in order: do-no-harm baseline, engine lease, then the lead gate.
        guard quietZone.hasBaseline else { return wait("capturing the seat baseline") }
        guard quietZone.verdict == .ok else { return wait("the seat check has not cleared yet") }
        guard !quietZone.leaseRequired || quietZone.leaseHealthy else { return wait("the engine lease is not running") }
        guard quietZone.budget.readiness == .physicallyPlausible,
              let preview = quietZone.budget.conservativePreviewSeconds,
              let path = quietZone.budget.antiNoisePathSeconds
        else { return wait("the timing budget is not measured") }
        guard let delay = shadow.pumpDelaySeconds, shadow.referenceRunning else {
            return wait("the upstream reference is not running")
        }
        let gate = FeedForwardLiveArmGate.Inputs(
            featureEnabled: true,  // the engine overrides this with the real flag
            liveOutputAuthorized: true,  // the user's request, owner approval of 2 Nov 2026
            stability: shadow.stability,
            verifiedRemovalDecibels: shadow.verifiedRemovalDecibels,
            leadSeconds: preview - delay,
            requiredLeadSeconds: path + QuietZoneFeedForwardBudgetAnalyzer.requiredReserveSeconds,
            referenceLive: shadow.referenceRunning)
        if case .refused(let why) = FeedForwardLiveArmGate.decide(gate) {
            // E4 S22b3 question 17: the stage needs a few seconds of music to lock and verify.
            return wait(why == FeedForwardLiveArmGate.removalNotVerifiedMessage
                ? "play music for a few seconds so echo removal can lock" : why)
        }
        return .arm(gate)
    }

    private mutating func stepPlaying(
        quietZone: FeedForwardLiveQuietZoneFacts, shadow: FeedForwardLiveShadowFacts,
        kernel: FeedForwardLiveKernelFacts?
    ) -> Decision {
        if let broken = commonBreak(quietZone) { return turnOff(broken) }
        if case .harm = quietZone.verdict { return turnOff(.seatRegression) }
        guard quietZone.hasBaseline, quietZone.verdict != .baselining else { return turnOff(.baselineLost) }
        guard !quietZone.leaseRequired || quietZone.leaseHealthy else { return turnOff(.leaseLost) }
        guard shadow.referenceRunning else { return turnOff(.referenceLost) }
        guard case .passed = shadow.stability else { return turnOff(.stabilityLost) }
        if watchRemoval(shadow) { return turnOff(.echoRemovalLost) }
        guard let kernel else { return turnOff(.engineRefused("the live filter is gone")) }
        switch kernel.state {
        case .tripped(let code): return turnOff(.filterTripped(FeedForwardLiveOffReason.tripText(code)))
        case .idle: return turnOff(.filterDisarmed)
        case .armed:
            if phase == .fadingIn, kernel.gain >= Self.fadeCompleteGain { phase = .live }
            return .none
        }
    }

    /// True once the live removal sat under 10 dB for 10 s of programme (programme time, not wall time).
    private mutating func watchRemoval(_ shadow: FeedForwardLiveShadowFacts) -> Bool {
        let programme = shadow.removalProgrammeSeconds
        defer { lastProgramme = programme }
        guard let removal = shadow.verifiedRemovalDecibels else { return false }
        if removal >= Self.staleRemovalDecibels { weakProgramme = 0; return false }
        // The first reading only sets the baseline; later ones add the programme heard since.
        weakProgramme += max(0, programme - (lastProgramme ?? programme))
        return weakProgramme >= Self.staleProgrammeSeconds
    }

    private func commonBreak(_ quietZone: FeedForwardLiveQuietZoneFacts) -> FeedForwardLiveOffReason? {
        guard quietZone.armed else { return .quietZoneDisarmed }
        if quietZone.subwooferActive { return .engineRefused("not available with a subwoofer yet") }
        if quietZone.outputDeviceUID != anchorUID { return .environmentChanged }
        guard let rate = quietZone.sampleRate, let was = anchorRate, abs(rate - was) < 0.5 else {
            return .environmentChanged
        }
        return nil
    }

    private mutating func wait(_ reason: String) -> Decision {
        phase = .waiting(reason)
        return .none
    }
}

/// The engine's side. `AudioIOEngine` conforms; tests inject a fake.
@MainActor
protocol FeedForwardLiveArmingEngine: AnyObject {
    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32?
    func disarmFeedForwardLive()
    func feedForwardLiveKernelFacts() -> FeedForwardLiveKernelFacts?
}

/// Runs the policy against the engine and publishes the state for the card. Held by the Quiet Zone
/// controller, which polls it and tells it when Quiet Zone disarms. Created only with the flag on.
@MainActor
final class FeedForwardLiveArmingController: ObservableObject {
    @Published private(set) var phase: FeedForwardLiveArmingPolicy.Phase = .off
    /// Fade-in progress, 0 to 1, while armed.
    @Published private(set) var fadeProgress: Double = 0
    @Published private(set) var statusMessage: String?

    private var policy = FeedForwardLiveArmingPolicy()
    private let engine: any FeedForwardLiveArmingEngine
    private let shadowFacts: () -> FeedForwardLiveShadowFacts
    private let clock: () -> Double

    init(
        engine: any FeedForwardLiveArmingEngine,
        shadowFacts: @escaping () -> FeedForwardLiveShadowFacts,
        clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.engine = engine
        self.shadowFacts = shadowFacts
        self.clock = clock
    }

    var isRequested: Bool { !policy.isOff }

    /// The single user action. False when Quiet Zone is not armed or a request is already open.
    @discardableResult
    func request(quietZone: FeedForwardLiveQuietZoneFacts) -> Bool {
        let accepted = policy.request(quietZone: quietZone, now: clock())
        if !accepted {
            statusMessage = quietZone.subwooferActive
                ? "Feed-forward is not available with a subwoofer yet."
                : quietZone.armed
                ? "Feed-forward is already on."
                : "Arm Quiet Zone first; feed-forward starts only from an armed Quiet Zone."
        }
        publish()
        if accepted { poll(quietZone: quietZone) }
        return accepted
    }

    /// The user turns it off.
    func cancel() { force(.user) }

    /// Quiet Zone disarmed, faulted or stopped.
    func quietZoneStopped() { force(.quietZoneDisarmed) }

    func poll(quietZone: FeedForwardLiveQuietZoneFacts) {
        let decision = policy.step(
            quietZone: quietZone, shadow: shadowFacts(), kernel: engine.feedForwardLiveKernelFacts(),
            now: clock())
        apply(decision)
        publish()
    }

    private func force(_ reason: FeedForwardLiveOffReason) {
        apply(policy.turnOff(reason))
        publish()
    }

    private func apply(_ decision: FeedForwardLiveArmingPolicy.Decision) {
        switch decision {
        case .none: break
        case .disarm: engine.disarmFeedForwardLive()
        case .arm(let gate):
            let code = engine.armFeedForwardLive(gate: gate)
            if case .disarm = policy.armResult(code) { engine.disarmFeedForwardLive() }
        }
    }

    private func publish() {
        phase = policy.phase
        statusMessage = policy.lastOff?.message ?? (policy.isOff ? statusMessage : nil)
        if policy.isOff, policy.lastOff == .user { statusMessage = nil }
        switch policy.phase {
        case .fadingIn: fadeProgress = Double(engine.feedForwardLiveKernelFacts()?.gain ?? 0)
        case .live: fadeProgress = 1
        default: fadeProgress = 0
        }
    }
}

extension AudioIOEngine: FeedForwardLiveArmingEngine {
    func feedForwardLiveKernelFacts() -> FeedForwardLiveKernelFacts? {
        feedForwardLiveStatus().flatMap { $0.attached ? FeedForwardLiveKernelFacts($0) : nil }
    }
}

extension FeedForwardLiveShadowFacts {
    /// E4 S22b3: the gate trusts the live stage's own removal (locked, at least 5 s of programme since
    /// the lock), not the shadow's. A stage that is off, searching or refused verifies nothing.
    init(
        stability: FeedForwardLeakageStabilityCheck.Verdict, live: N60FeedForwardLiveEchoStatus?,
        referenceRunning: Bool, pumpDelaySeconds: Double?
    ) {
        var removal: Double?
        var seconds = 0.0
        if let live, live.state == UInt32(N60FeedForwardLiveEchoLocked) {
            seconds = live.programmeSeconds
            if seconds >= Self.minimumVerifiedProgrammeSeconds, live.bandBeforePower > 0, live.bandAfterPower > 0 {
                removal = 10 * log10(live.bandBeforePower / live.bandAfterPower)
            }
        }
        self.init(
            stability: stability, verifiedRemovalDecibels: removal, removalProgrammeSeconds: seconds,
            referenceRunning: referenceRunning, pumpDelaySeconds: pumpDelaySeconds)
    }

    /// Reads the shadow's echo readout and the engine's reference driver.
    @MainActor
    static func read(shadow: QuietZoneFeedForwardShadow, engine: AudioIOEngine) -> FeedForwardLiveShadowFacts {
        let echo = shadow.status.echo
        let driver = engine.feedForwardLiveDriver
        return FeedForwardLiveShadowFacts(
            stability: echo.stability, live: engine.feedForwardLiveStatus()?.echo,
            referenceRunning: driver.state == .running, pumpDelaySeconds: driver.delaySeconds)
    }
}
