import CryptoKit
import Foundation

struct NotchSixtyBackupPreferences: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var appearance: String
    var presence: String
    var volumeStepResolution: Int
    // Optional for backward-compatible decoding of existing schema-1 backups.
    var showVolumeInMenuBar: Bool? = nil
    var showVolumePopup: Bool? = nil

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              ["system", "light", "dark"].contains(appearance),
              ["dock", "tray", "both"].contains(presence),
              [16, 32, 64].contains(volumeStepResolution) else {
            throw NotchSixtyBackupError.invalidPreferences
        }
    }
}

struct NotchSixtyBackupManifestEntry: Codable, Equatable, Sendable {
    var domain: String
    var sha256: String
    var byteCount: Int
}

struct NotchSixtyBackupManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var entries: [NotchSixtyBackupManifestEntry]
}

struct NotchSixtyBackupBundle: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var createdAt: Date
    var appVersion: String
    var appBuild: String
    var profiles: ProductProfileBackupSnapshot
    var roomCorrectionProjects: [RoomCorrectionProject]
    var measurementLabSessions: [SpeakerMeasurementLabSession]
    var binauralAssets: [BinauralProfileAsset]
    var preferences: NotchSixtyBackupPreferences
    var manifest: NotchSixtyBackupManifest
}

struct NotchSixtyBackupRestoreReport: Equatable, Sendable {
    var contentPresetCount: Int
    var playbackSystemCount: Int
    var roomCorrectionProjectCount: Int
    var measurementLabSessionCount: Int
    var binauralAssetCount: Int
    var hardwareMappingRequiredSystemIDs: [UUID]

    var hardwareMappingRequiredCount: Int {
        hardwareMappingRequiredSystemIDs.count
    }
}

enum NotchSixtyBackupError: Error, LocalizedError, Equatable {
    case unsupportedBundleVersion(Int)
    case unsupportedManifestVersion(Int)
    case integrityMismatch(String)
    case duplicateIdentity(String)
    case invalidPreferences
    case corruptBundle
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedBundleVersion(let version):
            return "This Notch Sixty backup uses unsupported bundle version \(version)."
        case .unsupportedManifestVersion(let version):
            return "This Notch Sixty backup uses unsupported manifest version \(version)."
        case .integrityMismatch(let domain):
            return "Backup integrity verification failed for \(domain). No data was restored."
        case .duplicateIdentity(let domain):
            return "The backup contains duplicate \(domain) identifiers."
        case .invalidPreferences:
            return "The backup contains invalid application preferences."
        case .corruptBundle:
            return "The selected file is not a valid Notch Sixty backup."
        case .rollbackFailed(let message):
            return "Backup restore failed and rollback was incomplete: \(message)"
        }
    }
}

/// Versioned, integrity-checked backup service. The service has no audio-start
/// authority. Profile restore is allowed only while the audio engine is idle.
/// ProductProfileController preserves imported stable hardware identities for
/// review but persists unavailable bindings behind a Needs Mapping gate, so a
/// backup can never silently claim a different physical device.
@MainActor
final class NotchSixtyBackupService {
    private let profiles: ProductProfileController
    private let roomStore: RoomCorrectionProjectStore
    private let labStore: SpeakerMeasurementLabSessionStore
    private let binauralStore: BinauralProfileAssetStore

    private enum RollbackValue<T> {
        case absent
        case present(T)
    }

    init(
        profiles: ProductProfileController,
        roomStore: RoomCorrectionProjectStore,
        labStore: SpeakerMeasurementLabSessionStore =
            SpeakerMeasurementLabSessionStore(),
        binauralStore: BinauralProfileAssetStore =
            BinauralProfileAssetStore()
    ) {
        self.profiles = profiles
        self.roomStore = roomStore
        self.labStore = labStore
        self.binauralStore = binauralStore
    }

    func exportData(
        preferences: NotchSixtyBackupPreferences,
        appVersion: String,
        appBuild: String,
        createdAt: Date = Date()
    ) throws -> Data {
        try preferences.validate()

        let profileSnapshot = profiles.makeBackupSnapshot()
        try profileSnapshot.validate()

        let projects = try roomStore.existingProjectIDs()
            .map { try roomStore.load($0) }
        let sessions = try labStore.existingSessionIDs()
            .compactMap { try labStore.load($0) }
        let assets = try binauralStore.existingAssetIDs()
            .map { try binauralStore.load(id: $0) }

        try validateUniqueIdentities(
            projects: projects,
            sessions: sessions,
            assets: assets
        )
        for project in projects { try project.validateForPersistence() }
        for session in sessions { try session.validateStructure() }
        for asset in assets { try asset.validate() }

        let manifest = try makeManifest(
            profiles: profileSnapshot,
            projects: projects,
            sessions: sessions,
            assets: assets,
            preferences: preferences
        )

        let bundle = NotchSixtyBackupBundle(
            createdAt: createdAt,
            appVersion: appVersion,
            appBuild: appBuild,
            profiles: profileSnapshot,
            roomCorrectionProjects: projects,
            measurementLabSessions: sessions,
            binauralAssets: assets,
            preferences: preferences,
            manifest: manifest
        )
        return try Self.encoder().encode(bundle)
    }

