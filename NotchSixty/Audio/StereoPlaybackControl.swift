import Foundation

enum EQChannelMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case linked
    case independent
    case midSide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linked: return "Linked"
        case .independent: return "Independent"
        case .midSide: return "Mid/Side"
        }
    }
}

enum EQEditChannel: String, CaseIterable, Identifiable, Codable, Sendable {
    case linked
    case left
    case right
    case mid
    case side

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linked: return "Linked"
        case .left: return "Left"
        case .right: return "Right"
        case .mid: return "Mid"
        case .side: return "Side"
        }
    }
}

struct StereoEQConfiguration: Equatable, Codable, Sendable {
    static let bandGainRange = -24.0...24.0

    var channelMode: EQChannelMode
    var editChannel: EQEditChannel
    var phaseMode: EQPhaseMode
    var bypassed: Bool
    var linkedBands: [EQBand]
    var leftBands: [EQBand]
    var rightBands: [EQBand]
    var midBands: [EQBand]
    var sideBands: [EQBand]
    var independentSeeded: Bool
    var midSideSeeded: Bool

    init(
        channelMode: EQChannelMode = .linked,
        editChannel: EQEditChannel = .linked,
        phaseMode: EQPhaseMode = .minimumPhase,
        bypassed: Bool = false,
        linkedBands: [EQBand] = [],
        leftBands: [EQBand] = [],
        rightBands: [EQBand] = [],
        midBands: [EQBand] = [],
        sideBands: [EQBand] = [],
        independentSeeded: Bool = false,
        midSideSeeded: Bool = false
    ) {
        self.channelMode = channelMode
        switch channelMode {
        case .linked:
            self.editChannel = .linked
        case .independent:
            self.editChannel = editChannel == .right ? .right : .left
        case .midSide:
            self.editChannel = editChannel == .side ? .side : .mid
        }
        self.phaseMode = phaseMode
        self.bypassed = bypassed
        self.linkedBands = linkedBands
        self.leftBands = leftBands
        self.rightBands = rightBands
        self.midBands = midBands
        self.sideBands = sideBands
        self.independentSeeded = independentSeeded
        self.midSideSeeded = midSideSeeded
    }

    var editableBands: [EQBand] {
        switch channelMode {
        case .linked:
            return linkedBands
        case .independent:
            return editChannel == .right ? rightBands : leftBands
        case .midSide:
            return editChannel == .side ? sideBands : midBands
        }
    }

    var enabledBandCount: Int {
        switch channelMode {
        case .linked:
            return linkedBands.lazy.filter(\.enabled).count
        case .independent:
            return leftBands.lazy.filter(\.enabled).count + rightBands.lazy.filter(\.enabled).count
        case .midSide:
            return midBands.lazy.filter(\.enabled).count + sideBands.lazy.filter(\.enabled).count
        }
    }

    mutating func setChannelMode(_ mode: EQChannelMode) {
        guard channelMode != mode else { return }
        if mode == .independent && !independentSeeded {
            leftBands = linkedBands
            rightBands = linkedBands
            independentSeeded = true
        }
        if mode == .midSide && !midSideSeeded {
            midBands = linkedBands
            sideBands = linkedBands
            midSideSeeded = true
        }
        channelMode = mode
        switch mode {
        case .linked: editChannel = .linked
        case .independent: editChannel = editChannel == .right ? .right : .left
        case .midSide: editChannel = editChannel == .side ? .side : .mid
        }
    }

    mutating func setEditChannel(_ channel: EQEditChannel) {
        switch channelMode {
        case .linked:
            editChannel = .linked
        case .independent:
            editChannel = channel == .right ? .right : .left
        case .midSide:
            editChannel = channel == .side ? .side : .mid
        }
    }

    mutating func replaceEditableBands(_ bands: [EQBand]) {
        switch channelMode {
        case .linked:
            linkedBands = bands
        case .independent:
            if editChannel == .right {
                rightBands = bands
            } else {
                leftBands = bands
            }
        case .midSide:
            if editChannel == .side {
                sideBands = bands
            } else {
                midBands = bands
            }
        }
    }

    mutating func updateEditableBand(_ band: EQBand) {
        var bands = editableBands
        guard let index = bands.firstIndex(where: { $0.id == band.id }) else { return }
        bands[index] = band
        replaceEditableBands(bands)
    }

    mutating func removeEditableBand(id: UUID) {
        var bands = editableBands
        bands.removeAll { $0.id == id }
        replaceEditableBands(bands)
    }

