import XCTest
@testable import NotchSixty

/// E4 S18b: the coordinator's control-plane decisions. Audio-path behaviour of the worker and the
/// kernel is covered by the C++ re-solve harness; here the gate and the request flow are checked
/// without a worker, so nothing can reach the render path.
@MainActor
final class AdaptiveTonalLiveCoordinatorTests: XCTestCase {
    private func coordinator() -> AdaptiveTonalLiveCoordinator {
        AdaptiveTonalLiveCoordinator(ambient: nil, linkProvider: { nil }, clock: { 0 })
    }

    private func input(
        armed: Bool = true,
        controller: UInt64? = 4,
        engine: UInt64 = 4,
        hasBaseline: Bool = true,
        verdict: DoNoHarmVerdict = .ok,
        now: TimeInterval = 10
    ) -> AdaptiveTonalLivePollInput {
        AdaptiveTonalLivePollInput(
            now: now, armed: armed, controllerGeneration: controller, engineGeneration: engine,
            targetRampedIn: true, hasBaseline: hasBaseline, verdict: verdict, measurement: nil,
            seeds: [], plannedPeakLinear: 0.1, leaseRequired: false, leaseRenewed: false
        )
    }

    func testUnarmedPollRequestsNothingAndNeverEnablesWrites() {
        let c = coordinator()
        XCTAssertTrue(c.poll(input(armed: false, controller: nil)).isEmpty)
        XCTAssertFalse(c.command.writeEnabled)
        XCTAssertFalse(c.hasWorker)
    }

    func testStaleArmGenerationKeepsTheGateClosed() {
        let c = coordinator()
        _ = c.poll(input(controller: 4, engine: 5))
        XCTAssertEqual(c.gate, .closed(.staleArm))
        XCTAssertFalse(c.command.writeEnabled)
        XCTAssertTrue(c.command.hold)
    }

    func testNoBaselineKeepsTheGateClosed() {
        let c = coordinator()
        _ = c.poll(input(hasBaseline: false))
        XCTAssertEqual(c.gate, .closed(.noBaseline))
    }

    func testHarmVerdictKeepsTheGateClosed() {
        let c = coordinator()
        _ = c.poll(input(verdict: .harm(frequencyHz: 43, increaseDB: 3)))
        XCTAssertEqual(c.gate, .closed(.seatHarm))
        XCTAssertFalse(c.command.writeEnabled)
    }

    func testWithoutAMicrophoneStreamTheCoreIsNotAdaptingSoNothingIsWritten() {
        let c = coordinator()
        let requests = c.poll(input())
        XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(c.gate, .closed(.coreNotAdapting))
        XCTAssertFalse(c.command.writeEnabled)
    }

    func testDisarmingTheArmResetsTheCoordinator() {
        let c = coordinator()
        _ = c.poll(input())
        _ = c.poll(input(armed: false, controller: nil))
        XCTAssertEqual(c.gate, .closed(.notArmed))
        XCTAssertFalse(c.resolver.isRunning)
    }
}
