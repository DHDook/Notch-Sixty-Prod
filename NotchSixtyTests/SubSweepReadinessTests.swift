import XCTest
@testable import NotchSixty

/// E26 S6b: readiness from the measured sweeps. The splitter-render verifier covers the sub bands with the 8 s sweep
/// (G2), the open-preout check runs on measured bands (G3) and per-band eligibility comes from the same bands (G4).
/// The twin room is the splitter's own combined impulse response delayed and scaled, which is what the sweep analysis
/// returns for a room that is a pure delay. Eight rates.
@MainActor
final class SubSweepReadinessTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func bass(_ hz: Double = 80, enabled: Bool = true) -> BassManagementConfiguration {
        var c = BassManagementConfiguration()
        c.enabled = enabled
        c.frequencyHz = hz
        c.physicalOutputMode = .mainsSub
        return c
    }

    private func arrangement(receiver: ReceiverBass = .openPreout) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 2,
            choices: .init(layout: .fiveOne, bass: .downstreamReceiver, subwooferCount: 1, receiverBass: receiver))
    }

    private func path(_ a: SystemArrangement) -> AncBassPathState { AncBassPathState.resolve(arrangement: a, bassManagement: nil) }

    /// The impulse response a seat microphone would give: the splitter's combined response, delayed and scaled.
    private func twinImpulse(rate: Double, delaySeconds: Double, gain: Float, feed: ThroughFeedSplitterRenderer.Feed = .left) throws -> [Float] {
        let ir = try ThroughFeedSplitterRenderer.combinedImpulseResponse(feed: feed, bass: bass(), sampleRate: rate, seconds: 0.5)
        let shift = Int((delaySeconds * rate).rounded())
        return [Float](repeating: 0, count: shift) + ir.map { $0 * gain }
    }

    func testVerifierCoversSubBandsOnTheLongSweepAtEveryRate() throws {
        for rate in rates {
            let dry = SplitterVerificationSweep.samples(sampleRate: rate)
            let rendered = try ThroughFeedSplitterRenderer.render(dry, feed: .left, bass: bass(), sampleRate: rate)
            let impulse = try ThroughFeedSplitterRenderer.combinedImpulseResponse(
                feed: .left, bass: bass(), sampleRate: rate, seconds: SplitterVerificationSweep.tailSeconds)
            let bands = CombinedPathBandAnalyzer.analyze(impulseResponse: impulse, sampleRate: rate)
            let result = SplitterRenderVerifier.verify(
                dry: dry, rendered: rendered.combined, impulseBands: bands, sampleRate: rate)
            XCTAssertTrue(result.passes, "rate \(rate)")
            XCTAssertLessThan(result.worstGainErrorDB, 0.25, "rate \(rate): window bias is below the insurance bound")
            XCTAssertLessThan(result.worstDelayErrorSeconds, 0.0002, "rate \(rate)")
            let subBands = bands.filter { $0.centerHz < 40 && $0.delaySeconds != nil }.count
            XCTAssertGreaterThanOrEqual(subBands, 3, "rate \(rate): the verifier now has sub bands to compare")
            XCTAssertGreaterThan(result.bandsCompared, 12, "rate \(rate)")
        }
    }

    func testAnalyzerPassesATwinWithBroadbandOffsetAtEveryRate() throws {
        let a = arrangement()
        for rate in rates {
            let l = try twinImpulse(rate: rate, delaySeconds: 0.007, gain: 0.3)
            let r = try twinImpulse(rate: rate, delaySeconds: 0.007, gain: 0.3, feed: .right)
            let report = try SubSweepAnalyzer.analyze(
                leftImpulse: l, rightImpulse: r, sampleRate: rate, bass: bass(), path: path(a), arrangement: a,
                conservativePreviewSeconds: 0.05)
            XCTAssertEqual(report.openPreoutRefusal, "", "rate \(rate): a pure delay and gain offset is not a mismatch")
            XCTAssertNil(report.renderUnverifiedMessage, "rate \(rate)")
            XCTAssertTrue(report.verification.passes)
            XCTAssertEqual(report.fingerprint, path(a).fingerprint)
        }
    }

    func testAnalyzerRefusesAnOpenPreoutThatIsReallyBassManaged() throws {
        let a = arrangement()
        for rate in [48_000.0, 96_000, 384_000] {
            // The receiver adds its own 60 Hz low-pass in the sub path, which the app's model does not have.
            let ir = try twinImpulse(rate: rate, delaySeconds: 0.004, gain: 0.5)
            let alpha = Float(1 - exp(-2 * Double.pi * 60 / rate))
            var y: Float = 0
            let lowPassed = ir.map { x -> Float in y += alpha * (x - y); return y }
            let report = try SubSweepAnalyzer.analyze(
                leftImpulse: lowPassed, rightImpulse: lowPassed, sampleRate: rate, bass: bass(), path: path(a),
                arrangement: a, conservativePreviewSeconds: 0.05)
            XCTAssertEqual(report.openPreoutRefusal, OpenPreoutCheck.refusal, "rate \(rate)")
        }
    }

    func testOpenPreoutNeedsBassManagementAndCalibratedLFEIsNotChecked() throws {
        let a = arrangement()
        let ir = try twinImpulse(rate: 48_000, delaySeconds: 0.004, gain: 0.5)
        let off = try SubSweepAnalyzer.analyze(
            leftImpulse: ir, rightImpulse: ir, sampleRate: 48_000, bass: bass(enabled: false), path: path(a),
            arrangement: a, conservativePreviewSeconds: nil)
        XCTAssertEqual(off.openPreoutRefusal, SubSweepAnalyzer.preoutNeedsBassManagementText)
        let lfe = arrangement(receiver: .calibratedLFE(crossoverHz: 100))
        let report = try SubSweepAnalyzer.analyze(
            leftImpulse: ir, rightImpulse: [Float](repeating: 0, count: 100), sampleRate: 48_000, bass: bass(), path: path(lfe),
            arrangement: lfe, conservativePreviewSeconds: nil)
        XCTAssertEqual(report.openPreoutRefusal, "", "calibrated LFE declares its own crossover")
    }

    func testOffsetRemovalStillNeedsThreeSharedBands() {
        let bands = (0..<2).map { CombinedPathBand(centerHz: 40 + Double($0) * 10, lowHz: 35, highHz: 45, gain: 1, delaySeconds: 0.004) }
        XCTAssertNotNil(OpenPreoutCheck.refusal(measured: bands, expected: bands, sampleRate: 48_000, removingCommonOffset: true))
    }

    func testEligibilityCountComesFromTheSlowerFeed() throws {
        let a = arrangement()
        let rate = 48_000.0
        let fast = try twinImpulse(rate: rate, delaySeconds: 0.004, gain: 0.3)
        let report = try SubSweepAnalyzer.analyze(
            leftImpulse: fast, rightImpulse: fast, sampleRate: rate, bass: bass(), path: path(a), arrangement: a,
            conservativePreviewSeconds: 0.05)
        XCTAssertEqual(report.feedForwardBandCount, report.eligibility.feedForwardBandsHz.count)
        XCTAssertEqual(report.eligibility.bands.count, report.leftBands.count)
    }

    func testSweepAndControllerReadinessThroughUIModelCalls() throws {
        let a = arrangement()
        let c = try makeController(a)
        c.subAwareAncEnabled = true
        c.attachExcursionCap { ExcursionLimits(mainLowerLimitHz: 45, subCrossoverHz: 80) }
        try c.declareReceiverBass(.openPreout)
        let fp = c.ancBassPathState.fingerprint
        let z = { (r: Double) in ActiveQuietZoneComplex(real: r, imaginary: 0) }
        let band = QuietZoneVirtualSeatBand(
            frequencyHz: 50, sourceToReference: z(1), sourceToListener: z(0.02), leftSecondaryAtListener: z(1),
            rightSecondaryAtListener: z(1), leftLeakageAtReference: z(0.2), rightLeakageAtReference: z(0.2),
            measuredCoherence: 0.98)
        c.setBassPlant(BassPlantMap(bands: [band]), fingerprint: fp)
        XCTAssertEqual(c.subAwareReadiness(mode: .tonal).reason, .sweepsNotAnalysed)

        // A report whose splitter render cannot be trusted refuses, with its own words.
        c.setSubSweepReport(SubAwareArmingTests.report(fingerprint: fp, unverified: SubSweepAnalyzer.renderUnverifiedText))
        XCTAssertEqual(c.subAwareReadiness(mode: .tonal).reason, .renderUnverified)
        XCTAssertEqual(c.openPreoutRefusal, "")
        // An open-preout mismatch refuses.
        c.setSubSweepReport(SubAwareArmingTests.report(fingerprint: fp, preout: OpenPreoutCheck.refusal))
        XCTAssertEqual(c.subAwareReadiness(mode: .tonal).reason, .openPreoutMismatch)
        // A good report is ready in tonal mode; feed-forward needs at least one eligible band.
        c.setSubSweepReport(SubAwareArmingTests.report(fingerprint: fp, eligibleBands: 0))
        XCTAssertTrue(c.subAwareReadiness(mode: .tonal).isReady)
        XCTAssertEqual(c.subAwareReadiness(mode: .feedForward).reason, .noFeedForwardBand)
        c.setSubSweepReport(SubAwareArmingTests.report(fingerprint: fp))
        XCTAssertTrue(c.subAwareReadiness(mode: .feedForward).isReady)
        // Changing the setup makes the report stale along with the plant.
        try c.declareReceiverBass(.calibratedLFE(crossoverHz: 100))
        XCTAssertEqual(c.subAwareReadiness(mode: .tonal).reason, .recordStale)
        c.setBassPlant(BassPlantMap(bands: [band]), fingerprint: c.ancBassPathState.fingerprint)
        XCTAssertEqual(c.subAwareReadiness(mode: .tonal).reason, .sweepsNotAnalysed, "the old report is stale")
    }

    func testSubPathSummaryWordsEachOutcome() {
        let fp = path(arrangement()).fingerprint
        XCTAssertEqual(
            QuietZoneFeedForwardSurveyController.subPathSummary(SubAwareArmingTests.report(fingerprint: fp, unverified: "u")), "u")
        XCTAssertEqual(
            QuietZoneFeedForwardSurveyController.subPathSummary(SubAwareArmingTests.report(fingerprint: fp, preout: "p")), "p")
        XCTAssertTrue(QuietZoneFeedForwardSurveyController.subPathSummary(SubAwareArmingTests.report(fingerprint: fp, eligibleBands: 0))
            .contains("tonal Quiet Zone can still run"))
        XCTAssertTrue(QuietZoneFeedForwardSurveyController.subPathSummary(SubAwareArmingTests.report(fingerprint: fp))
            .contains("Feed-forward can run in 1 of 1"))
    }

    // MARK: G7: the tonal core's Tikhonov scaling and the graph ABI constant

    private func tonalConfig(rate: Double) -> N60RemoteTonalConfig {
        var config = N60RemoteTonalConfigDefault(rate, AdaptiveTonalLiveWorker.hostTicksPerSecond)
        config.toneCount = 1
        withUnsafeMutableBytes(of: &config.toneHz) { $0.bindMemory(to: Float.self)[0] = 50 }
        return config
    }

    func testTonalTikhonovScaleIsBoundedAtEveryRate() {
        for rate in rates {
            var config = tonalConfig(rate: rate)
            XCTAssertTrue(N60RemoteTonalConfigIsValid(&config), "rate \(rate): the default tone is valid")
            withUnsafeMutableBytes(of: &config.bassMode) { $0.bindMemory(to: UInt8.self)[0] = UInt8(N60_REMOTE_TONAL_BASS_TIKHONOV) }
            withUnsafeMutableBytes(of: &config.leakageScale) { $0.bindMemory(to: Float.self)[0] = 10 }
            let leakage = config.leakagePerSecond
            let accepted = N60RemoteTonalConfigIsValid(&config)
            XCTAssertEqual(accepted, leakage * 10 <= 10, "rate \(rate): leakagePerSecond * scale must stay at or under 10")
            withUnsafeMutableBytes(of: &config.leakageScale) { $0.bindMemory(to: Float.self)[0] = 1_000 }
            XCTAssertFalse(N60RemoteTonalConfigIsValid(&config), "rate \(rate): an unbounded scale is refused")
            withUnsafeMutableBytes(of: &config.leakageScale) { $0.bindMemory(to: Float.self)[0] = 1 }
            XCTAssertTrue(N60RemoteTonalConfigIsValid(&config), "rate \(rate): scale 1 is today's leakage")
        }
    }

    func testGraphAbiVersionConstantMatchesTheLoadedLibrary() {
        XCTAssertEqual(N60_GRAPH_ABI_VERSION, 20)
        XCTAssertEqual(n60_graph_abi_version(), UInt32(N60_GRAPH_ABI_VERSION))
    }

    private func makeController(_ a: SystemArrangement?) throws -> ActiveQuietZoneController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        try profiles.replaceSelectedSystemArrangement(a)
        let calibration = RoomCorrectionCalibrationController(engine: engine)
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        let ambient = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        return ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
    }
}