    private func validatedEnabledBands(_ bands: [EQBand], sampleRate: Double) throws -> [EQBand] {
        guard bands.count <= EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [EQBand] = []
        result.reserveCapacity(bands.count)
        for (index, band) in bands.enumerated() where band.enabled {
            if band.type == .fir {
                guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
                try kernel.validate(for: sampleRate)
                result.append(band)
                continue
            }
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
            if band.type == .linkwitzTransform {
                guard band.linkwitzTargetHz.isFinite,
                      band.linkwitzTargetHz > 0,
                      band.linkwitzTargetHz < sampleRate * 0.5,
                      band.linkwitzTargetQ.isFinite,
                      band.linkwitzTargetQ > 0 else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
            }
            if band.dynamic.enabled {
                guard band.type.supportsDynamicEQ,
                      DynamicEQBandConfiguration.frequencyRange.contains(band.frequencyHz),
                      DynamicEQBandConfiguration.qRange.contains(band.q),
                      band.dynamic.isValid,
                      !(band.type == .notch && band.dynamic.direction != .cutOnly) else {
                    throw EQConfigurationError.invalidBand(index: index)
                }
            }
            if band.frequencyHz < sampleRate * 0.5 {
                result.append(band)
            }
        }
        return result
    }

    private func dynamicBoostDB(in bands: [EQBand]) -> Double {
        bands.lazy
            .filter { $0.enabled && $0.type.supportsDynamicEQ && $0.dynamic.enabled }
            .reduce(0.0) { partial, band in
                let dynamic = band.dynamic
                let boost = dynamic.direction == .cutOnly ? 0.0 : max(0.0, dynamic.maxBoostDB)
                return partial + boost
            }
    }

    private func conservativeAutomaticHeadroomDB(
        dynamics: DynamicsConfiguration
    ) -> Double {
        guard dynamics.automaticHeadroom.enabled else { return 0 }

        func channelBoost(_ bands: [EQBand]) -> Double {
            bands.lazy.filter(\.enabled).reduce(0.0) { partial, band in
                if band.type == .fir {
                    return partial + (band.firKernel?.conservativeBoostDB ?? 0.0)
                }
                return partial + max(0.0, band.gainDB)
            }
        }
        let staticBoost: Double
        if bypassed {
            staticBoost = 0
        } else {
            switch channelMode {
            case .linked: staticBoost = channelBoost(linkedBands)
            case .independent: staticBoost = max(channelBoost(leftBands), channelBoost(rightBands))
            case .midSide: staticBoost = max(channelBoost(midBands), channelBoost(sideBands))
            }
        }

        let dynamicBoost: Double
        if bypassed {
            dynamicBoost = 0
        } else {
            switch channelMode {
            case .linked:
                dynamicBoost = dynamicBoostDB(in: linkedBands)
            case .independent:
                dynamicBoost = max(dynamicBoostDB(in: leftBands), dynamicBoostDB(in: rightBands))
            case .midSide:
                dynamicBoost = max(dynamicBoostDB(in: midBands), dynamicBoostDB(in: sideBands))
            }
        }
        return min(dynamics.automaticHeadroom.maxAttenuationDB, staticBoost + dynamicBoost)
    }

