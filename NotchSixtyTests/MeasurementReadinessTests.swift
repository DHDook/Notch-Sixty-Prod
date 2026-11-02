import XCTest
@testable import NotchSixty

/// E24 S2: the shared readiness table and the one playback policy.
@MainActor
final class MeasurementReadinessTests: XCTestCase {
    private func ready() -> MeasurementReadiness.Inputs {
        .init(permission: .authorized, hasInputDevice: true, hasOutputDevice: true)
    }

    func testReadyWhenEverythingIsPresent() {
        XCTAssertEqual(MeasurementReadiness.evaluate(ready()), .ready)
    }

    func testEveryBlockingInputGivesAReasonAndTheRightFix() {
        var cases: [(String, MeasurementReadiness.Inputs, MeasurementReadiness.Fix?)] = []
        var i = ready(); i.permission = .notDetermined; cases.append(("notDetermined", i, .grantMicrophoneAccess))
        i = ready(); i.permission = .denied; cases.append(("denied", i, .openSystemSettings))
        i = ready(); i.permission = .restricted; cases.append(("restricted", i, nil))
        i = ready(); i.hasInputDevice = false; cases.append(("no input", i, .selectMicrophone))
        i = ready(); i.hasOutputDevice = false; cases.append(("no output", i, .selectOutput))
        i = ready(); i.requiresProfile = true; i.hasProfile = false; cases.append(("no profile", i, .describeSpeakers))
        i = ready(); i.requiresWork = true; i.hasWork = false; cases.append(("no work", i, .startSession))
        i = ready(); i.stateAllowsStart = false; cases.append(("state", i, nil))
        i = ready(); i.transportActive = true; cases.append(("transport", i, nil))
        i = ready(); i.busyDescription = "measuring"; cases.append(("busy", i, nil))
        for (name, inputs, fix) in cases {
            let result = MeasurementReadiness.evaluate(inputs)
            XCTAssertFalse(result.isReady, name)
            XCTAssertFalse((result.reason ?? "").isEmpty, name)
            XCTAssertEqual(result.fix, fix, name)
        }
    }

    func testTimelineOverTheMemoryBudgetIsBlockedWithAReason() {
        let big = RoomCorrectionSweepSettings(sampleRate: 384_000, durationSeconds: 20, repeatCount: 8)
        var inputs = ready(); inputs.timelineBytes = MeasurementReadiness.timelineBytes(for: big)
        let result = MeasurementReadiness.evaluate(inputs)
        XCTAssertFalse(result.isReady)
        XCTAssertTrue(result.reason?.contains("fewer repeats") ?? false)

        let usual = RoomCorrectionSweepSettings(sampleRate: 384_000, durationSeconds: 5, repeatCount: 3)
        inputs.timelineBytes = MeasurementReadiness.timelineBytes(for: usual)
        XCTAssertTrue(MeasurementReadiness.evaluate(inputs).isReady)
    }

    func testRunningPlaybackIsNeverABlocker() {
        // There is no playback input at all: the policy stops it instead.
        XCTAssertTrue(MeasurementReadiness.evaluate(ready()).isReady)
    }

    func testPolicyStopsRunningPlaybackAndReturnsTheNotice() {
        var stops = 0
        let notice = MeasurementPlaybackPolicy.stopPlaybackIfRunning(isRunning: true) { stops += 1 }
        XCTAssertEqual(stops, 1)
        XCTAssertEqual(notice, MeasurementPlaybackPolicy.stoppedNotice)
        let none = MeasurementPlaybackPolicy.stopPlaybackIfRunning(isRunning: false) { stops += 1 }
        XCTAssertEqual(stops, 1)
        XCTAssertNil(none)
    }

    func testRoomCorrectionAndCampaignReportReasonsInsteadOfThrowingOnPlayback() throws {
        let rig = try OfflineSetupRig(rate: 48_000, permission: .denied)
        defer { rig.tearDown() }
        try rig.installTwoPointOneProfile()
        rig.microphone.prepareForUse()
        rig.calibration.prepareForUse()
        XCTAssertEqual(rig.microphone.readiness.fix, .openSystemSettings)
        XCTAssertFalse(rig.microphone.canBeginMeasurement)
        XCTAssertEqual(rig.calibration.readiness.fix, .openSystemSettings)
        XCTAssertFalse(rig.calibration.canMeasure)
    }

    func testCampaignIsReadyWithPermissionAndAnIdleEngineAndSetsNoNotice() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try rig.installTwoPointOneProfile()
        rig.calibration.prepareForUse()
        XCTAssertEqual(rig.calibration.readiness, .ready)
        XCTAssertNil(rig.calibration.playbackNotice)
        try rig.calibration.beginNextMeasurement()
        XCTAssertNil(rig.calibration.playbackNotice, "idle engine: nothing to stop, nothing to announce")
        rig.calibration.cancelMeasurement()
    }
}
