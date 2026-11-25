import XCTest
@testable import NotchSixty

/// E15 S3b: permission, coalescing, delivery and response routing with a fake notifier and clock. Real
/// UserNotifications delivery and the permission prompt cannot run in XCTest (ledger G1; bench in E22).
@MainActor
final class FollowNotificationTests: XCTestCase {
    private final class FakeNotifier: FollowNotifier {
        var onResponse: ((Bool) -> Void)?
        var status: FollowNotificationAuthorization = .notDetermined
        var grant = true
        var requests = 0
        var delivered: [FollowNotice] = []
        var openedSettings = 0
        func authorizationStatus() async -> FollowNotificationAuthorization { status }
        func requestAuthorization() async -> FollowNotificationAuthorization {
            requests += 1
            status = grant ? .authorized : .denied
            return status
        }
        func deliver(_ notice: FollowNotice) { delivered.append(notice) }
        func openSystemSettings() { openedSettings += 1 }
    }

    private final class Clock: FollowScheduling, @unchecked Sendable {
        private var now: TimeInterval = 0
        private var tasks: [(due: TimeInterval, block: @MainActor () -> Void, live: Flag)] = []
        final class Flag { var on = true }
        func schedule(after delay: TimeInterval, _ block: @escaping @MainActor () -> Void) -> FollowTimerToken {
            let flag = Flag()
            tasks.append((now + delay, block, flag))
            return FollowTimerToken { flag.on = false }
        }
        @MainActor func advance(_ seconds: TimeInterval) {
            let target = now + seconds
            while let next = tasks.filter({ $0.live.on && $0.due <= target }).min(by: { $0.due < $1.due }) {
                now = max(now, next.due)
                next.live.on = false
                next.block()
            }
            now = target
        }
    }

    private var suites: [String] = []
    private var active = true

    private func make() -> (FollowNotificationController, FakeNotifier, Clock, UserDefaults) {
        let suite = "e15.s3b.\(UUID().uuidString)"
        suites.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        let notifier = FakeNotifier()
        let clock = Clock()
        active = true
        let controller = FollowNotificationController(
            notifier: notifier, scheduler: clock, defaults: defaults, isActive: { [unowned self] in self.active })
        return (controller, notifier, clock, defaults)
    }

    override func tearDown() async throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func switched(_ device: String, profile: String = "Desk", disarmed: [String] = []) -> OutputFollowAnnouncement {
        OutputFollowAnnouncement(device: device, kind: .switched(profile: profile), disarmed: disarmed)
    }

    private func paused(_ device: String) -> OutputFollowAnnouncement {
        OutputFollowAnnouncement(device: device, kind: .paused(.noBinding), disarmed: [])
    }

    func testPermissionAskedOnceOnFirstEnableNeverAtConstruction() async {
        let (c, n, _, _) = make()
        XCTAssertEqual(n.requests, 0, "never at launch")
        c.followingChanged(true)
        await c.permissionTask?.value
        XCTAssertEqual(n.requests, 1)
        XCTAssertEqual(c.authorization, .authorized)
        c.followingChanged(false)
        c.followingChanged(true)
        await c.permissionTask?.value
        XCTAssertEqual(n.requests, 1, "asked once only")
    }

    func testNeverAsksAgainAfterDenial() async {
        let (c, n, _, defaults) = make()
        n.grant = false
        c.followingChanged(true)
        await c.permissionTask?.value
        XCTAssertEqual(c.authorization, .denied)
        defaults.removeObject(forKey: FollowNotificationController.promptedKey)
        c.followingChanged(true)
        await c.permissionTask?.value
        XCTAssertEqual(n.requests, 1, "a denied state is never asked again")
        XCTAssertTrue(c.needsAttention)
    }

    func testRefreshOnActivationReadsTheCurrentState() async {
        let (c, n, _, _) = make()
        n.status = .denied
        await c.refreshAuthorization()
        XCTAssertEqual(c.authorization, .denied)
        n.status = .authorized
        c.refreshInBackground()
        await c.permissionTask?.value
        XCTAssertEqual(c.authorization, .authorized)
        XCTAssertFalse(c.needsAttention)
    }

    func testDeniedAndNotDeterminedDeliverNothing() async {
        for status in [FollowNotificationAuthorization.denied, .notDetermined] {
            let (c, n, clock, _) = make()
            n.status = status
            await c.refreshAuthorization()
            c.announce(switched("A"))
            clock.advance(6)
            XCTAssertTrue(n.delivered.isEmpty)
            XCTAssertTrue(c.needsAttention)
        }
    }

