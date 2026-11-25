import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S19 (`e12.active-acoustics-page`): the one Quiet Zone card. The model is pure; the page tests host the real
/// Active Acoustics page with the flag on and read its AppKit controls (the harness reads NSSwitch for `.switch` toggles).
@MainActor
final class QuietZoneCardTests: XCTestCase {
    private func facts(armed: Bool, readiness: QuietZoneFeedForwardReadiness = .physicallyPlausible) -> FeedForwardLiveQuietZoneFacts {
        var budget = QuietZoneFeedForwardBudget.missing
        budget.readiness = readiness
        return FeedForwardLiveQuietZoneFacts(
            armed: armed, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "out", sampleRate: 48_000, budget: budget)
    }

    private func inputs(
        armed: Bool = false, mic: String? = "Mic", permission: Bool = true, model: String? = "Seat", running: Bool = true,
        readiness: QuietZoneFeedForwardReadiness = .physicallyPlausible, ffOn: Bool = false, ffAvailable: Bool = true,
        disarm: String? = nil
    ) -> QuietZoneCardInputs {
        QuietZoneCardInputs(
            microphonePermissionGranted: permission, microphoneName: mic, engineRunning: running, measuredModelName: model,
            subMeasurementApplies: false, subMeasurementMissing: nil, area: .oneSeat,
            areaUnavailable: [.earPosition: "Measure your ear position first."],
            armed: armed, lastAutoDisarmMessage: disarm, feedForwardAvailable: ffAvailable, feedForwardOn: ffOn,
            feedForwardFacts: facts(armed: armed, readiness: readiness))
    }

    // MARK: Model

    func testThereAreExactlyTwoSwitchesArmThenFeedForward() {
        XCTAssertEqual(QuietZoneCardModel(inputs()).switches.map(\.id), [.arm, .feedForward])
        XCTAssertEqual(QuietZoneSwitchID.allCases.count, 2)
    }

    func testFeedForwardCannotBeTurnedOnWhileArmIsOff() {
        let model = QuietZoneCardModel(inputs(armed: false))
        XCTAssertFalse(model.feedForwardSwitch.isEnabled)
        XCTAssertEqual(model.feedForwardSwitch.disabledReason, "Turn on Arm first.")
    }

    func testFeedForwardWaitsForItsMeasurementsAndChecksOnceArmed() {
        for readiness: QuietZoneFeedForwardReadiness in [.missingMeasurements, .invalidTimebase, .unreliableMeasurements, .nonCausal, .limitedMargin] {
            let model = QuietZoneCardModel(inputs(armed: true, readiness: readiness))
            XCTAssertFalse(model.feedForwardSwitch.isEnabled, "\(readiness)")
            guard case .notReady(let reason, let action) = model.readiness else { return XCTFail("\(readiness) must be not ready") }
            XCTAssertFalse(reason.isEmpty)
            XCTAssertFalse(action.isEmpty)
            XCTAssertEqual(model.feedForwardSwitch.disabledReason, reason)
        }
        let ready = QuietZoneCardModel(inputs(armed: true))
        XCTAssertEqual(ready.readiness, .ready)
        XCTAssertTrue(ready.feedForwardSwitch.isEnabled)
    }

    func testSubwooferAndReceiverRefusalsAreReadableReasons() {
        var armed = inputs(armed: true)
        armed.feedForwardFacts.subwooferActive = true
        XCTAssertNotNil(QuietZoneCardModel(armed).feedForwardSwitch.disabledReason)
        armed.feedForwardFacts.subwooferActive = false
        armed.feedForwardFacts.receiverBassUndeclared = true
        XCTAssertNotNil(QuietZoneCardModel(armed).feedForwardSwitch.disabledReason)
    }

