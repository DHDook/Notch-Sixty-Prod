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
    var speakerIR: SpeakerIRConfiguration

    init(
        schemaVersion: Int = PlaybackSystemState.currentSchemaVersion,
        associatedOutputUID: String? = nil,
        outputGainDB: Double = 0,
        playback: PlaybackSystemControlState = PlaybackSystemControlState(),
        bassManagement: BassManagementConfiguration = BassManagementConfiguration(),
        roomCorrection: RoomCorrectionConfiguration = RoomCorrectionConfiguration(),
        speakerIR: SpeakerIRConfiguration = SpeakerIRConfiguration()
    ) {
        self.schemaVersion = schemaVersion
        self.associatedOutputUID = associatedOutputUID
        self.outputGainDB = outputGainDB
        self.playback = playback
        self.bassManagement = bassManagement
        self.roomCorrection = roomCorrection
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

    var errorDescription: String? {
        switch self {
        case .outputChangeRequiresIdle(let profile):
            return "Stop processing before selecting \(profile); it is associated with a different output device."
        case .persistenceVersion(let version):
            return "Saved profile data uses unsupported schema version \(version)."
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

    private static let factoryContentPresets: [ContentPreset] = [
        ContentPreset(
            id: referencePresetID,
            name: "Reference",
            origin: .factory,
            state: ContentPresetState()
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
            }
            selectedContentPresetID = archive.selectedContentPresetID
            selectedSystemProfileID = archive.selectedSystemProfileID
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    private func persist() {
        do {
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
        } catch {
            lastErrorDescription = error.localizedDescription
        }
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
