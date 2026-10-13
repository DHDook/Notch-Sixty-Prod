import Combine
import CryptoKit
import Foundation

struct ProductBackupPreferences: Codable, Equatable, Sendable {
    static let appearanceKey = "application.appearance"
    static let presenceKey = "application.presence"
    static let volumeStepResolutionKey = "application.volumeStepResolution"

    var appearanceRawValue: String?
    var presenceRawValue: String?
    var volumeStepResolution: Int?

    static func capture(from defaults: UserDefaults) -> Self {
        Self(
            appearanceRawValue: defaults.string(forKey: appearanceKey),
            presenceRawValue: defaults.string(forKey: presenceKey),
            volumeStepResolution: defaults.object(
                forKey: volumeStepResolutionKey
            ) as? Int
        )
    }

    func apply(to defaults: UserDefaults) {
        if let appearanceRawValue {
            defaults.set(
                appearanceRawValue,
                forKey: Self.appearanceKey
            )
        } else {
            defaults.removeObject(forKey: Self.appearanceKey)
        }

        if let presenceRawValue {
            defaults.set(
                presenceRawValue,
                forKey: Self.presenceKey
            )
        } else {
            defaults.removeObject(forKey: Self.presenceKey)
        }

        if let volumeStepResolution {
            defaults.set(
                volumeStepResolution,
                forKey: Self.volumeStepResolutionKey
            )
        } else {
            defaults.removeObject(
                forKey: Self.volumeStepResolutionKey
            )
        }
    }
}

struct ProductBackupPayload: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var profiles: ProductProfileBackupSnapshot
    var roomCorrectionProjects: [RoomCorrectionProject]
    var measurementLabSessions: [SpeakerMeasurementLabSession]
    var hardwareAcceptanceReferenceEvidence:
        [HardwareAcceptanceCampaign]
    var preferences: ProductBackupPreferences

    init(
        schemaVersion: Int = ProductBackupPayload.currentSchemaVersion,
        profiles: ProductProfileBackupSnapshot,
        roomCorrectionProjects: [RoomCorrectionProject],
        measurementLabSessions: [SpeakerMeasurementLabSession],
        hardwareAcceptanceReferenceEvidence:
            [HardwareAcceptanceCampaign],
        preferences: ProductBackupPreferences
    ) {
        self.schemaVersion = schemaVersion
        self.profiles = profiles
        self.roomCorrectionProjects = roomCorrectionProjects
        self.measurementLabSessions = measurementLabSessions
        self.hardwareAcceptanceReferenceEvidence =
            hardwareAcceptanceReferenceEvidence
        self.preferences = preferences
    }
}

struct ProductBackupManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var productName: String
    var createdAt: Date
    var payloadSHA256: String
    var contentPresetCount: Int
    var playbackSystemCount: Int
    var roomCorrectionProjectCount: Int
    var measurementLabSessionCount: Int
    var hardwareAcceptanceReferenceEvidenceCount: Int
    var hardwareAcceptanceReferenceOnly: Bool

    init(
        schemaVersion: Int = ProductBackupManifest.currentSchemaVersion,
        productName: String = "Notch Sixty",
        createdAt: Date,
        payloadSHA256: String,
        contentPresetCount: Int,
        playbackSystemCount: Int,
        roomCorrectionProjectCount: Int,
        measurementLabSessionCount: Int,
        hardwareAcceptanceReferenceEvidenceCount: Int,
        hardwareAcceptanceReferenceOnly: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.productName = productName
        self.createdAt = createdAt
        self.payloadSHA256 = payloadSHA256
        self.contentPresetCount = contentPresetCount
        self.playbackSystemCount = playbackSystemCount
        self.roomCorrectionProjectCount = roomCorrectionProjectCount
        self.measurementLabSessionCount = measurementLabSessionCount
        self.hardwareAcceptanceReferenceEvidenceCount =
            hardwareAcceptanceReferenceEvidenceCount
        self.hardwareAcceptanceReferenceOnly =
            hardwareAcceptanceReferenceOnly
    }
}

struct ProductBackupEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var manifest: ProductBackupManifest
    var payload: ProductBackupPayload

    init(
        schemaVersion: Int = ProductBackupEnvelope.currentSchemaVersion,
        manifest: ProductBackupManifest,
        payload: ProductBackupPayload
    ) {
        self.schemaVersion = schemaVersion
        self.manifest = manifest
        self.payload = payload
    }
}

