import XCTest
@testable import NotchSixty

/// E28 S7b: expander extras (config, knee curve), dynamics listen session and its posting through the host.
final class ExpanderExtrasConfigTests: XCTestCase {
    func testDefaultsDecodeAndGiveTheSevenExtras() throws {
        let e = ExpanderConfiguration()
        XCTAssertEqual(e.coreExtras(), [0, 0, 0, 50, 0, 100, 0])
        let back = try JSONDecoder().decode(ExpanderConfiguration.self, from: JSONEncoder().encode(e))
        XCTAssertEqual(back, e)
        // A profile written before S7b has none of the extra keys.
        let old = #"{"enabled":true,"thresholdDB":-40,"ratio":2,"rangeDB":-20,"attackMs":5,"releaseMs":100}"#
        let decoded = try JSONDecoder().decode(ExpanderConfiguration.self, from: Data(old.utf8))
        XCTAssertNil(decoded.holdMs)
        XCTAssertEqual(decoded.coreExtras(), [0, 0, 0, 50, 0, 100, 0])
    }

    func testExtrasClampAndValidate() throws {
        var e = ExpanderConfiguration()
        e.holdMs = 50; e.kneeDB = 6; e.rmsDetector = true; e.rmsWindowMs = 80; e.sidechainHighPassHz = 80; e.linkPercent = 30
        XCTAssertEqual(e.coreExtras(), [50, 6, 1, 80, 80, 30, 0])
        XCTAssertNoThrow(try e.validate())
        e.holdMs = 501
        XCTAssertThrowsError(try e.validate())
        e.holdMs = 0; e.sidechainHighPassHz = 301
        XCTAssertThrowsError(try e.validate())
    }
}

final class ExpanderKneeCurveTests: XCTestCase {
    private func curve(knee: Double) -> DynamicsTransferCurve {
        DynamicsTransferCurve(kind: .expander, thresholdDB: -40, ratio: 3, kneeDB: knee, floorDB: -60)
    }

    func testKneeMatchesTheQuadraticAndIsContinuousWithItsSlope() {
        let c = curve(knee: 12)
        // Analytic: gain = -(ratio - 1)(over - K/2)^2 / (2K) inside the knee, (ratio - 1) * over below it.
        for over in stride(from: -5.9, through: 5.9, by: 0.5) {
            let expected = -2 * (over - 6) * (over - 6) / 24
            XCTAssertEqual(c.gainDB(atInput: -40 + over), expected, accuracy: 1e-9)
        }
        XCTAssertEqual(c.gainDB(atInput: -40 + 6), 0, accuracy: 1e-12)
        XCTAssertEqual(c.gainDB(atInput: -40 - 6), -12, accuracy: 1e-12)
        XCTAssertEqual(c.gainDB(atInput: -90), -60, accuracy: 1e-12, "floored at the range")
        func slope(_ x: Double) -> Double { (c.gainDB(atInput: x + 1e-4) - c.gainDB(atInput: x - 1e-4)) / 2e-4 }
        XCTAssertEqual(slope(-46 + 1e-3), slope(-46 - 1e-3), accuracy: 1e-2)
        XCTAssertEqual(slope(-34 + 1e-3), slope(-34 - 1e-3), accuracy: 1e-2)
    }

    func testKneeZeroIsTheHardLawAndTheDotInvertsOnBothBranches() {
        XCTAssertEqual(curve(knee: 0).gainDB(atInput: -45), -10, accuracy: 1e-12)
        let c = curve(knee: 12)
        for reduction in [0.5, 2.0, 11.0, 12.0, 20.0] {
            let input = try! XCTUnwrap(c.inputDB(forReductionDB: reduction))
            XCTAssertEqual(c.reductionDB(atInput: input), reduction, accuracy: 1e-9)
        }
        XCTAssertNil(c.inputDB(forReductionDB: 61))
    }
}

final class DynamicsListenSessionTests: XCTestCase {
    func testOneListenerAtATimeAndClear() {
        let s = DynamicsListenSession()
        XCTAssertNil(s.listener)
        XCTAssertTrue(s.request(DynamicsListener(stage: .compressor, mode: .sidechain)))
        XCTAssertFalse(s.request(DynamicsListener(stage: .compressor, mode: .sidechain)))
        XCTAssertEqual(s.parameterValue(for: .compressor), 1)
        XCTAssertEqual(s.parameterValue(for: .expander), 0)
        XCTAssertTrue(s.request(DynamicsListener(stage: .expander, mode: .delta)))
        XCTAssertEqual(s.parameterValue(for: .compressor), 0, "a second request replaces the first")
        XCTAssertEqual(s.parameterValue(for: .expander), 2)
        XCTAssertTrue(s.clear())
        XCTAssertNil(s.listener)
        XCTAssertFalse(s.clear())
    }

