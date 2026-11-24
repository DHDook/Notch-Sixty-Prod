import Foundation

// E13 S10 (`e13.headphones-page`): a Playback System holds a list of headphones. Pure value types; nothing here
// touches the engine or an audio thread. `PlaybackSystemState.headphoneDeviceProfile` stays the entry the engine
// plays (the selected one), so the render path and the saved-profile reader are unchanged.

enum HeadphoneListError: Error, Equatable, LocalizedError {
    case emptyName
    case unknownEntry

    var errorDescription: String? {
        switch self {
        case .emptyName: return "Give the headphones a name."
        case .unknownEntry: return "Those headphones are no longer in the list."
        }
    }
}

/// One pair of headphones: its name, its correction (trim, delay, polarity, EQ, headroom, crossfeed, in `profile`),
/// the fitted response and target it was made from, and an optional linked output device.
struct HeadphoneListEntry: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var profile: HeadphoneDeviceProfileConfiguration
    /// The stored response the correction was fitted from (the target is `profile.fittedTargetID`).
    var fittedResponseID: UUID?
    /// When this output device becomes the output, this entry is the one to use. nil: picked by hand (a wired pair
    /// on a DAC).
    var linkedOutputUID: String?

    init(
        id: UUID = UUID(), name: String, profile: HeadphoneDeviceProfileConfiguration? = nil,
        fittedResponseID: UUID? = nil, linkedOutputUID: String? = nil
    ) {
        self.id = id
        self.name = name
        var p = profile ?? HeadphoneDeviceProfileConfiguration()
        p.name = name
        self.profile = p
        self.fittedResponseID = fittedResponseID
        self.linkedOutputUID = linkedOutputUID
    }
}

struct HeadphoneList: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = HeadphoneList.currentSchemaVersion
    var entries: [HeadphoneListEntry] = []
    var selectedID: UUID?

    var selected: HeadphoneListEntry? { entries.first { $0.id == selectedID } }

    /// Today's single saved profile becomes the first entry, selected. nil when there is no saved profile.
    static func migrating(_ profile: HeadphoneDeviceProfileConfiguration?) -> HeadphoneList? {
        guard let profile else { return nil }
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = HeadphoneListEntry(
            name: name.isEmpty ? "Headphones" : name, profile: profile, linkedOutputUID: nil)
        var migrated = entry
        // The profile's own bytes are kept; only the entry's name mirrors it.
        migrated.profile = profile
        return HeadphoneList(entries: [migrated], selectedID: migrated.id)
    }

    private func trimmed(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw HeadphoneListError.emptyName }
        return value
    }

    /// A name not yet used, by appending a number.
    func uniqueName(_ base: String) -> String {
        let names = Set(entries.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Adds fresh headphones (default correction, `enabled` carried so the mode stays as the user left it).
    @discardableResult
    mutating func add(name: String, enabled: Bool, outputDeviceUID: String?) throws -> UUID {
        var profile = HeadphoneDeviceProfileConfiguration()
        profile.enabled = enabled
        profile.outputDeviceUID = outputDeviceUID
        let entry = HeadphoneListEntry(name: uniqueName(try trimmed(name)), profile: profile)
        entries.append(entry)
        return entry.id
    }

    /// A copy right after the original, with no linked device (a device links to one pair).
    @discardableResult
    mutating func duplicate(_ id: UUID) throws -> UUID {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw HeadphoneListError.unknownEntry }
        var copy = entries[index]
        copy.id = UUID()
        copy.name = uniqueName(entries[index].name + " copy")
        copy.profile.name = copy.name
        copy.linkedOutputUID = nil
        entries.insert(copy, at: index + 1)
        return copy.id
    }

    mutating func rename(_ id: UUID, to name: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw HeadphoneListError.unknownEntry }
        let value = try trimmed(name)
        entries[index].name = value
        entries[index].profile.name = value
    }

    /// Removes an entry. When it was selected the next one (or the previous, at the end) is selected; nil when the
    /// list is now empty.
    mutating func delete(_ id: UUID) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw HeadphoneListError.unknownEntry }
        entries.remove(at: index)
        if selectedID == id {
            selectedID = entries.isEmpty ? nil : entries[min(index, entries.count - 1)].id
        }
    }

    mutating func select(_ id: UUID) throws {
        guard entries.contains(where: { $0.id == id }) else { throw HeadphoneListError.unknownEntry }
        selectedID = id
    }

    /// Links an output device to one entry. A device links to one pair at a time, so any other entry that had it
    /// is unlinked.
    mutating func link(_ id: UUID, toOutputUID uid: String?) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw HeadphoneListError.unknownEntry }
        if let uid {
            for i in entries.indices where entries[i].linkedOutputUID == uid { entries[i].linkedOutputUID = nil }
        }
        entries[index].linkedOutputUID = uid
    }

    /// The entry linked to an output device, for when binding (E15 S6) reports it became the output.
    func entry(linkedTo uid: String) -> HeadphoneListEntry? {
        entries.first { $0.linkedOutputUID == uid }
    }

    /// Stores the edited correction of the selected entry. Without a list entry (nothing saved before) one is made
    /// from the profile's own name.
    mutating func updateSelected(profile: HeadphoneDeviceProfileConfiguration, fittedResponseID: UUID?) {
        if let index = entries.firstIndex(where: { $0.id == selectedID }) {
            var p = profile
            p.name = entries[index].name
            entries[index].profile = p
            if let fittedResponseID { entries[index].fittedResponseID = fittedResponseID }
        } else {
            let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
            var entry = HeadphoneListEntry(name: uniqueName(name.isEmpty ? "Headphones" : name), profile: profile)
            entry.fittedResponseID = fittedResponseID
            entries.append(entry)
            selectedID = entry.id
        }
    }
}