struct ProductBackupInspection: Equatable, Sendable {
    var manifest: ProductBackupManifest
    var profileCount: Int
    var roomCorrectionProjectCount: Int
    var measurementLabSessionCount: Int
    var hardwareAcceptanceReferenceEvidenceCount: Int
}

struct ProductBackupRestoreReport: Equatable, Sendable {
    var contentPresetCount: Int
    var playbackSystemCount: Int
    var roomCorrectionProjectCount: Int
    var measurementLabSessionCount: Int
    var playbackSystemsNeedingHardwareMapping:
        [PlaybackSystemHardwareMappingRequirement]
    var preservedHardwareAcceptanceReferenceEvidenceCount: Int

    var summary: String {
        var parts = [
            "\(contentPresetCount) presets",
            "\(playbackSystemCount) playback systems",
            "\(roomCorrectionProjectCount) room projects",
            "\(measurementLabSessionCount) lab sessions",
        ]
        if !playbackSystemsNeedingHardwareMapping.isEmpty {
            parts.append(
                "\(playbackSystemsNeedingHardwareMapping.count) systems need hardware mapping"
            )
        }
        if preservedHardwareAcceptanceReferenceEvidenceCount > 0 {
            parts.append(
                "\(preservedHardwareAcceptanceReferenceEvidenceCount) acceptance records preserved as reference-only evidence"
            )
        }
        return parts.joined(separator: " · ")
    }
}

enum ProductBackupError: Error, LocalizedError, Equatable {
    case unsupportedEnvelopeVersion(Int)
    case unsupportedManifestVersion(Int)
    case unsupportedPayloadVersion(Int)
    case checksumMismatch
    case restoreRequiresIdle(AudioLifecycleState)
    case invalidContentPreset
    case invalidPlaybackSystem
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedEnvelopeVersion(let version):
            return "Backup envelope schema \(version) is not supported."
        case .unsupportedManifestVersion(let version):
            return "Backup manifest schema \(version) is not supported."
        case .unsupportedPayloadVersion(let version):
            return "Backup payload schema \(version) is not supported."
        case .checksumMismatch:
            return "The backup payload checksum does not match the manifest. The file may be incomplete or modified."
        case .restoreRequiresIdle(let state):
            return "Stop audio processing before restoring a backup. Current state: \(state)."
        case .invalidContentPreset:
            return "The backup contains an unsupported or invalid Content Preset."
        case .invalidPlaybackSystem:
            return "The backup contains an unsupported or invalid Playback System."
        case .rollbackFailed:
            return "Backup restore failed and the previous local state could not be completely restored."
        }
    }
}

extension SpeakerMeasurementLabSessionStore {
    func existingSessionIDs() throws -> [UUID] {
        guard FileManager.default.fileExists(
            atPath: rootDirectory.path
        ) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension.lowercased() == "json" else {
                return nil
            }
            return UUID(
                uuidString:
                    url.deletingPathExtension().lastPathComponent
            )
        }.sorted { $0.uuidString < $1.uuidString }
    }

    func delete(_ sessionID: UUID) throws {
        let path = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return
        }
        try FileManager.default.removeItem(at: path)
    }
}

@MainActor
final class ProductBackupController: ObservableObject {
    let profiles: ProductProfileController
    let roomCorrectionStore: RoomCorrectionProjectStore
    let measurementLabStore: SpeakerMeasurementLabSessionStore
    let hardwareAcceptanceStore: HardwareAcceptanceCampaignStore

    private let defaults: UserDefaults

    @Published private(set) var lastRestoreReport:
        ProductBackupRestoreReport?
    @Published private(set) var lastErrorDescription: String?

    init(
        profiles: ProductProfileController,
        roomCorrectionStore: RoomCorrectionProjectStore =
            RoomCorrectionProjectStore(),
        measurementLabStore: SpeakerMeasurementLabSessionStore =
            SpeakerMeasurementLabSessionStore(),
        hardwareAcceptanceStore: HardwareAcceptanceCampaignStore =
            HardwareAcceptanceCampaignStore(),
        defaults: UserDefaults = .standard
    ) {
        self.profiles = profiles
        self.roomCorrectionStore = roomCorrectionStore
        self.measurementLabStore = measurementLabStore
        self.hardwareAcceptanceStore = hardwareAcceptanceStore
        self.defaults = defaults
    }

