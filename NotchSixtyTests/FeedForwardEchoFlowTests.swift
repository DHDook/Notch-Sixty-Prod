import Foundation
import XCTest
@testable import NotchSixty

/// E4 S22b2: the feed-forward echo flow without hardware. The three-repeat echo model and its
/// bound, the stability check, the clock fits, the store (v1 reads as "not checked"), the flag
/// gate on the drive demand, and the shadow engine removing a simulated echo end to end.
final class FeedForwardEchoFlowTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Echo model

    private func impulse(rate: Double, delaySeconds: Double, gain: Float, seconds: Double = 0.15) -> [Float] {
        var ir = [Float](repeating: 0, count: Int(seconds * rate))
        let at = Int((delaySeconds * rate).rounded())
        // A short decaying tail, so the model has several taps.
        for k in 0..<Int(0.01 * rate) where at + k < ir.count {
            ir[at + k] = gain * Float(exp(-Double(k) / (0.002 * rate)))
        }
        return ir
    }

    func testThreeRepeatsGiveMeanAndBoundAtEveryRate() throws {
        for rate in rates {
            let base = impulse(rate: rate, delaySeconds: 0.020, gain: Float(0.05 * 48_000 / rate))
            let repeats = [base, base.map { $0 * 1.01 }, base.map { $0 * 0.99 }]
            let model = try FeedForwardEchoModelBuilder.build(
                left: repeats, right: repeats, nativeSampleRate: rate, capturedAt: Date()
            )
            let fd = rate / Double(N60AncDecimationFactor(rate))
            XCTAssertEqual(model.sampleRate, fd, accuracy: 1e-9)
            XCTAssertEqual(model.repeats, 3)
            XCTAssertLessThanOrEqual(model.left.taps.count, FeedForwardEchoModel.maximumTaps)
            XCTAssertEqual(model.left.bound.count, model.left.taps.count)
            // Onset 20 ms less 1 ms, within a few fd samples of filter spread.
            XCTAssertEqual(Double(model.left.bulkDelay), 0.019 * fd, accuracy: 6, "rate \(rate)")
            XCTAssertGreaterThan(model.left.bound.max() ?? 0, 0)
            XCTAssertGreaterThanOrEqual(model.coherence ?? 0, FeedForwardEchoModel.minimumCoherence)
            guard case .passed(let gain) = FeedForwardLeakageStabilityCheck.evaluate(
                model: model, weightsLeft: [0.004], weightsRight: [0.004]
            ) else { return XCTFail("rate \(rate) must pass") }
            XCTAssertEqual(gain, model.left.upperL1 * 0.004 + model.right.upperL1 * 0.004, accuracy: 1e-6)
        }
    }

    func testFifteenPercentRepeatDeviationIsRefused() throws {
        let rate = 48_000.0
        let base = impulse(rate: rate, delaySeconds: 0.010, gain: 0.05)
        let repeats = [base, base.map { $0 * 1.15 }, base.map { $0 * 0.85 }]
        let model = try FeedForwardEchoModelBuilder.build(
            left: repeats, right: repeats, nativeSampleRate: rate, capturedAt: Date()
        )
        XCTAssertGreaterThan(model.repeatDeviation ?? 0, 0.10)
        let verdict = FeedForwardLeakageStabilityCheck.evaluate(model: model, weightsLeft: [0.1], weightsRight: [0.1])
        XCTAssertTrue(verdict.wouldBeRefused, "\(verdict)")
    }

    func testStabilityCheckPassesAndFailsOnFixtureWeights() throws {
        let rate = 48_000.0
        let base = impulse(rate: rate, delaySeconds: 0.010, gain: 0.02)
        let model = try FeedForwardEchoModelBuilder.build(
            left: [base, base, base], right: [base, base, base], nativeSampleRate: rate, capturedAt: Date()
        )
        guard case .passed = FeedForwardLeakageStabilityCheck.evaluate(
            model: model, weightsLeft: [0.004, 0.004], weightsRight: [0.004, 0.004]
        ) else { return XCTFail("small weights must pass") }
        let loud = [Float](repeating: 5, count: 64)
        XCTAssertTrue(FeedForwardLeakageStabilityCheck.evaluate(
            model: model, weightsLeft: loud, weightsRight: loud
        ).wouldBeRefused)
    }

    func testV1StoreReadsAsNotChecked() throws {
        let rate = 48_000.0
        var survey = QuietZoneFeedForwardDesignSurvey(
            projectID: UUID(), microphoneStableID: "mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: rate, capturedAt: Date(), segments: 100, bands: []
        )
        survey.leakage = QuietZoneFeedForwardLeakage(
            sampleRate: rate, leftImpulseResponse: impulse(rate: rate, delaySeconds: 0.01, gain: 0.05),
            rightImpulseResponse: impulse(rate: rate, delaySeconds: 0.01, gain: 0.05), capturedAt: Date()
        )
        // A v1 file has no echoModel key.
        let decoded = try JSONDecoder().decode(
            QuietZoneFeedForwardDesignSurvey.self, from: JSONEncoder().encode(survey)
        )
        XCTAssertNil(decoded.echoModel)
        let legacy = try XCTUnwrap(decoded.echoModelOrLegacy)
        XCTAssertEqual(legacy.repeats, 1)
        XCTAssertEqual(
            FeedForwardLeakageStabilityCheck.evaluate(model: legacy, weightsLeft: [0.1], weightsRight: [0.1]),
            .notChecked("not checked: measure leakage again")
        )
    }

    func testV2StoreRoundTripsTheModel() throws {
        let rate = 96_000.0
        let base = impulse(rate: rate, delaySeconds: 0.01, gain: 0.05)
        let model = try FeedForwardEchoModelBuilder.build(
            left: [base, base, base], right: [base, base, base], nativeSampleRate: rate, capturedAt: Date()
        )
        var survey = QuietZoneFeedForwardDesignSurvey(
            projectID: UUID(), microphoneStableID: "mic", errorChannel: 0, referenceChannel: 1,
            sampleRate: rate, capturedAt: Date(), segments: 100, bands: []
        )
        survey.echoModel = model
        survey.leakage = model.asLeakage()
        let decoded = try JSONDecoder().decode(
            QuietZoneFeedForwardDesignSurvey.self, from: JSONEncoder().encode(survey)
        )
        XCTAssertEqual(decoded.echoModel, model)
        XCTAssertEqual(decoded.version, 2)
        XCTAssertEqual(decoded.leakage?.sampleRate, model.sampleRate)
    }

    // MARK: Clock fits

    private func aligner(micRate: Double, driveRate: Double, driftPPM: Double, jitter: Double = 0)
        -> FeedForwardDriveAligner.Result
    {
        var a = FeedForwardDriveAligner(micRate: micRate, driveRate: driveRate)
        let eps = driftPPM * 1.0e-6
        for c in 0..<400 {  // 20 s in 50 ms callbacks
            let t = Double(c) * 0.05
            let noise = c % 2 == 0 ? jitter : -jitter
            a.addMic(frame: UInt64(t * micRate), hostSeconds: 100 + t + noise)
            a.addDrive(frame: UInt64(t * driveRate / (1 + eps)), hostSeconds: 100 + t)
        }
        return a.evaluate(micFrame: UInt64(19 * micRate))
    }

    func testAlignerFollowsTwoRatesAndTheirDrift() {
        guard case .aligned(let frame, let ratio, let drift) = aligner(micRate: 48_000, driveRate: 44_100, driftPPM: 40)
        else { return XCTFail("expected an alignment") }
        XCTAssertEqual(abs(drift), 40, accuracy: 2)
        XCTAssertEqual(ratio, 44_100.0 / 48_000.0, accuracy: 1e-4)
        XCTAssertEqual(frame, 19 * 44_100 / (1 + 40e-6), accuracy: 2)
    }

    func testAlignerStopsOnDriftAndOnResidual() {
        guard case .stopped(let drift) = aligner(micRate: 48_000, driveRate: 48_000, driftPPM: 300)
        else { return XCTFail("drift must stop") }
        XCTAssertTrue(drift.contains("drift"))
        guard case .stopped(let residual) = aligner(micRate: 48_000, driveRate: 48_000, driftPPM: 0, jitter: 0.002)
        else { return XCTFail("residual must stop") }
        XCTAssertTrue(residual.contains("residual"))
        XCTAssertEqual(
            FeedForwardDriveAligner(micRate: 48_000, driveRate: 48_000).evaluate(micFrame: 0), .aligning
        )
    }

    func testRemovalWatchGoesStaleAfterTenSecondsUnderTenDB() {
        var watch = FeedForwardRemovalWatch()
        for _ in 0..<99 { watch.observe(locked: true, removalDB: 6, drivePower: 0.01, dt: 0.1) }
        XCTAssertFalse(watch.stale)
        for _ in 0..<2 { watch.observe(locked: true, removalDB: 6, drivePower: 0.01, dt: 0.1) }
        XCTAssertTrue(watch.stale)
        var quiet = FeedForwardRemovalWatch()
        for _ in 0..<200 { quiet.observe(locked: true, removalDB: 0, drivePower: 0, dt: 0.1) }
        XCTAssertFalse(quiet.stale, "no programme, no verdict")
    }

    // MARK: Flag gate

    @MainActor
    func testFlagOffNeverSetsTheDriveDemand() throws {
        let source = RecordingDriveSource()
        let shadow = QuietZoneFeedForwardShadow(pollsAutomatically: false)
        shadow.driveSource = source
        let rate = 48_000.0
        let base = impulse(rate: rate, delaySeconds: 0.01, gain: 0.05)
        let model = try FeedForwardEchoModelBuilder.build(
            left: [base], right: [base], nativeSampleRate: rate, capturedAt: Date()
        )
        let inputs = try XCTUnwrap(Self.minimalInputs(echo: model))
        XCTAssertNotNil(shadow.echoBlockedReason(inputs), "flag off: echo removal is blocked")
        shadow.setActive(true)
        shadow.update(inputs: inputs, reason: "")
        shadow.setActive(false)
        XCTAssertTrue(source.demandCalls.allSatisfy { $0 == false })

        shadow.forceEchoForTesting = true
        XCTAssertNil(shadow.echoBlockedReason(inputs))
        source.subwoofer = true
        XCTAssertTrue(shadow.echoBlockedReason(inputs)?.contains("subwoofer") == true)
    }

    // MARK: Engine end to end

    private struct Run {
        var status: N60FeedForwardShadowStatus
        var note: String?
    }

    /// 14 s of white programme through a 6 ms, 0.5 gain echo into the reference microphone.
    /// Output at `driveRate`, input at `micRate`, clocks `driftPPM` apart.
    private func simulate(micRate: Double, driveRate: Double, driftPPM: Double) throws -> Run {
        let seconds = 14.0
        let epsO = driftPPM * 1.0e-6
        let drive = Self.noise(count: Int((seconds + 1) * driveRate), seed: 7)
        let ir = [Float](repeating: 0, count: Int(0.006 * micRate)) + [0.5]
        let model = try FeedForwardEchoModelBuilder.build(
            left: [ir + [Float](repeating: 0, count: 2_000)], right: [ir + [Float](repeating: 0, count: 2_000)],
            nativeSampleRate: micRate, capturedAt: Date()
        )
        // The right speaker is silent: give it a token path so the model is valid.
        var tokenRight = model.right
        tokenRight = FeedForwardEchoPath(bulkDelay: 0, taps: [0], bound: [0])
        var echo = model
        echo.right = tokenRight
        let fd = micRate / Double(N60AncDecimationFactor(micRate))
        let plan = QuietZoneFeedForwardShadowPlan(
            nativeSampleRate: micRate, decimatedRate: fd, seedSource: .zeroWeights(reason: "test"),
            seedLeft: [Float](repeating: 0, count: 128), seedRight: [Float](repeating: 0, count: 128),
            leftPath: .init(bulkDelay: echo.left.bulkDelay, taps: echo.left.taps),
            rightPath: .init(bulkDelay: echo.right.bulkDelay, taps: echo.right.taps), bands: []
        )
        let capture = EchoSimulatedPair(
            sampleRate: micRate, drive: drive, driveRate: driveRate, driveDrift: epsO, delay: 0.006, gain: 0.5
        )
        let engine = try XCTUnwrap(QuietZoneFeedForwardShadowEngine(
            plan: plan, capture: capture, echo: echo, driveSampleRate: driveRate,
            hostSeconds: { Double($0) * 1.0e-9 }
        ))
        XCTAssertTrue(engine.echoActive)
        try engine.start()
        var driveNext = 0
        var snapshot: QuietZoneFeedForwardShadowEngine.Snapshot?
        var t = 0.0
        while t < seconds {
            t += 0.1
            capture.produce(seconds: 0.1)
            // The drive runs 0.05 s ahead of the microphone's time.
            let upTo = min(Int((t + 0.05) * driveRate / (1 + epsO)), drive.count)
            var chunk = FeedForwardDriveChunk(
                anchors: [], left: [], right: [], firstFrame: UInt64(driveNext), droppedFrames: 0, droppedAnchors: 0
            )
            var k = driveNext
            while k < upTo {
                let n = min(512, upTo - k)
                chunk.anchors.append(N60SpeakerDriveAnchor(
                    outputHostTime: capture.driveHostNanos(frame: k), firstFrameIndex: UInt64(k), frames: UInt32(n), reserved: 0
                ))
                k += n
            }
            chunk.left = Array(drive[driveNext..<upTo])
            chunk.right = [Float](repeating: 0, count: upTo - driveNext)
            driveNext = upTo
            snapshot = try engine.pump(drive: chunk)
        }
        let result = try XCTUnwrap(snapshot)
        return Run(status: result.status, note: result.alignmentNote)
    }

    func testEngineRemovesTheSimulatedEchoByTwentyDB() throws {
        for (mic, drive, ppm) in [(48_000.0, 48_000.0, 0.0), (48_000.0, 44_100.0, 40.0)] {
            let run = try simulate(micRate: mic, driveRate: drive, driftPPM: ppm)
            XCTAssertEqual(run.status.echoState, UInt32(N60_FF_ECHO_LOCKED), "\(mic)/\(drive): \(run.note ?? "")")
            XCTAssertLessThanOrEqual(abs(Int(run.status.echoOffset)), 1)
            let removal = 10 * log10(Double(run.status.referencePowerBefore) / max(Double(run.status.referencePowerAfter), 1e-30))
            XCTAssertGreaterThanOrEqual(removal, 20, "\(mic)/\(drive) before \(run.status.referencePowerBefore) after \(run.status.referencePowerAfter) offset \(run.status.echoOffset) peak \(run.status.searchPeak) drive \(run.status.drivePower) restarts \(run.status.searchRestarts)")
            XCTAssertNil(run.note)
        }
    }

    func testEngineStaysOffWhenTheClocksDrift() throws {
        let run = try simulate(micRate: 48_000, driveRate: 48_000, driftPPM: 300)
        XCTAssertNotEqual(run.status.echoState, UInt32(N60_FF_ECHO_LOCKED))
        XCTAssertTrue(run.note?.contains("drift") == true, "\(run.note ?? "nil")")
    }

    // MARK: Fixtures

    static func noise(count: Int, seed: UInt64) -> [Float] {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        return (0..<count).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int64(bitPattern: state >> 11) % 2_000_000 - 1_000_000) / 3_000_000
        }
    }

    @MainActor
    static func minimalInputs(echo: FeedForwardEchoModel?) -> QuietZoneFeedForwardShadowInputs? {
        let device = AudioInputDevice(
            deviceID: 1, uid: "mic", name: "Mic", nominalSampleRate: 48_000, availableSampleRateRanges: []
        )
        let channel = RoomCorrectionChannelMeasurement(
            capturedAt: Date(), rawCapture: [], impulseResponse: [1], transferFunction: nil,
            quality: RoomCorrectionMeasurementQuality()
        )
        return QuietZoneFeedForwardShadowInputs(
            device: device, referenceChannel: 1, errorChannel: 0, bands: [], design: nil,
            budget: QuietZoneFeedForwardBudget.missing,
            position: RoomCorrectionMeasurementPosition(name: "Seat", sampleRate: 48_000, left: channel, right: channel),
            echoModel: echo
        )
    }
}

