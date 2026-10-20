import Foundation

/// E6 S8: turns what the shipping engine already computes (the kernel DSP snapshot, the
/// multichannel route plan, the sub calibration) into a `UnifiedGraphConfiguration`.
/// Returns nil (never throws) when the core cannot reproduce the snapshot, so the caller
/// keeps the kernel path for that snapshot. Control thread only.
enum UnifiedGraphTranslator {
    /// Stereo snapshot to a two-lane configuration, or nil when the kernel must render it.
    static func stereoConfiguration(
        snapshot: inout N60DSPGraphSnapshot,
        sampleRate: Double,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80
    ) -> UnifiedGraphConfiguration? {
        guard withUnsafePointer(to: &snapshot, {
            N60UnifiedGraphSnapshotUnsupportedReason($0) == N60UnifiedGraphSupported
        }) else { return nil }

        var left: [UnifiedGraphPEQSection] = []
        var right: [UnifiedGraphPEQSection] = []
        withUnsafePointer(to: &snapshot) { pointer in
            var band = N60UnifiedGraphBand()
            var index: UInt32 = 0
            while !pointer.pointee.eqBypassed, N60UnifiedGraphReadBand(pointer, index, &band) {
                index += 1
                guard band.enabled else { continue }
                let section = UnifiedGraphPEQSection(
                    type: Int(band.type), frequencyHz: band.frequencyHz,
                    gainDB: band.gainDB, q: band.q
                )
                if band.channelMask & UInt8(N60_EQ_CHANNEL_LEFT) != 0 { left.append(section) }
                if band.channelMask & UInt8(N60_EQ_CHANNEL_RIGHT) != 0 { right.append(section) }
            }
        }

        let output = snapshot.outputGainLinear * snapshot.masterGainLinear
        var configuration = UnifiedGraphConfiguration(
            sampleRate: sampleRate,
            lanes: [
                UnifiedGraphLane(outputGain: output * snapshot.balanceGainLeftLinear, eq: left),
                UnifiedGraphLane(outputGain: output * snapshot.balanceGainRightLinear, eq: right),
            ]
        )
        configuration.inputGain = snapshot.inputGainLinear * snapshot.headroomGainLinear
        guard let stages = stereoStages(snapshot: &snapshot, configuration: &configuration) else {
            return nil
        }
        configuration.stereoStages = stages
        if snapshot.protection.limiterEnabled || snapshot.protection.truePeakGuardEnabled {
            let p = snapshot.protection
            let ceilingDB = 20.0 * log10(Double(max(p.limiterCeilingLinear, 1e-6)))
            guard ceilingDB >= -20, ceilingDB <= 0 else { return nil }
            configuration.protection = UnifiedGraphProtection(
                limiterEnabled: p.limiterEnabled,
                ceilingDB: ceilingDB,
                attackMilliseconds: Double(p.limiterAttackMs),
                releaseMilliseconds: Double(p.limiterReleaseMs),
                lookAheadMilliseconds: Double(p.limiterLookAheadMs),
                truePeakGuard: p.truePeakGuardEnabled,
                oversampling: (p.limiterEnabled && p.truePeakGuardEnabled) ? 4 : 2
            )
        }
        if !subwoofers.isEmpty {
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: crossoverHz, lfeLane: nil, subwoofers: subwoofers
            )
        }
        return configuration
    }

    /// The kernel stages between the EQ and the output gain that the core reproduces. The
    /// eligibility check has already accepted every parameter list read here; a failed read is
    /// still treated as ineligible rather than approximated.
    private static func stereoStages(
        snapshot: inout N60DSPGraphSnapshot,
        configuration: inout UnifiedGraphConfiguration
    ) -> UnifiedGraphStereoStages? {
        var stages = UnifiedGraphStereoStages()
        stages.midSideEQ = snapshot.eqMidSideMode && !snapshot.eqBypassed
        var ok = true
        withUnsafePointer(to: &snapshot) { pointer in
            let dynamics = pointer.pointee.dynamics
            if dynamics.compressor.enabled {
                var values = [Float](repeating: 0, count: 10)
                if N60UnifiedGraphCompressorParams(pointer, &values) { stages.compressor = values } else { ok = false }
            }
            if dynamics.expander.enabled {
                var values = [Float](repeating: 0, count: 6)
                if N60UnifiedGraphExpanderParams(pointer, &values) { stages.expander = values } else { ok = false }
            }
            if dynamics.pauseGate.enabled {
                var values = [Float](repeating: 0, count: 5)
                if N60UnifiedGraphPauseGateParams(pointer, &values) { stages.pauseGate = values } else { ok = false }
            }
            if pointer.pointee.ambientCompensation.enabled {
                var values = [Float](repeating: 0, count: 10)
                if N60UnifiedGraphAmbientParams(pointer, &values) { stages.ambient = values } else { ok = false }
            }
            if pointer.pointee.symmetryBalance.enabled {
                stages.symmetryPosition = Float(pointer.pointee.symmetryBalance.position)
            }
            if pointer.pointee.speakerCrossfeed.enabled {
                stages.crossfeedAmount = pointer.pointee.speakerCrossfeed.amount
            }
            if pointer.pointee.crosstalkCancellation.enabled {
                let c = pointer.pointee.crosstalkCancellation
                stages.crosstalk = [Float(c.headShadowFrequencyHz), c.amount]
            }
            if pointer.pointee.interChannelDelay.enabled {
                var frames: (UInt32, UInt32) = (0, 0)
                let read = withUnsafeMutablePointer(to: &frames) { tuple in
                    tuple.withMemoryRebound(to: UInt32.self, capacity: 2) { N60UnifiedGraphIntegerDelay(pointer, $0) }
                }
                if read {
                    configuration.lanes[0].delayFrames = frames.0
                    configuration.lanes[1].delayFrames = frames.1
                } else { ok = false }
            }
        }
        return ok ? stages : nil
    }

    /// A multichannel speaker layout with `programChannels` lanes and 0 to 8 sub lanes.
    /// `trimsDB` is the per-lane calibration gain; lane `lfeLane` (if any) carries the LFE.
    static func multichannelConfiguration(
        sampleRate: Double,
        programChannels: Int,
        lfeLane: Int? = nil,
        trimsDB: [Double] = [],
        masterGain: Float = 1,
        subwoofers: [UnifiedGraphSubwoofer] = [],
        crossoverHz: Double = 80,
        delaysMilliseconds: [Double] = []
    ) -> UnifiedGraphConfiguration {
        var lanes: [UnifiedGraphLane] = []
        for index in 0..<programChannels {
            var lane = UnifiedGraphLane(outputGain: masterGain)
            if index < trimsDB.count { lane.preGain = Float(pow(10.0, trimsDB[index] / 20.0)) }
            if index < delaysMilliseconds.count { lane.delayMilliseconds = delaysMilliseconds[index] }
            lanes.append(lane)
        }
        var configuration = UnifiedGraphConfiguration(sampleRate: sampleRate, lanes: lanes)
        if !subwoofers.isEmpty {
            configuration.bassManagement = UnifiedGraphBassManagement(
                crossoverHz: crossoverHz, lfeLane: lfeLane, subwoofers: subwoofers
            )
        }
        return configuration
    }

    /// Binaural profile data for `layoutSpec`: `orientations * channels * 2 * taps` responses.
    struct BinauralProfile {
        var taps: UInt32
        var orientations: UInt32 = 1
        var yawStartDeg: Float = 0
        var yawStepDeg: Float = 0
        var wrap: UInt32 = 0
        var equalEarChannel: Int32 = -1
        var responses: [Float]
    }

    /// A standard layout (`N60_LAYOUT_*`) rendered to speakers or, with a profile, to ears
    /// on lanes 0 and 1, through the core's own layout builder.
    static func layoutSpec(
        layoutIdentifier: UInt32,
        sampleRate: Double,
        binaural: BinauralProfile? = nil,
        headphoneCrossfeed: Float = 0,
        linkedDynamics: Bool = false,
        protection: Bool = true,
        maxBlockFrames: UInt32 = 16_384
    ) throws -> UnifiedGraphSpec {
        var layout = n60_layout()
        layout.structSize = UInt32(MemoryLayout<n60_layout>.size)
        let layoutStatus = n60_layout_standard(layoutIdentifier, &layout)
        guard layoutStatus == N60_STATUS_OK else { throw UnifiedGraphError.coreStatus(layoutStatus.rawValue) }

        var options = n60_layout_options()
        options.structSize = UInt32(MemoryLayout<n60_layout_options>.size)
        options.sampleRate = sampleRate
        options.maxBlockFrames = maxBlockFrames
        options.mode = binaural == nil ? N60_MODE_SPEAKERS.rawValue : N60_MODE_BINAURAL.rawValue
        options.linkedDynamics = linkedDynamics ? 1 : 0
        options.headphoneCrossfeed = headphoneCrossfeed
        options.protection = protection ? 1 : 0

        var built: OpaquePointer?
        func build(_ options: inout n60_layout_options) -> n60_status {
            withUnsafePointer(to: &layout) { layoutPointer in
                options.layout = layoutPointer
                return n60_layout_graph_build(&options, &built)
            }
        }
        let status: n60_status
        if let binaural {
            status = binaural.responses.withUnsafeBufferPointer { responses in
                var profile = n60_binaural_profile()
                profile.structSize = UInt32(MemoryLayout<n60_binaural_profile>.size)
                profile.taps = binaural.taps
                profile.orientations = binaural.orientations
                profile.yawStartDeg = binaural.yawStartDeg
                profile.yawStepDeg = binaural.yawStepDeg
                profile.wrap = binaural.wrap
                profile.equalEarChannel = binaural.equalEarChannel
                profile.responses = responses.baseAddress
                return withUnsafePointer(to: &profile) { profilePointer in
                    options.binaural = profilePointer
                    return build(&options)
                }
            }
        } else {
            status = build(&options)
        }
        guard status == N60_STATUS_OK, let built else {
            throw UnifiedGraphError.coreStatus(status.rawValue)
        }
        defer { n60_layout_graph_free(built) }
        guard let description = n60_layout_graph_desc(built) else {
            throw UnifiedGraphError.invalidConfiguration("layout description")
        }
        var spec = UnifiedGraphSpec(copying: description)
        spec.maxBlockFrames = maxBlockFrames
        return spec
    }
}
