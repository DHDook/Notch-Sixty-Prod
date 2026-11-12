import AppKit
import XCTest
@testable import NotchSixty

/// E4 S26b: head follow through production wiring (`QuietZoneFlagWiring`, the survey controller and the real
/// `ActiveQuietZoneController` design) with a fake pose source in place of the camera, at the eight device rates.
/// The camera source itself needs a Mac camera and is a bench check (E22).
@MainActor
extension QuietZoneVirtualMicWiringTests {
    final class FakeHeadSource: QuietZoneHeadPoseSourcing {
        var starts = 0
        var stops = 0
        var failure: Error?
        let onPose: @Sendable (QuietZoneHeadPose) -> Void
        init(onPose: @escaping @Sendable (QuietZoneHeadPose) -> Void) { self.onPose = onPose }
        func start() async throws {
            if let failure { throw failure }
            starts += 1
        }
        func stop() { stops += 1 }
        func emit(_ x: Double, _ y: Double = 0, _ z: Double = 0, confidence: Double = 0.9) {
            onPose(QuietZoneHeadPose(x: x, y: y, z: z, confidence: confidence, time: 0))
        }
    }

    final class HeadRig {
        var made: [FakeHeadSource] = []
        var failure: Error?
        var now = 1000.0
        let workspace = NotificationCenter()
        let app = NotificationCenter()
        var source: FakeHeadSource { made[made.count - 1] }
        func factory() -> QuietZoneHeadFollowController.SourceFactory {
            { [unowned self] onPose in
                let s = FakeHeadSource(onPose: onPose)
                s.failure = self.failure
                self.made.append(s)
                return s
            }
        }
    }

    private func headFlags(_ on: [String]) -> FeatureFlags {
        let defaults = UserDefaults(suiteName: "QuietZoneHeadFollowTests.\(UUID().uuidString)")!
        return FeatureFlags(
            known: FeatureFlag.all, defaults: defaults, policy: .launchArgumentOnly,
            // The three E4 survey flags graduated (G16): the list is the exact set that is on, the rest are off.
            arguments: ["-NotchSixtyFeatures", (on + ["e4.virtual-microphone", "e4.head-position-camera", "e4.zones"]
                .filter { !on.contains($0) }.map { "-" + $0 }).joined(separator: ",")])
    }

    private func attachFollow(_ rig: Rig, _ head: HeadRig) throws -> QuietZoneHeadFollowController {
        QuietZoneFlagWiring.attachHeadFollow(
            to: rig.survey, flags: headFlags(["e4.virtual-microphone", "e4.head-position-camera"]),
            source: head.factory(), clock: { head.now }, workspaceCenter: head.workspace, appCenter: head.app)
        return try XCTUnwrap(rig.survey.headFollow)
    }

    private func deliver(_ head: HeadRig, _ follow: QuietZoneHeadFollowController, at x: Double) async {
        for _ in 0..<12 {
            head.now += 0.5
            head.source.emit(x)
            await Task.yield()
            await Task.yield()
        }
        // Frames arrive on main-actor tasks; wait until the last one is in.
        for _ in 0..<50 where follow.pose.map({ abs($0.x - x) > 0.02 }) ?? true { await Task.yield() }
    }

