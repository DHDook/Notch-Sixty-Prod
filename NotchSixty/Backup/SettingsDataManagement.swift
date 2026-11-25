import Combine
import Foundation

// E12 S25 (behind `e12.settings-page`): automatic backups, restore default settings and erase all data.
// Swift only; the engine never reads any of this. Nothing here starts, stops or arms audio: an erase needs the
// engine idle, and a restore of defaults changes preferences only.

/// The automatic backup folder: at most one backup a day, on days when saved data changed, the last five kept.
/// Backups made just before an erase live in `Pre-Erase`, which is never pruned and never erased.
struct AutomaticBackupStore: Sendable {
    static let keepCount = 5
    static let fileExtension = "n60backup"

    let directory: URL
    var calendar: Calendar = .current

    var preEraseDirectory: URL { directory.appendingPathComponent("Pre-Erase", isDirectory: true) }

    static func standard() -> AutomaticBackupStore {
        let base = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return AutomaticBackupStore(
            directory: base.appendingPathComponent("NotchSixty", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true))
    }

    private static func stamp() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    private func fileName(_ prefix: String, _ date: Date) -> String {
        "\(prefix)-\(Self.stamp().string(from: date)).\(Self.fileExtension)"
    }

    private func date(of url: URL) -> Date? {
        // The stamp is the last 15 characters: yyyyMMdd-HHmmss.
        let name = url.deletingPathExtension().lastPathComponent
        guard name.count > 15 else { return nil }
        return Self.stamp().date(from: String(name.suffix(15)))
    }

    /// Backups in the folder, newest first.
    func backups() -> [(url: URL, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in date(of: url).map { (url, $0) } }
            .sorted { $0.date > $1.date }
    }