@MainActor
private final class RecordingDriveSource: FeedForwardDriveSource {
    var demandCalls: [Bool] = []
    var subwoofer = false
    var driveSampleRate: Double? { 48_000 }
    var subwooferActive: Bool { subwoofer }
    func setDriveDemand(_ requested: Bool) { demandCalls.append(requested) }
    func readDrive(maximumFrames: Int) -> FeedForwardDriveChunk? { nil }
}

/// The reference microphone hears the drive, delayed and scaled. Host time is nanoseconds from a
/// fixed base; the microphone clock is exact and the output clock is `driveDrift` slow.
private final class EchoSimulatedPair: QuietZoneFeedForwardPairCapturing {
    let sampleRate: Double
    private let drive: [Float]
    private let driveRate: Double
    private let driveDrift: Double
    private let delay: Double
    private let gain: Float
    private var available = 0
    private var next = 0
    private let base = 1.0e12

    init(sampleRate: Double, drive: [Float], driveRate: Double, driveDrift: Double, delay: Double, gain: Float) {
        self.sampleRate = sampleRate
        self.drive = drive
        self.driveRate = driveRate
        self.driveDrift = driveDrift
        self.delay = delay
        self.gain = gain
    }

    func start() throws {}
    func close() {}
    func produce(seconds: Double) { available += Int((seconds * sampleRate).rounded()) }

