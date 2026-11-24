import CryptoKit
import Foundation

/// E19 S6: the control-plane owner of the graph's MIMO treatment stage (`N60_STAGE_MIMO`). It holds the staged design,
/// owns `LiveTreatmentArm(.mimoRoomTreatment)` and decides when the stage's live `arm` word is written (design note 8).
///
/// Rules it enforces:
/// - Arming is one user action (`requestArm`). Launch, wake, device or rate change, a graph rebuild and a stage swap
///   never arm; every one of them leaves the switch off (`graphRebuilt`, `arm.observe`).
/// - The 3 s fade-in starts only after every gate passed: flag on, a permit whose fingerprint matches, the stage
///   attached to the running graph, the output hard limit present, the engine lease held, not video latency mode.
/// - A per-output trim or any change of the chain after the stage breaks the fingerprint and disarms. The master
///   volume is common to every lane and does not (the arm environment pins `outputGainDB`).
/// - The stage's own monitor and thermal budget latch a fault in the core; `observe` turns it into a disarm.
///
/// Control plane only (main actor). The realtime path sees nothing but the two live words in the snapshot.
@MainActor
final class MIMOGraphTreatment: ObservableObject {
    /// The permit binding of design note 7. `issuePermit` (E19 S7, `MIMOTreatmentPermit.swift`) is the production issuer:
    /// verification, repeat measurement and acceptance or class qualification. It refuses until S8 wires the video latency input
    /// and E22 fills the qualification table, so nothing arms in production before then.
    struct Permit: Equatable, Sendable {
        enum Basis: Equatable, Sendable { case unspecified, hardwareAcceptance, classQualification, selfQualification }
        var fingerprint: String
        var issuedAt: Date? = nil
        var basis: Basis = .unspecified
    }

    enum ArmRefusal: Error, Equatable, LocalizedError {
        case featureOff
        case noStagedDesign
        case noPermit
        case fingerprintMismatch
        case videoLatencyMode
        case stageNotAttached
        case hardLimitMissing
        case engineLeaseMissing
        case engineNotRunning
        case outputUnknown
        case alreadyArmed
        /// E19 S12b: a probe arm needs a live probe ticket (issued after SQ1 to SQ4) in place of a permit.
        case noProbeTicket
        /// E19 S12b: the probe plays only the measurement stimulus; programme playback must be stopped first.
        case programmeNotStopped

        var errorDescription: String? {
            switch self {
            case .featureOff: return "MIMO room treatment is switched off."
            case .noStagedDesign: return "No room treatment design is staged."
            case .noPermit: return "No valid permit for this room treatment design."
            case .fingerprintMismatch: return "The room treatment permit no longer matches the design, output or chain."
            case .videoLatencyMode: return "Room treatment is not available in video latency mode."
            case .stageNotAttached: return "The running audio graph does not carry the room treatment stage."
            case .hardLimitMissing: return "The output hard limit is not present."
            case .engineLeaseMissing: return "The engine lease for live treatment is not held."
            case .engineNotRunning: return "Start audio processing before arming."
            case .outputUnknown: return "Select an output device before arming."
            case .alreadyArmed: return "Room treatment is already armed."
            case .noProbeTicket: return "No treated measurement is approved for this design."
            case .programmeNotStopped: return "Stop programme playback before the treated measurement."
            }
        }
    }

    /// What the engine knows at the moment of a decision.
    struct Context: Equatable, Sendable {
        var engineRunning: Bool
        var outputDeviceUID: String?
        var sampleRate: Double?
        var stageAttached: Bool
        var hardLimitPresent: Bool
        var engineLeaseHeld: Bool
        var videoLatencyMode: Bool
        /// Per-output trim (dB) of every graph lane, program lanes then sub lanes.
        var outputTrimsDB: [Double]
        var laneCount: Int
        /// E19 S9: digest of the routing's ROUTE entries and way parameters (`MIMORoutedTreatmentPlanner.digest`); empty when unrouted.
        var routedDigest = ""
        /// E19 S12a (SQ7): the engine-held part of a self-qualified permit's binding (`MIMOTreatmentSelfQualification.engineBinding`).
        /// Empty (and unused) for the other permit bases.
        var selfQualificationBinding = ""
    }

    let arm = LiveTreatmentArm(feature: .mimoRoomTreatment)

