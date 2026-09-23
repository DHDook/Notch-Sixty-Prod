import Combine
import CoreAudio
import Foundation

enum EQFilterType: String, CaseIterable, Identifiable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        }
    }

    var cType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        case .lowPass: return N60BiquadFilterTypeLowPass
        case .highPass: return N60BiquadFilterTypeHighPass
        case .notch: return N60BiquadFilterTypeNotch
        }
    }
}

enum EQPhaseMode: String, CaseIterable, Identifiable, Sendable {
    case minimumPhase
    case linearPhase

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .minimumPhase: return "Minimum phase"
        case .linearPhase: return "Linear phase"
        }
    }
}

struct EQBand: Identifiable, Equatable, Sendable {
    let id: UUID
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: EQFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 0.707
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}

enum EQConfigurationError: Error, LocalizedError, Equatable {
    case tooManyBands(Int)
    case invalidBand(index: Int)
    case linearPhaseDesignFailed
    case convolutionProgramUnavailable

    var errorDescription: String? {
        switch self {
        case .tooManyBands(let count):
            return "Parametric EQ supports at most \(Int(N60_MAX_EQ_BANDS)) bands; configuration contains \(count)."
        case .invalidBand(let index):
            return "EQ band \(index + 1) is invalid for the current output sample rate."
        case .linearPhaseDesignFailed:
            return "Unable to design the linear-phase FIR for the current EQ configuration."
        case .convolutionProgramUnavailable:
            return "No safe FIR program slot is currently available."
        }
    }
}

struct DSPGainConfiguration: Equatable, Sendable {
    static let inputPreampRange = -60.0...24.0
    static let headroomAttenuationRange = -48.0...0.0
    static let outputGainRange = -60.0...12.0

    var inputPreampDB: Double = 0
    var headroomAttenuationDB: Double = 0
    var outputGainDB: Double = 0

    static func linearGain(forDB db: Double) -> Float {
        Float(pow(10.0, db / 20.0))
    }
}

enum DSPGainConfigurationError: Error, LocalizedError, Equatable {
    case invalidInputPreamp(Double)
    case invalidHeadroomAttenuation(Double)
    case invalidOutputGain(Double)

    var errorDescription: String? {
        switch self {
        case .invalidInputPreamp(let value):
            return "Input preamp \(value) dB is outside the supported -60...+24 dB range."
        case .invalidHeadroomAttenuation(let value):
            return "Headroom attenuation \(value) dB is outside the supported -48...0 dB range."
        case .invalidOutputGain(let value):
            return "Output gain \(value) dB is outside the supported -60...+12 dB range."
        }
    }
}

enum CrossoverTopology: String, CaseIterable, Identifiable, Sendable {
    case linkwitzRiley24
    case linkwitzRiley48

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .linkwitzRiley24: return "Linkwitz-Riley 24 dB/oct"
        case .linkwitzRiley48: return "Linkwitz-Riley 48 dB/oct"
        }
    }

    var cType: N60CrossoverTopology {
        switch self {
        case .linkwitzRiley24: return N60CrossoverTopologyLinkwitzRiley24
        case .linkwitzRiley48: return N60CrossoverTopologyLinkwitzRiley48
        }
    }
}

enum CrossoverMonitorMode: String, CaseIterable, Identifiable, Sendable {
    case recombined
    case mainsOnly
    case subOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .recombined: return "Recombined preview"
        case .mainsOnly: return "Mains only"
        case .subOnly: return "Sub only"
        }
    }

    var cType: N60CrossoverMonitorMode {
        switch self {
        case .recombined: return N60CrossoverMonitorModeRecombined
        case .mainsOnly: return N60CrossoverMonitorModeMainsOnly
        case .subOnly: return N60CrossoverMonitorModeSubOnly
        }
    }
}

struct BassManagementConfiguration: Equatable, Sendable {
    static let frequencyRange = 20.0...500.0
    static let subGainRange = -24.0...12.0

    var enabled = false
    var frequencyHz: Double = 80
    var topology: CrossoverTopology = .linkwitzRiley24
    var monitorMode: CrossoverMonitorMode = .recombined
    var subGainDB: Double = 0
    var subPolarityInverted = false
}

enum BassManagementConfigurationError: Error, LocalizedError, Equatable {
    case invalidFrequency(Double)
    case invalidSubGain(Double)
    case graphDesignFailed

