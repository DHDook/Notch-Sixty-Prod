import AppKit
import Foundation
import UserNotifications

/// E15 S3b (design note 13): macOS notifications for Follow macOS output. Local notifications only; nothing here is
/// reachable from the realtime path, the engine or the transport. Posted on the main actor after the coordinator's
/// transaction has finished. Device and profile names stay on the Mac.

enum FollowNotificationAuthorization: Equatable, Sendable {
    case notDetermined, authorized, denied
}

/// One notification's content. Every delivery uses the one identifier, so a newer notice replaces an older one.
struct FollowNotice: Equatable, Sendable {
    static let identifier = "e15.output-follow"

    var title: String
    var body: String
    /// A pause notice opens the "Choose…" sheet when clicked.
    var isPause: Bool

    init(_ note: OutputFollowAnnouncement) {
        isPause = note.isPause
        switch note.kind {
        case .switched(let profile):
            title = "Now on \(note.device)"
            body = [profile, note.disarmLine].compactMap { $0 }.joined(separator: ". ")
        case .paused:
            title = "Processing paused on \(note.device): no Playback System"
            body = note.disarmLine ?? "Choose a Playback System for this output."
        case .failed(let message):
            title = "Could not move to \(note.device)"
            body = message
        }
    }
}

@MainActor
protocol FollowNotifier: AnyObject {
    /// Called when the user clicks a delivered notice; the flag is `FollowNotice.isPause`.
    var onResponse: ((Bool) -> Void)? { get set }
    func authorizationStatus() async -> FollowNotificationAuthorization
    /// Asks macOS once (`.alert` only: no sound, no badge) and returns the resulting state.
    func requestAuthorization() async -> FollowNotificationAuthorization
    func deliver(_ notice: FollowNotice)
    /// Opens System Settings, Notifications. Notch Sixty never changes the setting itself.
    func openSystemSettings()
}

/// Production notifier over `UNUserNotificationCenter`. It touches the center only when asked, so building it in a
/// test host costs nothing; `installResponseHandling()` is the one launch-time call.
@MainActor
final class UserNotificationFollowNotifier: NSObject, FollowNotifier, UNUserNotificationCenterDelegate {
    var onResponse: ((Bool) -> Void)?
    private var center: UNUserNotificationCenter { .current() }

    func installResponseHandling() { center.delegate = self }

    func authorizationStatus() async -> FollowNotificationAuthorization {
        Self.map(await center.notificationSettings().authorizationStatus)
    }

    func requestAuthorization() async -> FollowNotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorizationStatus()
    }

    func deliver(_ notice: FollowNotice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.userInfo = ["pause": notice.isPause]
        let request = UNNotificationRequest(identifier: FollowNotice.identifier, content: content, trigger: nil)
        center.add(request) { _ in }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let isPause = response.notification.request.content.userInfo["pause"] as? Bool ?? false
        await MainActor.run { onResponse?(isPause) }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    static func map(_ status: UNAuthorizationStatus) -> FollowNotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .denied
        }
    }
}

/// Permission, coalescing and delivery. One notice per settled switch: the first switch opens a window, later
/// switches inside it replace the pending notice, and the final device and profile are delivered when it ends.
@MainActor
final class FollowNotificationController: ObservableObject {
    static let promptedKey = "e15.followNotificationsPrompted"
    static let window: TimeInterval = 5

    @Published private(set) var authorization: FollowNotificationAuthorization = .notDetermined

    private let notifier: any FollowNotifier
    private let scheduler: any FollowScheduling
    private let defaults: UserDefaults
    /// True only while the flag and the mode are both on.
    private let isActive: @MainActor () -> Bool
    private var pending: FollowNotice?
    private var timer: FollowTimerToken?
    /// The latest permission task, so tests can await it.
    private(set) var permissionTask: Task<Void, Never>?
    /// A clicked pause notice asks the coordinator to show the "Choose…" sheet again.
    var onPauseResponse: (() -> Void)?

    init(
        notifier: any FollowNotifier,
        scheduler: any FollowScheduling = DispatchFollowScheduler(),
        defaults: UserDefaults = .standard,
        isActive: @escaping @MainActor () -> Bool
    ) {
        self.notifier = notifier
        self.scheduler = scheduler
        self.defaults = defaults
        self.isActive = isActive
        notifier.onResponse = { [weak self] isPause in
            NSApp.activate()
            if isPause { self?.onPauseResponse?() }
        }
    }

    /// Settings shows the "notifications are off" row while following and macOS is not allowing them.
    var needsAttention: Bool { isActive() && authorization != .authorized }

    func openSystemSettings() { notifier.openSystemSettings() }

    /// The user turned Follow macOS output on (or off): ask once, on the first enable only.
    func followingChanged(_ on: Bool) {
        guard on else { cancelPending(); return }
        permissionTask = Task { await self.requestIfFirstEnable() }
    }

    func requestIfFirstEnable() async {
        await refreshAuthorization()
        guard authorization == .notDetermined, !defaults.bool(forKey: Self.promptedKey) else { return }
        defaults.set(true, forKey: Self.promptedKey)
        authorization = await notifier.requestAuthorization()
    }

    /// At launch (while following) and every time the app becomes active.
    func refreshAuthorization() async { authorization = await notifier.authorizationStatus() }

    func refreshInBackground() {
        guard isActive() else { return }
        permissionTask = Task { await self.refreshAuthorization() }
    }

    func announce(_ note: OutputFollowAnnouncement) {
        guard isActive() else { return }
        pending = FollowNotice(note)
        if timer == nil {
            timer = scheduler.schedule(after: Self.window) { [weak self] in self?.flush() }
        }
    }

    private func flush() {
        timer = nil
        guard let notice = pending else { return }
        pending = nil
        if isActive(), authorization == .authorized { notifier.deliver(notice) }
    }

    private func cancelPending() {
        timer?.cancel()
        timer = nil
        pending = nil
    }
}