    func testEveryDisabledSwitchShowsAReasonAcrossAllStates() {
        let permissions = [true, false], mics: [String?] = ["Mic", nil], models: [String?] = ["Seat", nil]
        for permission in permissions { for mic in mics { for model in models { for running in [true, false] {
            for armed in [true, false] { for ffAvailable in [true, false] {
                for readiness: QuietZoneFeedForwardReadiness in [.missingMeasurements, .physicallyPlausible] {
                    let m = QuietZoneCardModel(inputs(
                        armed: armed, mic: mic, permission: permission, model: model, running: running,
                        readiness: readiness, ffAvailable: ffAvailable))
                    for sw in m.switches where !sw.isEnabled {
                        XCTAssertFalse((sw.disabledReason ?? "").isEmpty, "\(sw.id) disabled without a reason")
                    }
                }
            } }
        } } } }
    }

    func testArmIsDisabledWithTheFirstMissingSetupStep() {
        XCTAssertEqual(QuietZoneCardModel(inputs(permission: false)).armSwitch.disabledReason, "Microphone access is not allowed yet.")
        XCTAssertEqual(QuietZoneCardModel(inputs(mic: nil)).armSwitch.disabledReason, "Choose a microphone first.")
        XCTAssertEqual(QuietZoneCardModel(inputs(model: nil)).armSwitch.disabledReason, "Measure your speakers first.")
        XCTAssertEqual(QuietZoneCardModel(inputs(running: false)).armSwitch.disabledReason, "Start audio processing first.")
        XCTAssertNil(QuietZoneCardModel(inputs()).armSwitch.disabledReason)
    }

    func testSetupStepsShowStateAndNextAction() {
        let blank = QuietZoneCardModel(inputs(mic: nil, model: nil)).steps
        XCTAssertEqual(blank.map(\.id), ["microphone", "measure", "area", "turnOn"])
        XCTAssertEqual(blank.first { $0.id == "microphone" }?.state, .todo)
        XCTAssertNotNil(blank.first { $0.id == "microphone" }?.nextAction)
        let done = QuietZoneCardModel(inputs(armed: true)).steps
        XCTAssertTrue(done.allSatisfy { $0.state == .done && $0.nextAction == nil })
        var sub = inputs()
        sub.subMeasurementApplies = true
        sub.subMeasurementMissing = "Measure with your subwoofer."
        XCTAssertEqual(QuietZoneCardModel(sub).steps.map(\.id), ["microphone", "measure", "subwoofer", "area", "turnOn"])
        XCTAssertNotNil(QuietZoneCardModel(sub).armSwitch.disabledReason)
    }

    func testArmStatusSaysWhyItIsOffAndWhatTrippedIt() {
        XCTAssertTrue(QuietZoneCardModel(inputs()).armStatusLine.contains("Off after each launch for safety"))
        let tripped = QuietZoneCardModel(inputs(disarm: LiveTreatmentDisarmReason.microphoneStalled.message))
        XCTAssertEqual(tripped.armStatusLine, LiveTreatmentDisarmReason.microphoneStalled.message)
    }

    // MARK: Controller

