import Combine
import Foundation

protocol MultichannelCalibrationTransporting: AnyObject {
    func start() throws
    func snapshot() -> N60TargetedRoomMeasurementBridgeSnapshot?
    func finishAndMaterialize() throws -> MultichannelCalibrationCapture
    func cancel()
}

extension MultichannelCalibrationTransport: MultichannelCalibrationTransporting {}

typealias MultichannelCalibrationTransportFactory = (
    LiveNChannelOutputRoutePlan,
    [AudioOutputDevice],
    AudioInputDevice,
    Int,
    RoomCorrectionSweepProgram,
    UInt32
) throws -> any MultichannelCalibrationTransporting

typealias MultichannelCalibrationAnalysisOperation = @Sendable (
    MultichannelCalibrationCapture,
    RoomCorrectionSweepProgram,
    RoomCorrectionMicrophoneCalibration?
) async throws -> RoomCorrectionChannelMeasurement

enum MultichannelCalibrationCampaignState: String, Equatable, Sendable {
    case idle
    case ready
    case measuring
    case analyzing
    case reviewing
    case failed
}

struct MultichannelCalibrationTarget: Equatable, Sendable {
    var seat: MultichannelCalibrationSeat
    var source: MultichannelCalibrationSource
    var physicalOutputChannelIndex: UInt32

    var displayName: String { "\(seat.name) · \(source.displayName)" }
}

enum MultichannelCalibrationCampaignError: Error, Equatable, LocalizedError {
    case playbackSystemRequired
    case outputDeviceProfileRequired
    case playbackMustBeIdle(AudioLifecycleState)
    case microphonePermissionRequired
    case measurementInputRequired
    case outputRequired
    case campaignComplete
    case measurementAlreadyActive
    case measurementNotActive
    case invalidSeat
    case maximumSeatCount
    case staleCampaign
    case physicalRouteUnavailable(String)
    case designRequired
    case predictionRequired
    case predictionRejected([String])
    case intelligentTargetRequiresCompleteCampaign

    var errorDescription: String? {
        switch self {
        case .playbackSystemRequired:
            return "Select a Playback System before speaker calibration."
        case .outputDeviceProfileRequired:
            return "Enable and configure an Output Device Profile before speaker calibration."
        case .playbackMustBeIdle(let state):
            return "Stop normal DSP playback before speaker calibration. The playback engine is currently \(state.rawValue)."
        case .microphonePermissionRequired:
            return "Microphone access is required before speaker calibration can begin."
        case .measurementInputRequired:
            return "Select a measurement microphone before speaker calibration."
        case .outputRequired:
            return "Select the Playback System output before speaker calibration."
        case .campaignComplete:
            return "Every included seat and physical source has already been measured."
        case .measurementAlreadyActive:
            return "A speaker measurement is already active."
        case .measurementNotActive:
            return "No speaker measurement is active."
        case .invalidSeat:
            return "Calibration seat metadata is invalid."
        case .maximumSeatCount:
            return "Speaker calibration supports up to \(Int(N60_CALIBRATION_MAX_SEATS)) listening seats."
        case .staleCampaign:
            return "The saved calibration campaign no longer matches this Playback System routing."
        case .physicalRouteUnavailable(let source):
            return "No unique physical output route is available for \(source)."
        case .designRequired:
            return "Generate a calibration design before deployment."
        case .predictionRequired:
            return "Run calibration prediction verification before deployment."
        case .predictionRejected(let reasons):
            return "Calibration prediction blocked deployment: " + reasons.joined(separator: " ")
        case .intelligentTargetRequiresCompleteCampaign:
            return "Complete all included speaker measurements before generating an adaptive calibration target."
        }
    }
}

struct MultichannelCalibrationCampaignArchive: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var playbackSystemID: UUID
    var routingSignature: String
    var sampleRate: Double
    var seats: [MultichannelCalibrationSeat]
    var measurements: [MultichannelCalibrationMeasurement]
    var modifiedAt: Date = Date()
}

struct MultichannelCalibrationCampaignStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func url(for playbackSystemID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(playbackSystemID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func load(_ playbackSystemID: UUID) throws -> MultichannelCalibrationCampaignArchive? {
        let url = url(for: playbackSystemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let archive = try JSONDecoder().decode(MultichannelCalibrationCampaignArchive.self, from: data)
        guard archive.schemaVersion == MultichannelCalibrationCampaignArchive.currentSchemaVersion,
              archive.playbackSystemID == playbackSystemID else {
            throw MultichannelCalibrationCampaignError.staleCampaign
        }
        return archive
    }

    func save(_ archive: MultichannelCalibrationCampaignArchive) throws {
        guard archive.schemaVersion == MultichannelCalibrationCampaignArchive.currentSchemaVersion,
              archive.sampleRate.isFinite,
              archive.sampleRate > 0 else {
            throw MultichannelCalibrationCampaignError.staleCampaign
        }
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: url(for: archive.playbackSystemID), options: .atomic)
    }

    func delete(_ playbackSystemID: UUID) throws {
        let url = url(for: playbackSystemID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent("Multichannel Calibration", isDirectory: true)
    }
}

extension OutputDeviceProfileConfiguration {
    /// Identity of the physical acoustic topology only. Deployed calibration is
    /// deliberately excluded so applying a new design does not invalidate the
    /// measurements that produced it.
    var multichannelCalibrationRoutingSignature: String {
        let speakers = speakerAssignments
            .sorted { lhs, rhs in
                if lhs.role.rawValue != rhs.role.rawValue { return lhs.role.rawValue < rhs.role.rawValue }
                if lhs.destination.deviceUID != rhs.destination.deviceUID {
                    return lhs.destination.deviceUID < rhs.destination.deviceUID
                }
                return lhs.destination.channelIndex < rhs.destination.channelIndex
            }
            .map {
                "speaker:\($0.role.rawValue):\($0.destination.deviceUID):\($0.destination.channelIndex)"
            }
        let subs = subwooferAssignments
            .sorted { $0.index < $1.index }
            .map {
                "sub:\($0.index):\($0.destination.deviceUID):\($0.destination.channelIndex)"
            }
        return ([programLayout.rawValue, referenceDeviceUID ?? "auto"] + speakers + subs)
            .joined(separator: "|")
    }
}

@MainActor
final class MultichannelCalibrationController: ObservableObject {
    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    private let store: MultichannelCalibrationCampaignStore
    private let transportFactory: MultichannelCalibrationTransportFactory
    private let analysisOperation: MultichannelCalibrationAnalysisOperation
    private let designer = MultichannelCalibrationDesigner()
    private let predictionVerifier =
        MultichannelCalibrationPredictionVerifier()
    private let sweepGenerator = RoomCorrectionSweepGenerator()
    private var activeTransport: (any MultichannelCalibrationTransporting)?
    private var activeProgram: RoomCorrectionSweepProgram?
    private var activeTarget: MultichannelCalibrationTarget?
    private var analysisGeneration: UInt64 = 0
    private var campaignSystemID: UUID?
    private var campaignSignature = ""
    private var campaignSampleRate = 0.0

    @Published private(set) var state: MultichannelCalibrationCampaignState = .idle
    @Published private(set) var seats: [MultichannelCalibrationSeat] = []
    @Published private(set) var measurements: [MultichannelCalibrationMeasurement] = []
    @Published private(set) var latestDesign: MultichannelCalibrationDesign?
    @Published private(set) var latestPrediction:
        CalibrationPredictionReport?
    @Published private(set) var intelligentTargetReport:
        IntelligentTargetGenerationReport?
    @Published private(set) var lastErrorDescription: String?

    init(
        engine: AudioIOEngine,
        profiles: ProductProfileController,
        microphone: RoomCorrectionCalibrationController,
        store: MultichannelCalibrationCampaignStore = MultichannelCalibrationCampaignStore(),
        transportFactory: @escaping MultichannelCalibrationTransportFactory = {
            routePlan, outputs, input, inputChannel, program, physicalOutput in
            try MultichannelCalibrationTransport(
                routePlan: routePlan,
                availableOutputs: outputs,
                input: input,
                inputChannelIndex: inputChannel,
                program: program,
                physicalOutputChannelIndex: physicalOutput
            )
        },
        analysisOperation: @escaping MultichannelCalibrationAnalysisOperation = {
            capture, program, microphoneCalibration in
            try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionMeasurementAnalyzer().analyzeSingleChannel(
                    rawCapture: capture.samples,
                    program: program,
                    microphoneCalibration: microphoneCalibration
                )
            }.value
        }
    ) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.store = store
        self.transportFactory = transportFactory
        self.analysisOperation = analysisOperation
    }

    var profile: OutputDeviceProfileConfiguration? {
        guard let profile = profiles.selectedSystemOutputDeviceProfile, profile.enabled else { return nil }
        return profile
    }

    var sources: [MultichannelCalibrationSource] {
        guard let profile else { return [] }
        let speakers = profile.programLayout.roles
            .filter { $0 != .lowFrequencyEffects }
            .map(MultichannelCalibrationSource.speaker)
        let subs = profile.subwooferAssignments
            .sorted { $0.index < $1.index }
            .map { MultichannelCalibrationSource.subwoofer($0.index) }
        return speakers + subs
    }

    var includedSeats: [MultichannelCalibrationSeat] {
        seats.filter { $0.included && $0.weight > 0 }
    }

    var totalMeasurementCount: Int { includedSeats.count * sources.count }

    var completedMeasurementCount: Int {
        requiredTargets().filter { target in
            measurements.contains { $0.seatID == target.seat.id && $0.source == target.source }
        }.count
    }

    var measurementProgress: Double {
        guard totalMeasurementCount > 0 else { return 0 }
        return min(max(Double(completedMeasurementCount) / Double(totalMeasurementCount), 0), 1)
    }

    var currentTarget: MultichannelCalibrationTarget? { activeTarget ?? nextTarget() }

    var campaignComplete: Bool {
        totalMeasurementCount > 0 && completedMeasurementCount == totalMeasurementCount
    }

    var canMeasure: Bool {
        state != .measuring
            && state != .analyzing
            && profile != nil
            && microphone.permissionStatus == .authorized
            && microphone.selectedInputDevice != nil
            && engine.selectedOutputDevice != nil
            && engine.lifecycleState == .idle
            && nextTarget() != nil
    }

    func prepareForUse() {
        do {
            try synchronizeCampaign()
            lastErrorDescription = nil
        } catch {
            fail(error)
        }
    }

    func synchronizeCampaign() throws {
        guard activeTransport == nil else { return }
        guard let systemID = profiles.selectedSystemProfileID else {
            clearInMemory()
            state = .idle
            return
        }
        guard let profile, let output = engine.selectedOutputDevice else {
            clearInMemory()
            campaignSystemID = systemID
            state = .idle
            return
        }
        let signature = profile.multichannelCalibrationRoutingSignature
        let sampleRate = output.nominalSampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw MultichannelCalibrationCampaignError.outputRequired
        }

        if campaignSystemID == systemID,
           campaignSignature == signature,
           abs(campaignSampleRate - sampleRate) < 0.5,
           !seats.isEmpty {
            state = campaignComplete ? .reviewing : .ready
            return
        }

        campaignSystemID = systemID
        campaignSignature = signature
        campaignSampleRate = sampleRate
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        if let archive = try store.load(systemID),
           archive.routingSignature == signature,
           abs(archive.sampleRate - sampleRate) < 0.5 {
            seats = normalizedSeats(archive.seats)
            measurements = archive.measurements.filter { measurement in
                abs(measurement.sampleRate - sampleRate) < 0.5
                    && sources.contains(measurement.source)
                    && seats.contains(where: { $0.id == measurement.seatID })
            }
        } else {
            seats = [MultichannelCalibrationSeat(name: "Main Seat")]
            measurements = []
            try persistCampaign()
        }
        state = campaignComplete ? .reviewing : .ready
    }

    func addSeat(named proposedName: String? = nil) throws {
        guard activeTransport == nil else {
            throw MultichannelCalibrationCampaignError.measurementAlreadyActive
        }
        guard seats.count < Int(N60_CALIBRATION_MAX_SEATS) else {
            throw MultichannelCalibrationCampaignError.maximumSeatCount
        }
        let index = seats.count + 1
        let trimmed = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        seats.append(MultichannelCalibrationSeat(
            name: trimmed.isEmpty ? "Seat \(index)" : trimmed
        ))
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        state = .ready
        try persistCampaign()
    }

    func updateSeat(
        _ id: UUID,
        name: String,
        included: Bool,
        weight: Double
    ) throws {
        guard activeTransport == nil else {
            throw MultichannelCalibrationCampaignError.measurementAlreadyActive
        }
        guard let index = seats.firstIndex(where: { $0.id == id }),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              weight.isFinite,
              weight >= 0 else {
            throw MultichannelCalibrationCampaignError.invalidSeat
        }
        seats[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        seats[index].included = included
        seats[index].weight = weight
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        state = campaignComplete ? .reviewing : .ready
        try persistCampaign()
    }

    func removeSeat(_ id: UUID) throws {
        guard activeTransport == nil else {
            throw MultichannelCalibrationCampaignError.measurementAlreadyActive
        }
        guard seats.count > 1, seats.contains(where: { $0.id == id }) else {
            throw MultichannelCalibrationCampaignError.invalidSeat
        }
        seats.removeAll { $0.id == id }
        measurements.removeAll { $0.seatID == id }
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        state = campaignComplete ? .reviewing : .ready
        try persistCampaign()
    }

    func resetMeasurements() throws {
        cancelMeasurement()
        measurements = []
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        state = profile == nil ? .idle : .ready
        try persistCampaign()
    }

    func beginNextMeasurement() throws {
        guard activeTransport == nil else {
            throw MultichannelCalibrationCampaignError.measurementAlreadyActive
        }
        try synchronizeCampaign()
        guard engine.lifecycleState == .idle else {
            throw MultichannelCalibrationCampaignError.playbackMustBeIdle(engine.lifecycleState)
        }
        guard microphone.permissionStatus == .authorized else {
            throw MultichannelCalibrationCampaignError.microphonePermissionRequired
        }
        guard let input = microphone.selectedInputDevice else {
            throw MultichannelCalibrationCampaignError.measurementInputRequired
        }
        guard let output = engine.selectedOutputDevice,
              let selectedOutputUID = engine.routeConfiguration.selectedOutputUID else {
            throw MultichannelCalibrationCampaignError.outputRequired
        }
        guard let profile else {
            throw MultichannelCalibrationCampaignError.outputDeviceProfileRequired
        }
        guard let target = nextTarget() else {
            throw MultichannelCalibrationCampaignError.campaignComplete
        }

        let bassEnabled = profiles.selectedSystemProfile?.state.bassManagement.enabled
            ?? engine.bassManagementConfiguration.enabled
        let routePlan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices,
            sampleRate: output.nominalSampleRate,
            selectedOutputUID: selectedOutputUID,
            bassManagementEnabled: bassEnabled
        )
        let physicalOutput = try physicalOutputChannel(for: target.source, routePlan: routePlan)

        let settings = RoomCorrectionSweepSettings(
            sampleRate: output.nominalSampleRate,
            startFrequencyHz: microphone.sweepStartFrequencyHz,
            endFrequencyHz: microphone.sweepEndFrequencyHz,
            durationSeconds: microphone.sweepDurationSeconds,
            levelDBFS: microphone.sweepLevelDBFS,
            leadInSeconds: microphone.sweepLeadInSeconds,
            tailSeconds: microphone.sweepTailSeconds,
            fadeSeconds: microphone.sweepFadeSeconds
        )
        let program = try sweepGenerator.makeProgram(settings: settings)
        let transport = try transportFactory(
            routePlan,
            engine.outputDevices,
            input,
            microphone.selectedInputChannelIndex,
            program,
            physicalOutput
        )
        analysisGeneration &+= 1
        activeProgram = program
        activeTarget = MultichannelCalibrationTarget(
            seat: target.seat,
            source: target.source,
            physicalOutputChannelIndex: physicalOutput
        )
        activeTransport = transport
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        do {
            try transport.start()
            state = .measuring
            lastErrorDescription = nil
        } catch {
            transport.cancel()
            activeTransport = nil
            activeProgram = nil
            activeTarget = nil
            fail(error)
            throw error
        }
    }

    func measurementSnapshot() -> N60TargetedRoomMeasurementBridgeSnapshot? {
        activeTransport?.snapshot()
    }

    var activeMeasurementProgress: Double {
        guard let snapshot = measurementSnapshot(), snapshot.totalFrameCount > 0 else { return 0 }
        return min(max(Double(snapshot.frameCursor) / Double(snapshot.totalFrameCount), 0), 1)
    }

    @discardableResult
    func finishMeasurementIfComplete() async throws -> Bool {
        guard state == .measuring, let transport = activeTransport else { return false }
        guard transport.snapshot()?.complete == true else { return false }
        let capture: MultichannelCalibrationCapture
        do {
            capture = try transport.finishAndMaterialize()
        } catch {
            activeTransport = nil
            activeProgram = nil
            activeTarget = nil
            fail(error)
            throw error
        }
        activeTransport = nil
        guard let program = activeProgram, let target = activeTarget else {
            activeProgram = nil
            activeTarget = nil
            let error = MultichannelCalibrationCampaignError.measurementNotActive
            fail(error)
            throw error
        }
        activeProgram = nil
        state = .analyzing
        let generation = analysisGeneration

        do {
            let analyzed = try await analysisOperation(
                capture,
                program,
                microphone.microphoneCalibration
            )
            guard generation == analysisGeneration, state == .analyzing else { return false }
            let compact = compactMeasurement(analyzed, sampleRate: program.sampleRate)
            measurements.removeAll {
                $0.seatID == target.seat.id && $0.source == target.source
            }
            measurements.append(MultichannelCalibrationMeasurement(
                seatID: target.seat.id,
                source: target.source,
                sampleRate: program.sampleRate,
                channel: compact
            ))
            latestDesign = nil
            latestPrediction = nil
            intelligentTargetReport = nil
            activeTarget = nil
            try persistCampaign()
            state = campaignComplete ? .reviewing : .ready
            lastErrorDescription = nil
            return true
        } catch {
            activeTarget = nil
            fail(error)
            throw error
        }
    }

    func cancelMeasurement() {
        analysisGeneration &+= 1
        activeTransport?.cancel()
        activeTransport = nil
        activeProgram = nil
        activeTarget = nil
        state = profile == nil ? .idle : (campaignComplete ? .reviewing : .ready)
        lastErrorDescription = nil
    }

    func remeasure(seatID: UUID, source: MultichannelCalibrationSource) throws {
        guard activeTransport == nil else {
            throw MultichannelCalibrationCampaignError.measurementAlreadyActive
        }
        measurements.removeAll { $0.seatID == seatID && $0.source == source }
        latestDesign = nil
        latestPrediction = nil
        intelligentTargetReport = nil
        state = .ready
        try persistCampaign()
    }

    @discardableResult
    func generateIntelligentTarget(
        preference: IntelligentTargetPreference
    ) throws -> IntelligentTargetGenerationReport {
        try synchronizeCampaign()
        guard campaignComplete else {
            throw MultichannelCalibrationCampaignError
                .intelligentTargetRequiresCompleteCampaign
        }
        guard let output = engine.selectedOutputDevice else {
            throw MultichannelCalibrationCampaignError.outputRequired
        }

        let included = includedSeats
        let seatByID = Dictionary(
            uniqueKeysWithValues: included.map { ($0.id, $0) }
        )
        let speakerSources = sources.compactMap {
            source -> MultichannelCalibrationSource? in
            if case .speaker = source { return source }
            return nil
        }
        let speakerCount = max(speakerSources.count, 1)
        let speakerSet = Set(speakerSources)

        let evidence = try measurements.compactMap {
            measurement -> IntelligentTargetEvidenceSample? in
            guard speakerSet.contains(measurement.source),
                  let seat = seatByID[measurement.seatID],
                  let response = measurement.channel.transferFunction else {
                return nil
            }
            return IntelligentTargetEvidenceSample(
                label: "\(seat.name) \(measurement.source.displayName)",
                response: response,
                quality: measurement.channel.quality,
                weight: seat.weight / Double(speakerCount)
            )
        }

        let parameters = RoomCorrectionDesignParameters(
            correctionLowHz:
                MultichannelCalibrationDesigner.minimumFrequencyHz,
            correctionHighHz: min(
                MultichannelCalibrationDesigner
                    .nominalMaximumFrequencyHz,
                output.nominalSampleRate * 0.48
            ),
            smoothingOctaves: 1.0 / 6.0,
            maximumBoostDB: 4.0,
            maximumCutDB: 8.0,
            requestedTapCount: 4_096
        )
        let report = try IntelligentRoomTargetGenerator().generate(
            samples: evidence,
            parameters: parameters,
            preference: preference
        )
        intelligentTargetReport = report
        latestDesign = nil
        latestPrediction = nil
        lastErrorDescription = nil
        return report
    }

    func clearIntelligentTarget() {
        intelligentTargetReport = nil
        latestDesign = nil
        latestPrediction = nil
        state = campaignComplete ? .reviewing : .ready
    }

    @discardableResult
    func designCalibration(target: RoomCorrectionTargetCurve? = nil) async throws -> MultichannelCalibrationDesign {
        try synchronizeCampaign()
        let resolvedTarget = target ?? intelligentTargetReport?.target
        guard let profile, let output = engine.selectedOutputDevice else {
            throw MultichannelCalibrationCampaignError.outputDeviceProfileRequired
        }
        let seats = seats
        let measurements = measurements
        let bassEnabled = profiles.selectedSystemProfile?.state.bassManagement.enabled
            ?? engine.bassManagementConfiguration.enabled
        let measuredAt = measurements.compactMap { $0.channel.capturedAt }.max() ?? Date()
        do {
            let result = try await Task.detached(
                priority: .userInitiated
            ) { [designer, predictionVerifier] in
                let design = try designer.design(
                    profile: profile,
                    bassManagementEnabled: bassEnabled,
                    seats: seats,
                    measurements: measurements,
                    sampleRate: output.nominalSampleRate,
                    target: resolvedTarget,
                    measuredAt: measuredAt,
                    deployedAt: Date()
                )
                let prediction = try predictionVerifier.verify(
                    design: design,
                    seats: seats,
                    measurements: measurements,
                    target: resolvedTarget
                )
                return (design, prediction)
            }.value
            latestDesign = result.0
            latestPrediction = result.1
            state = .reviewing
            lastErrorDescription = nil
            return result.0
        } catch {
            fail(error)
            throw error
        }
    }

    func deployLatestDesign() throws {
        guard engine.lifecycleState == .idle else {
            throw MultichannelCalibrationCampaignError.playbackMustBeIdle(engine.lifecycleState)
        }
        guard let design = latestDesign else {
            throw MultichannelCalibrationCampaignError.designRequired
        }
        guard let prediction = latestPrediction else {
            throw MultichannelCalibrationCampaignError.predictionRequired
        }
        guard prediction.accepted else {
            throw MultichannelCalibrationCampaignError.predictionRejected(
                prediction.blockingReasons
            )
        }
        guard let profile else {
            throw MultichannelCalibrationCampaignError.outputDeviceProfileRequired
        }
        let updated = try design.applying(to: profile)
        try profiles.replaceSelectedSystemOutputDeviceProfile(updated)
        campaignSignature = updated.multichannelCalibrationRoutingSignature
        state = .reviewing
        lastErrorDescription = nil
    }

    func clearError() { lastErrorDescription = nil }

    private func nextTarget() -> MultichannelCalibrationTarget? {
        requiredTargets().first { target in
            !measurements.contains { $0.seatID == target.seat.id && $0.source == target.source }
        }
    }

    private func requiredTargets() -> [MultichannelCalibrationTarget] {
        includedSeats.flatMap { seat in
            sources.map { source in
                MultichannelCalibrationTarget(
                    seat: seat,
                    source: source,
                    physicalOutputChannelIndex: UInt32.max
                )
            }
        }
    }

    private func physicalOutputChannel(
        for source: MultichannelCalibrationSource,
        routePlan: LiveNChannelOutputRoutePlan
    ) throws -> UInt32 {
        let channel: UInt32
        switch source {
        case .speaker(let role):
            guard role != .lowFrequencyEffects,
                  let index = routePlan.programLayout.roles.firstIndex(of: role),
                  index < routePlan.programPhysicalChannels.count else {
                throw MultichannelCalibrationCampaignError.physicalRouteUnavailable(source.displayName)
            }
            channel = routePlan.programPhysicalChannels[index]
        case .subwoofer(let index):
            guard Int(index) < routePlan.subwooferPhysicalChannels.count else {
                throw MultichannelCalibrationCampaignError.physicalRouteUnavailable(source.displayName)
            }
            channel = routePlan.subwooferPhysicalChannels[Int(index)]
        }
        guard channel != UInt32.max, channel < routePlan.physicalChannelCount else {
            throw MultichannelCalibrationCampaignError.physicalRouteUnavailable(source.displayName)
        }
        return channel
    }

    private func compactMeasurement(
        _ measurement: RoomCorrectionChannelMeasurement,
        sampleRate: Double
    ) -> RoomCorrectionChannelMeasurement {
        var compact = measurement
        compact.rawCapture = []
        if let arrival = measurement.quality.directArrivalSeconds,
           arrival.isFinite,
           arrival >= 0 {
            let arrivalFrame = max(0, Int((arrival * sampleRate).rounded()))
            let retainedTail = max(256, Int((sampleRate * 0.05).rounded()))
            let count = min(measurement.impulseResponse.count, arrivalFrame + retainedTail)
            compact.impulseResponse = Array(measurement.impulseResponse.prefix(max(count, 1)))
        }
        return compact
    }

    private func persistCampaign() throws {
        guard let systemID = campaignSystemID,
              campaignSampleRate.isFinite,
              campaignSampleRate > 0 else { return }
        let archive = MultichannelCalibrationCampaignArchive(
            playbackSystemID: systemID,
            routingSignature: campaignSignature,
            sampleRate: campaignSampleRate,
            seats: seats,
            measurements: measurements,
            modifiedAt: Date()
        )
        try store.save(archive)
    }

    private func normalizedSeats(_ stored: [MultichannelCalibrationSeat]) -> [MultichannelCalibrationSeat] {
        let valid = stored.filter {
            !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.weight.isFinite
                && $0.weight >= 0
        }
        return Array(valid.prefix(Int(N60_CALIBRATION_MAX_SEATS))).isEmpty
            ? [MultichannelCalibrationSeat(name: "Main Seat")]
            : Array(valid.prefix(Int(N60_CALIBRATION_MAX_SEATS)))
    }

    private func clearInMemory() {
        analysisGeneration &+= 1
        activeTransport?.cancel()
        activeTransport = nil
        activeProgram = nil
        activeTarget = nil
        campaignSignature = ""
        campaignSampleRate = 0
        seats = []
        measurements = []
        latestDesign = nil
        latestPrediction = nil
        lastErrorDescription = nil
    }

    private func fail(_ error: Error) {
        activeTransport?.cancel()
        activeTransport = nil
        activeProgram = nil
        activeTarget = nil
        state = .failed
        lastErrorDescription = error.localizedDescription
    }
}
