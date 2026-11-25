import XCTest
@testable import NotchSixty

@MainActor
private final class FakeResumeTarget: ResumeTarget {
    var isProcessingRunning = false
    var selectedOutputUID: String? = "dac-1"
    var availableOutputUIDs: Set<String> = ["dac-1"]
    var startCount = 0
    var startError: Error?
    /// What `LiveTreatmentArm` reads after a start; resume must leave it off.
    let arms = LiveTreatmentFeature.allCases.map { LiveTreatmentArm(feature: $0) }

    func startProcessing() async throws {
        startCount += 1
        if let startError { throw startError }
        isProcessingRunning = true
    }
}

@MainActor
final class ResumeAndPermissionsTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    typealias K = PreferenceKeys.Application

    override func setUp() async throws {
        suiteName = "ResumeAndPermissionsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Runs one launch and, when `quitRunning` is non-nil, a clean quit with that running state.
    private func launch(
        target: FakeResumeTarget? = nil, switchOn: Bool = true, flag: Bool = true
    ) async -> (ResumeProcessingCoordinator, FakeResumeTarget) {
        let target = target ?? FakeResumeTarget()
        defaults.set(switchOn, forKey: K.resumeProcessingOnOpen)
        let coordinator = ResumeProcessingCoordinator(defaults: defaults)
        await coordinator.resumeIfNeeded(target: target, flagEnabled: flag)
        return (coordinator, target)
    }

    private func cleanRunningSession() async {
        let (c, t) = await launch()
        t.isProcessingRunning = true
        c.recordCleanQuit(target: t)
    }

    func testSwitchIsOffByDefault() {
        XCTAssertFalse(defaults.bool(forKey: K.resumeProcessingOnOpen))
    }

    func testResumesWhenRunningAtCleanQuitWithSameDevice() async {
        await cleanRunningSession()
        let (coordinator, target) = await launch()
        XCTAssertEqual(target.startCount, 1)
        XCTAssertNil(coordinator.skippedReason)
    }

    func testDoesNotResumeWhenSwitchOff() async {
        await cleanRunningSession()
        let (coordinator, target) = await launch(switchOn: false)
        XCTAssertEqual(target.startCount, 0)
        XCTAssertNil(coordinator.skippedReason)
    }

    func testDoesNotResumeWhenItWasStoppedAtQuit() async {
        let (c, t) = await launch()
        t.isProcessingRunning = false
        c.recordCleanQuit(target: t)
        let (coordinator, target) = await launch()
        XCTAssertEqual(target.startCount, 0)
        XCTAssertNil(coordinator.skippedReason)
    }

    func testDeviceMissingStaysStoppedAndSaysWhy() async {
        await cleanRunningSession()
        let missing = FakeResumeTarget()
        missing.availableOutputUIDs = []
        let (coordinator, target) = await launch(target: missing)
        XCTAssertEqual(target.startCount, 0)
        XCTAssertEqual(coordinator.skippedReason, .outputMissing)
    }

    func testDifferentSelectedDeviceStaysStopped() async {
        await cleanRunningSession()
        let other = FakeResumeTarget()
        other.selectedOutputUID = "dac-2"
        other.availableOutputUIDs = ["dac-1", "dac-2"]
        let (coordinator, target) = await launch(target: other)
        XCTAssertEqual(target.startCount, 0)
        XCTAssertEqual(coordinator.skippedReason, .outputMissing)
    }

    func testUncleanLastExitNeverResumesAndDoesNotLoop() async {
        await cleanRunningSession()
        // This session starts (resumes) and then crashes: no recordCleanQuit.
        let (_, first) = await launch()
        XCTAssertEqual(first.startCount, 1)
        let (coordinator, second) = await launch()
        XCTAssertEqual(second.startCount, 0)
        XCTAssertEqual(coordinator.skippedReason, .lastExitUnclean)
        // Still not a resume until a clean quit while running happens again.
        let (_, third) = await launch()
        XCTAssertEqual(third.startCount, 0)
    }

    func testResumeLeavesEveryArmOff() async {
        await cleanRunningSession()
        let (_, target) = await launch()
        XCTAssertEqual(target.startCount, 1)
        XCTAssertTrue(target.arms.allSatisfy { !$0.isArmed })
        // Nothing about arming is persisted by resume.
        XCTAssertFalse(defaults.dictionaryRepresentation().keys.contains { $0.lowercased().contains("arm") })
    }

    func testStartFailureIsReportedNotRetried() async {
        await cleanRunningSession()
        let failing = FakeResumeTarget()
        failing.startError = ProductRecoveryError.safeLaunchDecisionRequired
        let (coordinator, target) = await launch(target: failing)
        XCTAssertEqual(target.startCount, 1)
        guard case .startFailed = coordinator.skippedReason else { return XCTFail("expected startFailed") }
    }

    func testFlagOffTouchesNothing() async {
        let (coordinator, target) = await launch(flag: false)
        XCTAssertEqual(target.startCount, 0)
        coordinator.recordCleanQuit(target: target)
        XCTAssertNil(defaults.object(forKey: K.resumeSessionOpen))
        XCTAssertNil(defaults.object(forKey: K.resumeRunningAtCleanQuit))
    }

    func testResumeOnlyOncePerLaunch() async {
        await cleanRunningSession()
        let (coordinator, target) = await launch()
        target.isProcessingRunning = false
        await coordinator.resumeIfNeeded(target: target, flagEnabled: true)
        XCTAssertEqual(target.startCount, 1)
    }

    func testDashboardShowsTheReasonUntilRunning() {
        var inputs = DashboardInputs()
        inputs.resumeNote = ResumeSkipReason.outputMissing.message
        XCTAssertEqual(DashboardModel.attention(inputs).map(\.kind), [.resumeSkipped])
        inputs.lifecycle = .running
        XCTAssertTrue(DashboardModel.attention(inputs).isEmpty)
    }

    // MARK: Permissions

    private struct FakeReader: PermissionStatusReading {
        var states: [PermissionKind: PermissionState]
        func state(for kind: PermissionKind) -> PermissionState { states[kind] ?? .unknown }
    }

    func testPermissionStateMapping() {
        XCTAssertEqual(PermissionState(.authorized), .granted)
        XCTAssertEqual(PermissionState(.denied), .denied)
        XCTAssertEqual(PermissionState(.restricted), .denied)
        XCTAssertEqual(PermissionState(.notDetermined), .notAskedYet)
        XCTAssertEqual(PermissionState(video: .authorized), .granted)
        XCTAssertEqual(PermissionState(video: .notDetermined), .notAskedYet)
        XCTAssertEqual(PermissionState(video: .denied), .denied)
    }

    func testModelShowsStatusRefreshesAndOpensTheRightPane() {
        var opened: [URL] = []
        var reader = FakeReader(states: [.microphone: .denied, .camera: .notAskedYet, .systemAudio: .unknown])
        let model = PermissionStatusModel(reader: reader, openURL: { opened.append($0) })
        XCTAssertEqual(model.state(.microphone), .denied)
        XCTAssertEqual(model.state(.camera).label, "Not asked yet")
        reader.states[.microphone] = .granted
        // A new model stands in for a refresh with a changed system state.
        let refreshed = PermissionStatusModel(reader: reader, openURL: { opened.append($0) })
        XCTAssertEqual(refreshed.state(.microphone).label, "Allowed")
        refreshed.openSystemSettings(for: .microphone)
        refreshed.openSystemSettings(for: .camera)
        refreshed.openSystemSettings(for: .systemAudio)
        XCTAssertEqual(opened.map(\.absoluteString), [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ])
    }

    func testSystemAudioReadsAllowedOnlyAfterProcessingRan() async {
        let reader = SystemPermissionStatusReader(defaults: defaults)
        XCTAssertEqual(reader.state(for: .systemAudio), .unknown)
        let coordinator = ResumeProcessingCoordinator(defaults: defaults)
        let target = FakeResumeTarget()
        coordinator.noteProcessingRan(target: target)
        XCTAssertEqual(reader.state(for: .systemAudio), .unknown)
        target.isProcessingRunning = true
        coordinator.noteProcessingRan(target: target)
        XCTAssertEqual(reader.state(for: .systemAudio), .granted)
    }
}
