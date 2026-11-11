import XCTest
@testable import NotchSixty

/// E19 S6: the MIMO stage in the graph (spec, latency matching, headroom budgets) and the arm controller's gates.
/// The runtime monitor, the 3 s fade and the 10 ms trip are covered by `core/tests/test_mimo_stage.cpp`.
@MainActor
final class MIMOGraphWiringTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    // MARK: Fixtures

    private func filters(rate: Double, sources: Int = 2, taps: Int = 16, tau: Double = 0.015) throws -> MIMOTreatmentFilterSet {
        let low = try MIMORoomTreatmentCoreDesigner.lowRate(forSampleRate: rate)
        return MIMOTreatmentFilterSet(
            sampleRate: rate, lowRateHz: low.lowRateHz, decimation: low.decimation, sourceCount: sources, tapCount: taps,
            tauSeconds: tau, taps: [Float](repeating: 0, count: sources * sources * taps), solved: [], gridLowHz: 0, gridBins: 0)
    }

    private func configuration(rate: Double, protection: Bool = true, preGain: Float = 1) -> UnifiedGraphConfiguration {
        var lane = UnifiedGraphLane()
        lane.preGain = preGain
        var config = UnifiedGraphConfiguration(sampleRate: rate, lanes: [lane, UnifiedGraphLane()])
        config.outputProtection = protection ? UnifiedGraphOutputProtection() : nil
        return config
    }

    private func flags(on: Bool) -> FeatureFlags {
        FeatureFlags(
            defaults: UserDefaults(suiteName: "MIMOGraphWiringTests.\(UUID().uuidString)") ?? .standard,
            policy: .launchArgumentOnly,
            arguments: on ? [FeatureFlags.launchArgument, FeatureFlag.mimoTreatment.id] : [])
    }

    private func context(
        stage: UnifiedGraphMIMOStage? = nil, uid: String? = "OUT-1", rate: Double? = 48_000, trims: [Double] = [0, 0],
        running: Bool = true, attached: Bool = true, hardLimit: Bool = true, lease: Bool = true, video: Bool = false
    ) -> MIMOGraphTreatment.Context {
        MIMOGraphTreatment.Context(
            engineRunning: running, outputDeviceUID: uid, sampleRate: rate, stageAttached: attached, hardLimitPresent: hardLimit,
            engineLeaseHeld: lease, videoLatencyMode: video, outputTrimsDB: trims, laneCount: 2)
    }

    private struct Rig {
        var treatment: MIMOGraphTreatment
        var stage: UnifiedGraphMIMOStage
        var published: Box
    }

    private final class Box { var stages: [UnifiedGraphMIMOStage] = []; var settles = 0 }

    private func rig(on: Bool = true, permitted: Bool = true, uid: String = "OUT-1") throws -> Rig {
        let treatment = MIMOGraphTreatment(flags: flags(on: on))
        let box = Box()
        treatment.publish = { box.stages.append($0) }
        treatment.settle = { box.settles += 1 }
        let stage = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), sourceLanes: [0, 1])
        treatment.stage(stage)
        if permitted {
            treatment.setPermit(.init(fingerprint: MIMOGraphTreatment.fingerprint(
                stage: stage, outputUID: uid, trimsDB: [0, 0], laneCount: 2)))
        }
        return Rig(treatment: treatment, stage: stage, published: box)
    }

    // MARK: Graph

    func testStageAndLatencyMatchingDelaysAtEightRates() throws {
        for rate in rates {
            let stage = try UnifiedGraphMIMOStage(filters: filters(rate: rate, sources: 1), sourceLanes: [0])
            var config = configuration(rate: rate)
            config.mimo = stage
            let spec = try config.makeSpec()
            let mimo = spec.stages.filter { $0.kind == N60_STAGE_MIMO.rawValue }
            XCTAssertEqual(mimo.count, 1, "rate \(rate)")
            XCTAssertEqual(mimo[0].laneMask, 1)
            XCTAssertEqual(mimo[0].params.count, 8 + 1 + 16, "8 header words, S bounds, S*S*T taps")
            XCTAssertEqual(mimo[0].params[4], 0, "published disarmed")
            XCTAssertEqual(mimo[0].params[5], 0, "published untripped")
            let latency = UInt32(10 * stage.filters.decimation) + UInt32((0.015 * rate).rounded())
            XCTAssertEqual(stage.latencyFrames, latency)
            let delays = spec.stages.filter { $0.kind == N60_STAGE_DELAY.rawValue && $0.stageId >= UnifiedGraphMIMOStage.alignStageBase }
            XCTAssertEqual(delays.count, 1, "one lane outside the mask")
            XCTAssertEqual(delays[0].laneA, 1)
            XCTAssertEqual(delays[0].params, [Float(latency)])
        }
    }

    func testNoStageWhenNoneIsConfigured() throws {
        let spec = try configuration(rate: 48_000).makeSpec()
        XCTAssertFalse(spec.stages.contains { $0.kind == N60_STAGE_MIMO.rawValue })
        XCTAssertFalse(spec.stages.contains { $0.stageId >= UnifiedGraphMIMOStage.alignStageBase && $0.stageId < 700 })
    }

    func testStageRefusedWithoutTheHardLimit() throws {
        var config = configuration(rate: 48_000, protection: false)
        config.mimo = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), sourceLanes: [0, 1])
        XCTAssertThrowsError(try config.makeSpec())
    }

    func testStageRefusedAtAnotherRate() throws {
        var config = configuration(rate: 96_000)
        config.mimo = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), sourceLanes: [0, 1])
        XCTAssertThrowsError(try config.makeSpec())
    }

    func testUnarmedOutputIsTheProgramDelayedByLatency() throws {
        for rate in [48_000.0, 384_000.0] {
            let stage = try UnifiedGraphMIMOStage(filters: filters(rate: rate), sourceLanes: [0, 1])
            let latency = Int(stage.latencyFrames)
            let frames = latency + 4_096
            var input = [[Float]](repeating: [Float](repeating: 0, count: frames), count: 2)
            for n in 0..<frames {
                input[0][n] = 0.1 * Float(sin(2 * Double.pi * 220 * Double(n) / rate))
                input[1][n] = 0.1 * Float(sin(2 * Double.pi * 330 * Double(n) / rate))
            }
            let plain = try UnifiedGraphHost(spec: try configuration(rate: rate).makeSpec())
            var config = configuration(rate: rate)
            config.mimo = stage
            let staged = try UnifiedGraphHost(spec: try config.makeSpec())
            let reference = try plain.processOffline(input: input, frames: frames)
            let output = try staged.processOffline(input: input, frames: frames)
            for lane in 0..<2 {
                var worst: Float = 0
                for n in latency..<frames { worst = max(worst, abs(output[lane][n] - reference[lane][n - latency])) }
                XCTAssertLessThan(worst, 1e-4, "rate \(rate) lane \(lane): unarmed stage must only delay by L = \(latency)")
            }
            let readback = try XCTUnwrap(staged.mimoReadback(stageId: UnifiedGraphMIMOStage.stageId))
            XCTAssertEqual(readback.state, 0, "off")
            XCTAssertEqual(readback.latencyFrames, stage.latencyFrames)
        }
    }

    // MARK: Headroom (G17, G19)

    func testBudgetsCapTheGainLimitAndRefuseAnImpossibleChain() async throws {
        let request = MIMOTreatmentRequest(
            sampleRate: 48_000, sources: [MIMOTreatmentSourceSpec(), MIMOTreatmentSourceSpec()],
            seats: [MIMOTreatmentSeatSpec()], plants: [[nil], [nil]])
        let ok = try await MIMOGraphHeadroom.budgetedRequest(
            request, configuration: configuration(rate: 48_000), sourceLanes: [0, 1])
        for source in ok.sources { XCTAssertLessThanOrEqual(source.gainLimitDB, 9.0) }
        XCTAssertLessThan(ok.sources[0].gainLimitDB, 9.0 + 1e-9)
        // A lane whose chain already peaks 12 dB high cannot take a treatment: refused by name, not designed.
        do {
            _ = try await MIMOGraphHeadroom.budgetedRequest(
                request, configuration: configuration(rate: 48_000, preGain: 4), sourceLanes: [0, 1])
            XCTFail("expected a headroom refusal")
        } catch let error as MIMORoomTreatmentCoreDesignError {
            XCTAssertEqual(error, .headroom(source: 0))
        }
    }

    func testDesignedStageMustFitTheHardLimitAllowance() async throws {
        let stage = try UnifiedGraphMIMOStage(filters: filters(rate: 48_000), sourceLanes: [0, 1])
        try await MIMOGraphHeadroom.verifyDesignedStage(configuration: configuration(rate: 48_000), stage: stage)
        do {
            try await MIMOGraphHeadroom.verifyDesignedStage(configuration: configuration(rate: 48_000, preGain: 4), stage: stage)
            XCTFail("expected over budget")
        } catch let failure as MIMOGraphHeadroom.Failure {
            guard case .overBudget(let source, let needed) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(source, 0)
            XCTAssertGreaterThan(needed, 3.0)
        }
    }

    // MARK: Arm controller

    func testNothingArmsByItself() throws {
        let rig = try rig()
        XCTAssertFalse(rig.treatment.isArmed)
        rig.treatment.observe(context: context(), readback: nil)
        XCTAssertFalse(rig.treatment.isArmed)
        XCTAssertTrue(rig.published.stages.isEmpty, "staging and observing never post a live word")
        XCTAssertFalse(rig.treatment.stage?.armed ?? true)
        // A restage, a permit and a rebuild are not arms either.
        rig.treatment.stage(rig.stage)
        rig.treatment.graphRebuilt()
        XCTAssertFalse(rig.treatment.isArmed)
        XCTAssertFalse(MIMOGraphTreatment(flags: flags(on: true)).isArmed, "a new controller (launch) starts disarmed")
    }

    func testArmingPassesEveryGateAndPostsTheArmWord() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        XCTAssertTrue(rig.treatment.isArmed)
        XCTAssertEqual(rig.published.stages.last?.armed, true)
        XCTAssertEqual(rig.published.stages.last?.trip, false)
        XCTAssertEqual(rig.published.settles, 1, "a held latch is cleared with arm = 0 and trip = 0 posted first")
        XCTAssertEqual(rig.published.stages.first?.armed, false)
    }

    func testEachGateRefuses() async throws {
        let cases: [(String, MIMOGraphTreatment.Context, MIMOGraphTreatment.ArmRefusal)] = [
            ("not running", context(running: false), .engineNotRunning),
            ("no output", context(uid: nil), .outputUnknown),
            ("video mode", context(video: true), .videoLatencyMode),
            ("stage not attached", context(attached: false), .stageNotAttached),
            ("no hard limit", context(hardLimit: false), .hardLimitMissing),
            ("no lease", context(lease: false), .engineLeaseMissing),
            ("another output", context(uid: "OUT-2"), .fingerprintMismatch),
            ("a trim changed", context(trims: [-1, 0]), .fingerprintMismatch),
        ]
        for (name, ctx, expected) in cases {
            let rig = try rig()
            do { try await rig.treatment.requestArm(context: ctx); XCTFail("\(name): armed") } catch let error as MIMOGraphTreatment.ArmRefusal {
                XCTAssertEqual(error, expected, name)
            }
            XCTAssertFalse(rig.treatment.isArmed, name)
            XCTAssertFalse(rig.published.stages.contains { $0.armed }, "\(name): no arm word posted")
        }
        let noPermit = try rig(permitted: false)
        do { try await noPermit.treatment.requestArm(context: context()); XCTFail("armed without a permit") } catch {
            XCTAssertEqual(error as? MIMOGraphTreatment.ArmRefusal, .noPermit)
        }
        let off = try rig(on: false)
        do { try await off.treatment.requestArm(context: context()); XCTFail("armed with the flag off") } catch {
            XCTAssertEqual(error as? MIMOGraphTreatment.ArmRefusal, .featureOff)
        }
    }

    func testTrimOrChainChangeDisarmsAndTrips() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        rig.treatment.observe(context: context(), readback: nil)
        XCTAssertTrue(rig.treatment.isArmed, "the same context keeps it armed (master volume is not part of the context)")
        rig.treatment.observe(context: context(trims: [0, -2]), readback: nil)
        XCTAssertFalse(rig.treatment.isArmed)
        XCTAssertEqual(rig.treatment.arm.lastDisarmReason, .downstreamChainChanged)
        XCTAssertEqual(rig.published.stages.last?.armed, false)
        XCTAssertEqual(rig.published.stages.last?.trip, true, "an automatic disarm trips (10 ms fade)")
    }

    func testDeviceRateAndStopDisarm() async throws {
        let cases: [(MIMOGraphTreatment.Context, LiveTreatmentDisarmReason)] = [
            (context(uid: "OUT-2"), .outputDeviceChanged),
            (context(rate: 96_000), .sampleRateChanged),
            (context(running: false), .engineStopped),
            (context(uid: nil), .outputDeviceLost),
        ]
        for (ctx, reason) in cases {
            let rig = try rig()
            try await rig.treatment.requestArm(context: context())
            rig.treatment.observe(context: ctx, readback: nil)
            XCTAssertEqual(rig.treatment.arm.lastDisarmReason, reason)
            XCTAssertFalse(rig.treatment.isArmed)
        }
    }

    func testLongArmWithoutMicrophoneStaysArmed() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        rig.treatment.arm.observe(
            LiveTreatmentEnvironment(outputDeviceUID: "OUT-1", sampleRate: 48_000, engineRunning: true, inputAvailable: true),
            now: Date().addingTimeInterval(3_600))
        XCTAssertTrue(rig.treatment.isArmed, "no microphone analysis exists for MIMO; the stall rule must not apply")
    }

    func testStageFaultDisarms() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        var readback = n60_mimo_readback()
        readback.structSize = UInt32(MemoryLayout<n60_mimo_readback>.size)
        readback.faultLatched = 1
        readback.faultReason = 2
        rig.treatment.observe(context: context(), readback: readback)
        XCTAssertEqual(rig.treatment.arm.lastDisarmReason, .treatmentFault)
        XCTAssertEqual(rig.published.stages.last?.trip, true)
    }

    func testRebuildAndTeardownDisarmAndNeedAFreshArm() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        rig.treatment.graphRebuilt()
        XCTAssertFalse(rig.treatment.isArmed)
        XCTAssertEqual(rig.treatment.arm.lastDisarmReason, .transportReconfigured)
        XCTAssertTrue(rig.treatment.latchMayBeHeld)
        try await rig.treatment.requestArm(context: context())
        XCTAssertTrue(rig.treatment.isArmed)
        XCTAssertEqual(rig.published.settles, 2, "every re-arm after a rebuild lets the core clear its latch first")
        rig.treatment.arm.transportTornDown(.sleep)
        XCTAssertEqual(rig.treatment.arm.lastDisarmReason, .sleep)
        XCTAssertFalse(rig.treatment.isArmed)
    }

    func testUserDisarmFadesWithoutTripping() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        rig.treatment.userDisarm()
        XCTAssertEqual(rig.published.stages.last?.armed, false)
        XCTAssertEqual(rig.published.stages.last?.trip, false)
    }

    func testFailedDisarmPostIsRetriedUntilItLands() async throws {
        let rig = try rig()
        try await rig.treatment.requestArm(context: context())
        struct PostFailed: Error {}
        var failing = true
        var landed: [UnifiedGraphMIMOStage] = []
        rig.treatment.publish = { stage in
            if failing { throw PostFailed() }
            landed.append(stage)
        }
        rig.treatment.observe(context: context(trims: [0, -2]), readback: nil)
        XCTAssertFalse(rig.treatment.isArmed)
        XCTAssertTrue(landed.isEmpty)
        failing = false
        rig.treatment.observe(context: context(trims: [0, -2]), readback: nil)
        XCTAssertEqual(landed.last?.armed, false, "the disarm word is re-posted on the next poll")
        XCTAssertEqual(landed.last?.trip, true)
    }

    func testLosingAGateWhileArmedDisarms() async throws {
        let losses: [MIMOGraphTreatment.Context] = [
            context(attached: false), context(hardLimit: false), context(lease: false), context(video: true),
        ]
        for lost in losses {
            let rig = try rig()
            try await rig.treatment.requestArm(context: context())
            rig.treatment.observe(context: lost, readback: nil)
            XCTAssertFalse(rig.treatment.isArmed)
            XCTAssertEqual(rig.published.stages.last?.trip, true)
        }
    }
}
