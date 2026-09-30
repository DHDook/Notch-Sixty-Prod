import Combine
import Foundation

enum ProductProfileOrigin: String, Codable, Sendable {
    case factory
    case user
}

struct ContentPresetState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var stereoEQ: StereoEQConfiguration
    var inputPreampDB: Double
    var headroomAttenuationDB: Double
    var dynamics: DynamicsConfiguration

    init(
        schemaVersion: Int = ContentPresetState.currentSchemaVersion,
        stereoEQ: StereoEQConfiguration = StereoEQConfiguration(),
        inputPreampDB: Double = 0,
        headroomAttenuationDB: Double = 0,
        dynamics: DynamicsConfiguration = DynamicsConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.stereoEQ = stereoEQ
        self.inputPreampDB = inputPreampDB
        self.headroomAttenuationDB = headroomAttenuationDB
        self.dynamics = dynamics
    }

    func composingGain(over base: DSPGainConfiguration) -> DSPGainConfiguration {
        var result = base
        result.inputPreampDB = inputPreampDB
        result.headroomAttenuationDB = headroomAttenuationDB
        return result
    }
}

struct ContentPreset: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var origin: ProductProfileOrigin
    var state: ContentPresetState

    init(
        schemaVersion: Int = ContentPreset.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        origin: ProductProfileOrigin,
        state: ContentPresetState
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.origin = origin
        self.state = state
    }
}

struct PlaybackSystemControlState: Codable, Equatable, Sendable {
    var balance: Double
    var symmetryBalanceEnabled: Bool
    var symmetryBalancePosition: Double
    var speakerCrossfeedEnabled: Bool
    var speakerCrossfeedAmount: Double
    var crosstalkCancellationEnabled: Bool
    var crosstalkCancellationAmount: Double
    var crosstalkHeadShadowFrequencyHz: Double
    var interChannelDelayMs: Double

    init(_ playback: PlaybackControlConfiguration = PlaybackControlConfiguration()) {
        balance = playback.balance
        symmetryBalanceEnabled = playback.symmetryBalanceEnabled
        symmetryBalancePosition = playback.symmetryBalancePosition
        speakerCrossfeedEnabled = playback.speakerCrossfeedEnabled
        speakerCrossfeedAmount = playback.speakerCrossfeedAmount
        crosstalkCancellationEnabled = playback.crosstalkCancellationEnabled
        crosstalkCancellationAmount = playback.crosstalkCancellationAmount
        crosstalkHeadShadowFrequencyHz = playback.crosstalkHeadShadowFrequencyHz
        interChannelDelayMs = playback.interChannelDelayMs
    }

    func applying(to base: PlaybackControlConfiguration) -> PlaybackControlConfiguration {
        // globalBypassed and auditionMode are session state and intentionally survive.
        var result = base
        result.balance = balance
        result.symmetryBalanceEnabled = symmetryBalanceEnabled
        result.symmetryBalancePosition = symmetryBalancePosition
        result.speakerCrossfeedEnabled = speakerCrossfeedEnabled
        result.speakerCrossfeedAmount = speakerCrossfeedAmount
        result.crosstalkCancellationEnabled = crosstalkCancellationEnabled
        result.crosstalkCancellationAmount = crosstalkCancellationAmount
        result.crosstalkHeadShadowFrequencyHz = crosstalkHeadShadowFrequencyHz
        result.interChannelDelayMs = interChannelDelayMs
        return result
    }
}

struct PlaybackSystemState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var associatedOutputUID: String?
    var outputGainDB: Double
    var playback: PlaybackSystemControlState
    var bassManagement: BassManagementConfiguration
    var roomCorrection: RoomCorrectionConfiguration
    var roomCorrectionCalibration: RoomCorrectionCalibrationSummary?
    var outputRouting: MultiOutputRoutingConfiguration?
    var speakerDriverProcessing: SpeakerDriverProcessingConfiguration?
    var speakerIR: SpeakerIRConfiguration

    init(
        schemaVersion: Int = PlaybackSystemState.currentSchemaVersion,
        associatedOutputUID: String? = nil,
        outputGainDB: Double = 0,
        playback: PlaybackSystemControlState = PlaybackSystemControlState(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),
        roomCorrectionCalibration: RoomCorrectionCalibrationSummary? = nil,
        outputRouting: MultiOutputRoutingConfiguration? = nil,
        speakerDriverProcessing: SpeakerDriverProcessingConfiguration? = nil,
        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.associatedOutputUID = associatedOutputUID
        self.outputGainDB = outputGainDB
        self.playback = playback
        self.bassManagement = bassManagement
        self.roomCorrection = roomCorrection
        self.roomCorrectionCalibration = roomCorrectionCalibration
        self.outputRouting = outputRouting
        self.speakerDriverProcessing = speakerDriverProcessing
        self.speakerIR = speakerIR
    }

    func composingGain(over base: DSPGainConfiguration) -> DSPGainConfiguration {
        // Input preamp/headroom belong to the selected Content Preset.
        var result = base
        result.outputGainDB = outputGainDB
        return result
    }
}

struct PlaybackSystemProfile: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var id: UUID
    var name: String
    var state: PlaybackSystemState

    init(
        schemaVersion: Int = PlaybackSystemProfile.currentSchemaVersion,
        id: UUID = UUID(),
        name: String,
        state: PlaybackSystemState
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.state = state
    }
}

enum ProductProfileError: Error, LocalizedError {
    case outputChangeRequiresIdle(profile: String)
    case persistenceVersion(Int)
    case roomCorrectionCalibrationVersion(Int)
    case selectedSystemProfileRequired

    var errorDescription: String? {
        switch self {
        case .outputChangeRequiresIdle(let profile):
            return "Stop processing before selecting \(profile); it is associated with a different output device."
        case .persistenceVersion(let version):
            return "Saved profile data uses unsupported schema version \(version)."
        case .roomCorrectionCalibrationVersion(let version):
            return "Room-correction calibration metadata uses unsupported schema version \(version)."
        case .selectedSystemProfileRequired:
            return "Select a Playback System before changing deployed room correction."
        }
    }
}

@MainActor
final class ProductProfileController: ObservableObject {
    private struct Archive: Codable {
        static let currentSchemaVersion = 1
        var schemaVersion: Int = 1
        var userContentPresets: [ContentPreset]
        var systemProfiles: [PlaybackSystemProfile]
        var selectedContentPresetID: UUID?
        var selectedSystemProfileID: UUID?
    }