    @Published private(set) var stage: UnifiedGraphMIMOStage?
    @Published private(set) var permit: Permit?
    @Published private(set) var lastRefusal: ArmRefusal?
    /// True from a disarm, trip, rebuild or restage until a re-arm has let the core clear `held`
    /// (the graph must show arm = 0 and trip = 0 first).
    private(set) var latchMayBeHeld = false
    private var armedFingerprint: String?
    /// E19 S12b: the probe in progress or last ended (`MIMOGraphTreatment+Probe.swift`). In memory only; never a permit.
    @Published var probeSession: MIMOTreatmentProbeSession?
    /// True while the current arm is a probe arm: its fingerprint carries the self-qualification binding.
    var armedAsProbe = false
    /// Set by whoever stops programme playback for the measurement (E24 stimulus owner). Nothing sets it in production before S12c.
    var probeProgrammeMuted = false
    /// Time source for the per-seat limit; injectable so tests do not wait.
    var clock: () -> Date = { Date() }

    let flags: FeatureFlags
    /// E19 S12a (SQ7): digest of the evidence a self-qualified permit was issued on (seat set, capture digests, microphone).
    /// `updateSelfQualificationEvidence` moves it when the evidence changes, which voids the permit.
    var selfQualificationEvidenceDigest = ""
    /// Hands the stage to the engine, which posts the live words (or republishes a changed design).
    /// Throws when the post failed; the controller keeps the last stage and retries it from `observe`.
    var publish: ((UnifiedGraphMIMOStage) throws -> Void)?
    private var pendingPublish: UnifiedGraphMIMOStage?
    private var tapDigest: String?
    /// Digest of the room correction, speaker IR and per-lane delay and polarity chain after the stage; the engine sets it
    /// whenever it builds a graph (`chainDigest(of:)`). Part of the fingerprint, so a change of the chain disarms (note 7).
    var chainDigest = ""
    /// E19 S10b (G38): the user's support overrides by speaker, so the speaker list and the permit's class key count in-band ways
    /// over the window the design uses. Set by the screen's controller; empty means the default window.
    var routedSupportOverrides: [UUID: ClosedRange<Double>] = [:]
    /// Time the core needs to see arm = 0 and trip = 0 before a re-arm; injectable so tests do not wait.
    var settle: () async throws -> Void = { try await Task.sleep(nanoseconds: 100_000_000) }

    init(flags: FeatureFlags) {
        self.flags = flags
        arm.onDisarm = { [weak self] reason in self?.didDisarm(reason) }
    }

    var isArmed: Bool { arm.isArmed }

