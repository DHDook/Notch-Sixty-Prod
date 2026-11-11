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
    /// The permit binding of design note 7. S7 issues real permits (verification, repeat measurement, acceptance);
    /// until then no production code constructs one, so nothing can arm in production.
    struct Permit: Equatable, Sendable {
        var fingerprint: String
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
    }

    let arm = LiveTreatmentArm(feature: .mimoRoomTreatment)

    @Published private(set) var stage: UnifiedGraphMIMOStage?
    @Published private(set) var permit: Permit?
    @Published private(set) var lastRefusal: ArmRefusal?
    /// True from a disarm, trip, rebuild or restage until a re-arm has let the core clear `held`
    /// (the graph must show arm = 0 and trip = 0 first).
    private(set) var latchMayBeHeld = false
    private var armedFingerprint: String?

    private let flags: FeatureFlags
    /// Hands the stage to the engine, which posts the live words (or republishes a changed design).
    /// Throws when the post failed; the controller keeps the last stage and retries it from `observe`.
    var publish: ((UnifiedGraphMIMOStage) throws -> Void)?
    private var pendingPublish: UnifiedGraphMIMOStage?
    private var tapDigest: String?
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

    static func fingerprint(
        stage: UnifiedGraphMIMOStage, outputUID: String?, trimsDB: [Double], laneCount: Int, tapDigest: String? = nil
    ) -> String {
        let digest = tapDigest ?? Self.tapDigest(stage)
        let trims = trimsDB.map { String(format: "%.3f", $0) }.joined(separator: ",")
        let sources = stage.sourceLanes.map(String.init).joined(separator: ",")
        return [
            digest, "src=" + sources,
            "tau=\(stage.tauFrames)", "D=\(stage.filters.decimation)", "T=\(stage.filters.tapCount)",
            "rate=\(stage.filters.sampleRate)", "uid=\(outputUID ?? "-")", "lanes=\(laneCount)", "trim=" + trims,
        ].joined(separator: "|")
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
        latchMayBeHeld = true
    }

    private func currentFingerprint(_ stage: UnifiedGraphMIMOStage, _ context: Context) -> String {
        Self.fingerprint(
            stage: stage, outputUID: context.outputDeviceUID, trimsDB: context.outputTrimsDB, laneCount: context.laneCount,
            tapDigest: tapDigest)
    }

    private func post(_ next: UnifiedGraphMIMOStage) {
        do { try publish?(next); pendingPublish = nil } catch { pendingPublish = next }
    }

    func setPermit(_ permit: Permit?) {
        self.permit = permit
    }

    // MARK: Gates

    func gateFailure(_ context: Context) -> ArmRefusal? {
        guard flags.isEnabled(.mimoTreatment) else { return .featureOff }
        guard let stage else { return .noStagedDesign }
        guard context.engineRunning, context.sampleRate != nil else { return .engineNotRunning }
        guard context.outputDeviceUID != nil else { return .outputUnknown }
        guard !context.videoLatencyMode else { return .videoLatencyMode }
        guard context.stageAttached else { return .stageNotAttached }
        guard context.hardLimitPresent else { return .hardLimitMissing }
        guard context.engineLeaseHeld else { return .engineLeaseMissing }
        guard let permit else { return .noPermit }
        guard permit.fingerprint == currentFingerprint(stage, context) else { return .fingerprintMismatch }
        return nil
    }

    // MARK: Arming

    /// The only way the stage's arm word becomes 1. Checks the gates, lets the core clear a held latch, checks them
    /// again and only then starts the fade-in (the core ramps 0 to 1 over 3 s).
    /// `refresh` re-reads the engine's context after the settle wait, so the arm decision uses the facts at that moment.
    func requestArm(context initial: Context, refresh: (() -> Context)? = nil) async throws {
        var context = initial
        guard !arm.isArmed else { throw ArmRefusal.alreadyArmed }
        if let failure = gateFailure(context) { lastRefusal = failure; throw failure }
        if latchMayBeHeld, var idle = stage {
            idle.armed = false
            idle.trip = false
            stage = idle
            post(idle)
            try await settle()
            guard !arm.isArmed else { throw ArmRefusal.alreadyArmed }
            if let refresh { context = refresh() }
            latchMayBeHeld = false
            if let failure = gateFailure(context) { lastRefusal = failure; throw failure }
        }
        guard var live = stage else { throw ArmRefusal.noStagedDesign }
        try arm.arm(environment: environment(context))
        armedFingerprint = currentFingerprint(live, context)
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
    func observe(context: Context, readback: n60_mimo_readback?) {
        // A disarm word that did not reach the core is re-posted until it does.
        if let pending = pendingPublish { post(pending) }
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
        if let stage, let armedFingerprint, currentFingerprint(stage, context) != armedFingerprint {
            arm.disarm(.downstreamChainChanged)
            return
        }
        if let readback, readback.faultLatched != 0 { arm.disarm(.treatmentFault) }
    }

    private func environment(_ context: Context) -> LiveTreatmentEnvironment {
        // The master volume is common to every lane and never disarms, so the gain the switch compares is pinned.
        LiveTreatmentEnvironment(
            outputDeviceUID: context.outputDeviceUID, sampleRate: context.sampleRate, engineRunning: context.engineRunning,
            inputAvailable: true, outputGainDB: 0)
    }

    private func didDisarm(_ reason: LiveTreatmentDisarmReason) {
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
