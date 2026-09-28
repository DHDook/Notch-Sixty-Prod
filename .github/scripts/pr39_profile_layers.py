from pathlib import Path
import re


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    if old not in text:
        raise SystemExit(f"expected snippet not found in {path}: {old[:120]!r}")
    p.write_text(text.replace(old, new, 1))


def add_codable(path: str, names: list[str]) -> None:
    p = Path(path)
    text = p.read_text()
    for name in names:
        pattern = re.compile(rf"((?:enum|struct)\s+{re.escape(name)}\s*:\s*[^\n{{]*?)Sendable(\s*{{)")
        match = pattern.search(text)
        if not match:
            raise SystemExit(f"Codable declaration target {name} not found in {path}")
        if "Codable" in match.group(0):
            continue
        text = text[:match.start()] + match.group(1) + "Codable, Sendable" + match.group(2) + text[match.end():]
    p.write_text(text)


add_codable(
    "NotchSixty/Audio/AudioIOEngine.swift",
    [
        "EQFilterType",
        "EQFilterSlope",
        "EQPhaseMode",
        "EQBandDynamicConfiguration",
        "EQFIRKernel",
        "EQBand",
        "DSPGainConfiguration",
        "CrossoverTopology",
        "CrossoverMonitorMode",
        "BassManagementConfiguration",
        "RoomCorrectionFilter",
        "RoomCorrectionConfiguration",
        "SpeakerIRFilter",
        "SpeakerIRConfiguration",
    ],
)
add_codable(
    "NotchSixty/Audio/StereoPlaybackControl.swift",
    ["EQChannelMode", "EQEditChannel", "StereoEQConfiguration"],
)

dynamics_path = Path("NotchSixty/Audio/DynamicsConfiguration.swift")
dynamics = dynamics_path.read_text()
dynamics = re.sub(
    r"((?:enum|struct)\s+\w+\s*:\s*[^\n{{]*?)(?<!Codable, )Sendable(\s*{{)",
    r"\1Codable, Sendable\2",
    dynamics,
)
dynamics_path.write_text(dynamics)

replace_once(
    "NotchSixty/Audio/AudioIOEngine.swift",
    "    func setInputPreampDB(_ value: Double) throws {\n",
    "    func replaceGainConfiguration(_ configuration: DSPGainConfiguration) throws {\n"
    "        try applyGainConfiguration(configuration)\n"
    "    }\n\n"
    "    func setInputPreampDB(_ value: Double) throws {\n",
)
replace_once(
    "NotchSixty/Audio/AudioIOEngine.swift",
    "    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {\n",
    "    func replacePlaybackControlConfiguration(_ configuration: PlaybackControlConfiguration) throws {\n"
    "        try applyPlaybackControlConfiguration(configuration)\n"
    "    }\n\n"
    "    func setCrosstalkCancellationEnabled(_ enabled: Bool) throws {\n",
)

profiles = '''import Combine
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
            return "Stop processing before selecting \\(profile); it is associated with a different output device."
        case .persistenceVersion(let version):
            return "Saved profile data uses unsupported schema version \\(version)."
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
        return ContentPresetState(
            stereoEQ: eq,
            inputPreampDB: gain.inputPreampDB,
            headroomAttenuationDB: gain.headroomAttenuationDB,
            dynamics: engine.dynamicsConfiguration
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
        while existing.contains("\\(base) \\(suffix)".lowercased()) {
            suffix += 1
        }
        return "\\(base) \\(suffix)"
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
'''
Path("NotchSixty/State/ProductProfiles.swift").write_text(profiles)