    private func makeDomainDynamicEQSnapshot(sampleRate: Double) throws -> N60DynamicEQSnapshot {
        var snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate)
        let domain: N60DynamicEQDomain
        switch channelMode {
        case .linked: domain = N60DynamicEQDomainLinkedStereo
        case .independent: domain = N60DynamicEQDomainDualMono
        case .midSide: domain = N60DynamicEQDomainMidSide
        }
        guard N60DynamicEQSnapshotSetDomain(&snapshot, domain) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }

        func compileLane(_ source: [EQBand], lane: N60DynamicEQLane) throws -> Int {
            let validated = try validatedEnabledBands(source, sampleRate: sampleRate)
            let dynamicBands = validated.filter { $0.dynamic.enabled }
            var outputIndex: UInt32 = 0
            for (sourceIndex, band) in dynamicBands.enumerated() {
                guard let shape = band.type.dynamicEQShape else {
                    throw EQConfigurationError.invalidBand(index: sourceIndex)
                }
                let dynamic = band.dynamic
                guard N60DynamicEQSnapshotSetBandForLane(
                    &snapshot, sampleRate, lane, outputIndex, true, shape,
                    band.frequencyHz, Float(band.q), 0,
                    Float(dynamic.thresholdDB), Float(dynamic.ratio), Float(dynamic.rangeDB),
                    Float(dynamic.attackMs), Float(dynamic.releaseMs), dynamic.direction.cType,
                    Float(dynamic.boostThresholdDB), Float(dynamic.boostRatio), Float(dynamic.maxBoostDB),
                    dynamic.detectorMode.cType, Float(dynamic.rmsWindowMs)
                ) else {
                    throw EQConfigurationError.invalidBand(index: sourceIndex)
                }
                outputIndex += 1
            }
            return Int(outputIndex)
        }

        let count: Int
        switch channelMode {
        case .linked:
            count = try compileLane(linkedBands, lane: N60DynamicEQLanePrimary)
        case .independent:
            let primaryCount = try compileLane(leftBands, lane: N60DynamicEQLanePrimary)
            let secondaryCount = try compileLane(rightBands, lane: N60DynamicEQLaneSecondary)
            count = primaryCount + secondaryCount
        case .midSide:
            let primaryCount = try compileLane(midBands, lane: N60DynamicEQLanePrimary)
            let secondaryCount = try compileLane(sideBands, lane: N60DynamicEQLaneSecondary)
            count = primaryCount + secondaryCount
        }
        guard N60DynamicEQSnapshotSetEnabled(&snapshot, !bypassed && count > 0) else {
            throw DynamicsConfigurationError.invalidDynamicEQ
        }
        return snapshot
    }

    private func publishMinimumPhaseBand(
        _ band: EQBand,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        if band.type == .fir { return }
        for section in try band.compiledSections(sampleRate: graph.sampleRate) {
            let compiledCapacity = UInt32(EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND))
            guard renderIndex < compiledCapacity else {
                throw EQConfigurationError.invalidBand(index: Int(renderIndex))
            }
            let ok: Bool
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            }
            guard ok else { throw EQConfigurationError.invalidBand(index: Int(renderIndex)) }
            renderIndex += 1
        }
    }

    private func mixedPhaseSourceSections(
        _ bands: [EQBand],
        sampleRate: Double
    ) throws -> [N60BiquadBandSnapshot] {
        var source: [N60BiquadBandSnapshot] = []
        for band in try validatedEnabledBands(bands, sampleRate: sampleRate) {
            if band.type == .fir { continue }
            if band.type == .allPass { throw EQConfigurationError.allPassRequiresMinimumPhase }
            source.append(contentsOf: try band.compiledSections(sampleRate: sampleRate))
        }
        return source
    }

    private func appendMixedPhaseCorrection(
        for bands: [EQBand],
        sampleRate: Double,
        into graph: inout N60DSPGraphSnapshot,
        renderIndex: inout UInt32,
        channelMask: UInt8? = nil
    ) throws {
        let source = try mixedPhaseSourceSections(bands, sampleRate: sampleRate)
        var design = N60MixedPhaseDesignInfo()
        let designed = source.withUnsafeBufferPointer { buffer in
            N60MixedPhaseDesign(sampleRate, buffer.baseAddress, UInt32(buffer.count), &design)
        }
        guard designed else { throw EQConfigurationError.mixedPhaseDesignFailed }
        let userCapacity = EQConfiguration.maximumBandCount * 2 * Int(N60_MAX_EQ_COMPILED_SECTIONS_PER_BAND)
        let totalCapacity = UInt32(userCapacity + 12)
        for correctionIndex in 0..<design.sectionCount {
            let section = N60MixedPhaseDesignSectionAt(&design, correctionIndex)
            guard renderIndex < totalCapacity else { throw EQConfigurationError.mixedPhaseDesignFailed }
            let ok: Bool
            if let channelMask {
                ok = N60DSPGraphSnapshotSetEQPreparedBandForChannels(
                    &graph, renderIndex, channelMask, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            } else {
                ok = N60DSPGraphSnapshotSetEQPreparedBand(
                    &graph, renderIndex, section.type,
                    section.frequencyHz, section.gainDB, section.q,
                    section.coefficients, true
                )
            }
            guard ok else { throw EQConfigurationError.mixedPhaseDesignFailed }
            renderIndex += 1
        }
        graph.mixedPhaseCorrectionSectionCount += design.sectionCount
    }

    var requiresEQFIRProgram: Bool {
        guard !bypassed else { return false }
        if phaseMode == .linearPhase { return true }
        let activeBanks: [[EQBand]]
        switch channelMode {
        case .linked: activeBanks = [linkedBands]
        case .independent: activeBanks = [leftBands, rightBands]
        case .midSide: activeBanks = [midBands, sideBands]
        }
        return activeBanks.contains { bands in
            bands.contains { $0.enabled && $0.type == .fir }
        }
    }

    func firKernels(for channel: EQEditChannel, sampleRate: Double) throws -> [EQFIRKernel] {
        let source: [EQBand]
        switch channelMode {
        case .linked: source = linkedBands
        case .independent: source = channel == .right ? rightBands : leftBands
        case .midSide: source = channel == .side ? sideBands : midBands
        }
        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)
        return try bands.compactMap { band in
            guard band.type == .fir else { return nil }
            guard let kernel = band.firKernel else { throw EQConfigurationError.firKernelRequired }
            try kernel.validate(for: sampleRate)
            return kernel
        }
    }

    func makeGraphSnapshot(
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration,
        dynamicsConfiguration: DynamicsConfiguration = DynamicsConfiguration(),
        playbackConfiguration: PlaybackControlConfiguration,
        masterGainLinear: Float = 1.0
    ) throws -> N60DSPGraphSnapshot {
        guard bassManagementConfiguration.frequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(bassManagementConfiguration.frequencyHz)
        }
        guard bassManagementConfiguration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(bassManagementConfiguration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(bassManagementConfiguration.subGainDB)
        }
        guard bassManagementConfiguration.subPhaseAlignmentFrequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(bassManagementConfiguration.subPhaseAlignmentFrequencyHz) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentFrequency(
                bassManagementConfiguration.subPhaseAlignmentFrequencyHz
            )
        }
        guard bassManagementConfiguration.subPhaseAlignmentQ.isFinite,
              BassManagementConfiguration.subPhaseAlignmentQRange.contains(bassManagementConfiguration.subPhaseAlignmentQ) else {
            throw BassManagementConfigurationError.invalidSubPhaseAlignmentQ(
                bassManagementConfiguration.subPhaseAlignmentQ
            )
        }

        var compiledDynamics = dynamicsConfiguration
        // EQ-band dynamics are compiled below into a domain-aware realtime snapshot.
        // Keep the older standalone DynamicEQConfiguration empty so it cannot
        // accidentally create a second shared layer.
        compiledDynamics.dynamicEQ = DynamicEQConfiguration()

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.inputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.inputPreampDB)
        let automaticHeadroomDB = playbackConfiguration.globalBypassed
            ? 0.0 : conservativeAutomaticHeadroomDB(dynamics: dynamicsConfiguration)
        graph.headroomGainLinear = DSPGainConfiguration.linearGain(
            forDB: gainConfiguration.headroomAttenuationDB - automaticHeadroomDB)
        graph.outputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.outputGainDB)
        graph.masterGainLinear = masterGainLinear
        let balance = playbackConfiguration.balanceLinearGains
        graph.balanceGainLeftLinear = balance.left
        graph.balanceGainRightLinear = balance.right
        guard N60DSPGraphSnapshotSetSymmetryBalance(
            &graph,
            playbackConfiguration.symmetryBalancePosition,
            playbackConfiguration.symmetryBalanceEnabled
        ) else {
            throw PlaybackControlConfigurationError.invalidSymmetryBalance(
                playbackConfiguration.symmetryBalancePosition
            )
        }
        guard N60DSPGraphSnapshotSetSpeakerCrossfeed(
            &graph,
            playbackConfiguration.speakerCrossfeedAmount,
            playbackConfiguration.speakerCrossfeedEnabled
        ) else {
            throw PlaybackControlConfigurationError.invalidSpeakerCrossfeed(
                playbackConfiguration.speakerCrossfeedAmount
            )
        }
        guard PlaybackControlConfiguration.crosstalkCancellationAmountRange.contains(
            playbackConfiguration.crosstalkCancellationAmount
        ) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkCancellationAmount(
                playbackConfiguration.crosstalkCancellationAmount
            )
        }
        guard PlaybackControlConfiguration.crosstalkHeadShadowFrequencyRange.contains(
            playbackConfiguration.crosstalkHeadShadowFrequencyHz
        ) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(
                playbackConfiguration.crosstalkHeadShadowFrequencyHz
            )
        }
        guard N60DSPGraphSnapshotSetCrosstalkCancellation(
            &graph,
            playbackConfiguration.crosstalkCancellationAmount,
            playbackConfiguration.crosstalkHeadShadowFrequencyHz,
            playbackConfiguration.crosstalkCancellationEnabled
        ) else {
            throw PlaybackControlConfigurationError.invalidCrosstalkHeadShadowFrequency(
                playbackConfiguration.crosstalkHeadShadowFrequencyHz
            )
        }
        graph.bypassed = playbackConfiguration.globalBypassed
        graph.auditionMode = playbackConfiguration.auditionMode.cType
        guard N60DSPGraphSnapshotSetInterChannelDelay(&graph, playbackConfiguration.interChannelDelayMs) else {
            throw PlaybackControlConfigurationError.invalidInterChannelDelay(playbackConfiguration.interChannelDelayMs)
        }
        graph.eqBypassed = bypassed
        graph.eqMidSideMode = channelMode == .midSide
        N60DSPGraphSnapshotClearEQ(&graph)

        if phaseMode != .linearPhase && !bypassed && !graph.bypassed {
            var renderIndex: UInt32 = 0
            switch channelMode {
            case .linked:
                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(band, into: &graph, renderIndex: &renderIndex)
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: linkedBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex
                    )
                }
            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: leftBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                    try appendMixedPhaseCorrection(
                        for: rightBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            case .midSide:
                for band in try validatedEnabledBands(midBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                }
                for band in try validatedEnabledBands(sideBands, sampleRate: sampleRate) {
                    if phaseMode == .mixedPhase && band.type == .allPass {
                        throw EQConfigurationError.allPassRequiresMinimumPhase
                    }
                    try publishMinimumPhaseBand(
                        band, into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
                if phaseMode == .mixedPhase {
                    graph.mixedPhaseEnabled = true
                    try appendMixedPhaseCorrection(
                        for: midBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_LEFT)
                    )
                    try appendMixedPhaseCorrection(
                        for: sideBands, sampleRate: sampleRate,
                        into: &graph, renderIndex: &renderIndex,
                        channelMask: UInt8(N60_EQ_CHANNEL_RIGHT)
                    )
                }
            }
        }

        guard N60DSPGraphSnapshotSetCrossover(
            &graph,
            bassManagementConfiguration.frequencyHz,
            bassManagementConfiguration.topology.cType,
            bassManagementConfiguration.monitorMode.cType,
            DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB),
            bassManagementConfiguration.subPolarityInverted,
            bassManagementConfiguration.enabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        guard N60DSPGraphSnapshotSetSubPhaseAlignment(
            &graph,
            bassManagementConfiguration.subPhaseAlignmentFrequencyHz,
            bassManagementConfiguration.subPhaseAlignmentQ,
            bassManagementConfiguration.subPhaseAlignmentEnabled
        ) else {
            throw BassManagementConfigurationError.graphDesignFailed
        }
        graph.dynamics = try compiledDynamics.makeSnapshot(sampleRate: sampleRate)
        graph.dynamics.dynamicEQ = try makeDomainDynamicEQSnapshot(sampleRate: sampleRate)
        graph.protection = try compiledDynamics.makeProtectionSnapshot(sampleRate: sampleRate)
        let denoiserLatency = graph.dynamics.spectralDenoiser.enabled
            ? UInt64(graph.dynamics.spectralDenoiser.latencyFrames)
            : 0
        let protectionLatency = UInt64(graph.protection.latencyFrames)
        let totalLatency = UInt64(graph.latencyFrames) + denoiserLatency + protectionLatency
        guard totalLatency < UInt64(N60_MAX_AUDITION_DELAY_FRAMES) else {
            throw DynamicsConfigurationError.invalidOversampling
        }
        graph.latencyFrames = UInt32(totalLatency)
        return graph
    }

    func linearPhaseBands(for channel: EQEditChannel, sampleRate: Double) throws -> [N60LinearPhaseEQBand] {
        let source: [EQBand]
        switch channelMode {
        case .linked:
            source = linkedBands
        case .independent:
            source = channel == .right ? rightBands : leftBands
        case .midSide:
            source = channel == .side ? sideBands : midBands
        }
        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)
        guard !bands.contains(where: { $0.type == .allPass }) else {
            throw EQConfigurationError.allPassRequiresMinimumPhase
        }
        var result: [N60LinearPhaseEQBand] = []
        result.reserveCapacity(bands.count * 2)
        for (index, band) in bands.enumerated() {
            do {
                for section in try band.compiledSections(sampleRate: sampleRate) {
                    var cBand = N60LinearPhaseEQBand()
                    cBand.enabled = true
                    cBand.type = section.type
                    cBand.frequencyHz = section.frequencyHz
                    cBand.gainDB = section.gainDB
                    cBand.q = section.q
                    cBand.usesPreparedCoefficients = true
                    cBand.preparedCoefficients = section.coefficients
                    result.append(cBand)
                }
            } catch {
                throw EQConfigurationError.invalidBand(index: index)
            }
        }
        return result
    }
}

