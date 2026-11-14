import XCTest
@testable import NotchSixty

/// E19 S11: `e19.mimo-treatment` graduates as available, never armed. The production controller on a real (stopped) engine,
/// in a release-style configuration with no launch argument, shows the controls and then refuses at every step: no audio, no
/// design, no permit, no arm. The designed and armed paths, unrouted and routed, are in `MIMOTreatmentControllerTests` and
/// `MIMORoutedWayCaptureTests` (test permit only: the production registry holds no qualification until E22).
@MainActor
final class E19GraduationTests: XCTestCase {
    private func release(_ arguments: [String] = []) -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "E19GraduationTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly, arguments: arguments)
    }

    func testFlagIsGraduatedOnInReleaseAndCanBeSwitchedOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.mimoTreatment))
        XCTAssertTrue(FeatureFlag.mimoTreatment.graduated)
        XCTAssertTrue(release().isEnabled(.mimoTreatment))
        XCTAssertFalse(release([FeatureFlags.launchArgument, "-" + FeatureFlag.mimoTreatment.id]).isEnabled(.mimoTreatment))
    }

    func testProductionControllerOnARealEngineIsAvailableButNothingArms() async throws {
        let engine = AudioIOEngine()
        let controller = MIMOTreatmentController(host: engine, flags: release(), seats: { [] }, baseline: { [] })
        XCTAssertTrue(controller.isAvailable, "graduated: the Room Treatment section shows")
        controller.refreshSources()
        await controller.design()
        if case .designed = controller.phase { XCTFail("no running audio, so no design") }
        controller.requestPermit()
        XCTAssertFalse(controller.permitRefusals.isEmpty)
        XCTAssertFalse(controller.permitHeld, "no permit exists before the E22 qualification")
        XCTAssertFalse(controller.canArm)
        await controller.arm()
        XCTAssertNotNil(controller.armMessage)
        XCTAssertFalse(controller.isArmed)
        XCTAssertFalse(engine.mimoGraphTreatment.isArmed)
    }

    func testSwitchedOffControllerIsUnavailable() {
        let off = release([FeatureFlags.launchArgument, "-" + FeatureFlag.mimoTreatment.id])
        let controller = MIMOTreatmentController(host: AudioIOEngine(), flags: off, seats: { [] }, baseline: { [] })
        XCTAssertFalse(controller.isAvailable)
    }
}
