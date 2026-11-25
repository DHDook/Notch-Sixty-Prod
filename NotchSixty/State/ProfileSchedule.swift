import Foundation

/// E15 S7 (design note 16): the schedule model and its pure timeline. App shell and State only; nothing here touches
/// the engine, the output, the Playback System or any arm. Stored as an optional field of `profiles-v1.json` and of
/// the backup snapshot (older files load with no schedule).

/// What a boundary does. Q1: content presets now; `.nightMode` is carried but hidden until E30 injects a switch.
enum ScheduledAction: Codable, Equatable, Sendable {
    case contentPreset(UUID)
    case nightMode(Bool)

    var presetID: UUID? {
        if case .contentPreset(let id) = self { return id }
        return nil
    }
}

/// One time of day. `weekdays` uses `Calendar` weekday numbers (1 = Sunday ... 7 = Saturday); every day by default.
/// `systemScope` limits the entry to one Playback System; nil means any (Q2).
struct ScheduleEntry: Codable, Equatable, Sendable, Identifiable {
    static let everyDay: Set<Int> = Set(1...7)

    var id: UUID
    var hour: Int
    var minute: Int
    var weekdays: Set<Int>
    var action: ScheduledAction
    var systemScope: UUID?

    init(
        id: UUID = UUID(), hour: Int, minute: Int, weekdays: Set<Int> = ScheduleEntry.everyDay,
        action: ScheduledAction, systemScope: UUID? = nil
    ) {
        self.id = id
        self.hour = min(max(hour, 0), 23)
        self.minute = min(max(minute, 0), 59)
        self.weekdays = weekdays.intersection(Self.everyDay)
        self.action = action
        self.systemScope = systemScope
    }

    /// Two entries at the same minute and scope are refused in the editor (design note 16).
    func collides(with other: ScheduleEntry) -> Bool {
        id != other.id && hour == other.hour && minute == other.minute && systemScope == other.systemScope
            && !weekdays.isDisjoint(with: other.weekdays)
    }
}

struct ProfileSchedule: Codable, Equatable, Sendable {
    var isEnabled = false
    private(set) var entries: [ScheduleEntry] = []
    /// The latest boundary already consumed (applied or skipped). Turning a schedule on or editing it sets this to
    /// "now" so the change waits for the next boundary (Q5); one place, `markingConsumed(upTo:)`.
    private(set) var lastAppliedBoundary: Date?

    /// True when nothing is stored, so the field is omitted from files.
    var isDefault: Bool { !isEnabled && entries.isEmpty && lastAppliedBoundary == nil }

    enum EditError: Error, Equatable { case collision, emptyWeekdays }

    /// Q5: every schedule edit waits for the next boundary.
    func markingConsumed(upTo date: Date) -> ProfileSchedule {
        var copy = self
        copy.lastAppliedBoundary = date
        return copy
    }

    /// Adds or replaces an entry (by id). Refuses a same-minute, same-scope collision.
    mutating func upsert(_ entry: ScheduleEntry) throws {
        guard !entry.weekdays.isEmpty else { throw EditError.emptyWeekdays }
        guard !entries.contains(where: { entry.collides(with: $0) }) else { throw EditError.collision }
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
        entries.sort { ($0.hour, $0.minute, $0.id.uuidString) < ($1.hour, $1.minute, $1.id.uuidString) }
    }

    mutating func remove(_ id: UUID) { entries.removeAll { $0.id == id } }

    /// Deleting a preset removes the entries that name it; deleting a system removes entries scoped to it.
    mutating func removeReferences(presetID: UUID? = nil, systemID: UUID? = nil) {
        entries.removeAll { entry in
            (presetID != nil && entry.action.presetID == presetID) || (systemID != nil && entry.systemScope == systemID)
        }
    }

    func pruned(validPresetIDs: Set<UUID>, validSystemIDs: Set<UUID>) -> ProfileSchedule {
        var copy = self
        copy.entries.removeAll { entry in
            if let preset = entry.action.presetID, !validPresetIDs.contains(preset) { return true }
            if let scope = entry.systemScope, !validSystemIDs.contains(scope) { return true }
            return false
        }
        return copy
    }
}

/// One firing of one entry.
struct ScheduleBoundary: Equatable, Sendable {
    var date: Date
    var entry: ScheduleEntry
}

/// Pure boundary arithmetic over an injected calendar (and so time zone). A local time that does not exist (spring
/// forward) fires at the first valid minute after it; a repeated hour (fall back) fires once, on its first occurrence.
struct ScheduleTimeline: Sendable {
    var entries: [ScheduleEntry]
    var calendar: Calendar

    /// How far to look. Every entry fires at least weekly, so eight days always finds the next or latest boundary.
    private static let searchDays = 8

    func next(after date: Date) -> ScheduleBoundary? {
        boundaries(from: date, forward: true).first { $0.date > date }
    }

    func latest(atOrBefore date: Date) -> ScheduleBoundary? {
        boundaries(from: date, forward: false).last { $0.date <= date }
    }

    /// Boundaries over a window of days around `date`, sorted ascending by date then entry order.
    private func boundaries(from date: Date, forward: Bool) -> [ScheduleBoundary] {
        var result: [ScheduleBoundary] = []
        let today = calendar.startOfDay(for: date)
        for offset in 0..<Self.searchDays {
            let signed = forward ? offset : -offset
            guard let day = calendar.date(byAdding: .day, value: signed, to: today) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            for entry in entries where entry.weekdays.contains(weekday) {
                guard let fire = calendar.date(
                    bySettingHour: entry.hour, minute: entry.minute, second: 0, of: day,
                    matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
                else { continue }
                result.append(ScheduleBoundary(date: fire, entry: entry))
            }
        }
        return result.sorted { $0.date < $1.date }
    }
}
