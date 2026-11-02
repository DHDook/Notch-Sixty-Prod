import XCTest
@testable import NotchSixty

/// E10 S7: the joint bass optimiser's result deployed through the snapshot path. Real optimiser, real synthesis, every
/// standard rate.
final class RoomCorrectionBassApplyTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    /// 2 mains and 2 subs at 4 seats: delayed direct sounds plus separable modal rings.
    private func bassRoom(rate: Double) -> [[RoomCorrectionCore.SeatImpulseResponse]] {
        let frames = Int(rate * 0.5)
        let modes: [Double] = [31, 44, 58, 73, 96, 112]
        let sourceDelay: [Double] = [0, 0.0004, 0.0031, 0.0046]
        let tau = 0.12 / log(1000.0)
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / 4_503_599_627_370_496.0 - 1.0
        }
        let seatGain = (0..<4).map { _ in modes.map { _ in next() } }
        let sourceGain = (0..<4).map { _ in modes.map { _ in 0.35 + 0.65 * next() } }
        return (0..<4).map { source in
            (0..<4).map { seat in
                var ir = [Float](repeating: 0, count: frames)
                let arrival = (sourceDelay[source] + 0.0035 * Double(seat) / 10 + 0.004) * rate
                ir[Int(arrival.rounded())] = 0.1
                for (index, mode) in modes.enumerated() {
                    let amplitude = 0.012 * (48_000 / rate) * seatGain[seat][index] * sourceGain[source][index]
                    var i = Int(arrival) + 1
                    while i < frames {
                        let t = (Double(i) - arrival) / rate
                        if t > 6 * tau { break }
                        ir[i] += Float(amplitude * exp(-t / tau) * sin(2 * .pi * mode * t))
                        i += 1
                    }
                }
                return .init(samples: ir, arrivalFrames: arrival, weight: 1)
            }
        }
    }

    private let specs: [BassChannelSpec] = [.defaults(.main), .defaults(.main), .defaults(.sub), .defaults(.sub)]
    /// 5.1 lanes: the front pair and two further lanes standing in for the sub lanes.
    private let lanes = [0, 1, 4, 5]

    private func optimise() throws -> BassOptimisation {
        try RoomCorrectionCore.optimiseBass(
            irs: bassRoom(rate: 48_000), channels: specs, sampleRate: 48_000,
            settings: BassOptimiserSettings(timingTier: .acoustic))
    }

    private func emptyProgram() -> UnifiedGraphProgramDSP {
        var base = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.stereoStages = UnifiedGraphStereoStages()
        return UnifiedGraphProgramDSP(
            stereo: base, shape: UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles)!, eqMode: .linked)
    }

    func testFlagOffChangesNothing() throws {
        let result = try RoomCorrectionBassApply.plan(
            optimisation: optimise(), channels: specs, lanes: lanes, laneCount: 6, latencyMode: .music20ms, enabled: false)
        XCTAssertNil(result)
    }

    func testPlanPublishesTheOptimisersDelayGainPolarityAndHeadroom() throws {
        let optimisation = try optimise()
        let plan = try XCTUnwrap(RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: lanes, laneCount: 6, latencyMode: .music20ms, enabled: true))
        let report = optimisation.report
        XCTAssertEqual(plan.mainLanes, [0, 1])
        XCTAssertEqual(plan.subLanes, [4, 5])
        XCTAssertEqual(plan.subGainDB, [report.channels[2].gainDB, report.channels[3].gainDB])
        XCTAssertEqual(plan.subPolarityInverted, [report.channels[2].polarityInverted, report.channels[3].polarityInverted])
        XCTAssertEqual(plan.subDelaySeconds, [report.channels[2].delaySeconds, report.channels[3].delaySeconds])
        XCTAssertEqual(plan.headroomDB, max(0, report.headroomDB))
        for (index, item) in plan.design.lanes.enumerated() {
            XCTAssertEqual(item.lane, lanes[index])
            for (applied, original) in zip(item.grid.correctionDB, optimisation.designs[index].correctionDB) {
                XCTAssertEqual(applied, original - plan.headroomDB, accuracy: 1e-12)
            }
        }
        XCTAssertTrue(plan.subGainDB.allSatisfy { (-60.0...24.0).contains($0) })
    }

    func testPublishedFiltersMatchThePredictionOnEverySynthesisedRate() throws {
        let optimisation = try optimise()
        // 100 ms resolves the bass filter at every rate: the single-band stage holds it up to 192 kHz and the two-band
        // stage (E10 S8) above that.
        for rate in Self.rates {
            try checkPrediction(optimisation, rate: rate, mode: .music100ms, exact: true)
        }
    }

    private func checkPrediction(_ optimisation: BassOptimisation, rate: Double, mode: RoomCorrectionLatencyMode, exact: Bool) throws {
        let plan = try XCTUnwrap(RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: lanes, laneCount: 6, latencyMode: mode, enabled: true))
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        let probes = frequencies.enumerated().filter { $0.element >= 25 && $0.element <= 110 }.map(\.offset)
            .enumerated().filter { $0.offset % 6 == 0 }.map(\.element)
        XCTAssertFalse(probes.isEmpty)
        let cache = RoomCorrectionRateCache()
        do {
            var program = emptyProgram()
            let lanePlan = try RoomCorrectionBassApply.install(plan, program: &program, sampleRate: rate, cache: cache)
            XCTAssertEqual(program.roomLanes, lanePlan)
            XCTAssertEqual(program.laneDelayFrames, plan.mainDelayFrames(sampleRate: rate))
            XCTAssertEqual(lanePlan.sampleRate, rate)
            // Every channel lane is covered by exactly one stage.
            XCTAssertEqual(lanePlan.coveredMask, lanes.reduce(UInt64(0)) { $0 | (UInt64(1) << UInt64($1)) })
            for (index, lane) in lanes.enumerated() {
                let stage = try XCTUnwrap(lanePlan.stages.first { $0.laneMask & (UInt64(1) << UInt64(lane)) != 0 })
                XCTAssertTrue(stage.taps.allSatisfy { $0.isFinite })
                if exact {
                    // Synthesis tracks the prediction on average; the residual is the fine structure that the
                    // tap budget cannot hold (recorded in the E10 log).
                    let measured = try RoomCorrectionCore.filterResponse(
                        sampleRate: rate, taps: stage.taps, twoBand: stage.twoBand,
                        declaredLatencyFrames: lanePlan.declaredLatencyFrames, frequencies: probes.map { frequencies[$0] })
                    let errors = probes.enumerated().map {
                        measured.magnitudeDB[$0.offset] - plan.design.lanes[index].grid.correctionDB[$0.element]
                    }
                    let rms = (errors.map { $0 * $0 }.reduce(0, +) / Double(errors.count)).squareRoot()
                    XCTAssertLessThan(rms, 2.0, "lane \(lane) at \(rate)")
                }
            }
            // Sub delays stay within the graph limit (they are published through the profile, not the graph).
            let frames = plan.subDelayFrames(sampleRate: rate)
            XCTAssertTrue(frames.allSatisfy { $0 >= 0 && $0 <= Int(N60_GRAPH_MAX_DELAY_FRAMES) })
        }
    }

    func testRefusalsCarryReasons() throws {
        let optimisation = try optimise()
        XCTAssertThrowsError(try RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: [0, 1, 4, 4], laneCount: 6, latencyMode: .music20ms, enabled: true)) {
            XCTAssertEqual($0 as? RoomCorrectionBassApplyError, .duplicateLane(4))
        }
        XCTAssertThrowsError(try RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: [0, 1, 4, 9], laneCount: 6, latencyMode: .music20ms, enabled: true)) {
            XCTAssertEqual($0 as? RoomCorrectionBassApplyError, .laneOutOfRange(9))
        }
        XCTAssertThrowsError(try RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: [0, 1, 4], laneCount: 6, latencyMode: .music20ms, enabled: true)) {
            XCTAssertEqual($0 as? RoomCorrectionBassApplyError, .channelMismatch)
        }
        var tooLoud = optimisation
        tooLoud.report.channels[2].gainDB = 40
        XCTAssertThrowsError(try RoomCorrectionBassApply.plan(
            optimisation: tooLoud, channels: specs, lanes: lanes, laneCount: 6, latencyMode: .music20ms, enabled: true)) {
            XCTAssertEqual($0 as? RoomCorrectionBassApplyError, .subGainOutOfRange(40))
        }
        var absurd = try XCTUnwrap(RoomCorrectionBassApply.plan(
            optimisation: optimisation, channels: specs, lanes: lanes, laneCount: 6, latencyMode: .music20ms, enabled: true))
        absurd.subDelaySeconds[0] = 100
        var program = emptyProgram()
        XCTAssertThrowsError(try RoomCorrectionBassApply.install(
            absurd, program: &program, sampleRate: 384_000, cache: RoomCorrectionRateCache())) {
            guard case .delayTooLong = $0 as? RoomCorrectionBassApplyError else { return XCTFail("\($0)") }
        }
        XCTAssertNil(program.roomLanes)
    }
}
