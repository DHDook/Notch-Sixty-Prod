import XCTest
@testable import NotchSixty

/// E19 S10: the routed MIMO stage in the graph (`N60_STAGE_MIMO_ROUTED`): spec, refusals, delay-only when unarmed, the lane
/// table made from a plan, the headroom lanes and the dead-man heartbeat. The core arithmetic is in `test_mimo_stage.cpp`.
@MainActor
final class MIMORoutedStageTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func ep(_ channel: UInt32) -> PhysicalOutputEndpoint { PhysicalOutputEndpoint(deviceUID: "DEV", channelIndex: channel) }
    private func way(_ name: String, _ channel: UInt32, high: CrossoverCore.FilterSpec? = nil, low: CrossoverCore.FilterSpec? = nil) -> RoutedWay {
        var w = RoutedWay(endpoint: ep(channel))
        w.name = name
        w.highPass = high
        w.lowPass = low
        return w
    }
    private func speaker(_ name: String, _ source: RoutingSource, _ ways: [RoutedWay]) -> RoutedSpeaker {
        var s = RoutedSpeaker(source: source, ways: ways)
        s.name = name
        return s
    }
    private func lr(_ hz: Double) -> CrossoverCore.FilterSpec { .init(family: .linkwitzRiley, order: 4, cornerHz: hz) }

    /// Two 2-way mains (outputs 0 to 3): output 0 and 2 are the woofers.
    private func routing() -> SpeakerRoutingConfiguration {
        SpeakerRoutingConfiguration(speakers: [
            speaker("Left", .program(0), [way("L woofer", 0, low: lr(2_000)), way("L tweeter", 1, high: lr(2_000))]),
            speaker("Right", .program(1), [way("R woofer", 2, low: lr(2_000)), way("R tweeter", 3, high: lr(2_000))]),
        ])
    }

    private func filters(rate: Double, sources: Int = 2, taps: Int = 16) throws -> MIMOTreatmentFilterSet {
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        return MIMOTreatmentFilterSet(
            sampleRate: rate, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: sources, tapCount: taps,
            tauSeconds: 0.015, taps: [Float](repeating: 0, count: sources * sources * taps), solved: [], gridLowHz: 0, gridBins: 0)
    }

    private func routedLayout() -> UnifiedGraphMIMOStage.Routed {
        .init(firstOutputLane: 2, outputCount: 4, inputPositions: [0, 2], injectionPositions: [[0], [2]])
    }

    private func routedConfiguration(rate: Double, protection: Bool = true) throws -> UnifiedGraphConfiguration {
        var base = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        base.outputProtection = protection ? UnifiedGraphOutputProtection() : nil
        return try SpeakerRoutingCompiler.compile(routing(), onto: base)
    }

    func testRoutedStageSpecAtEightRates() throws {
        for rate in rates {
            let stage = try UnifiedGraphMIMOStage(filters: filters(rate: rate), routed: routedLayout())
            var config = try routedConfiguration(rate: rate)
            config.mimo = stage
            let spec = try config.makeSpec()
            let found = spec.stages.filter { $0.kind == N60_STAGE_MIMO_ROUTED.rawValue }
            XCTAssertEqual(found.count, 1, "rate \(rate)")
            XCTAssertEqual(found[0].laneMask, 0b111100, "every output lane is delayed by L")
            XCTAssertEqual(found[0].params.count, 8 + 2 + 2 * 2 * 16 + 5 * 2)
            XCTAssertEqual(found[0].params[4], 0)
            XCTAssertEqual(found[0].params[7], Float(UnifiedGraphMIMOStage.leaseMilliseconds))
            XCTAssertFalse(spec.stages.contains { $0.kind == N60_STAGE_MIMO.rawValue })
            XCTAssertFalse(spec.stages.contains { $0.stageId >= UnifiedGraphMIMOStage.alignStageBase && $0.stageId < 700 }, "mask covers the outputs")
        }
    }

    func testStageAndRoutingMustAgree() throws {
        var routed = try routedConfiguration(rate: 48_000)
        routed.mimo = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), sourceLanes: [0, 1])
        XCTAssertThrowsError(try routed.makeSpec(), "an unrouted stage on a routed graph")
        var plain = UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
        plain.outputProtection = UnifiedGraphOutputProtection()
        plain.mimo = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), routed: routedLayout())
        XCTAssertThrowsError(try plain.makeSpec(), "a routed stage on an unrouted graph")
        var noLimit = try routedConfiguration(rate: 48_000, protection: false)
        noLimit.mimo = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), routed: routedLayout())
        XCTAssertThrowsError(try noLimit.makeSpec(), "no hard limit")
    }

    func testBadLayoutsAreRefused() throws {
        let f = try filters(rate: 48_000)
        XCTAssertThrowsError(try UnifiedGraphMIMOStage(filters: f, routed: .init(
            firstOutputLane: 2, outputCount: 4, inputPositions: [0, 2], injectionPositions: [[0], [0]])), "a lane injected twice")
        XCTAssertThrowsError(try UnifiedGraphMIMOStage(filters: f, routed: .init(
            firstOutputLane: 2, outputCount: 4, inputPositions: [0, 2], injectionPositions: [[0], []])), "no injection")
        XCTAssertThrowsError(try UnifiedGraphMIMOStage(filters: f, routed: .init(
            firstOutputLane: 2, outputCount: 4, inputPositions: [0, 9], injectionPositions: [[0], [2]])), "input outside the outputs")
        XCTAssertThrowsError(try UnifiedGraphMIMOStage(filters: f, routed: .init(
            firstOutputLane: 2, outputCount: 4, inputPositions: [0], injectionPositions: [[0]])), "table does not match the sources")
    }

    func testHeadroomChecksCoverEveryInjectionLane() throws {
        let stage = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), routed: .init(
            firstOutputLane: 2, outputCount: 4, inputPositions: [0, 2], injectionPositions: [[0, 1], [2, 3]]))
        XCTAssertEqual(stage.headroomChecks.map(\.lane), [2, 3, 4, 5])
        XCTAssertEqual(stage.headroomChecks.map(\.source), [0, 0, 1, 1])
    }

    func testUnarmedRoutedGraphIsTheRoutedGraphDelayedByL() throws {
        for rate in [48_000.0, 384_000.0] {
            let stage = try UnifiedGraphMIMOStage(filters: filters(rate: rate), routed: routedLayout())
            let latency = Int(stage.latencyFrames)
            let plain = try UnifiedGraphHost(spec: try routedConfiguration(rate: rate).makeSpec())
            var config = try routedConfiguration(rate: rate)
            config.mimo = stage
            let staged = try UnifiedGraphHost(spec: try config.makeSpec())
            defer { plain.release(); staged.release() }
            let frames = latency + 4_096
            var input = [[Float]](repeating: [Float](repeating: 0, count: frames), count: Int(plain.inputChannels))
            for lane in input.indices {
                for n in 0..<frames { input[lane][n] = 0.1 * Float(sin(2 * Double.pi * (220 + 110 * Double(lane)) * Double(n) / rate)) }
            }
            let reference = try plain.processOffline(input: input, frames: frames)
            let output = try staged.processOffline(input: input, frames: frames)
            XCTAssertEqual(output.count, reference.count)
            for lane in reference.indices {
                var worst: Float = 0
                for n in latency..<frames { worst = max(worst, abs(output[lane][n] - reference[lane][n - latency])) }
                XCTAssertLessThan(worst, 1e-4, "rate \(rate) lane \(lane)")
            }
            let readback = try XCTUnwrap(staged.mimoReadback(stageId: UnifiedGraphMIMOStage.stageId))
            XCTAssertEqual(readback.state, 0)
            XCTAssertEqual(readback.latencyFrames, stage.latencyFrames)
        }
    }

    func testMakeBuildsTheLaneTableFromThePlan() async throws {
        let rate = 48_000.0
        let routing = routing()
        let seats = [MultichannelCalibrationSeat(name: "Seat 1")]
        var captures: [MIMORoutedWayCapture] = []
        for speaker in routing.speakers {
            for way in speaker.ways {
                var ir = [Float](repeating: 0, count: Int(rate))
                ir[100] = 1
                captures.append(MIMORoutedWayCapture(
                    speakerID: speaker.id, wayID: way.id, seatID: seats[0].id, sampleRate: rate, impulseResponse: ir))
            }
        }
        var settings = MIMORoutedTreatmentSettings()
        settings.taps = 48
        let plan = try await MIMORoutedTreatmentPlanner.plan(
            routing: routing, sampleRate: rate, programLanes: 2, subwoofers: 0, seats: seats, captures: captures, settings: settings)
        let made = try UnifiedGraphMIMOStage.Routed.make(routing: routing, plan: plan, firstOutputLane: 2)
        XCTAssertEqual(made.outputCount, 4)
        XCTAssertEqual(made.inputPositions, [0, 2], "the woofers are the in-band ways")
        XCTAssertEqual(made.injectionPositions, [[0], [2]], "tweeters carry the program only")
    }

    func testHeartbeatPostsOnEveryObserveWhileArmed() async throws {
        let flags = FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMORoutedStageTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly, arguments: [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id])
        let treatment = MIMOGraphTreatment(flags: flags)
        var posted: [UnifiedGraphMIMOStage] = []
        treatment.publish = { posted.append($0) }
        treatment.settle = {}
        let stage = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), routed: routedLayout())
        treatment.stage(stage)
        let context = MIMOGraphTreatment.Context(
            engineRunning: true, outputDeviceUID: "OUT", sampleRate: 48_000, stageAttached: true, hardLimitPresent: true,
            engineLeaseHeld: true, videoLatencyMode: false, outputTrimsDB: [0, 0], laneCount: 2, routedDigest: "r")
        treatment.setPermit(.init(fingerprint: treatment.currentFingerprint(stage, context)))
        try await treatment.requestArm(context: context)
        XCTAssertTrue(treatment.isArmed)
        let before = posted.count
        for _ in 0..<3 { treatment.observe(context: context, readback: nil) }
        let beats = posted.dropFirst(before).map(\.heartbeat)
        XCTAssertEqual(beats.count, 3)
        XCTAssertEqual(Set(beats).count, 3, "every poll changes the word")
        XCTAssertTrue(posted.dropFirst(before).allSatisfy { $0.armed })
        var changed = context
        changed.routedDigest = "edited"
        treatment.observe(context: changed, readback: nil)
        XCTAssertFalse(treatment.isArmed, "a routing edit disarms")
    }
}