    var errorDescription: String? {
        switch self {
        case .invalidFrequency(let value):
            return "Crossover frequency \(value) Hz is outside the supported 20...500 Hz range."
        case .invalidSubGain(let value):
            return "Sub gain \(value) dB is outside the supported -24...+12 dB range."
        case .graphDesignFailed:
            return "Unable to design the crossover for the current output sample rate."
        }
    }
}

struct RoomCorrectionFilter: Equatable, Sendable {
    var name: String
    var sampleRate: Double?
    var leftTaps: [Float]
    var rightTaps: [Float]?
    var declaredLatencyFrames: UInt32

    static let validation = RoomCorrectionFilter(
        name: "Deterministic 3-tap validation",
        sampleRate: nil,
        leftTaps: [0.25, 0.5, 0.25],
        rightTaps: nil,
        declaredLatencyFrames: 1
    )

    func validateSampleRate(forOutputSampleRate outputSampleRate: Double) throws {
        guard let sampleRate else { return }
        guard sampleRate.isFinite,
              abs(sampleRate - outputSampleRate) < 0.5 else {
            throw RoomCorrectionConfigurationError.sampleRateMismatch(
                filter: sampleRate,
                output: outputSampleRate
            )
        }
    }
}

struct RoomCorrectionConfiguration: Equatable, Sendable {
    var enabled = false
    var filter: RoomCorrectionFilter?
}

enum RoomCorrectionConfigurationError: Error, LocalizedError, Equatable {
    case filterRequired
    case invalidTapCount(Int)
    case mismatchedStereoTapCount(left: Int, right: Int)
    case nonFiniteTap
    case sampleRateMismatch(filter: Double, output: Double)
    case invalidDeclaredLatency(UInt32)
    case convolutionProgramUnavailable
    case graphAttachmentFailed

    var errorDescription: String? {
        switch self {
        case .filterRequired:
            return "Room correction cannot be enabled until a correction filter is loaded."
        case .invalidTapCount(let count):
            return "Room-correction FIR tap count \(count) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .mismatchedStereoTapCount(let left, let right):
            return "Room-correction left/right FIR lengths must match (left \(left), right \(right))."
        case .nonFiniteTap:
            return "Room-correction FIR coefficients must all be finite."
        case .sampleRateMismatch(let filter, let output):
            return "Room-correction filter rate \(filter) Hz does not match the active output rate \(output) Hz."
        case .invalidDeclaredLatency(let frames):
            return "Room-correction declared filter latency \(frames) frames exceeds the FIR length."
        case .convolutionProgramUnavailable:
            return "No safe room-correction FIR program slot is currently available."
        case .graphAttachmentFailed:
            return "Unable to attach the prepared room-correction FIR to the DSP graph."
        }
    }
}

struct EQConfiguration: Equatable, Sendable {
    static let maximumBandCount = Int(N60_MAX_EQ_BANDS)

    var phaseMode: EQPhaseMode
    var bypassed: Bool
    var bands: [EQBand]

    init(
        phaseMode: EQPhaseMode = .minimumPhase,
        bypassed: Bool = false,
        bands: [EQBand] = []
    ) {
        self.phaseMode = phaseMode
        self.bypassed = bypassed
        self.bands = bands
    }

    var enabledBandCount: Int {
        bands.reduce(into: 0) { count, band in
            if band.enabled { count += 1 }
        }
    }

    private func validateBand(_ band: EQBand, index: Int, sampleRate: Double) throws -> Bool {
        guard band.frequencyHz.isFinite,
              band.frequencyHz > 0,
              band.gainDB.isFinite,
              band.q.isFinite,
              band.q > 0 else {
            throw EQConfigurationError.invalidBand(index: index)
        }
        return band.frequencyHz < sampleRate * 0.5
    }