    func driveHostNanos(frame: Int) -> UInt64 {
        UInt64(base + Double(frame) / driveRate * (1 + driveDrift) * 1.0e9)
    }

    private func driveValue(atSeconds t: Double) -> Float {
        let position = t * driveRate / (1 + driveDrift)
        guard position >= 0, Int(position) + 1 < drive.count else { return 0 }
        let i = Int(position), f = Float(position - Double(i))
        return drive[i] * (1 - f) + drive[i + 1] * f
    }

    func readPair(maximumFrames: Int) throws -> (reference: [N60FeedForwardReferenceFrame], error: [Float]) {
        let count = min(maximumFrames, available)
        available -= count
        var frames = [N60FeedForwardReferenceFrame](repeating: N60FeedForwardReferenceFrame(), count: count)
        var error = [Float](repeating: 0, count: count)
        let callback = 512
        for i in 0..<count {
            let m = next + i
            let offset = (m % callback)
            let start = m - offset
            let x = gain * driveValue(atSeconds: Double(m) / sampleRate - delay)
            frames[i].sample = x
            frames[i].firstFrameHostTime = UInt64(base + Double(start) / sampleRate * 1.0e9)
            frames[i].firstFrameSampleTime = Double(start)
            frames[i].frameOffset = UInt32(offset)
            error[i] = x
        }
        next += count
        return (frames, error)
    }