    func testListenerIsNotPartOfAnyEncodedProfile() throws {
        var config = DynamicsConfiguration()
        config.compressor.enabled = true
        let before = try JSONEncoder().encode(config)
        let session = DynamicsListenSession()
        session.request(DynamicsListener(stage: .compressor, mode: .delta))
        XCTAssertEqual(try JSONEncoder().encode(config), before)
        XCTAssertFalse(String(decoding: before, as: UTF8.self).lowercased().contains("listen"))
    }
}

final class DynamicsListenHostTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func spec(rate: Double, hostBlocks: UInt32 = 1_024) -> UnifiedGraphSpec {
        var comp = CompressorConfiguration()
        comp.thresholdDB = -20
        let expander = ExpanderConfiguration()
        let all = N60_LANE_ALL
        return UnifiedGraphSpec(
            sampleRate: rate, maxBlockFrames: hostBlocks, inputChannels: 2, outputChannels: 2,
            stages: [
                UnifiedGraphStageSpec(kind: N60_STAGE_COMPRESSOR.rawValue, stageId: UnifiedGraphConfiguration.compressorStageId,
                                      laneA: all, laneB: 0, laneMask: 0, capacityFrames: 0, params: [-20, 4, 0, 1, 20, 0, 0, 0, 0, 1] + comp.coreExtras(sampleRate: rate)),
                UnifiedGraphStageSpec(kind: N60_STAGE_EXPANDER.rawValue, stageId: UnifiedGraphConfiguration.expanderStageId,
                                      laneA: all, laneB: 0, laneMask: 0, capacityFrames: 0, params: [-120, 2, -12, 5, 100, 1] + expander.coreExtras()),
            ])
    }

    private func run(_ host: UnifiedGraphHost, _ input: [[Float]]) throws -> [[Float]] {
        var out: [[Float]] = [[], []]
        var at = 0
        while at < input[0].count {
            let n = min(1_024, input[0].count - at)
            let block = try host.processOffline(input: input.map { Array($0[at..<at + n]) }, frames: n)
            for c in 0..<2 { out[c] += block[c][0..<n] }
            at += n
        }
        return out
    }

    private func tone(_ rate: Double, frames: Int, amp: Float) -> [[Float]] {
        let one = (0..<frames).map { amp * Float(sin(0.3 + 2 * Double.pi * 1_000 * Double($0) / rate)) }
        return [one, one]
    }

    func testListenPostsLiveAndReplacesAndClears() throws {
        for rate in rates {
            let host = try UnifiedGraphHost(spec: spec(rate: rate))
            let frames = Int(rate * 0.1)
            let input = tone(rate, frames: frames, amp: 0.5)
            // Not listening: the loud tone is compressed.
            let normal = try run(host, input)
            XCTAssertLessThan(normal[0][(frames - 1000)...].map { abs($0) }.max() ?? 0, 0.4, "compressed at \(rate)")
            // Compressor sidechain listen: the detector input is the tone itself, no gain, no make-up.
            try host.setListener(DynamicsListener(stage: .compressor, mode: .sidechain))
            _ = try run(host, input)  // crossfade
            let listened = try run(host, input)
            let diffs = zip(listened[0], input[0]).map { abs($0 - $1) }
            let diff = diffs.max() ?? 1
            let at = diffs.firstIndex(of: diff) ?? -1
            XCTAssertLessThan(diff, 1e-4, "sidechain listen is the input at \(rate): max at \(at) of \(frames), listened \(listened[0][at]) input \(input[0][at])")
            // A second request replaces the first: only the expander slot is posted as listened.
            try host.setListener(DynamicsListener(stage: .expander, mode: .sidechain))
            XCTAssertEqual(host.listenSession.listener?.stage, .expander)
            // Clearing returns to the normal output.
            host.clearListener()
            XCTAssertNil(host.listenSession.listener)
            _ = try run(host, input)
            let back = try run(host, input)
            XCTAssertLessThan(back[0][(frames - 1000)...].map { abs($0) }.max() ?? 0, 0.4)
            host.release()
        }
    }

    func testListenSurvivesARebuildAndDiesWithTheHost() throws {
        let rate = 48_000.0
        let host = try UnifiedGraphHost(spec: spec(rate: rate))
        try host.setListener(DynamicsListener(stage: .compressor, mode: .delta))
        var changed = spec(rate: rate)
        changed.stages[1].params = Array(changed.stages[1].params.prefix(6))  // a different block size is a rebuild
        XCTAssertEqual(try host.apply(changed), .published)
        XCTAssertEqual(host.listenSession.listener, DynamicsListener(stage: .compressor, mode: .delta))
        host.release()
        XCTAssertNil(host.listenSession.listener, "release clears the listener")
    }

    func testListenRefusedWhenTheBlockHasNoListenSlot() throws {
        var s = spec(rate: 48_000)
        s.stages[0].params = Array(s.stages[0].params.prefix(10))
        let host = try UnifiedGraphHost(spec: s)
        XCTAssertThrowsError(try host.setListener(DynamicsListener(stage: .compressor, mode: .sidechain)))
        XCTAssertNil(host.listenSession.listener)
        host.release()
    }
}
