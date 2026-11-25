import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E15 S7: schedules (design note 16). Q1-Q5 built to the plan's recommendations.
@MainActor
final class ProfileScheduleTests: XCTestCase {
    // MARK: Fixtures

    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func calendar(_ zone: String) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: zone)!
        cal.locale = Locale(identifier: "en_GB")
        return cal
    }

    private func date(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min, second: s))!
    }

    private final class FakeHost: ScheduleContentHost {
        var selectedContentPresetID: UUID?
        var selectedSystemProfileID: UUID?
        var hasUnsavedContentEdits = false
        var names: [UUID: String] = [:]
        var selectCalls: [UUID] = []
        var failure: Error?
        func contentPresetName(_ id: UUID) -> String? { names[id] }
        func selectContentPreset(_ id: UUID) async throws {
            if let failure { throw failure }
            selectCalls.append(id)
            selectedContentPresetID = id
        }
    }

    private final class FakeTimer: ScheduleTimer {
        var armedAt: Date?
        var cancelled = 0
        func arm(at date: Date, fire: @escaping @MainActor () -> Void) { armedAt = date }
        func cancel() { armedAt = nil; cancelled += 1 }
    }

    private final class FakeNight: NightModeSwitching {
        var calls: [Bool] = []
        func setNightMode(_ on: Bool) { calls.append(on) }
    }

    private struct Rig {
        let profiles: ProductProfileController
        let host: FakeHost
        let timer: FakeTimer
        let scheduler: ProfileScheduler
        let a: UUID
        let b: UUID
        let cal: Calendar
        var now: Box
    }

    private final class Box { var value: Date; init(_ v: Date) { value = v } }

    private func rig(
        zone: String = "Europe/London", start: Date? = nil, blocks: @escaping () -> Set<OutputFollowBlock> = { [] }
    ) -> Rig {
        let cal = calendar(zone)
        let profiles = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("\(UUID().uuidString).json"))
        let a = profiles.saveCurrentContentPreset(named: "Daytime")
        let b = profiles.saveCurrentContentPreset(named: "Cinema Night")
        return makeRig(profiles: profiles, cal: cal, a: a, b: b, start: start ?? date(cal, 2026, 6, 1, 12), blocks: blocks)
    }

    private func makeRig(
        profiles: ProductProfileController, cal: Calendar, a: UUID, b: UUID, start: Date,
        blocks: @escaping () -> Set<OutputFollowBlock> = { [] }
    ) -> Rig {
        let host = FakeHost()
        host.names = [a: "Daytime", b: "Cinema Night"]
        host.selectedContentPresetID = a
        host.selectedSystemProfileID = profiles.selectedSystemProfileID
        let timer = FakeTimer()
        let now = Box(start)
        let scheduler = ProfileScheduler(
            profiles: profiles, host: host, clock: { now.value }, calendar: { cal }, timer: timer, blocks: blocks)
        return Rig(profiles: profiles, host: host, timer: timer, scheduler: scheduler, a: a, b: b, cal: cal, now: now)
    }

    private func enable(_ r: Rig, entries: [ScheduleEntry]) throws {
        for entry in entries { try r.scheduler.upsert(entry) }
        r.scheduler.setEnabled(true)
    }

    // MARK: Timeline

    func testEntryFiresAtItsMinuteOnChosenWeekdays() {
        let cal = calendar("Europe/London")
        // 2026-06-01 is a Monday. Weekday numbers: Monday = 2.
        let entry = ScheduleEntry(hour: 22, minute: 0, weekdays: [2, 4], action: .contentPreset(UUID()))
        let line = ScheduleTimeline(entries: [entry], calendar: cal)
        XCTAssertEqual(line.next(after: date(cal, 2026, 6, 1, 12))?.date, date(cal, 2026, 6, 1, 22))
        XCTAssertEqual(line.next(after: date(cal, 2026, 6, 1, 22))?.date, date(cal, 2026, 6, 3, 22), "Wednesday next")
        XCTAssertEqual(line.latest(atOrBefore: date(cal, 2026, 6, 2, 9))?.date, date(cal, 2026, 6, 1, 22))
        XCTAssertEqual(line.latest(atOrBefore: date(cal, 2026, 6, 1, 22))?.date, date(cal, 2026, 6, 1, 22))
        XCTAssertNil(ScheduleTimeline(entries: [], calendar: cal).next(after: Date()))
    }

    private func firings(_ line: ScheduleTimeline, cal: Calendar, day: DateComponents) -> [Date] {
        let start = cal.date(from: day)!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        var result: [Date] = []
        var cursor = start.addingTimeInterval(-1)
        while let next = line.next(after: cursor), next.date < end {
            result.append(next.date)
            cursor = next.date
        }
        return result
    }

    func testSpringForwardAndFallBackFireOnceInLondonAndNewYork() {
        let cases: [(zone: String, spring: DateComponents, fall: DateComponents, hour: Int, minute: Int)] = [
            ("Europe/London", DateComponents(year: 2026, month: 3, day: 29), DateComponents(year: 2026, month: 10, day: 25), 1, 30),
            ("America/New_York", DateComponents(year: 2026, month: 3, day: 8), DateComponents(year: 2026, month: 11, day: 1), 2, 30),
        ]
        for item in cases {
            let cal = calendar(item.zone)
            let line = ScheduleTimeline(
                entries: [ScheduleEntry(hour: item.hour, minute: item.minute, action: .nightMode(true))], calendar: cal)
            let spring = firings(line, cal: cal, day: item.spring)
            XCTAssertEqual(spring.count, 1, "\(item.zone) spring forward fires once")
            let start = cal.date(from: item.spring)!
            XCTAssertGreaterThan(spring[0], start)
            XCTAssertLessThan(spring[0].timeIntervalSince(start), 4 * 3600)
            let fall = firings(line, cal: cal, day: item.fall)
            XCTAssertEqual(fall.count, 1, "\(item.zone) fall back fires once")
        }
        // Fall back: the first occurrence of the repeated London 01:30 is 00:30 UTC.
        let london = calendar("Europe/London")
        let line = ScheduleTimeline(
            entries: [ScheduleEntry(hour: 1, minute: 30, action: .nightMode(true))], calendar: london)
        let fall = firings(line, cal: london, day: DateComponents(year: 2026, month: 10, day: 25))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(fall.first, utc.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 0, minute: 30)))
    }

    func testTimeZoneChangeReplansTheTimer() throws {
        let r = rig()
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        let london = r.timer.armedAt
        XCTAssertEqual(london, date(r.cal, 2026, 6, 1, 22))
        // The same scheduler under another time zone plans a different instant.
        let ny = calendar("America/New_York")
        let moved = ProfileScheduler(
            profiles: r.profiles, host: r.host, clock: { r.now.value }, calendar: { ny }, timer: r.timer)
        XCTAssertEqual(r.timer.armedAt, date(ny, 2026, 6, 1, 22))
        XCTAssertNotEqual(r.timer.armedAt, london)
        _ = moved
    }

    // MARK: Scheduler rules

    func testScheduledSwitchAppliesOnceAndShowsBannerWithUndo() async throws {
        let r = rig()
        let b = r.b
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(b))])
        XCTAssertEqual(r.scheduler.nextChangeText, "Next: 22:00, Cinema Night")
        r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 5)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [b])
        XCTAssertEqual(r.scheduler.notice?.message, "Scheduled: Cinema Night (22:00)")
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [b], "applied once")
        await r.scheduler.undoNotice()
        XCTAssertEqual(r.host.selectCalls, [b, r.a], "Undo restores the previous preset")
        XCTAssertNil(r.scheduler.notice)
        r.now.value = date(r.cal, 2026, 6, 1, 23)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [b, r.a], "Undo is a manual change; nothing reasserts")
    }

    func testEnablingOrEditingWaitsForTheNextBoundary() async throws {
        let r = rig(start: date(calendar("Europe/London"), 2026, 6, 1, 22, 30))
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        await r.scheduler.handle(.launch)
        XCTAssertTrue(r.host.selectCalls.isEmpty, "the 22:00 boundary already passed when it was switched on")
        XCTAssertEqual(r.scheduler.nextChangeText, "Next: 22:00, Cinema Night")
        r.now.value = date(r.cal, 2026, 6, 2, 22, 0, 1)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [r.b])
    }

    func testManualPickHoldsAndSurvivesARelaunchWithNoMissedBoundary() async throws {
        let r = rig()
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 1)
        await r.scheduler.handle(.timer)
        r.host.selectedContentPresetID = r.a // the user picks Daytime by hand
        r.host.selectCalls = []
        r.now.value = date(r.cal, 2026, 6, 1, 23)
        await r.scheduler.handle(.timer)
        XCTAssertTrue(r.host.selectCalls.isEmpty, "between boundaries nothing is reasserted")
        // Relaunch: a new scheduler over the same stored schedule.
        let again = makeRig(profiles: r.profiles, cal: r.cal, a: r.a, b: r.b, start: date(r.cal, 2026, 6, 1, 23, 30))
        again.host.selectedContentPresetID = r.a
        await again.scheduler.handle(.launch)
        XCTAssertTrue(again.host.selectCalls.isEmpty, "a manual pick survives a relaunch")
        // The next boundary applies whatever the user chose.
        again.now.value = date(r.cal, 2026, 6, 2, 22, 0, 1)
        await again.scheduler.handle(.timer)
        XCTAssertEqual(again.host.selectCalls, [r.b])
    }

    func testTwoMissedBoundariesApplyOnlyTheLatestOnce() async throws {
        let r = rig()
        try enable(r, entries: [
            ScheduleEntry(hour: 20, minute: 0, action: .contentPreset(r.a)),
            ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b)),
        ])
        r.host.selectedContentPresetID = nil
        r.now.value = date(r.cal, 2026, 6, 1, 23) // woke after both passed
        await r.scheduler.handle(.wake)
        XCTAssertEqual(r.host.selectCalls, [r.b])
        await r.scheduler.handle(.wake)
        XCTAssertEqual(r.host.selectCalls, [r.b])
    }

    func testClockAndTimeZoneChangesReplanWithoutApplying() async throws {
        let r = rig()
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        r.now.value = date(r.cal, 2026, 6, 1, 23)
        await r.scheduler.handle(.clockChanged)
        await r.scheduler.handle(.timeZoneChanged)
        XCTAssertTrue(r.host.selectCalls.isEmpty)
        XCTAssertEqual(r.timer.armedAt, date(r.cal, 2026, 6, 2, 22))
    }

    func testUnsavedEditsAndWrongScopeSkipTheBoundary() async throws {
        let r = rig()
        let otherSystem = UUID()
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        r.host.hasUnsavedContentEdits = true
        r.now.value = date(r.cal, 2026, 6, 1, 22, 1)
        await r.scheduler.handle(.timer)
        XCTAssertTrue(r.host.selectCalls.isEmpty, "unsaved edits are a manual change")
        r.host.hasUnsavedContentEdits = false
        await r.scheduler.handle(.timer)
        XCTAssertTrue(r.host.selectCalls.isEmpty, "a skipped boundary is consumed, not retried")

        r.scheduler.remove(r.scheduler.schedule.entries[0].id)
        try r.scheduler.upsert(ScheduleEntry(hour: 23, minute: 0, action: .contentPreset(r.b), systemScope: otherSystem))
        r.now.value = date(r.cal, 2026, 6, 1, 23, 1)
        await r.scheduler.handle(.timer)
        XCTAssertTrue(r.host.selectCalls.isEmpty, "scope is not the active system")
        r.host.selectedSystemProfileID = otherSystem
        r.now.value = date(r.cal, 2026, 6, 2, 23, 1)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [r.b])
    }

    func testSafeLaunchCaptureAndFailedWaitThenApply() async throws {
        for block in [OutputFollowBlock.safeLaunch, .measurementCapture, .engineFailed] {
            var active: Set<OutputFollowBlock> = [block]
            let r = rig(blocks: { active })
            try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
            r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 5)
            await r.scheduler.handle(.timer)
            XCTAssertTrue(r.host.selectCalls.isEmpty, "\(block) waits")
            active = []
            await r.scheduler.handle(.blockEnded)
            XCTAssertEqual(r.host.selectCalls, [r.b], "\(block) applies when the block ends")
        }
    }

    func testFailedSwitchIsReportedAndNotRetried() async throws {
        let r = rig()
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        r.host.failure = EQSlotChoiceError.choiceRequired
        r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 5)
        await r.scheduler.handle(.timer)
        XCTAssertNotNil(r.scheduler.lastFailure)
        XCTAssertNil(r.scheduler.notice)
        r.host.failure = nil
        await r.scheduler.handle(.timer)
        XCTAssertTrue(r.host.selectCalls.isEmpty)
    }

    func testNightModeActionIsHiddenUntilAProviderExists() async throws {
        let r = rig()
        XCTAssertFalse(r.scheduler.isNightModeAvailable)
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .nightMode(true))])
        r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 5)
        await r.scheduler.handle(.timer)
        XCTAssertNil(r.scheduler.notice, "no provider: skipped")
        let night = FakeNight()
        r.scheduler.nightMode = night
        XCTAssertTrue(r.scheduler.isNightModeAvailable)
        r.now.value = date(r.cal, 2026, 6, 2, 22, 0, 5)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(night.calls, [true])
        await r.scheduler.undoNotice()
        XCTAssertEqual(night.calls, [true, false])
    }

    func testScheduleNeverChangesTheSystemOrOutput() async throws {
        let r = rig()
        let system = r.profiles.selectedSystemProfileID
        let output = r.profiles.outputBindings
        try enable(r, entries: [ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b))])
        r.now.value = date(r.cal, 2026, 6, 1, 22, 0, 5)
        await r.scheduler.handle(.timer)
        XCTAssertEqual(r.host.selectCalls, [r.b], "the only recorded call is a content preset pick")
        XCTAssertEqual(r.profiles.selectedSystemProfileID, system)
        XCTAssertEqual(r.profiles.outputBindings, output)
    }

    func testTwoEntriesAtTheSameMinuteAndScopeAreRefused() throws {
        let r = rig()
        try r.scheduler.upsert(ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.a)))
        XCTAssertThrowsError(try r.scheduler.upsert(ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b)))) {
            XCTAssertEqual($0 as? ProfileSchedule.EditError, .collision)
        }
        XCTAssertNoThrow(try r.scheduler.upsert(
            ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b), systemScope: UUID())))
        XCTAssertThrowsError(try r.scheduler.upsert(
            ScheduleEntry(hour: 7, minute: 0, weekdays: [], action: .contentPreset(r.b))))
    }

    // MARK: Store

    func testScheduleRoundTripsAndOldFilesLoadEmpty() throws {
        let url = root.appendingPathComponent("p.json")
        let first = ProductProfileController(engine: AudioIOEngine(), storageURL: url)
        let id = first.saveCurrentContentPreset(named: "Cinema Night")
        XCTAssertTrue(first.schedule.isDefault)
        let plain = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(plain.contains("\"schedule\""), "an empty schedule leaves the file as it was")

        var schedule = ProfileSchedule()
        schedule.isEnabled = true
        try schedule.upsert(ScheduleEntry(hour: 22, minute: 15, weekdays: [6, 7], action: .contentPreset(id)))
        first.setSchedule(schedule.markingConsumed(upTo: Date(timeIntervalSince1970: 1_000)))
        let second = ProductProfileController(engine: AudioIOEngine(), storageURL: url)
        XCTAssertEqual(second.schedule, first.schedule)
        XCTAssertEqual(second.makeBackupSnapshot().schedule, first.schedule)
    }

    func testDeletingAPresetRemovesItsEntries() throws {
        let r = rig()
        try enable(r, entries: [
            ScheduleEntry(hour: 20, minute: 0, action: .contentPreset(r.a)),
            ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b)),
        ])
        XCTAssertEqual(r.profiles.selectedContentPresetID, r.b)
        r.profiles.deleteSelectedContentPreset()
        XCTAssertEqual(r.profiles.schedule.entries.map(\.action), [.contentPreset(r.a)])
    }

    func testBackupRestoreCarriesTheScheduleAndPrunesDeadReferences() throws {
        let r = rig()
        try enable(r, entries: [
            ScheduleEntry(hour: 22, minute: 0, action: .contentPreset(r.b)),
            ScheduleEntry(hour: 23, minute: 0, action: .contentPreset(UUID())),
        ])
        let snapshot = r.profiles.makeBackupSnapshot()
        XCTAssertEqual(snapshot.schedule?.entries.count, 2)
        let target = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("q.json"))
        _ = try target.restoreBackupSnapshot(snapshot)
        XCTAssertEqual(target.schedule.entries.map(\.action), [.contentPreset(r.b)])
    }

    // MARK: Production wiring and UI

    func testFlagOffBuildsNoSchedulerAndFlagOnBuildsOne() {
        let product = ProductController(audioEngine: AudioIOEngine())
        let host = ProductScheduleHost(profiles: product.profiles)
        func build(_ flag: Bool) -> ProfileScheduler? {
            ProfileSchedulerWiring.make(
                flagEnabled: flag, engine: product.audioEngine, profiles: product.profiles,
                recovery: product.recovery, calibration: product.calibration,
                multichannel: product.multichannelCalibration, host: host)?.scheduler
        }
        XCTAssertNil(build(false))
        XCTAssertNotNil(build(true))
    }

    func testCardFitsAtBothScreenSizes() throws {
        let r = rig()
        try enable(r, entries: [
            ScheduleEntry(hour: 22, minute: 0, weekdays: [2, 3, 4, 5, 6], action: .contentPreset(r.b), systemScope: UUID()),
            ScheduleEntry(hour: 7, minute: 30, action: .contentPreset(r.a)),
        ])
        for width in [CGFloat(520), 1_280, 1_920] {
            let host = NSHostingView(rootView: ProfileScheduleCard(scheduler: r.scheduler, profiles: r.profiles)
                .frame(width: width))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 1_000)
            host.layoutSubtreeIfNeeded()
            XCTAssertLessThanOrEqual(host.fittingSize.width, width + 0.5, "width \(width)")
        }
    }

    func testWeekdaySummaries() {
        let cal = calendar("Europe/London")
        XCTAssertEqual(ScheduleDisplay.weekdaySummary(ScheduleEntry.everyDay, calendar: cal), "Every day")
        XCTAssertEqual(ScheduleDisplay.weekdaySummary([2, 3, 4, 5, 6], calendar: cal), "Weekdays")
        XCTAssertEqual(ScheduleDisplay.weekdaySummary([1, 7], calendar: cal), "Weekends")
    }
}