enum FIRUpdatePolicy {
    static func isRawBypassed(_ playback: PlaybackControlConfiguration) -> Bool {
        playback.globalBypassed
    }

    static func shouldPrepareLinearPhase(
        stereoEQ: StereoEQConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback)
            && stereoEQ.phaseMode == .linearPhase
            && !stereoEQ.bypassed
    }

    static func shouldPrepareEQFIR(
        stereoEQ: StereoEQConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && stereoEQ.requiresEQFIRProgram
    }

    static func shouldPrepareRoomCorrection(
        roomCorrection: RoomCorrectionConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && roomCorrection.enabled
    }

    static func shouldPrepareSpeakerIR(
        speakerIR: SpeakerIRConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && speakerIR.enabled
    }
}

enum MasterVolumeControlMode: String, Equatable, Sendable {
    case softwareDSP
    case device
}

struct MasterVolumeDeviceCapabilities: Equatable, Sendable {
    var volumeReadable = false
    var volumeWritable = false
    var muteReadable = false
    var muteWritable = false

    static let softwareOnly = MasterVolumeDeviceCapabilities()

    var controlMode: MasterVolumeControlMode {
        volumeReadable && volumeWritable ? .device : .softwareDSP
    }

    var usesDeviceMute: Bool {
        muteReadable && muteWritable
    }
}