    func preEraseBackups() -> [(url: URL, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: preEraseDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return urls
            .filter { $0.pathExtension == Self.fileExtension }
            .compactMap { url in date(of: url).map { (url, $0) } }
            .sorted { $0.date > $1.date }
    }

    /// The newest backup of either kind.
    func lastBackupDate() -> Date? {
        [backups().first?.date, preEraseBackups().first?.date].compactMap { $0 }.max()
    }

    /// True when no backup was made today.
    func isDue(now: Date) -> Bool {
        guard let last = backups().first?.date else { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    /// The per-domain checksums of the newest backup, so an unchanged day makes no new file.
    func lastSignature() -> [String: String]? {
        guard let newest = backups().first, let data = try? Data(contentsOf: newest.url) else { return nil }
        return Self.signature(of: data)
    }

    static func signature(of data: Data) -> [String: String]? {
        struct Header: Decodable { var manifest: NotchSixtyBackupManifest }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else { return nil }
        return Dictionary(uniqueKeysWithValues: header.manifest.entries.map { ($0.domain, $0.sha256) })
    }

    @discardableResult
    func write(_ data: Data, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName("Backup", now))
        try data.write(to: url, options: .atomic)
        prune()
        return url
    }

    @discardableResult
    func writePreErase(_ data: Data, now: Date) throws -> URL {
        try FileManager.default.createDirectory(at: preEraseDirectory, withIntermediateDirectories: true)
        let url = preEraseDirectory.appendingPathComponent(fileName("Before-Erase", now))
        try data.write(to: url, options: .atomic)
        return url
    }

    func prune() {
        for old in backups().dropFirst(Self.keepCount) { try? FileManager.default.removeItem(at: old.url) }
    }
}

/// Every stored setting that "Restore default settings" returns to its first-launch value. Presets, systems,
/// measurements and the Quiet Zone's measured data are not settings and are not listed.
enum SettingsPreferenceKeys {
    static var keys: [String] {
        typealias A = PreferenceKeys.Application
        return [
            A.appearance, A.presence, A.volumeStepResolution, A.showVolumeInMenuBar, A.showVolumePopup,
            A.volumePopupPosition, A.coverSystemVolumePopup, A.resumeProcessingOnOpen,
            PreferenceKeys.abComparisonEnabled, PreferenceKeys.vuMetersEnabled,
        ] + PageDisplayPreferences.keys
    }

    /// Saved with the data and removed by an erase as well.
    static var measuredDataKeys: [String] {
        [
            PreferenceKeys.quietZoneMeasuredLatency, PreferenceKeys.quietZoneEarnedCaps,
            PreferenceKeys.quietZoneSurveys, PreferenceKeys.quietZoneFeedForwardReferenceChannel,
        ]
    }
}

enum SettingsDataError: Error, LocalizedError, Equatable {
    case audioRunning
    case confirmationMismatch
    case backupFirstFailed(String)

    var errorDescription: String? {
        switch self {
        case .audioRunning: return "Stop audio processing first."
        case .confirmationMismatch: return "The word you typed does not match, so nothing was erased."
        case .backupFirstFailed(let reason):
            return "Nothing was erased because the backup made first failed: \(reason)"
        }
    }
}

/// What the Data tab does: back up now, automatic backups, restore default settings, erase all data.
@MainActor
final class SettingsDataManager: ObservableObject {
    static let eraseConfirmationWord = "ERASE"

    @Published private(set) var lastBackupDate: Date?

    private let backup: NotchSixtyBackupService
    let store: AutomaticBackupStore
    private let isIdle: () -> Bool
    private let defaults: UserDefaults
    private let now: () -> Date
    private let appVersion: String
    private let appBuild: String
    /// Clears state that was built from the saved data (A/B snapshots, open Room Correction project, analyser).
    private let afterDataChange: () -> Void

    init(
        backup: NotchSixtyBackupService,
        store: AutomaticBackupStore = .standard(),
        isIdle: @escaping () -> Bool,
        defaults: UserDefaults = .standard,
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
        appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
        now: @escaping () -> Date = Date.init,
        afterDataChange: @escaping () -> Void = {}
    ) {
        self.backup = backup
        self.store = store
        self.isIdle = isIdle
        self.defaults = defaults
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.now = now
        self.afterDataChange = afterDataChange
        lastBackupDate = store.lastBackupDate()
    }

    private func export(_ preferences: ApplicationPreferences) throws -> Data {
        try backup.exportData(
            preferences: preferences.makeBackupSnapshot(), appVersion: appVersion, appBuild: appBuild, createdAt: now())
    }

    /// At most one a day, and only when the saved data differs from the newest backup. Returns the new file.
    @discardableResult
    func backUpAutomaticallyIfDue(preferences: ApplicationPreferences) -> URL? {
        let moment = now()
        guard store.isDue(now: moment), let data = try? export(preferences) else { return nil }
        if let last = store.lastSignature(), last == AutomaticBackupStore.signature(of: data) { return nil }
        let url = try? store.write(data, now: moment)
        lastBackupDate = store.lastBackupDate()
        return url
    }

    /// "Back up now": always writes a file (the same folder, so the last five rule still holds).
    @discardableResult
    func backUpNow(preferences: ApplicationPreferences) throws -> URL {
        let url = try store.write(try export(preferences), now: now())
        lastBackupDate = store.lastBackupDate()
        return url
    }

    /// Preferences only. Presets, systems, measurements and backups are not touched.
    func restoreDefaultSettings(preferences: ApplicationPreferences) {
        preferences.restoreDefaultSettings()
        for key in SettingsPreferenceKeys.keys { defaults.removeObject(forKey: key) }
        afterDataChange()
    }

    /// Removes presets, systems, measurements, history and settings after a typed confirmation, with audio stopped.
    /// A backup is taken first into `Pre-Erase`; if it cannot be written nothing is erased.
    func eraseAllData(typed: String, preferences: ApplicationPreferences) throws {
        guard isIdle() else { throw SettingsDataError.audioRunning }
        guard typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == Self.eraseConfirmationWord else {
            throw SettingsDataError.confirmationMismatch
        }
        do {
            try store.writePreErase(try export(preferences), now: now())
        } catch {
            throw SettingsDataError.backupFirstFailed(error.localizedDescription)
        }
        try backup.eraseAllSavedData()
        preferences.restoreDefaultSettings()
        for key in SettingsPreferenceKeys.keys + SettingsPreferenceKeys.measuredDataKeys {
            defaults.removeObject(forKey: key)
        }
        afterDataChange()
        lastBackupDate = store.lastBackupDate()
    }
}