toolbar = '''import SwiftUI

struct ProductionProfileToolbar: View {
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var engine: AudioIOEngine

    @State private var savePrompt: SavePrompt?
    @State private var draftName = ""

    private enum SavePrompt {
        case content
        case system

        var title: String {
            switch self {
            case .content: return "Save Content Preset"
            case .system: return "Save Playback System"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            contentPresetMenu

            Button {
                if profiles.canOverwriteSelectedContentPreset {
                    profiles.overwriteSelectedContentPreset()
                } else {
                    beginSave(
                        .content,
                        defaultName: profiles.selectedContentPresetName == "Custom"
                            ? "My Preset"
                            : profiles.selectedContentPresetName
                    )
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.glass)
            .help(
                profiles.canOverwriteSelectedContentPreset
                    ? "Update selected Content Preset"
                    : "Save current Content Preset"
            )

            systemMenu.controlSize(.small)

            if let error = profiles.lastErrorDescription {
                Button {
                    profiles.clearError()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(error)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .alert(
            savePrompt?.title ?? "Save",
            isPresented: Binding(
                get: { savePrompt != nil },
                set: { if !$0 { savePrompt = nil } }
            )
        ) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { savePrompt = nil }
            Button("Save") {
                let prompt = savePrompt
                savePrompt = nil
                switch prompt {
                case .content:
                    profiles.saveCurrentContentPreset(named: draftName)
                case .system:
                    profiles.saveCurrentSystemProfile(named: draftName)
                case .none:
                    break
                }
            }
        }
    }

    private var contentPresetMenu: some View {
        Menu {
            Section("Content Presets") {
                ForEach(profiles.contentPresets) { preset in
                    Button {
                        profiles.selectContentPreset(preset.id)
                    } label: {
                        HStack {
                            if profiles.selectedContentPresetID == preset.id {
                                Image(systemName: "checkmark")
                            }
                            Text(preset.name)
                            if preset.origin == .factory {
                                Text("Factory")
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Save Current as New Preset…") {
                beginSave(.content, defaultName: "My Preset")
            }
            if profiles.canOverwriteSelectedContentPreset {
                Button("Update \\(profiles.selectedContentPresetName)") {
                    profiles.overwriteSelectedContentPreset()
                }
                Button("Delete \\(profiles.selectedContentPresetName)", role: .destructive) {
                    profiles.deleteSelectedContentPreset()
                }
            }
        } label: {
            Label(
                "\\(profiles.selectedContentPresetName)\\(profiles.selectedContentPresetIsDirty ? " •" : "")",
                systemImage: "music.note.list"
            )
        }
        .buttonStyle(.glass)
        .help("Content Preset: EQ/voicing, phase mode, dynamics, and input/headroom gain")
    }

    private var systemMenu: some View {
        Menu {
            Section("Playback Systems") {
                ForEach(profiles.systemProfiles) { system in
                    Button {
                        profiles.selectSystemProfile(system.id)
                    } label: {
                        HStack {
                            if profiles.selectedSystemProfileID == system.id {
                                Image(systemName: "checkmark")
                            }
                            Text(system.name)
                        }
                    }
                }
            }

            Divider()
            Button("New System from Current…") {
                beginSave(.system, defaultName: "My System")
            }
            if profiles.selectedSystemProfile != nil {
                Button("Update \\(profiles.selectedSystemProfileName)") {
                    profiles.overwriteSelectedSystemProfile()
                }
                Button("Associate with Current Output") {
                    profiles.associateSelectedSystemWithCurrentOutput()
                }
                Button("Delete \\(profiles.selectedSystemProfileName)", role: .destructive) {
                    profiles.deleteSelectedSystemProfile()
                }
            }
        } label: {
            Label(
                "\\(profiles.selectedSystemProfileName)\\(profiles.selectedSystemProfileIsDirty ? " •" : "")",
                systemImage: profiles.selectedSystemOutputMatches
                    ? "hifispeaker.2"
                    : "hifispeaker.2.fill"
            )
        }
        .help(
            "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"
        )
    }

    private func beginSave(_ prompt: SavePrompt, defaultName: String) {
        draftName = defaultName
        savePrompt = prompt
    }
}
'''
Path("NotchSixty/UI/ProductionProfileToolbar.swift").write_text(toolbar)

