import XCTest
@testable import NotchSixty

/// Behavioural contracts of the stereo realtime path that used to be guarded by
/// source-text checks: the SPSC ring wraps in FIFO order at any capacity, and
/// optional speaker stages become exactly transparent once disabled.
final class RealtimeStageContractTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]

    // A capacity that is not a multiple of the callback size makes every wrap
    // land mid-block, so the modulo/wrap arithmetic is exercised at each offset.
    func testRingDeliversFramesInOrderAcrossManyWraps() throws {
        let capacity: UInt32 = 1_000
        let block = 128
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(capacity))
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, N60DSPGraphSnapshotMakeUnity(48_000)))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, UInt32(2 * block), 1)
        let harness = StereoIOProcHarness(bridge: bridge)

        func value(_ index: Int) -> Float { Float(index % 37 + 1) * 0.01 }

        harness.capture(frames: block, value: value(0))
        harness.capture(frames: block, value: value(1))
        let blocks = 64 // 8,192 frames: more than eight trips around the ring
        for index in 0..<blocks {
            let output = harness.render(frames: block)
            harness.capture(frames: block, value: value(index + 2))
            guard index > 0 else { continue } // the first block carries the startup fade
            XCTAssertTrue(
                output.allSatisfy { abs($0 - value(index)) <= 1.0e-6 },
                "block \(index) out of order or corrupted: \(output.prefix(3))"
            )
        }
        let snapshot = N60RealtimeAudioBridgeGetSnapshot(bridge)
        XCTAssertEqual(snapshot.underrunFrames, 0)
        XCTAssertGreaterThan(snapshot.deliveredFrames, UInt64(capacity) * 8)
    }

    // Once crossfeed and crosstalk cancellation are switched off and their
    // smoothed amounts settle at zero, the stages are parked: output must be
    // bit-identical to input, with no residue from the head-shadow filter.
    func testDisabledSpeakerStagesBecomeBitTransparentAtEveryRate() throws {
        for sampleRate in Self.standardSampleRates {
            let kernel = try XCTUnwrap(N60RenderKernelCreate())
            defer { N60RenderKernelDestroy(kernel) }

            var enabled = N60DSPGraphSnapshotMakeUnity(sampleRate)
            XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerCrossfeed(&enabled, 0.5, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetCrosstalkCancellation(&enabled, 0.5, 700, true))
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, enabled))
            var left: Float = 0
            var right: Float = 0
            let oneSecond = Int(sampleRate)
            for frame in 0..<(oneSecond / 4) {
                N60RenderKernelProcessStereoFrame(kernel, signal(frame, 0), signal(frame, 1), &left, &right)
            }
            XCTAssertNotEqual(left, signal(oneSecond / 4 - 1, 0), "\(sampleRate) Hz: stages were active")

            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, N60DSPGraphSnapshotMakeUnity(sampleRate)))
            for frame in 0..<oneSecond {
                N60RenderKernelProcessStereoFrame(kernel, signal(frame, 0), signal(frame, 1), &left, &right)
            }
            var mismatches = 0
            for frame in oneSecond..<(oneSecond + 4_096) {
                N60RenderKernelProcessStereoFrame(kernel, signal(frame, 0), signal(frame, 1), &left, &right)
                if left != signal(frame, 0) || right != signal(frame, 1) { mismatches += 1 }
            }
            XCTAssertEqual(mismatches, 0, "\(sampleRate) Hz: disabled stages must be bit-transparent")
        }
    }

    private func signal(_ frame: Int, _ channel: Int) -> Float {
        let phase = Double(frame) * (channel == 0 ? 0.013 : 0.029)
        return Float(0.25 * sin(phase))
    }
}
