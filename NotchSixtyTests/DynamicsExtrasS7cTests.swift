import XCTest
@testable import NotchSixty

/// E28 S7c: multiband extras (config, kernel mapping), band listen and solo session state, and their posting through the host.
final class MultibandExtrasConfigTests: XCTestCase {
    func testDefaultsDecodeAndGiveTheSeventeenExtras() throws {
        let m = MultibandCompressorConfiguration()
        let lookahead = Float(CompressorConfiguration.lookaheadFrames(ms: 0, sampleRate: 48_000))
        XCTAssertEqual(m.coreExtras(sampleRate: 48_000), [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 50, lookahead])
        XCTAssertEqual(m.coreExtras(sampleRate: 48_000).count, 17)
        let back = try JSONDecoder().decode(MultibandCompressorConfiguration.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        // A profile written before S7c has none of the extra keys.
        let old = try JSONEncoder().encode(m)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        for key in ["autoReleaseBands", "bypassedBands", "rmsDetectorBands", "rmsWindowMs", "lookaheadMs"] { object[key] = nil }
        let decoded = try JSONDecoder().decode(MultibandCompressorConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.bypassedBands)
        XCTAssertEqual(decoded.coreExtras(sampleRate: 48_000), m.coreExtras(sampleRate: 48_000))
    }

    func testExtrasPackInOrderAndValidate() throws {
        var m = MultibandCompressorConfiguration()
        m.autoReleaseBands = [0]; m.bypassedBands = [1]; m.rmsDetectorBands = [2]; m.rmsWindowMs = 80; m.lookaheadMs = 5
        let extras = m.coreExtras(sampleRate: 48_000)
        XCTAssertEqual(Array(extras[0..<3]), [1, 0, 0], "auto release")
        XCTAssertEqual(Array(extras[3..<6]), [0, 1, 0], "bypass")
        XCTAssertEqual(Array(extras[6..<12]), [0, 0, 0, 0, 0, 0], "solo and listen are session state")
        XCTAssertEqual(Array(extras[12..<15]), [0, 0, 1], "detector")
        XCTAssertEqual(extras[15], 80)
        XCTAssertEqual(extras[16], Float(CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: 48_000)))
        XCTAssertNoThrow(try m.validate())
        m.bypassedBands = [3]
        XCTAssertThrowsError(try m.validate())
        m.bypassedBands = nil; m.rmsWindowMs = 4
        XCTAssertThrowsError(try m.validate())
        m.rmsWindowMs = nil; m.lookaheadMs = 21
        XCTAssertThrowsError(try m.validate())
    }

    func testKernelMappingPassesABypassedBandAtUnity() {
        var m = MultibandCompressorConfiguration()
        m.lowRatio = 8; m.lowMakeupGainDB = 6; m.midRatio = 4; m.midMakeupGainDB = 3
        m.bypassedBands = [0]
        let k = m.kernelMapped()
        XCTAssertEqual(k.lowRatio, 1)
        XCTAssertEqual(k.lowMakeupGainDB, 0)
        XCTAssertEqual(k.midRatio, 4)
        XCTAssertEqual(k.midMakeupGainDB, 3)
    }
}

final class MultibandSessionTests: XCTestCase {
    func testBandListenersShareOneStageAndReplaceEachOther() {
        let s = DynamicsListenSession()
        XCTAssertEqual(DynamicsListenStage.multibandLow.stageId, DynamicsListenStage.multibandHigh.stageId)
        XCTAssertEqual([DynamicsListenStage.multibandLow, .multibandMid, .multibandHigh].map(\.paramIndex), [35, 36, 37])
        XCTAssertTrue(s.request(DynamicsListener(stage: .multibandMid, mode: .delta)))
        XCTAssertEqual(s.parameterValue(for: .multibandMid), 2)
        XCTAssertTrue(s.request(DynamicsListener(stage: .multibandHigh, mode: .sidechain)))
        XCTAssertEqual(s.parameterValue(for: .multibandMid), 0)
        XCTAssertEqual(s.parameterValue(for: .multibandHigh), 1)
        XCTAssertEqual(s.parameterValue(for: .compressor), 0)
    }