replace_once(
    "NotchSixty/NotchSixtyApp.swift",
    '''    let audioEngine: AudioIOEngine
    private var audioEngineObservation: AnyCancellable?

    init() {
        self.audioEngine = AudioIOEngine()
        observeAudioEngine()
    }

    init(audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
        observeAudioEngine()
    }
''',
    '''    let audioEngine: AudioIOEngine
    let profiles: ProductProfileController
    private var audioEngineObservation: AnyCancellable?

    init() {
        let audioEngine = AudioIOEngine()
        self.audioEngine = audioEngine
        self.profiles = ProductProfileController(engine: audioEngine)
        observeAudioEngine()
    }

    init(audioEngine: AudioIOEngine) {
        self.audioEngine = audioEngine
        self.profiles = ProductProfileController(engine: audioEngine)
        observeAudioEngine()
    }
''',
)
replace_once(
    "NotchSixty/NotchSixtyApp.swift",
    '''    func prepareForUse() {
        audioEngine.prepareForUse()
    }
''',
    '''    func prepareForUse() {
        audioEngine.prepareForUse()
        profiles.restoreSelectedLayers()
    }
''',
)
replace_once(
    "NotchSixty/UI/ProductionRootView.swift",
    '''        ToolbarItemGroup(placement: .primaryAction) {
            if let output = engine.selectedOutputDevice {
''',
    '''        ToolbarItemGroup(placement: .primaryAction) {
            ProductionProfileToolbar(profiles: product.profiles, engine: engine)

            if let output = engine.selectedOutputDevice {
''',
)

pbx = Path("NotchSixty.xcodeproj/project.pbxproj")
project = pbx.read_text()
pairs = [
    (
        "\t\tA2000000000000000000001A /* ProductionAnalysisWorker.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000000000000000000002A /* ProductionAnalysisWorker.swift */; };\n",
        "\t\tA2000000000000000000001A /* ProductionAnalysisWorker.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000000000000000000002A /* ProductionAnalysisWorker.swift */; };\n"
        "\t\tA2000000000000000000001B /* ProductProfiles.swift in Sources */ = {isa = PBXBuildFile; fileRef = A2000000000000000000002B /* ProductProfiles.swift */; };\n",
    ),
    (
        "\t\tA40000000000000000000015 /* ProductionAnalysisViews.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000025 /* ProductionAnalysisViews.swift */; };\n",
        "\t\tA40000000000000000000015 /* ProductionAnalysisViews.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000025 /* ProductionAnalysisViews.swift */; };\n"
        "\t\tA40000000000000000000016 /* ProductionProfileToolbar.swift in Sources */ = {isa = PBXBuildFile; fileRef = A40000000000000000000026 /* ProductionProfileToolbar.swift */; };\n",
    ),
    (
        "\t\tA2000000000000000000002A /* ProductionAnalysisWorker.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionAnalysisWorker.swift; sourceTree = \"<group>\"; };\n",
        "\t\tA2000000000000000000002A /* ProductionAnalysisWorker.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionAnalysisWorker.swift; sourceTree = \"<group>\"; };\n"
        "\t\tA2000000000000000000002B /* ProductProfiles.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductProfiles.swift; sourceTree = \"<group>\"; };\n",
    ),
    (
        "\t\tA40000000000000000000025 /* ProductionAnalysisViews.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionAnalysisViews.swift; sourceTree = \"<group>\"; };\n",
        "\t\tA40000000000000000000025 /* ProductionAnalysisViews.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionAnalysisViews.swift; sourceTree = \"<group>\"; };\n"
        "\t\tA40000000000000000000026 /* ProductionProfileToolbar.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ProductionProfileToolbar.swift; sourceTree = \"<group>\"; };\n",
    ),
    (
        "A20000000000000000000054 /* State */ = {isa = PBXGroup; children = (A20000000000000000000025 /* AudioLifecycleState.swift */,); path = State; sourceTree = \"<group>\"; };",
        "A20000000000000000000054 /* State */ = {isa = PBXGroup; children = (A20000000000000000000025 /* AudioLifecycleState.swift */, A2000000000000000000002B /* ProductProfiles.swift */,); path = State; sourceTree = \"<group>\"; };",
    ),
    (
        "A40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */, A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */, A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */, A40000000000000000000024 /* ProductionMetersView.swift */, A40000000000000000000025 /* ProductionAnalysisViews.swift */,); path = UI; sourceTree = \"<group>\"; };",
        "A40000000000000000000050 /* UI */ = {isa = PBXGroup; children = (A40000000000000000000020 /* ProductionRootView.swift */, A40000000000000000000021 /* ProductionEqualizerView.swift */, A40000000000000000000022 /* ProductionDynamicsView.swift */, A40000000000000000000023 /* ProductionDynamicsTelemetryView.swift */, A40000000000000000000024 /* ProductionMetersView.swift */, A40000000000000000000025 /* ProductionAnalysisViews.swift */, A40000000000000000000026 /* ProductionProfileToolbar.swift */,); path = UI; sourceTree = \"<group>\"; };",
    ),
    (
        "\t\t\t\tA40000000000000000000015 /* ProductionAnalysisViews.swift in Sources */,\n",
        "\t\t\t\tA40000000000000000000015 /* ProductionAnalysisViews.swift in Sources */,\n"
        "\t\t\t\tA40000000000000000000016 /* ProductionProfileToolbar.swift in Sources */,\n",
    ),
    (
        "\t\t\t\tA2000000000000000000001A /* ProductionAnalysisWorker.swift in Sources */,\n",
        "\t\t\t\tA2000000000000000000001A /* ProductionAnalysisWorker.swift in Sources */,\n"
        "\t\t\t\tA2000000000000000000001B /* ProductProfiles.swift in Sources */,\n",
    ),
]
for old, new in pairs:
    if old not in project:
        raise SystemExit(f"project insertion anchor missing: {old[:100]!r}")
    project = project.replace(old, new, 1)
