import XCTest
@testable import NotchSixty

extension OfflineSetupRig {
    /// Drives the guided flow through the production model to the Save step (applied design is mixed phase).
    func driveToSave(label: String) async throws {
        try installTwoPointOneProfile()
        model.begin()
        model.chooseOutput(uid: Self.outputUID)
        model.next()
        model.chooseTopology(.twoPointOne)
        model.next()
        model.selectMicrophone(uid: Self.inputUID)
        model.acceptSweepLevel(measuredSPLdBC: 75)
        model.next()
        model.next()
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
            let layout = SyntheticReferenceRoom(rate: rate, seatCount: 3, sourcesPerSeat: 3)
            let range = PhysicalSubwooferCalibration.gainRangeDB
            trialPlayer.subPaths = bass.rows.compactMap { row in
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
        trialPlayer.mainDelaySeconds = engine.roomCorrectionConfiguration.lanes?.laneDelays.first { $0.lane == 0 }?.seconds ?? 0
        model.next()
        try await verify(label: label)
        model.next()
        XCTAssertEqual(model.step, .save, "\(label): \(model.message ?? "")")
    }

    func verify(label: String) async throws {
        model.runVerification()
        for _ in 0..<600 where model.isVerifying { try? await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(model.choices.verificationPassed, true, "\(label): \(model.message ?? "")")
    }

    /// Plays every trial of the open run, answering right or wrong from what the fake player was handed.
    func runABXTrials(correct: Bool) throws {
        let controller = try XCTUnwrap(model.abx)
        for _ in 0..<controller.totalTrials {
            controller.select(.x)
            let handed = try XCTUnwrap(abxPlayer.played.last)
            // B is the mixed-phase (music latency mode) design; A is the video-mode minimum phase one.
            let xIsB = handed.install.design.latencyMode != .video
            controller.answer(xIsB: correct ? xIsB : !xIsB)
        }
    }
}

/// E24 S9: Keep A / Keep B after a finished blind ABX, through the production setup model.
@MainActor
final class SystemSetupABXKeepTests: XCTestCase {
    static var rates: [Double] {
        if let list = ProcessInfo.processInfo.environment["N60_E24_RATES"] {
            let parsed = list.split(separator: ",").compactMap { Double($0) }
            if !parsed.isEmpty { return parsed }
        }
        return [48_000, 384_000]
    }

    func testABXIsOfferedOnlyWhenPlayable() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        XCTAssertEqual(rig.model.abxUnavailableReason, "Apply the correction first.")
        try await rig.driveToSave(label: "gate")
        XCTAssertNil(rig.model.abxUnavailableReason)
        rig.abxPlayer.unavailableReason = "Start playback with music to compare by ear."
        XCTAssertEqual(rig.model.abxUnavailableReason, "Start playback with music to compare by ear.")
        await rig.model.openABX()
        XCTAssertNil(rig.model.abx)
    }

    func testKeepingTheAppliedDesignChangesNothing() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            try await rig.driveToSave(label: label)
            let before = rig.engine.roomCorrectionConfiguration
            await rig.model.openABX()
            let controller = try XCTUnwrap(rig.model.abx, "\(label): \(rig.model.message ?? "")")
            XCTAssertEqual(rig.model.step, .save)
            try rig.runABXTrials(correct: true)
            controller.submitPreference(.b)
            XCTAssertEqual(controller.phase, .finished, label)
            rig.model.keepABXCandidate(.mixedPhase)
            XCTAssertNil(rig.model.abx, label)
            XCTAssertEqual(rig.engine.roomCorrectionConfiguration, before, label)
            XCTAssertEqual(rig.model.choices.designKind, .mixedPhase, label)
            XCTAssertEqual(rig.model.choices.verificationPassed, true, label)
            XCTAssertEqual(rig.model.step, .save, label)
            XCTAssertGreaterThanOrEqual(rig.abxPlayer.restoreCount, 1, label)
        }
    }

    func testKeepingTheOtherDesignWritesItAndReturnsToVerify() async throws {
        for rate in Self.rates {
            let rig = try OfflineSetupRig(rate: rate)
            defer { rig.tearDown() }
            let label = "\(rate) Hz"
            try await rig.driveToSave(label: label)
            let before = rig.engine.roomCorrectionConfiguration
            await rig.model.openABX()
            let controller = try XCTUnwrap(rig.model.abx, "\(label): \(rig.model.message ?? "")")
            try rig.runABXTrials(correct: true)
            controller.submitPreference(.a)
            rig.model.keepABXCandidate(.minimumPhase)
            XCTAssertNil(rig.model.abx, label)
            XCTAssertNotEqual(rig.engine.roomCorrectionConfiguration.lanes, before.lanes, label)
            XCTAssertEqual(rig.engine.roomCorrectionConfiguration.lanes?.design.latencyMode, .video, label)
            XCTAssertEqual(rig.model.choices.designKind, .minimumPhase, label)
            XCTAssertNotEqual(rig.model.choices.verificationPassed, true, label)
            XCTAssertEqual(rig.model.step, .verify, label)
            // Save is blocked until the kept design is verified.
            rig.model.save()
            XCTAssertNil(rig.model.savedProfileName, label)
            try await rig.verify(label: label)
            rig.model.next()
            XCTAssertEqual(rig.model.step, .save, "\(label): \(rig.model.message ?? "")")
            rig.model.setProfileName("ABX keep \(Int(rate))")
            rig.model.save()
            XCTAssertNotNil(rig.model.savedProfileName, "\(label): \(rig.model.message ?? "")")
            let saved = try XCTUnwrap(rig.profiles.selectedSystemProfile)
            XCTAssertEqual(saved.state.roomCorrection.lanes?.design.latencyMode, .video, label)
        }
    }

    func testKeepIsRefusedBeforeTheRunIsFinishedAndWhenMixedPhaseDoesNotFit() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try await rig.driveToSave(label: "refuse")
        await rig.model.openABX()
        let controller = try XCTUnwrap(rig.model.abx)
        let before = rig.engine.roomCorrectionConfiguration
        rig.model.keepABXCandidate(.minimumPhase)
        XCTAssertNotNil(rig.model.abx, "Keep before the names are shown does nothing")
        XCTAssertEqual(rig.engine.roomCorrectionConfiguration, before)
        try rig.runABXTrials(correct: true)
        controller.submitPreference(.b)
        rig.model.abxMixedFitsEveryRate = false
        XCTAssertNotNil(rig.model.keepMixedPhaseUnavailableReason)
        rig.model.keepABXCandidate(.mixedPhase)
        XCTAssertNotNil(rig.model.abx, "an over-budget Keep B is refused")
        XCTAssertNotNil(rig.model.message)
        rig.model.closeABX()
        XCTAssertNil(rig.model.abx)
        XCTAssertEqual(rig.engine.roomCorrectionConfiguration, before)
    }

    func testCancelClosesTheRun() async throws {
        let rig = try OfflineSetupRig(rate: 48_000)
        defer { rig.tearDown() }
        try await rig.driveToSave(label: "cancel")
        await rig.model.openABX()
        XCTAssertNotNil(rig.model.abx)
        rig.model.cancel()
        XCTAssertNil(rig.model.abx)
        XCTAssertGreaterThanOrEqual(rig.abxPlayer.restoreCount, 1)
    }
}
