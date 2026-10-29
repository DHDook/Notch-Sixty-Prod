import Combine
import Foundation

/// Per-poll facts the Quiet Zone controller hands to the adaptive coordinator.
struct AdaptiveTonalLivePollInput: Sendable {
    var now: TimeInterval
    var armed: Bool
    var controllerGeneration: UInt64?
    var engineGeneration: UInt64
    /// The offline target is fully ramped in (the controller's active stage).
    var targetRampedIn: Bool
    var hasBaseline: Bool
    var verdict: DoNoHarmVerdict
    var measurement: DoNoHarmVerifier.Measurement?
    var seeds: [AdaptiveQuietZoneSeed]
    /// The planned peak per channel at full strength (linear); the cap in force before a move.
    var plannedPeakLinear: Double
    var leaseRequired: Bool
    var leaseRenewed: Bool
}

/// What the coordinator asks of the controller after a poll.
enum AdaptiveTonalLiveRequest: Equatable, Sendable {
    /// Drop the S16 baseline so the next windows (anti-noise out) capture a new one.
    case beginRebaseline
    /// Disarm with this reason.
    case disarm(LiveTreatmentDisarmReason)
}

enum AdaptiveTonalLiveState: Equatable, Sendable {
    case off
    case waiting(AdaptiveTonalGateReason)
    case adapting
    case reSolving(MicrophoneMovePhase)

    var displayName: String {
        switch self {
        case .off: return "Adaptive tuning is off"
        case .waiting(let reason): return reason.displayName
        case .adapting: return "Adapting to the room"
        case .reSolving(let phase):
            switch phase {
            case .idle: return "Adapting to the room"
            case .reducing: return "The microphone moved: backing off"
            case .reidentifying: return "The microphone moved: measuring the new position"
            case .rebaselining: return "The microphone moved: measuring the seat without anti-noise"
            case .rampingIn: return "The microphone moved: bringing anti-noise back"
            case .adapting: return "The microphone moved: re-tuning"
            }
        }
    }
}

/// E4 S18b: the control-plane side of the adaptive tonal canceller. Owns the worker, the output
/// gate, the supervised re-solve after the microphone moved and the S17 events. The Quiet Zone
/// controller calls `poll` once per analysis window; microphone blocks arrive through
/// `receiveMicrophoneFrames`. It writes no audio: the worker writes the render mailbox, and only
/// while `AdaptiveTonalOutputGate` is open or the output is being silenced.
@MainActor
final class AdaptiveTonalLiveCoordinator: ObservableObject {
    @Published private(set) var state: AdaptiveTonalLiveState = .off
    /// Plain-language note after a successful re-solve, until the next arm.
    @Published private(set) var lastResolveNote: String?

    /// Safety events for the S17 flight recorder.
    var onEvent: ((SafetyEventKind, String) -> Void)?

    private(set) var gate: AdaptiveTonalGateDecision = .closed(.notArmed)
    private(set) var resolver = MicrophoneMoveResolver()
    private(set) var latestReport = AdaptiveTonalLiveReport()
    private(set) var command = AdaptiveTonalLiveCommand()

    private let linkProvider: () -> (any AdaptiveTonalLiveLink)?
    private let clock: () -> TimeInterval
    private let hostTicksPerSecond: Double
    private var worker: AdaptiveTonalLiveWorker?
    private var epoch: UUID?
    private var generation = 0
    private var pendingBlocks = 0
    private var submitted: UInt64 = 0
    private var lastApplied: UInt64 = 0
    private var dropPending = false
    private var seeds: [AdaptiveQuietZoneSeed] = []
    private var armGeneration: UInt64 = 0
    private var capInForce: Float = 0
    private var attemptCap: Float = 0
    private var capSteppingBackSince: TimeInterval?
    private var rampInStartedAt: TimeInterval?
    private var rebaselineStartedAt: TimeInterval?
    private var rebaselineBegan = false
    private var gapTimes: [TimeInterval] = []
    private var lastGaps: UInt64 = 0
    private var lastModelResets: UInt64 = 0
    private var levelHistory: [(time: TimeInterval, level: Double)] = []
    private var reductionHistory: [(time: TimeInterval, reduction: Double)] = []
    private var lastGateReason: AdaptiveTonalGateReason?
    private var faulted = false
    private var firstWriteLogged = false
    static let maximumPendingBlocks = 8
    static let maximumGapsPer10Seconds = 2
    static let capStepBackDB = 3.0
    static let capStepBackSeconds = 5.0

    var isRebaselining: Bool { resolver.holdsOutputSilent }
    var hasWorker: Bool { worker != nil }

    init(
        ambient: AmbientCompensationController?,
        linkProvider: @escaping () -> (any AdaptiveTonalLiveLink)?,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        hostTicksPerSecond: Double = AdaptiveTonalLiveWorker.hostTicksPerSecond
    ) {
        self.linkProvider = linkProvider
        self.clock = clock
        self.hostTicksPerSecond = hostTicksPerSecond
        ambient?.anchoredMicrophoneFramesObserver = { [weak self] frames, rate, epoch, skipped, hostTime in
            self?.receiveMicrophoneFrames(frames, sampleRate: rate, epoch: epoch, skipped: skipped, hostTime: hostTime)
        }
    }

