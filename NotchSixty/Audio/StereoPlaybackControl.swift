import Foundation

enum EQChannelMode: String, CaseIterable, Identifiable, Sendable {
    case linked
    case independent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linked: return "Linked"
        case .independent: return "Independent"
        }
    }
}

enum EQEditChannel: String, CaseIterable, Identifiable, Sendable {
    case linked
    case left
    case right

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linked: return "Linked"
        case .left: return "Left"
        case .right: return "Right"
        }
    }
}

struct StereoEQConfiguration: Equatable, Sendable {
    static let bandGainRange = -24.0...24.0

    var channelMode: EQChannelMode
    var editChannel: EQEditChannel
    var phaseMode: EQPhaseMode
    var bypassed: Bool
    var linkedBands: [EQBand]
    var leftBands: [EQBand]
    var rightBands: [EQBand]
    var independentSeeded: Bool

    init(
        channelMode: EQChannelMode = .linked,
        editChannel: EQEditChannel = .linked,
        phaseMode: EQPhaseMode = .minimumPhase,
        bypassed: Bool = false,
        linkedBands: [EQBand] = [],
        leftBands: [EQBand] = [],
        rightBands: [EQBand] = [],
        independentSeeded: Bool = false
    ) {
        self.channelMode = channelMode
        self.editChannel = channelMode == .linked ? .linked : editChannel
        self.phaseMode = phaseMode
        self.bypassed = bypassed
        self.linkedBands = linkedBands
        self.leftBands = leftBands
        self.rightBands = rightBands
        self.independentSeeded = independentSeeded
    }

    var editableBands: [EQBand] {
        switch channelMode {
        case .linked:
            return linkedBands
        case .independent:
            return editChannel == .right ? rightBands : leftBands
        }
    }

    var enabledBandCount: Int {
        switch channelMode {
        case .linked:
            return linkedBands.lazy.filter(\.enabled).count
        case .independent:
            return leftBands.lazy.filter(\.enabled).count + rightBands.lazy.filter(\.enabled).count
        }
    }

    mutating func setChannelMode(_ mode: EQChannelMode) {
        guard channelMode != mode else { return }
        if mode == .independent && !independentSeeded {
            leftBands = linkedBands
            rightBands = linkedBands
            independentSeeded = true
        }
        channelMode = mode
        editChannel = mode == .linked ? .linked : (editChannel == .right ? .right : .left)
    }

    mutating func setEditChannel(_ channel: EQEditChannel) {
        guard channelMode == .independent else {
            editChannel = .linked
            return
        }
        editChannel = channel == .right ? .right : .left
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
            guard band.frequencyHz.isFinite,
                  band.frequencyHz > 0,
                  band.gainDB.isFinite,
                  Self.bandGainRange.contains(band.gainDB),
                  band.q.isFinite,
                  band.q > 0 else {
                throw EQConfigurationError.invalidBand(index: index)
            }
            if band.frequencyHz < sampleRate * 0.5 {
                result.append(band)
            }
        }
        return result
    }

    func makeGraphSnapshot(
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration,
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

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.inputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.inputPreampDB)
        graph.headroomGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.headroomAttenuationDB)
        graph.outputGainLinear = DSPGainConfiguration.linearGain(forDB: gainConfiguration.outputGainDB)
        graph.masterGainLinear = masterGainLinear
        let balance = playbackConfiguration.balanceLinearGains
        graph.balanceGainLeftLinear = balance.left
        graph.balanceGainRightLinear = balance.right
        graph.bypassed = playbackConfiguration.globalBypassed
        graph.auditionMode = playbackConfiguration.auditionMode.cType
        graph.eqBypassed = bypassed
        N60DSPGraphSnapshotClearEQ(&graph)

        if phaseMode == .minimumPhase && !bypassed && !graph.bypassed {
            var renderIndex: UInt32 = 0
            switch channelMode {
            case .linked:
                for band in try validatedEnabledBands(linkedBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBand(
                        &graph,
                        renderIndex,
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
                }
            case .independent:
                for band in try validatedEnabledBands(leftBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBandForChannels(
                        &graph,
                        renderIndex,
                        UInt8(N60_EQ_CHANNEL_LEFT),
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
                }
                for band in try validatedEnabledBands(rightBands, sampleRate: sampleRate) {
                    guard N60DSPGraphSnapshotSetEQBandForChannels(
                        &graph,
                        renderIndex,
                        UInt8(N60_EQ_CHANNEL_RIGHT),
                        band.type.cType,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw EQConfigurationError.invalidBand(index: Int(renderIndex))
                    }
                    renderIndex += 1
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
        return graph
    }

    func linearPhaseBands(for channel: EQEditChannel, sampleRate: Double) throws -> [N60LinearPhaseEQBand] {
        let source: [EQBand]
        switch channelMode {
        case .linked:
            source = linkedBands
        case .independent:
            source = channel == .right ? rightBands : leftBands
        }
        let bands = try validatedEnabledBands(source, sampleRate: sampleRate)
        return bands.map { band in
            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
            cBand.type = band.type.cType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.gainDB
            cBand.q = band.q
            return cBand
        }
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

    static func shouldPrepareRoomCorrection(
        roomCorrection: RoomCorrectionConfiguration,
        playback: PlaybackControlConfiguration
    ) -> Bool {
        !isRawBypassed(playback) && roomCorrection.enabled
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

struct MasterVolumeConfiguration: Equatable, Sendable {
    static let levelRange = 0.0...1.0

    var level: Double = 1.0
    var muted = false

    func softwareGain(for capabilities: MasterVolumeDeviceCapabilities) -> Float {
        let volumeGain = capabilities.controlMode == .device ? 1.0 : level
        let muteGain = muted && !capabilities.usesDeviceMute ? 0.0 : 1.0
        return Float(volumeGain * muteGain)
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

    var balance: Double
    var globalBypassed: Bool
    var auditionMode: AuditionMode

    init(
        balance: Double = 0,
        globalBypassed: Bool = false,
        flatAuditionEnabled: Bool = false,
        auditionMode: AuditionMode? = nil
    ) {
        self.balance = balance
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

    var errorDescription: String? {
        switch self {
        case .invalidBalance(let value):
            return "Channel balance \(value) is outside the supported -1...+1 range."
        }
    }
}
