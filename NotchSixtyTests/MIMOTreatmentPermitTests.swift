import XCTest
@testable import NotchSixty

/// E19 S7: the predicted-IR wrapper (G1), the decay verifier on noisy measured responses (G2), the named criteria, and the
/// permit issuer through the controller and the engine (G20, G30). The thermal window tests are in `core/tests/test_mimo_stage.cpp`.
@MainActor
final class MIMOTreatmentPermitTests: XCTestCase {
    private let rate = 48_000.0
    private let modeHz = [25.0, 31.5, 40, 50, 63, 80, 100, 125, 160]

    // MARK: Fixtures

    /// Sum of one damped sinusoid per third-octave centre, each with RT60 `rt60`, plus a deterministic noise floor.
    private func room(rt60: [Double], seconds: Double = 3.0, noiseDB: Double = -75, seed: UInt32 = 1) -> [Float] {
        let n = Int(seconds * rate)
        var out = [Float](repeating: 0, count: n)
        var state = seed
        let noise = pow(10, noiseDB / 20)
        for i in 0..<n {
            let t = Double(i) / rate
            var v = 0.0
            for (k, hz) in modeHz.enumerated() {
                v += exp(-6.9078 * t / rt60[k]) * sin(2 * .pi * hz * t + Double(k)) / Double(modeHz.count)
            }
            state = state &* 1_664_525 &+ 1_013_904_223
            v += noise * (Double(state >> 8) / 8_388_608.0 - 1)
            out[i] = Float(v)
        }
        return out
    }

    private func flat(_ value: Double) -> [Double] { [Double](repeating: value, count: modeHz.count) }

    private func seats(baseline: Double = 1.0, predicted: Double = 0.5, measured: Double? = 0.55, count: Int = 2)
        -> (base: [[Float]], predicted: [[Float]], measured: [[Float]]?)
    {
        let base = (0..<count).map { room(rt60: flat(baseline), seed: UInt32($0 + 1)) }
        let pred = (0..<count).map { room(rt60: flat(predicted), seed: UInt32($0 + 11)) }
        let meas = measured.map { m in (0..<count).map { room(rt60: flat(m), seed: UInt32($0 + 21)) } }
        return (base, pred, meas)
    }

    private func spatial(accepted: Bool = true) -> MIMORoomTreatmentVerificationReport {
        MIMORoomTreatmentVerificationReport(
            sampleRate: rate, seatIDs: [], sources: [], frequenciesHz: [], sourceReports: [], baselineSpatialRMSErrorDB: 5,
            treatedSpatialRMSErrorDB: 3, spatialRMSErrorImprovementDB: 2, maximumAbsoluteMeanLevelShiftDB: 0.5,
            worstSeatErrorIncreaseDB: 0, accepted: accepted)
    }

    private func verify(
        _ s: (base: [[Float]], predicted: [[Float]], measured: [[Float]]?), spatialReport: MIMORoomTreatmentVerificationReport? = nil
    ) -> MIMOTreatmentVerificationResult {
        MIMOTreatmentVerifier.verify(
            baseline: s.base, predicted: s.predicted, measured: s.measured, spatial: spatialReport ?? spatial(), sampleRate: rate)
    }

    // MARK: G1: predicted treated IR wrapper

    func testPredictionWithIdentityFiltersIsTheMeasuredSum() throws {
        let a: [Float] = [1, 0.5, 0.25, 0], b: [Float] = [0, 1, -0.5, 0.125]
        let out = try MeasurementCore.predictTreatedIR(plants: [a, b], filters: [[1], [1]])
        XCTAssertEqual(out, zip(a, b).map { $0 + $1 })
    }

    func testPredictionMatchesDirectConvolutionAndExcludedSourceAddsNothing() throws {
        let plant: [Float] = (0..<64).map { Float(sin(Double($0) * 0.3)) / Float($0 + 1) }
        let filter: [Float] = [0.5, -0.25, 0.125]
        let out = try MeasurementCore.predictTreatedIR(plants: [plant, plant], filters: [filter, [0]])
        var expected = [Float](repeating: 0, count: plant.count + filter.count - 1)
        for (i, p) in plant.enumerated() { for (j, f) in filter.enumerated() { expected[i + j] += p * f } }
        XCTAssertEqual(out.count, expected.count)
        for (x, y) in zip(out, expected) { XCTAssertEqual(x, y, accuracy: 1e-5) }
        XCTAssertThrowsError(try MeasurementCore.predictTreatedIR(plants: [], filters: []))
        XCTAssertThrowsError(try MeasurementCore.predictTreatedIR(plants: [plant], filters: [[]]))
    }

