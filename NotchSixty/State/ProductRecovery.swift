import Combine
import Foundation

enum ProductRecoveryFailureKind: String, Codable, Equatable, Sendable {
    case audioStart
    case plugInStart
}

enum ProductSafeLaunchReason: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case uncleanTermination
    case repeatedAudioStartFailures
    case repeatedPlugInFailures
    case recoveryStateUnreadable

    var title: String {
        switch self {
        case .uncleanTermination:
            return "Previous session ended unexpectedly"
        case .repeatedAudioStartFailures:
            return "Repeated audio-start failures"
        case .repeatedPlugInFailures:
            return "Repeated plug-in start failures"
        case .recoveryStateUnreadable:
            return "Recovery state could not be read"
        }
    }

    var detail: String {
        switch self {
        case .uncleanTermination:
            return "Notch Sixty did not record a clean application termination. Processing remains stopped until you choose how to continue."
        case .repeatedAudioStartFailures:
            return "Audio processing has failed to start repeatedly. Safe Launch prevents another automatic attempt."
        case .repeatedPlugInFailures:
            return "The Audio Unit rack has failed to prepare or build repeatedly. You can continue with plug-ins bypassed for this launch without changing the saved rack."
        case .recoveryStateUnreadable:
            return "The machine-local recovery record was invalid or unreadable. Saved presets and Playback Systems were left untouched."
        }
    }
}

struct ProductRecoveryPersistentState: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var launchSessionOpen = false
    var consecutiveAudioStartFailures = 0
    var consecutivePlugInFailures = 0
    var lastFailureKind: ProductRecoveryFailureKind?
    var lastFailureDescription: String?
    var lastFailureAt: Date?
    var lastKnownGoodProfiles: ProductProfileBackupSnapshot?
    var lastKnownGoodAt: Date?

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion,
              consecutiveAudioStartFailures >= 0,
              consecutivePlugInFailures >= 0 else {
            throw ProductRecoveryError.invalidState
        }
        try lastKnownGoodProfiles?.validate()
    }
}

enum ProductRecoveryError: Error, LocalizedError, Equatable {
    case invalidState
    case noLastKnownGood
    case safeLaunchDecisionRequired
    case recoveryRequiresIdle
    case lastKnownGoodRequiresHardwareMapping(Int)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidState:
            return "The machine-local recovery record is invalid."
        case .noLastKnownGood:
            return "No successful normal processing start has been recorded yet."
        case .safeLaunchDecisionRequired:
            return "Choose a Safe Launch recovery option before starting audio processing."
        case .recoveryRequiresIdle:
            return "Stop audio processing before using Safe Launch recovery."
        case .lastKnownGoodRequiresHardwareMapping(let count):
            return "Last Known Good references unavailable hardware in \(count) Playback System\(count == 1 ? "" : "s"). Reconnect or remap that hardware before restoring it."
        case .persistence(let reason):
            return "Recovery state could not be saved: \(reason)"
        }
    }
}

struct ProductRecoveryStore: Sendable {
    let storageURL: URL?

    init(storageURL: URL? = ProductRecoveryStore.defaultStorageURL()) {
        self.storageURL = storageURL
    }

    func load() throws -> ProductRecoveryPersistentState? {
        guard let storageURL,
              FileManager.default.fileExists(atPath: storageURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(
            ProductRecoveryPersistentState.self,
            from: Data(contentsOf: storageURL)
        )
        try state.validate()
        return state
    }

    func save(_ state: ProductRecoveryPersistentState) throws {
        try state.validate()
        guard let storageURL else { return }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(state).write(
            to: storageURL,
            options: .atomic
        )
    }

    static func defaultStorageURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return root
            .appendingPathComponent("Notch Sixty", isDirectory: true)
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(
                "recovery-state.json",
                isDirectory: false
            )
    }
}

@MainActor
final class ProductRecoveryController: ObservableObject {
    static let failureThreshold = 2

    private let store: ProductRecoveryStore
    private var prepared = false

    @Published private(set) var persistentState =
        ProductRecoveryPersistentState()
    @Published private(set) var safeLaunchReasons:
        [ProductSafeLaunchReason] = []
    @Published private(set) var plugInsBypassedForThisLaunch = false
    @Published private(set) var lastPersistenceErrorDescription: String?

    init(store: ProductRecoveryStore = ProductRecoveryStore()) {
        self.store = store
    }

    var safeLaunchActive: Bool {
        !safeLaunchReasons.isEmpty
    }

    var lastKnownGoodAvailable: Bool {
        persistentState.lastKnownGoodProfiles != nil
    }

