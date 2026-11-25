import SwiftUI

/// E15 S7: Settings > General "Schedules" card and the scheduled-switch banner (design note 16), shown only while
/// `e15.follow-output` is on. Controls reflow with `ViewThatFits` so no row forces the page wider (AGENTS.md section 13).

/// Display helpers, kept pure so tests can read them.
enum ScheduleDisplay {
    /// Weekday numbers in the order shown, starting Monday.
    static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]

    static func weekdaySummary(_ days: Set<Int>, calendar: Calendar = .current) -> String {
        if days == ScheduleEntry.everyDay { return "Every day" }
        if days == [2, 3, 4, 5, 6] { return "Weekdays" }
        if days == [1, 7] { return "Weekends" }
        let symbols = calendar.shortWeekdaySymbols
        return weekdayOrder.filter(days.contains).map { symbols[$0 - 1] }.joined(separator: " ")
    }

    static func weekdayInitial(_ weekday: Int, calendar: Calendar = .current) -> String {
        calendar.veryShortWeekdaySymbols[weekday - 1]
    }
}

struct ProfileScheduleCard: View {
    @ObservedObject var scheduler: ProfileScheduler
    @ObservedObject var profiles: ProductProfileController

    @State private var time = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var weekdays = ScheduleEntry.everyDay
    @State private var actionChoice: ActionChoice = .none
    @State private var scope: UUID?
    @State private var editorError: String?

    private enum ActionChoice: Hashable {
        case none
        case preset(UUID)
        case nightMode(Bool)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Schedules", systemImage: "clock.badge.checkmark").font(.headline)
            Toggle("Switch presets by time of day", isOn: Binding(
                get: { scheduler.schedule.isEnabled }, set: { scheduler.setEnabled($0) }))
            Text("A schedule only switches the content preset, like picking it yourself. It never changes the output or the Playback System. Turning it on or editing it waits for the next time.")
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if scheduler.schedule.isEnabled, let next = scheduler.nextChangeText {
                Text(next).font(.callout.weight(.medium))
            }
            if let failure = scheduler.lastFailure {
                Text("Last scheduled switch did not apply: \(failure)").font(.caption).foregroundStyle(.orange)
            }
            ForEach(scheduler.schedule.entries) { entry in entryRow(entry) }
            Divider()
            addForm
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func entryRow(_ entry: ScheduleEntry) -> some View {
        let timeText = scheduler.timeText(
            Calendar.current.date(bySettingHour: entry.hour, minute: entry.minute, second: 0, of: Date()) ?? Date())
        let scopeName = entry.systemScope.flatMap { id in profiles.systemProfiles.first { $0.id == id }?.name }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(timeText)  \(scheduler.describe(entry.action))").font(.body)
                Text([ScheduleDisplay.weekdaySummary(entry.weekdays), scopeName.map { "Only on \($0)" }]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(role: .destructive) { scheduler.remove(entry.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove schedule entry")
        }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a time").font(.subheadline.weight(.medium))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { timePicker; actionPicker; scopePicker }
                VStack(alignment: .leading, spacing: 8) { timePicker; actionPicker; scopePicker }
            }
            weekdayChips
            HStack {
                Button("Add") { add() }
                    .disabled(actionChoice == .none)
                if let editorError { Text(editorError).font(.caption).foregroundStyle(.orange) }
            }
        }
    }

    private var timePicker: some View {
        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden().fixedSize()
    }

    private var actionPicker: some View {
        Picker("Switch to", selection: $actionChoice) {
            Text("Choose…").tag(ActionChoice.none)
            ForEach(profiles.contentPresets) { preset in Text(preset.name).tag(ActionChoice.preset(preset.id)) }
            if scheduler.isNightModeAvailable {
                Text("Night mode on").tag(ActionChoice.nightMode(true))
                Text("Night mode off").tag(ActionChoice.nightMode(false))
            }
        }
        .frame(maxWidth: 240)
    }

    private var scopePicker: some View {
        Picker("On", selection: $scope) {
            Text("Any Playback System").tag(UUID?.none)
            ForEach(profiles.systemProfiles) { system in Text("Only \(system.name)").tag(UUID?.some(system.id)) }
        }
        .frame(maxWidth: 260)
    }

    private var weekdayChips: some View {
        HStack(spacing: 4) {
            ForEach(ScheduleDisplay.weekdayOrder, id: \.self) { day in
                Toggle(ScheduleDisplay.weekdayInitial(day), isOn: Binding(
                    get: { weekdays.contains(day) },
                    set: { if $0 { weekdays.insert(day) } else { weekdays.remove(day) } }))
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
    }

    private func add() {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
        let action: ScheduledAction
        switch actionChoice {
        case .none: return
        case .preset(let id): action = .contentPreset(id)
        case .nightMode(let on): action = .nightMode(on)
        }
        let entry = ScheduleEntry(
            hour: parts.hour ?? 0, minute: parts.minute ?? 0, weekdays: weekdays, action: action, systemScope: scope)
        do {
            try scheduler.upsert(entry)
            editorError = nil
        } catch ProfileSchedule.EditError.collision {
            editorError = "Another entry is already set for that time."
        } catch {
            editorError = "Choose at least one day."
        }
    }
}

/// The scheduled-switch banner (Q4): an in-app popover with Undo, no macOS notification.
struct ScheduleNoticePresentation: ViewModifier {
    let scheduler: ProfileScheduler?

    func body(content: Content) -> some View {
        if let scheduler {
            content.modifier(Inner(scheduler: scheduler))
        } else {
            content
        }
    }

    private struct Inner: ViewModifier {
        @ObservedObject var scheduler: ProfileScheduler

        func body(content: Content) -> some View {
            content.popover(
                isPresented: Binding(
                    get: { scheduler.notice != nil }, set: { if !$0 { scheduler.dismissNotice() } }),
                arrowEdge: .bottom
            ) {
                if let notice = scheduler.notice {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(notice.message).font(.headline)
                        HStack {
                            if notice.canUndo { Button("Undo") { Task { await scheduler.undoNotice() } } }
                            Button("OK") { scheduler.dismissNotice() }.keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: 360, alignment: .leading)
                }
            }
        }
    }
}