    private func makeController() -> ActiveQuietZoneController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        let calibration = RoomCorrectionCalibrationController(engine: engine)
        let projects = RoomCorrectionProjectController(
            profiles: profiles, store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        let ambient = AmbientCompensationController(engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        return ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
    }

    func testAFreshControllerIsDisarmedWithOneSeatAndNoAutoDisarmMessage() {
        let controller = makeController()
        let card = controller.cardInputs(engineRunning: false, microphonePermissionGranted: true, microphoneName: "Mic", measuredModelName: "Seat")
        XCTAssertFalse(card.armed)
        XCTAssertNil(card.lastAutoDisarmMessage)
        XCTAssertEqual(card.area, .oneSeat)
        XCTAssertNotNil(card.areaUnavailable[.earPosition], "no ear survey in this build or yet")
        XCTAssertFalse(controller.setAreaChoice(.twoZones), "an unavailable choice changes nothing")
        XCTAssertEqual(controller.areaChoice, .oneSeat)
    }

    func testAnAutomaticDisarmReasonReachesTheCard() throws {
        let controller = makeController()
        try controller.arm.arm(environment: LiveTreatmentEnvironment(
            outputDeviceUID: "out", sampleRate: 48_000, engineRunning: true, inputAvailable: true))
        controller.arm.disarm(.microphoneStalled)
        let card = controller.cardInputs(engineRunning: true, microphonePermissionGranted: true, microphoneName: "Mic", measuredModelName: "Seat")
        XCTAssertEqual(card.lastAutoDisarmMessage, LiveTreatmentDisarmReason.microphoneStalled.message)
        controller.arm.disarm(.user)
        try controller.arm.arm(environment: LiveTreatmentEnvironment(
            outputDeviceUID: "out", sampleRate: 48_000, engineRunning: true, inputAvailable: true))
        controller.arm.disarm(.user)
        XCTAssertNil(controller.cardInputs(engineRunning: true, microphonePermissionGranted: true, microphoneName: "Mic", measuredModelName: "Seat").lastAutoDisarmMessage)
    }

    // MARK: Page

    private func page(flag: Bool, size: CGSize, tab: ActiveAcousticsTab = .quietZone) -> HostedPage {
        let flags = FeatureFlags()
        flags.setEnabled(flag, for: .activeAcousticsPage)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: []))
        let product = ProductController(audioEngine: engine)
        return HostedPage(ProductionActiveAcousticsWorkspace(
            engine: engine, ambient: product.ambientCompensation, quietZone: product.activeQuietZone,
            adaptiveQuietZone: product.adaptiveQuietZone, feedForwardSurvey: product.feedForwardSurvey,
            feedForwardShadow: product.feedForwardShadow, feedForwardArming: product.feedForwardArming,
            mimoTreatment: product.mimoTreatment, microphone: product.calibration,
            projects: product.roomCorrectionProjects, initialTab: tab), size: size)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(ProcessInfo.processInfo.environment[FeatureFlags.graduatedOffEnvironmentKey] == "1",
                      "the flags-off matrix forces graduated flags off")
    }

    override func tearDown() {
        FeatureFlags().resetOverrides()
        super.tearDown()
    }

    func testTheQuietZonePageHasExactlyTwoSwitchesAndFeedForwardIsDisabled() {
        let page = page(flag: true, size: CGSize(width: 1_280, height: 800))
        let switches = page.controls.filter { $0.view is NSSwitch }
        XCTAssertEqual(switches.count, 2, page.outline)
        XCTAssertFalse(switches[1].isEnabled, "Feed-forward is disabled while Arm is off")
        XCTAssertFalse(switches[0].isEnabled, "Arm is disabled without a microphone and measurement")
    }

    func testTheOldPageIsUnchangedWithTheFlagOff() {
        let page = page(flag: false, size: CGSize(width: 1_280, height: 800))
        XCTAssertTrue(page.has("Arm", kind: .toggle) || !page.controls(of: .toggle).isEmpty, page.outline)
        XCTAssertGreaterThanOrEqual(page.controls.filter { $0.view is NSSwitch }.count, 1)
    }

    func testThePlaybackAdaptationTabHasNoSecondArmSwitch() {
        let page = page(flag: true, size: CGSize(width: 1_280, height: 800), tab: .ambientAnalysis)
        XCTAssertTrue(page.controls.filter { $0.view is NSSwitch }.isEmpty, "no Arm switch on this tab:\n\(page.outline)")
        XCTAssertFalse(page.controls.contains { $0.label.contains("Arm Active Quiet Zone") }, page.outline)
    }

    func testTheCardFitsAtBothReferenceSizes() {
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let page = page(flag: true, size: size)
            let controls = page.controls.filter { [.popup, .segmented, .toggle, .textField, .button].contains($0.kind) }
            XCTAssertFalse(controls.isEmpty)
            for control in controls {
                let frame = control.view.convert(control.view.bounds, to: page.hosting)
                XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(control.label) \(control.title) passes the page width at \(size.width)")
            }
        }
    }
}