    private static let referencePresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000001")!
    private static let defaultSystemID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000002")!
    private static let rockArenaPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000010")!
    private static let modernPopPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000011")!
    private static let hipHopClubPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000012")!
    private static let cinemaPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000013")!
    private static let streamingPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000014")!
    private static let classicPopRockPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000015")!
    private static let vocalStandardsPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000016")!
    private static let classicPopRockPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000015")!
    private static let vocalStandardsPresetID = UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000016")!

    private static func factoryBand(
        _ type: EQFilterType,
        _ frequencyHz: Double,
        _ gainDB: Double,
        _ q: Double
    ) -> EQBand {
        EQBand(
            enabled: true,
            type: type,
            frequencyHz: frequencyHz,
            gainDB: gainDB,
            q: q,
            slope: .db12
        )
    }

    private static func factoryEQ(_ bands: [EQBand]) -> StereoEQConfiguration {
        StereoEQConfiguration(
            channelMode: .linked,
            editChannel: .linked,
            phaseMode: .minimumPhase,
            bypassed: false,
            linkedBands: bands
        )
    }

    private static func factoryBaseDynamics(
        limiterLookAheadMs: Double = 1.5,
        limiterReleaseMs: Double = 80.0
    ) -> DynamicsConfiguration {
        var dynamics = DynamicsConfiguration()
        dynamics.dcOffsetFilter.enabled = true
        dynamics.infrasonicFilter.enabled = true
        dynamics.infrasonicFilter.cutoffHz = 18.0
        dynamics.infrasonicFilter.slope = .db48
        dynamics.limiter.enabled = true
        dynamics.limiter.ceilingDB = -0.5
        dynamics.limiter.attackMs = 0.1
        dynamics.limiter.lookAheadMs = limiterLookAheadMs
        dynamics.limiter.releaseMs = limiterReleaseMs
        dynamics.limiter.truePeakGuardEnabled = true
        return dynamics
    }

    private static func modernPopDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics()
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -18.0
        dynamics.compressor.ratio = 1.4
        dynamics.compressor.attackMs = 20.0
        dynamics.compressor.releaseMs = 120.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 0.7
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = true
        dynamics.stereoWidener.lowWidth = 0.0
        dynamics.stereoWidener.midWidth = 1.15
        dynamics.stereoWidener.highWidth = 1.12
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func hipHopClubDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics(limiterLookAheadMs: 2.0, limiterReleaseMs: 100.0)
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -20.0
        dynamics.compressor.ratio = 1.5
        dynamics.compressor.attackMs = 25.0
        dynamics.compressor.releaseMs = 150.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 1.0
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = true
        dynamics.stereoWidener.lowWidth = 0.0
        dynamics.stereoWidener.midWidth = 1.08
        dynamics.stereoWidener.highWidth = 1.05
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func streamingDynamics() -> DynamicsConfiguration {
        var dynamics = factoryBaseDynamics()
        dynamics.compressor.enabled = true
        dynamics.compressor.thresholdDB = -20.0
        dynamics.compressor.ratio = 1.35
        dynamics.compressor.attackMs = 15.0
        dynamics.compressor.releaseMs = 100.0
        dynamics.compressor.kneeWidthDB = 6.0
        dynamics.compressor.makeupGainDB = 0.5
        dynamics.stereoWidener.enabled = true
        dynamics.stereoWidener.monoLowBand = false
        dynamics.stereoWidener.lowWidth = 1.0
        dynamics.stereoWidener.midWidth = 1.05
        dynamics.stereoWidener.highWidth = 1.05
        dynamics.stereoWidener.lowMidFrequencyHz = 180.0
        dynamics.stereoWidener.midHighFrequencyHz = 4_000.0
        return dynamics
    }

    private static func factoryState(
        bands: [EQBand],
        inputPreampDB: Double,
        headroomAttenuationDB: Double,
        dynamics: DynamicsConfiguration
    ) -> ContentPresetState {
        ContentPresetState(
            stereoEQ: factoryEQ(bands),
            inputPreampDB: inputPreampDB,
            headroomAttenuationDB: headroomAttenuationDB,
            dynamics: dynamics
        )
    }

