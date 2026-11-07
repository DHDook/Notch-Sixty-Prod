import XCTest
@testable import NotchSixty

/// E24 S11: the joint-bass prediction paths (built in the verifier, not the wizard view) and the trial's ownership of
/// playback when Verify runs with playback idle (Q4).
@MainActor
final class RoomCorrectionAuditLeftoversTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Joint-bass prediction paths

    private func impulse(_ delay: Int, count: Int = 4_800) -> [Float] {
        var x = [Float](repeating: 0, count: count)
        x[delay] = 0.5
        return x
    }

    private func plan(rate: Double) -> RoomCorrectionLanePlan {
        // Lane 0 (main L) and lane 2 (sub) carry a flat one-tap stage; lane 1 carries none.
        RoomCorrectionLanePlan(
            designID: UUID(), sampleRate: rate, stages: [RoomCorrectionLaneStage(laneMask: 0b101, taps: [1])],
            declaredLatencyFrames: 0, laneCount: 3)
    }

    func testJointBassPathsPickTheMeasuredMainAndEverySubAtEveryRate() throws {
        for rate in Self.rates {
            let sources = [
                RoomCorrectionJointBassSource(isSubwoofer: false, impulse: impulse(100), directArrivalSeconds: 100 / rate),
                RoomCorrectionJointBassSource(isSubwoofer: false, impulse: impulse(110), directArrivalSeconds: 110 / rate),
                RoomCorrectionJointBassSource(
                    isSubwoofer: true, impulse: impulse(120), directArrivalSeconds: 120 / rate,
                    gainDB: 100, delayMilliseconds: 5_000, polarityInverted: true),
            ]
            let delays = [RoomCorrectionLaneDelay(lane: 0, seconds: 0.002)]
            let left = RoomCorrectionPostApplyVerifier.jointBassPaths(
                sources: sources, mainLanes: [0, 1], subLanes: [2], plan: plan(rate: rate), measuredLane: 0,
                laneDelays: delays, sampleRate: rate)
            XCTAssertEqual(left.count, 2, "main L and the sub at \(rate)")
            XCTAssertEqual(left[0].arrivalFrames, 100, accuracy: 1e-6)
            XCTAssertEqual(left[0].delaySeconds, 0.002, accuracy: 1e-12)
            XCTAssertNotNil(left[0].stage)
            XCTAssertEqual(left[1].gainDB, PhysicalSubwooferCalibration.gainRangeDB.upperBound)
            XCTAssertEqual(left[1].delaySeconds, PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound / 1_000, accuracy: 1e-12)
            XCTAssertTrue(left[1].polarityInverted)
            XCTAssertNotNil(left[1].stage, "the sub lane's stage")

            let right = RoomCorrectionPostApplyVerifier.jointBassPaths(
                sources: sources, mainLanes: [0, 1], subLanes: [2], plan: plan(rate: rate), measuredLane: 1,
                laneDelays: delays, sampleRate: rate)
            XCTAssertEqual(right.count, 2)
            XCTAssertEqual(right[0].arrivalFrames, 110, accuracy: 1e-6)
            XCTAssertNil(right[0].stage, "lane 1 carries no stage")
            XCTAssertEqual(right[0].delaySeconds, 0)
        }
    }

    func testJointBassPathsSkipUnmeasuredSourcesWithoutShiftingLanes() {
        let rate = 48_000.0
        let sources = [
            RoomCorrectionJointBassSource(isSubwoofer: false, impulse: nil, directArrivalSeconds: nil),
            RoomCorrectionJointBassSource(isSubwoofer: false, impulse: impulse(110), directArrivalSeconds: 110 / rate),
            RoomCorrectionJointBassSource(isSubwoofer: true, impulse: nil, directArrivalSeconds: nil),
        ]
        let paths = RoomCorrectionPostApplyVerifier.jointBassPaths(
            sources: sources, mainLanes: [0, 1], subLanes: [2], plan: plan(rate: rate), measuredLane: 1,
            laneDelays: [], sampleRate: rate)
        XCTAssertEqual(paths.count, 1, "the missing left and the missing sub are skipped; lane 1 is still the second main")
        XCTAssertEqual(paths[0].arrivalFrames, 110, accuracy: 1e-6)
    }

    func testJointBassPathsFeedTheSummedPrediction() throws {
        let rate = 48_000.0
        let sources = [
            RoomCorrectionJointBassSource(isSubwoofer: false, impulse: impulse(100), directArrivalSeconds: 100 / rate),
            RoomCorrectionJointBassSource(
                isSubwoofer: true, impulse: impulse(100), directArrivalSeconds: 100 / rate, polarityInverted: true),
        ]
        let criteria = RoomCorrectionPostApplyCriteria()
        let paths = RoomCorrectionPostApplyVerifier.jointBassPaths(
            sources: sources, mainLanes: [0, 1], subLanes: [2], plan: plan(rate: rate), measuredLane: 0,
            laneDelays: [], sampleRate: rate)
        let together = try RoomCorrectionPostApplyVerifier.prediction(
            paths: paths, declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria)
        let mainAlone = try RoomCorrectionPostApplyVerifier.prediction(
            paths: [paths[0]], declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria)
        XCTAssertTrue(together.magnitudeDB.allSatisfy { $0 < mainAlone.magnitudeDB.min()! - 40 },
                      "an inverted sub at the same arrival cancels the main")
    }

    // MARK: Trial playback ownership

    private final class FakeControl: TrialPlaybackControlling {
        var liveGraphAvailable = false
        var isIdle = true
        var startError: Error?
        var becomesLiveAfterStart = true
        private(set) var starts = 0, stops = 0
        func start() throws {
            starts += 1
            if let startError { throw startError }
            isIdle = false
            if becomesLiveAfterStart { liveGraphAvailable = true }
        }
        func stop() { stops += 1; isIdle = true; liveGraphAvailable = false }
    }

    func testIdlePlaybackIsStartedForTheTrialAndStoppedAfterwards() async throws {
        let control = FakeControl()
        let owner = TrialPlaybackOwner(control: control, pollNanoseconds: 1_000_000)
        try await owner.acquire()
        XCTAssertEqual(control.starts, 1)
        XCTAssertTrue(owner.startedByTrial)
        owner.release()
        owner.release()
        XCTAssertEqual(control.stops, 1, "restored to idle exactly once")
        XCTAssertTrue(control.isIdle)
    }

    func testRunningGraphPlaybackIsLeftRunning() async throws {
        let control = FakeControl()
        control.isIdle = false
        control.liveGraphAvailable = true
        let owner = TrialPlaybackOwner(control: control, pollNanoseconds: 1_000_000)
        try await owner.acquire()
        owner.release()
        XCTAssertEqual(control.starts, 0)
        XCTAssertEqual(control.stops, 0)
        XCTAssertFalse(control.isIdle)
    }

    func testPlaybackOnARendererWithoutTheGraphIsRefusedAndUntouched() async {
        let control = FakeControl()
        control.isIdle = false
        let owner = TrialPlaybackOwner(control: control, pollNanoseconds: 1_000_000)
        do { try await owner.acquire(); XCTFail("should refuse") } catch {
            XCTAssertEqual(error as? RoomCorrectionTrialError, .playbackNotRunning)
        }
        XCTAssertEqual(control.starts, 0)
        XCTAssertEqual(control.stops, 0)
    }

    func testStartFailureIsReportedAndNothingIsStopped() async {
        struct Boom: LocalizedError { var errorDescription: String? { "no output" } }
        let control = FakeControl()
        control.startError = Boom()
        let owner = TrialPlaybackOwner(control: control, pollNanoseconds: 1_000_000)
        do { try await owner.acquire(); XCTFail("should throw") } catch {
            guard case .captureFailed(let detail)? = error as? RoomCorrectionTrialError else { return XCTFail("\(error)") }
            XCTAssertTrue(detail.contains("no output"))
        }
        XCTAssertFalse(owner.startedByTrial)
        XCTAssertEqual(control.stops, 0)
    }

    func testPlaybackThatNeverReachesTheGraphIsStoppedAgain() async {
        let control = FakeControl()
        control.becomesLiveAfterStart = false
        let owner = TrialPlaybackOwner(control: control, pollNanoseconds: 1_000_000)
        let task = Task { try await owner.acquire() }
        task.cancel()
        do { try await task.value; XCTFail("should throw") } catch {
            XCTAssertEqual(error as? RoomCorrectionTrialError, .playbackNotRunning)
        }
        XCTAssertEqual(control.stops, 1)
        XCTAssertTrue(control.isIdle)
    }
}
