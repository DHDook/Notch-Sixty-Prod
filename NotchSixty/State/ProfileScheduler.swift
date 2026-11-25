import Combine
import Foundation

/// E15 S7 (design note 16): applies the schedule. Main actor, injected clock, calendar and one-shot timer, no polling.
/// It only ever selects a content preset through the same path as a manual pick (`ScheduleContentHost`); it never
/// changes the output, the Playback System or any arm (Q3).
///
/// Owner decisions Q1-Q5 are built to the plan's recommendations (the owner merged the plan without answering in
/// words). Each rule lives in one place so a different answer is a one-place change:
/// - Q1 content presets plus a hidden `.nightMode` action: `ScheduledAction`, `nightMode` provider, `applyAction`.
/// - Q2 one global list, optional per-system scope: `ScheduleEntry.systemScope`, `scopeAllows`.
/// - Q3 content presets only: `ScheduleContentHost` has no system or output method.
/// - Q4 in-app banner with Undo, no macOS notification: `notice`.
/// - Q5 latest missed boundary once; edits wait: `evaluate` and `ProfileSchedule.markingConsumed`.

/// What the scheduler needs from the app: read the current selection, select a content preset. Deliberately has no
/// way to change a Playback System, the output or an arm.
@MainActor
protocol ScheduleContentHost: AnyObject {
    var selectedContentPresetID: UUID? { get }
    var selectedSystemProfileID: UUID? { get }
    /// The selected preset has unsaved edits (editing is a manual change).
    var hasUnsavedContentEdits: Bool { get }
    func contentPresetName(_ id: UUID) -> String?
    func selectContentPreset(_ id: UUID) async throws
}

/// E30 injects this; until then the `.nightMode` action stays hidden and is skipped (Q1).
@MainActor
protocol NightModeSwitching: AnyObject {
    func setNightMode(_ on: Bool)
}

@MainActor
protocol ScheduleTimer: AnyObject {
    func arm(at date: Date, fire: @escaping @MainActor () -> Void)
    func cancel()
}

