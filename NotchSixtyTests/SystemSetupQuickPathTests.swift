import XCTest
@testable import NotchSixty

/// E12 S10: the quick path is a step preset of the one guided-setup flow.
@MainActor
final class SystemSetupQuickPathTests: XCTestCase {
    private func state() -> PlaybackSystemState { PlaybackSystemState(associatedOutputUID: "uid-a", outputGainDB: -3) }

    private func runningQuickFlow() throws -> SystemSetupFlow {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: state(), preset: .quick)
        return flow
    }

    func testQuickPresetPassesOverSpeakersAndRoomOnly() throws {
        XCTAssertEqual(SystemSetupPreset.quick.steps, [.output, .microphone, .measure, .alignment, .bass, .correction, .verify, .save])
        XCTAssertEqual(SystemSetupPreset.full.steps, SystemSetupStep.allCases)
        var flow = try runningQuickFlow()
        flow.choices.outputUID = "out"
        flow.choices.sampleRate = 48_000
        try flow.next()
        XCTAssertEqual(flow.step, .microphone)
        try flow.back()
        XCTAssertEqual(flow.step, .output)
        XCTAssertEqual(flow.skipped, [.topology, .room])
    }

    func testQuickPresetRefusesMoreThanOneSeatWithAReason() throws {
        var flow = try runningQuickFlow()
        flow.choices.seatNames = ["Seat 1", "Seat 2"]
        flow.choices.measurementIDs = [UUID(), UUID()]
        XCTAssertNotNil(flow.unmetPrecondition(for: .measure))
        try flow.openFullSetup()
        XCTAssertNil(flow.unmetPrecondition(for: .measure))
    }

    func testOpeningTheFullSetupKeepsChoicesAndMakesStepsReachable() throws {
        var flow = try runningQuickFlow()
        flow.choices.outputUID = "out"
        flow.choices.sampleRate = 96_000
        try flow.next()
        try flow.openFullSetup()
        XCTAssertEqual(flow.preset, .full)
        XCTAssertEqual(flow.choices.outputUID, "out")
        XCTAssertEqual(flow.step, .microphone)
        try flow.back()
        XCTAssertEqual(flow.step, .topology)
    }

    func testPresetSurvivesSessionRoundTripAndOldSessionsLoadAsFull() throws {
        let quick = try runningQuickFlow()
        let data = try JSONEncoder().encode(quick)
        XCTAssertEqual(try JSONDecoder().decode(SystemSetupFlow.self, from: data).preset, .quick)
        var full = SystemSetupFlow()
        try full.start(snapshot: state())
        let fullData = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(SystemSetupFlow.self, from: fullData).preset, .full)
    }

    func testFlagIsRegisteredAndDefaultsOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.setupFlow))
        XCTAssertFalse(FeatureFlag.setupFlow.graduated)
    }

    private func waitForVerification(_ model: SystemSetupFlowModel) async {
        for _ in 0..<600 where model.isVerifying { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// The whole quick path through the production model on the reference room, then the full flow over its state.
    func testQuickPathEndsVerifiedAtEveryRateAndFullFlowShowsSameState() async throws {
        for rate in SystemSetupEndToEndTests.rates {
            let rig = try OfflineSetupRig(rate: rate, seats: 3, outputChannels: 2)
            defer { rig.tearDown() }
            let model = rig.model
            let label = "\(rate) Hz"
            model.begin(preset: .quick)
            XCTAssertEqual(model.visibleSteps.count, 8, label)
            model.chooseOutput(uid: OfflineSetupRig.outputUID)
            model.next()
            XCTAssertEqual(model.step, .microphone, "\(label): \(model.message ?? "")")
            model.selectMicrophone(uid: OfflineSetupRig.inputUID)
            model.acceptSweepLevel(measuredSPLdBC: 75)
            model.next()
            XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")
            model.prepareMeasure()
            model.addSeat()
            XCTAssertEqual(model.choices.seatNames.count, 1, "\(label): the quick path adds no extra seat")
            await model.measureAll()
            model.next()
            XCTAssertEqual(model.step, .alignment, "\(label): \(model.message ?? "")")
            await model.computeAlignment()
            model.applyAlignment()
            model.next()
            XCTAssertEqual(model.step, .bass, "\(label): \(model.message ?? "")")
            model.next()
            XCTAssertEqual(model.step, .correction, "\(label): \(model.message ?? "")")
            model.prepareCorrection()
            await model.applyCorrection()
            XCTAssertTrue(model.choices.correctionApplied, "\(label): \(model.message ?? "")")
            rig.trialPlayer.mainDelaySeconds = rig.engine.roomCorrectionConfiguration.lanes?.laneDelays.first { $0.lane == 0 }?.seconds ?? 0
            rig.trialPlayer.mainDelaySeconds += (rig.profiles.selectedSystemProfile?.state.systemArrangement?.stereoAlignment?.left.delayMs ?? 0) / 1_000
            model.next()
            XCTAssertEqual(model.step, .verify, "\(label): \(model.message ?? "")")
            model.runVerification()
            await waitForVerification(model)
            XCTAssertEqual(model.choices.verificationPassed, true, "\(label): \(model.message ?? "")")
            model.next()
            XCTAssertEqual(model.step, .save, "\(label): \(model.message ?? "")")
            model.setProfileName("Quick \(Int(rate))")
            model.save()
            XCTAssertNotNil(model.savedProfileName, "\(label): \(model.message ?? "")")
            XCTAssertTrue(model.quickFinished, label)

            // The full flow opened afterwards starts from the state the quick run left.
            let saved = try XCTUnwrap(rig.profiles.selectedSystemProfile?.state, label)
            model.beginFullAfterQuick()
            XCTAssertEqual(model.preset, .full, label)
            XCTAssertEqual(model.step, .output, label)
            XCTAssertEqual(model.flow.snapshot?.systemArrangement, saved.systemArrangement, label)
            XCTAssertEqual(model.arrangement, saved.systemArrangement, label)
        }
    }
}
