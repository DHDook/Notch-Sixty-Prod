import XCTest
@testable import NotchSixty

// E26 S5: SubAwareAncReadiness (design 8), the controller wiring through UI-model calls, and the refusals for a missing
// plant. Readiness alone never arms.
@MainActor
final class SubAwareArmingTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func z(_ r: Double, _ i: Double = 0) -> ActiveQuietZoneComplex { ActiveQuietZoneComplex(real: r, imaginary: i) }

    private func arrangement(_ bass: BassHandling, layout: OutputProgramLayout = .stereo, receiver: ReceiverBass = .undeclared)
        -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 2,
            choices: .init(
                layout: layout, bass: bass, subwooferCount: bass.isDownstream || bass == .dspToSubOutputs ? 1 : 0,
                receiverBass: receiver))
    }

    /// A rank-one twin plant at `rate`: both feeds reach the sub through the same delayed path.
    private func plant(rate: Double) -> BassPlantMap {
        BassPlantMap(bands: [40.0, 50, 63].map { hz in
            let angle = -2 * Double.pi * hz * (0.004 * rate).rounded() / rate
            let sub = z(cos(angle), sin(angle))
            return QuietZoneVirtualSeatBand(
                frequencyHz: hz, sourceToReference: z(1), sourceToListener: z(0.02),
                leftSecondaryAtListener: sub, rightSecondaryAtListener: sub,
                leftLeakageAtReference: sub * z(0.2), rightLeakageAtReference: sub * z(0.2), measuredCoherence: 0.98)
        })
    }

    private func inputs(
        _ a: SystemArrangement?, mode: SubAwareAncReadiness.Mode = .tonal, rate: Double = 48_000, stamped: Bool = true,
        safety: Bool = true, preout: String? = nil, plantMap: BassPlantMap? = nil
    ) -> SubAwareAncReadiness.Inputs {
        let path = AncBassPathState.resolve(arrangement: a, bassManagement: nil)
        return .init(
            mode: mode, path: path, plant: plantMap ?? plant(rate: rate), plantFingerprint: stamped ? path.fingerprint : nil,
            openPreoutRefusal: preout, safetyAvailable: safety, feedForwardBandCount: nil)
    }

    func testReadinessReasonsInOrderAtEveryRate() {
        let declared = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout)
        for rate in rates {
            XCTAssertTrue(SubAwareAncReadiness.evaluate(inputs(declared, rate: rate)).isReady, "\(rate)")

            var all = inputs(arrangement(.downstreamReceiver, layout: .fiveOne), rate: rate, stamped: false, safety: false,
                             preout: "x")
            all.plant = BassPlantMap(bands: [])
            XCTAssertEqual(SubAwareAncReadiness.evaluate(all).reason, .receiverUndeclared)

            var i = inputs(declared, rate: rate, stamped: false, safety: false, preout: OpenPreoutCheck.refusal)
            i.plant = BassPlantMap(bands: [])
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .plantMissing)
            i.plant = plant(rate: rate)
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .plantMissing, "unstamped plant")
            i.plantFingerprint = AncBassPathState.resolve(arrangement: arrangement(.fullRange), bassManagement: nil).fingerprint
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .recordStale)
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).message, AncBassPathState.staleMessage)
            i.plantFingerprint = i.path.fingerprint
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .openPreoutMismatch)
            i.openPreoutRefusal = ""
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .safetyUnavailable)
            i.safetyAvailable = true
            XCTAssertTrue(SubAwareAncReadiness.evaluate(i).isReady)

            i.mode = .feedForward
            i.feedForwardBandCount = 0
            XCTAssertEqual(SubAwareAncReadiness.evaluate(i).reason, .noFeedForwardBand)
            i.feedForwardBandCount = 3
            XCTAssertTrue(SubAwareAncReadiness.evaluate(i).isReady)
        }
    }

    func testOpenPreoutRefusalDoesNotApplyToCalibratedLFE() {
        let lfe = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .calibratedLFE(crossoverHz: 80))
        XCTAssertTrue(SubAwareAncReadiness.evaluate(inputs(lfe, preout: OpenPreoutCheck.refusal)).isReady)
    }

    func testNonFinitePlantIsNotConditioned() {
        let declared = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout)
        let bad = BassPlantMap(bands: [QuietZoneVirtualSeatBand(
            frequencyHz: 50, sourceToReference: z(1), sourceToListener: z(0.02), leftSecondaryAtListener: z(.nan),
            rightSecondaryAtListener: z(1), leftLeakageAtReference: z(0.2), rightLeakageAtReference: z(0.2),
            measuredCoherence: 0.9)])
        XCTAssertEqual(SubAwareAncReadiness.evaluate(inputs(declared, plantMap: bad)).reason, .notConditioned)
    }

    // MARK: Controller, through UI-model calls

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

    func testFlagOffIsUnchanged() throws {
        let c = try makeController(arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout))
        XCTAssertTrue(c.subAwareReadiness(mode: .tonal).isReady, "the flag-off path never consults readiness")
        let facts = c.feedForwardLiveFacts()
        XCTAssertTrue(facts.subwooferActive)
        XCTAssertNil(facts.subAwareRefusal)
        XCTAssertEqual(c.arrangementRefusal, "Quiet Zone is not available with a subwoofer yet.")
    }

    func testClassesDAndEThroughTheUIModelCalls() throws {
        let cases: [(BassHandling, OutputProgramLayout)] = [(.downstreamSubCrossover, .stereo), (.downstreamReceiver, .fiveOne)]
        for (bass, layout) in cases {
            let c = try makeController(arrangement(bass, layout: layout))
            c.subAwareAncEnabled = true
            c.attachExcursionCap { ExcursionLimits(mainLowerLimitHz: 45, subCrossoverHz: 80) }
            // Undeclared: the old always-on refusal wins.
            XCTAssertThrowsError(try c.setEnabled(true)) {
                XCTAssertEqual($0 as? ActiveQuietZoneControllerError, .receiverBassUndeclared)
            }
            // Declared through the setup card: a missing plant refuses, and says what to do.
            try c.declareReceiverBass(.openPreout)
            XCTAssertFalse(c.receiverBassUndeclared)
            XCTAssertThrowsError(try c.setEnabled(true)) {
                XCTAssertEqual(
                    $0 as? ActiveQuietZoneControllerError,
                    .subAwareRefused(SubAwareAncReadiness.plantMissingMessage))
            }
            XCTAssertFalse(c.arm.isArmed)
            let facts = c.feedForwardLiveFacts()
            XCTAssertFalse(facts.subwooferActive, "readiness replaces the blanket refusal under the flag")
            XCTAssertEqual(facts.subAwareRefusal, SubAwareAncReadiness.plantMissingMessage)
            XCTAssertNotEqual(c.arrangementRefusal, "Quiet Zone is not available with a subwoofer yet.")

            // Measured under today's setup: readiness passes; Turn On then fails only at the engine (not running),
            // so readiness never arms.
            c.setBassPlant(plant(rate: 48_000), fingerprint: c.ancBassPathState.fingerprint)
            XCTAssertTrue(c.subAwareReadiness(mode: .tonal).isReady)
            XCTAssertNil(c.feedForwardLiveFacts().subAwareRefusal)
            XCTAssertFalse(c.arm.isArmed, "readiness alone never arms")
            XCTAssertThrowsError(try c.setEnabled(true)) {
                XCTAssertEqual($0 as? LiveTreatmentArmError, .engineNotRunning)
            }

            // Changing the declaration makes the measurement stale.
            try c.declareReceiverBass(.calibratedLFE(crossoverHz: 100))
            let stale = c.subAwareReadiness(mode: .tonal)
            XCTAssertEqual(stale.reason, .recordStale)
            XCTAssertEqual(c.feedForwardLiveFacts().subAwareRefusal, AncBassPathState.staleMessage)
        }
    }

    func testFeedForwardWaitsThenTurnsOffOnSubAwareRefusal() {
        var policy = FeedForwardLiveArmingPolicy()
        var budget = QuietZoneFeedForwardBudget.missing
        budget.readiness = .physicallyPlausible
        var f = FeedForwardLiveQuietZoneFacts(
            armed: true, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "dac", sampleRate: 48_000, budget: budget)
        f.subAwareRefusal = SubAwareAncReadiness.plantMissingMessage
        XCTAssertTrue(policy.request(quietZone: f, now: 0), "a sub in the path waits instead of refusing the request")
        _ = policy.step(quietZone: f, shadow: FeedForwardLiveShadowFacts(stability: .passed(loopGain: 0.2), verifiedRemovalDecibels: 25, referenceRunning: true, pumpDelaySeconds: 0.020), kernel: nil, now: 1)
        XCTAssertEqual(policy.phase, .waiting(SubAwareAncReadiness.plantMissingMessage))
    }

    func testMissingPlantIsNotTheFreeSolve() {
        let empty = BassPlantMap(bands: [])
        XCTAssertNil(empty.conditioning(atHz: 50), "the controller turns this into a refusal under the flag")
        XCTAssertNil(plant(rate: 48_000).conditioning(atHz: 500), "a tone far from any measured band has no plant")
    }

    func testDeclareReceiverBassWithoutArrangementDoesNothing() throws {
        let c = try makeController(nil)
        try c.declareReceiverBass(.openPreout)
        XCTAssertNil(c.arrangement)
    }

    func testSetupTextCoversEveryPath() {
        let paths: [AncBassPath] = [.none, .monoBassOnPair, .downstream(.undeclared), .downstream(.openPreout),
                                    .downstream(.calibratedLFE(crossoverHz: 100)), .appSplitter(BassManagementConfiguration()),
                                    .subOutput]
        XCTAssertEqual(Set(paths.map(SubAwareQuietZoneText.pathSummary)).count, paths.count)
        XCTAssertTrue(SubAwareQuietZoneText.pathSummary(.downstream(.calibratedLFE(crossoverHz: 100))).contains("100 Hz"))
        XCTAssertTrue(SubAwareQuietZoneText.advice.contains("room EQ"))
        XCTAssertEqual(SubAwareQuietZoneText.question, "How does bass reach the room?")
    }
}
