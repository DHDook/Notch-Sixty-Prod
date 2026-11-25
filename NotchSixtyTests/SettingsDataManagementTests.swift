import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S25: settings in the backup, automatic backup, restore defaults, erase, and the layout check (G99).
@MainActor
final class SettingsDataManagementTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suite = ""
    private var clock = Date(timeIntervalSince1970: 1_799_971_200 + 43_200)

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        suite = "SettingsDataManagementTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private struct Rig {
        var manager: SettingsDataManager
        var service: NotchSixtyBackupService
        var profiles: ProductProfileController
        var history: BlindTestHistoryStore
        var preferences: ApplicationPreferences
        var store: AutomaticBackupStore
    }

    private func rig(isIdle: @escaping () -> Bool = { true }, folder: String = "a") -> Rig {
        let root = self.root.appendingPathComponent(folder, isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let profiles = ProductProfileController(
            engine: AudioIOEngine(), storageURL: root.appendingPathComponent("p.json"))
        let history = BlindTestHistoryStore(url: root.appendingPathComponent("h.json"))
        let service = NotchSixtyBackupService(
            profiles: profiles,
            roomStore: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("room", isDirectory: true)),
            labStore: SpeakerMeasurementLabSessionStore(rootDirectory: root.appendingPathComponent("lab", isDirectory: true)),
            binauralStore: BinauralProfileAssetStore(rootURL: root.appendingPathComponent("binaural", isDirectory: true)),
            blindHistory: history)
        let store = AutomaticBackupStore(directory: root.appendingPathComponent("Backups", isDirectory: true), calendar: calendar)
        let preferences = ApplicationPreferences(defaults: defaults)
        let manager = SettingsDataManager(
            backup: service, store: store, isIdle: isIdle, defaults: defaults,
            appVersion: "1", appBuild: "1", now: { [unowned self] in clock })
        return Rig(manager: manager, service: service, profiles: profiles, history: history, preferences: preferences, store: store)
    }

    private func record() throws -> BlindTestRecord {
        var session = try BlindABXSession(trialCount: 12, initialAssignment: false)
        for _ in 0..<12 {
            try session.recordXPlayback()
            try session.submit(false, nextAssignment: false)
        }
        return try XCTUnwrap(BlindTestRecords.abx(sideA: "A", sideB: "B", session: session))
    }

    func testBackupCarriesTheRemainingSettingsAndOlderBackupsStillRestore() throws {
        let r = rig()
        defaults.set(true, forKey: PreferenceKeys.Application.resumeProcessingOnOpen)
        defaults.set(true, forKey: PreferenceKeys.abComparisonEnabled)
        defaults.set(false, forKey: PreferenceKeys.vuMetersEnabled)
        let snapshot = r.preferences.makeBackupSnapshot()
        XCTAssertEqual(snapshot.resumeProcessingOnOpen, true)
        XCTAssertEqual(snapshot.abComparisonEnabled, true)
        XCTAssertEqual(snapshot.vuMetersEnabled, false)
        let data = try r.service.exportData(preferences: snapshot, appVersion: "1", appBuild: "1")

        r.manager.restoreDefaultSettings(preferences: r.preferences)
        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.Application.resumeProcessingOnOpen))
        let restored = try r.service.restore(data)
        try r.preferences.restoreBackupSnapshot(restored.preferences)
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.Application.resumeProcessingOnOpen))
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.abComparisonEnabled))
        XCTAssertEqual(defaults.object(forKey: PreferenceKeys.vuMetersEnabled) as? Bool, false)

        // A schema-1 backup from before S25 has none of the three keys and leaves the current values alone.
        let older = try r.service.exportData(
            preferences: NotchSixtyBackupPreferences(appearance: "dark", presence: "dock", volumeStepResolution: 32),
            appVersion: "1", appBuild: "1")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: older) as? [String: Any])
        let prefs = try XCTUnwrap(object["preferences"] as? [String: Any])
        XCTAssertNil(prefs["resumeProcessingOnOpen"])
        let olderRestored = try r.service.restore(older)
        try r.preferences.restoreBackupSnapshot(olderRestored.preferences)
        XCTAssertEqual(r.preferences.appearance, .dark)
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.Application.resumeProcessingOnOpen))
    }

    func testAutomaticBackupIsOnceADayOnlyWhenDataChangedAndKeepsFive() throws {
        let r = rig()
        XCTAssertNotNil(r.manager.backUpAutomaticallyIfDue(preferences: r.preferences), "the first backup is due")
        XCTAssertNotNil(r.manager.lastBackupDate)
        clock += 3_600
        r.history.append(try record())
        XCTAssertNil(r.manager.backUpAutomaticallyIfDue(preferences: r.preferences), "already one today")
        XCTAssertEqual(r.store.backups().count, 1)

        clock += 86_400
        XCTAssertNotNil(r.manager.backUpAutomaticallyIfDue(preferences: r.preferences), "next day, data changed")
        clock += 86_400
        XCTAssertNil(r.manager.backUpAutomaticallyIfDue(preferences: r.preferences), "next day, nothing changed")
        XCTAssertEqual(r.store.backups().count, 2)

        for day in 0..<8 {
            clock += 86_400
            r.preferences.showVolumePopup.toggle()
            _ = r.manager.backUpAutomaticallyIfDue(preferences: r.preferences)
            XCTAssertLessThanOrEqual(r.store.backups().count, AutomaticBackupStore.keepCount, "day \(day)")
        }
        XCTAssertEqual(r.store.backups().count, AutomaticBackupStore.keepCount)
        let newest = try XCTUnwrap(r.store.backups().first)
        XCTAssertEqual(r.manager.lastBackupDate, newest.date)
        _ = try r.service.inspect(Data(contentsOf: newest.url))
    }

    func testBackUpNowAlwaysWritesAFile() throws {
        let r = rig()
        _ = try r.manager.backUpNow(preferences: r.preferences)
        clock += 60
        _ = try r.manager.backUpNow(preferences: r.preferences)
        XCTAssertEqual(r.store.backups().count, 2)
    }

    func testRestoreDefaultSettingsLeavesSavedData() throws {
        let r = rig()
        r.history.append(try record())
        _ = r.profiles.saveCurrentContentPreset(named: "Mine")
        r.preferences.appearance = .dark
        r.preferences.presence = .tray
        defaults.set(true, forKey: PreferenceKeys.Application.resumeProcessingOnOpen)
        defaults.set("x", forKey: PreferenceKeys.Meters.scaleFloorDB)
        defaults.set("keep", forKey: PreferenceKeys.quietZoneSurveys)

        r.manager.restoreDefaultSettings(preferences: r.preferences)

        XCTAssertEqual(r.preferences.appearance, .system)
        XCTAssertEqual(r.preferences.presence, .both)
        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.Application.resumeProcessingOnOpen))
        XCTAssertNil(defaults.object(forKey: PreferenceKeys.Meters.scaleFloorDB))
        XCTAssertEqual(defaults.string(forKey: PreferenceKeys.quietZoneSurveys), "keep", "measured data is not a setting")
        XCTAssertEqual(r.history.records.count, 1)
        XCTAssertTrue(r.profiles.contentPresets.contains { $0.name == "Mine" })
    }

    func testEraseTakesABackupFirstThatTheEraseDoesNotDelete() throws {
        let r = rig()
        r.history.append(try record())
        let id = r.profiles.saveCurrentContentPreset(named: "Mine")
        r.preferences.appearance = .light
        defaults.set("keep", forKey: PreferenceKeys.quietZoneSurveys)

        XCTAssertThrowsError(try r.manager.eraseAllData(typed: "no", preferences: r.preferences)) {
            XCTAssertEqual($0 as? SettingsDataError, .confirmationMismatch)
        }
        XCTAssertTrue(r.store.preEraseBackups().isEmpty)
        XCTAssertEqual(r.history.records.count, 1, "a wrong word erases nothing")

        try r.manager.eraseAllData(typed: " erase ", preferences: r.preferences)

        XCTAssertTrue(r.history.records.isEmpty)
        XCTAssertFalse(r.profiles.contentPresets.contains { $0.id == id })
        XCTAssertEqual(r.preferences.appearance, .system)
        XCTAssertNil(defaults.object(forKey: PreferenceKeys.quietZoneSurveys))
        let pre = try XCTUnwrap(r.store.preEraseBackups().first)
        let bundle = try r.service.inspect(Data(contentsOf: pre.url))
        XCTAssertEqual(bundle.blindListeningHistory?.count, 1)
        XCTAssertTrue(bundle.profiles.contentPresets.contains { $0.id == id })

        // Automatic backups later never prune the pre-erase one.
        for _ in 0..<8 {
            clock += 86_400
            r.preferences.showVolumePopup.toggle()
            _ = r.manager.backUpAutomaticallyIfDue(preferences: r.preferences)
        }
        XCTAssertEqual(r.store.preEraseBackups().count, 1)

        // And it restores the erased data.
        _ = try r.service.restore(Data(contentsOf: pre.url))
        XCTAssertEqual(r.history.records.count, 1)
    }

    func testEraseRefusesWhileAudioRunsAndWhenTheBackupFirstFails() throws {
        let running = rig(isIdle: { false }, folder: "running")
        running.history.append(try record())
        XCTAssertThrowsError(try running.manager.eraseAllData(typed: "ERASE", preferences: running.preferences)) {
            XCTAssertEqual($0 as? SettingsDataError, .audioRunning)
        }
        XCTAssertEqual(running.history.records.count, 1)

        let r = rig(folder: "failing")
        r.history.append(try record())
        // A file where the Pre-Erase folder must go makes the backup first fail.
        try FileManager.default.createDirectory(at: r.store.directory, withIntermediateDirectories: true)
        try Data().write(to: r.store.preEraseDirectory)
        XCTAssertThrowsError(try r.manager.eraseAllData(typed: "ERASE", preferences: r.preferences))
        XCTAssertEqual(r.history.records.count, 1, "nothing is erased without its backup")
    }

    /// Settings change -> saved backup file -> restore defaults -> restore from that file: the changed setting returns.
    func testSettingsWindowFlowFromChangedSettingToRestoredBackup() throws {
        let r = rig()
        r.preferences.volumePopupPosition = .topRight
        defaults.set(true, forKey: PreferenceKeys.Application.resumeProcessingOnOpen)
        let file = try r.manager.backUpNow(preferences: r.preferences)

        r.manager.restoreDefaultSettings(preferences: r.preferences)
        XCTAssertEqual(r.preferences.volumePopupPosition, .bottomCenter)

        let restored = try r.service.restore(Data(contentsOf: file))
        try r.preferences.restoreBackupSnapshot(restored.preferences)
        XCTAssertEqual(r.preferences.volumePopupPosition, .topRight)
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.Application.resumeProcessingOnOpen))
    }

    // MARK: G99 layout

    func testEveryTabFitsTheMinimumAndTheTwoCheckedWindowWidths() throws {
        let engine = AudioIOEngine()
        let product = ProductController(audioEngine: engine)
        let flags = FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .storedOverrides, arguments: [], environment: [:])
        flags.setEnabled(true, for: .settingsPage)
        let preferences = ApplicationPreferences(defaults: defaults)
        let view = ProductionSettingsView(preferences: preferences, product: product, featureFlags: flags)
        // 520 is the window's minimum; 1,280 x 800 and 1,920 x 1,000 are the screen-fit sizes (AGENTS.md 13).
        for (width, height) in [(520.0, 900.0), (1_280.0, 800.0), (1_920.0, 1_000.0)] {
            for tab in SettingsTab.allCases {
                let page = HostedPage(view.tabCards(tab).padding(18), size: CGSize(width: width, height: height))
                for control in page.controls {
                    let frame = control.view.convert(control.view.bounds, to: page.hosting)
                    XCTAssertLessThanOrEqual(frame.maxX, width + 0.5, "\(tab.title): \(control.searchText) at \(width)")
                }
            }
        }
    }
}
