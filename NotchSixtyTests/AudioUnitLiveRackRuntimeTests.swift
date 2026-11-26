import AudioToolbox
import AVFAudio
import Foundation
import XCTest
@testable import NotchSixty

@MainActor
final class AudioUnitLiveRackRuntimeTests: XCTestCase {
    func testLatencyMatchedBypassStageDelaysExactly() {
        let stage = AudioUnitLiveBypassStage(
            slotIndex: 0,
            component: nil,
            channelCount: 2,
            latencyFrames: 3
        )
        let input: [Float] = [
            1, 10,
            2, 20,
            3, 30,
            4, 40,
            5, 50,
            6, 60,
        ]
        var output = [Float](repeating: -1, count: input.count)

        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                _ = stage.process(
                    inputInterleaved: source.baseAddress!,
                    outputInterleaved: destination.baseAddress!,
                    frameCount: 6,
                    channelCount: 2,
                    sampleTime: 0
                )
            }
        }

        XCTAssertEqual(
            output,
            [
                0, 0,
                0, 0,
                0, 0,
                1, 10,
                2, 20,
                3, 30,
            ]
        )
    }

    func testSerialLatencyMatchedBypassesAccumulateExactly() throws {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        let first = AudioUnitLiveBypassStage(
            slotIndex: 0,
            component: nil,
            channelCount: 2,
            latencyFrames: 2
        )
        let second = AudioUnitLiveBypassStage(
            slotIndex: 1,
            component: nil,
            channelCount: 2,
            latencyFrames: 3
        )
        let runtime = try AudioUnitLiveRackRuntime(
            format: format,
            totalLatencyFrames: 5,
            stages: [first, second],
            componentsBySlot: [nil, nil]
        )
        defer { runtime.stopFaultMonitoring() }

        var input = [Float](repeating: 0, count: 20)
        for frame in 0..<10 {
            input[frame * 2] = Float(frame + 1)
            input[frame * 2 + 1] = Float((frame + 1) * 10)
        }
        var output = [Float](repeating: -1, count: input.count)
        let ok = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                runtime.process(
                    inputInterleaved: source.baseAddress!,
                    outputInterleaved: destination.baseAddress!,
                    frameCount: 10,
                    channelCount: 2,
                    sampleTime: 0
                )
            }
        }

        XCTAssertTrue(ok)
        for frame in 0..<5 {
            XCTAssertEqual(output[frame * 2], 0)
            XCTAssertEqual(output[frame * 2 + 1], 0)
        }
        for frame in 5..<10 {
            XCTAssertEqual(
                output[frame * 2],
                Float(frame - 4)
            )
            XCTAssertEqual(
                output[frame * 2 + 1],
                Float((frame - 4) * 10)
            )
        }
    }

    func testRuntimeFailsClosedWhenCallbackExceedsPreparedQuantum() throws {
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 32
        )
        let stage = AudioUnitLiveBypassStage(
            slotIndex: 0,
            component: nil,
            channelCount: 2,
            latencyFrames: 0
        )
        let runtime = try AudioUnitLiveRackRuntime(
            format: format,
            totalLatencyFrames: 0,
            stages: [stage],
            componentsBySlot: [nil]
        )
        let input = [Float](repeating: 0.25, count: 66)
        var output = [Float](repeating: 1, count: 66)

        let ok = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                runtime.process(
                    inputInterleaved: source.baseAddress!,
                    outputInterleaved: destination.baseAddress!,
                    frameCount: 33,
                    channelCount: 2,
                    sampleTime: 0
                )
            }
        }

        XCTAssertFalse(ok)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }

    func testRenderWatchdogRequiresSustainedSevereOverrun() {
        var watchdog = AudioUnitLiveRenderWatchdog()
        let budget: UInt64 = 100

        XCTAssertFalse(
            watchdog.observe(
                elapsedTicks: 101,
                budgetTicks: budget
            )
        )
        XCTAssertFalse(
            watchdog.observe(
                elapsedTicks: 150,
                budgetTicks: budget
            )
        )
        XCTAssertEqual(watchdog.consecutiveOverruns, 2)

        // A healthy render resets the streak so a one-off scheduler hiccup
        // cannot quarantine a plug-in.
        XCTAssertFalse(
            watchdog.observe(
                elapsedTicks: 100,
                budgetTicks: budget
            )
        )
        XCTAssertEqual(watchdog.consecutiveOverruns, 0)

        XCTAssertFalse(
            watchdog.observe(
                elapsedTicks: 101,
                budgetTicks: budget
            )
        )
        XCTAssertFalse(
            watchdog.observe(
                elapsedTicks: 101,
                budgetTicks: budget
            )
        )
        XCTAssertTrue(
            watchdog.observe(
                elapsedTicks: 101,
                budgetTicks: budget
            )
        )
        XCTAssertEqual(
            watchdog.consecutiveOverruns,
            AudioUnitLiveRenderWatchdog.consecutiveOverrunLimit
        )

        // Small buffers retain a generous 10 ms floor.
        XCTAssertEqual(
            AudioUnitLiveRenderWatchdog.budgetTicks(
                frameCount: 64,
                sampleRate: 48_000,
                ticksPerSecond: 1_000_000_000
            ),
            10_000_000
        )

        // Larger buffers use the four-times-buffer-duration threshold.
        XCTAssertGreaterThan(
            AudioUnitLiveRenderWatchdog.budgetTicks(
                frameCount: 512,
                sampleRate: 48_000,
                ticksPerSecond: 1_000_000_000
            ),
            40_000_000
        )
    }

    func testLiveTimingValidatorRejectsPathologicalValues() {
        XCTAssertNil(
            AudioUnitLiveTimingValidator.frameCount(
                seconds: .nan,
                sampleRate: 48_000,
                maximumSeconds:
                    AudioUnitProbeResult.maximumLatencySeconds
            )
        )
        XCTAssertNil(
            AudioUnitLiveTimingValidator.frameCount(
                seconds: .infinity,
                sampleRate: 48_000,
                maximumSeconds:
                    AudioUnitProbeResult.maximumLatencySeconds
            )
        )
        XCTAssertNil(
            AudioUnitLiveTimingValidator.frameCount(
                seconds: -0.001,
                sampleRate: 48_000,
                maximumSeconds:
                    AudioUnitProbeResult.maximumLatencySeconds
            )
        )
        XCTAssertNil(
            AudioUnitLiveTimingValidator.frameCount(
                seconds:
                    AudioUnitProbeResult.maximumTailSeconds + 0.001,
                sampleRate: 48_000,
                maximumSeconds:
                    AudioUnitProbeResult.maximumTailSeconds
            )
        )
        XCTAssertEqual(
            AudioUnitLiveTimingValidator.frameCount(
                seconds: 0.001,
                sampleRate: 48_000,
                maximumSeconds:
                    AudioUnitProbeResult.maximumLatencySeconds
            ),
            48
        )
    }

    func testControlPlaneHealthCollectionSurfacesInjectedLatencyDrift() throws {
        let identity = AudioUnitComponentIdentity(
            componentType: 0x61756678,
            componentSubType: 0x68383461,
            componentManufacturer: 0x6e363079
        )
        let issue = AudioUnitLiveRackControlPlaneIssue.latencyChanged(
            slot: 0,
            component: identity,
            expected: 64,
            actual: 96
        )
        let stage = PR84InjectedHealthStage(
            slotIndex: 0,
            component: identity,
            latencyFrames: 64,
            issue: issue
        )
        let runtime = try AudioUnitLiveRackRuntime(
            format: AudioUnitRackProcessingFormat(
                sampleRate: 48_000,
                channelCount: 2,
                maximumFramesPerSlice: 64
            ),
            totalLatencyFrames: 64,
            stages: [stage],
            componentsBySlot: [identity]
        )

        XCTAssertEqual(
            runtime.controlPlaneHealthIssues(),
            [issue]
        )
        XCTAssertTrue(
            runtime.controlPlaneHealthIssues()[0]
                .description.contains("changed latency after activation")
        )
    }

    func testControlPlaneHealthCollectionSurfacesInjectedInvalidTail() throws {
        let identity = AudioUnitComponentIdentity(
            componentType: 0x61756678,
            componentSubType: 0x68383462,
            componentManufacturer: 0x6e363079
        )
        let issue = AudioUnitLiveRackControlPlaneIssue.invalidTail(
            slot: 0,
            component: identity,
            seconds: .infinity
        )
        let runtime = try AudioUnitLiveRackRuntime(
            format: AudioUnitRackProcessingFormat(
                sampleRate: 96_000,
                channelCount: 8,
                maximumFramesPerSlice: 256
            ),
            totalLatencyFrames: 0,
            stages: [
                PR84InjectedHealthStage(
                    slotIndex: 0,
                    component: identity,
                    latencyFrames: 0,
                    issue: issue
                ),
            ],
            componentsBySlot: [identity]
        )

        XCTAssertEqual(runtime.controlPlaneHealthIssues(), [issue])
    }

    func testRealAppleLowPassCanRunThroughPreparedLiveRack() async throws {
        let identity = AudioUnitComponentIdentity(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_LowPassFilter,
            componentManufacturer: kAudioUnitManufacturer_Apple
        )
        let host = AudioUnitHostController()
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 512
        )
        host.scan(format: format)
        guard host.descriptor(for: identity) != nil else {
            throw XCTSkip(
                "Apple Low Pass Audio Unit is not registered on this runner."
            )
        }

        try host.installComponent(identity, inSlot: 0)
        await host.prepareSlotOffline(
            0,
            format: format,
            using: SystemAudioUnitOfflinePreparationBackend(
                renderPassCount: 2
            )
        )
        guard host.lifecycleByComponent[identity] == .prepared else {
            return XCTFail(
                host.lastErrorDescription
                    ?? "Apple Low Pass did not prepare."
            )
        }
        try host.setBypassed(false, slot: 0)

        guard let runtime =
            try await host.makeLiveRackRuntime(format: format) else {
            return XCTFail("Expected a non-empty live rack.")
        }
        defer { runtime.stopFaultMonitoring() }

        XCTAssertEqual(
            runtime.totalLatencyFrames,
            host.probeResult(forSlot: 0)?.latencyFrames
        )

        let frames = 512
        var input = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let sample = Float(
                0.08 * sin(
                    2.0 * Double.pi * 997.0
                    * Double(frame) / format.sampleRate
                )
            )
            input[frame * 2] = sample
            input[frame * 2 + 1] = sample * 0.7
        }
        var output = [Float](repeating: 0, count: input.count)

        let ok = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                runtime.process(
                    inputInterleaved: source.baseAddress!,
                    outputInterleaved: destination.baseAddress!,
                    frameCount: frames,
                    channelCount: 2,
                    sampleTime: 10_000
                )
            }
        }

        XCTAssertTrue(ok)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(
            output.reduce(0) { $0 + abs(Double($1)) },
            0.01
        )
    }

    func testInitialLiveBuildFailureQuarantinesUnavailableComponent() async throws {
        let identity = AudioUnitComponentIdentity(
            componentType: 0x61756678,
            componentSubType: 0x78383461,
            componentManufacturer: 0x78383462
        )
        let descriptor = AudioUnitComponentDescriptor(
            identity: identity,
            kind: .effect,
            name: "PR84A Missing Live Unit",
            manufacturerName: "Notch Labs",
            typeName: "Effect",
            version: 0x00010000,
            versionString: "1.0.0",
            hasCustomView: false,
            hasMIDIInput: false,
            hasMIDIOutput: false,
            passesAUVal: true,
            sandboxSafe: true,
            supportedSymmetricChannelCounts: [2]
        )
        let format = AudioUnitRackProcessingFormat(
            sampleRate: 48_000,
            channelCount: 2,
            maximumFramesPerSlice: 64
        )
        let host = AudioUnitHostController(
            catalog: PR84LiveMockCatalog(components: [descriptor])
        )
        host.scan()
        try host.installComponent(identity, inSlot: 0)
        await host.prepareSlotOffline(
            0,
            format: format,
            using: PR84LiveFixedBackend(
                report: pr84Report(
                    identity: identity,
                    format: format
                )
            )
        )
        XCTAssertEqual(host.lifecycleByComponent[identity], .prepared)
        try host.setBypassed(false, slot: 0)

        do {
            _ = try await host.makeLiveRackRuntime(format: format)
            XCTFail("Expected unavailable live Audio Unit failure.")
        } catch let error as AudioUnitLiveRackBuildError {
            guard case .liveInstantiationFailed(let slot, _) = error else {
                return XCTFail("Unexpected live build error: \(error)")
            }
            XCTAssertEqual(slot, 0)
        }

        XCTAssertEqual(
            host.quarantine.entry(for: identity)?.reason,
            .instantiationFailed
        )
        XCTAssertTrue(host.rackConfiguration.slots[0].bypassed)
        XCTAssertNil(host.probeResult(forSlot: 0))
    }

    private func pr84Report(
        identity: AudioUnitComponentIdentity,
        format: AudioUnitRackProcessingFormat
    ) -> AudioUnitOfflinePreparationReport {
        let metrics = AudioUnitOfflineRenderMetrics(
            renderedFrames: 512,
            renderPassCount: 2,
            channelCount: format.channelCount,
            maximumAbsoluteSample: 0.1,
            rmsByChannel: Array(
                repeating: 0.05,
                count: format.channelCount
            ),
            allSamplesFinite: true
        )
        return AudioUnitOfflinePreparationReport(
            component: identity,
            format: format,
            probe: AudioUnitProbeResult(
                component: identity,
                sampleRate: format.sampleRate,
                inputChannelCount: format.channelCount,
                outputChannelCount: format.channelCount,
                maximumFramesToRender: format.maximumFramesPerSlice,
                latencySeconds: 0,
                tailTimeSeconds: 0,
                supportsFullState: false,
                supportsHostBypass: true
            ),
            capturedFullState: nil,
            stateRestored: false,
            stateRecaptured: false,
            initialRender: metrics,
            postResetRender: metrics,
            latencyStableAcrossReset: true,
            tailStableAcrossReset: true,
            renderResourcesReleased: true
        )
    }

    /// E23 T1b: replaces `testStereoPlaybackSystemSplitMatchesLegacyWrapperWithoutRack`, which compared the render kernel's
    /// split playback/system entry points with its one-call wrapper (the kernel against itself, so it is retired with the
    /// kernel API). Its subject was that the rack seam between the two halves adds nothing. The graph twin: a stereo graph
    /// with crossfeed and balance and the rack's EXTERNAL stage bound to a gain rack renders the plain graph scaled by the
    /// rack's gain (the chain after the seam is linear at this level), so the seam is exact at unity and carries the rack's
    /// audio at 0.5. The rack runs inside the graph (calls counted, no faults).
    func testStereoGraphRackSeamIsTransparentAtUnityAndCarriesTheRackGain() throws {
        let process: N60AudioUnitLiveRackProcessFunction = { context, input, output, frames, channels, _ in
            let gain = context!.assumingMemoryBound(to: Float.self).pointee
            for i in 0..<Int(frames * channels) { output[i] = input[i] * gain }
            return true
        }
        let block = 512
        for rate in [44_100.0, 48_000, 96_000, 192_000, 384_000] {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerCrossfeed(&snapshot, 0.2, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetSymmetryBalance(&snapshot, -0.25, true))
            var forGraph = snapshot
            let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &forGraph, sampleRate: rate))
            let plainSpec = try configuration.makeSpec()
            let frames = 4 * block
            let input: [[Float]] = [
                (0..<frames).map { Float(0.21 * sin(Double($0) * 0.031)) },
                (0..<frames).map { Float(0.17 * cos(Double($0) * 0.047)) },
            ]
            func render(_ host: UnifiedGraphHost) throws -> [[Float]] {
                var out: [[Float]] = [[], []]
                for position in stride(from: 0, to: frames, by: block) {
                    let r = try host.processOffline(input: input.map { Array($0[position..<position + block]) }, frames: block)
                    out[0] += r[0]; out[1] += r[1]
                }
                return out
            }
            let plain = try render(try UnifiedGraphHost(spec: plainSpec))
            XCTAssertGreaterThan(plain[0].map { abs($0) }.max() ?? 0, 0.05, "signal present, rate \(rate)")
            for gain: Float in [1.0, 0.5] {
                let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(65_536))
                let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
                pointer.pointee = gain
                defer { pointer.deallocate() }
                let processor = N60AudioUnitLiveRackProcessor(
                    context: UnsafeMutableRawPointer(pointer), process: process, faultLatch: nil,
                    channelCount: 2, maximumFramesPerSlice: UInt32(block), latencyFrames: 0)
                XCTAssertTrue(N60RealtimeAudioBridgeConfigureAudioUnitRack(bridge, processor))
                let host = try UnifiedGraphHost(spec: plainSpec.insertingExternalRackStage(latencyFrames: 0))
                let raw = try XCTUnwrap(host.rawGraph)
                XCTAssertTrue(N60RealtimeAudioBridgeBindRackToGraph(bridge, raw))
                defer {
                    N60RealtimeAudioBridgeUnbindRackFromGraph(bridge, raw)
                    N60RealtimeAudioBridgeDestroy(bridge)
                }
                let racked = try render(host)
                var calls: UInt64 = 0, faults: UInt64 = 0
                n60_graph_external_stats(OpaquePointer(raw), &calls, &faults)
                XCTAssertGreaterThan(calls, 0, "the rack ran inside the graph, rate \(rate) gain \(gain)")
                XCTAssertEqual(faults, 0, "rate \(rate) gain \(gain)")
                for lane in 0..<2 {
                    var worst: Float = 0
                    for (a, b) in zip(plain[lane], racked[lane]) { worst = max(worst, abs(a * gain - b)) }
                    XCTAssertLessThan(worst, 1e-5, "rack seam, lane \(lane) rate \(rate) gain \(gain)")
                }
            }
        }
    }
}