    private static let factoryContentPresets: [ContentPreset] = [
        ContentPreset(
            id: referencePresetID,
            name: "Reference",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 42, 0.4, 0.65),
                    factoryBand(.peaking, 78, 0.5, 0.90),
                    factoryBand(.peaking, 165, -0.5, 1.00),
                    factoryBand(.peaking, 320, -0.4, 1.20),
                    factoryBand(.peaking, 680, 0.2, 1.00),
                    factoryBand(.peaking, 2_100, 0.4, 0.90),
                    factoryBand(.peaking, 3_600, -0.7, 1.20),
                    factoryBand(.peaking, 6_800, -0.2, 1.10),
                    factoryBand(.highShelf, 11_500, 0.8, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.7,
                dynamics: factoryBaseDynamics()
            )
        ),
        ContentPreset(
            id: rockArenaPresetID,
            name: "Rock Arena",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.8, 0.70),
                    factoryBand(.peaking, 82, 1.3, 0.90),
                    factoryBand(.peaking, 165, -0.5, 1.00),
                    factoryBand(.peaking, 320, 0.8, 1.00),
                    factoryBand(.peaking, 700, 1.5, 0.90),
                    factoryBand(.peaking, 1_800, 1.2, 1.00),
                    factoryBand(.peaking, 3_600, -1.3, 1.20),
                    factoryBand(.peaking, 6_500, -0.2, 1.10),
                    factoryBand(.highShelf, 12_000, 0.4, 0.70),
                ],
                inputPreampDB: -2.0,
                headroomAttenuationDB: -1.0,
                // Final listening revision: compressor and widener intentionally remain off.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 90.0)
            )
        ),
        ContentPreset(
            id: classicPopRockPresetID,
            name: "Classic Pop/Rock",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 50, 0.6, 0.70),
                    factoryBand(.peaking, 220, -0.5, 1.00),
                    factoryBand(.peaking, 750, 0.5, 0.90),
                    factoryBand(.peaking, 2_000, 0.9, 0.90),
                    factoryBand(.peaking, 4_500, -0.4, 1.10),
                    factoryBand(.highShelf, 11_000, 0.6, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.8,
                // Preserve vintage dynamics and image; no content compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 90.0)
            )
        ),
        ContentPreset(
            id: classicPopRockPresetID,
            name: "Classic Pop/Rock",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 50, 0.6, 0.70),
                    factoryBand(.peaking, 220, -0.5, 1.00),
                    factoryBand(.peaking, 750, 0.5, 0.90),
                    factoryBand(.peaking, 2_000, 0.9, 0.90),
                    factoryBand(.peaking, 4_500, -0.4, 1.10),
                    factoryBand(.highShelf, 11_000, 0.6, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.8,
                // Preserve vintage dynamics and image; no content compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 90.0)
            )
        ),
        ContentPreset(
            id: modernPopPresetID,
            name: "Modern Pop",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.4, 0.70),
                    factoryBand(.peaking, 70, 0.8, 0.90),
                    factoryBand(.peaking, 180, -0.5, 1.00),
                    factoryBand(.peaking, 900, 0.3, 1.00),
                    factoryBand(.peaking, 2_500, 0.6, 0.90),
                    factoryBand(.peaking, 5_500, 0.4, 1.00),
                    factoryBand(.highShelf, 12_000, 1.2, 0.70),
                ],
                inputPreampDB: -2.0,
                headroomAttenuationDB: -1.0,
                dynamics: modernPopDynamics()
            )
        ),
        ContentPreset(
            id: hipHopClubPresetID,
            name: "Hip-Hop Club",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 38, 1.4, 0.70),
                    factoryBand(.peaking, 60, 1.3, 0.90),
                    factoryBand(.peaking, 90, 0.6, 1.00),
                    factoryBand(.peaking, 220, -1.0, 1.10),
                    factoryBand(.peaking, 1_800, 0.4, 1.00),
                    factoryBand(.peaking, 4_000, -0.5, 1.10),
                    factoryBand(.highShelf, 10_000, 0.6, 0.70),
                ],
                inputPreampDB: -2.5,
                headroomAttenuationDB: -1.2,
                dynamics: hipHopClubDynamics()
            )
        ),
        ContentPreset(
            id: vocalStandardsPresetID,
            name: "Vocal Standards",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 70, 0.2, 0.70),
                    factoryBand(.peaking, 150, 0.5, 0.85),
                    factoryBand(.peaking, 350, -0.5, 1.00),
                    factoryBand(.peaking, 1_700, 0.9, 0.90),
                    factoryBand(.peaking, 4_000, -0.5, 1.10),
                    factoryBand(.highShelf, 10_500, 0.3, 0.70),
                ],
                inputPreampDB: -1.3,
                headroomAttenuationDB: -0.7,
                // Keep mono/hard-panned-era recordings natural; no compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 100.0)
            )
        ),
        ContentPreset(
            id: vocalStandardsPresetID,
            name: "Vocal Standards",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 70, 0.2, 0.70),
                    factoryBand(.peaking, 150, 0.5, 0.85),
                    factoryBand(.peaking, 350, -0.5, 1.00),
                    factoryBand(.peaking, 1_700, 0.9, 0.90),
                    factoryBand(.peaking, 4_000, -0.5, 1.10),
                    factoryBand(.highShelf, 10_500, 0.3, 0.70),
                ],
                inputPreampDB: -1.3,
                headroomAttenuationDB: -0.7,
                // Keep mono/hard-panned-era recordings natural; no compressor or widener.
                dynamics: factoryBaseDynamics(limiterReleaseMs: 100.0)
            )
        ),
        ContentPreset(
            id: cinemaPresetID,
            name: "Cinema",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 45, 0.4, 0.70),
                    factoryBand(.peaking, 120, -0.6, 1.00),
                    factoryBand(.peaking, 300, -0.7, 1.10),
                    factoryBand(.peaking, 2_000, 1.1, 0.90),
                    factoryBand(.peaking, 3_500, 0.4, 1.10),
                    factoryBand(.peaking, 7_000, -0.3, 1.00),
                    factoryBand(.highShelf, 12_000, 0.5, 0.70),
                ],
                inputPreampDB: -1.5,
                headroomAttenuationDB: -0.7,
                dynamics: factoryBaseDynamics()
            )
        ),
        ContentPreset(
            id: streamingPresetID,
            name: "Streaming",
            origin: .factory,
            state: factoryState(
                bands: [
                    factoryBand(.lowShelf, 60, 0.3, 0.70),
                    factoryBand(.peaking, 180, -0.5, 1.00),
                    factoryBand(.peaking, 500, -0.4, 1.00),
                    factoryBand(.peaking, 2_200, 0.8, 0.90),
                    factoryBand(.peaking, 4_500, -0.6, 1.10),
                    factoryBand(.highShelf, 10_000, 0.8, 0.70),
                ],
                inputPreampDB: -1.8,
                headroomAttenuationDB: -0.8,
                dynamics: streamingDynamics()
            )
        ),
    ]

    let engine: AudioIOEngine
    private let storageURL: URL
    private var didRestoreSelection = false

    @Published private(set) var userContentPresets: [ContentPreset] = []
    @Published private(set) var systemProfiles: [PlaybackSystemProfile] = []
    @Published private(set) var selectedContentPresetID: UUID?
    @Published private(set) var selectedSystemProfileID: UUID?
    @Published private(set) var lastErrorDescription: String?

    init(engine: AudioIOEngine, storageURL: URL? = nil) {
        self.engine = engine
        self.storageURL = storageURL ?? Self.defaultStorageURL()
        loadArchive()
        ensureDefaultSystemProfile()
        reconcileSelections()
    }

    var contentPresets: [ContentPreset] {
        Self.factoryContentPresets + userContentPresets
    }

    var selectedContentPreset: ContentPreset? {
        guard let selectedContentPresetID else { return nil }
        return contentPresets.first { $0.id == selectedContentPresetID }
    }

    var selectedSystemProfile: PlaybackSystemProfile? {
        guard let selectedSystemProfileID else { return nil }
        return systemProfiles.first { $0.id == selectedSystemProfileID }
    }

    var selectedContentPresetName: String { selectedContentPreset?.name ?? "Custom" }
    var selectedSystemProfileName: String { selectedSystemProfile?.name ?? "System" }
    var selectedSystemOutputRouting: MultiOutputRoutingConfiguration {
        selectedSystemProfile?.state.outputRouting ?? MultiOutputRoutingConfiguration()
    }
    var canOverwriteSelectedContentPreset: Bool { selectedContentPreset?.origin == .user }

    var selectedContentPresetIsDirty: Bool {
        guard let preset = selectedContentPreset else { return true }
        return preset.state != captureContentState()
    }

    var selectedSystemProfileIsDirty: Bool {
        guard let profile = selectedSystemProfile else { return true }
        var current = captureSystemState()
        current.associatedOutputUID = profile.state.associatedOutputUID
        return profile.state != current
    }

    var selectedSystemOutputMatches: Bool {
        guard let associated = selectedSystemProfile?.state.associatedOutputUID else { return true }
        return associated == engine.routeConfiguration.selectedOutputUID
    }

    func restoreSelectedLayers() {
        guard !didRestoreSelection else { return }
        didRestoreSelection = true
        do {
            if let system = selectedSystemProfile {
                try applySystemState(system.state, profileName: system.name)
            }
            if let preset = selectedContentPreset {
                try applyContentState(preset.state)
            }
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    func selectContentPreset(_ id: UUID) {
        guard let preset = contentPresets.first(where: { $0.id == id }) else { return }
        do {
            try applyContentState(preset.state)
            selectedContentPresetID = preset.id
            lastErrorDescription = nil
            persist()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func saveCurrentContentPreset(named proposedName: String) -> UUID {
        let preset = ContentPreset(
            name: uniqueContentName(proposedName),
            origin: .user,
            state: captureContentState()
        )
        userContentPresets.append(preset)
        selectedContentPresetID = preset.id
        lastErrorDescription = nil
        persist()
        return preset.id
    }

    func overwriteSelectedContentPreset() {
        guard let selectedContentPresetID,
              let index = userContentPresets.firstIndex(where: { $0.id == selectedContentPresetID }) else { return }
        userContentPresets[index].state = captureContentState()
        lastErrorDescription = nil
        persist()
    }

    func renameSelectedContentPreset(to proposedName: String) {
        guard let selectedContentPresetID,
              let index = userContentPresets.firstIndex(where: { $0.id == selectedContentPresetID }) else { return }
        let existing = Set(
            contentPresets
                .filter { $0.id != selectedContentPresetID }
                .map { $0.name.lowercased() }
        )
        userContentPresets[index].name = uniqueName(
            proposedName,
            existing: existing,
            fallback: "My Preset"
        )
        lastErrorDescription = nil
        persist()
    }

    func deleteSelectedContentPreset() {
        guard let selectedContentPresetID,
              let selected = selectedContentPreset,
              selected.origin == .user else { return }
        userContentPresets.removeAll { $0.id == selectedContentPresetID }
        self.selectedContentPresetID = nil
        persist()
    }

    func selectSystemProfile(_ id: UUID) {
        guard let profile = systemProfiles.first(where: { $0.id == id }) else { return }
        do {
            try applySystemState(profile.state, profileName: profile.name)
            selectedSystemProfileID = profile.id
            lastErrorDescription = nil
            persist()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func saveCurrentSystemProfile(named proposedName: String) -> UUID {
        let profile = PlaybackSystemProfile(
            name: uniqueSystemName(proposedName),
            state: captureSystemState()
        )
        systemProfiles.append(profile)
        selectedSystemProfileID = profile.id
        lastErrorDescription = nil
        persist()
        return profile.id
    }

    func overwriteSelectedSystemProfile() {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        let association = systemProfiles[index].state.associatedOutputUID
        var state = captureSystemState()
        state.associatedOutputUID = association
        systemProfiles[index].state = state
        lastErrorDescription = nil
        persist()
    }

    func renameSelectedSystemProfile(to proposedName: String) {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        let existing = Set(
            systemProfiles
                .filter { $0.id != selectedSystemProfileID }
                .map { $0.name.lowercased() }
        )
        systemProfiles[index].name = uniqueName(
            proposedName,
            existing: existing,
            fallback: "My System"
        )
        lastErrorDescription = nil
        persist()
    }

    func associateSelectedSystemWithCurrentOutput() {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        systemProfiles[index].state.associatedOutputUID = engine.routeConfiguration.selectedOutputUID
        lastErrorDescription = nil
        persist()
    }

    func replaceSelectedSystemOutputRouting(
        _ configuration: MultiOutputRoutingConfiguration?
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        if let configuration {
            try configuration.validateStructure()
        }

        let previousEngineConfiguration = engine.multiOutputRoutingConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceMultiOutputRoutingConfiguration(configuration)
            systemProfiles[index].state.outputRouting = configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceMultiOutputRoutingConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func replaceSelectedSystemSpeakerDriverProcessing(
        _ configuration: SpeakerDriverProcessingConfiguration
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        try configuration.validateStructure()

        let previousEngineConfiguration = engine.speakerDriverProcessingConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceSpeakerDriverProcessingConfiguration(configuration)
            systemProfiles[index].state.speakerDriverProcessing = configuration.isNeutral ? nil : configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceSpeakerDriverProcessingConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func replaceSelectedSystemBassManagement(
        _ configuration: BassManagementConfiguration
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }

        let previousEngineConfiguration = engine.bassManagementConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceBassManagementConfiguration(configuration)
            systemProfiles[index].state.bassManagement = configuration
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceBassManagementConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func setSelectedSystemBassManagementEnabled(_ enabled: Bool) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        var configuration = systemProfiles[index].state.bassManagement
        configuration.enabled = enabled
        try replaceSelectedSystemBassManagement(configuration)
    }

    func replaceSelectedSystemRoomCorrection(
        _ configuration: RoomCorrectionConfiguration,
        calibrationSummary summary: RoomCorrectionCalibrationSummary?
    ) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        if let summary, summary.schemaVersion != RoomCorrectionCalibrationSummary.currentSchemaVersion {
            throw ProductProfileError.roomCorrectionCalibrationVersion(summary.schemaVersion)
        }

        let previousEngineConfiguration = engine.roomCorrectionConfiguration
        let previousState = systemProfiles[index].state
        do {
            try engine.replaceRoomCorrectionConfiguration(configuration)
            systemProfiles[index].state.roomCorrection = configuration
            systemProfiles[index].state.roomCorrectionCalibration = summary
            try persistThrowing()
            lastErrorDescription = nil
        } catch {
            systemProfiles[index].state = previousState
            try? engine.replaceRoomCorrectionConfiguration(previousEngineConfiguration)
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func setSelectedSystemRoomCorrectionEnabled(_ enabled: Bool) throws {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else {
            throw ProductProfileError.selectedSystemProfileRequired
        }
        var configuration = systemProfiles[index].state.roomCorrection
        configuration.enabled = enabled
        try replaceSelectedSystemRoomCorrection(
            configuration,
            calibrationSummary: systemProfiles[index].state.roomCorrectionCalibration
        )
    }

    func setSelectedSystemRoomCorrectionCalibration(_ summary: RoomCorrectionCalibrationSummary?) {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        if let summary, summary.schemaVersion != RoomCorrectionCalibrationSummary.currentSchemaVersion {
            lastErrorDescription = ProductProfileError
                .roomCorrectionCalibrationVersion(summary.schemaVersion)
                .localizedDescription
            return
        }
        systemProfiles[index].state.roomCorrectionCalibration = summary
        lastErrorDescription = nil
        persist()
    }

    func deleteSelectedSystemProfile() {
        guard let selectedSystemProfileID else { return }
        systemProfiles.removeAll { $0.id == selectedSystemProfileID }
        self.selectedSystemProfileID = systemProfiles.first?.id
        ensureDefaultSystemProfile()
        persist()
    }

    func clearError() { lastErrorDescription = nil }

    func captureContentState() -> ContentPresetState {
        var eq = engine.stereoEQConfiguration
        switch eq.channelMode {
        case .linked: eq.setEditChannel(.linked)
        case .independent: eq.setEditChannel(.left)
        case .midSide: eq.setEditChannel(.mid)
        }
        let gain = engine.gainConfiguration
        var dynamics = engine.dynamicsConfiguration
        dynamics.spectralDenoiser.profileCommand = .none
        return ContentPresetState(
            stereoEQ: eq,
            inputPreampDB: gain.inputPreampDB,
            headroomAttenuationDB: gain.headroomAttenuationDB,
            dynamics: dynamics
        )
    }

    func captureSystemState() -> PlaybackSystemState {
        let gain = engine.gainConfiguration
        return PlaybackSystemState(
            associatedOutputUID: engine.routeConfiguration.selectedOutputUID,
            outputGainDB: gain.outputGainDB,
            playback: PlaybackSystemControlState(engine.playbackControlConfiguration),
            bassManagement: engine.bassManagementConfiguration,
            roomCorrection: engine.roomCorrectionConfiguration,
            roomCorrectionCalibration: selectedSystemProfile?.state.roomCorrectionCalibration,
            outputRouting: engine.multiOutputRoutingConfiguration,
            speakerDriverProcessing: engine.speakerDriverProcessingConfiguration.isNeutral
                ? nil
                : engine.speakerDriverProcessingConfiguration,
            speakerIR: engine.speakerIRConfiguration
        )
    }

    private func applyContentState(_ state: ContentPresetState) throws {
        let previous = captureContentState()
        do {
            let gain = state.composingGain(over: engine.gainConfiguration)
            try engine.replaceStereoEQConfiguration(state.stereoEQ)
            try engine.replaceDynamicsConfiguration(state.dynamics)
            try engine.replaceGainConfiguration(gain)
        } catch {
            let rollbackGain = previous.composingGain(over: engine.gainConfiguration)
            try? engine.replaceStereoEQConfiguration(previous.stereoEQ)
            try? engine.replaceDynamicsConfiguration(previous.dynamics)
            try? engine.replaceGainConfiguration(rollbackGain)
            throw error
        }
    }

    private func applySystemState(_ state: PlaybackSystemState, profileName: String) throws {
        let previous = captureSystemState()
        let previousOutputUID = engine.routeConfiguration.selectedOutputUID
        do {
            if let associated = state.associatedOutputUID,
               associated != engine.routeConfiguration.selectedOutputUID {
                guard engine.lifecycleState == .idle else {
                    throw ProductProfileError.outputChangeRequiresIdle(profile: profileName)
                }
                try engine.selectOutput(uid: associated)
            }

            let playback = state.playback.applying(to: engine.playbackControlConfiguration)
            let gain = state.composingGain(over: engine.gainConfiguration)
            try engine.replaceMultiOutputRoutingConfiguration(state.outputRouting)
            try engine.replaceSpeakerDriverProcessingConfiguration(
                state.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()
            )
            try engine.replacePlaybackControlConfiguration(playback)
            try engine.replaceBassManagementConfiguration(state.bassManagement)
            try engine.replaceGainConfiguration(gain)
            try engine.replaceRoomCorrectionConfiguration(state.roomCorrection)
            try engine.replaceSpeakerIRConfiguration(state.speakerIR)
        } catch {
            if engine.lifecycleState == .idle,
               engine.routeConfiguration.selectedOutputUID != previousOutputUID {
                try? engine.selectOutput(uid: previousOutputUID)
            }
            let playback = previous.playback.applying(to: engine.playbackControlConfiguration)
            let gain = previous.composingGain(over: engine.gainConfiguration)
            try? engine.replaceMultiOutputRoutingConfiguration(previous.outputRouting)
            try? engine.replaceSpeakerDriverProcessingConfiguration(
                previous.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()
            )
            try? engine.replacePlaybackControlConfiguration(playback)
            try? engine.replaceBassManagementConfiguration(previous.bassManagement)
            try? engine.replaceGainConfiguration(gain)
            try? engine.replaceRoomCorrectionConfiguration(previous.roomCorrection)
            try? engine.replaceSpeakerIRConfiguration(previous.speakerIR)
            throw error
        }
    }

    private func ensureDefaultSystemProfile() {
        guard systemProfiles.isEmpty else { return }
        systemProfiles = [
            PlaybackSystemProfile(
                id: Self.defaultSystemID,
                name: "Default System",
                state: captureSystemState()
            ),
        ]
        selectedSystemProfileID = Self.defaultSystemID
        persist()
    }

    private func reconcileSelections() {
        if let selectedContentPresetID,
           !contentPresets.contains(where: { $0.id == selectedContentPresetID }) {
            self.selectedContentPresetID = nil
        }
        if selectedContentPresetID == nil, userContentPresets.isEmpty {
            selectedContentPresetID = Self.referencePresetID
        }
        if let selectedSystemProfileID,
           !systemProfiles.contains(where: { $0.id == selectedSystemProfileID }) {
            self.selectedSystemProfileID = systemProfiles.first?.id
        }
    }

    private func uniqueContentName(_ proposed: String) -> String {
        uniqueName(
            proposed,
            existing: Set(contentPresets.map { $0.name.lowercased() }),
            fallback: "My Preset"
        )
    }

    private func uniqueSystemName(_ proposed: String) -> String {
        uniqueName(
            proposed,
            existing: Set(systemProfiles.map { $0.name.lowercased() }),
            fallback: "My System"
        )
    }

    private func uniqueName(_ proposed: String, existing: Set<String>, fallback: String) -> String {
        let trimmed = proposed.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? fallback : trimmed
        guard existing.contains(base.lowercased()) else { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)".lowercased()) {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }

    private func loadArchive() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            let archive = try JSONDecoder().decode(Archive.self, from: data)
            guard archive.schemaVersion == Archive.currentSchemaVersion else {
                throw ProductProfileError.persistenceVersion(archive.schemaVersion)
            }
            userContentPresets = archive.userContentPresets.filter {
                $0.schemaVersion == ContentPreset.currentSchemaVersion
                    && $0.state.schemaVersion == ContentPresetState.currentSchemaVersion
            }
            systemProfiles = archive.systemProfiles.filter {
                $0.schemaVersion == PlaybackSystemProfile.currentSchemaVersion
                    && $0.state.schemaVersion == PlaybackSystemState.currentSchemaVersion
                    && ($0.state.roomCorrectionCalibration == nil
                        || $0.state.roomCorrectionCalibration?.schemaVersion
                            == RoomCorrectionCalibrationSummary.currentSchemaVersion)
            }
            selectedContentPresetID = archive.selectedContentPresetID
            selectedSystemProfileID = archive.selectedSystemProfileID
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func persist() {
        do {
            try persistThrowing()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func persistThrowing() throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let archive = Archive(
            userContentPresets: userContentPresets,
            systemProfiles: systemProfiles,
            selectedContentPresetID: selectedContentPresetID,
            selectedSystemProfileID: selectedSystemProfileID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        try data.write(to: storageURL, options: .atomic)
    }

    private static func defaultStorageURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent("profiles-v1.json", isDirectory: false)
    }
}

struct RoomCorrectionCalibrationSummary: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var projectID: UUID
    var activeDesignID: UUID
    var measurementDate: Date?
    var designDate: Date
    var positionCount: Int
    var correctionLowHz: Double
    var correctionHighHz: Double
    var targetName: String
    var smoothingOctaves: Double
    var maximumBoostDB: Double
    var maximumCutDB: Double
    var recommendedHeadroomDB: Double
    var algorithmVersion: String

    init(
        schemaVersion: Int = RoomCorrectionCalibrationSummary.currentSchemaVersion,
        projectID: UUID,
        activeDesignID: UUID,
        measurementDate: Date? = nil,
        designDate: Date,
        positionCount: Int,
        correctionLowHz: Double,
        correctionHighHz: Double,
        targetName: String,
        smoothingOctaves: Double,
        maximumBoostDB: Double,
        maximumCutDB: Double,
        recommendedHeadroomDB: Double,
        algorithmVersion: String
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.activeDesignID = activeDesignID
        self.measurementDate = measurementDate
        self.designDate = designDate
        self.positionCount = positionCount
        self.correctionLowHz = correctionLowHz
        self.correctionHighHz = correctionHighHz
        self.targetName = targetName
        self.smoothingOctaves = smoothingOctaves
        self.maximumBoostDB = maximumBoostDB
        self.maximumCutDB = maximumCutDB
        self.recommendedHeadroomDB = recommendedHeadroomDB
        self.algorithmVersion = algorithmVersion
    }
}

struct RoomCorrectionCalibrationPoint: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var gainDB: Double
}

struct RoomCorrectionMicrophoneCalibration: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var sourceName: String?
    var points: [RoomCorrectionCalibrationPoint] = []
}

struct RoomCorrectionMicrophone: Codable, Equatable, Sendable {
    var stableID: String?
    var displayName: String
    var manufacturer: String?
    var inputChannelIndex: Int = 0
    var calibration: RoomCorrectionMicrophoneCalibration?
}

struct RoomCorrectionSweepSettings: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var sampleRate: Double
    var startFrequencyHz: Double = 20
    var endFrequencyHz: Double = 20_000
    var durationSeconds: Double = 5
    var levelDBFS: Double = -18
    var leadInSeconds: Double = 0.5
    var tailSeconds: Double = 1.0
    var fadeSeconds: Double = 0.02
}

struct RoomCorrectionFrequencyResponse: Codable, Equatable, Sendable {
    var frequenciesHz: [Double]
    var magnitudeDB: [Double]
    var phaseRadians: [Double]?
}

struct RoomCorrectionMeasurementQuality: Codable, Equatable, Sendable {
    var clipped: Bool = false
    var playbackPeakDBFS: Double?
    var capturePeakDBFS: Double?
    var estimatedNoiseFloorDBFS: Double?
    var estimatedSNRDB: Double?
    var sweepComplete: Bool = false
    var directArrivalSeconds: Double?
    var usableLowHz: Double?
    var usableHighHz: Double?
    var warnings: [String] = []
}

struct RoomCorrectionChannelMeasurement: Codable, Equatable, Sendable {
    var capturedAt: Date
    var rawCapture: [Float]
    var impulseResponse: [Float]
    var transferFunction: RoomCorrectionFrequencyResponse?
    var quality: RoomCorrectionMeasurementQuality
}

struct RoomCorrectionMeasurementPosition: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var included: Bool = true
    var weight: Double = 1
    var sampleRate: Double
    var left: RoomCorrectionChannelMeasurement
    var right: RoomCorrectionChannelMeasurement
}

struct RoomCorrectionAggregateResponse: Codable, Equatable, Sendable {
    var generatedAt: Date
    var includedPositionIDs: [UUID]
    var leftResponse: RoomCorrectionFrequencyResponse
    var rightResponse: RoomCorrectionFrequencyResponse
}

struct RoomCorrectionTargetPoint: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var gainDB: Double
}

struct RoomCorrectionTargetCurve: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var points: [RoomCorrectionTargetPoint]
}

struct RoomCorrectionDesignParameters: Codable, Equatable, Sendable {
    var correctionLowHz: Double
    var correctionHighHz: Double
    var smoothingOctaves: Double
    var maximumBoostDB: Double
    var maximumCutDB: Double
    var requestedTapCount: Int
}

struct RoomCorrectionDesignSourcePosition: Codable, Equatable, Sendable {
    var id: UUID
    var weight: Double
}

struct RoomCorrectionDesign: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date
    var sampleRate: Double
    var parameters: RoomCorrectionDesignParameters
    var target: RoomCorrectionTargetCurve? = nil
    var sourcePositions: [RoomCorrectionDesignSourcePosition]? = nil
    var effectiveCorrectionLowHz: Double? = nil
    var effectiveCorrectionHighHz: Double? = nil
    var filter: RoomCorrectionFilter
    var predictedLeftResponse: RoomCorrectionFrequencyResponse?
    var predictedRightResponse: RoomCorrectionFrequencyResponse?
    var recommendedHeadroomDB: Double
    var algorithmVersion: String
}

struct RoomCorrectionProject: Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var playbackSystemID: UUID
    var name: String
    var createdAt: Date
    var modifiedAt: Date
    var microphone: RoomCorrectionMicrophone?
    var sweep: RoomCorrectionSweepSettings?
    var measurements: [RoomCorrectionMeasurementPosition] = []
    var aggregate: RoomCorrectionAggregateResponse?
    var target: RoomCorrectionTargetCurve?
    var designs: [RoomCorrectionDesign] = []
    var selectedDesignID: UUID?

    init(
        id: UUID = UUID(),
        playbackSystemID: UUID,
        name: String,
        createdAt: Date = Date(),
        modifiedAt: Date = Date()
    ) {
        self.id = id
        self.playbackSystemID = playbackSystemID
        self.name = name
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    func validateForPersistence() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw RoomCorrectionProjectError.unsupportedVersion(schemaVersion)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RoomCorrectionProjectError.invalidProject("Project name is empty.")
        }
        guard Set(measurements.map(\.id)).count == measurements.count else {
            throw RoomCorrectionProjectError.invalidProject("Measurement position identifiers must be unique.")
        }
        guard Set(designs.map(\.id)).count == designs.count else {
            throw RoomCorrectionProjectError.invalidProject("Design identifiers must be unique.")
        }
        if let selectedDesignID, !designs.contains(where: { $0.id == selectedDesignID }) {
            throw RoomCorrectionProjectError.invalidProject("Selected design does not exist in this project.")
        }
        if let microphone { try Self.validateMicrophone(microphone) }
        if let sweep { try Self.validateSweep(sweep) }
        for measurement in measurements { try Self.validateMeasurementPosition(measurement) }
        if let aggregate {
            guard Set(aggregate.includedPositionIDs).count == aggregate.includedPositionIDs.count,
                  aggregate.includedPositionIDs.allSatisfy({ id in measurements.contains(where: { $0.id == id }) }) else {
                throw RoomCorrectionProjectError.invalidProject("Aggregate response references invalid measurement positions.")
            }
            try Self.validateResponse(aggregate.leftResponse)
            try Self.validateResponse(aggregate.rightResponse)
        }
        if let target { try Self.validateTarget(target) }
        for design in designs { try Self.validateDesign(design) }
    }

    private static func validateMicrophone(_ microphone: RoomCorrectionMicrophone) throws {
        guard !microphone.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              microphone.inputChannelIndex >= 0 else {
            throw RoomCorrectionProjectError.invalidProject("Microphone identity or selected input channel is invalid.")
        }
        guard let calibration = microphone.calibration else { return }
        guard calibration.schemaVersion == RoomCorrectionMicrophoneCalibration.currentSchemaVersion else {
            throw RoomCorrectionProjectError.unsupportedVersion(calibration.schemaVersion)
        }
        var previous = 0.0
        for point in calibration.points {
            guard point.frequencyHz.isFinite, point.frequencyHz > previous, point.gainDB.isFinite else {
                throw RoomCorrectionProjectError.invalidProject(
                    "Microphone calibration points must be finite and strictly increasing in frequency."
                )
            }
            previous = point.frequencyHz
        }
    }

    private static func validateSweep(_ sweep: RoomCorrectionSweepSettings) throws {
        guard sweep.schemaVersion == RoomCorrectionSweepSettings.currentSchemaVersion else {
            throw RoomCorrectionProjectError.unsupportedVersion(sweep.schemaVersion)
        }
        guard sweep.sampleRate.isFinite, sweep.sampleRate > 0,
              sweep.startFrequencyHz.isFinite, sweep.startFrequencyHz > 0,
              sweep.endFrequencyHz.isFinite, sweep.endFrequencyHz > sweep.startFrequencyHz,
              sweep.endFrequencyHz < sweep.sampleRate * 0.5,
              sweep.durationSeconds.isFinite, sweep.durationSeconds > 0,
              sweep.levelDBFS.isFinite, sweep.levelDBFS <= 0,
              sweep.leadInSeconds.isFinite, sweep.leadInSeconds >= 0,
              sweep.tailSeconds.isFinite, sweep.tailSeconds >= 0,
              sweep.fadeSeconds.isFinite, sweep.fadeSeconds >= 0 else {
            throw RoomCorrectionProjectError.invalidProject("Sweep settings are invalid for their sample rate.")
        }
    }

    private static func validateMeasurementPosition(_ measurement: RoomCorrectionMeasurementPosition) throws {
        guard !measurement.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              measurement.sampleRate.isFinite, measurement.sampleRate > 0,
              measurement.weight.isFinite, measurement.weight >= 0 else {
            throw RoomCorrectionProjectError.invalidProject("Measurement position metadata is invalid.")
        }
        try validateChannelMeasurement(measurement.left)
        try validateChannelMeasurement(measurement.right)
    }

    private static func validateChannelMeasurement(_ measurement: RoomCorrectionChannelMeasurement) throws {
        guard measurement.rawCapture.allSatisfy(\.isFinite),
              measurement.impulseResponse.allSatisfy(\.isFinite) else {
            throw RoomCorrectionProjectError.invalidProject("Measurement data is invalid or non-finite.")
        }
        if let response = measurement.transferFunction { try validateResponse(response) }
        let metrics: [Double?] = [
            measurement.quality.playbackPeakDBFS,
            measurement.quality.capturePeakDBFS,
            measurement.quality.estimatedNoiseFloorDBFS,
            measurement.quality.estimatedSNRDB,
            measurement.quality.directArrivalSeconds,
            measurement.quality.usableLowHz,
            measurement.quality.usableHighHz,
        ]
        guard metrics.compactMap({ $0 }).allSatisfy(\.isFinite) else {
            throw RoomCorrectionProjectError.invalidProject("Measurement quality metrics must be finite.")
        }
    }

    private static func validateResponse(_ response: RoomCorrectionFrequencyResponse) throws {
        guard response.frequenciesHz.count == response.magnitudeDB.count,
              response.phaseRadians == nil || response.phaseRadians?.count == response.frequenciesHz.count else {
            throw RoomCorrectionProjectError.invalidProject("Frequency-response arrays have mismatched lengths.")
        }
        var previous = 0.0
        for index in response.frequenciesHz.indices {
            let frequency = response.frequenciesHz[index]
            guard frequency.isFinite, frequency > previous, response.magnitudeDB[index].isFinite else {
                throw RoomCorrectionProjectError.invalidProject(
                    "Frequency-response data must be finite and strictly increasing in frequency."
                )
            }
            if let phase = response.phaseRadians, !phase[index].isFinite {
                throw RoomCorrectionProjectError.invalidProject("Frequency-response phase must be finite.")
            }
            previous = frequency
        }
    }

    private static func validateTarget(_ target: RoomCorrectionTargetCurve) throws {
        guard !target.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              target.points.count >= 2 else {
            throw RoomCorrectionProjectError.invalidProject("Target curve must have a name and at least two points.")
        }
        var previous = 0.0
        for point in target.points {
            guard point.frequencyHz.isFinite, point.frequencyHz > previous, point.gainDB.isFinite else {
                throw RoomCorrectionProjectError.invalidProject(
                    "Target points must be finite and strictly increasing in frequency."
                )
            }
            previous = point.frequencyHz
        }
    }

    private static func validateDesign(_ design: RoomCorrectionDesign) throws {
        let parameters = design.parameters
        guard design.sampleRate.isFinite, design.sampleRate > 0,
              parameters.correctionLowHz.isFinite, parameters.correctionLowHz > 0,
              parameters.correctionHighHz.isFinite,
              parameters.correctionHighHz > parameters.correctionLowHz,
              parameters.correctionHighHz < design.sampleRate * 0.5,
              parameters.smoothingOctaves.isFinite, parameters.smoothingOctaves >= 0,
              parameters.maximumBoostDB.isFinite, parameters.maximumBoostDB >= 0,
              parameters.maximumCutDB.isFinite, parameters.maximumCutDB >= 0,
              parameters.requestedTapCount > 0,
              parameters.requestedTapCount <= Int(N60_CONVOLUTION_MAX_TAPS),
              design.recommendedHeadroomDB.isFinite, design.recommendedHeadroomDB >= 0,
              !design.algorithmVersion.isEmpty else {
            throw RoomCorrectionProjectError.invalidProject("Correction design metadata is invalid.")
        }
        if let target = design.target { try validateTarget(target) }
        if let sourcePositions = design.sourcePositions {
            guard !sourcePositions.isEmpty,
                  Set(sourcePositions.map(\.id)).count == sourcePositions.count,
                  sourcePositions.allSatisfy({ $0.weight.isFinite && $0.weight > 0 }) else {
                throw RoomCorrectionProjectError.invalidProject("Correction design source positions are invalid.")
            }
        }
        switch (design.effectiveCorrectionLowHz, design.effectiveCorrectionHighHz) {
        case (nil, nil):
            break
        case let (low?, high?) where low.isFinite && high.isFinite && low > 0 && high > low:
            break
        default:
            throw RoomCorrectionProjectError.invalidProject("Correction design effective range is invalid.")
        }
        let filter = design.filter
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS),
              filter.leftTaps.allSatisfy(\.isFinite),
              filter.rightTaps?.allSatisfy(\.isFinite) ?? true,
              filter.rightTaps == nil || filter.rightTaps?.count == tapCount,
              filter.declaredLatencyFrames < UInt32(tapCount),
              filter.sampleRate == nil
                || abs((filter.sampleRate ?? design.sampleRate) - design.sampleRate) < 0.5 else {
            throw RoomCorrectionProjectError.invalidProject("Generated correction filter metadata is invalid.")
        }
        if let response = design.predictedLeftResponse { try validateResponse(response) }
        if let response = design.predictedRightResponse { try validateResponse(response) }
    }
}