    func testTenSwitchesInTwoSecondsDeliverOneWithTheLastDevice() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        for i in 0..<10 {
            c.announce(switched("Dev\(i)", profile: "Profile\(i)"))
            clock.advance(0.2)
        }
        clock.advance(10)
        XCTAssertEqual(n.delivered.count, 1)
        XCTAssertEqual(n.delivered.first?.title, "Now on Dev9")
        XCTAssertEqual(n.delivered.first?.body, "Profile9")
        XCTAssertEqual(FollowNotice.identifier, "e15.output-follow")
    }

    func testSwitchesSixSecondsApartDeliverTwo() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        c.announce(switched("A"))
        clock.advance(6)
        c.announce(switched("B"))
        clock.advance(6)
        XCTAssertEqual(n.delivered.map(\.title), ["Now on A", "Now on B"])
    }

    func testDisarmLineAppearsInTheBody() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        c.announce(switched("A", disarmed: ["Quiet Zone"]))
        clock.advance(6)
        XCTAssertEqual(n.delivered.first?.body, "Desk. Quiet Zone disarmed: output changed")
    }

    func testPauseNoticeTextAndResponseRoutesToTheSheet() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        var routed = 0
        c.onPauseResponse = { routed += 1 }
        c.announce(paused("Speakers"))
        clock.advance(6)
        XCTAssertEqual(n.delivered.first?.title, "Processing paused on Speakers: no Playback System")
        XCTAssertEqual(n.delivered.first?.isPause, true)
        n.onResponse?(false)
        XCTAssertEqual(routed, 0, "a switch notice only brings the app forward")
        n.onResponse?(true)
        XCTAssertEqual(routed, 1)
    }

    func testNothingIsSentWhenFollowModeOrFlagIsOff() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        active = false
        c.announce(switched("A"))
        c.refreshInBackground()
        clock.advance(10)
        XCTAssertTrue(n.delivered.isEmpty)
        XCTAssertFalse(c.needsAttention)
    }

    func testTurningFollowOffCancelsAPendingNotice() async {
        let (c, n, clock, _) = make()
        n.status = .authorized
        await c.refreshAuthorization()
        c.announce(switched("A"))
        c.followingChanged(false)
        clock.advance(10)
        XCTAssertTrue(n.delivered.isEmpty)
    }

    func testCoordinatorFeedsTheControllerAndReopensThePauseSheet() async {
        let n = FakeNotifier()
        n.status = .authorized
        let clock = Clock()
        let defaults = UserDefaults(suiteName: "e15.s3b.coord.\(UUID().uuidString)")!
        let coordinator = OutputFollowCoordinator(
            engine: StubEngine(), profiles: StubProfiles(), treatments: StubDisarmer(), source: StubSource(),
            defaults: defaults, flagEnabled: { true })
        let c = FollowNotificationController(
            notifier: n, scheduler: clock, defaults: defaults, isActive: { coordinator.isFollowing })
        coordinator.notifications = c
        coordinator.setFollowing(true)
        await c.permissionTask?.value
        XCTAssertEqual(c.authorization, .authorized)
        n.onResponse?(true)
        XCTAssertNil(coordinator.announcement, "nothing is paused, so no sheet opens")
        coordinator.setFollowing(false)
        XCTAssertFalse(c.needsAttention)
    }

    @MainActor private final class StubEngine: OutputFollowSwitching {
        var selectedOutputUID: String? = "a"
        var isFailed = false
        func switchFollowedOutput(to uid: String, resume: Bool, prepare: () throws -> Void) throws {}
    }

    @MainActor private final class StubProfiles: OutputFollowProfiles {
        var outputBindings = OutputProfileBindings()
        var systemProfileIDs: Set<UUID> = []
        var systemProfileIDsNeedingMapping: Set<UUID> = []
        func systemProfileName(for id: UUID) -> String? { nil }
        func applyBoundSystem(_ id: UUID) throws {}
        func seedOutputBindingsFromAssociations() -> [String] { [] }
        func useSelectedSystem(for key: OutputKey) {}
        func unbindOutput(_ key: OutputKey) {}
    }

    @MainActor private final class StubDisarmer: OutputFollowTreatmentDisarming {
        func disarmAllForOutputFollow() -> [String] { [] }
    }

    private final class StubSource: FollowOutputEventSource {
        var onDefaultOutputChanged: ((OutputFollowTarget?) -> Void)?
        var onDataSourceChanged: ((OutputFollowTarget) -> Void)?
        var onDeviceListChanged: (() -> Void)?
        var onWillSleep: (() -> Void)?
        var onDidWake: (() -> Void)?
        func start() throws {}
        func stop() {}
        func monitorDataSource(ofDeviceUID uid: String?) {}
        func currentDefaultTarget() -> OutputFollowTarget? { nil }
        func dataSourceID(forDeviceUID uid: String) -> UInt32? { nil }
        func availableOutputUIDs() -> Set<String> { [] }
        func ownDeviceUIDs() -> Set<String> { [] }
    }
}