    // MARK: G2: decay bands on noisy measured responses

    func testDecayBandsAreReliableFrom25To160HzOnANoisyMeasuredResponse() throws {
        let bands = try MIMOTreatmentVerifier.decayBands(impulseResponse: room(rt60: flat(1.0)), sampleRate: rate)
        XCTAssertEqual(bands.map(\.centreHz).map { Int($0.rounded()) }, [25, 32, 40, 50, 63, 79, 100, 126, 158])
        for band in bands {
            let t = try XCTUnwrap(band.seconds, "\(band.centreHz) Hz must be reliable on a -75 dB noise floor")
            XCTAssertEqual(t, 1.0, accuracy: 0.25, "\(band.centreHz) Hz")
        }
    }

    func testAShortResponseIsNotReliable() throws {
        let short = room(rt60: flat(1.0), seconds: 0.08)
        let bands = try MIMOTreatmentVerifier.decayBands(impulseResponse: short, sampleRate: rate)
        XCTAssertLessThan(bands.compactMap(\.seconds).count, 5)
    }

    // MARK: Criteria, each with its own named reason

    func testShortenedDecayPasses() {
        let result = verify(seats())
        XCTAssertTrue(result.passed, result.failures.map(\.reason).joined(separator: " | "))
        XCTAssertGreaterThan(try XCTUnwrap(result.predictedMedianImprovement), 0.3)
        XCTAssertTrue(result.includesRepeatMeasurement)
    }

    func testNoShorteningBlocks() {
        let result = verify(seats(predicted: 1.0, measured: 1.0))
        XCTAssertTrue(result.failures.contains { if case .decayNotShortened(.predicted, _) = $0 { return true }; return false })
        XCTAssertTrue(result.failures.contains { if case .decayNotShortened(.repeatMeasured, _) = $0 { return true }; return false })
    }

    func testOneBandGettingLongerBlocksByName() {
        var rt = flat(0.5)
        rt[4] = 1.4  // 63 Hz longer than the 1.0 s baseline
        let s = seats()
        let worse = (0..<2).map { room(rt60: rt, seed: UInt32($0 + 31)) }
        let result = verify((s.base, worse, s.measured))
        XCTAssertTrue(result.failures.contains {
            if case .decayWorsened(.predicted, _, let hz, let ratio) = $0 { return abs(hz - 63) < 1 && ratio > 1.1 }
            return false
        }, result.failures.map(\.reason).joined(separator: " | "))
        XCTAssertFalse(result.passed)
    }

    func testSpatialFailureAndMissingReportBlock() {
        XCTAssertTrue(verify(seats(), spatialReport: spatial(accepted: false)).failures.contains(.spatialCriteriaFailed))
        let s = seats()
        let none = MIMOTreatmentVerifier.verify(
            baseline: s.base, predicted: s.predicted, measured: s.measured, spatial: nil, sampleRate: rate)
        XCTAssertTrue(none.failures.contains(.spatialReportMissing))
    }

    func testMissingRepeatMeasurementBlocks() {
        let result = verify(seats(measured: nil))
        XCTAssertEqual(result.failures, [.repeatMeasurementMissing])
        XCTAssertFalse(result.includesRepeatMeasurement)
    }

    func testMeasurementThatDisagreesWithThePredictionBlocks() {
        let result = verify(seats(predicted: 0.4, measured: 0.8))  // both shorter than 1.0, but 100 percent apart
        XCTAssertTrue(result.failures.contains { if case .predictionDisagrees = $0 { return true }; return false },
                      result.failures.map(\.reason).joined(separator: " | "))
    }