    /// A new arm starts from nothing: no worker, no resolver history, no held cap.
    func reset() {
        dropWorker()
        armGeneration = 0
        resolver.reset()
        command = AdaptiveTonalLiveCommand()
        gate = .closed(.notArmed)
        latestReport = AdaptiveTonalLiveReport()
        capInForce = 0
        attemptCap = 0
        capSteppingBackSince = nil
        rampInStartedAt = nil
        rebaselineStartedAt = nil
        rebaselineBegan = false
        gapTimes = []
        lastGaps = 0
        lastModelResets = 0
        levelHistory = []
        reductionHistory = []
        lastGateReason = nil
        faulted = false
        firstWriteLogged = false
        lastResolveNote = nil
        state = .off
    }

    // MARK: - Microphone blocks

    func receiveMicrophoneFrames(
        _ frames: [Float],
        sampleRate: Double,
        epoch: UUID,
        skipped: Bool,
        hostTime: UInt64?
    ) {
        guard armGeneration != 0, !frames.isEmpty, !faulted else { return }
        let tones = AdaptiveQuietZoneShadowTone.tones(from: seeds)
        guard !tones.isEmpty else { return }
        if pendingBlocks >= Self.maximumPendingBlocks {
            dropPending = true
            return
        }
        var discontinuity = epoch != self.epoch || skipped || dropPending
        dropPending = false
        if worker == nil || worker?.sampleRate != sampleRate
            || !AdaptiveQuietZoneShadowTone.sameDesign(worker?.tones ?? [], tones) {
            dropWorker()
            guard let link = linkProvider(),
                  let created = AdaptiveTonalLiveWorker(
                      sampleRate: sampleRate, tones: tones,
                      hostTicksPerSecond: hostTicksPerSecond, link: link
                  ) else {
                return
            }
            worker = created
            discontinuity = false
            onEvent?(.environment, "Adaptive tuning started at \(Int(sampleRate.rounded())) Hz.")
        }
        self.epoch = epoch
        guard let worker else { return }
        let current = generation
        pendingBlocks += 1
        submitted += 1
        let order = submitted
        var toSend = command
        toSend.armGeneration = armGeneration
        command.reseedFromReference = false
        command.acknowledgeMove = false
        worker.submit(
            frames, hostTime: hostTime, discontinuity: discontinuity, now: clock(), command: toSend
        ) { [weak self] report in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBlocks -= 1
                guard self.generation == current, order > self.lastApplied else { return }
                self.lastApplied = order
                self.latestReport = report
            }
        }
    }

    /// Waits for queued blocks and their results (tests).
    func flushForTesting() async {
        worker?.flush()
        while pendingBlocks > 0 { await Task.yield() }
    }

    // MARK: - Poll

    /// Called by the controller once per analysis window. Returns what the controller must do.
    func poll(_ input: AdaptiveTonalLivePollInput) -> [AdaptiveTonalLiveRequest] {
        var requests: [AdaptiveTonalLiveRequest] = []
        guard input.armed, let controllerGeneration = input.controllerGeneration else {
            if armGeneration != 0 { reset() }
            return requests
        }
        if armGeneration == 0 {
            armGeneration = input.engineGeneration &+ 1
            capInForce = Float(input.plannedPeakLinear)
        }
        seeds = input.seeds
        let report = latestReport
        trackFaults(report, now: input.now)

        if faulted {
            requests.append(.disarm(.adaptiveFault))
            return requests
        }

        // The supervised re-solve.
        let observation = observe(report, input)
        let action = resolver.step(observation)
        switch action {
        case .none:
            break
        case .reduceGains:
            attemptCap = capInForce > 0 ? capInForce * Float(pow(10.0, -MicrophoneMoveResolver.attemptCapReductionDB / 20)) : 0
            capSteppingBackSince = nil
            onEvent?(.environment, "The microphone moved: backing the anti-noise off 10 dB.")
        case .beginReidentify:
            command.reidentify = true
            onEvent?(.environment, "Measuring the speaker-to-microphone path at the new position.")
        case .rampOutAndBaseline:
            command.reidentify = false
            command.silence = true
            rebaselineStartedAt = input.now
            rebaselineBegan = false
            onEvent?(.environment, "Anti-noise out to measure the seat at the new position.")
        case .reseedAndRampIn:
            command.silence = false
            command.reseedFromReference = true
            command.acknowledgeMove = true
            rampInStartedAt = input.now
            onEvent?(.environment, "Bringing the anti-noise back for the new position.")
        case .succeeded:
            rampInStartedAt = nil
            capSteppingBackSince = input.now
            lastResolveNote = "Re-solved after the microphone moved."
            onEvent?(.environment, "Re-solved after the microphone moved.")
        case .disarm(let failure):
            command.silence = true
            onEvent?(.disarm, "Microphone moved: \(failure.explanation).")
            requests.append(.disarm(.microphoneMoved))
            return requests
        }
        if resolver.phase == .rebaselining, !rebaselineBegan, let started = rebaselineStartedAt,
           input.now - started >= MicrophoneMoveResolver.rampOutSeconds {
            rebaselineBegan = true
            requests.append(.beginRebaseline)
        }
        if resolver.phase != .rebaselining { rebaselineBegan = false }

        // The cap: ramp-in after a re-solve, then step back to the pre-move level.
        var cap = attemptCap
        if let started = rampInStartedAt {
            let fraction = min(1, max(0.02, (input.now - started) / MicrophoneMoveResolver.rampInSeconds))
            cap = max(Float(1.0e-4), attemptCap * Float(fraction))
        } else if let since = capSteppingBackSince, attemptCap > 0 {
            let steps = Int((input.now - since) / Self.capStepBackSeconds)
            let stepped = attemptCap * Float(pow(10.0, Double(steps) * Self.capStepBackDB / 20))
            if capInForce > 0, stepped >= capInForce {
                attemptCap = 0
                capSteppingBackSince = nil
                cap = 0
            } else {
                cap = stepped
            }
        }
        command.attemptCapLinear = cap

        // The gate.
        let decision = AdaptiveTonalOutputGate.evaluate(AdaptiveTonalGateInput(
            flagEnabled: true,
            armed: input.armed,
            controllerGeneration: controllerGeneration,
            engineGeneration: input.engineGeneration,
            targetRampedIn: input.targetRampedIn,
            hasBaseline: input.hasBaseline && !(resolver.phase == .rebaselining && !rebaselineBegan),
            verdict: input.verdict,
            guardTripped: report.guardTripped,
            leaseRequired: input.leaseRequired,
            leaseRenewed: input.leaseRenewed,
            pathWithinTolerance: !report.micMoved,
            resolveRunning: resolver.isRunning,
            coreAdapting: report.anyAdapting,
            coreFault: report.pathFault
        ))
        gate = decision
        command.writeEnabled = decision.isOpen && !command.silence
        command.hold = !decision.isOpen
        publishState(decision)
        return requests
    }

    // MARK: - Helpers

    private func observe(_ report: AdaptiveTonalLiveReport, _ input: AdaptiveTonalLivePollInput) -> MicrophoneMoveObservation {
        let measurement = input.measurement
        let over = measurement?.worstIncreaseDB ?? -100
        let reduction = measurement?.minimumToneReductionDB ?? (measurement == nil ? 0 : 99)
        levelHistory.append((input.now, report.weightLevelDBFS))
        reductionHistory.append((input.now, reduction))
        levelHistory.removeAll { input.now - $0.time > 2 }
        reductionHistory.removeAll { input.now - $0.time > 2 }
        let levelThen = levelHistory.last(where: { input.now - $0.time >= 1 })?.level
        let reductionThen = reductionHistory.last(where: { input.now - $0.time >= 1 })?.reduction
        let rise = levelThen.map { report.weightLevelDBFS - $0 } ?? 0
        let drop = reductionThen.map { reduction - $0 } ?? 0
        let atCap = attemptCap > 0 && report.playedPeakLinear >= Double(attemptCap) * 0.95
        return MicrophoneMoveObservation(
            now: input.now,
            moveLatched: report.micMoved,
            seatOverBaselineDB: over,
            seatMinimumReductionDB: reduction,
            antiNoiseRiseDB: rise,
            seatDropDB: drop,
            atAttemptCap: atCap,
            pathStepDegrees: report.pathStepDegrees,
            pathRateDegreesPerSecond: report.pathRateDegreesPerSecond,
            newBaselineReady: rebaselineBegan && input.hasBaseline
        )
    }

    private func trackFaults(_ report: AdaptiveTonalLiveReport, now: TimeInterval) {
        if report.gaps > lastGaps {
            for _ in 0 ..< Int(report.gaps - lastGaps) { gapTimes.append(now) }
            lastGaps = report.gaps
        }
        gapTimes.removeAll { now - $0 > 10 }
        if report.modelResets > lastModelResets || report.pathFault || report.trackingLost
            || gapTimes.count > Self.maximumGapsPer10Seconds {
            faulted = true
            let why = report.trackingLost ? "a tone drifted out of the tracking range"
                : report.pathFault ? "a non-finite path or weight"
                : (report.modelResets > lastModelResets ? "the adaptive model had to reset" : "too many gaps in the microphone")
            onEvent?(.environment, "Adaptive fault: \(why).")
        }
        lastModelResets = report.modelResets
    }

    private func publishState(_ decision: AdaptiveTonalGateDecision) {
        let reason: AdaptiveTonalGateReason? = { if case .closed(let r) = decision { return r } else { return nil } }()
        if reason != lastGateReason {
            lastGateReason = reason
            onEvent?(.environment, reason.map { "Adaptive output held: \($0.displayName)." } ?? "Adaptive output open.")
        }
        if resolver.isRunning {
            state = .reSolving(resolver.phase)
        } else if let reason {
            state = .waiting(reason)
        } else {
            state = .adapting
        }
    }

    private func dropWorker() {
        worker?.retire()
        worker = nil
        epoch = nil
        generation += 1
        pendingBlocks = 0
    }
}
