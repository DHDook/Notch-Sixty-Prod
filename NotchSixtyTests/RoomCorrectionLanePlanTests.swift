import XCTest
@testable import NotchSixty

/// E10 S4: rate-independent designs synthesised per rate and published as one ROOM_FIR stage per
/// distinct tap set on any layout. Behavioural: real synthesis, real graphs, every standard rate.
final class RoomCorrectionLanePlanTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func grid(_ shape: (Double) -> Double) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map(shape),
            correctionPhaseRadians: [Double](repeating: 0, count: frequencies.count),
            coherence: [Double](repeating: 0, count: frequencies.count), seatContribution: [])
    }

    /// A smooth two-feature correction: a 3 dB cut near 120 Hz and a 2 dB lift near 3 kHz.
    private func smooth(_ f: Double) -> Double {
        let a = log2(f / 120), b = log2(f / 3_000)
        return -3 * exp(-a * a / 0.8) + 2 * exp(-b * b / 1.5)
    }

    private func response(_ taps: [Float], _ frequency: Double, _ rate: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * frequency / rate
        for (n, tap) in taps.enumerated() {
            re += Double(tap) * cos(w * Double(n))
            im -= Double(tap) * sin(w * Double(n))
        }
        return 20 * log10(max(hypot(re, im), 1e-12))
    }

    private func design(mode: RoomCorrectionLatencyMode, laneGrids: [Int: RoomCorrectionGridDesign], laneCount: Int)
        -> RoomCorrectionMultiLaneDesign {
        RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: laneCount,
            lanes: laneGrids.keys.sorted().map { RoomCorrectionLaneDesign(lane: $0, grid: laneGrids[$0]!) })
    }

    func testOneDesignAgreesAcrossAllEightRatesOnTheCommonBand() throws {
        let g = try grid(smooth)
        let multi = design(mode: .video, laneGrids: [0: g], laneCount: 2)
        let cache = RoomCorrectionRateCache()
        let probes: [Double] = [60, 90, 120, 200, 400, 800, 1_500, 3_000, 5_000, 8_000, 12_000]
        for rate in Self.rates {
            let plan = try cache.plan(for: multi, sampleRate: rate)
            XCTAssertEqual(plan.sampleRate, rate)
            let taps = try XCTUnwrap(plan.stages.first).taps
            for f in probes {
                XCTAssertEqual(response(taps, f, rate), smooth(f), accuracy: 0.1, "\(f) Hz at \(rate)")
            }
        }
    }

    func testMixedPhaseDesignAgreesAtRatesThatFitASingleBand() throws {
        let g = try grid(smooth)
        let multi = design(mode: .music20ms, laneGrids: [0: g], laneCount: 2)
        let cache = RoomCorrectionRateCache()
        for rate in [44_100.0, 48_000, 88_200, 96_000] {
            let plan = try cache.plan(for: multi, sampleRate: rate)
            XCTAssertEqual(Int(plan.declaredLatencyFrames), Int((0.02 * rate).rounded()), "latency at \(rate)")
            let taps = try XCTUnwrap(plan.stages.first).taps
            for f in [120.0, 400, 3_000, 8_000] {
                XCTAssertEqual(response(taps, f, rate), smooth(f), accuracy: 0.1, "\(f) Hz at \(rate)")
            }
        }
    }

    /// E10 S8: a budget longer than the single-band stage holds is carried by the two-band stage and still lands on the
    /// design at every rate.
    func testLongBudgetBeyondASingleBandUsesTheTwoBandStage() throws {
        let g = try grid(smooth)
        let multi = design(mode: .music100ms, laneGrids: [0: g], laneCount: 2)
        let cache = RoomCorrectionRateCache()
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            let plan = try cache.plan(for: multi, sampleRate: rate)
            let stage = try XCTUnwrap(plan.stages.first)
            XCTAssertEqual(Int(plan.declaredLatencyFrames), Int((0.1 * rate).rounded()), "latency at \(rate)")
            XCTAssertLessThanOrEqual(stage.taps.count, RoomCorrectionRateCache.maximumSingleBandTaps)
            XCTAssertEqual(
                stage.twoBand != nil, Int(n60_correct_latency_mode_tap_count(RoomCorrectionLatencyMode.music100ms.rawValue, rate)) > 32_768)
            let probes = [120.0, 400, 3_000, 8_000]
            let result = try RoomCorrectionCore.filterResponse(
                sampleRate: rate, taps: stage.taps, twoBand: stage.twoBand,
                declaredLatencyFrames: plan.declaredLatencyFrames, frequencies: probes)
            for (index, f) in probes.enumerated() {
                XCTAssertEqual(result.magnitudeDB[index], smooth(f), accuracy: 0.1, "\(f) Hz at \(rate)")
            }
            if let part = stage.twoBand {
                XCTAssertTrue([11_025.0, 12_000.0].contains(rate / Double(part.decimation)), "low rate at \(rate)")
                XCTAssertEqual(stage.graphKind, N60_STAGE_ROOM_FIR_TWO_BAND)
                XCTAssertEqual(stage.graphParams.count, 4 + stage.taps.count + part.lowTaps.count)
            }
        }
        let high = try cache.plan(for: multi, sampleRate: 384_000)
        XCTAssertNotNil(high.stages.first?.twoBand)
    }

    func testLegacyKernelRefusesWithAReason() throws {
        let multi = design(mode: .video, laneGrids: [0: try grid(smooth), 1: try grid(smooth)], laneCount: 2)
        XCTAssertThrowsError(try RoomCorrectionRateCache().plan(for: multi, sampleRate: 48_000, unifiedGraphEnabled: false)) {
            XCTAssertEqual($0 as? RoomCorrectionLanePlanError, .legacyKernel)
            XCTAssertTrue((($0 as? LocalizedError)?.errorDescription ?? "").contains("legacy kernel"))
        }
    }

    func testLaneValidation() throws {
        let g = try grid(smooth)
        let cache = RoomCorrectionRateCache()
        XCTAssertThrowsError(try cache.plan(for: design(mode: .video, laneGrids: [:], laneCount: 2), sampleRate: 48_000)) {
            XCTAssertEqual($0 as? RoomCorrectionLanePlanError, .noLanes)
        }
        XCTAssertThrowsError(try cache.plan(for: design(mode: .video, laneGrids: [5: g], laneCount: 2), sampleRate: 48_000)) {
            XCTAssertEqual($0 as? RoomCorrectionLanePlanError, .laneOutOfRange(5))
        }
        let dup = RoomCorrectionMultiLaneDesign(
            latencyMode: .video, laneCount: 2,
            lanes: [RoomCorrectionLaneDesign(lane: 1, grid: g), RoomCorrectionLaneDesign(lane: 1, grid: g)])
        XCTAssertThrowsError(try cache.plan(for: dup, sampleRate: 48_000)) {
            XCTAssertEqual($0 as? RoomCorrectionLanePlanError, .duplicateLane(1))
        }
    }

    func testCacheSynthesisesOncePerRateAndInvalidates() async throws {
        let g = try grid(smooth)
        let multi = design(mode: .video, laneGrids: [0: g, 1: g], laneCount: 2)
        let cache = RoomCorrectionRateCache()
        let first = try await cache.planAsync(for: multi, sampleRate: 48_000)
        let again = try cache.plan(for: multi, sampleRate: 48_000)
        XCTAssertEqual(first, again)
        XCTAssertEqual(cache.synthesisCount, 1, "two lanes with one grid share one synthesis")
        _ = try cache.plan(for: multi, sampleRate: 96_000)
        XCTAssertEqual(cache.synthesisCount, 2)
        cache.invalidate(designID: multi.id)
        _ = try cache.plan(for: multi, sampleRate: 48_000)
        XCTAssertEqual(cache.synthesisCount, 3)
    }

    // MARK: - Graph publishing

    private func shape(_ layout: OutputProgramLayout) throws -> UnifiedGraphLayoutShape {
        try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
    }

    private func spec(rate: Double, layout: OutputProgramLayout, plan: RoomCorrectionLanePlan?) throws -> UnifiedGraphSpec {
        var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.stereoStages = UnifiedGraphStereoStages()
        var dsp = UnifiedGraphProgramDSP(stereo: base, shape: try shape(layout), eqMode: .linked)
        dsp.roomLanes = plan
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return try configuration.makeSpec()
    }

    private func impulseResponse(_ spec: UnifiedGraphSpec, lane: Int, frames: Int) throws -> [Float] {
        let host = try UnifiedGraphHost(spec: spec)
        let channels = Int(spec.outputChannels)
        var out: [Float] = []
        var position = 0
        while position < frames {
            var input = [[Float]](repeating: [Float](repeating: 0, count: block), count: channels)
            if position == 0 { input[lane][0] = 1 }
            out += try host.processOffline(input: input, frames: block)[lane]
            position += block
        }
        return out
    }

    private func peakIndex(_ x: [Float]) -> Int {
        var best = 0
        for index in x.indices where abs(x[index]) > abs(x[best]) { best = index }
        return best
    }

    func testFiveOnePublishesOneStagePerDistinctTapSetWithTheRightMasks() throws {
        let layout = OutputProgramLayout.fiveOne
        let s = try shape(layout)
        let fl = try XCTUnwrap(s.frontLeft), fr = try XCTUnwrap(s.frontRight), lfe = try XCTUnwrap(s.lfeLane)
        let others = (0..<6).filter { ![fl, fr, lfe].contains($0) }
        let a = try grid(smooth), b = try grid { 2 * self.smooth($0) }, c = try grid { _ in 0 }, d = try grid { _ in -1 }
        var lanes: [Int: RoomCorrectionGridDesign] = [fl: a, fr: b, lfe: d]
        for lane in others { lanes[lane] = c }
        let multi = design(mode: .video, laneGrids: lanes, laneCount: 6)
        let plan = try RoomCorrectionRateCache().plan(for: multi, sampleRate: 48_000)
        XCTAssertEqual(plan.stages.count, 4)
        func bit(_ lane: Int) -> UInt64 { UInt64(1) << UInt64(lane) }
        let expected = Set([bit(fl), bit(fr), bit(lfe), others.reduce(0) { $0 | bit($1) }])
        XCTAssertEqual(Set(plan.stages.map(\.laneMask)), expected)
        XCTAssertEqual(plan.coveredMask, (1 << 6) - 1)
        let built = try spec(rate: 48_000, layout: layout, plan: plan)
        let roomStages = built.stages.filter { $0.kind == N60_STAGE_ROOM_FIR.rawValue }
        XCTAssertEqual(roomStages.count, 4)
        XCTAssertEqual(Set(roomStages.map(\.laneMask)), expected)
        XCTAssertEqual(Set(roomStages.map(\.stageId)).count, 4)
    }

    func testPartialCoverageAlignsEveryOtherLaneIncludingTheSubLane() throws {
        for rate in [48_000.0, 96_000.0] {
            let layout = OutputProgramLayout.fiveOne
            let s = try shape(layout)
            let fl = try XCTUnwrap(s.frontLeft), fr = try XCTUnwrap(s.frontRight), lfe = try XCTUnwrap(s.lfeLane)
            // Flat music-mode correction on the front pair only: the taps are a pure delay of the budget.
            let multi = design(mode: .music20ms, laneGrids: [fl: try grid { _ in 0 }, fr: try grid { _ in 0 }], laneCount: 6)
            let plan = try RoomCorrectionRateCache().plan(for: multi, sampleRate: rate)
            let built = try spec(rate: rate, layout: layout, plan: plan)
            let expected = 256 + Int(plan.declaredLatencyFrames)
            let host = try UnifiedGraphHost(spec: built)
            XCTAssertEqual(Int(host.latencyFrames), expected, "reported latency at \(rate)")
            for lane in [fl, fr, lfe] {
                let out = try impulseResponse(built, lane: lane, frames: expected + 1_024)
                XCTAssertEqual(peakIndex(out), expected, "lane \(lane) at \(rate)")
            }
        }
    }

    func testRateChangeRepublishesWithoutAMismatch() throws {
        let layout = OutputProgramLayout.fiveOne
        let all = try grid(smooth)
        let multi = design(mode: .video, laneGrids: Dictionary(uniqueKeysWithValues: (0..<6).map { ($0, all) }), laneCount: 6)
        let cache = RoomCorrectionRateCache()
        for rate in [48_000.0, 384_000, 48_000, 192_000] {
            let plan = try cache.plan(for: multi, sampleRate: rate)
            XCTAssertEqual(plan.stages.count, 1)
            let built = try spec(rate: rate, layout: layout, plan: plan)
            XCTAssertEqual(built.sampleRate, rate)
            _ = try UnifiedGraphHost(spec: built)
        }
        XCTAssertEqual(cache.synthesisCount, 3, "48 kHz is served from the cache the second time")
    }

    func testPlanAndStereoStageAreMutuallyExclusiveAndNeutralStaysNeutral() throws {
        let layout = OutputProgramLayout.fiveOne
        let multi = design(mode: .video, laneGrids: [0: try grid(smooth)], laneCount: 6)
        let plan = try RoomCorrectionRateCache().plan(for: multi, sampleRate: 48_000)
        var base = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        var stages = UnifiedGraphStereoStages()
        stages.roomFIR = UnifiedGraphFIRProgram(generation: 1, left: [1], right: nil, declaredLatencyFrames: 0)
        base.stereoStages = stages
        var dsp = UnifiedGraphProgramDSP(stereo: base, shape: try shape(layout), eqMode: .linked)
        dsp.roomLanes = plan
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(sampleRate: 48_000, programChannels: 6, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        XCTAssertThrowsError(try configuration.makeSpec())

        // Flag off / no plan: the spec is exactly the program-less spec.
        XCTAssertEqual(try spec(rate: 48_000, layout: layout, plan: nil).stages, try {
            var plain = UnifiedGraphTranslator.multichannelConfiguration(sampleRate: 48_000, programChannels: 6, subwoofers: [])
            plain.orderPolicy = .canonical
            return try plain.makeSpec().stages
        }())
    }
}