/// How far one intercepted volume-key press moves the software master volume.
/// Control plane only (main thread); never read on the audio callback.
enum MasterVolumeKeyStep: Equatable, Sendable {
    /// 1/denominator of the slider's range per press.
    case fraction(denominator: Int)
    /// A fixed change in attenuation on the software taper. Presses land on
    /// whole multiples of the step (−1, −2 … or −0.5, −1 …), up to 0 dB.
    case decibels(Double)

    /// The lowest level a dB step lands on; one more press down is silence,
    /// and the first press up from silence returns here.
    static let decibelFloor = -80.0

    var isValid: Bool {
        switch self {
        case .fraction(let denominator): return [16, 32, 64].contains(denominator)
        case .decibels(let step): return step.isFinite && step > 0 && step <= 12
        }
    }

    /// The level after one press up (`direction` 1) or down (−1).
    func level(afterPress direction: Double, from level: Double) -> Double {
        let range = MasterVolumeConfiguration.levelRange
        switch self {
        case .fraction(let denominator):
            return min(max(level + direction / Double(denominator), range.lowerBound), range.upperBound)
        case .decibels(let step):
            // The tolerance keeps a level already on the grid from snapping
            // to itself after the level ↔ dB round trip.
            let tolerance = 1e-6
            guard let current = MasterVolumeConfiguration.softwareTaperDB(forLevel: level) else {
                return direction > 0
                    ? MasterVolumeConfiguration.level(forSoftwareTaperDB: Self.decibelFloor)
                    : range.lowerBound
            }
            if direction > 0 {
                let target = max(
                    (((current + tolerance) / step).rounded(.up)) * step,
                    Self.decibelFloor
                )
                return MasterVolumeConfiguration.level(forSoftwareTaperDB: min(target, 0))
            }
            let target = (((current - tolerance) / step).rounded(.down)) * step
            guard target >= Self.decibelFloor - tolerance else { return range.lowerBound }
            return MasterVolumeConfiguration.level(forSoftwareTaperDB: target)
        }
    }
}

