import CoreAudio
import Foundation
import os
import XCTest
@testable import NotchSixty

/// E20 S6: the render worker pool (realtime threads in the output device's Audio Workgroup), the worker-count policy and
/// their host hooks. No hardware: the workgroup is a test `WorkGroupParallel`, the graph is rendered offline through
/// `UnifiedGraphHost.processOffline`, and the wake function is the production semaphore header.
final class ParallelRenderWorkersTests: XCTestCase {
    private static let standardRates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    override func tearDown() {
        ParallelRenderPolicy.setEnabledForTesting(false)
        super.tearDown()
    }

    /// `lanes` output lanes with `stages` consecutive non-uniform FIR stages of `taps` taps on every lane.
    private func firSpec(rate: Double, lanes: UInt32, stages: Int, taps: Int, scheme: UInt32 = UnifiedGraphFIRScheme.nonUniform) -> UnifiedGraphSpec {
        var seed: UInt32 = 12345
        func next() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(Int32(bitPattern: seed)) / Float(Int32.max)
        }
        var specStages: [UnifiedGraphStageSpec] = []
        for index in 0..<stages {
            let impulse = (0..<taps).map { _ in next() * 0.5 / Float(taps).squareRoot() }
            specStages.append(UnifiedGraphStageSpec(
                kind: N60_STAGE_FIR.rawValue, stageId: UInt32(index + 1), laneA: N60_LANE_ALL, params: impulse
            ))
        }
        return UnifiedGraphSpec(
            sampleRate: rate, maxBlockFrames: 512, inputChannels: lanes, outputChannels: lanes,
            stages: specStages, denoiserPark: nil, firScheme: scheme
        )
    }

    // MARK: Policy

    func testPolicyTableAtStandardRates() {
        let cores = 8
        var previous = 0
        for rate in Self.standardRates {
            let spec = firSpec(rate: rate, lanes: 8, stages: 2, taps: 65_536)
            let load = ParallelRenderPolicy.estimatedLoad(spec)
            XCTAssertGreaterThan(load, 0, "rate \(rate)")
            let workers = ParallelRenderPolicy.workerCount(spec: spec, cores: cores, enabled: true)
            let expected = load < ParallelRenderPolicy.minLoad
                ? 0 : min(Int((load / ParallelRenderPolicy.minLoad).rounded(.up)), 15, cores - 1, Int(N60_GRAPH_MAX_WORKERS))
            XCTAssertEqual(workers, expected, "rate \(rate) load \(load)")
            XCTAssertGreaterThanOrEqual(workers, previous, "workers never fall as the rate rises (\(rate))")
            XCTAssertLessThanOrEqual(workers, Int(N60_GRAPH_MAX_WORKERS))
            previous = workers
        }
        // The load rises with the rate: nothing at the lowest, workers at the highest.
        XCTAssertEqual(ParallelRenderPolicy.workerCount(spec: firSpec(rate: 44_100, lanes: 8, stages: 2, taps: 65_536), cores: cores, enabled: true), 0)
        XCTAssertGreaterThan(previous, 0, "384 kHz with 16 long FIR lanes needs workers")
    }

    func testPolicyIsZeroWhenFlagOffUniformSchemeOneLaneOrOneCore() {
        let heavy = firSpec(rate: 384_000, lanes: 8, stages: 2, taps: 65_536)
        XCTAssertGreaterThan(ParallelRenderPolicy.workerCount(spec: heavy, cores: 8, enabled: true), 0)
        XCTAssertEqual(ParallelRenderPolicy.workerCount(spec: heavy, cores: 8, enabled: false), 0, "flag off")
        XCTAssertEqual(ParallelRenderPolicy.workerCount(spec: heavy, cores: 1, enabled: true), 0, "one core")
        let uniform = firSpec(rate: 384_000, lanes: 8, stages: 2, taps: 30_000, scheme: UnifiedGraphFIRScheme.uniform)
        XCTAssertEqual(ParallelRenderPolicy.workerCount(spec: uniform, cores: 8, enabled: true), 0, "uniform scheme has no parallel phase")
        let oneLane = firSpec(rate: 384_000, lanes: 1, stages: 4, taps: 65_536)
        XCTAssertEqual(ParallelRenderPolicy.workerCount(spec: oneLane, cores: 8, enabled: true), 0, "one lane job cannot be shared")
        XCTAssertEqual(ParallelRenderPolicy.poolSize(scheme: UnifiedGraphFIRScheme.uniform, cores: 8, enabled: true), 0)
        XCTAssertEqual(ParallelRenderPolicy.poolSize(scheme: UnifiedGraphFIRScheme.nonUniform, cores: 8, enabled: false), 0)
        XCTAssertEqual(ParallelRenderPolicy.poolSize(scheme: UnifiedGraphFIRScheme.nonUniform, cores: 8, enabled: true), Int(N60_GRAPH_MAX_WORKERS))
        XCTAssertEqual(ParallelRenderPolicy.poolSize(scheme: UnifiedGraphFIRScheme.nonUniform, cores: 2, enabled: true), 1)
    }

    func testFeatureFlagIsRegisteredAndOffByDefault() {
        XCTAssertTrue(FeatureFlag.all.contains(.parallelRender))
        XCTAssertEqual(FeatureFlag.parallelRender.id, "e20.parallel-render")
        XCTAssertFalse(FeatureFlag.parallelRender.graduated)
        XCTAssertFalse(ParallelRenderPolicy.isEnabled)
    }

    // MARK: Pool lifecycle

    func testFlagOffCreatesNoThreads() throws {
        ParallelRenderPolicy.setEnabledForTesting(false)
        let host = try UnifiedGraphHost(spec: firSpec(rate: 384_000, lanes: 8, stages: 2, taps: 65_536))
        XCTAssertEqual(host.beginParallelRender(workgroup: WorkGroupParallel(name: "n60.test.off")), 0)
        XCTAssertNil(host.parallelRenderStats)
        XCTAssertNil(host.endParallelRender())
        host.release()
    }

    func testJoinLeaveAndRejoinOnAnotherWorkgroup() throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 2, "needs a second core")
        ParallelRenderPolicy.setEnabledForTesting(true)
        let host = try UnifiedGraphHost(spec: firSpec(rate: 384_000, lanes: 8, stages: 2, taps: 65_536))
        let first = try XCTUnwrap(WorkGroupParallel(name: "n60.test.first"))
        let second = try XCTUnwrap(WorkGroupParallel(name: "n60.test.second"))
        let size = host.beginParallelRender(workgroup: first)
        XCTAssertGreaterThan(size, 0)
        XCTAssertEqual(size, ParallelRenderPolicy.poolSize(scheme: UnifiedGraphFIRScheme.nonUniform))
        let started = try XCTUnwrap(host.parallelRenderStats)
        XCTAssertEqual(started.started, size)
        XCTAssertEqual(started.joined + started.joinFailed, size, "every worker tried to join")
        XCTAssertEqual(started.joined, size, "a parallel workgroup accepts every worker")
        XCTAssertEqual(started.policySet + started.policyFailed, size)

        // Stop (and Quit, and device loss): every worker that joined has left, and the pool is gone.
        let stopped = try XCTUnwrap(host.endParallelRender())
        XCTAssertEqual(stopped.left, stopped.joined)
        XCTAssertNil(host.parallelRenderStats)
        XCTAssertEqual(host.parallelRenderWorkerLimit, 0)

        // Rejoin on a different workgroup (a new device after a rate change or reconnect).
        XCTAssertEqual(host.beginParallelRender(workgroup: second), size)
        // Beginning again without an end (a restart without teardown) stops the old pool first.
        XCTAssertEqual(host.beginParallelRender(workgroup: first), size)
        let again = try XCTUnwrap(host.parallelRenderStats)
        XCTAssertEqual(again.joined, size)
        // No workgroup (a device that offers none): still realtime threads, no join.
        XCTAssertEqual(host.beginParallelRender(workgroup: nil), size)
        let none = try XCTUnwrap(host.parallelRenderStats)
        XCTAssertEqual(none.joined + none.joinFailed, 0)
        // Release stops the pool before the graph is retired.
        host.release()
        XCTAssertNil(host.parallelRenderStats)
    }

    func testLiveWorkerLimitFollowsThePublishedSpec() throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 3, "needs three cores")
        ParallelRenderPolicy.setEnabledForTesting(true)
        let heavy = firSpec(rate: 384_000, lanes: 8, stages: 2, taps: 65_536)
        let host = try UnifiedGraphHost(spec: heavy)
        defer { host.release() }
        XCTAssertGreaterThan(host.beginParallelRender(workgroup: WorkGroupParallel(name: "n60.test.live")), 0)
        let expectedHeavy = min(ParallelRenderPolicy.workerCount(spec: heavy), host.parallelRenderStats?.started ?? 0)
        XCTAssertEqual(host.parallelRenderWorkerLimit, expectedHeavy)
        XCTAssertGreaterThan(expectedHeavy, 0)
        // A lighter FIR (one short stage) of the same topology class publishes and the limit drops to zero.
        var light = heavy
        light.stages = [heavy.stages[0]]
        light.stages[0].params = Array(light.stages[0].params.prefix(256))
        _ = try host.apply(light)
        XCTAssertEqual(host.parallelRenderWorkerLimit, 0)
        _ = try host.apply(heavy)
        XCTAssertEqual(host.parallelRenderWorkerLimit, expectedHeavy)
    }

    // MARK: Rendering

    /// The workers change who computes a lane, never the result: a graph rendered with the pool running is bit-identical
    /// to the same graph rendered on one thread, at every standard rate.
    func testWorkersRenderBitIdenticalToSingleThreadAtStandardRates() throws {
        try XCTSkipIf(ProcessInfo.processInfo.activeProcessorCount < 3, "needs three cores")
        for rate in Self.standardRates {
            let spec = firSpec(rate: rate, lanes: 4, stages: 2, taps: 8_192)
            ParallelRenderPolicy.setEnabledForTesting(false)
            let reference = try UnifiedGraphHost(spec: spec)
            let parallel = try UnifiedGraphHost(spec: spec)
            defer { reference.release(); parallel.release() }
            // The policy would hand this small graph no workers; the pool is started on the full thread set and the
            // worker limit is forced up through the live-apply path by enabling the flag with a zero load threshold.
            ParallelRenderPolicy.setEnabledForTesting(true)
            let size = parallel.beginParallelRender(workgroup: WorkGroupParallel(name: "n60.test.render"))
            XCTAssertGreaterThan(size, 0)
            parallel.forceParallelWorkersForTesting(size)

            var seed: UInt32 = 99
            func sample() -> Float {
                seed = seed &* 1_103_515_245 &+ 12_345
                return Float(Int32(bitPattern: seed)) / Float(Int32.max) * 0.25
            }
            for block in 0..<24 {
                let input = (0..<4).map { _ in (0..<512).map { _ in sample() } }
                let expected = try reference.processOffline(input: input, frames: 512)
                let actual = try parallel.processOffline(input: input, frames: 512)
                for lane in 0..<4 {
                    XCTAssertTrue(expected[lane].elementsEqual(actual[lane]) { $0.bitPattern == $1.bitPattern },
                                  "rate \(rate) block \(block) lane \(lane)")
                }
            }
            XCTAssertGreaterThan(parallel.parallelRenderWakeCount, 0, "rate \(rate): the audio thread woke the workers")
            _ = parallel.endParallelRender()
        }
    }
}
