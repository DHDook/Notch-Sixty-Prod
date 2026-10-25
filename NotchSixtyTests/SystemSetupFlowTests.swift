import XCTest
@testable import NotchSixty

@MainActor
final class SystemSetupFlowTests: XCTestCase {
    private func baseState() -> PlaybackSystemState {
        var s = PlaybackSystemState(associatedOutputUID: "uid-a", outputGainDB: -3)
        s.bassManagement.subGainDB = 2
        return s
    }

    private func fill(_ flow: inout SystemSetupFlow, through step: SystemSetupStep, subwoofer: Bool = true) throws {
        let steps = SystemSetupStep.allCases
        for s in steps {
            if s == step { return }
            switch s {
            case .output: flow.choices.outputUID = "uid-a"; flow.choices.sampleRate = 48_000
            case .topology: flow.choices.topology = subwoofer ? .twoPointOne : .stereo
            case .microphone: flow.choices.microphoneUID = "mic"; flow.choices.sweepLevelDBFS = -20
            case .room: try flow.skip(); continue
            case .measure:
                flow.choices.seatNames = ["Main"]
                flow.choices.measurementIDs = [UUID()]
            case .alignment: flow.choices.alignmentApplied = true
            case .bass:
                if subwoofer { flow.choices.bassApplied = true } else { try flow.skip(); continue }
            case .correction: flow.choices.correctionApplied = true
            case .verify: flow.choices.verificationPassed = true
            case .save: return
            }
            try flow.next()
        }
    }

    func testNextRefusedUntilPreconditionsHold() throws {
        var flow = SystemSetupFlow()
        XCTAssertThrowsError(try flow.next()) { XCTAssertEqual($0 as? SystemSetupRefusal, .notRunning) }
        try flow.start(snapshot: baseState())
        for step in SystemSetupStep.allCases where step != .room && step != .save {
            var f = SystemSetupFlow()
            try f.start(snapshot: baseState())
            try fill(&f, through: step)
            XCTAssertEqual(f.step, step)
            if step == .bass { continue }
            XCTAssertThrowsError(try f.next(), "\(step)") {
                guard case .preconditionNotMet(let s, let why)? = $0 as? SystemSetupRefusal else {
                    return XCTFail("wrong refusal")
                }
                XCTAssertEqual(s, step)
                XCTAssertFalse(why.isEmpty)
            }
            XCTAssertEqual(f.step, step)
        }
    }