pbx.write_text(project)

validator = '''#!/usr/bin/env python3
from pathlib import Path
import sys

PROFILES = Path("NotchSixty/State/ProductProfiles.swift").read_text()
TOOLBAR = Path("NotchSixty/UI/ProductionProfileToolbar.swift").read_text()
APP = Path("NotchSixty/NotchSixtyApp.swift").read_text()
ROOT = Path("NotchSixty/UI/ProductionRootView.swift").read_text()


def require(text: str, needle: str, context: str) -> None:
    if needle not in text:
        print(f"PR39 profile layers: FAIL: missing {context}: {needle!r}", file=sys.stderr)
        raise SystemExit(1)


require(PROFILES, "struct ContentPresetState: Codable", "versioned Content Preset state")
for field in ["stereoEQ", "inputPreampDB", "headroomAttenuationDB", "dynamics"]:
    require(PROFILES, field, f"Content Preset field {field}")
require(PROFILES, "struct PlaybackSystemState: Codable", "versioned Playback System state")
for field in ["associatedOutputUID", "outputGainDB", "bassManagement", "roomCorrection", "speakerIR"]:
    require(PROFILES, field, f"Playback System field {field}")
require(PROFILES, "globalBypassed and auditionMode are session state", "session-state exclusion")
require(PROFILES, "result.outputGainDB = outputGainDB", "system-owned output trim")
require(PROFILES, "result.inputPreampDB = inputPreampDB", "content-owned input gain")
require(PROFILES, "profiles-v1.json", "versioned on-disk persistence")
require(PROFILES, "try data.write(to: storageURL, options: .atomic)", "atomic persistence")
require(TOOLBAR, "Content Presets", "production Content Preset selector")
require(TOOLBAR, "Playback Systems", "production Playback System selector")
require(TOOLBAR, "Associate with Current Output", "manual output association")
require(APP, "let profiles: ProductProfileController", "product-level profile ownership")
require(APP, "profiles.restoreSelectedLayers()", "saved layer restoration")
require(ROOT, "ProductionProfileToolbar(profiles: product.profiles", "production toolbar wiring")
print("PR39 profile layers: PASS")
'''
Path("ci/validate_pr39_profile_layers.py").write_text(validator)

macos = Path(".github/workflows/macos.yml")
macos_text = macos.read_text()
anchor = "      - name: Validate PR37 Production Equalizer\n"
if anchor not in macos_text:
    raise SystemExit("macOS validator insertion anchor not found")
macos.write_text(
    macos_text.replace(
        anchor,
        "      - name: Validate PR39 Content Preset / Playback System Layers\n"
        "        run: python3 ci/validate_pr39_profile_layers.py\n\n"
        + anchor,
        1,
    )
)

