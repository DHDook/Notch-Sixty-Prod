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
/// E33 S11c: the request counter and newest pending configuration of the off-main EQ edits (main actor only).
struct EQOffMainState {
    var token = 0
    var pending: StereoEQConfiguration?
}

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
    /// The configuration an off-main edit builds on: the newest edit still being designed, else the stored one.
    var eqEditBase: StereoEQConfiguration { eqOffMain.pending ?? stereoEQConfiguration }

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
        guard length != eqEditBase.linearPhaseLength else { return }
        var updated = eqEditBase
        updated.linearPhaseLength = length
        eqOffMain.token &+= 1
        let token = eqOffMain.token
        eqOffMain.pending = updated
        defer { if token == eqOffMain.token { eqOffMain.pending = nil } }
        if updated.phaseMode == .linearPhase, !updated.bypassed {
            let rate = transportSession?.outputFormat.sampleRate ?? nChannelTransportSession?.outputFormat.sampleRate
            if let rate {
                let lanes = Int(nChannelTransportSession?.outputFormat.channelCount ?? 2)
                if let reason = updated.effectiveLinearPhaseLength.refusal(sampleRate: rate, laneCount: lanes) {
                    throw EQLinearPhaseLengthError.refused(reason)
                }
                let rendered = eqAudition.map { updated.auditioned($0) } ?? updated
                try await prepareEQFIRDesignOffMain(rendered, sampleRate: rate)
                try await prepareEQGroupFIRsOffMain(rendered)
                guard token == eqOffMain.token else { return }
            }
        }
        guard token == eqOffMain.token else { return }
        try replaceStereoEQConfiguration(updated)
    }

    /// E33 S11c (G97, G98): true when applying an EQ edit would design a linear-phase FIR (the session lane, and on a wide
    /// session the group lists) on the thread that applies it, so the caller should use the off-main path.
    var eqEditDesignsOffMain: Bool {
        stereoEQConfiguration.phaseMode == .linearPhase && !stereoEQConfiguration.bypassed
    }

    /// Designs the group lane FIRs of a wide session off the main actor (G98), so the graph rebuild that follows hits
    /// `EQGroupFIRCache`. A no-op on a stereo or binaural session, a mixed-phase or bypassed EQ, or with no group lists.
    func prepareEQGroupFIRsOffMain(_ configuration: StereoEQConfiguration) async throws {
        guard configuration.phaseMode == .linearPhase, !configuration.bypassed,
              let session = nChannelTransportSession,
              let shape = UnifiedGraphLayoutShape(roles: session.routePlan.programLayout.roles),
              shape.laneCount > 2 else { return }
        let rate = session.outputFormat.sampleRate
        try await Task.detached(priority: .userInitiated) {
            _ = try configuration.groupCurves(shape: shape, sampleRate: rate)
        }.value
        try Task.checkCancellation()
    }

    /// E33 S11c (G97, G98): applies `updated` with every linear-phase design run off the main actor first. A newer request
    /// (a later edit, a Phase or length change) supersedes this one, so results never apply out of order; a superseded
    /// request returns without applying. The stored configuration changes only at the final synchronous publish, which
    /// then hits the design caches. With no linear phase it is the plain synchronous apply.
    func applyEQConfigurationOffMain(_ updated: StereoEQConfiguration) async throws {
        eqOffMain.token &+= 1
        let token = eqOffMain.token
        eqOffMain.pending = updated
        defer { if token == eqOffMain.token { eqOffMain.pending = nil } }
        let rendered = eqAudition.map { updated.auditioned($0) } ?? updated
        if rendered.phaseMode == .linearPhase, !rendered.bypassed {
            let rate = transportSession?.outputFormat.sampleRate ?? nChannelTransportSession?.outputFormat.sampleRate
            if let rate {
                try await prepareEQFIRDesignOffMain(rendered, sampleRate: rate)
                try await prepareEQGroupFIRsOffMain(rendered)
            }
        }
        guard token == eqOffMain.token else { return }
        try replaceStereoEQConfiguration(updated)
    }

    /// `updateEQBand` with the design off the main actor (G97). The edit builds on the newest pending configuration, so
    /// two quick edits to different bands both land (the later request applies both).
    func updateEQBandOffMain(_ band: EQBand) async throws {
        var updated = eqEditBase
        guard updated.editableBands.contains(where: { $0.id == band.id }) else { return }
        updated.updateEditableBand(band)
        try await applyEQConfigurationOffMain(updated)
    }

    /// `setEQPhaseMode` with the FIR design off the main actor: the Phase picker stays responsive while a
    /// linear-phase design runs at high rates. Falls back to the plain synchronous path when no session is running.
    func setEQPhaseModeOffMain(_ mode: EQPhaseMode) async throws {
        eqOffMain.token &+= 1
        let token = eqOffMain.token
        guard mode != eqEditBase.phaseMode else {
            // Already what an in-flight edit will leave; that edit was superseded by the bump, so land it here (its design is cached or runs now).
            if let pending = eqOffMain.pending {
                try await applyEQConfigurationOffMain(pending)
            }
            return
        }
        var updated = eqEditBase
        updated.phaseMode = mode
        eqOffMain.pending = updated
        defer { if token == eqOffMain.token { eqOffMain.pending = nil } }
        let rendered = eqAudition.map { updated.auditioned($0) } ?? updated
        if rendered.requiresEQFIRProgram {
            let rate = transportSession?.outputFormat.sampleRate
                ?? nChannelTransportSession?.outputFormat.sampleRate
            if let rate {
                try await prepareEQFIRDesignOffMain(rendered, sampleRate: rate)
                try await prepareEQGroupFIRsOffMain(rendered)
            }
        }
        // A newer Phase request (rapid toggles) supersedes this one, so results never apply out of order.
        guard token == eqOffMain.token else { return }
        try replaceStereoEQConfiguration(updated)
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