    func inspect(_ data: Data) throws -> NotchSixtyBackupBundle {
        let bundle: NotchSixtyBackupBundle
        do {
            bundle = try Self.decoder().decode(
                NotchSixtyBackupBundle.self,
                from: data
            )
        } catch {
            throw NotchSixtyBackupError.corruptBundle
        }
        try validate(bundle)
        return bundle
    }

    /// Restores the portable product state and historical evidence contained in
    /// the bundle. Existing Room Correction / Measurement Lab / binaural items
    /// not named by the backup are intentionally retained. Items with matching
    /// IDs are replaced transactionally.
    ///
    /// App preferences are returned to the caller only after product-data
    /// restore succeeds, allowing the UI-owned preference controller to apply
    /// them as the final no-fail step.
    func restore(
        _ data: Data
    ) throws -> (
        report: NotchSixtyBackupRestoreReport,
        preferences: NotchSixtyBackupPreferences
    ) {
        let bundle = try inspect(data)

        let priorProfiles = profiles.makeBackupSnapshot()
        let existingProjectIDs = Set(try roomStore.existingProjectIDs())
        let existingSessionIDs = Set(try labStore.existingSessionIDs())
        let existingAssetIDs = Set(try binauralStore.existingAssetIDs())

        let projectRollback = try rollbackMap(
            ids: bundle.roomCorrectionProjects.map(\.id),
            existingIDs: existingProjectIDs,
            loader: { try roomStore.load($0) }
        )
        let sessionRollback = try rollbackMap(
            ids: bundle.measurementLabSessions.map(\.id),
            existingIDs: existingSessionIDs,
            loader: {
                guard let session = try labStore.load($0) else {
                    throw NotchSixtyBackupError.corruptBundle
                }
                return session
            }
        )
        let assetRollback = try rollbackMap(
            ids: bundle.binauralAssets.map(\.id),
            existingIDs: existingAssetIDs,
            loader: { try binauralStore.load(id: $0) }
        )

        do {
            for project in bundle.roomCorrectionProjects {
                try roomStore.save(project)
            }
            for session in bundle.measurementLabSessions {
                try labStore.save(session)
            }
            for asset in bundle.binauralAssets {
                _ = try binauralStore.save(asset)
            }

            let profileReport =
                try profiles.restoreBackupSnapshot(bundle.profiles)

            return (
                NotchSixtyBackupRestoreReport(
                    contentPresetCount: bundle.profiles.contentPresets.count,
                    playbackSystemCount: bundle.profiles.systemProfiles.count,
                    roomCorrectionProjectCount:
                        bundle.roomCorrectionProjects.count,
                    measurementLabSessionCount:
                        bundle.measurementLabSessions.count,
                    binauralAssetCount: bundle.binauralAssets.count,
                    hardwareMappingRequiredSystemIDs:
                        profileReport.hardwareMappingRequiredSystemIDs
                ),
                bundle.preferences
            )
        } catch {
            let originalError = error
            var rollbackFailures: [String] = []

            do {
                _ = try profiles.restoreBackupSnapshot(
                    priorProfiles,
                    recomputeHardwareRequirements: false
                )
            } catch {
                rollbackFailures.append(
                    "profiles: \(error.localizedDescription)"
                )
            }

            restore(
                projectRollback,
                saver: { try roomStore.save($0) },
                deleter: { try roomStore.delete($0) },
                failures: &rollbackFailures,
                label: "Room Correction"
            )
            restore(
                sessionRollback,
                saver: { try labStore.save($0) },
                deleter: { try labStore.delete($0) },
                failures: &rollbackFailures,
                label: "Measurement Lab"
            )
            restore(
                assetRollback,
                saver: { _ = try binauralStore.save($0) },
                deleter: { try binauralStore.delete(id: $0) },
                failures: &rollbackFailures,
                label: "binaural asset"
            )

            if rollbackFailures.isEmpty {
                throw originalError
            }
            throw NotchSixtyBackupError.rollbackFailed(
                rollbackFailures.joined(separator: "; ")
            )
        }
    }

