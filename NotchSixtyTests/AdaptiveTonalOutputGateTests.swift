import XCTest
@testable import NotchSixty

extension AdaptiveTonalGateInput {
    /// A gate input for which every condition holds (the gate is open) unless `armed` is false.
    static func sample(armed: Bool = true) -> AdaptiveTonalGateInput {
        AdaptiveTonalGateInput(
            flagEnabled: true, armed: armed,
            controllerGeneration: 4, engineGeneration: 4,
            targetRampedIn: true, hasBaseline: true, verdict: .ok,
            guardTripped: false, leaseRequired: true, leaseRenewed: true,
            pathWithinTolerance: true, resolveRunning: false,
            coreAdapting: true, coreFault: false
        )
    }
}

/// E4 S18b: the single route from the adaptive weights to output. Each condition alone closes it.
final class AdaptiveTonalOutputGateTests: XCTestCase {
    private func decision(_ edit: (inout AdaptiveTonalGateInput) -> Void) -> AdaptiveTonalGateDecision {
        var input = AdaptiveTonalGateInput.sample()
        edit(&input)
        return AdaptiveTonalOutputGate.evaluate(input)
    }

    func testOpenOnlyWhenEveryConditionHolds() {
        XCTAssertEqual(AdaptiveTonalOutputGate.evaluate(.sample()), .open)
    }

    func testEachConditionAloneClosesTheGate() {
        XCTAssertEqual(decision { $0.flagEnabled = false }, .closed(.flagOff))
        XCTAssertEqual(decision { $0.armed = false }, .closed(.notArmed))
        XCTAssertEqual(decision { $0.controllerGeneration = nil }, .closed(.staleArm))
        XCTAssertEqual(decision { $0.engineGeneration = 5 }, .closed(.staleArm))
        XCTAssertEqual(decision { $0.targetRampedIn = false }, .closed(.rampingIn))
        XCTAssertEqual(decision { $0.hasBaseline = false }, .closed(.noBaseline))
        XCTAssertEqual(decision { $0.verdict = .baselining }, .closed(.noBaseline))
        XCTAssertEqual(decision { $0.verdict = .warning }, .closed(.seatWarning))
        XCTAssertEqual(decision { $0.verdict = .harm(frequencyHz: 43, increaseDB: 3) }, .closed(.seatHarm))
        XCTAssertEqual(decision { $0.guardTripped = true }, .closed(.guardTripped))
        XCTAssertEqual(decision { $0.leaseRenewed = false }, .closed(.leaseLapsed))
        XCTAssertEqual(decision { $0.coreFault = true }, .closed(.coreFault))
        XCTAssertEqual(decision { $0.pathWithinTolerance = false }, .closed(.pathOutOfTolerance))
        XCTAssertEqual(decision { $0.coreAdapting = false }, .closed(.coreNotAdapting))
    }

    func testTheLeaseIsOnlyRequiredWhenItsFlagIsOn() {
        XCTAssertEqual(decision { $0.leaseRequired = false; $0.leaseRenewed = false }, .open)
    }

    func testARunningResolveKeepsTheGateOpenWhileThePathIsOutOfTolerance() {
        XCTAssertEqual(decision { $0.pathWithinTolerance = false; $0.resolveRunning = true }, .open)
    }

    func testEveryClosedReasonHasAMessage() {
        let reasons: [AdaptiveTonalGateReason] = [
            .flagOff, .notArmed, .staleArm, .rampingIn, .noBaseline, .seatWarning, .seatHarm,
            .guardTripped, .leaseLapsed, .pathOutOfTolerance, .coreNotAdapting, .coreFault,
        ]
        for reason in reasons { XCTAssertFalse(reason.displayName.isEmpty) }
    }
}