    func makeGraphSnapshot(
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration = DSPGainConfiguration(),
        bassManagementConfiguration: BassManagementConfiguration = BassManagementConfiguration()
    ) throws -> N60DSPGraphSnapshot {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
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
        graph.eqBypassed = bypassed
        N60DSPGraphSnapshotClearEQ(&graph)

        if phaseMode == .minimumPhase && !bypassed {
            var renderIndex: UInt32 = 0
            for (modelIndex, band) in bands.enumerated() where band.enabled {
                guard try validateBand(band, index: modelIndex, sampleRate: sampleRate) else { continue }
                guard N60DSPGraphSnapshotSetEQBand(
                    &graph,
                    renderIndex,
                    band.type.cType,
                    band.frequencyHz,
                    band.gainDB,
                    band.q,
                    true
                ) else {
                    throw EQConfigurationError.invalidBand(index: modelIndex)
                }
                renderIndex += 1
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

    func linearPhaseBands(sampleRate: Double) throws -> [N60LinearPhaseEQBand] {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }
        var result: [N60LinearPhaseEQBand] = []
        result.reserveCapacity(enabledBandCount)
        for (index, band) in bands.enumerated() where band.enabled {
            guard try validateBand(band, index: index, sampleRate: sampleRate) else { continue }
            var cBand = N60LinearPhaseEQBand()
            cBand.enabled = true
            cBand.type = band.type.cType
            cBand.frequencyHz = band.frequencyHz
            cBand.gainDB = band.gainDB
            cBand.q = band.q
            result.append(cBand)
        }
        return result
    }
}

private struct PreparedLinearPhaseProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
    let designInfo: N60LinearPhaseEQDesignInfo
}

private struct PreparedRoomCorrectionProgram {
    let slot: UInt32
    let programInfo: N60ConvolutionProgramInfo
}

@MainActor
final class AudioIOEngine: ObservableObject {
    private let deviceCatalog: any OutputDeviceCataloging
    private let eventMonitor: AudioHardwareEventMonitor
    private var lifecycle: AudioLifecycleStateMachine
    private var transportSession: CoreAudioTransportSession?
    private var lifetimeArchivedCounters = AudioTransportCounters()
    private var processingSessionArchivedCounters = AudioTransportCounters()
    private var reconfigurationWorkItem: DispatchWorkItem?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryGeneration: UInt64 = 0
    private var resumeAfterWake = false
    private var prepared = false
    private var activeLinearPhaseProgram: PreparedLinearPhaseProgram?
    private var nextLinearPhaseProgramSlot: UInt32 = 0
    private var activeRoomCorrectionProgram: PreparedRoomCorrectionProgram?
    private var nextRoomCorrectionProgramSlot: UInt32 = 0

    private(set) var sampleRateChangesHandled: UInt64 = 0
    private(set) var recoveryAttempts: UInt64 = 0
    private(set) var recoverySuccesses: UInt64 = 0
    private(set) var recoveryFailures: UInt64 = 0

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var routeConfiguration: AudioRouteConfiguration
    @Published private(set) var eqConfiguration = EQConfiguration()
    @Published private(set) var gainConfiguration = DSPGainConfiguration()
    @Published private(set) var bassManagementConfiguration = BassManagementConfiguration()
    @Published private(set) var roomCorrectionConfiguration = RoomCorrectionConfiguration()
    @Published private(set) var linearPhaseDesignInfo: N60LinearPhaseEQDesignInfo?
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var lifecycleState: AudioLifecycleState

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration(),
        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor()
    ) {
        self.deviceCatalog = deviceCatalog
        self.routeConfiguration = initialRouteConfiguration
        self.eventMonitor = eventMonitor
        let lifecycle = AudioLifecycleStateMachine()
        self.lifecycle = lifecycle
        self.lifecycleState = lifecycle.state

        eventMonitor.onDeviceListChanged = { [weak self] in self?.handleDeviceListChanged() }
        eventMonitor.onSelectedOutputSampleRateChanged = { [weak self] in self?.scheduleSampleRateReconfiguration() }
        eventMonitor.onWillSleep = { [weak self] in self?.handleWillSleep() }
        eventMonitor.onDidWake = { [weak self] in self?.handleDidWake() }
    }