    func prepareForLaunch(now: Date = Date()) {
        _ = now
        guard !prepared else { return }
        prepared = true

        var loaded = ProductRecoveryPersistentState()
        var unreadable = false
        var readErrorDescription: String?
        do {
            if let existing = try store.load() {
                loaded = existing
            }
        } catch {
            unreadable = true
            readErrorDescription = error.localizedDescription
            lastPersistenceErrorDescription =
                error.localizedDescription
        }

        var reasons: [ProductSafeLaunchReason] = []
        if unreadable {
            reasons.append(.recoveryStateUnreadable)
        }
        if loaded.launchSessionOpen {
            reasons.append(.uncleanTermination)
        }
        if loaded.consecutiveAudioStartFailures
            >= Self.failureThreshold {
            reasons.append(.repeatedAudioStartFailures)
        }
        if loaded.consecutivePlugInFailures
            >= Self.failureThreshold {
            reasons.append(.repeatedPlugInFailures)
        }

        persistentState = loaded
        safeLaunchReasons = Self.uniqueReasons(reasons)
        persistentState.launchSessionOpen = true
        persistNonFatal()
        if unreadable,
           let readErrorDescription,
           lastPersistenceErrorDescription == nil {
            // Keep the original read failure visible for this launch even
            // though a clean replacement recovery record was written.
            lastPersistenceErrorDescription = readErrorDescription
        }
    }

    func openNormally() {
        plugInsBypassedForThisLaunch = false
        safeLaunchReasons = []
    }

    func openWithPlugInsBypassed() {
        plugInsBypassedForThisLaunch = true
        safeLaunchReasons = []
    }

    func resolveAfterLastKnownGoodRestore() {
        plugInsBypassedForThisLaunch = false
        persistentState.consecutiveAudioStartFailures = 0
        persistentState.consecutivePlugInFailures = 0
        safeLaunchReasons = []
        persistNonFatal()
    }

    func recordStartFailure(
        _ kind: ProductRecoveryFailureKind,
        description: String,
        now: Date = Date()
    ) {
        switch kind {
        case .audioStart:
            persistentState.consecutiveAudioStartFailures += 1
        case .plugInStart:
            persistentState.consecutivePlugInFailures += 1
        }
        persistentState.lastFailureKind = kind
        persistentState.lastFailureDescription = description
        persistentState.lastFailureAt = now

        var reasons = safeLaunchReasons
        if persistentState.consecutiveAudioStartFailures
            >= Self.failureThreshold {
            reasons.append(.repeatedAudioStartFailures)
        }
        if persistentState.consecutivePlugInFailures
            >= Self.failureThreshold {
            reasons.append(.repeatedPlugInFailures)
        }
        safeLaunchReasons = Self.uniqueReasons(reasons)
        persistNonFatal()
    }

    func recordSuccessfulStart(
        profiles: ProductProfileBackupSnapshot,
        plugInChainHealthy: Bool = true,
        now: Date = Date()
    ) {
        persistentState.consecutiveAudioStartFailures = 0
        if plugInsBypassedForThisLaunch || !plugInChainHealthy {
            // A core-audio success with the rack omitted or quarantined does
            // not certify the saved plug-in chain as known-good.
            persistNonFatal()
            return
        }

        persistentState.consecutivePlugInFailures = 0
        persistentState.lastKnownGoodProfiles = profiles
        persistentState.lastKnownGoodAt = now
        persistNonFatal()
    }

    func lastKnownGoodSnapshot() throws -> ProductProfileBackupSnapshot {
        guard let snapshot =
                persistentState.lastKnownGoodProfiles else {
            throw ProductRecoveryError.noLastKnownGood
        }
        try snapshot.validate()
        return snapshot
    }

    func markCleanTermination() {
        persistentState.launchSessionOpen = false
        persistNonFatal()
    }

    func diagnosticsLines() -> [String] {
        [
            "Safe Launch: \(safeLaunchActive ? "Required" : "No")",
            "Safe Launch Reasons: \(safeLaunchReasons.map(\.title).joined(separator: " | ").isEmpty ? "None" : safeLaunchReasons.map(\.title).joined(separator: " | "))",
            "Plug-ins Bypassed This Launch: \(plugInsBypassedForThisLaunch ? "Yes" : "No")",
            "Consecutive Audio Start Failures: \(persistentState.consecutiveAudioStartFailures)",
            "Consecutive Plug-in Start Failures: \(persistentState.consecutivePlugInFailures)",
            "Last Recovery Failure: \(persistentState.lastFailureDescription ?? "None")",
            "Last Known Good: \(persistentState.lastKnownGoodAt.map { ISO8601DateFormatter().string(from: $0) } ?? "Unavailable")",
            "Recovery Persistence Error: \(lastPersistenceErrorDescription ?? "None")",
        ]
    }

    private func persistNonFatal() {
        do {
            try store.save(persistentState)
            lastPersistenceErrorDescription = nil
        } catch {
            lastPersistenceErrorDescription =
                error.localizedDescription
        }
    }

    private static func uniqueReasons(
        _ reasons: [ProductSafeLaunchReason]
    ) -> [ProductSafeLaunchReason] {
        var seen = Set<ProductSafeLaunchReason>()
        return reasons.filter { seen.insert($0).inserted }
    }
}