    func testUnreliableDecayAndSeatMismatchBlock() {
        let s = seats()
        let short = (0..<2).map { room(rt60: flat(0.5), seconds: 0.08, seed: UInt32($0 + 41)) }
        let unreliable = verify((s.base, short, s.measured))
        XCTAssertTrue(unreliable.failures.contains { if case .decayNotReliable(.predicted, _, _) = $0 { return true }; return false })
        let mismatch = verify((s.base, [s.predicted[0]], s.measured))
        XCTAssertEqual(mismatch.failures, [.seatCountMismatch(phase: .predicted)])
        XCTAssertEqual(verify(([], [], nil)).failures, [.noSeats])
        for failure in unreliable.failures + mismatch.failures { XCTAssertFalse(failure.reason.isEmpty) }
    }

    // MARK: Permit

    private func stage(rate: Double = 48_000, sources: Int = 2) throws -> UnifiedGraphMIMOStage {
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        let filters = MIMOTreatmentFilterSet(
            sampleRate: rate, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: sources, tapCount: 16,
            tauSeconds: 0.015, taps: [Float](repeating: 0, count: sources * sources * 16), solved: [], gridLowHz: 0, gridBins: 0)
        var stage = try UnifiedGraphMIMOStage(filters: filters, sourceLanes: Array(0..<sources))
        stage.supportRangesHz = [30, 150, 30, 150]
        return stage
    }