enum RoomCorrectionProjectError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case projectNotFound(UUID)
    case corruptProject(UUID)
    case identityMismatch(expected: UUID, decoded: UUID)
    case invalidProject(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Room-correction project uses unsupported schema version \(version)."
        case .projectNotFound(let id):
            return "Room-correction project \(id.uuidString) was not found."
        case .corruptProject(let id):
            return "Room-correction project \(id.uuidString) is unreadable or corrupt. The stored file was left unchanged."
        case .identityMismatch(let expected, let decoded):
            return "Room-correction project identity mismatch: expected \(expected.uuidString), found \(decoded.uuidString)."
        case .invalidProject(let message):
            return message
        }
    }
}

struct RoomCorrectionProjectStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
    }

    func projectDirectory(for id: UUID) -> URL {
        rootDirectory.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    func projectURL(for id: UUID) -> URL {
        projectDirectory(for: id).appendingPathComponent("project-v2.json", isDirectory: false)
    }

    @discardableResult
    func save(_ project: RoomCorrectionProject) throws -> URL {
        try project.validateForPersistence()
        let directory = projectDirectory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(project)
        let url = projectURL(for: project.id)
        try data.write(to: url, options: .atomic)
        return url
    }

    func load(_ id: UUID) throws -> RoomCorrectionProject {
        let url = projectURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw RoomCorrectionProjectError.projectNotFound(id)
        }
        let data = try Data(contentsOf: url)
        let project: RoomCorrectionProject
        do {
            project = try JSONDecoder().decode(RoomCorrectionProject.self, from: data)
        } catch {
            throw RoomCorrectionProjectError.corruptProject(id)
        }
        guard project.id == id else {
            throw RoomCorrectionProjectError.identityMismatch(expected: id, decoded: project.id)
        }
        try project.validateForPersistence()
        return project
    }

    func delete(_ id: UUID) throws {
        let directory = projectDirectory(for: id)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func existingProjectIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: rootDirectory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return urls
            .compactMap { UUID(uuidString: $0.lastPathComponent) }
            .sorted { $0.uuidString < $1.uuidString }
    }

    private static func defaultRootDirectory() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent("Room Correction", isDirectory: true)
    }
}