    func testSoloIsSessionStateAndClearCancelsBoth() {
        let s = DynamicsListenSession()
        XCTAssertTrue(s.setSolo([1, 7]))
        XCTAssertEqual(s.soloBands, [1], "out-of-range bands are dropped")
        XCTAssertFalse(s.setSolo([1]))
        s.request(DynamicsListener(stage: .multibandLow, mode: .sidechain))
        XCTAssertTrue(s.clear())
        XCTAssertTrue(s.soloBands.isEmpty)
        XCTAssertNil(s.listener)
        XCTAssertFalse(s.clear())
    }
}

final class MultibandHostTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func spec(rate: Double) -> UnifiedGraphSpec {
        var m = MultibandCompressorConfiguration()
        m.enabled = true
        // 29 base values (on, two crossovers, two slopes, thresholds, ratios, attacks, releases, knees, filters, make-ups, three
        // zeros) then the 17 extras: a 43-value block.
        var params: [Float] = [1, 120, 2_500, 0, 0]
        params += [-60, -60, -60, 1, 1, 1, 10, 10, 10, 100, 100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        params += Array(m.coreExtras(sampleRate: rate)[3...])
        params.replaceSubrange(26..<29, with: m.coreExtras(sampleRate: rate)[0..<3])
        return UnifiedGraphSpec(
            sampleRate: rate, maxBlockFrames: 1_024, inputChannels: 2, outputChannels: 2,
            stages: [UnifiedGraphStageSpec(kind: N60_STAGE_MULTIBAND.rawValue, stageId: UnifiedGraphConfiguration.multibandStageId,
                                           laneA: 0, laneB: 1, laneMask: 0, capacityFrames: 0, params: params)])
    }

    func testSoloAndListenPostAndSurviveARebuild() throws {
        let rate = 48_000.0
        var s = spec(rate: rate)
        XCTAssertEqual(s.stages[0].params.count, 43)
        let host = try UnifiedGraphHost(spec: s)
        try host.setListener(DynamicsListener(stage: .multibandLow, mode: .sidechain))
        try host.setSoloBands([0, 2])
        XCTAssertEqual(host.listenSession.listener?.stage, .multibandLow)
        XCTAssertEqual(host.listenSession.soloBands, [0, 2])
        // Moving the listener between bands is a post of two records of the same stage id.
        XCTAssertEqual(try host.setListener(DynamicsListener(stage: .multibandHigh, mode: .delta)), .posted(count: 2))
        // A rebuild (lookahead frames change the topology) posts the session state again.
        s.stages[0].params[42] = 64
        XCTAssertEqual(try host.apply(s), .published)
        XCTAssertEqual(host.listenSession.soloBands, [0, 2])
        host.clearListener()
        XCTAssertTrue(host.listenSession.soloBands.isEmpty)
        XCTAssertNil(host.listenSession.listener)
        host.release()
    }

    func testSoloAndListenAreRefusedOnTheShortBlockAtEveryRate() throws {
        for rate in rates {
            var s = spec(rate: rate)
            s.stages[0].params = Array(s.stages[0].params.prefix(29))
            let host = try UnifiedGraphHost(spec: s)
            XCTAssertThrowsError(try host.setSoloBands([1]))
            XCTAssertThrowsError(try host.setListener(DynamicsListener(stage: .multibandMid, mode: .sidechain)))
            XCTAssertTrue(host.listenSession.soloBands.isEmpty)
            XCTAssertNil(host.listenSession.listener)
            XCTAssertNoThrow(try host.setSoloBands([]), "clearing is always allowed")
            host.release()
        }
    }
}