/// Production timer: one sleeping task, replaced on every re-plan.
@MainActor
final class TaskScheduleTimer: ScheduleTimer {
    private var task: Task<Void, Never>?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    func arm(at date: Date, fire: @escaping @MainActor () -> Void) {
        task?.cancel()
        let delay = max(0, date.timeIntervalSince(now()))
        task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            fire()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

enum ScheduleEvent: Equatable, Sendable {
    case launch, wake, blockEnded, timer
    /// The wall clock or time zone changed: boundaries move, but nothing is applied for the jump itself.
    case clockChanged, timeZoneChanged
}

struct ScheduleNotice: Equatable {
    var message: String
    var canUndo: Bool
}

@MainActor
final class ProfileScheduler: ObservableObject {
    private let profiles: ProductProfileController
    private let host: ScheduleContentHost
    private let clock: () -> Date
    private let calendar: () -> Calendar
    private let timer: ScheduleTimer
    private let blocks: () -> Set<OutputFollowBlock>
    private var observation: AnyCancellable?
    private var undoHandler: (() async -> Void)?

    /// E30 sets this; nil keeps the night-mode action hidden.
    weak var nightMode: NightModeSwitching?

    /// Q4: the in-app banner. Cleared by the user or replaced by the next scheduled switch.
    @Published private(set) var notice: ScheduleNotice?
    /// Why the last boundary did nothing worth a banner but failed (for the card), if it did.
    @Published private(set) var lastFailure: String?
    /// "Next: 22:00, Cinema Night", or nil when nothing is scheduled.
    @Published private(set) var nextChangeText: String?

    init(
        profiles: ProductProfileController,
        host: ScheduleContentHost,
        clock: @escaping () -> Date = Date.init,
        calendar: @escaping () -> Calendar = { Calendar.autoupdatingCurrent },
        timer: ScheduleTimer? = nil,
        blocks: @escaping () -> Set<OutputFollowBlock> = { [] }
    ) {
        self.profiles = profiles
        self.host = host
        self.clock = clock
        self.calendar = calendar
        self.timer = timer ?? TaskScheduleTimer(now: clock)
        self.blocks = blocks
        // The published schedule changes in willSet; hop once so the plan reads the new value.
        observation = profiles.$schedule.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.planTimer() } }
        }
        planTimer()
    }

    var schedule: ProfileSchedule { profiles.schedule }
    var isNightModeAvailable: Bool { nightMode != nil }

    // MARK: Events

    /// Entry point for launch, wake, clock and time-zone changes, the timer and the end of a block.
    func handle(_ event: ScheduleEvent) async {
        switch event {
        case .launch, .wake, .blockEnded, .timer: await evaluate()
        case .clockChanged, .timeZoneChanged: planTimer()
        }
    }

    func dismissNotice() {
        notice = nil
        undoHandler = nil
    }

    /// Restores what was selected before the scheduled switch. A manual change: nothing is reasserted afterwards.
    func undoNotice() async {
        let handler = undoHandler
        notice = nil
        undoHandler = nil
        await handler?()
    }

    // MARK: Editing (Q5: every edit waits for the next boundary)

    func setEnabled(_ enabled: Bool) {
        var next = schedule
        next.isEnabled = enabled
        commitEdit(next)
    }

    func upsert(_ entry: ScheduleEntry) throws {
        var next = schedule
        try next.upsert(entry)
        commitEdit(next)
    }

    func remove(_ id: UUID) {
        var next = schedule
        next.remove(id)
        commitEdit(next)
    }

    private func commitEdit(_ next: ProfileSchedule) {
        profiles.setSchedule(next.markingConsumed(upTo: clock()))
        planTimer()
    }

    // MARK: Evaluation

    /// Applies the latest boundary at or before now that has not been consumed, once (Q5).
    func evaluate() async {
        let schedule = self.schedule
        guard schedule.isEnabled, !schedule.entries.isEmpty else { planTimer(); return }
        let now = clock()
        guard let last = schedule.lastAppliedBoundary else {
            // Never consumed anything: nothing before now is "missed".
            profiles.setSchedule(schedule.markingConsumed(upTo: now))
            planTimer()
            return
        }
        guard let boundary = timeline(schedule).latest(atOrBefore: now), boundary.date > last else {
            planTimer()
            return
        }
        // A block defers the boundary: it stays unconsumed and applies when the block ends.
        guard blocks().isEmpty else { planTimer(); return }
        profiles.setSchedule(schedule.markingConsumed(upTo: boundary.date))
        planTimer()
        await applyAction(of: boundary)
    }

    private func scopeAllows(_ entry: ScheduleEntry) -> Bool {
        entry.systemScope == nil || entry.systemScope == host.selectedSystemProfileID
    }

    private func applyAction(of boundary: ScheduleBoundary) async {
        let entry = boundary.entry
        guard scopeAllows(entry) else { return }
        let when = timeText(boundary.date)
        switch entry.action {
        case .nightMode(let on):
            guard let nightMode else { return }
            nightMode.setNightMode(on)
            show(ScheduleNotice(message: "Scheduled: Night mode \(on ? "on" : "off") (\(when))", canUndo: true)) {
                [weak nightMode] in nightMode?.setNightMode(!on)
            }
        case .contentPreset(let id):
            guard let name = host.contentPresetName(id), host.selectedContentPresetID != id,
                  !host.hasUnsavedContentEdits else { return }
            let previous = host.selectedContentPresetID
            do {
                try await host.selectContentPreset(id)
                lastFailure = nil
            } catch {
                lastFailure = error.localizedDescription
                return
            }
            show(ScheduleNotice(message: "Scheduled: \(name) (\(when))", canUndo: previous != nil)) { [weak self] in
                guard let self, let previous else { return }
                try? await self.host.selectContentPreset(previous)
            }
        }
    }

    private func show(_ notice: ScheduleNotice, undo: @escaping () async -> Void) {
        self.notice = notice
        undoHandler = undo
    }

    // MARK: Timer and text

    private func timeline(_ schedule: ProfileSchedule) -> ScheduleTimeline {
        ScheduleTimeline(entries: schedule.entries, calendar: calendar())
    }

    /// Arms one timer for the next boundary and refreshes the row text.
    func planTimer() {
        let schedule = self.schedule
        guard schedule.isEnabled, !schedule.entries.isEmpty,
              let next = timeline(schedule).next(after: clock()) else {
            timer.cancel()
            nextChangeText = nil
            return
        }
        timer.arm(at: next.date) { [weak self] in
            guard let self else { return }
            Task { @MainActor in await self.handle(.timer) }
        }
        nextChangeText = "Next: \(timeText(next.date)), \(describe(next.entry.action))"
    }

    func describe(_ action: ScheduledAction) -> String {
        switch action {
        case .contentPreset(let id): return host.contentPresetName(id) ?? "Missing preset"
        case .nightMode(let on): return "Night mode \(on ? "on" : "off")"
        }
    }

    func timeText(_ date: Date) -> String {
        let cal = calendar()
        let formatter = DateFormatter()
        formatter.calendar = cal
        formatter.timeZone = cal.timeZone
        formatter.locale = cal.locale ?? .current
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
