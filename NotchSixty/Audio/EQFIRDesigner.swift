import Foundation

// E6 (EQ linear-phase hardening): the EQ FIR design, free of engine state so it can run off the main actor.
//
// Designing a linear-phase EQ is heavy: at 192-384 kHz the default design is 16385 taps through a 65536-point FFT, and the
// 340 ms length is up to 261121 taps through a 1M-point FFT (E33 S27, designed by the core), once per lane and again for
// the cascade with FIR kernels. On the main actor that stalls the UI long enough to look like a
// hang. `design` is a pure function of its inputs (control plane, never the audio thread); the engine runs it on a
// background task, stores the result in `EQFIRProgramCache`, and the unchanged synchronous publish path then hits
// the cache. Realtime impact: none; the render path only sees the immutable snapshot built from the taps.
// Allocation: the tap arrays, on the calling (background) thread. Synchronisation: none; main-actor cache insert.
enum EQFIRDesigner {
    typealias Result = (left: [Float], right: [Float]?, declaredLatencyFrames: UInt32, designInfo: EQLinearPhaseDesignInfo?)

    static func design(_ configuration: StereoEQConfiguration, sampleRate: Double) throws -> Result {
        let signpost = AppSignposts.signposter.beginInterval("eqFIRDesign")
        defer { AppSignposts.signposter.endInterval("eqFIRDesign", signpost) }
        let primaryChannel: EQEditChannel
        switch configuration.channelMode {
        case .linked: primaryChannel = .linked
        case .independent: primaryChannel = .left
        case .midSide: primaryChannel = .mid
        }
        var primary = try designLane(configuration, channel: primaryChannel, sampleRate: sampleRate)

        var secondaryTaps: [Float]?
        if configuration.channelMode != .linked {
            let secondaryChannel: EQEditChannel = configuration.channelMode == .midSide ? .side : .right
            var secondary = try designLane(configuration, channel: secondaryChannel, sampleRate: sampleRate)
            guard secondary.declaredLatencyFrames == primary.declaredLatencyFrames else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let commonCount = max(primary.taps.count, secondary.taps.count)
            if primary.taps.count < commonCount {
                primary.taps.append(contentsOf: repeatElement(0, count: commonCount - primary.taps.count))
            }
            if secondary.taps.count < commonCount {
                secondary.taps.append(contentsOf: repeatElement(0, count: commonCount - secondary.taps.count))
            }
            secondaryTaps = secondary.taps
        }
        return (primary.taps, secondaryTaps, primary.declaredLatencyFrames, primary.designInfo)
    }

    private static func designLane(
        _ configuration: StereoEQConfiguration,
        channel: EQEditChannel,
        sampleRate: Double
    ) throws -> (taps: [Float], declaredLatencyFrames: UInt32, designInfo: EQLinearPhaseDesignInfo?) {
        let baseTaps: [Float]
        let declaredLatency: UInt32
        let designInfo: EQLinearPhaseDesignInfo?
        if configuration.phaseMode == .linearPhase {
            let length = configuration.effectiveLinearPhaseLength
            // A length the FIR engine in use cannot carry is refused by name, never silently shortened.
            if let reason = length.refusal(sampleRate: sampleRate, laneCount: 1) {
                throw EQLinearPhaseLengthError.refused(reason)
            }
            let design = try designLinearPhaseTaps(
                configuration, channel: channel, sampleRate: sampleRate, length: length)
            baseTaps = design.taps
            declaredLatency = design.info.groupDelayFrames
            designInfo = design.info
        } else {
            baseTaps = [1.0]
            declaredLatency = 0
            designInfo = nil
        }

        let kernels = try configuration.firKernels(for: channel, sampleRate: sampleRate)
        return (
            try EQFIRCompiler.cascade(base: baseTaps, kernels: kernels),
            declaredLatency,
            designInfo
        )
    }

    private static func designLinearPhaseTaps(
        _ configuration: StereoEQConfiguration,
        channel: EQEditChannel,
        sampleRate: Double,
        length: EQLinearPhaseLength
    ) throws -> (taps: [Float], info: EQLinearPhaseDesignInfo) {
        let bands = try configuration.linearPhaseBands(for: channel, sampleRate: sampleRate)
        let design = try EQLinearPhaseDesigner.design(bands: bands, sampleRate: sampleRate, length: length)
        return (design.taps, design.info)
    }
}