    private func validate(_ bundle: NotchSixtyBackupBundle) throws {
        guard bundle.schemaVersion == NotchSixtyBackupBundle.currentSchemaVersion
        else {
            throw NotchSixtyBackupError.unsupportedBundleVersion(
                bundle.schemaVersion
            )
        }
        guard bundle.manifest.schemaVersion
                == NotchSixtyBackupManifest.currentSchemaVersion else {
            throw NotchSixtyBackupError.unsupportedManifestVersion(
                bundle.manifest.schemaVersion
            )
        }

        try bundle.preferences.validate()
        try bundle.profiles.validate()
        try validateUniqueIdentities(
            projects: bundle.roomCorrectionProjects,
            sessions: bundle.measurementLabSessions,
            assets: bundle.binauralAssets
        )
        for project in bundle.roomCorrectionProjects {
            try project.validateForPersistence()
        }
        for session in bundle.measurementLabSessions {
            try session.validateStructure()
        }
        for asset in bundle.binauralAssets {
            try asset.validate()
        }

        let expected = try makeManifest(
            profiles: bundle.profiles,
            projects: bundle.roomCorrectionProjects,
            sessions: bundle.measurementLabSessions,
            assets: bundle.binauralAssets,
            preferences: bundle.preferences
        )
        guard expected == bundle.manifest else {
            let actualByDomain = Dictionary(
                uniqueKeysWithValues:
                    bundle.manifest.entries.map { ($0.domain, $0.sha256) }
            )
            let failed = expected.entries.first {
                actualByDomain[$0.domain] != $0.sha256
            }?.domain ?? "manifest"
            throw NotchSixtyBackupError.integrityMismatch(failed)
        }
    }

    private func makeManifest(
        profiles: ProductProfileBackupSnapshot,
        projects: [RoomCorrectionProject],
        sessions: [SpeakerMeasurementLabSession],
        assets: [BinauralProfileAsset],
        preferences: NotchSixtyBackupPreferences
    ) throws -> NotchSixtyBackupManifest {
        let domains: [(String, Data)] = [
            ("profiles", try Self.encoder().encode(profiles)),
            (
                "room-correction-projects",
                try Self.encoder().encode(projects)
            ),
            (
                "measurement-lab-sessions",
                try Self.encoder().encode(sessions)
            ),
            ("binaural-assets", try Self.encoder().encode(assets)),
            ("preferences", try Self.encoder().encode(preferences)),
        ]
        let entries = domains.map { domain, data in
            NotchSixtyBackupManifestEntry(
                domain: domain,
                sha256: Self.sha256(data),
                byteCount: data.count
            )
        }
        .sorted { $0.domain < $1.domain }
        return NotchSixtyBackupManifest(entries: entries)
    }

    private func validateUniqueIdentities(
        projects: [RoomCorrectionProject],
        sessions: [SpeakerMeasurementLabSession],
        assets: [BinauralProfileAsset]
    ) throws {
        guard Set(projects.map(\.id)).count == projects.count else {
            throw NotchSixtyBackupError.duplicateIdentity(
                "Room Correction project"
            )
        }
        guard Set(sessions.map(\.id)).count == sessions.count else {
            throw NotchSixtyBackupError.duplicateIdentity(
                "Measurement Lab session"
            )
        }
        guard Set(assets.map(\.id)).count == assets.count else {
            throw NotchSixtyBackupError.duplicateIdentity(
                "binaural asset"
            )
        }
    }

    private func rollbackMap<T>(
        ids: [UUID],
        existingIDs: Set<UUID>,
        loader: (UUID) throws -> T
    ) throws -> [UUID: RollbackValue<T>] {
        var result: [UUID: RollbackValue<T>] = [:]
        for id in Set(ids) {
            if existingIDs.contains(id) {
                result[id] = .present(try loader(id))
            } else {
                result[id] = .absent
            }
        }
        return result
    }

    private func restore<T>(
        _ rollback: [UUID: RollbackValue<T>],
        saver: (T) throws -> Void,
        deleter: (UUID) throws -> Void,
        failures: inout [String],
        label: String
    ) {
        for (id, previous) in rollback {
            do {
                switch previous {
                case .present(let value):
                    try saver(value)
                case .absent:
                    try deleter(id)
                }
            } catch {
                failures.append(
                    "\(label) \(id.uuidString): \(error.localizedDescription)"
                )
            }
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
