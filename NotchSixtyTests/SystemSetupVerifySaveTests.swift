import XCTest
@testable import NotchSixty

@MainActor
final class SystemSetupVerifySaveTests: XCTestCase {
    private func baseState() -> PlaybackSystemState {
        var s = PlaybackSystemState(associatedOutputUID: "uid-a", outputGainDB: -3)
        s.bassManagement.subGainDB = 2
        return s
    }

    private func finding(
        _ kind: RoomTreatmentAdvisorFindingKind, _ severity: RoomTreatmentAdvisorSeverity, id: String
    ) -> RoomTreatmentAdvisorFinding {
        RoomTreatmentAdvisorFinding(
            id: id, kind: kind, severity: severity, title: "T-\(id)", measuredEvidence: "", interpretation: "",
            recommendation: "R-\(id)", primaryRemedy: .passiveTreatment, confidence: 0.8)
    }

    private func report(
        findings: [RoomTreatmentAdvisorFinding], decay: [RoomTreatmentAdvisorBandDecay] = []
    ) -> RoomTreatmentAdvisorReport {
        RoomTreatmentAdvisorReport(
            projectID: UUID(), projectName: "p", retainedMeasurementCount: 3, includedMeasurementCount: 3,
            analysisMode: .multiPosition, microphoneName: nil, calibratedMicrophone: true, qualityWarnings: [],
            findings: findings, actionPriorities: [], bandDecayMeasurements: decay)
    }

    private func driverToVerify(
        _ services: SimulatedSystemSetupServices, designKind: SystemSetupDesignKind
    ) async throws -> SystemSetupDriver {
        let driver = SystemSetupDriver(services: services, current: baseState())
        try driver.start()
        driver.update {
            $0.designKind = designKind; $0.outputUID = "uid-a"; $0.sampleRate = 48_000
            $0.topology = .twoPointOne; $0.microphoneUID = "m"; $0.sweepLevelDBFS = -20; $0.seatNames = ["Main"]
        }
        await driver.measureSeats()
        await driver.applyAlignment()
        await driver.applyBass()
        await driver.applyCorrection()
        return driver
    }

    // MARK: Summary and labels

    func testSummaryVerdicts() {
        let pass = SystemSetupVerificationReport(passed: true, predictedErrorDB: 1, measuredErrorDB: 1.2, sampleRate: 48_000)
        let miss = SystemSetupVerificationReport(passed: false, predictedErrorDB: 1, measuredErrorDB: 6, sampleRate: 48_000)
        XCTAssertEqual(SystemSetupVerificationSummary.make(report: pass, designKind: .mixedPhase).verdict, .verified)
        XCTAssertEqual(SystemSetupVerificationSummary.make(report: miss, designKind: .minimumPhase).verdict, .notVerified)
        XCTAssertEqual(SystemSetupVerificationSummary.make(report: miss, designKind: .mixedPhase).verdict, .failed)
        let none = SystemSetupVerificationSummary.make(report: nil, designKind: .minimumPhase)
        XCTAssertEqual(none.verdict, .notVerified)
        XCTAssertEqual(none.headline, "Not verified")
    }