    /// Fingerprint of everything the permit binds that the graph side knows: taps, sources, tau, rate family, output and
    /// the downstream chain's per-output trims. S7 extends it with the room-correction and routed fields.
    static func tapDigest(_ stage: UnifiedGraphMIMOStage) -> String {
        var hasher = SHA256()
        stage.filters.taps.withUnsafeBytes { hasher.update(bufferPointer: $0) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Digest of the chain downstream of the stage that the plant depends on: room correction and speaker IR taps, and each
    /// lane's delay, calibration delay and polarity. Trims are listed separately; the master volume is deliberately absent.
    static func chainDigest(of configuration: UnifiedGraphConfiguration) -> String {
        var hasher = SHA256()
        func add(_ program: UnifiedGraphFIRProgram?) {
            guard let program else { hasher.update(data: Data([0])); return }
            hasher.update(data: Data([1]))
            program.left.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            (program.right ?? []).withUnsafeBytes { hasher.update(bufferPointer: $0) }
            withUnsafeBytes(of: program.declaredLatencyFrames) { hasher.update(bufferPointer: $0) }
        }
        add(configuration.stereoStages.roomFIR)
        add(configuration.stereoStages.speakerIR)
        for lane in configuration.lanes {
            let text = "\(lane.delayMilliseconds)|\(lane.delayFrames)|\(lane.fractionalDelayFrames ?? -1)|\(lane.polarityInverted)|\(lane.calibrationDelayFrames)|\(lane.preBassDelayMilliseconds);"
            hasher.update(data: Data(text.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func fingerprint(
        stage: UnifiedGraphMIMOStage, outputUID: String?, trimsDB: [Double], laneCount: Int, tapDigest: String? = nil,
        chainDigest: String = "", routedDigest: String = ""
    ) -> String {
        let digest = tapDigest ?? Self.tapDigest(stage)
        let trims = trimsDB.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let sources = stage.sourceLanes.map(String.init).joined(separator: ",")
        return ([
            digest, "src=" + sources,
            "tau=\(stage.tauFrames)", "D=\(stage.filters.decimation)", "T=\(stage.filters.tapCount)",
            "rate=\(stage.filters.sampleRate)", "uid=\(outputUID ?? "-")", "lanes=\(laneCount)", "trim=" + trims,
            "support=" + stage.supportRangesHz.map { String(format: "%.2f", $0) }.joined(separator: ","), "chain=" + chainDigest,
        ] + (routedDigest.isEmpty ? [] : ["routed=" + routedDigest])
        ).joined(separator: "|")
    }

    // MARK: Staging

    /// Stages a design (control plane). Disarms a running treatment; never arms.
    func stage(_ design: UnifiedGraphMIMOStage?) {
        if arm.isArmed { arm.disarm(.transportReconfigured) }
        var next = design
        next?.armed = false
        next?.trip = false
        stage = next
        pendingPublish = nil
        tapDigest = next.map(Self.tapDigest)
        permit = nil
        selfQualificationEvidenceDigest = ""
        latchMayBeHeld = true
        probeEnd(.fingerprintChanged)
    }

    /// E19 S12a (SQ7): the evidence behind a self-qualified permit changed (a seat, weight, capture or the microphone).
    /// The digest moves, so the permit no longer matches and an armed treatment disarms on the next `observe`.
    func updateSelfQualificationEvidence(_ evidence: MIMOTreatmentSelfQualificationEvidence?) {
        selfQualificationEvidenceDigest = evidence?.bindingDigest ?? ""
    }

    /// `selfQualified` defaults to the held permit's basis, so every gate and the armed-time check compare the binding the
    /// permit was issued with; the other bases compute exactly the fingerprint they always did.
    func currentFingerprint(_ stage: UnifiedGraphMIMOStage, _ context: Context, selfQualified: Bool? = nil) -> String {
        let base = Self.fingerprint(
            stage: stage, outputUID: context.outputDeviceUID, trimsDB: context.outputTrimsDB, laneCount: context.laneCount,
            tapDigest: tapDigest, chainDigest: chainDigest, routedDigest: context.routedDigest)
        guard selfQualified ?? (permit?.basis == .selfQualification) else { return base }
        return base + "|sq=" + selfQualificationEvidenceDigest + "|" + context.selfQualificationBinding
    }

    private func post(_ next: UnifiedGraphMIMOStage) {
        do { try publish?(next); pendingPublish = nil } catch { pendingPublish = next }
    }

    func setPermit(_ permit: Permit?) {
        self.permit = permit
    }

    // MARK: Gates

    func gateFailure(_ context: Context) -> ArmRefusal? {
        if let common = commonGateFailure(context) { return common }
        guard let stage else { return .noStagedDesign }
        guard let permit else { return .noPermit }
        if permit.basis == .selfQualification, !flags.isEnabled(.selfQualification) { return .noPermit }
        guard permit.fingerprint == currentFingerprint(stage, context) else { return .fingerprintMismatch }
        return nil
    }

    /// The gates every arm shares, permit or probe: flag, staged design, running engine, output, latency mode, attached stage,
    /// hard limit and lease.
    func commonGateFailure(_ context: Context) -> ArmRefusal? {
        guard flags.isEnabled(.mimoTreatment) else { return .featureOff }
        guard stage != nil else { return .noStagedDesign }
        guard context.engineRunning, context.sampleRate != nil else { return .engineNotRunning }
        guard context.outputDeviceUID != nil else { return .outputUnknown }
        guard !context.videoLatencyMode else { return .videoLatencyMode }
        guard context.stageAttached else { return .stageNotAttached }
        guard context.hardLimitPresent else { return .hardLimitMissing }
        guard context.engineLeaseHeld else { return .engineLeaseMissing }
        return nil
    }

    // MARK: Arming

    /// The only way the stage's arm word becomes 1. Checks the gates, lets the core clear a held latch, checks them
    /// again and only then starts the fade-in (the core ramps 0 to 1 over 3 s).
    /// `refresh` re-reads the engine's context after the settle wait, so the arm decision uses the facts at that moment.
    func requestArm(context initial: Context, refresh: (() -> Context)? = nil) async throws {
        try await armStage(context: initial, refresh: refresh, probe: false)
    }

    /// Shared by the permit arm and the probe arm (E19 S12b): the same gates, the same settle wait, the same fade-in. Only the
    /// authority differs (`gateFailure` needs a permit, `probeGateFailure` a live ticket).
    func armStage(context initial: Context, refresh: (() -> Context)?, probe: Bool) async throws {
        var context = initial
        func gates(_ context: Context) -> ArmRefusal? { probe ? probeGateFailure(context) : gateFailure(context) }
        guard !arm.isArmed else { throw ArmRefusal.alreadyArmed }
        if let failure = gates(context) { lastRefusal = failure; throw failure }
        if latchMayBeHeld, var idle = stage {
            idle.armed = false
            idle.trip = false
            stage = idle
            post(idle)
            try await settle()
            guard !arm.isArmed else { throw ArmRefusal.alreadyArmed }
            if let refresh { context = refresh() }
            latchMayBeHeld = false
            if let failure = gates(context) { lastRefusal = failure; throw failure }
        }
        guard var live = stage else { throw ArmRefusal.noStagedDesign }
        try arm.arm(environment: environment(context))
        armedAsProbe = probe
        armedFingerprint = currentFingerprint(live, context, selfQualified: probe ? true : nil)
        if probe { probeArmed() }
        lastRefusal = nil
        live.armed = true
        live.trip = false
        stage = live
        post(live)
        if pendingPublish != nil { arm.disarm(.transportReconfigured) }
    }

    func userDisarm() { arm.disarm(.user) }

    /// A new graph was published (engine rebuild): the core mutes the delta and holds it off, so the switch goes off
    /// too and re-arming goes through `requestArm`.
    func graphRebuilt() {
        latchMayBeHeld = true
        if arm.isArmed { arm.disarm(.transportReconfigured) }
    }

    /// Periodic control-plane check. `readback` is the stage's telemetry (nil when unavailable).
    func observe(context: Context, readback: n60_mimo_readback?, hardLimitGainReductionDB: Double? = nil) {
        // A disarm word that did not reach the core is re-posted until it does.
        if let pending = pendingPublish { post(pending) }
        probeObserveUnarmed(context: context)
        guard arm.isArmed else { return }
        if !flags.isEnabled(.mimoTreatment) { arm.disarm(.featureSwitchedOff); return }
        arm.observe(environment(context))
        guard arm.isArmed else { return }
        // The gates that must hold for the whole armed time, not only at the start.
        if !context.stageAttached || !context.hardLimitPresent || !context.engineLeaseHeld {
            arm.disarm(.transportReconfigured)
            return
        }
        if context.videoLatencyMode { arm.disarm(.transportReconfigured); return }
        if let stage, let armedFingerprint,
           currentFingerprint(stage, context, selfQualified: armedAsProbe ? true : nil) != armedFingerprint {
            arm.disarm(.downstreamChainChanged)
            return
        }
        if armedAsProbe, probeObserveArmed(readback: readback, hardLimitGainReductionDB: hardLimitGainReductionDB) { return }
        if let readback, readback.faultLatched != 0 { arm.disarm(.treatmentFault); return }
        // Dead-man lease (E19 G22): every poll tick while armed changes word [6]; a silent host latches the core's fault.
        if var beating = stage {
            beating.heartbeat = beating.heartbeat >= UnifiedGraphMIMOStage.maxHeartbeat ? 1 : beating.heartbeat + 1
            stage = beating
            post(beating)
        }
    }

    private func environment(_ context: Context) -> LiveTreatmentEnvironment {
        // The master volume is common to every lane and never disarms, so the gain the switch compares is pinned.
        LiveTreatmentEnvironment(
            outputDeviceUID: context.outputDeviceUID, sampleRate: context.sampleRate, engineRunning: context.engineRunning,
            inputAvailable: true, outputGainDB: 0)
    }

    private func didDisarm(_ reason: LiveTreatmentDisarmReason) {
        probeDidDisarm(reason)
        armedAsProbe = false
        armedFingerprint = nil
        latchMayBeHeld = true
        guard var next = stage else { return }
        next.armed = false
        // A fault or an automatic disarm trips (10 ms fade, latched until re-armed); the user's own disarm only fades.
        next.trip = reason != .user
        stage = next
        post(next)
    }
}
