import XCTest
@testable import NotchSixty

/// E26 S1: the bass path model, its fingerprint, the combined path record, the receiver bass declaration and the
/// undeclared-receiver refusal (always on) against the flag-gated class C change.
@MainActor
final class AncBassPathTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func arrangement(
        _ bass: BassHandling, layout: OutputProgramLayout = .stereo, receiver: ReceiverBass = .undeclared
    ) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "dac", detectedChannelCount: 8, channelsInUse: 2,
            choices: .init(
                layout: layout, bass: bass, subwooferCount: bass.isDownstream || bass == .dspToSubOutputs ? 1 : 0,
                receiverBass: receiver))
    }

    private func budget() -> QuietZoneFeedForwardBudget {
        var b = QuietZoneFeedForwardBudget.missing
        b.readiness = .physicallyPlausible
        b.conservativePreviewSeconds = 0.030
        b.antiNoisePathSeconds = 0.004
        return b
    }

    // MARK: Receiver bass

    func testReceiverBassCodableRoundTripAndValidity() throws {
        for value in [ReceiverBass.undeclared, .openPreout, .calibratedLFE(crossoverHz: 80), .calibratedLFE(crossoverHz: 120)] {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(ReceiverBass.self, from: data), value)
        }
        XCTAssertFalse(ReceiverBass.undeclared.isDeclared)
        XCTAssertTrue(ReceiverBass.openPreout.isDeclared)
        XCTAssertTrue(ReceiverBass.calibratedLFE(crossoverHz: 80).isDeclared)
        XCTAssertFalse(ReceiverBass.calibratedLFE(crossoverHz: 10).isValid)
        XCTAssertFalse(ReceiverBass.calibratedLFE(crossoverHz: .nan).isValid)
        XCTAssertEqual(ReceiverBass.defaultCrossoverHz, 80)
        // A stored out-of-range crossover cannot be trusted for the caps, so it decodes as undeclared.
        let bad = Data(#"{"kind":"calibratedLFE","crossoverHz":900}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(ReceiverBass.self, from: bad), .undeclared)
        XCTAssertThrowsError(try JSONDecoder().decode(ReceiverBass.self, from: Data(#"{"kind":"x"}"#.utf8)))
    }

    func testOldArrangementWithoutDeclarationDecodesAsUndeclared() throws {
        let a = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as? [String: Any])
        object.removeValue(forKey: "receiverBass")
        let old = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(SystemArrangement.self, from: old).receiverBass, .undeclared)
        let kept = try JSONDecoder().decode(SystemArrangement.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(kept.receiverBass, .openPreout)
    }

    func testPlannerCarriesTheDeclarationOnlyForDownstreamBass() {
        XCTAssertEqual(arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout).receiverBass, .openPreout)
        XCTAssertEqual(
            arrangement(.downstreamSubCrossover, receiver: .calibratedLFE(crossoverHz: 100)).receiverBass,
            .calibratedLFE(crossoverHz: 100))
        XCTAssertEqual(arrangement(.fullRange, receiver: .openPreout).receiverBass, .undeclared)
        XCTAssertEqual(arrangement(.dspMonoToMains, receiver: .openPreout).receiverBass, .undeclared)
        XCTAssertEqual(
            arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .calibratedLFE(crossoverHz: 5)).receiverBass,
            .undeclared, "an invalid crossover is not stored as a declaration")
        let a = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout)
        XCTAssertEqual(SystemSetupArrangementPlanner.choices(from: a).receiverBass, .openPreout)
    }

    // MARK: Class table

    func testPathResolutionForClassesBToE() {
        let table: [(String, SystemArrangement, (AncBassPath) -> Bool, Bool)] = [
            ("B", arrangement(.fullRange), { $0 == .none }, false),
            ("C", arrangement(.dspMonoToMains), { $0 == .monoBassOnPair }, false),
            ("D", arrangement(.downstreamSubCrossover, receiver: .openPreout), { $0.isDownstream }, true),
            ("E", arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .calibratedLFE(crossoverHz: 80)),
             { $0.isDownstream }, true),
        ]
        for rate in rates {
            for (name, a, matches, sub) in table {
                let state = AncBassPathState.resolve(arrangement: a, bassManagement: nil)
                XCTAssertTrue(matches(state.path), "class \(name) at \(rate)")
                XCTAssertEqual(state.path.hasSubwooferForAnc, sub, "class \(name) at \(rate)")
            }
        }
        var splitter = BassManagementConfiguration()
        splitter.enabled = true
        XCTAssertEqual(AncBassPathState.resolve(arrangement: nil, bassManagement: splitter).path, .appSplitter(splitter))
        XCTAssertTrue(AncBassPath.appSplitter(splitter).hasSubwooferForAnc)
        XCTAssertEqual(AncBassPathState.resolve(arrangement: nil, bassManagement: BassManagementConfiguration()).path, .none)
    }

    // MARK: Fingerprint

    func testFingerprintChangesOnEverySplitterField() {
        let base: BassManagementConfiguration = {
            var c = BassManagementConfiguration()
            c.enabled = true
            c.physicalOutputMode = .mainsSub
            c.upperFrequencyHz = 160
            c.upperTopology = .linkwitzRiley24
            return c
        }()
        func print(_ c: BassManagementConfiguration) -> AncBassPathFingerprint {
            AncBassPathState.resolve(arrangement: nil, bassManagement: c).fingerprint
        }
        let reference = print(base)
        XCTAssertEqual(reference, print(base), "deterministic")
        var edits: [(String, (inout BassManagementConfiguration) -> Void)] = [
            ("frequency", { $0.frequencyHz = 100 }),
            ("topology", { $0.topology = .linkwitzRiley48 }),
            ("monitor", { $0.monitorMode = .subOnly }),
            ("subGain", { $0.subGainDB = 3 }),
            ("polarity", { $0.subPolarityInverted = true }),
            ("alignEnabled", { $0.subPhaseAlignmentEnabled = true }),
            ("alignFrequency", { $0.subPhaseAlignmentFrequencyHz = 60 }),
            ("alignQ", { $0.subPhaseAlignmentQ = 1.2 }),
            ("mode", { $0.physicalOutputMode = .biAmp }),
            ("upperFrequency", { $0.upperFrequencyHz = 200 }),
            ("upperTopology", { $0.upperTopology = .linkwitzRiley48 }),
        ]
        edits.append(("mode nil", { $0.physicalOutputMode = nil }))
        for (name, edit) in edits {
            var c = base
            edit(&c)
            XCTAssertNotEqual(print(c), reference, "splitter field \(name) must change the fingerprint")
        }
    }

    func testFingerprintChangesOnArrangementEditsAndDeclaration() {
        let base = arrangement(.downstreamReceiver, layout: .fiveOne, receiver: .openPreout)
        func print(_ a: SystemArrangement) -> AncBassPathFingerprint {
            AncBassPathState.resolve(arrangement: a, bassManagement: nil).fingerprint
        }
        let reference = print(base)
        XCTAssertEqual(reference, print(base))
        var edits: [(String, (inout SystemArrangement) -> Void)] = [
            ("declaration", { $0.receiverBass = .calibratedLFE(crossoverHz: 80) }),
            ("crossover", { $0.receiverBass = .calibratedLFE(crossoverHz: 90) }),
            ("subs", { $0.subwooferCount = 2 }),
            ("layout", { $0.layout = .stereo }),
            ("foldDown", { $0.foldDown = nil; $0.realisation = .routing }),
        ]
        edits.append(("bass", { $0.bass = .downstreamSubCrossover }))
        for (name, edit) in edits {
            var a = base
            edit(&a)
            XCTAssertNotEqual(print(a), reference, "arrangement edit \(name) must change the fingerprint")
        }
        XCTAssertNotEqual(
            AncBassPathState.resolve(arrangement: arrangement(.fullRange), bassManagement: nil).fingerprint,
            AncBassPathState.resolve(arrangement: arrangement(.dspMonoToMains), bassManagement: nil).fingerprint)
    }

    func testFreshnessOfUnstampedAndStampedMeasurements() {
        let none = AncBassPathState.resolve(arrangement: arrangement(.fullRange), bassManagement: nil)
        let mono = AncBassPathState.resolve(arrangement: arrangement(.dspMonoToMains), bassManagement: nil)
        let down = AncBassPathState.resolve(
            arrangement: arrangement(.downstreamSubCrossover, receiver: .openPreout), bassManagement: nil)
        XCTAssertEqual(none.freshness(of: nil), .fresh, "existing ANC measurements read as .none")
        XCTAssertEqual(mono.freshness(of: nil), .fresh)
        XCTAssertEqual(down.freshness(of: nil), .stale(AncBassPathState.staleMessage))
        XCTAssertEqual(down.freshness(of: down.fingerprint), .fresh)
        XCTAssertEqual(down.freshness(of: none.fingerprint), .stale("Your bass settings changed. Measure Quiet Zone again."))
        var splitter = BassManagementConfiguration()
        splitter.enabled = true
        let app = AncBassPathState.resolve(arrangement: nil, bassManagement: splitter)
        XCTAssertEqual(app.freshness(of: nil), .stale(AncBassPathState.staleMessage))
    }

    // MARK: Combined path record

    func testCombinedPathRecordRoundTripsAndRejectsDamage() throws {
        let fp = AncBassPathState.resolve(arrangement: arrangement(.fullRange), bassManagement: nil).fingerprint
        for rate in rates {
            let n = Int(rate * 0.05)
            let record = CombinedAncPathRecord(
                source: .feedLeft, destination: .seatMicrophone, windowSeconds: 0.05, sampleRate: rate,
                fingerprint: fp, impulseResponse: (0..<n).map { Float(sin(Double($0) * 0.01)) })
            XCTAssertTrue(record.isValid, "\(rate)")
            let decoded = try JSONDecoder().decode(CombinedAncPathRecord.self, from: JSONEncoder().encode(record))
            XCTAssertEqual(decoded, record, "\(rate)")
        }
        var bad = CombinedAncPathRecord(
            source: .subLane, destination: .referenceMicrophone, windowSeconds: 0.01, sampleRate: 48_000,
            fingerprint: fp, impulseResponse: [0, 1])
        bad.schemaVersion = 99
        XCTAssertFalse(bad.isValid)
        XCTAssertThrowsError(try JSONDecoder().decode(CombinedAncPathRecord.self, from: JSONEncoder().encode(bad)))
        bad.schemaVersion = 1
        bad.impulseResponse = []
        XCTAssertFalse(bad.isValid)
        bad.impulseResponse = [0, .nan]
        XCTAssertFalse(bad.isValid)
        bad.impulseResponse = [0, 1]
        bad.bandLowHz = 5
        XCTAssertFalse(bad.isValid, "below the 15 Hz band")
        bad.bandLowHz = 15
        bad.sampleRate = 0
        XCTAssertFalse(bad.isValid)
    }

    // MARK: Refusals

    func testUndeclaredReceiverRefusalAndDeclaredSetupsClearIt() {
        let undeclared = TwoChannelAncArming.undeclaredReceiverRefusal
        XCTAssertEqual(undeclared, "Tell Notch Sixty how your receiver handles bass.")
        for (bass, layout) in [(BassHandling.downstreamSubCrossover, OutputProgramLayout.stereo), (.downstreamReceiver, .fiveOne)] {
            XCTAssertEqual(TwoChannelAncArming.refusal(arrangement: arrangement(bass, layout: layout), budget: budget()), undeclared)
            for declared in [ReceiverBass.openPreout, .calibratedLFE(crossoverHz: 80)] {
                XCTAssertEqual(
                    TwoChannelAncArming.refusal(arrangement: arrangement(bass, layout: layout, receiver: declared), budget: budget()),
                    "Quiet Zone is not available with a subwoofer yet.",
                    "a declaration clears the undeclared refusal; the blanket sub refusal stays until S5")
            }
        }
    }

    func testNoDownstreamSubLeavesArmingUnchanged() {
        for bass in [BassHandling.fullRange, .dspMonoToMains] {
            XCTAssertNil(TwoChannelAncArming.refusal(arrangement: arrangement(bass), budget: budget()), "\(bass)")
        }
        XCTAssertNil(TwoChannelAncArming.refusal(arrangement: nil, budget: budget()))
    }

    func testFeedForwardRefusesWhileUndeclaredAndNotOtherwise() {
        var policy = FeedForwardLiveArmingPolicy()
        var f = FeedForwardLiveQuietZoneFacts(
            armed: true, hasBaseline: true, verdict: .ok, leaseRequired: false, leaseHealthy: true,
            outputDeviceUID: "dac", sampleRate: 48_000, budget: budget())
        f.receiverBassUndeclared = true
        XCTAssertFalse(policy.request(quietZone: f, now: 0))
        f.receiverBassUndeclared = false
        XCTAssertTrue(policy.request(quietZone: f, now: 0), "no downstream sub: arming is unchanged")
    }

    // MARK: Controller

    private func makeController(_ arrangement: SystemArrangement?) throws -> ActiveQuietZoneController {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let engine = AudioIOEngine()
        let profiles = ProductProfileController(engine: engine, storageURL: root.appendingPathComponent("profiles.json"))
        try profiles.replaceSelectedSystemArrangement(arrangement)
        let calibration = RoomCorrectionCalibrationController(engine: engine)
        let projects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: root.appendingPathComponent("rc", isDirectory: true)))
        let ambient = AmbientCompensationController(
            engine: engine, profiles: profiles, microphone: calibration, projects: projects)
        return ActiveQuietZoneController(engine: engine, profiles: profiles, ambient: ambient)
    }

    func testTonalArmIsRefusedWhileReceiverBassIsUndeclared() throws {
        let undeclared = try makeController(arrangement(.downstreamReceiver, layout: .fiveOne))
        XCTAssertTrue(undeclared.receiverBassUndeclared)
        XCTAssertTrue(undeclared.feedForwardLiveFacts().receiverBassUndeclared)
        XCTAssertThrowsError(try undeclared.setEnabled(true)) {
            XCTAssertEqual($0 as? ActiveQuietZoneControllerError, .receiverBassUndeclared)
        }
        XCTAssertFalse(undeclared.arm.isArmed)
        XCTAssertFalse(undeclared.configuration.enabled)

        for declared in [ReceiverBass.openPreout, .calibratedLFE(crossoverHz: 80)] {
            let c = try makeController(arrangement(.downstreamReceiver, layout: .fiveOne, receiver: declared))
            XCTAssertFalse(c.receiverBassUndeclared)
            XCTAssertThrowsError(try c.setEnabled(true)) {
                XCTAssertEqual($0 as? LiveTreatmentArmError, .engineNotRunning, "the declaration clears the new refusal only")
            }
        }
        for a in [arrangement(.fullRange), arrangement(.dspMonoToMains)] {
            let c = try makeController(a)
            XCTAssertFalse(c.receiverBassUndeclared)
            XCTAssertThrowsError(try c.setEnabled(true)) {
                XCTAssertEqual($0 as? LiveTreatmentArmError, .engineNotRunning)
            }
        }
    }

    func testClassCStopsCountingAsASubOnlyUnderTheFlag() throws {
        let c = try makeController(arrangement(.dspMonoToMains))
        // The engine's own bass management state decides with the flag off; class C is never downstream.
        XCTAssertEqual(c.subwooferActiveForAnc, c.engine.subwooferActive)
        c.subAwareAncEnabled = true
        XCTAssertFalse(c.subwooferActiveForAnc, "anti-noise bypasses STEREO_CROSSOVER, so mono bass is not a sub")
        let d = try makeController(arrangement(.downstreamSubCrossover, receiver: .openPreout))
        d.subAwareAncEnabled = true
        XCTAssertTrue(d.subwooferActiveForAnc, "downstream subs stay refused until S5")
        d.subAwareAncEnabled = false
        XCTAssertTrue(d.subwooferActiveForAnc)
    }

    func testFlagIsRegisteredAndOff() {
        XCTAssertTrue(FeatureFlag.all.contains(.subAwareAnc))
        XCTAssertEqual(FeatureFlag.subAwareAnc.id, "e26.sub-aware-anc")
        XCTAssertFalse(FeatureFlags().isEnabled(.subAwareAnc))
    }
}
