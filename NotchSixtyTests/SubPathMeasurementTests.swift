import XCTest
@testable import NotchSixty

/// E26 S7c: the class A (two mains plus one sub output) sub-path measurement: arming shape, seat and leakage plans,
/// offline composition, the per-output stability bound and the record schema. Eight rates where DSP is involved.
/// Bench (E22): a 2.1 interface with the sub on output 3, the nine leakage passes and the two seat passes.
final class SubPathMeasurementTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func classA(subs: Int = 1, layout: OutputProgramLayout = .stereo, channels: Int = 3) -> SystemArrangement {
        SystemSetupArrangementPlanner.arrangement(
            deviceUID: "out", detectedChannelCount: 8, channelsInUse: channels,
            choices: .init(layout: layout, bass: .dspToSubOutputs, subwooferCount: subs, receiverBass: .undeclared))
    }

    private func bass() -> BassManagementConfiguration {
        var c = BassManagementConfiguration()
        c.enabled = true
        c.frequencyHz = 80
        c.physicalOutputMode = .mainsSub
        return c
    }

    private func program(rate: Double) throws -> RoomCorrectionSweepProgram {
        try RoomCorrectionSweepGenerator().makeProgram(settings: RoomCorrectionSweepSettings(
            sampleRate: rate, startFrequencyHz: 15, endFrequencyHz: 640, durationSeconds: 0.5, levelDBFS: -20,
            leadInSeconds: 0.05, tailSeconds: 0.3, fadeSeconds: 0.01))
    }

    // MARK: arming shape

    func testShapeIsTwoMainsAndOneSubOnly() {
        XCTAssertTrue(classA().isTwoMainsOneSub)
        XCTAssertFalse(classA(subs: 2, channels: 4).isTwoMainsOneSub, "two subs are not v1")
        XCTAssertFalse(classA(layout: .fiveOne, channels: 6).isTwoMainsOneSub, "5.1 is not v1")
    }

    func testClassARefusalIsUnchangedWithTheFlagOffAndLiftedForTheV1ShapeOnly() {
        let a = classA()
        guard case .refused(let off) = TwoChannelAncEligibility.evaluate(
            arrangement: a, feedLatencyUpperBoundSeconds: 0.001, conservativePreviewSeconds: 0.05)
        else { return XCTFail("flag off keeps the refusal") }
        XCTAssertTrue(off.contains("two-channel session"))
        guard case .eligible = TwoChannelAncEligibility.evaluate(
            arrangement: a, feedLatencyUpperBoundSeconds: 0.001, conservativePreviewSeconds: 0.05, allowClassA: true)
        else { return XCTFail("v1 shape is eligible with sub-aware ANC on") }
        let wide = classA(layout: .fiveOne, channels: 6)
        XCTAssertEqual(
            TwoChannelAncEligibility.evaluate(
                arrangement: wide, feedLatencyUpperBoundSeconds: 0.001, conservativePreviewSeconds: 0.05,
                allowClassA: true),
            .refused(reason: "Quiet Zone supports two speakers and one subwoofer output."))
    }

    func testArmingRefusalFollowsTheSubAwareParameter() {
        let budget = QuietZoneFeedForwardBudget.missing
        XCTAssertNotNil(TwoChannelAncArming.refusal(arrangement: classA(), budget: budget, subAware: false))
        // With the flag on the shape passes; any remaining refusal is the timing budget, never the class.
        let on = TwoChannelAncArming.refusal(arrangement: classA(), budget: budget, subAware: true)
        XCTAssertFalse(on?.contains("two-channel session") ?? false)
        XCTAssertEqual(
            TwoChannelAncArming.refusal(arrangement: classA(layout: .fiveOne, channels: 6), budget: budget, subAware: true),
            TwoChannelAncArming.classAShapeRefusal)
    }

    func testCapabilityMatrixFollowsTheFlag() {
        let a = classA()
        XCTAssertFalse(SystemCapabilityMatrix.evaluate(.quietZone, arrangement: a).text.isEmpty)
        if case .unavailable = SystemCapabilityMatrix.evaluate(.quietZone, arrangement: a) {} else { XCTFail("off") }
        if case .limited = SystemCapabilityMatrix.evaluate(.quietZone, arrangement: a, subAwareQuietZone: true) {} else {
            XCTFail("on")
        }
        if case .unavailable = SystemCapabilityMatrix.evaluate(
            .quietZone, arrangement: classA(layout: .fiveOne, channels: 6), subAwareQuietZone: true) {} else {
            XCTFail("wide shapes stay unavailable")
        }
    }

    // MARK: fingerprint and record

    func testFingerprintHashesTheSplitterAndAChangedMapOrBassSettingMakesTheRecordStale() {
        let a = classA()
        var b = bass()
        let first = AncBassPathState.resolve(arrangement: a, bassManagement: b)
        XCTAssertEqual(first.path, .subOutput)
        b.frequencyHz = 100
        let second = AncBassPathState.resolve(arrangement: a, bassManagement: b)
        XCTAssertNotEqual(first.fingerprint, second.fingerprint, "a bass setting change")
        guard case .stale = second.freshness(of: first.fingerprint) else { return XCTFail("stale after a bass change") }
        var moved = a
        moved.subOutputs = [PhysicalOutputEndpoint(deviceUID: "out", channelIndex: 5)]
        XCTAssertNotEqual(first.fingerprint, AncBassPathState.resolve(arrangement: moved, bassManagement: bass()).fingerprint,
                          "a changed output map")
    }

    func testRecordSchemaTwoRoundTripsAndSchemaOneStillDecodes() throws {
        let fp = AncBassPathFingerprint(value: "x")
        let record = CombinedAncPathRecord(
            source: .outputLeakage, destination: .referenceMicrophone, windowSeconds: 1, sampleRate: 48_000,
            fingerprint: fp, impulseResponse: [0, 0.5], outputChannel: 2, outputRole: .sub)
        XCTAssertEqual(record.schemaVersion, 2)
        XCTAssertTrue(record.isValid)
        let decoded = try JSONDecoder().decode(CombinedAncPathRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        // A leakage record without its output is not valid.
        var bad = record
        bad.outputRole = nil
        XCTAssertFalse(bad.isValid)
        // A schema 1 record (no output fields) still decodes.
        let v1 = CombinedAncPathRecord(
            source: .feedLeft, destination: .seatMicrophone, windowSeconds: 1, sampleRate: 48_000, fingerprint: fp,
            impulseResponse: [1])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(v1)) as? [String: Any])
        object["schemaVersion"] = 1
        object.removeValue(forKey: "outputChannel")
        object.removeValue(forKey: "outputRole")
        let old = try JSONDecoder().decode(
            CombinedAncPathRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.schemaVersion, 1)
        XCTAssertNil(old.outputChannel)
    }

    // MARK: plans

    func testSeatPassesAndLeakageSignalsAtEveryRate() throws {
        let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
        for rate in rates {
            let p = try program(rate: rate)
            let passes = try SubPathMeasurement.seatPasses(program: p, bass: bass(), map: map, outputChannelCount: 3)
            XCTAssertEqual(passes.map(\.feed), [.left, .right], "\(rate)")
            XCTAssertEqual(passes[0].plan.primary.outputChannel, 0, "\(rate)")
            XCTAssertEqual(passes[1].plan.primary.outputChannel, 1, "\(rate)")
            for pass in passes {
                XCTAssertEqual(pass.plan.lanes.map(\.outputChannel), [2], "the sub plays beside the main (\(rate))")
                // Lanes start with the primary, after the lead-in, to within one frame.
                let lanes = pass.plan.laneProgramsForTransport(leadInFrames: p.leadInFrames)
                XCTAssertEqual(lanes.map(\.startFrame), [p.leadInFrames], "\(rate)")
                XCTAssertEqual(pass.plan.primary.samples.count, p.sweepSamples.count, "\(rate)")
            }
            let signals = try SubPathMeasurement.leakageSignals(passes: passes)
            XCTAssertEqual(signals.map(\.role), [.leftMain, .rightMain, .sub], "\(rate)")
            XCTAssertEqual(signals.map(\.outputChannel), [0, 1, 2], "\(rate)")
            XCTAssertEqual(SubPathMeasurement.leakagePassCount, 9)
        }
    }

    // MARK: offline composition and the echo model

    private func pulse(_ at: Int, _ gain: Float, count: Int) -> [Float] {
        var v = [Float](repeating: 0, count: count)
        v[at] = gain
        return v
    }

    func testComposedLeakageMatchesTheDirectFeedLeakageAtEveryRate() throws {
        for rate in rates {
            let n = Int(rate * 0.2)
            let delay = Int(rate * 0.004)
            let main = (0..<3).map { r in pulse(delay, 0.05 + Float(r) * 0.0005, count: n) }
            let rightMain = (0..<3).map { r in pulse(delay + 2, 0.04 + Float(r) * 0.0005, count: n) }
            let sub = (0..<3).map { r in pulse(delay + 4, 0.08 - Float(r) * 0.0005, count: n) }
            let composed = SubPathMeasurement.composeFeeds(leftMain: main, rightMain: rightMain, sub: sub)
            // A direct twin of the left feed: the same two pulses measured as one.
            let direct = (0..<3).map { r -> [Float] in
                var v = [Float](repeating: 0, count: n)
                v[delay] += main[r][delay]
                v[delay + 4] += sub[r][delay + 4]
                return v
            }
            XCTAssertEqual(composed.left, direct, "\(rate)")
            let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
            let model = try SubPathMeasurement.echoModel(
                leftMain: main, rightMain: rightMain, sub: sub, map: map, nativeSampleRate: rate, capturedAt: Date())
            let reference = try FeedForwardEchoModelBuilder.build(
                left: direct, right: composed.right, nativeSampleRate: rate, capturedAt: Date())
            let dB = 20 * log10(max(model.left.l1, 1e-9) / max(reference.left.l1, 1e-9))
            XCTAssertEqual(dB, 0, accuracy: 0.5, "\(rate)")
            XCTAssertEqual(model.outputs?.map(\.role), ["leftMain", "rightMain", "sub"], "\(rate)")
            XCTAssertEqual(model.outputs?.map(\.outputChannel), [0, 1, 2], "\(rate)")
            XCTAssertEqual(model.outputs?[2].feeds, [0, 1])
        }
    }

    func testStabilityBoundRefusesWhenOnlyTheSubCouplesStrongly() {
        func path(_ gain: Float) -> FeedForwardEchoPath {
            FeedForwardEchoPath(bulkDelay: 0, taps: [gain], bound: [0])
        }
        var model = FeedForwardEchoModel(
            sampleRate: 1_000, nativeSampleRate: 48_000, repeats: 3, left: path(0.01), right: path(0.01),
            coherence: 0.99, repeatDeviation: 0, capturedAt: Date())
        let weights: [Float] = [0.5]
        // Without the per-output paths the composed sum passes.
        XCTAssertFalse(FeedForwardLeakageStabilityCheck.evaluate(
            model: model, weightsLeft: weights, weightsRight: weights).wouldBeRefused)
        model.outputs = [
            FeedForwardOutputEcho(role: "leftMain", outputChannel: 0, feeds: [0], path: path(0.01)),
            FeedForwardOutputEcho(role: "rightMain", outputChannel: 1, feeds: [1], path: path(0.01)),
            FeedForwardOutputEcho(role: "sub", outputChannel: 2, feeds: [0, 1], path: path(1.0)),
        ]
        XCTAssertTrue(FeedForwardLeakageStabilityCheck.evaluate(
            model: model, weightsLeft: weights, weightsRight: weights).wouldBeRefused,
            "the sub's own coupling counts against both feeds")
    }

    func testRecordsCarryTheSeatPathsAndOnePerOutputLeakage() {
        let fp = AncBassPathFingerprint(value: "f")
        let map = SubActuatorOutputMap(leftOutput: 0, rightOutput: 1, subOutput: 2)
        let ir: [Float] = [0, 0.2, 0.1]
        let all = SubPathMeasurement.records(
            seatLeft: ir, seatRight: ir, leftMain: [ir, ir], rightMain: [ir, ir], sub: [ir, ir], map: map,
            sampleRate: 48_000, fingerprint: fp)
        XCTAssertEqual(all.map(\.source), [.feedLeft, .feedRight, .outputLeakage, .outputLeakage, .outputLeakage])
        XCTAssertEqual(all.compactMap(\.outputRole), [.leftMain, .rightMain, .sub])
        let seatOnly = SubPathMeasurement.records(
            seatLeft: ir, seatRight: ir, leftMain: [], rightMain: [], sub: [], map: map, sampleRate: 48_000,
            fingerprint: fp)
        XCTAssertEqual(seatOnly.count, 2)
    }
}