    func exportData(now: Date = Date()) throws -> Data {
        let roomProjects = try roomCorrectionStore
            .existingProjectIDs()
            .map { try roomCorrectionStore.load($0) }

        let labSessions = try measurementLabStore
            .existingSessionIDs()
            .compactMap { try measurementLabStore.load($0) }

        let acceptance = try hardwareAcceptanceStore
            .existingCampaignIDs()
            .compactMap { try hardwareAcceptanceStore.load($0) }

        let payload = ProductBackupPayload(
            profiles: profiles.makeBackupSnapshot(),
            roomCorrectionProjects: roomProjects,
            measurementLabSessions: labSessions,
            hardwareAcceptanceReferenceEvidence: acceptance,
            preferences: ProductBackupPreferences.capture(
                from: defaults
            )
        )

        try validate(payload)

        let payloadData = try Self.encode(
            payload,
            prettyPrinted: false
        )
        let manifest = ProductBackupManifest(
            createdAt: now,
            payloadSHA256: Self.sha256Hex(payloadData),
            contentPresetCount:
                payload.profiles.contentPresets.count,
            playbackSystemCount:
                payload.profiles.systemProfiles.count,
            roomCorrectionProjectCount:
                payload.roomCorrectionProjects.count,
            measurementLabSessionCount:
                payload.measurementLabSessions.count,
            hardwareAcceptanceReferenceEvidenceCount:
                payload.hardwareAcceptanceReferenceEvidence.count
        )

        let envelope = ProductBackupEnvelope(
            manifest: manifest,
            payload: payload
        )
        lastErrorDescription = nil
        return try Self.encode(envelope, prettyPrinted: true)
    }

    func inspect(data: Data) throws -> ProductBackupInspection {
        let envelope = try decodeAndValidate(data)
        return ProductBackupInspection(
            manifest: envelope.manifest,
            profileCount:
                envelope.payload.profiles.systemProfiles.count,
            roomCorrectionProjectCount:
                envelope.payload.roomCorrectionProjects.count,
            measurementLabSessionCount:
                envelope.payload.measurementLabSessions.count,
            hardwareAcceptanceReferenceEvidenceCount:
                envelope.payload
                    .hardwareAcceptanceReferenceEvidence.count
        )
    }

    @discardableResult
    func restore(
        data: Data,
        now: Date = Date()
    ) throws -> ProductBackupRestoreReport {
        guard profiles.engine.lifecycleState == .idle else {
            throw ProductBackupError.restoreRequiresIdle(
                profiles.engine.lifecycleState
            )
        }

        let envelope = try decodeAndValidate(data)
        let payload = envelope.payload

        let previousProfiles = profiles.makeBackupSnapshot()
        let previousPreferences =
            ProductBackupPreferences.capture(from: defaults)

        var originalProjects: [UUID: RoomCorrectionProject] = [:]
        var newProjectIDs = Set<UUID>()
        for project in payload.roomCorrectionProjects {
            if let existing = try? roomCorrectionStore.load(project.id) {
                originalProjects[project.id] = existing
            } else {
                newProjectIDs.insert(project.id)
            }
        }

        var originalLabSessions:
            [UUID: SpeakerMeasurementLabSession] = [:]
        var newLabSessionIDs = Set<UUID>()
        for session in payload.measurementLabSessions {
            if let existing = try measurementLabStore.load(session.id) {
                originalLabSessions[session.id] = existing
            } else {
                newLabSessionIDs.insert(session.id)
            }
        }

        do {
            let availableUIDs =
                Set(profiles.engine.outputDevices.map(\.uid))
            let mappingRequirements =
                try profiles.restoreBackupSnapshot(
                    payload.profiles,
                    availableOutputUIDs: availableUIDs,
                    recomputeHardwareRequirements: true,
                    now: now
                )

            for project in payload.roomCorrectionProjects {
                _ = try roomCorrectionStore.save(project)
            }
            for session in payload.measurementLabSessions {
                try measurementLabStore.save(session)
            }

            payload.preferences.apply(to: defaults)

            let report = ProductBackupRestoreReport(
                contentPresetCount:
                    payload.profiles.contentPresets.count,
                playbackSystemCount:
                    payload.profiles.systemProfiles.count,
                roomCorrectionProjectCount:
                    payload.roomCorrectionProjects.count,
                measurementLabSessionCount:
                    payload.measurementLabSessions.count,
                playbackSystemsNeedingHardwareMapping:
                    mappingRequirements,
                preservedHardwareAcceptanceReferenceEvidenceCount:
                    payload.hardwareAcceptanceReferenceEvidence.count
            )
            lastRestoreReport = report
            lastErrorDescription = nil
            return report
        } catch {
            var rollbackOK = true

            do {
                _ = try profiles.restoreBackupSnapshot(
                    previousProfiles,
                    availableOutputUIDs:
                        Set(profiles.engine.outputDevices.map(\.uid)),
                    recomputeHardwareRequirements: false
                )
            } catch {
                rollbackOK = false
            }

            for id in newProjectIDs {
                do {
                    try roomCorrectionStore.delete(id)
                } catch {
                    rollbackOK = false
                }
            }
            for project in originalProjects.values {
                do {
                    _ = try roomCorrectionStore.save(project)
                } catch {
                    rollbackOK = false
                }
            }

            for id in newLabSessionIDs {
                do {
                    try measurementLabStore.delete(id)
                } catch {
                    rollbackOK = false
                }
            }
            for session in originalLabSessions.values {
                do {
                    try measurementLabStore.save(session)
                } catch {
                    rollbackOK = false
                }
            }

            previousPreferences.apply(to: defaults)
            lastRestoreReport = nil

            if rollbackOK {
                lastErrorDescription = error.localizedDescription
                throw error
            }
            lastErrorDescription =
                ProductBackupError.rollbackFailed.localizedDescription
            throw ProductBackupError.rollbackFailed
        }
    }