struct MasterVolumeConfiguration: Equatable, Sendable {
    static let levelRange = 0.0...1.0
    /// Software volume uses an audio (cubic) taper: gain = level³, i.e.
    /// 60 dB per decade of slider position. 50% ≈ -18 dB, 25% ≈ -36 dB, and a
    /// 1/16 key step from full scale ≈ -1.7 dB, giving fine control at low
    /// listening levels instead of a linear-amplitude slider whose last step
    /// jumps from -24 dB to silence. Device-mode outputs use the driver's own
    /// volume scalar and are unaffected.
    static let softwareTaperExponent = 3.0

    var level: Double = 1.0
    var muted = false

    static func softwareTaperGain(forLevel level: Double) -> Double {
        guard level.isFinite, level > 0 else { return 0 }
        return pow(min(level, 1), softwareTaperExponent)
    }

    /// The slider level whose taper gives `decibels` (≤ 0), the inverse of
    /// `softwareTaperDB`: level = 10^(dB / (20 × exponent)).
    static func level(forSoftwareTaperDB decibels: Double) -> Double {
        guard decibels.isFinite else { return decibels > 0 ? 1 : 0 }
        return min(pow(10, min(decibels, 0) / (20 * softwareTaperExponent)), 1)
    }

    /// Attenuation shown beside the percentage, nil at silence.
    static func softwareTaperDB(forLevel level: Double) -> Double? {
        let gain = softwareTaperGain(forLevel: level)
        guard gain > 0 else { return nil }
        return 20 * log10(gain)
    }

