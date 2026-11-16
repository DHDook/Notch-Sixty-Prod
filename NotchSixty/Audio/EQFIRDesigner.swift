import Foundation

// E6 (EQ linear-phase hardening): the EQ FIR design, free of engine state so it can run off the main actor.
//
// Designing a linear-phase EQ is heavy: at 192-384 kHz the design is 16385 taps through a 65536-point FFT, once per
// lane and again for the cascade with FIR kernels. On the main actor that stalls the UI long enough to look like a
// hang. `design` is a pure function of its inputs (control plane, never the audio thread); the engine runs it on a
// background task, stores the result in `EQFIRProgramCache`, and the unchanged synchronous publish path then hits
// the cache. Realtime impact: none; the render path only sees the immutable snapshot built from the taps.
// Allocation: the tap arrays, on the calling (background) thread. Synchronisation: none; main-actor cache insert.
enum EQFIRDesigner {
    typealias Result = (left: [Float], right: [Float]?, declaredLatencyFrames: UInt32, designInfo: N60LinearPhaseEQDesignInfo?)

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
    ) throws -> (taps: [Float], declaredLatencyFrames: UInt32, designInfo: N60LinearPhaseEQDesignInfo?) {
        let baseTaps: [Float]
        let declaredLatency: UInt32
        let designInfo: N60LinearPhaseEQDesignInfo?
        if configuration.phaseMode == .linearPhase {
            let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
            guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            let design = try designLinearPhaseTaps(
                configuration, channel: channel, sampleRate: sampleRate, tapCount: tapCount)
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
        tapCount: Int
    ) throws -> (taps: [Float], info: N60LinearPhaseEQDesignInfo) {
        let bands = try configuration.linearPhaseBands(for: channel, sampleRate: sampleRate)
        var taps = [Float](repeating: 0, count: tapCount)
        var designInfo = N60LinearPhaseEQDesignInfo()
        let designed = taps.withUnsafeMutableBufferPointer { tapBuffer -> Bool in
            guard let tapBase = tapBuffer.baseAddress else { return false }
            if bands.isEmpty {
                return N60LinearPhaseEQDesign(sampleRate, nil, 0, tapBase, UInt32(tapBuffer.count), &designInfo)
            }
            return bands.withUnsafeBufferPointer { bandBuffer in
                guard let bandBase = bandBuffer.baseAddress else { return false }
                return N60LinearPhaseEQDesign(
                    sampleRate, bandBase, UInt32(bandBuffer.count), tapBase, UInt32(tapBuffer.count), &designInfo)
            }
        }
        guard designed else { throw EQConfigurationError.linearPhaseDesignFailed }
        return (taps, designInfo)
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
