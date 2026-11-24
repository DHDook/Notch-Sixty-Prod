import AppKit
import SwiftUI
import XCTest
@testable import NotchSixty

/// E12 S29: the frame around the guided-setup steps. Pure shell values first, then the production model against the
/// synthetic reference room at the eight standard rates, then the hosted window at the two owner sizes.
@MainActor
final class SystemSetupShellTests: XCTestCase {
    private static var rates: [Double] { SystemSetupEndToEndTests.rates }

    // MARK: Step list, time and reopening

    func testBassIsLeftOutWithoutASubwoofer() {
        let full = SystemSetupPreset.full.steps
        XCTAssertFalse(SystemSetupShell.listedSteps(presetSteps: full, bassIsListed: false).contains(.bass))
        XCTAssertTrue(SystemSetupShell.listedSteps(presetSteps: full, bassIsListed: true).contains(.bass))
        let quick = SystemSetupPreset.quick.steps
        XCTAssertFalse(SystemSetupShell.listedSteps(presetSteps: quick, bassIsListed: true).contains(.topology))
    }

    func testRowsTickFinishedStepsAndOnlyFinishedStepsOpen() {
        let listed = SystemSetupShell.listedSteps(presetSteps: SystemSetupPreset.full.steps, bassIsListed: false)
        let rows = SystemSetupShell.rows(
            listed: listed, current: .measure, completed: [.output, .topology, .microphone], skipped: [.room])
        XCTAssertEqual(rows.first { $0.step == .output }?.state, .done)
        XCTAssertEqual(rows.first { $0.step == .output }?.canOpen, true)
        XCTAssertEqual(rows.first { $0.step == .room }?.state, .done)
        XCTAssertEqual(rows.first { $0.step == .room }?.canOpen, false, "a skipped step was never finished")
        XCTAssertEqual(rows.first { $0.step == .measure }?.state, .current)
        XCTAssertEqual(rows.first { $0.step == .correction }?.state, .upcoming)
        XCTAssertEqual(rows.filter { $0.canOpen }.count, 3)
    }

    func testPositionFollowsTheListedStepsWhenBassIsLeftOut() {
        let listed = SystemSetupShell.listedSteps(presetSteps: SystemSetupPreset.full.steps, bassIsListed: false)
        XCTAssertEqual(listed.count, 9)
        XCTAssertEqual(SystemSetupShell.position(listed: listed, current: .correction).position, 7)
        // A run that lands on the unlisted Bass step stays at the step before it.
        XCTAssertEqual(SystemSetupShell.position(listed: listed, current: .bass).position, 6)
        XCTAssertEqual(SystemSetupShell.position(listed: listed, current: .bass).total, 9)
        let rows = SystemSetupShell.rows(listed: listed, current: .bass, completed: [.alignment], skipped: [])
        XCTAssertEqual(rows.filter { $0.state == .current }.map(\.step), [.alignment])
    }

    func testTimeRemainingFallsAsStepsFinishAndScalesWithSeats() {
        let listed = SystemSetupShell.listedSteps(presetSteps: SystemSetupPreset.full.steps, bassIsListed: true)
        let start = SystemSetupTimeEstimate.minutesRemaining(listed: listed, from: .output, seats: 1)
        let later = SystemSetupTimeEstimate.minutesRemaining(listed: listed, from: .alignment, seats: 1)
        XCTAssertGreaterThan(start, later)
        XCTAssertGreaterThan(SystemSetupTimeEstimate.minutesRemaining(listed: listed, from: .output, seats: 3), start)
        XCTAssertGreaterThan(SystemSetupTimeEstimate.minutesRemaining(listed: listed, from: .save, seats: 1), 0)
        XCTAssertEqual(SystemSetupTimeEstimate.label(minutes: 1), "About a minute left")
        XCTAssertEqual(SystemSetupTimeEstimate.label(minutes: 12), "About 12 minutes left")
    }