    func softwareGain(for capabilities: MasterVolumeDeviceCapabilities) -> Float {
        let volumeGain = capabilities.controlMode == .device
            ? 1.0
            : Self.softwareTaperGain(forLevel: level)
        let muteGain = muted && !capabilities.usesDeviceMute ? 0.0 : 1.0
        return Float(volumeGain * muteGain)
    }
}

/// Per-output persistence for the software (DSP) master volume. Device-mode
/// outputs own their volume in hardware and are never stored here.
protocol MasterVolumePersisting: AnyObject {
    /// The volume to restore when this output is first synchronized, or nil to
    /// keep the current in-memory configuration.
    func restoredSoftwareVolume(forOutputUID uid: String) -> MasterVolumeConfiguration?
    func storeSoftwareVolume(_ configuration: MasterVolumeConfiguration, forOutputUID uid: String)
}

final class UserDefaultsMasterVolumeStore: MasterVolumePersisting {
    /// Level used the first time a software-volume output is seen: 50% on the
    /// software taper (≈ -18 dB), never full scale into an amplifier that has
    /// no volume control of its own.
    static let firstUseSoftwareLevel = 0.5
    static let defaultsKey = "audio.masterVolume.softwareByOutputUID"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func restoredSoftwareVolume(forOutputUID uid: String) -> MasterVolumeConfiguration? {
        guard let entry = defaults.dictionary(forKey: Self.defaultsKey)?[uid] as? [String: Any],
              let level = entry["level"] as? Double,
              level.isFinite,
              MasterVolumeConfiguration.levelRange.contains(level) else {
            return MasterVolumeConfiguration(level: Self.firstUseSoftwareLevel, muted: false)
        }
        return MasterVolumeConfiguration(level: level, muted: entry["muted"] as? Bool ?? false)
    }

    func storeSoftwareVolume(_ configuration: MasterVolumeConfiguration, forOutputUID uid: String) {
        guard configuration.level.isFinite,
              MasterVolumeConfiguration.levelRange.contains(configuration.level) else { return }
        var entries = defaults.dictionary(forKey: Self.defaultsKey) ?? [:]
        entries[uid] = ["level": configuration.level, "muted": configuration.muted]
        defaults.set(entries, forKey: Self.defaultsKey)
    }
}

enum MasterVolumeConfigurationError: Error, LocalizedError, Equatable {
    case invalidLevel(Double)

    var errorDescription: String? {
        switch self {
        case .invalidLevel(let level):
            return "Master volume \(level) is outside the supported 0...1 range."
        }
    }
}

extension PlaybackControlConfiguration {
    /// True when a playback/image control would change the signal. Disabled
    /// controls are inert even when their parameters differ from defaults.
    /// Global bypass is reported separately.
    var hasActiveImageProcessing: Bool {
        abs(balance) > 1.0e-9
            || (symmetryBalanceEnabled && abs(symmetryBalancePosition) > 1.0e-9)
            || (speakerCrossfeedEnabled && speakerCrossfeedAmount > 0)
            || (crosstalkCancellationEnabled && crosstalkCancellationAmount > 0)
            || abs(interChannelDelayMs) > 1.0e-9
            || auditionMode != .processed
    }
}