tests = Path("NotchSixtyTests/NotchSixtyTests.swift")
test_text = tests.read_text()
insertion = '''

    func testProductProfileModelsRoundTripAndPreserveLayerOwnership() throws {
        var eq = StereoEQConfiguration()
        eq.phaseMode = .mixedPhase
        eq.linkedBands = [
            EQBand(type: .peaking, frequencyHz: 1_800, gainDB: 1.2, q: 1.0)
        ]
        var dynamics = DynamicsConfiguration()
        dynamics.loudnessContour.enabled = true
        dynamics.loudnessContour.strength = 0.65

        let content = ContentPreset(
            name: "Round Trip",
            origin: .user,
            state: ContentPresetState(
                stereoEQ: eq,
                inputPreampDB: -2,
                headroomAttenuationDB: -1.5,
                dynamics: dynamics
            )
        )
        let contentData = try JSONEncoder().encode(content)
        XCTAssertEqual(try JSONDecoder().decode(ContentPreset.self, from: contentData), content)

        var baseGain = DSPGainConfiguration()
        baseGain.outputGainDB = 4
        let contentGain = content.state.composingGain(over: baseGain)
        XCTAssertEqual(contentGain.inputPreampDB, -2)
        XCTAssertEqual(contentGain.headroomAttenuationDB, -1.5)
        XCTAssertEqual(contentGain.outputGainDB, 4, "Content Presets must preserve System output trim")

        var playback = PlaybackControlConfiguration()
        playback.globalBypassed = true
        playback.auditionMode = .delta
        var systemPlayback = PlaybackSystemControlState(playback)
        systemPlayback.balance = 0.2
        systemPlayback.interChannelDelayMs = 0.75
        let appliedPlayback = systemPlayback.applying(to: playback)
        XCTAssertTrue(appliedPlayback.globalBypassed)
        XCTAssertEqual(appliedPlayback.auditionMode, .delta)
        XCTAssertEqual(appliedPlayback.balance, 0.2)
        XCTAssertEqual(appliedPlayback.interChannelDelayMs, 0.75)

        var bass = BassManagementConfiguration()
        bass.enabled = true
        bass.frequencyHz = 80
        let system = PlaybackSystemProfile(
            name: "Living Room",
            state: PlaybackSystemState(
                associatedOutputUID: "test-output",
                outputGainDB: 2.5,
                playback: systemPlayback,
                bassManagement: bass
            )
        )
        let systemData = try JSONEncoder().encode(system)
        XCTAssertEqual(
            try JSONDecoder().decode(PlaybackSystemProfile.self, from: systemData),
            system
        )

        var retainedContentGain = DSPGainConfiguration()
        retainedContentGain.inputPreampDB = -3
        retainedContentGain.headroomAttenuationDB = -2
        let systemGain = system.state.composingGain(over: retainedContentGain)
        XCTAssertEqual(systemGain.inputPreampDB, -3)
        XCTAssertEqual(systemGain.headroomAttenuationDB, -2)
        XCTAssertEqual(systemGain.outputGainDB, 2.5)
    }
'''
closing = test_text.rfind("\n}")
if closing < 0:
    raise SystemExit("test class closing brace not found")
tests.write_text(test_text[:closing] + insertion + test_text[closing:])

Path("docs/PR39_PROFILE_LAYERS.md").write_text(
    '''# PR39 Content Presets / Playback System Profiles

PR39 separates media-dependent voicing from physical playback-system calibration.

## Content Preset owns
- stereo EQ banks and phase mode
- dynamics and loudness/tonal processing
- input preamp and headroom attenuation

## Playback System owns
- optional output-device UID association
- output trim
- balance/symmetry, speaker crossfeed, crosstalk cancellation, and inter-channel alignment delay
- bass management/crossover, sub polarity, and sub phase alignment
- room-correction FIR and speaker-correction IR

## Session state stays outside both layers
- master volume and mute
- global DSP bypass
- Processed / Reference / Delta audition mode
- metering and UI state

Both models are versioned and persisted in an atomic JSON archive under Application Support. Factory Content Presets are code-owned and immutable; user Content Presets and Playback System Profiles are persisted. Applying one layer preserves the fields owned by the other layer. A System Profile may be associated with an output UID; selecting a differently-associated system requires processing to be stopped before the route is changed.
'''
)