    // MARK: Live arm gate (E4 S25b)

    private func gateInputs() -> FeedForwardLiveArmGate.Inputs {
        .init(featureEnabled: true, liveOutputAuthorized: true, stability: .passed(loopGain: 0.05),
              verifiedRemovalDecibels: 24, leadSeconds: 0.010, requiredLeadSeconds: 0.005, referenceLive: true)
    }

    func testArmGateAllowsOnlyWhenEveryConditionHolds() {
        XCTAssertTrue(FeedForwardLiveArmGate.decide(gateInputs()).isAllowed)
        var a = gateInputs(); a.featureEnabled = false
        var b = gateInputs(); b.liveOutputAuthorized = false
        var c = gateInputs(); c.stability = .refused("loop")
        var d = gateInputs(); d.stability = .notChecked("not checked")
        var e = gateInputs(); e.verifiedRemovalDecibels = 19.9
        var f = gateInputs(); f.verifiedRemovalDecibels = nil
        var g = gateInputs(); g.leadSeconds = 0.004
        var h = gateInputs(); h.referenceLive = false
        var i = gateInputs(); i.leadSeconds = .nan
        for input in [a, b, c, d, e, f, g, h, i] {
            XCTAssertFalse(FeedForwardLiveArmGate.decide(input).isAllowed, "\(input)")
        }
    }

    func testArmGateExactBoundaries() {
        var input = gateInputs()
        input.verifiedRemovalDecibels = 20
        input.leadSeconds = input.requiredLeadSeconds
        XCTAssertTrue(FeedForwardLiveArmGate.decide(input).isAllowed)
    }
}
