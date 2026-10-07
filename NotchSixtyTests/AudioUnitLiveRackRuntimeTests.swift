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
        var input = [Float](repeating: 0.25, count: 66)
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

    func testStereoPlaybackSystemSplitMatchesLegacyWrapperWithoutRack() {
        guard let wrapperKernel = N60RenderKernelCreate(),
              let splitKernel = N60RenderKernelCreate() else {
            return XCTFail("Unable to allocate stereo render kernels.")
        }
        defer {
            N60RenderKernelDestroy(wrapperKernel)
            N60RenderKernelDestroy(splitKernel)
        }

        var graph = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(
            N60DSPGraphSnapshotSetSpeakerCrossfeed(
                &graph,
                0.2,
                true
            )
        )
        XCTAssertTrue(
            N60DSPGraphSnapshotSetSymmetryBalance(
                &graph,
                -0.25,
                true
            )
        )
        XCTAssertTrue(
            N60RenderKernelPublishSnapshot(wrapperKernel, graph)
        )
        XCTAssertTrue(
            N60RenderKernelPublishSnapshot(splitKernel, graph)
        )

        var splitContext =
            N60RenderKernelBeginRender(splitKernel)
        let totalFrames: UInt32 = 2_048
        for frame in 0..<totalFrames {
            let left = Float(
                0.21 * sin(Double(frame) * 0.031)
            )
            let right = Float(
                0.17 * cos(Double(frame) * 0.047)
            )

            var wrapperLeft: Float = 0
            var wrapperRight: Float = 0
            N60RenderKernelProcessStereoFrame(
                wrapperKernel,
                left,
                right,
                &wrapperLeft,
                &wrapperRight
            )

            var playback = N60StereoPlaybackFrame()
            N60RenderKernelProcessStereoPlaybackFrameInContext(
                splitKernel,
                &splitContext,
                left,
                right,
                &playback
            )
            var splitLeft: Float = 0
            var splitRight: Float = 0
            N60RenderKernelProcessStereoSystemFrameInContext(
                splitKernel,
                &splitContext,
                &playback,
                playback.left,
                playback.right,
                &splitLeft,
                &splitRight
            )

            XCTAssertEqual(splitLeft, wrapperLeft, accuracy: 0.000_001)
            XCTAssertEqual(splitRight, wrapperRight, accuracy: 0.000_001)
        }
        N60RenderKernelEndRender(
            splitKernel,
            &splitContext,
            totalFrames
        )
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

