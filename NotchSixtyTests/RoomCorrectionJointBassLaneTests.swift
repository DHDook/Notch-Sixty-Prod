import XCTest
@testable import NotchSixty

/// E24 S3c: joint bass on the sub lanes. The composer, the graph with sub lanes (plain and routed) at every standard rate,
/// and the multi-path prediction. Real synthesis and real graphs.
final class RoomCorrectionJointBassLaneTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func grid(_ db: Double, phase: Double = 0, coherence: Double = 0) throws -> RoomCorrectionGridDesign {
        let frequencies = try RoomCorrectionCore.gridFrequencies()
        return RoomCorrectionGridDesign(
            correctionDB: frequencies.map { $0 < 500 ? db : 0 },
            correctionPhaseRadians: [Double](repeating: phase, count: frequencies.count),
            coherence: [Double](repeating: coherence, count: frequencies.count), seatContribution: [])
    }

    private func room(programLanes: Int = 2, subs: Int, mode: RoomCorrectionLatencyMode = .video, delay: Double = 0.001) throws
        -> RoomCorrectionLaneInstall {
        let g = try grid(-2)
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: programLanes + subs,
            lanes: (0..<2).map { RoomCorrectionLaneDesign(lane: $0, grid: g) })
        return RoomCorrectionLaneInstall(
            name: "Room", design: design, laneDelays: [RoomCorrectionLaneDelay(lane: 1, seconds: delay)],
            programLaneCount: programLanes, subwooferCount: subs)
    }

    private func bass(programLanes: Int = 2, subs: Int, mode: RoomCorrectionLatencyMode = .video) throws -> RoomCorrectionBassApplyPlan {
        let main = try grid(-1, phase: 0.1), sub = try grid(3, phase: -0.2)
        var lanes = [RoomCorrectionLaneDesign(lane: 0, grid: main), RoomCorrectionLaneDesign(lane: 1, grid: main)]
        for index in 0..<subs { lanes.append(RoomCorrectionLaneDesign(lane: programLanes + index, grid: sub)) }
        return RoomCorrectionBassApplyPlan(
            design: RoomCorrectionMultiLaneDesign(latencyMode: mode, laneCount: programLanes + subs, lanes: lanes),
            mainLanes: [0, 1], subLanes: (0..<subs).map { programLanes + $0 },
            subGainDB: [Double](repeating: 0, count: subs), subPolarityInverted: [Bool](repeating: false, count: subs),
            subDelaySeconds: [Double](repeating: 0, count: subs), mainDelaySeconds: [0, 0.002], headroomDB: 0)
    }

    // MARK: Composer

    func testComposerMultipliesSharedLanesAndKeepsSubLanesBassOnly() throws {
        let composed = try RoomCorrectionLaneComposer.compose(
            room: room(subs: 2), bass: bass(subs: 2), name: "Both", programLaneCount: 2, subwooferCount: 2)
        XCTAssertEqual(composed.design.laneCount, 4)
        XCTAssertEqual(composed.design.lanes.map(\.lane), [0, 1, 2, 3])
        let main = try XCTUnwrap(composed.design.lanes.first { $0.lane == 0 }?.grid)
        XCTAssertEqual(main.correctionDB[0], -3, accuracy: 1e-12)
        XCTAssertEqual(main.correctionPhaseRadians[0], 0.1, accuracy: 1e-12)
        let sub = try XCTUnwrap(composed.design.lanes.first { $0.lane == 3 }?.grid)
        XCTAssertEqual(sub.correctionDB[0], 3, accuracy: 1e-12)
        // The room's alignment delay and the bass main delay add on lane 1.
        XCTAssertEqual(try XCTUnwrap(composed.laneDelays.first { $0.lane == 1 }).seconds, 0.003, accuracy: 1e-12)
    }

    func testComposerHandlesEitherInputAloneAndRefusesTheRest() throws {
        let onlyRoom = try RoomCorrectionLaneComposer.compose(
            room: room(subs: 1), bass: nil, name: "R", programLaneCount: 2, subwooferCount: 1)
        XCTAssertEqual(onlyRoom.design.lanes.map(\.lane), [0, 1])
        let onlyBass = try RoomCorrectionLaneComposer.compose(
            room: nil, bass: bass(subs: 1), name: "B", programLaneCount: 2, subwooferCount: 1)
        XCTAssertEqual(onlyBass.design.lanes.map(\.lane), [0, 1, 2])
        XCTAssertThrowsError(try RoomCorrectionLaneComposer.compose(
            room: nil, bass: nil, name: "x", programLaneCount: 2, subwooferCount: 1)) {
            XCTAssertEqual($0 as? RoomCorrectionLaneComposerError, .nothingToCompose)
        }
        XCTAssertThrowsError(try RoomCorrectionLaneComposer.compose(
            room: room(subs: 1), bass: bass(subs: 2), name: "x", programLaneCount: 2, subwooferCount: 1)) {
            XCTAssertEqual($0 as? RoomCorrectionLaneComposerError, .layoutMismatch)
        }
    }

    // MARK: Graph

    private func spec(
        rate: Double, subs: Int, plan: RoomCorrectionLanePlan, delays: [UInt32: UInt32] = [:], routing: UnifiedGraphRouting? = nil
    ) throws -> UnifiedGraphSpec {
        var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.stereoStages = UnifiedGraphStereoStages()
        var dsp = UnifiedGraphProgramDSP(
            stereo: base, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight])), eqMode: .linked)
        dsp.roomLanes = plan
        dsp.subLaneCount = subs
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: 2, subwoofers: [UnifiedGraphSubwoofer](repeating: UnifiedGraphSubwoofer(), count: subs))
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return try configuration.makeSpec()
    }

    func testSubLanesCarryTheirGridsOnPlainTwoOneAndTwoTwoGraphsAtEveryRate() throws {
        for subs in [1, 2] {
            let install = try RoomCorrectionLaneComposer.compose(
                room: room(subs: subs), bass: bass(subs: subs), name: "x", programLaneCount: 2, subwooferCount: subs)
            for rate in Self.rates {
                let plan = try RoomCorrectionRateCache().plan(for: install.design, sampleRate: rate)
                let built = try spec(rate: rate, subs: subs, plan: plan)
                let covered = built.stages.filter { $0.kind == N60_STAGE_ROOM_FIR.rawValue }.reduce(UInt64(0)) { $0 | $1.laneMask }
                XCTAssertEqual(covered, (1 << UInt64(2 + subs)) - 1, "\(subs) subs at \(rate)")
                _ = try UnifiedGraphHost(spec: built)
            }
        }
    }

    func testRoutedGraphKeepsTheSubLanePlanAndAlignsRoutedOutputs() throws {
        let ep = { (i: UInt32) in PhysicalOutputEndpoint(deviceUID: "dev", channelIndex: i) }
        let mains: [SpeakerRoutingTemplate.Main] = [0, 1].enumerated().map { n, lane in
            .init(lane: lane, name: "M\(lane)", endpoints: [ep(UInt32(n * 2)), ep(UInt32(n * 2 + 1))])
        }
        let routing = try XCTUnwrap(SpeakerRoutingTemplate.twoWay.build(mains: mains, subs: [ep(5)], crossoverHz: [2_000]))
        let install = try RoomCorrectionLaneComposer.compose(
            room: room(subs: 1), bass: bass(subs: 1), name: "x", programLaneCount: 2, subwooferCount: 1)
        for rate in Self.rates {
            let plan = try RoomCorrectionRateCache().plan(for: install.design, sampleRate: rate)
            var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            base.bassManagement = UnifiedGraphBassManagement(subwoofers: [UnifiedGraphSubwoofer()])
            base.stereoStages = UnifiedGraphStereoStages()
            var dsp = UnifiedGraphProgramDSP(
                stereo: base, shape: try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight])), eqMode: .linked)
            dsp.roomLanes = plan
            dsp.subLaneCount = 1
            var config = try SpeakerRoutingCompiler.compile(routing, onto: base)
            config.orderPolicy = .canonical
            config.programDSP = dsp
            let built = try config.makeSpec()
            let covered = built.stages.filter { $0.kind == N60_STAGE_ROOM_FIR.rawValue }.reduce(UInt64(0)) { $0 | $1.laneMask }
            XCTAssertEqual(covered, 0b111, "routed 2.1 at \(rate)")
            XCTAssertEqual(built.outputChannels, UInt32(config.channelCount))
            _ = try UnifiedGraphHost(spec: built)
        }
    }

    // MARK: Prediction

    func testTwoPathPredictionDiffersFromEitherPathAlone() throws {
        let rate = 48_000.0
        func impulse(_ delay: Int) -> [Float] {
            var x = [Float](repeating: 0, count: 4_800)
            x[delay] = 0.5
            return x
        }
        let criteria = RoomCorrectionPostApplyCriteria()
        let main = RoomCorrectionPredictionPath(roomImpulse: impulse(100), arrivalFrames: 100)
        var sub = RoomCorrectionPredictionPath(roomImpulse: impulse(120), arrivalFrames: 120)
        let alone = try RoomCorrectionPostApplyVerifier.prediction(
            paths: [main], declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria)
        let together = try RoomCorrectionPostApplyVerifier.prediction(
            paths: [main, sub], declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria)
        XCTAssertEqual(alone.centres, together.centres)
        XCTAssertTrue(zip(alone.magnitudeDB, together.magnitudeDB).contains { abs($0 - $1) > 1 })
        // An inverted path at the same arrival cancels the main almost completely.
        sub = RoomCorrectionPredictionPath(roomImpulse: impulse(100), arrivalFrames: 100, polarityInverted: true)
        let cancelled = try RoomCorrectionPostApplyVerifier.prediction(
            paths: [main, sub], declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria)
        XCTAssertTrue(cancelled.magnitudeDB.allSatisfy { $0 < alone.magnitudeDB.min()! - 40 })
        XCTAssertThrowsError(try RoomCorrectionPostApplyVerifier.prediction(
            paths: [], declaredLatencyFrames: 0, sampleRate: rate, criteria: criteria))
    }
}