    private func flags() -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMOTreatmentPermitTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly, arguments: [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id])
    }

    private func context(video: Bool = false) -> MIMOGraphTreatment.Context {
        MIMOGraphTreatment.Context(
            engineRunning: true, outputDeviceUID: "OUT-1", sampleRate: 48_000, stageAttached: true, hardLimitPresent: true,
            engineLeaseHeld: true, videoLatencyMode: video, outputTrimsDB: [0, 0], laneCount: 2)
    }

    private func acceptance(complete: Bool = true, sources: Int = 2) -> MIMORoomTreatmentHardwareAcceptance {
        MIMORoomTreatmentHardwareAcceptance(
            confirmedAt: Date(), sourceCount: sources, sampleRate: 48_000, longRunThermalPassed: complete,
            protectionChainPassed: true, stopStartPassed: true, unplugReplugPassed: true, sleepWakePassed: true,
            audibleArtifactCheckPassed: true)
    }

    private func qualification(for stage: UnifiedGraphMIMOStage, complete: Bool = true) -> MIMOTreatmentQualificationRegistry {
        MIMOTreatmentQualificationRegistry(records: [
            MIMOTreatmentClassQualification(
                key: MIMOGraphTreatment.classKey(stage: stage), qualifiedAt: Date(), longRunThermalPassed: complete,
                protectionChainPassed: true, stopStartPassed: true, unplugReplugPassed: true, sleepWakePassed: true,
                audibleArtifactCheckPassed: true)])
    }

    private func controller() throws -> (MIMOGraphTreatment, UnifiedGraphMIMOStage) {
        let treatment = MIMOGraphTreatment(flags: flags())
        treatment.publish = { _ in }
        treatment.settle = {}
        let design = try stage()
        treatment.stage(design)
        return (treatment, design)
    }

    private func passing() -> MIMOTreatmentVerificationResult { verify(seats()) }

    private func refusal(_ r: Result<MIMOGraphTreatment.Permit, MIMOTreatmentPermitRefusal>) -> MIMOTreatmentPermitRefusal? {
        if case .failure(let f) = r { return f }
        return nil
    }

    func testNoPermitUntilTheVideoLatencyInputIsWired() throws {
        let (t, design) = try controller()
        let r = t.issuePermit(
            context: context(), videoLatency: .unknown, verification: passing(), acceptance: acceptance(),
            registry: qualification(for: design))
        XCTAssertEqual(refusal(r), .videoLatencyInputNotWired)
        XCTAssertNil(t.permit)
        let video = t.issuePermit(
            context: context(), videoLatency: .known(videoLatencyMode: true), verification: passing(), acceptance: acceptance())
        XCTAssertEqual(refusal(video), .videoLatencyMode)
    }

    func testProductionEngineIssuesNoPermitWithoutAStagedDesignOrQualification() {
        let engine = AudioIOEngine()
        // E19 S8 (G30): the input follows the installed room correction; with none installed it is known and not video.
        let r = engine.issueMIMOTreatmentPermit(verification: passing(), acceptance: acceptance())
        XCTAssertEqual(engine.mimoVideoLatencyInput, .known(videoLatencyMode: false))
        XCTAssertEqual(refusal(r), .noStagedDesign)
        XCTAssertNil(engine.mimoGraphTreatment.permit)
        XCTAssertTrue(MIMOTreatmentQualificationRegistry.production.records.isEmpty, "E22 fills the table")
        engine.mimoVideoLatencyInput = .known(videoLatencyMode: false)
        XCTAssertEqual(refusal(engine.issueMIMOTreatmentPermit(verification: passing(), acceptance: acceptance())), .noStagedDesign)
    }

    func testVerificationFailuresBlockWithTheirNamedReasons() throws {
        let (t, _) = try controller()
        let bad = verify(seats(predicted: 1.0, measured: 1.0), spatialReport: spatial(accepted: false))
        let r = t.issuePermit(context: context(), videoLatency: .known(videoLatencyMode: false), verification: bad, acceptance: acceptance())
        guard case .verificationFailed(let failures)? = refusal(r) else { return XCTFail("expected verificationFailed") }
        XCTAssertTrue(failures.contains(.spatialCriteriaFailed))
        XCTAssertEqual(refusal(t.issuePermit(
            context: context(), videoLatency: .known(videoLatencyMode: false), verification: nil, acceptance: acceptance()))?.reason.isEmpty, false)
        XCTAssertNil(t.permit)
        // A prediction-only verification is not enough.
        let s = seats()
        let predictionOnly = MIMOTreatmentVerifier.verify(
            baseline: s.base, predicted: s.predicted, measured: nil, spatial: nil, sampleRate: rate)
        XCTAssertEqual(refusal(t.issuePermit(
            context: context(), videoLatency: .known(videoLatencyMode: false), verification: predictionOnly, acceptance: acceptance())),
            .verificationFailed([.repeatMeasurementMissing]))
    }

    func testWithoutAcceptanceOrClassQualificationNoPermitIsIssued() throws {
        let (t, design) = try controller()
        let known = MIMOVideoLatencyInput.known(videoLatencyMode: false)
        for (acc, reg) in [
            (nil, MIMOTreatmentQualificationRegistry.production),
            (acceptance(complete: false), MIMOTreatmentQualificationRegistry.production),
            (acceptance(sources: 3), MIMOTreatmentQualificationRegistry.production),
            (nil, qualification(for: design, complete: false)),
        ] as [(MIMORoomTreatmentHardwareAcceptance?, MIMOTreatmentQualificationRegistry)] {
            let r = t.issuePermit(context: context(), videoLatency: known, verification: passing(), acceptance: acc, registry: reg)
            XCTAssertEqual(refusal(r), .hardwareAcceptanceRequired)
            XCTAssertNil(t.permit)
        }
        // A qualification of another class does not count.
        var other = qualification(for: design)
        other.records[0].key.decimation = 64
        XCTAssertEqual(refusal(t.issuePermit(context: context(), videoLatency: known, verification: passing(), acceptance: nil, registry: other)),
                       .hardwareAcceptanceRequired)
    }

    func testPermitIsIssuedOnAcceptanceOrClassQualificationAndArms() async throws {
        let known = MIMOVideoLatencyInput.known(videoLatencyMode: false)
        let (t, design) = try controller()
        let issued = t.issuePermit(context: context(), videoLatency: known, verification: passing(), acceptance: acceptance())
        guard case .success(let permit) = issued else { return XCTFail("expected a permit: \(String(describing: refusal(issued)))") }
        XCTAssertEqual(permit.basis, .hardwareAcceptance)
        XCTAssertEqual(t.permit, permit)
        XCTAssertNil(t.gateFailure(context()), "the issued permit passes the controller's gate")
        try await t.requestArm(context: context())
        XCTAssertTrue(t.isArmed)

        let (u, design2) = try controller()
        let viaClass = u.issuePermit(
            context: context(), videoLatency: known, verification: passing(), acceptance: nil, registry: qualification(for: design2))
        guard case .success(let p2) = viaClass else { return XCTFail("class qualification must issue") }
        XCTAssertEqual(p2.basis, .classQualification)
        _ = design
    }

    func testEveryFingerprintFieldInvalidatesThePermit() throws {
        let known = MIMOVideoLatencyInput.known(videoLatencyMode: false)
        let (t, design) = try controller()
        t.chainDigest = "room-a"
        guard case .success = t.issuePermit(context: context(), videoLatency: known, verification: passing(), acceptance: acceptance())
        else { return XCTFail("permit") }
        XCTAssertNil(t.gateFailure(context()))

        func changed(_ ctx: MIMOGraphTreatment.Context) { XCTAssertEqual(t.gateFailure(ctx), .fingerprintMismatch) }
        var uid = context(); uid.outputDeviceUID = "OUT-2"; changed(uid)
        var trim = context(); trim.outputTrimsDB = [0, -1]; changed(trim)
        var lanes = context(); lanes.laneCount = 3; lanes.outputTrimsDB = [0, 0, 0]; changed(lanes)
        t.chainDigest = "room-b"; changed(context())
        t.chainDigest = "room-a"
        XCTAssertNil(t.gateFailure(context()))
        // A changed design (support range, taps, tau, rate family) is a different fingerprint.
        var ranges = design; ranges.supportRangesHz = [30, 160, 30, 150]
        let base = MIMOGraphTreatment.fingerprint(stage: design, outputUID: "OUT-1", trimsDB: [0, 0], laneCount: 2, chainDigest: "room-a")
        XCTAssertNotEqual(base, MIMOGraphTreatment.fingerprint(stage: ranges, outputUID: "OUT-1", trimsDB: [0, 0], laneCount: 2, chainDigest: "room-a"))
        let other = try stage(rate: 96_000)
        XCTAssertNotEqual(base, MIMOGraphTreatment.fingerprint(stage: other, outputUID: "OUT-1", trimsDB: [0, 0], laneCount: 2, chainDigest: "room-a"))
        // Restaging drops the permit.
        t.stage(design)
        XCTAssertNil(t.permit)
    }

    func testChainDigestFollowsRoomCorrectionAndLaneDelayButNotMasterGain() {
        var config = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        let base = MIMOGraphTreatment.chainDigest(of: config)
        var gain = config
        gain.lanes[0].outputGain = 0.5
        XCTAssertEqual(MIMOGraphTreatment.chainDigest(of: gain), base, "master volume is common to all lanes and does not disarm")
        var delay = config
        delay.lanes[1].delayMilliseconds = 1
        XCTAssertNotEqual(MIMOGraphTreatment.chainDigest(of: delay), base)
        var polarity = config
        polarity.lanes[0].polarityInverted = true
        XCTAssertNotEqual(MIMOGraphTreatment.chainDigest(of: polarity), base)
        config.stereoStages.roomFIR = UnifiedGraphFIRProgram(generation: 1, left: [1, 0.5], right: nil, declaredLatencyFrames: 0)
        XCTAssertNotEqual(MIMOGraphTreatment.chainDigest(of: config), base)
    }

    // MARK: G29: the arm ignores microphone fields

    func testMIMOArmIgnoresMicrophoneFields() async throws {
        let (t, _) = try controller()
        guard case .success = t.issuePermit(
            context: context(), videoLatency: .known(videoLatencyMode: false), verification: passing(), acceptance: acceptance())
        else { return XCTFail("permit") }
        try await t.requestArm(context: context())
        var env = LiveTreatmentEnvironment(outputDeviceUID: "OUT-1", sampleRate: 48_000, engineRunning: true, inputAvailable: true)
        env.microphoneLevelDBFS = nil
        t.arm.observe(env, now: Date().addingTimeInterval(7_200))
        XCTAssertTrue(t.isArmed, "no microphone analysis exists for MIMO; the stall rule must not apply")
        env.inputDeviceUID = "SOME-MIC"
        t.arm.observe(env, now: Date().addingTimeInterval(7_200))
        XCTAssertTrue(t.isArmed, "the baseline captured no microphone, so a microphone UID is not compared")
    }
}