    var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputUID = routeConfiguration.selectedOutputUID else { return nil }
        return outputDevices.first { $0.uid == selectedOutputUID }
    }

    func prepareForUse() {
        guard !prepared else { return }
        prepared = true
        do {
            try refreshOutputDevices()
            try eventMonitor.start()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func refreshOutputDevices() throws -> [AudioOutputDevice] {
        do {
            let discoveredDevices = try deviceCatalog.outputDevices()
            outputDevices = discoveredDevices
            return discoveredDevices
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func selectOutput(uid: String?) throws {
        guard lifecycle.state == .idle else { return }
        guard let uid else {
            routeConfiguration.selectedOutputUID = nil
            return
        }
        guard outputDevices.contains(where: { $0.uid == uid }) else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: uid)
            lastErrorDescription = error.localizedDescription
            throw error
        }
        routeConfiguration.selectedOutputUID = uid
        lastErrorDescription = nil
    }

    func addEQBand(_ band: EQBand = EQBand()) throws {
        guard eqConfiguration.bands.count < EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(eqConfiguration.bands.count + 1)
        }
        var updated = eqConfiguration
        updated.bands.append(band)
        try applyEQConfiguration(updated)
    }

    func updateEQBand(_ band: EQBand) throws {
        guard let index = eqConfiguration.bands.firstIndex(where: { $0.id == band.id }) else { return }
        var updated = eqConfiguration
        updated.bands[index] = band
        try applyEQConfiguration(updated)
    }

    func removeEQBand(id: UUID) throws {
        var updated = eqConfiguration
        updated.bands.removeAll { $0.id == id }
        try applyEQConfiguration(updated)
    }

    func setEQBypassed(_ bypassed: Bool) throws {
        var updated = eqConfiguration
        updated.bypassed = bypassed
        try applyEQConfiguration(updated)
    }

    func setEQPhaseMode(_ mode: EQPhaseMode) throws {
        guard mode != eqConfiguration.phaseMode else { return }
        var updated = eqConfiguration
        updated.phaseMode = mode
        try applyEQConfiguration(updated)
    }

    func replaceEQConfiguration(_ configuration: EQConfiguration) throws {
        try applyEQConfiguration(configuration)
    }

    func setInputPreampDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.inputPreampRange.contains(value) else {
            throw DSPGainConfigurationError.invalidInputPreamp(value)
        }
        var updated = gainConfiguration
        updated.inputPreampDB = value
        try applyGainConfiguration(updated)
    }

    func setHeadroomAttenuationDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.headroomAttenuationRange.contains(value) else {
            throw DSPGainConfigurationError.invalidHeadroomAttenuation(value)
        }
        var updated = gainConfiguration
        updated.headroomAttenuationDB = value
        try applyGainConfiguration(updated)
    }

    func setOutputGainDB(_ value: Double) throws {
        guard value.isFinite, DSPGainConfiguration.outputGainRange.contains(value) else {
            throw DSPGainConfigurationError.invalidOutputGain(value)
        }
        var updated = gainConfiguration
        updated.outputGainDB = value
        try applyGainConfiguration(updated)
    }

    func replaceBassManagementConfiguration(_ configuration: BassManagementConfiguration) throws {
        guard configuration.frequencyHz.isFinite,
              BassManagementConfiguration.frequencyRange.contains(configuration.frequencyHz) else {
            throw BassManagementConfigurationError.invalidFrequency(configuration.frequencyHz)
        }
        guard configuration.subGainDB.isFinite,
              BassManagementConfiguration.subGainRange.contains(configuration.subGainDB) else {
            throw BassManagementConfigurationError.invalidSubGain(configuration.subGainDB)
        }
        if let session = transportSession {
            var graph = try eqConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: configuration
            )
            try attachActiveLinearPhaseProgramIfNeeded(to: &graph)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph)
            try session.publishDSPGraph(graph)
        }
        bassManagementConfiguration = configuration
        lastErrorDescription = nil
    }

    func loadRoomCorrectionValidationFilter() throws {
        var updated = roomCorrectionConfiguration
        updated.filter = .validation
        try applyRoomCorrectionConfiguration(updated)
    }

    func setRoomCorrectionEnabled(_ enabled: Bool) throws {
        var updated = roomCorrectionConfiguration
        updated.enabled = enabled
        try applyRoomCorrectionConfiguration(updated)
    }

    func replaceRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        try applyRoomCorrectionConfiguration(configuration)
    }

    func start() throws {
        try start(resetProcessingSessionCounters: true)
    }

    func stop() {
        guard lifecycle.state != .idle else { return }
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        reconfigurationWorkItem = nil
        recoveryWorkItem = nil
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
    }

    func shutdownForTermination() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .idle {
            if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
            tearDownTransport(fadeOut: true)
            try? setLifecycle(.idle)
        }
        eventMonitor.stop()
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        let currentCounters = transportSession?.counters() ?? AudioTransportCounters()
        let processingSessionCounters = processingSessionArchivedCounters + currentCounters
        let lifetimeCounters = lifetimeArchivedCounters + currentCounters
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: transportSession?.tapFormat.sampleRate,
            outputSampleRate: transportSession?.outputFormat.sampleRate,
            sessionTransportCounters: processingSessionCounters,
            lifetimeTransportCounters: lifetimeCounters,
            renderKernelDiagnostics: transportSession?.renderDiagnostics(),
            startupGateOpened: transportSession?.startupGateOpened,
            startupGateTargetFrames: transportSession?.startupGateTargetFrames,
            startupGateActivationFrames: transportSession?.startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func applyEQConfiguration(_ configuration: EQConfiguration) throws {
        guard configuration.bands.count <= EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(configuration.bands.count)
        }

        if let session = transportSession {
            var graph = try configuration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration
            )

            if configuration.phaseMode == .linearPhase && !configuration.bypassed {
                let preparedProgram = try prepareLinearPhaseProgram(configuration, for: session)
                guard N60DSPGraphSnapshotSetConvolutionProgram(
                    &graph,
                    preparedProgram.slot,
                    preparedProgram.programInfo,
                    true
                ) else {
                    throw EQConfigurationError.linearPhaseDesignFailed
                }
                try attachActiveRoomCorrectionProgramIfNeeded(to: &graph)
                try session.transitionDSPGraph(graph)
                activeLinearPhaseProgram = preparedProgram
                linearPhaseDesignInfo = preparedProgram.designInfo
            } else {
                let leavingLinearPhase = activeLinearPhaseProgram != nil
                try attachActiveRoomCorrectionProgramIfNeeded(to: &graph)
                if leavingLinearPhase {
                    try session.transitionDSPGraph(graph)
                } else {
                    try session.publishDSPGraph(graph)
                }
                activeLinearPhaseProgram = nil
                linearPhaseDesignInfo = nil
            }
        } else {
            activeLinearPhaseProgram = nil
            linearPhaseDesignInfo = nil
        }

        eqConfiguration = configuration
        lastErrorDescription = nil
    }

    private func applyGainConfiguration(_ configuration: DSPGainConfiguration) throws {
        if let session = transportSession {
            var graph = try eqConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: configuration,
                bassManagementConfiguration: bassManagementConfiguration
            )
            try attachActiveLinearPhaseProgramIfNeeded(to: &graph)
            try attachActiveRoomCorrectionProgramIfNeeded(to: &graph)
            try session.publishDSPGraph(graph)
        }
        gainConfiguration = configuration
        lastErrorDescription = nil
    }

    private func applyRoomCorrectionConfiguration(_ configuration: RoomCorrectionConfiguration) throws {
        if configuration.enabled && configuration.filter == nil {
            throw RoomCorrectionConfigurationError.filterRequired
        }

        if let session = transportSession {
            var graph = try eqConfiguration.makeGraphSnapshot(
                sampleRate: session.outputFormat.sampleRate,
                gainConfiguration: gainConfiguration,
                bassManagementConfiguration: bassManagementConfiguration
            )
            try attachActiveLinearPhaseProgramIfNeeded(to: &graph)

            if configuration.enabled {
                guard let filter = configuration.filter else {
                    throw RoomCorrectionConfigurationError.filterRequired
                }
                let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
                try attachRoomCorrectionProgram(preparedProgram, to: &graph)
                try session.transitionDSPGraph(graph)
                activeRoomCorrectionProgram = preparedProgram
            } else {
                if activeRoomCorrectionProgram != nil {
                    try session.transitionDSPGraph(graph)
                } else {
                    try session.publishDSPGraph(graph)
                }
                activeRoomCorrectionProgram = nil
            }
        } else {
            activeRoomCorrectionProgram = nil
        }

        roomCorrectionConfiguration = configuration
        lastErrorDescription = nil
    }

    private func prepareLinearPhaseProgram(
        _ configuration: EQConfiguration,
        for session: CoreAudioTransportSession
    ) throws -> PreparedLinearPhaseProgram {
        let sampleRate = session.outputFormat.sampleRate
        let tapCount = Int(N60LinearPhaseEQRecommendedTapCount(sampleRate))
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw EQConfigurationError.linearPhaseDesignFailed
        }

        let bands = try configuration.linearPhaseBands(sampleRate: sampleRate)
        var taps = [Float](repeating: 0, count: tapCount)
        var designInfo = N60LinearPhaseEQDesignInfo()
        let designed = taps.withUnsafeMutableBufferPointer { tapBuffer -> Bool in
            if bands.isEmpty {
                return N60LinearPhaseEQDesign(
                    sampleRate,
                    nil,
                    0,
                    tapBuffer.baseAddress!,
                    UInt32(tapBuffer.count),
                    &designInfo
                )
            }
            return bands.withUnsafeBufferPointer { bandBuffer in
                N60LinearPhaseEQDesign(
                    sampleRate,
                    bandBuffer.baseAddress!,
                    UInt32(bandBuffer.count),
                    tapBuffer.baseAddress!,
                    UInt32(tapBuffer.count),
                    &designInfo
                )
            }
        }
        guard designed else { throw EQConfigurationError.linearPhaseDesignFailed }

        let slot = nextLinearPhaseProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareConvolutionProgram(
                slot: slot,
                taps: taps,
                declaredLatencyFrames: designInfo.groupDelayFrames
            )
        } catch {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        nextLinearPhaseProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedLinearPhaseProgram(slot: slot, programInfo: programInfo, designInfo: designInfo)
    }

    private func prepareRoomCorrectionProgram(
        _ filter: RoomCorrectionFilter,
        for session: CoreAudioTransportSession
    ) throws -> PreparedRoomCorrectionProgram {
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw RoomCorrectionConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw RoomCorrectionConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: session.outputFormat.sampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw RoomCorrectionConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }

        let slot = nextRoomCorrectionProgramSlot % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        let programInfo: N60ConvolutionProgramInfo
        do {
            programInfo = try session.prepareRoomCorrectionProgram(
                slot: slot,
                leftTaps: filter.leftTaps,
                rightTaps: filter.rightTaps,
                declaredLatencyFrames: filter.declaredLatencyFrames
            )
        } catch {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        nextRoomCorrectionProgramSlot = (slot + 1) % UInt32(N60_CONVOLUTION_PROGRAM_SLOTS)
        return PreparedRoomCorrectionProgram(slot: slot, programInfo: programInfo)
    }

    private func attachActiveLinearPhaseProgramIfNeeded(to graph: inout N60DSPGraphSnapshot) throws {
        guard eqConfiguration.phaseMode == .linearPhase, !eqConfiguration.bypassed else { return }
        guard let activeLinearPhaseProgram else {
            throw EQConfigurationError.convolutionProgramUnavailable
        }
        guard N60DSPGraphSnapshotSetConvolutionProgram(
            &graph,
            activeLinearPhaseProgram.slot,
            activeLinearPhaseProgram.programInfo,
            true
        ) else {
            throw EQConfigurationError.linearPhaseDesignFailed
        }
    }

    private func attachRoomCorrectionProgram(
        _ program: PreparedRoomCorrectionProgram,
        to graph: inout N60DSPGraphSnapshot
    ) throws {
        guard N60DSPGraphSnapshotSetRoomCorrectionProgram(
            &graph,
            program.slot,
            program.programInfo,
            true
        ) else {
            throw RoomCorrectionConfigurationError.graphAttachmentFailed
        }
    }

    private func attachActiveRoomCorrectionProgramIfNeeded(to graph: inout N60DSPGraphSnapshot) throws {
        guard roomCorrectionConfiguration.enabled else { return }
        guard let activeRoomCorrectionProgram else {
            throw RoomCorrectionConfigurationError.convolutionProgramUnavailable
        }
        try attachRoomCorrectionProgram(activeRoomCorrectionProgram, to: &graph)
    }

    private func start(resetProcessingSessionCounters: Bool) throws {
        guard lifecycle.state == .idle else { return }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "No output selected")
            lastErrorDescription = error.localizedDescription
            throw error
        }

        if resetProcessingSessionCounters {
            processingSessionArchivedCounters = AudioTransportCounters()
        }

        do {
            try setLifecycle(.requestingPermission)
            try setLifecycle(.creatingTap)
            try buildTransport(output: output)
            try setLifecycle(.creatingAggregate)
            try setLifecycle(.openingOutput)
            try setLifecycle(.starting)
            try setLifecycle(.running)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            throw error
        }
    }

    private func setLifecycle(_ nextState: AudioLifecycleState) throws {
        try lifecycle.transition(to: nextState)
        lifecycleState = lifecycle.state
    }

    private func buildTransport(output: AudioOutputDevice) throws {
        let session = try CoreAudioTransportSession(selectedOutput: output)
        activeLinearPhaseProgram = nil
        nextLinearPhaseProgramSlot = 0
        activeRoomCorrectionProgram = nil
        nextRoomCorrectionProgramSlot = 0
        var graph = try eqConfiguration.makeGraphSnapshot(
            sampleRate: session.outputFormat.sampleRate,
            gainConfiguration: gainConfiguration,
            bassManagementConfiguration: bassManagementConfiguration
        )
        if eqConfiguration.phaseMode == .linearPhase && !eqConfiguration.bypassed {
            let preparedProgram = try prepareLinearPhaseProgram(eqConfiguration, for: session)
            guard N60DSPGraphSnapshotSetConvolutionProgram(
                &graph,
                preparedProgram.slot,
                preparedProgram.programInfo,
                true
            ) else {
                throw EQConfigurationError.linearPhaseDesignFailed
            }
            activeLinearPhaseProgram = preparedProgram
            linearPhaseDesignInfo = preparedProgram.designInfo
        } else {
            linearPhaseDesignInfo = nil
        }

        if roomCorrectionConfiguration.enabled {
            guard let filter = roomCorrectionConfiguration.filter else {
                throw RoomCorrectionConfigurationError.filterRequired
            }
            let preparedProgram = try prepareRoomCorrectionProgram(filter, for: session)
            try attachRoomCorrectionProgram(preparedProgram, to: &graph)
            activeRoomCorrectionProgram = preparedProgram
        }

        try session.publishDSPGraph(graph)
        transportSession = session
    }

    private func tearDownTransport(fadeOut: Bool) {
        if let session = transportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            transportSession = nil
        }
        activeLinearPhaseProgram = nil
        activeRoomCorrectionProgram = nil
    }

    private func forceFailedState(_ error: Error) {
        lastErrorDescription = error.localizedDescription
        if AudioLifecycleStateMachine.canTransition(from: lifecycle.state, to: .failed) {
            try? lifecycle.transition(to: .failed)
            lifecycleState = lifecycle.state
        }
    }

    private func handleDeviceListChanged() {
        do { try refreshOutputDevices() } catch { return }
        guard let selectedUID = routeConfiguration.selectedOutputUID else { return }
        let selectedIsPresent = outputDevices.contains { $0.uid == selectedUID }

        if !selectedIsPresent && (lifecycle.state == .running || lifecycle.state == .reconfiguring) {
            beginOutputRecovery()
            return
        }

        if selectedIsPresent && lifecycle.state == .recoveringOutput {
            scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
        }
    }

    private func scheduleSampleRateReconfiguration() {
        guard lifecycle.state == .running else { return }

        reconfigurationWorkItem?.cancel()
        do {
            try setLifecycle(.reconfiguring)
            eventMonitor.removeSelectedOutputSampleRateMonitor()
            tearDownTransport(fadeOut: false)
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            return
        }

        let workItem = DispatchWorkItem { [weak self] in self?.performSampleRateReconfiguration() }
        reconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performSampleRateReconfiguration() {
        guard lifecycle.state == .reconfiguring else { return }
        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                beginOutputRecovery()
                return
            }
            try buildTransport(output: output)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            sampleRateChangesHandled &+= 1
            reconfigurationWorkItem = nil
            try setLifecycle(.running)
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
        }
    }

    private func beginOutputRecovery() {
        guard lifecycle.state == .running || lifecycle.state == .reconfiguring else { return }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        try? setLifecycle(.recoveringOutput)
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        tearDownTransport(fadeOut: false)
        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
    }

    private func scheduleRecoveryAttempt(generation: UInt64, delay: TimeInterval) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performRecoveryAttempt(generation: generation) }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRecoveryAttempt(generation: UInt64) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryAttempts &+= 1

        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                lastErrorDescription = "Waiting for selected output to return."
                scheduleRecoveryAttempt(generation: generation, delay: 0.5)
                return
            }

            do {
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                recoverySuccesses &+= 1
                try setLifecycle(.running)
                lastErrorDescription = nil
                recoveryWorkItem = nil
                return
            } catch {
                recoveryFailures &+= 1
                lastErrorDescription = "Selected output is present but not ready yet: \(error.localizedDescription)"
                tearDownTransport(fadeOut: false)
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }

        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
    }

    private func handleWillSleep() {
        guard lifecycle.state == .running else {
            resumeAfterWake = false
            return
        }
        resumeAfterWake = true
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        try? setLifecycle(.stopping)
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        do {
            try start(resetProcessingSessionCounters: false)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
