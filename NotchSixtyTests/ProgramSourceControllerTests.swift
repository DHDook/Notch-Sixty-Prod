import XCTest
@testable import NotchSixty

/// E25 S8b: the Speakers-tab program source controller (classes B to E, LFE and headroom, every resolution text) and
/// Quiet Zone readiness and arming for the stored arrangement.
@MainActor
final class ProgramSourceControllerTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private final class FakeEngine: ProgramFoldDownEngine {
        var devices: [AudioOutputDevice] = []
        var selected: AudioOutputDevice?
        var applied: [ProgramFoldDownPlan?] = []
        var failure: Error?
        var programSourceCandidates: [AudioOutputDevice] { devices }
        var programSourceSelectedOutput: AudioOutputDevice? { selected }
        func applyProgramFoldDown(_ plan: ProgramFoldDownPlan?) throws {
            if let failure, plan != nil { throw failure }
            applied.append(plan)
        }
    }

    private func device(_ uid: String, channels: UInt32, rate: Double = 48_000) -> AudioOutputDevice {
        AudioOutputDevice(
            deviceID: 1, uid: uid, name: uid, nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)],
            outputChannelCount: channels)
    }

    private func arrangement(_ bass: BassHandling, layout: OutputProgramLayout = .fiveOne) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 2,
            choices: .init(layout: layout, bass: bass, subwooferCount: bass.isDownstream || bass == .dspToSubOutputs ? 1 : 0))
    }

    private func make(
        _ arrangement: SystemArrangement?, rate: Double = 48_000
    ) throws -> (ProgramSourceController, FakeEngine, ProductProfileController) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let real = AudioIOEngine()
        let profiles = ProductProfileController(engine: real, storageURL: root.appendingPathComponent("profiles.json"))
        try profiles.replaceSelectedSystemArrangement(arrangement)
        let engine = FakeEngine()
        engine.selected = device("dac", channels: 2, rate: rate)
        engine.devices = [engine.selected!, device("rx", channels: 6, rate: rate), device("stereo", channels: 2, rate: rate)]
        let controller = ProgramSourceController(engine: engine, profiles: profiles)
        return (controller, engine, profiles)
    }

    func testVisibleForClassesBToEAndHiddenForAOrNoArrangement() throws {
        for bass in [BassHandling.fullRange, .dspMonoToMains, .downstreamSubCrossover, .downstreamReceiver] {
            let (c, _, _) = try make(arrangement(bass))
            XCTAssertTrue(c.isVisible, "\(bass)")
        }
        XCTAssertFalse(try make(nil).0.isVisible)
        let a = SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 6, choices: .init(layout: .fiveOne, bass: .fullRange, subwooferCount: 0))
        XCTAssertFalse(try make(a).0.isVisible)
    }

    func testPickingASourceStoresItAndAppliesAPlan() throws {
        for rate in rates {
            let (c, engine, profiles) = try make(arrangement(.downstreamReceiver), rate: rate)
            XCTAssertEqual(c.candidates.map(\.uid), ["rx", "stereo"], "the DAC is never a candidate")
            XCTAssertEqual(c.resolution, .upstreamFold)
            c.setSource(uid: "rx")
            XCTAssertEqual(profiles.selectedSystemProfile?.state.systemArrangement?.foldDown?.programSourceDeviceUID, "rx")
            XCTAssertEqual(engine.applied.last??.sourceUID, "rx")
            XCTAssertEqual(c.resolution, .source(uid: "rx"))
            XCTAssertTrue(c.resolutionText.contains("Set the macOS output to rx"), c.resolutionText)
            c.setSource(uid: nil)
            XCTAssertNil(engine.applied.last!)
        }
    }

    func testLFEAndHeadroomRebuildThePlan() throws {
        let (c, engine, _) = try make(arrangement(.downstreamSubCrossover))
        c.setSource(uid: "rx")
        c.setLFE(.foldPlus10dBWithLimiter)
        XCTAssertEqual(engine.applied.last??.foldDown.lfe, .foldPlus10dBWithLimiter)
        XCTAssertTrue(engine.applied.last??.matrix.needsLimiter ?? false)
        XCTAssertTrue(c.lfeNote.contains("+10 dB"))
        c.setHeadroom(.peakSafe)
        XCTAssertFalse(engine.applied.last??.matrix.needsLimiter ?? true)
        let count = engine.applied.count
        c.setHeadroom(.peakSafe)
        XCTAssertEqual(engine.applied.count, count, "an unchanged choice does not touch the engine")
    }

    func testEachResolutionHasItsText() throws {
        let (c, engine, _) = try make(arrangement(.downstreamReceiver))
        c.setSource(uid: "gone")
        XCTAssertEqual(c.resolution, .waitForDevice(uid: "gone"))
        XCTAssertTrue(c.resolutionText.contains("never switches"))
        c.setSource(uid: "stereo")
        XCTAssertEqual(c.resolution, .channelCountMismatch(expected: 6, actual: 2))
        XCTAssertTrue(c.resolutionText.contains("2 channels"))
        engine.devices[1] = AudioOutputDevice(
            deviceID: 1, uid: "rx", name: "rx", nominalSampleRate: 44_100,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 44_100)], outputChannelCount: 6)
        c.setSource(uid: "rx")
        XCTAssertEqual(c.resolution, .sampleRateUnsupported(48_000))
        XCTAssertTrue(c.resolutionText.contains("never resamples"))
    }

    func testStereoProgramHasNothingToFold() throws {
        let (c, engine, _) = try make(arrangement(.fullRange, layout: .stereo))
        XCTAssertTrue(c.isVisible)
        XCTAssertFalse(c.foldApplies)
        c.setSource(uid: "rx")
        XCTAssertTrue(engine.applied.isEmpty)
        XCTAssertTrue(c.resolutionText.contains("nothing to fold"))
    }

    func testEngineRefusalRevertsStoredState() throws {
        let (c, engine, profiles) = try make(arrangement(.downstreamReceiver))
        engine.failure = CoreAudioTransportError.programFoldFailed(.incompatibleOutput("a headphone profile"))
        c.setSource(uid: "rx")
        XCTAssertNotNil(c.lastError)
        XCTAssertNil(profiles.selectedSystemProfile?.state.systemArrangement?.foldDown)
    }

    // MARK: - Quiet Zone

    private func budget(preview: Double? = 0.030, path: Double? = 0.004) -> QuietZoneFeedForwardBudget {
        var b = QuietZoneFeedForwardBudget.missing
        b.readiness = .physicallyPlausible
        b.conservativePreviewSeconds = preview
        b.antiNoisePathSeconds = path
        return b
    }

    func testDownstreamSubwooferRefusesLiveQuietZone() {
        XCTAssertTrue(arrangement(.downstreamSubCrossover, layout: .stereo).hasDownstreamSubwoofer)
        XCTAssertTrue(arrangement(.downstreamReceiver).hasDownstreamSubwoofer)
        XCTAssertFalse(arrangement(.fullRange).hasDownstreamSubwoofer)
        XCTAssertFalse(arrangement(.dspMonoToMains).hasDownstreamSubwoofer)
        let text = TwoChannelAncArming.refusal(arrangement: arrangement(.downstreamSubCrossover, layout: .stereo), budget: budget())
        XCTAssertEqual(text, "Quiet Zone is not available with a subwoofer yet.")
    }

    func testReadinessTextFollowsTheMeasuredFeedAtEveryRate() {
        for rate in rates {
            let fits = TwoChannelAncEligibility.seconds(frames: Int((0.010 * rate).rounded()), sampleRate: rate)
            let over = TwoChannelAncEligibility.seconds(frames: Int((0.029 * rate).rounded()), sampleRate: rate)
            XCTAssertNil(TwoChannelAncArming.refusal(arrangement: arrangement(.fullRange), budget: budget(path: fits)))
            XCTAssertNotNil(TwoChannelAncArming.refusal(arrangement: arrangement(.fullRange), budget: budget(path: over)))
            XCTAssertNotNil(TwoChannelAncArming.refusal(arrangement: arrangement(.fullRange), budget: budget(path: nil)))
        }
        XCTAssertNil(TwoChannelAncArming.refusal(arrangement: nil, budget: budget(path: nil)), "flag off adds nothing")
    }

    func testArrangementRefusalOnlyAddsAWaitAndNeverArms() {
        var policy = FeedForwardLiveArmingPolicy()
        var f = FeedForwardLiveQuietZoneFacts(
            armed: true, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "dac", sampleRate: 48_000, budget: budget())
        f.arrangementRefusal = "Measure the feed latency first."
        XCTAssertTrue(policy.request(quietZone: f, now: 0))
        let shadow = FeedForwardLiveShadowFacts(
            stability: .passed(loopGain: 0.2), verifiedRemovalDecibels: 25, referenceRunning: true, pumpDelaySeconds: 0.001)
        let decision = policy.step(quietZone: f, shadow: shadow, kernel: nil, now: 1)
        XCTAssertEqual(policy.phase, .waiting("Measure the feed latency first."))
        if case .arm = decision { XCTFail("a refusal must not arm") }
    }

    func testSubwooferFactBlocksTheRequest() {
        var policy = FeedForwardLiveArmingPolicy()
        var f = FeedForwardLiveQuietZoneFacts(
            armed: true, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "dac", sampleRate: 48_000, budget: budget())
        f.subwooferActive = true
        XCTAssertFalse(policy.request(quietZone: f, now: 0))
    }
}
