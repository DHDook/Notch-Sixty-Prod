import XCTest
@testable import NotchSixty

final class QuietZoneSpatialPlannerTests: XCTestCase {
    private let planner = QuietZoneSpatialPlanner()

    private func phasor(_ real: Double, _ imaginary: Double = 0) -> ActiveQuietZoneComplex {
        ActiveQuietZoneComplex(real: real, imaginary: imaginary)
    }

    private func seat(
        _ name: String,
        left: ActiveQuietZoneComplex,
        right: ActiveQuietZoneComplex,
        disturbance: ActiveQuietZoneComplex = ActiveQuietZoneComplex(real: 0.04, imaginary: 0)
    ) -> QuietZoneSeatCapture {
        QuietZoneSeatCapture(
            name: name,
            microphoneID: "measurement-mic",
            routeID: "mac-output:system-A",
            coherentReferenceID: "repeatable-clock-1",
            sampleRate: 48_000,
            capturedFrequencyHz: 75,
            snrDB: 40,
            leftSecondaryPath: left,
            rightSecondaryPath: right,
            disturbance: disturbance
        )
    }

    func testJointSolverImprovesBothSeatsWithinSourceLimits() throws {
        let first = seat("Couch", left: phasor(1), right: phasor(0))
        let second = seat("Chair", left: phasor(0), right: phasor(1))
        let session = QuietZoneSpatialSession(
            monitorSeatID: first.id,
            captures: [first, second]
        )
        let config = ActiveQuietZoneConfiguration()
        let result = try planner.solve(
            session: session, configuration: config,
            availableInjectionPeak: 0.10
        )
        XCTAssertEqual(result.predictions.count, 2)
        XCTAssertTrue(result.predictions.allSatisfy { $0.predictedReductionDB > 1 })
        XCTAssertGreaterThan(result.worstSeatReductionDB, 1)
        XCTAssertFalse(result.commissioned)
        XCTAssertLessThanOrEqual(
            result.leftOutput.magnitude,
            pow(10, config.maximumPerSourceTonePeakDBFS / 20) + 1.0e-9
        )
        XCTAssertLessThanOrEqual(
            result.rightOutput.magnitude,
            pow(10, config.maximumPerSourceTonePeakDBFS / 20) + 1.0e-9
        )
    }

    func testFailsClosedForUnrepeatedNoisePhaseReference() {
        let first = seat("Couch", left: phasor(1), right: phasor(0))
        var second = seat("Chair", left: phasor(0), right: phasor(1))
        second.coherentReferenceID = "different-unsynchronized-session"
        let session = QuietZoneSpatialSession(
            monitorSeatID: first.id,
            captures: [first, second]
        )
        XCTAssertThrowsError(try planner.solve(
            session: session,
            configuration: ActiveQuietZoneConfiguration(),
            availableInjectionPeak: 0.1
        ))
    }

    func testRejectsClippedSeatAndMixedRoute() {
        let first = seat("Couch", left: phasor(1), right: phasor(0))
        var second = seat("Chair", left: phasor(0), right: phasor(1))
        second.clipped = true
        let session = QuietZoneSpatialSession(monitorSeatID: first.id, captures: [first, second])
        XCTAssertThrowsError(try planner.solve(
            session: session, configuration: ActiveQuietZoneConfiguration(),
            availableInjectionPeak: 0.1
        ))
        second.clipped = false
        second.routeID = "different-output"
        let mixedRoute = QuietZoneSpatialSession(monitorSeatID: first.id, captures: [first, second])
        XCTAssertThrowsError(try planner.solve(
            session: mixedRoute, configuration: ActiveQuietZoneConfiguration(),
            availableInjectionPeak: 0.1
        ))
    }

    func testConflictingSeatDisturbancesCannotProduceSafeZone() {
        let first = seat("Couch", left: phasor(1), right: phasor(0),
                         disturbance: phasor(0.04))
        let second = seat("Chair", left: phasor(1), right: phasor(0),
                          disturbance: phasor(-0.04))
        let session = QuietZoneSpatialSession(monitorSeatID: first.id, captures: [first, second])
        XCTAssertThrowsError(try planner.solve(
            session: session,
            configuration: ActiveQuietZoneConfiguration(),
            availableInjectionPeak: 0.1
        ))
    }

    func testCommissioningRequiresMeasuredImprovementAtAllSeats() throws {
        let first = seat("Couch", left: phasor(1), right: phasor(0))
        let second = seat("Chair", left: phasor(0), right: phasor(1))
        let config = ActiveQuietZoneConfiguration()
        let result = try planner.solve(
            session: QuietZoneSpatialSession(monitorSeatID: first.id, captures: [first, second]),
            configuration: config, availableInjectionPeak: 0.10
        )
        XCTAssertThrowsError(try planner.verifyCommissioning(
            solution: result, measuredReductionBySeat: [first.id: 4],
            configuration: config
        ))
        XCTAssertThrowsError(try planner.verifyCommissioning(
            solution: result,
            measuredReductionBySeat: [first.id: 6, second.id: -2],
            configuration: config
        ))
        let commissioned = try planner.verifyCommissioning(
            solution: result,
            measuredReductionBySeat: [first.id: 4, second.id: 2],
            configuration: config
        )
        XCTAssertTrue(commissioned.commissioned)
    }
}