    func testForwardAndBackTransitions() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        XCTAssertThrowsError(try flow.back()) { XCTAssertEqual($0 as? SystemSetupRefusal, .atFirstStep) }
        try fill(&flow, through: .save)
        XCTAssertEqual(flow.step, .save)
        XCTAssertThrowsError(try flow.next()) { _ in }
        try flow.back()
        XCTAssertEqual(flow.step, .verify)
        XCTAssertThrowsError(try flow.start(snapshot: baseState())) {
            XCTAssertEqual($0 as? SystemSetupRefusal, .alreadyRunning)
        }
    }

    func testSkipRules() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        XCTAssertThrowsError(try flow.skip()) { XCTAssertEqual($0 as? SystemSetupRefusal, .cannotSkip(.output)) }
        try fill(&flow, through: .room)
        try flow.skip()
        XCTAssertEqual(flow.step, .measure)
        XCTAssertTrue(flow.skipped.contains(.room))
        XCTAssertThrowsError(try flow.skip()) { XCTAssertEqual($0 as? SystemSetupRefusal, .cannotSkip(.measure)) }

        var withSub = SystemSetupFlow()
        try withSub.start(snapshot: baseState())
        try fill(&withSub, through: .bass, subwoofer: true)
        XCTAssertFalse(withSub.canSkip(.bass))
        var stereo = SystemSetupFlow()
        try stereo.start(snapshot: baseState())
        try fill(&stereo, through: .bass, subwoofer: false)
        XCTAssertTrue(stereo.canSkip(.bass))
    }

    func testFailAndRetry() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        flow.fail("boom")
        XCTAssertEqual(flow.phase, .failed("boom"))
        XCTAssertThrowsError(try flow.next())
        try flow.retry()
        XCTAssertEqual(flow.phase, .running)
    }

    func testFinishRules() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        try fill(&flow, through: .save)
        XCTAssertEqual(flow.step, .save)
        XCTAssertThrowsError(try flow.finish()) { XCTAssertEqual($0 as? SystemSetupRefusal, .missingName) }
        flow.choices.profileName = "Lounge"
        flow.choices.designKind = .mixedPhase
        flow.choices.verificationPassed = nil
        XCTAssertThrowsError(try flow.finish()) {
            XCTAssertEqual($0 as? SystemSetupRefusal, .mixedPhaseNeedsVerification)
        }
        flow.choices.designKind = .minimumPhase
        XCTAssertTrue(flow.savesAsNotVerified)
        try flow.finish()
        XCTAssertEqual(flow.phase, .finished)
    }

    func testCancelFromEveryStepRestoresSnapshotBitForBit() async throws {
        let original = baseState()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let originalJSON = try encoder.encode(original)
        for step in SystemSetupStep.allCases {
            let services = SimulatedSystemSetupServices(initial: original)
            let driver = SystemSetupDriver(services: services, current: original)
            try driver.start()
            try driver.update { _ in }
            var flow = driver.flow
            try fill(&flow, through: step)
            // Drive the trial changes the services would have applied by this step.
            await driver.applyAlignment()
            await driver.applyBass()
            await driver.applyCorrection()
            await driver.cancel()
            let live = await services.live
            XCTAssertEqual(live, original, "\(step)")
            XCTAssertEqual(try encoder.encode(live), originalJSON, "\(step)")
            XCTAssertEqual(driver.flow.phase, .cancelled)
            XCTAssertEqual(driver.working, original)
        }
    }

    func testSessionRoundTripAndResume() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        try fill(&flow, through: .measure)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n60-e12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SystemSetupSessionStore(directory: dir)
        let session = SystemSetupSession(
            playbackSystemKey: "uid/a b", updatedAt: Date(timeIntervalSince1970: 1_000), flow: flow)
        try store.save(session)
        let loaded = try XCTUnwrap(store.load(key: "uid/a b"))
        XCTAssertEqual(loaded, session)
        XCTAssertEqual(loaded.flow.step, .measure)
        XCTAssertEqual(loaded.flow.snapshot, baseState())
        XCTAssertNil(store.load(key: "other"))
        store.delete(key: "uid/a b")
        XCTAssertNil(store.load(key: "uid/a b"))
    }

    func testSessionFromNewerSchemaIsIgnored() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n60-e12-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SystemSetupSessionStore(directory: dir)
        var session = SystemSetupSession(playbackSystemKey: "k", updatedAt: Date(), flow: flow)
        session.schemaVersion = 99
        try store.save(session)
        XCTAssertNil(store.load(key: "k"))
    }

    func testDeviceOrRateChangeInvalidatesMeasurementSteps() throws {
        for change in [("uid-b", 48_000.0), ("uid-a", 96_000.0)] {
            var flow = SystemSetupFlow()
            try flow.start(snapshot: baseState())
            try fill(&flow, through: .verify)
            XCTAssertEqual(flow.step, .verify)
            flow.outputConfigurationChanged(outputUID: change.0, sampleRate: change.1)
            XCTAssertEqual(flow.step, .measure)
            XCTAssertTrue(flow.choices.measurementIDs.isEmpty)
            XCTAssertFalse(flow.choices.alignmentApplied || flow.choices.bassApplied || flow.choices.correctionApplied)
            XCTAssertNil(flow.choices.verificationPassed)
            XCTAssertTrue(flow.completed.isDisjoint(with: [.measure, .alignment, .bass, .correction, .verify]))
            XCTAssertTrue(flow.completed.isSuperset(of: [.output, .topology, .microphone]))
            XCTAssertNotNil(flow.invalidationReason)
        }
        var early = SystemSetupFlow()
        try early.start(snapshot: baseState())
        early.outputConfigurationChanged(outputUID: "x", sampleRate: 44_100)
        XCTAssertEqual(early.step, .output)
        XCTAssertNil(early.invalidationReason)
    }

    func testVerificationFailureRevertsAndReturnsToCorrection() async throws {
        let original = baseState()
        let services = SimulatedSystemSetupServices(initial: original)
        await services.setVerificationPasses(false)
        let driver = SystemSetupDriver(services: services, current: original)
        try driver.start()
        driver.update { $0.designKind = .mixedPhase; $0.outputUID = "uid-a"; $0.sampleRate = 48_000
            $0.topology = .twoPointOne; $0.microphoneUID = "m"; $0.sweepLevelDBFS = -20
            $0.seatNames = ["Main"] }
        await driver.applyAlignment()
        await driver.applyBass()
        let beforeCorrection = driver.working
        await driver.applyCorrection()
        XCTAssertNotEqual(driver.working, beforeCorrection)
        await driver.runVerification()
        XCTAssertEqual(driver.flow.step, .correction)
        XCTAssertFalse(driver.flow.choices.correctionApplied)
        XCTAssertEqual(driver.working, beforeCorrection)
        let live = await services.live
        XCTAssertEqual(live, beforeCorrection)
    }

    func testMeasurementFailureStopsFlow() async throws {
        let services = SimulatedSystemSetupServices(initial: baseState())
        await services.setFailMeasureAtSeat(1)
        let driver = SystemSetupDriver(services: services, current: baseState())
        try driver.start()
        driver.update { $0.sampleRate = 48_000; $0.seatNames = ["A", "B"] }
        await driver.measureSeats()
        guard case .failed = driver.flow.phase else { return XCTFail("expected failure") }
        XCTAssertEqual(driver.flow.choices.measurementIDs.count, 1)
    }

    func testSimulatedFlowReachesSaveAtStandardRates() async throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let original = baseState()
            let services = SimulatedSystemSetupServices(initial: original)
            let driver = SystemSetupDriver(services: services, current: original)
            try driver.start()
            driver.update {
                $0.outputUID = "uid-a"; $0.sampleRate = rate
            }
            try driver.next()
            driver.update { $0.topology = .twoPointOne }
            try driver.next()
            driver.update { $0.microphoneUID = "mic"; $0.sweepLevelDBFS = -20 }
            try driver.next()
            try driver.skip() // room
            driver.update { $0.seatNames = ["Main", "Left", "Right"] }
            await driver.measureSeats()
            try driver.next()
            await driver.applyAlignment(); try driver.next()
            await driver.applyBass(); try driver.next()
            await driver.applyCorrection(); try driver.next()
            await driver.runVerification()
            XCTAssertEqual(driver.flow.choices.verificationPassed, true, "\(rate)")
            XCTAssertEqual(driver.report?.sampleRate, rate)
            try driver.next()
            XCTAssertEqual(driver.flow.step, .save)
            driver.update { $0.profileName = "Lounge" }
            await driver.finish()
            XCTAssertEqual(driver.flow.phase, .finished, "\(rate)")
            XCTAssertEqual(driver.savedProfile?.name, "Lounge")
            XCTAssertFalse(driver.flow.savesAsNotVerified)
            XCTAssertEqual(driver.working.bassManagement.subGainDB, 2.5)
            XCTAssertTrue(driver.working.roomCorrection.enabled)
        }
    }
}