    private func designReductionDB(_ rig: Rig, twin: Twin, f: Double) throws -> (db: Double, left: ActiveQuietZoneComplex) {
        let paths = try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID)
        let design = try XCTUnwrap(try rig.quietZone.virtualEarDesign(
            frequencyHz: f, monitorDisturbance: twin.noiseAtMonitor(f),
            monitorLeft: paths.monitorLeft, monitorRight: paths.monitorRight,
            bassMode: .free, injectionPeakOverride: 0.5))
        let ear = twin.noiseAtEar(f)
        let achieved = ear + paths.earLeft * design.left + paths.earRight * design.right
        return (20 * log10(ear.magnitude / achieved.magnitude), design.left)
    }

    func testHeadMovesTheZoneBetweenSurveyedSeatsAtEightRates() async throws {
        let f = 60.0
        for rate in rates {
            let head = HeadRig()
            var rig = try makeRig(rate: rate)
            let follow = try attachFollow(rig, head)
            await follow.setEnabledAndWait(true)
            XCTAssertEqual(follow.cameraState, .on, "rate \(rate)")

            // Seat A at 0 m and seat B at 0.3 m: a different ear noise at each, surveyed and saved in turn.
            let twinA = rig.twin
            var twinB = rig.twin
            twinB.noiseEarK = Int((rate * 0.0025).rounded())
            await deliver(head, follow, at: 0)
            runSurvey(rig, frequencies: [f])
            XCTAssertTrue(follow.savePosition(tones: rig.survey.tones), "rate \(rate)")
            rig.twin = twinB
            await deliver(head, follow, at: 0.3)
            runSurvey(rig, frequencies: [f])
            XCTAssertTrue(follow.savePosition(tones: rig.survey.tones), "rate \(rate)")
            XCTAssertEqual(follow.positions.count, 2)
            rig.survey.useAtEar = true

            // The head at each seat designs for that seat's ear, within 3 dB of a real error microphone there.
            await deliver(head, follow, at: 0)
            let atA = try designReductionDB(rig, twin: twinA, f: f)
            let realA = try ActiveQuietZonePlanner().solveStereo(
                frequencyHz: f, disturbance: twinA.noiseAtEar(f),
                leftSecondaryPath: try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID).earLeft,
                rightSecondaryPath: try rig.quietZone.surveyPaths(frequencyHz: f, earPositionID: rig.earID).earRight,
                availableInjectionPeak: 0.5, configuration: rig.quietZone.configuration)
            XCTAssertEqual(atA.db, realA.predictedReductionDB, accuracy: 3, "rate \(rate)")
            guard case .following(let nearA, _) = follow.readout else { return XCTFail("readout \(follow.readout)") }
            XCTAssertEqual(nearA, "Seat 1")

            await deliver(head, follow, at: 0.3)
            let atB = try designReductionDB(rig, twin: twinB, f: f)
            XCTAssertGreaterThan(atB.db, 3, "rate \(rate)")
            guard case .following(let nearB, _) = follow.readout else { return XCTFail("readout \(follow.readout)") }
            XCTAssertEqual(nearB, "Seat 2")
            // The pose moved the zone: the design at B is not the design at A.
            XCTAssertGreaterThan((atA.left - atB.left).magnitude, 1e-6, "rate \(rate)")

            // A stale pose or a head outside the saved seats keeps the fixed ear survey (seat B's, the last taken).
            let fixed = try XCTUnwrap(rig.survey.tones.first)
            head.now += 5
            XCTAssertEqual(follow.readout, .waitingForPose)
            XCTAssertEqual(rig.survey.earTone(near: f)?.ratio, fixed.ratio, "stale, rate \(rate)")
            await deliver(head, follow, at: 2.0)
            XCTAssertEqual(follow.readout, .outsideSurvey)
            XCTAssertEqual(rig.survey.earTone(near: f)?.ratio, fixed.ratio, "outside, rate \(rate)")
            follow.setEnabled(false)
        }
    }

    func testCameraIsOffByDefaultAndStopsOnDisableSleepAndBackground() async throws {
        let head = HeadRig()
        let rig = try makeRig(rate: 48_000)
        let follow = try attachFollow(rig, head)
        // Off at launch: no source made, no camera.
        XCTAssertFalse(follow.isEnabled)
        XCTAssertEqual(follow.cameraState, .off)
        XCTAssertTrue(head.made.isEmpty)

        await follow.setEnabledAndWait(true)
        XCTAssertEqual(follow.cameraState, .on)
        XCTAssertEqual(head.source.starts, 1)

        // Disable stops it at once and drops the pose.
        await deliver(head, follow, at: 0)
        XCTAssertNotNil(follow.pose)
        await follow.setEnabledAndWait(false)
        XCTAssertEqual(head.source.stops, 1)
        XCTAssertEqual(follow.cameraState, .off)
        XCTAssertNil(follow.pose)

        // Sleep stops it; wake restarts it only because the switch is still on.
        await follow.setEnabledAndWait(true)
        let first = head.made.count
        head.workspace.post(name: NSWorkspace.willSleepNotification, object: nil)
        for _ in 0..<20 where follow.cameraState == .on { await Task.yield() }
        XCTAssertEqual(follow.cameraState, .paused("this Mac is asleep"))
        XCTAssertEqual(head.source.stops, 1)
        head.workspace.post(name: NSWorkspace.didWakeNotification, object: nil)
        for _ in 0..<20 where head.made.count == first { await Task.yield() }
        await follow.settle()
        XCTAssertEqual(follow.cameraState, .on)
        XCTAssertEqual(head.made.count, first + 1)

        // Background stops it, and a second reason (sleep) keeps it stopped until both clear.
        head.app.post(name: NSApplication.didResignActiveNotification, object: nil)
        for _ in 0..<20 where follow.cameraState == .on { await Task.yield() }
        XCTAssertEqual(follow.cameraState, .paused("Notch Sixty is in the background"))
        XCTAssertEqual(head.source.stops, 1)
        follow.systemWillSleep()
        follow.appDidBecomeActive()
        await follow.settle()
        XCTAssertNotEqual(follow.cameraState, .on)
        follow.systemDidWake()
        await follow.settle()
        XCTAssertEqual(follow.cameraState, .on)

        // While disabled, wake and activation never start the camera.
        await follow.setEnabledAndWait(false)
        let made = head.made.count
        follow.systemWillSleep()
        follow.systemDidWake()
        follow.appDidBecomeActive()
        await follow.settle()
        XCTAssertEqual(head.made.count, made)
        XCTAssertEqual(follow.cameraState, .off)
    }

    func testDeniedPermissionShowsGuidanceAndNeverRunsTheCamera() async throws {
        let head = HeadRig()
        head.failure = QuietZoneCameraHeadSource.Failure.denied
        let rig = try makeRig(rate: 48_000)
        let follow = try attachFollow(rig, head)
        await follow.setEnabledAndWait(true)
        XCTAssertEqual(follow.cameraState, .denied)
        XCTAssertFalse(follow.isCameraOn)
        XCTAssertTrue(follow.message.contains("System Settings"), follow.message)
        // A pose that arrives anyway is ignored.
        head.source.emit(0)
        await Task.yield()
        XCTAssertNil(follow.pose)
        XCTAssertNil(follow.tone(near: 60))
    }

    func testLowConfidenceAndSingleOutlierPosesDoNotMoveTheZone() async throws {
        let head = HeadRig()
        let rig = try makeRig(rate: 48_000)
        let follow = try attachFollow(rig, head)
        await follow.setEnabledAndWait(true)
        await deliver(head, follow, at: 0)
        head.source.emit(0.01, confidence: 0.1)
        head.source.emit(3)
        for _ in 0..<10 { await Task.yield() }
        let pose = try XCTUnwrap(follow.pose)
        XCTAssertEqual(pose.x, 0, accuracy: 0.02)
    }

    func testHeadFollowExistsOnlyWithBothFlagsAndTheCameraIsNotTouchedByWiring() throws {
        let head = HeadRig()
        func survey(_ flags: [String]) throws -> QuietZoneVirtualMicSurveyController {
            let rig = try makeRig(rate: 48_000)
            QuietZoneFlagWiring.attachHeadFollow(
                to: rig.survey, flags: headFlags(flags), source: head.factory(),
                clock: { head.now }, workspaceCenter: head.workspace, appCenter: head.app)
            return rig.survey
        }
        XCTAssertNil(try survey([]).headFollow)
        XCTAssertNil(try survey(["e4.virtual-microphone"]).headFollow)
        XCTAssertNotNil(try survey(["e4.virtual-microphone", "e4.head-position-camera"]).headFollow)
        QuietZoneFlagWiring.attachHeadFollow(
            to: nil, flags: headFlags(["e4.head-position-camera"]), source: head.factory())
        XCTAssertTrue(head.made.isEmpty)
        XCTAssertTrue(FeatureFlag.headPositionCamera.graduated)
    }

    func testSavingNeedsALivePoseAndMatchingTonesAndNearbySeatsReplace() async throws {
        let head = HeadRig()
        let rig = try makeRig(rate: 48_000)
        let follow = try attachFollow(rig, head)
        runSurvey(rig, frequencies: [60, 80])
        XCTAssertFalse(follow.savePosition(tones: rig.survey.tones), "camera off")
        await follow.setEnabledAndWait(true)
        XCTAssertFalse(follow.savePosition(tones: rig.survey.tones), "no pose yet")
        await deliver(head, follow, at: 0)
        XCTAssertTrue(follow.savePosition(tones: rig.survey.tones))
        XCTAssertTrue(follow.savePosition(tones: rig.survey.tones))
        XCTAssertEqual(follow.positions.count, 1, "same seat replaces")
        XCTAssertFalse(follow.savePosition(tones: Array(rig.survey.tones.prefix(1))), "tones differ")
        follow.clearPositions()
        XCTAssertTrue(follow.positions.isEmpty)
    }
}