enum AuditionMode: String, CaseIterable, Identifiable, Sendable {
    case processed
    case reference
    case delta

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .processed: return "Processed"
        case .reference: return "Reference"
        case .delta: return "Delta"
        }
    }

    var cType: N60AuditionMode {
        switch self {
        case .processed: return N60AuditionModeProcessed
        case .reference: return N60AuditionModeReference
        case .delta: return N60AuditionModeDelta
        }
    }
}

struct PlaybackControlConfiguration: Equatable, Sendable {
    static let balanceRange = -1.0...1.0
    static let symmetryBalanceRange = -1.0...1.0
    static let speakerCrossfeedRange = 0.0...0.5
    static let crosstalkCancellationAmountRange = 0.0...1.0
    static let crosstalkHeadShadowFrequencyRange = 200.0...2000.0
    static let interChannelDelayRange = -20.0...20.0

    var balance: Double
    var symmetryBalanceEnabled: Bool
    var symmetryBalancePosition: Double
    var speakerCrossfeedEnabled: Bool
    var speakerCrossfeedAmount: Double
    var crosstalkCancellationEnabled: Bool
    var crosstalkCancellationAmount: Double
    var crosstalkHeadShadowFrequencyHz: Double
    var interChannelDelayMs: Double
    var globalBypassed: Bool
    var auditionMode: AuditionMode

    init(
        balance: Double = 0,
        symmetryBalanceEnabled: Bool = false,
        symmetryBalancePosition: Double = 0,
        speakerCrossfeedEnabled: Bool = false,
        speakerCrossfeedAmount: Double = 0,
        crosstalkCancellationEnabled: Bool = false,
        crosstalkCancellationAmount: Double = 0.5,
        crosstalkHeadShadowFrequencyHz: Double = 700,
        interChannelDelayMs: Double = 0,
        globalBypassed: Bool = false,
        flatAuditionEnabled: Bool = false,
        auditionMode: AuditionMode? = nil
    ) {
        self.balance = balance
        self.symmetryBalanceEnabled = symmetryBalanceEnabled
        self.symmetryBalancePosition = symmetryBalancePosition
        self.speakerCrossfeedEnabled = speakerCrossfeedEnabled
        self.speakerCrossfeedAmount = speakerCrossfeedAmount
        self.crosstalkCancellationEnabled = crosstalkCancellationEnabled
        self.crosstalkCancellationAmount = crosstalkCancellationAmount
        self.crosstalkHeadShadowFrequencyHz = crosstalkHeadShadowFrequencyHz
        self.interChannelDelayMs = interChannelDelayMs
        self.globalBypassed = globalBypassed
        self.auditionMode = auditionMode ?? (flatAuditionEnabled ? .reference : .processed)
    }

    var flatAuditionEnabled: Bool {
        get { auditionMode == .reference }
        set { auditionMode = newValue ? .reference : .processed }
    }

    var balanceLinearGains: (left: Float, right: Float) {
        let clamped = min(max(balance, Self.balanceRange.lowerBound), Self.balanceRange.upperBound)
        if clamped < 0 {
            return (1.0, Float(1.0 + clamped))
        }
        if clamped > 0 {
            return (Float(1.0 - clamped), 1.0)
        }
        return (1.0, 1.0)
    }
}

enum PlaybackControlConfigurationError: Error, LocalizedError, Equatable {
    case invalidBalance(Double)
    case invalidSymmetryBalance(Double)
    case invalidSpeakerCrossfeed(Double)
    case invalidCrosstalkCancellationAmount(Double)
    case invalidCrosstalkHeadShadowFrequency(Double)
    case invalidInterChannelDelay(Double)

    var errorDescription: String? {
        switch self {
        case .invalidBalance(let value):
            return "Channel balance \(value) is outside the supported -1...+1 range."
        case .invalidSymmetryBalance(let value):
            return "Listening-position symmetry \(value) is outside the supported -1...+1 range."
        case .invalidSpeakerCrossfeed(let value):
            return "Speaker crossfeed \(value) is outside the supported 0...0.5 range."
        case .invalidCrosstalkCancellationAmount(let value):
            return "Crosstalk cancellation amount \(value) is outside the supported 0...1 range."
        case .invalidCrosstalkHeadShadowFrequency(let value):
            return "Crosstalk head-shadow frequency \(value) Hz is outside the supported 200...2000 Hz range."
        case .invalidInterChannelDelay(let value):
            return "Inter-channel delay \(value) ms is outside the supported -20...+20 ms range."
        }
    }
}