    func testUnconnectedMeasurerNeverReportsPassed() async {
        let measurer = UnconnectedSystemSetupPostApplyMeasurer()
        do {
            _ = try await measurer.measureMainSeat(predictedErrorDB: 1, sampleRate: 48_000)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? SystemSetupVerificationError, .measurementUnavailable)
        }
    }

    func testPostApplyReportMapping() {
        let post = RoomCorrectionPostApplyReport(
            designID: "d", sampleRate: 96_000, outcome: .magnitudeMismatch, detail: "", centres: [], predictedDB: [],
            measuredDB: [], maxMagnitudeErrorDB: 4.5, predictedExcessGroupDelaySeconds: 0,
            measuredExcessGroupDelaySeconds: 0, criteria: RoomCorrectionPostApplyCriteria(), date: Date())
        let mapped = SystemSetupVerificationReport(postApply: post, predictedErrorDB: 1.5)
        XCTAssertFalse(mapped.passed)
        XCTAssertEqual(mapped.measuredErrorDB, 4.5)
        XCTAssertEqual(mapped.predictedErrorDB, 1.5)
        XCTAssertEqual(mapped.sampleRate, 96_000)
    }

    func testSaveNaming() {
        XCTAssertEqual(SystemSetupSaveNaming.profileName(" Lounge ", notVerified: false), "Lounge")
        XCTAssertEqual(SystemSetupSaveNaming.profileName("Lounge", notVerified: true), "Lounge (Not verified)")
        XCTAssertEqual(
            SystemSetupSaveNaming.profileName("Lounge (Not verified)", notVerified: true), "Lounge (Not verified)")
        XCTAssertEqual(SystemSetupSaveNaming.defaultName(outputName: nil), "My system")
        XCTAssertEqual(SystemSetupSaveNaming.defaultName(outputName: "Studio"), "Studio setup")
    }

    // MARK: Room insights

    func testInsightsKeepOnlyProblemsEQCannotFix() {
        let insights = SystemSetupRoomInsights.make(report: report(findings: [
            finding(.spatialBassVariation, .important, id: "a"),
            finding(.lowFrequencyRinging, .opportunity, id: "b"),
            finding(.deepBassCancellation, .important, id: "c"),
            finding(.earlyReflection, .information, id: "d"),
        ]))
        XCTAssertEqual(insights.map(\.id), ["c", "b"])
        XCTAssertTrue(insights[0].isImportant)
        XCTAssertEqual(insights[1].detail, "R-b")
        XCTAssertTrue(SystemSetupRoomInsights.make(report: nil).isEmpty)
    }

    func testLongLowBandDecayAddsInsight() {
        func decay(_ f: Double, _ t: Double, r2: Double = 0.95) -> RoomTreatmentAdvisorBandDecay {
            .init(positionName: "Main", channelName: "L", frequencyHz: f, t20DerivedRT60Seconds: t, fitR2: r2)
        }
        let long = SystemSetupRoomInsights.make(report: report(findings: [], decay: [decay(63, 0.9), decay(125, 0.7)]))
        XCTAssertEqual(long.map(\.id), ["rt60"])
        let short = SystemSetupRoomInsights.make(report: report(findings: [], decay: [decay(63, 0.3), decay(125, 0.4)]))
        XCTAssertTrue(short.isEmpty)
        let poorFit = SystemSetupRoomInsights.make(report: report(findings: [], decay: [decay(63, 2.0, r2: 0.3)]))
        XCTAssertTrue(poorFit.isEmpty)
        let highBand = SystemSetupRoomInsights.make(report: report(findings: [], decay: [decay(1000, 2.0)]))
        XCTAssertTrue(highBand.isEmpty)
    }

    // MARK: Resume

    func testResumeWithoutMeasurementsReturnsToMeasure() throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        flow.choices.outputUID = "uid-a"; flow.choices.sampleRate = 48_000; try flow.next()
        flow.choices.topology = .twoPointOne; try flow.next()
        flow.choices.microphoneUID = "m"; flow.choices.sweepLevelDBFS = -20; try flow.next()
        try flow.skip()
        flow.choices.seatNames = ["Main"]; flow.choices.measurementIDs = [UUID()]; try flow.next()
        flow.choices.alignmentApplied = true; try flow.next()
        XCTAssertEqual(flow.step, .bass)

        var kept = flow
        kept.resumed(measurementsAvailable: true)
        XCTAssertEqual(kept.step, .bass)

        flow.resumed(measurementsAvailable: false)
        XCTAssertEqual(flow.step, .measure)
        XCTAssertTrue(flow.choices.measurementIDs.isEmpty)
        XCTAssertFalse(flow.choices.alignmentApplied)
        XCTAssertNotNil(flow.invalidationReason)
        // Steps before Measure are kept.
        XCTAssertTrue(flow.completed.contains(.topology))
    }

    func testSessionResumesAtVerifyStepThroughTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("n60-s6-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SystemSetupSessionStore(directory: dir)
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        flow.choices.outputUID = "uid-a"; flow.choices.sampleRate = 48_000
        flow.choices.verificationPassed = false
        flow.choices.profileName = "Den"
        try store.save(SystemSetupSession(playbackSystemKey: "k", updatedAt: Date(), flow: flow))
        let loaded = try XCTUnwrap(store.load(key: "k")?.flow)
        XCTAssertEqual(loaded, flow)
        XCTAssertEqual(loaded.choices.profileName, "Den")
        XCTAssertTrue(loaded.savesAsNotVerified)
    }

    // MARK: Driver: verify, timeout, cancel, save

    func testTimeoutRevertsAndReturnsToCorrection() async throws {
        let services = SimulatedSystemSetupServices(initial: baseState())
        let driver = try await driverToVerify(services, designKind: .minimumPhase)
        let beforeCorrection = await services.live
        XCTAssertNotEqual(driver.working.roomCorrection.enabled, baseState().roomCorrection.enabled)
        await services.setVerifyDelaySeconds(5)
        await driver.runVerification(timeoutSeconds: 0.05)
        XCTAssertEqual(driver.flow.step, .correction)
        XCTAssertFalse(driver.flow.choices.correctionApplied)
        XCTAssertNil(driver.flow.choices.verificationPassed)
        XCTAssertEqual(driver.working.roomCorrection, baseState().roomCorrection)
        let live = await services.live
        XCTAssertEqual(live.roomCorrection, baseState().roomCorrection)
        XCTAssertNotEqual(live, beforeCorrection)
        XCTAssertTrue(driver.flow.invalidationReason?.contains("did not finish") == true)
    }

    func testCancelRevertsAndReturnsToCorrection() async throws {
        let services = SimulatedSystemSetupServices(initial: baseState())
        let driver = try await driverToVerify(services, designKind: .mixedPhase)
        await services.setVerifyDelaySeconds(5)
        let run = Task { await driver.runVerification(timeoutSeconds: 30) }
        try await Task.sleep(nanoseconds: 100_000_000)
        driver.cancelVerification()
        await run.value
        XCTAssertEqual(driver.flow.step, .correction)
        XCTAssertEqual(driver.working.roomCorrection, baseState().roomCorrection)
        let live = await services.live
        XCTAssertEqual(live.roomCorrection, baseState().roomCorrection)
    }

    func testMinimumPhaseMismatchSavesAsNotVerifiedWithReport() async throws {
        let services = SimulatedSystemSetupServices(initial: baseState())
        await services.setVerificationPasses(false)
        let driver = try await driverToVerify(services, designKind: .minimumPhase)
        await driver.runVerification()
        XCTAssertEqual(driver.flow.choices.verificationPassed, false)
        XCTAssertEqual(driver.report?.passed, false)
        XCTAssertTrue(driver.flow.savesAsNotVerified)
        XCTAssertTrue(driver.working.roomCorrection.enabled, "minimum phase keeps the correction")
    }

    func testMixedPhaseCannotSaveUnverified() async throws {
        var flow = SystemSetupFlow()
        try flow.start(snapshot: baseState())
        flow.choices.designKind = .mixedPhase
        flow.choices.verificationPassed = false
        flow.choices.profileName = "x"
        XCTAssertThrowsError(try flow.finish())
    }

    func testSavedProfileReloadsWithSameStateAtStandardRates() async throws {
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let original = baseState()
            let services = SimulatedSystemSetupServices(initial: original)
            let driver = SystemSetupDriver(services: services, current: original)
            try driver.start()
            driver.update { $0.outputUID = "uid-a"; $0.sampleRate = rate }
            try driver.next()
            driver.update { $0.topology = .twoPointOne }
            try driver.next()
            driver.update { $0.microphoneUID = "mic"; $0.sweepLevelDBFS = -20 }
            try driver.next()
            try driver.skip()
            driver.update { $0.seatNames = ["Main", "L", "R"]; $0.designKind = .mixedPhase }
            await driver.measureSeats()
            try driver.next()
            await driver.applyAlignment(); try driver.next()
            await driver.applyBass(); try driver.next()
            await driver.applyCorrection(); try driver.next()
            await driver.runVerification()
            XCTAssertEqual(driver.flow.choices.verificationPassed, true, "\(rate)")
            try driver.next()
            driver.update { $0.profileName = SystemSetupSaveNaming.profileName("Den", notVerified: false) }
            await driver.finish()
            XCTAssertEqual(driver.flow.phase, .finished, "\(rate)")
            let saved = try XCTUnwrap(driver.savedProfile)
            XCTAssertEqual(saved.name, "Den")
            let data = try JSONEncoder().encode(saved)
            let reloaded = try JSONDecoder().decode(PlaybackSystemProfile.self, from: data)
            XCTAssertEqual(reloaded, saved, "\(rate)")
            XCTAssertEqual(reloaded.state.roomCorrectionCalibration, saved.state.roomCorrectionCalibration)
            XCTAssertEqual(driver.report?.sampleRate, rate)
        }
    }
}