extension AudioIOEngine {
    /// Designs `configuration`'s EQ FIR on a background task and caches it, so the synchronous publish that follows
    /// designs nothing on the main actor. A no-op when the configuration needs no FIR or the design is already cached.
    /// Cancelling the caller discards the result (the C design itself cannot be interrupted).
    func prepareEQFIRDesignOffMain(_ configuration: StereoEQConfiguration, sampleRate: Double) async throws {
        guard configuration.requiresEQFIRProgram else { return }
        let key = EQFIRProgramKey(configuration, sampleRate: sampleRate)
        guard !eqFIRCache.hasDesign(key) else { return }
        let design = try await Task.detached(priority: .userInitiated) {
            let taps = try EQFIRDesigner.design(configuration, sampleRate: sampleRate)
            return EQFIRDesign(
                left: taps.left, right: taps.right,
                declaredLatencyFrames: taps.declaredLatencyFrames, designInfo: taps.designInfo)
        }.value
        try Task.checkCancellation()
        eqFIRCache.insert(design, for: key)
    }

    /// E33 S27: changes the linear-phase length with the design off the main actor. Refused by name when the length does not
    /// fit the FIR engine or the stage budget on this layout and rate; the stored length is then unchanged.
    func setEQLinearPhaseLengthOffMain(_ length: EQLinearPhaseLength) async throws {
        guard length != stereoEQConfiguration.linearPhaseLength else { return }
        var updated = stereoEQConfiguration
        updated.linearPhaseLength = length
        if updated.phaseMode == .linearPhase, !updated.bypassed {
            let rate = transportSession?.outputFormat.sampleRate ?? nChannelTransportSession?.outputFormat.sampleRate
            if let rate {
                let lanes = Int(nChannelTransportSession?.outputFormat.channelCount ?? 2)
                if let reason = updated.effectiveLinearPhaseLength.refusal(sampleRate: rate, laneCount: lanes) {
                    throw EQLinearPhaseLengthError.refused(reason)
                }
                let rendered = eqAudition.map { updated.auditioned($0) } ?? updated
                eqPhaseModeRequestToken &+= 1
                let token = eqPhaseModeRequestToken
                try await prepareEQFIRDesignOffMain(rendered, sampleRate: rate)
                guard token == eqPhaseModeRequestToken else { return }
            }
        }
        try replaceStereoEQConfiguration(updated)
    }

    /// `setEQPhaseMode` with the FIR design off the main actor: the Phase picker stays responsive while a
    /// linear-phase design runs at high rates. Falls back to the plain synchronous path when no session is running.
    func setEQPhaseModeOffMain(_ mode: EQPhaseMode) async throws {
        eqPhaseModeRequestToken &+= 1
        let token = eqPhaseModeRequestToken
        guard mode != stereoEQConfiguration.phaseMode else { return }
        var updated = stereoEQConfiguration
        updated.phaseMode = mode
        let rendered = eqAudition.map { updated.auditioned($0) } ?? updated
        if rendered.requiresEQFIRProgram {
            let rate = transportSession?.outputFormat.sampleRate
                ?? nChannelTransportSession?.outputFormat.sampleRate
            if let rate { try await prepareEQFIRDesignOffMain(rendered, sampleRate: rate) }
        }
        // A newer Phase request (rapid toggles) supersedes this one, so results never apply out of order.
        guard token == eqPhaseModeRequestToken else { return }
        try setEQPhaseMode(mode)
    }
}

/// E33 S27 (G88): the per-group lane FIRs of a wide session, kept by the design's inputs so a graph rebuild that changes
/// no band list designs nothing. The graph is built on any thread, so the cache takes a lock (control plane only; never
/// the render path). A handful of designs are kept (the longest is 261121 floats per lane list at 384 kHz).
final class EQGroupFIRCache: @unchecked Sendable {
    static let shared = EQGroupFIRCache()
    static let capacity = 6

    private let lock = NSLock()
    private var entries: [(key: EQFIRProgramKey, design: EQFIRDesigner.Result)] = []
    private(set) var designCount = 0

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        entries.removeAll()
    }

    /// The design for `configuration`, running the core design only on a miss (outside the lock, so two threads may
    /// design the same list once each, which is harmless).
    func design(_ configuration: StereoEQConfiguration, sampleRate: Double) throws -> EQFIRDesigner.Result {
        let key = EQFIRProgramKey(configuration, sampleRate: sampleRate)
        lock.lock()
        if let hit = entries.firstIndex(where: { $0.key == key }) {
            let entry = entries.remove(at: hit)
            entries.append(entry)
            lock.unlock()
            return entry.design
        }
        lock.unlock()
        let made = try EQFIRDesigner.design(configuration, sampleRate: sampleRate)
        lock.lock(); defer { lock.unlock() }
        designCount += 1
        entries.append((key, made))
        if entries.count > Self.capacity { entries.removeFirst() }
        return made
    }
}