    func clearError() {
        lastErrorDescription = nil
    }

    private func decodeAndValidate(
        _ data: Data
    ) throws -> ProductBackupEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let envelope = try decoder.decode(
            ProductBackupEnvelope.self,
            from: data
        )

        guard envelope.schemaVersion
                == ProductBackupEnvelope.currentSchemaVersion else {
            throw ProductBackupError.unsupportedEnvelopeVersion(
                envelope.schemaVersion
            )
        }
        guard envelope.manifest.schemaVersion
                == ProductBackupManifest.currentSchemaVersion else {
            throw ProductBackupError.unsupportedManifestVersion(
                envelope.manifest.schemaVersion
            )
        }
        guard envelope.payload.schemaVersion
                == ProductBackupPayload.currentSchemaVersion else {
            throw ProductBackupError.unsupportedPayloadVersion(
                envelope.payload.schemaVersion
            )
        }

        let canonical = try Self.encode(
            envelope.payload,
            prettyPrinted: false
        )
        guard Self.sha256Hex(canonical)
                == envelope.manifest.payloadSHA256 else {
            throw ProductBackupError.checksumMismatch
        }

        try validate(envelope.payload)
        return envelope
    }

    private func validate(
        _ payload: ProductBackupPayload
    ) throws {
        guard payload.profiles.schemaVersion
                == ProductProfileBackupSnapshot.currentSchemaVersion else {
            throw ProductBackupError.unsupportedPayloadVersion(
                payload.profiles.schemaVersion
            )
        }
        guard payload.profiles.contentPresets.allSatisfy({
            $0.schemaVersion == ContentPreset.currentSchemaVersion
                && $0.state.schemaVersion
                    == ContentPresetState.currentSchemaVersion
        }) else {
            throw ProductBackupError.invalidContentPreset
        }
        guard payload.profiles.systemProfiles.allSatisfy({
            $0.schemaVersion == PlaybackSystemProfile.currentSchemaVersion
                && $0.state.schemaVersion
                    == PlaybackSystemState.currentSchemaVersion
        }) else {
            throw ProductBackupError.invalidPlaybackSystem
        }

        for project in payload.roomCorrectionProjects {
            try project.validateForPersistence()
        }
        for session in payload.measurementLabSessions {
            try session.validateStructure()
        }
        for campaign in
            payload.hardwareAcceptanceReferenceEvidence {
            _ = try campaign.validated()
        }
    }

    private static func encode<T: Encodable>(
        _ value: T,
        prettyPrinted: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys]
            : [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
