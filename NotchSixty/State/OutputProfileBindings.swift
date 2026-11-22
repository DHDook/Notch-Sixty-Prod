import Foundation

/// E15 S1: whether Notch Sixty keeps the output the user selected (the default, `AGENTS.md` section 3) or, only when the
/// user opts in, processes whatever output macOS is set to. Swift only; the engine receives a selected UID as it does
/// today. With `e15.follow-output` off the mode is `.fixed` whatever is stored.
enum OutputSelectionMode: String, Codable, Equatable, Sendable {
    case fixed
    case followSystem

    static let defaultsKey = "audio.outputSelectionMode"

    /// The mode in force: the stored choice, forced to `.fixed` when the flag is off.
    static func effective(stored: OutputSelectionMode, flagEnabled: Bool) -> OutputSelectionMode {
        flagEnabled ? stored : .fixed
    }

    static func stored(in defaults: UserDefaults = .standard) -> OutputSelectionMode {
        defaults.string(forKey: defaultsKey).flatMap(OutputSelectionMode.init(rawValue:)) ?? .fixed
    }

    static func store(_ mode: OutputSelectionMode, in defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: defaultsKey)
    }
}

/// An output endpoint: the device UID plus the data-source ID where the device reports one
/// (`kAudioDevicePropertyDataSource`), so built-in speakers and a headphone jack on one device bind separately.
struct OutputKey: Codable, Hashable, Comparable, Sendable {
    var deviceUID: String
    var dataSourceID: UInt32?

    init(deviceUID: String, dataSourceID: UInt32? = nil) {
        self.deviceUID = deviceUID
        self.dataSourceID = dataSourceID
    }

    /// The same device without its data source.
    var deviceOnly: OutputKey { OutputKey(deviceUID: deviceUID) }

    static func < (lhs: OutputKey, rhs: OutputKey) -> Bool {
        if lhs.deviceUID != rhs.deviceUID { return lhs.deviceUID < rhs.deviceUID }
        return (lhs.dataSourceID.map { Int64($0) } ?? -1) < (rhs.dataSourceID.map { Int64($0) } ?? -1)
    }
}

/// The output-to-Playback-System table behind Follow macOS output. Pure value type, stored as an optional field of
/// `profiles-v1.json` and of the backup snapshot (older files load with an empty table). Content presets never follow
/// the device (owner decision 3, 11 Nov 2026).
struct OutputProfileBindings: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var key: OutputKey
        var systemProfileID: UUID
    }

    /// Sorted by key so the encoded file is deterministic.
    private(set) var entries: [Entry] = []
    /// True once the one-time seed from `associatedOutputUID` has run (on first enable).
    private(set) var seeded = false

    var isEmpty: Bool { entries.isEmpty }

    /// The profile bound to `key`; a key with a data source falls back to a binding for the device alone.
    func profileID(for key: OutputKey) -> UUID? {
        if let exact = entries.first(where: { $0.key == key }) { return exact.systemProfileID }
        guard key.dataSourceID != nil else { return nil }
        return entries.first(where: { $0.key == key.deviceOnly })?.systemProfileID
    }

    /// Binds `key` to a profile, replacing any earlier binding for that key.
    mutating func bind(_ key: OutputKey, to systemProfileID: UUID) {
        entries.removeAll { $0.key == key }
        entries.append(Entry(key: key, systemProfileID: systemProfileID))
        entries.sort { $0.key < $1.key }
    }

    mutating func unbind(_ key: OutputKey) {
        entries.removeAll { $0.key == key }
    }

    /// Drops every binding of a deleted profile.
    mutating func removeProfile(_ systemProfileID: UUID) {
        entries.removeAll { $0.systemProfileID == systemProfileID }
    }

    /// Drops bindings whose profile no longer exists.
    func pruned(validProfileIDs: Set<UUID>) -> OutputProfileBindings {
        var copy = self
        copy.entries.removeAll { !validProfileIDs.contains($0.systemProfileID) }
        return copy
    }

    /// Device UIDs that more than one profile names in `associatedOutputUID`, so the seed cannot choose.
    static func ambiguousUIDs(
        associations: [(profileID: UUID, outputUID: String?)],
        bindings: OutputProfileBindings
    ) -> [String] {
        var owners: [String: Set<UUID>] = [:]
        for item in associations {
            if let uid = item.outputUID { owners[uid, default: []].insert(item.profileID) }
        }
        return owners.filter { uid, ids in
            ids.count > 1 && !bindings.entries.contains { $0.key.deviceUID == uid }
        }.keys.sorted()
    }

    /// One-time seed on first enable: binds each device UID that exactly one profile names (device-level key, no data
    /// source). Ambiguous UIDs stay unbound (see `ambiguousUIDs`). Never overrides an existing binding for that device.
    mutating func seed(from associations: [(profileID: UUID, outputUID: String?)]) {
        guard !seeded else { return }
        seeded = true
        var owners: [String: [UUID]] = [:]
        for item in associations {
            if let uid = item.outputUID { owners[uid, default: []].append(item.profileID) }
        }
        for uid in owners.keys.sorted() {
            guard let ids = owners[uid], Set(ids).count == 1, let id = ids.first else { continue }
            guard !entries.contains(where: { $0.key.deviceUID == uid }) else { continue }
            bind(OutputKey(deviceUID: uid), to: id)
        }
    }
}