private final class PR84InjectedHealthStage:
    AudioUnitLiveRackStageProcessing {
    let slotIndex: Int
    let component: AudioUnitComponentIdentity?
    let latencyFrames: Int
    let issue: AudioUnitLiveRackControlPlaneIssue?

    init(
        slotIndex: Int,
        component: AudioUnitComponentIdentity?,
        latencyFrames: Int,
        issue: AudioUnitLiveRackControlPlaneIssue?
    ) {
        self.slotIndex = slotIndex
        self.component = component
        self.latencyFrames = latencyFrames
        self.issue = issue
    }

    func controlPlaneHealthIssue()
        -> AudioUnitLiveRackControlPlaneIssue? {
        issue
    }

    func process(
        inputInterleaved: UnsafePointer<Float>,
        outputInterleaved: UnsafeMutablePointer<Float>,
        frameCount: Int,
        channelCount: Int,
        sampleTime: Double
    ) -> AudioUnitLiveRackStageResult {
        _ = sampleTime
        memcpy(
            outputInterleaved,
            inputInterleaved,
            frameCount * channelCount * MemoryLayout<Float>.size
        )
        return .success
    }
}



private struct PR84LiveMockCatalog: AudioUnitComponentCataloging {
    let components: [AudioUnitComponentDescriptor]

    func discoverEffects() -> [AudioUnitComponentDescriptor] {
        components
    }
}

private struct PR84LiveFixedBackend: AudioUnitOfflinePreparing {
    let report: AudioUnitOfflinePreparationReport

    func prepare(
        component: AudioUnitComponentDescriptor,
        format: AudioUnitRackProcessingFormat,
        restoringState: Data?
    ) async throws -> AudioUnitOfflinePreparationReport {
        _ = component
        _ = format
        _ = restoringState
        return report
    }
}