    func testFlowReopensOnlyFinishedSteps() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: PlaybackSystemState(associatedOutputUID: "uid-a", outputGainDB: -3), choices: {
            var c = SystemSetupChoices(); c.outputUID = "x"; c.sampleRate = 48_000; c.topology = .stereo; return c
        }())
        try flow.next()
        XCTAssertEqual(flow.step, .topology)
        try flow.reopen(.output)
        XCTAssertEqual(flow.step, .output)
        XCTAssertThrowsError(try flow.reopen(.correction), "an unreached step cannot be opened")
        XCTAssertTrue(flow.completed.contains(.output), "reopening does not undo the step")
    }

    // MARK: Production model at the standard rates

    private func driveToCorrectionApplied(_ rig: OfflineSetupRig, label: String) async throws {
        let model = rig.model
        rig.chooseTwoPointOneThroughWizard()
        model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
        XCTAssertEqual(model.step, .measure, "\(label): \(model.message ?? "")")
        model.prepareMeasure()
        model.addSeat()
        model.addSeat()
        await model.measureAll()
        model.next()
        await model.computeAlignment()
        model.applyAlignment()
        model.next()
        model.computeBass()
        await model.applyBass()
        if let bass = model.bass, bass.mode == .jointOptimised {
            let layout = SyntheticReferenceRoom(rate: rig.rate, seatCount: 3, sourcesPerSeat: 3)
            let range = PhysicalSubwooferCalibration.gainRangeDB
            rig.trialPlayer.subPaths = bass.rows.compactMap { row in
                guard case .subwoofer(let index) = row.source else { return nil }
                return OfflineTrialSweepPlayer.SubPath(
                    lane: 2 + Int(index), room: layout.room(measurement: 2, outputChannel: 2),
                    gainDB: min(range.upperBound, max(range.lowerBound, row.gainDB)),
                    delaySeconds: min(PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound, max(0, row.delayMilliseconds)) / 1_000,
                    inverted: row.polarityInverted)
            }
        }
        model.next()
        model.prepareCorrection()
        await model.applyCorrection()
        XCTAssertTrue(model.choices.correctionApplied, "\(label): \(model.message ?? "")")
    }

    private func secondModel(_ rig: OfflineSetupRig, calibration: MultichannelCalibrationController? = nil) -> SystemSetupFlowModel {
        SystemSetupFlowModel(
            engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
            calibration: calibration ?? rig.calibration,
            sessions: SystemSetupSessionStore(directory: rig.root.appendingPathComponent("sessions")),
            roomProjectsDirectory: rig.root.appendingPathComponent("RoomCorrection"),
            abxDirectory: rig.root.appendingPathComponent("ABX"), abxSwitchHold: 0)
    }

    func testCloseRestoresThenResumeAppliesTheTrialAgain() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            let before = rig.profiles.captureSystemState()
            try await driveToCorrectionApplied(rig, label: label)
            let trialRoom = rig.profiles.captureSystemState().roomCorrection
            XCTAssertNotEqual(trialRoom, before.roomCorrection, label)
            let model = rig.model
            let measurements = rig.calibration.measurements.count
            XCTAssertGreaterThan(measurements, 0, label)

            model.closeForLater()
            XCTAssertNil(model.restoreFailure, label)
            XCTAssertEqual(rig.profiles.captureSystemState().roomCorrection, before.roomCorrection, "\(label): room correction restored")
            XCTAssertEqual(rig.profiles.captureSystemState().bassManagement, before.bassManagement, "\(label): bass restored")
            XCTAssertEqual(rig.calibration.measurements.count, measurements, "\(label): measurements kept")

            let resumed = secondModel(rig)
            resumed.begin()
            XCTAssertTrue(resumed.isRunning, label)
            XCTAssertEqual(resumed.step, .correction, "\(label): \(resumed.message ?? "")")
            await resumed.reapplyTask?.value
            XCTAssertTrue(resumed.choices.alignmentApplied, "\(label): \(resumed.message ?? "")")
            XCTAssertTrue(resumed.choices.bassApplied, "\(label): \(resumed.message ?? "")")
            XCTAssertTrue(resumed.choices.correctionApplied, "\(label): \(resumed.message ?? "")")
            XCTAssertNil(resumed.choices.verificationPassed, "\(label): verification is earned again")
            XCTAssertNotEqual(rig.profiles.captureSystemState().roomCorrection, before.roomCorrection, "\(label): trial applied again")
            XCTAssertFalse(resumed.isReapplying, label)
        }
    }

    func testCloseAfterNothingWasAppliedKeepsTheSessionAndRestoresNothingNew() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        rig.chooseTwoPointOneThroughWizard()
        rig.model.closeForLater()
        XCTAssertNil(rig.model.restoreFailure)
        let resumed = secondModel(rig)
        resumed.begin()
        XCTAssertTrue(resumed.isRunning)
        XCTAssertNil(resumed.reapplyTask, "nothing was applied, so nothing is applied again")
    }

    func testMeasurementsSurviveARelaunch() async throws {
        for rate in [48_000.0, 384_000.0] {
            let rig = try OfflineSetupRig(rate: rate, seats: 1)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            rig.chooseTwoPointOneThroughWizard()
            rig.model.selectMicrophone(uid: OfflineSetupRig.inputUID)
            rig.model.acceptSweepLevel(measuredSPLdBC: 75)
            rig.model.next()
            rig.model.next()
            rig.model.prepareMeasure()
            await rig.model.measureAll()
            let measured = rig.calibration.measurements.count
            XCTAssertGreaterThan(measured, 0, label)
            rig.model.next()
            rig.model.closeForLater()

            // A relaunch: a new calibration controller reads the saved campaign; nothing is held in memory.
            let relaunched = MultichannelCalibrationController(
                engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
                store: MultichannelCalibrationCampaignStore(rootDirectory: rig.root.appendingPathComponent("campaigns")),
                transportFactory: { _, _, _, _, _, _ in throw CocoaError(.fileNoSuchFile) })
            relaunched.prepareForUse()
            XCTAssertEqual(relaunched.measurements.count, 0, "\(label): closing put the earlier routing back, so the campaign is dropped")
            let resumed = secondModel(rig, calibration: relaunched)
            resumed.begin()
            XCTAssertEqual(resumed.step, .alignment, "\(label): \(resumed.message ?? "")")
            XCTAssertEqual(resumed.choices.measurementIDs.count, 1, label)
            XCTAssertEqual(relaunched.measurements.count, measured, "\(label): the kept measurements are back")
        }
    }

    /// A relaunch without Close: the session holds only IDs, and the saved campaign holds the measurements (G68).
    func testMeasurementsSurviveARelaunchWithoutClosing() async throws {
        for rate in [48_000.0, 384_000.0] {
            let rig = try OfflineSetupRig(rate: rate, seats: 1)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            rig.chooseTwoPointOneThroughWizard()
            rig.model.selectMicrophone(uid: OfflineSetupRig.inputUID)
            rig.model.acceptSweepLevel(measuredSPLdBC: 75)
            rig.model.next()
            rig.model.next()
            rig.model.prepareMeasure()
            await rig.model.measureAll()
            let measured = rig.calibration.measurements.count
            rig.model.next()
            let relaunched = MultichannelCalibrationController(
                engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
                store: MultichannelCalibrationCampaignStore(rootDirectory: rig.root.appendingPathComponent("campaigns")),
                transportFactory: { _, _, _, _, _, _ in throw CocoaError(.fileNoSuchFile) })
            relaunched.prepareForUse()
            XCTAssertEqual(relaunched.measurements.count, measured, "\(label): the saved campaign holds the measurements")
            let resumed = secondModel(rig, calibration: relaunched)
            resumed.begin()
            XCTAssertEqual(resumed.step, .alignment, "\(label): \(resumed.message ?? "")")
        }
    }

    func testCancelAsksOnlyOnceSomethingIsMeasured() async throws {
        let rig = try OfflineSetupRig(rate: 48_000, seats: 1)
        defer { rig.tearDown() }
        rig.chooseTwoPointOneThroughWizard()
        XCTAssertFalse(rig.model.cancelNeedsConfirmation)
        rig.model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        rig.model.acceptSweepLevel(measuredSPLdBC: 75)
        rig.model.next()
        rig.model.next()
        rig.model.prepareMeasure()
        await rig.model.measureAll()
        XCTAssertTrue(rig.model.cancelNeedsConfirmation)
    }

    func testAFailedRestoreIsHeldForTheDialogOnCancelAndOnClose() throws {
        for close in [false, true] {
            let rig = try OfflineSetupRig(rate: 48_000)
            defer { rig.tearDown() }
            rig.chooseTwoPointOneThroughWizard()
            rig.model.restoreOverride = { _ in "Restoring the previous settings failed: test." }
            if close { rig.model.closeForLater() } else { rig.model.cancel() }
            XCTAssertEqual(rig.model.restoreFailure, "Restoring the previous settings failed: test.", "close=\(close)")
            XCTAssertNil(rig.model.message, "the failure is the dialog's, not a line that disappears with the sheet")
        }
    }

    func testRefusalsAreShownBesideNextAndNextIsDisabledWithThem() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        rig.model.begin()
        XCTAssertNil(rig.model.nextBlockedReason, "an output is chosen")
        rig.model.chooseOutput(uid: OfflineSetupRig.outputUID)
        rig.model.chooseChannelCount(3)
        rig.model.next()
        rig.model.chooseBass(.dspToSubOutputs)
        rig.model.next()
        XCTAssertEqual(rig.model.step, .microphone)
        XCTAssertEqual(rig.model.nextBlockedReason, rig.model.flow.unmetPrecondition(for: .microphone))
        rig.model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        XCTAssertEqual(rig.model.nextBlockedReason, "Set the sweep level first.")
        rig.model.acceptSweepLevel(measuredSPLdBC: 75)
        XCTAssertNil(rig.model.nextBlockedReason)
    }

    func testMicrophoneCalibrationImportsInsideTheStep() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        rig.chooseTwoPointOneThroughWizard()
        rig.model.selectMicrophone(uid: OfflineSetupRig.inputUID)
        rig.model.importMicrophoneCalibration(text: "20 0.5\n1000 0\n20000 -1\n", sourceName: "umik.txt")
        XCTAssertNil(rig.model.message)
        XCTAssertNotNil(rig.microphone.microphoneCalibration)
        XCTAssertEqual(rig.model.choices.microphoneCalibrationFile, "umik.txt")
        rig.model.clearMicrophoneCalibration()
        XCTAssertNil(rig.microphone.microphoneCalibration)
        XCTAssertNil(rig.model.choices.microphoneCalibrationFile)
        rig.model.importMicrophoneCalibration(text: "not a file", sourceName: "bad.txt")
        XCTAssertNotNil(rig.model.message)
    }

    func testSaveShowsASummaryAndBeforeAfterUsesTheAuditionSwitch() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try await driveToCorrectionApplied(rig, label: "summary")
        let model = rig.model
        rig.trialPlayer.mainDelaySeconds = rig.engine.roomCorrectionConfiguration.lanes?.laneDelays.first { $0.lane == 0 }?.seconds ?? 0
        model.next()
        XCTAssertEqual(model.step, .verify, model.message ?? "")
        model.runVerification()
        for _ in 0..<600 where model.isVerifying { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.choices.verificationPassed, true, "\(model.message ?? "") \(String(describing: model.verificationSummary))")
        model.next()
        XCTAssertEqual(model.step, .save, model.message ?? "")
        model.setProfileName("Summary test")
        model.save()
        let summary = try XCTUnwrap(model.summary, model.message ?? "")
        XCTAssertEqual(summary.profileName, model.savedProfileName)
        XCTAssertTrue(summary.lines.contains { $0.hasPrefix("Output:") })
        XCTAssertTrue(summary.lines.contains("Bass blended"))
        XCTAssertTrue(summary.lines.contains { $0.hasPrefix("Room correction on") })
        model.toggleBeforeAfter()
        XCTAssertTrue(model.comparingBefore)
        XCTAssertEqual(rig.engine.playbackControlConfiguration.auditionMode, .reference)
        model.endComparison()
        XCTAssertEqual(rig.engine.playbackControlConfiguration.auditionMode, .processed)
    }

    // MARK: Menu command

    func testMenuCommandAsksForTheFullSetupOnTheSystemArea() {
        let navigation = ProductionNavigation()
        navigation.selection = .dashboard
        SystemSetupMenuCommand.perform(navigation: navigation)
        XCTAssertEqual(navigation.requestedGuidedSetup, .full)
        XCTAssertEqual(navigation.selection, .system)
    }

    // MARK: Screen fit (AGENTS.md section 13)

    func testWindowFitsAtTheOwnerSizesAndNextCarriesItsReason() throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        let product = ProductController(audioEngine: rig.engine)
        for size in [CGSize(width: 1_280, height: 800), CGSize(width: 1_920, height: 1_000)] {
            let view = ProductionSystemSetupFlowView(
                engine: rig.engine, profiles: rig.profiles, microphone: rig.microphone,
                calibration: rig.calibration, advisor: product.roomTreatmentAdvisor)
            let page = HostedPage(view, size: size)
            // SwiftUI buttons are not AppKit controls here, so read every laid-out view's frame instead.
            var views = 0
            func walk(_ v: NSView) {
                let frame = v.convert(v.bounds, to: page.hosting)
                if !(v is NSScroller), frame.width > 0 {
                    views += 1
                    XCTAssertGreaterThanOrEqual(frame.minX, -0.5, "\(type(of: v)) starts left of the window at \(size.width)")
                    XCTAssertLessThanOrEqual(frame.maxX, size.width + 0.5, "\(type(of: v)) ends past the window at \(size.width)")
                }
                v.subviews.forEach(walk)
            }
            walk(page.hosting)
            XCTAssertGreaterThan(views, 12, "the sheet laid out its step list, header and footer at \(size.width)")
        }
    }
}
