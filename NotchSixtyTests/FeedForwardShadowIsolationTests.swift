import CoreAudio
import XCTest
@testable import NotchSixty

/// The feed-forward Quiet Zone deadline bridge is a diagnostic shadow: it runs
/// a preview anti-noise FIR and schedules hypothetical output frames, but it has
/// no path to the speakers. Live ANC is only permitted through its written
/// authorisation path, so running the shadow must leave live output untouched.
///
/// Today the shadow holds no handle to the live bridge and neither side shares
/// mutable globals, so this is a regression guard: it fails if a later change
/// gives the shadow any route (a shared handle, a global, a callback) into the
/// stereo output IOProc, or lets it report itself as connected or qualified,
/// including after a fault halts it.
final class FeedForwardShadowIsolationTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]
    private static let maximumShadowSampleRate = 192_000.0

    private let block = 256
    private let blocks = 96
    private let leftTaps: [Float] = [0.01, 0.01, -0.005]
    private let rightTaps: [Float] = [0.008, -0.004, 0.002]

    func testShadowPathNeverChangesLiveOutput() throws {
        for rate in Self.standardSampleRates {
            try assertShadowIsolation(sampleRate: rate)
        }
    }

    private func plan(sampleRate: Double) -> N60FFDeadlinePlan {
        var plan = N60FFDeadlinePlan()
        plan.routeLeaseToken = 0xA11CE
        plan.synchronizedClockToken = 0xC10C
        plan.sampleRate = sampleRate
        plan.conservativeNoiseLeadSeconds = 0.025
        plan.referenceAcquisitionSeconds = 0.001
        plan.processingSeconds = 0.001
        plan.commandToSeatSeconds = 0.002
        plan.totalSafetyGuardSeconds = 0.002
        return plan
    }

    private func assertShadowIsolation(sampleRate: Double) throws {
        var deadlinePlan = plan(sampleRate: sampleRate)
        let shadow = N60FFDeadlineBridgeCreate(2_048, &deadlinePlan, leftTaps, rightTaps, UInt32(leftTaps.count))
        defer { if let shadow { N60FFDeadlineBridgeDestroy(shadow) } }
        guard sampleRate <= Self.maximumShadowSampleRate else {
            // The shadow scheduler is not available above 192 kHz; it must
            // refuse to start rather than run with an unchecked plan.
            XCTAssertNil(shadow, "\(sampleRate) Hz: shadow plan accepted above its validated range")
            return
        }
        let shadowBridge = try XCTUnwrap(shadow, "\(sampleRate) Hz: valid shadow plan rejected")

        let baseline = try makeLiveBridge(sampleRate: sampleRate)
        let withShadow = try makeLiveBridge(sampleRate: sampleRate)
        defer {
            N60RealtimeAudioBridgeDestroy(baseline.bridge)
            N60RealtimeAudioBridgeDestroy(withShadow.bridge)
        }

        let hostStart = 100.0
        var referenceFrame = 0
        var records = [N60FFDeadlineRecord](repeating: N60FFDeadlineRecord(), count: 512)
        var drained = 0
        var mismatchedSamples = 0
        var renderedSamples = 0
        var livePeak: Float = 0

        for index in 0..<(blocks + 2) {
            let program = (0..<block).map { frame -> Float in
                Float(0.5 * sin(Double(index * block + frame) * 2 * Double.pi * 997 / sampleRate))
            }
            baseline.capture(program)
            withShadow.capture(program)

            // Shadow: one deadline evaluation per reference frame, then drain
            // the diagnostic records as the control plane would.
            for _ in 0..<block {
                let acoustic = hostStart + Double(referenceFrame) / sampleRate
                var reference = N60FFDeadlineReference()
                reference.referenceFrame = Double(referenceFrame)
                reference.acousticAtHostSeconds = acoustic
                reference.availableAtHostSeconds = acoustic + 0.0005
                reference.evaluatedAtHostSeconds = acoustic + 0.0006
                reference.referenceSample = Float(0.2 * sin(Double(referenceFrame) * 2 * Double.pi * 60 / sampleRate))
                var witness = N60FFDeadlineOutputWitness()
                witness.routeLeaseToken = deadlinePlan.routeLeaseToken
                witness.synchronizedClockToken = deadlinePlan.synchronizedClockToken
                witness.sampleRate = sampleRate
                witness.firstFrame = Double(referenceFrame)
                witness.firstFrameHostSeconds = acoustic
                witness.witnessedAtSeconds = acoustic
                XCTAssertTrue(
                    N60FFDeadlineBridgeProcess(shadowBridge, &reference, &witness),
                    "\(sampleRate) Hz: shadow halted at frame \(referenceFrame)"
                )
                referenceFrame += 1
            }
            drained += Int(records.withUnsafeMutableBufferPointer {
                N60FFDeadlineBridgeRead(shadowBridge, $0.baseAddress!, UInt32($0.count))
            })

            guard index >= 2 else { continue } // two blocks of pre-roll fill the gate
            let expected = baseline.render(frames: block)
            let actual = withShadow.render(frames: block)
            renderedSamples += expected.count
            livePeak = max(livePeak, expected.map(abs).max() ?? 0)
            mismatchedSamples += zip(expected, actual).filter { $0.bitPattern != $1.bitPattern }.count
        }

        let snapshot = N60FFDeadlineBridgeGetSnapshot(shadowBridge)
        XCTAssertFalse(snapshot.outputConnected, "\(sampleRate) Hz")
        XCTAssertFalse(snapshot.liveANCQualified, "\(sampleRate) Hz")
        XCTAssertFalse(snapshot.halted, "\(sampleRate) Hz: fault \(snapshot.firstFault)")
        // The shadow really ran a non-zero preview FIR on every frame.
        XCTAssertEqual(snapshot.acceptedRecords, UInt64(referenceFrame), "\(sampleRate) Hz")
        XCTAssertEqual(drained, referenceFrame, "\(sampleRate) Hz")
        XCTAssertGreaterThan(snapshot.maximumObservedStereoSumMicro, 0, "\(sampleRate) Hz: preview FIR produced silence")
        XCTAssertEqual(mismatchedSamples, 0, "\(sampleRate) Hz: running shadow changed live output")

        // Fault the shadow, run its simulated fade to bypass, and keep
        // rendering: a halted shadow must not touch live output either.
        N60FFDeadlineBridgeStop(shadowBridge)
        var reference = N60FFDeadlineReference()
        var witness = N60FFDeadlineOutputWitness()
        XCTAssertFalse(N60FFDeadlineBridgeProcess(shadowBridge, &reference, &witness), "\(sampleRate) Hz")
        for _ in 0..<8 {
            XCTAssertTrue(N60FFDeadlineBridgeAdvanceFaultFade(shadowBridge, UInt32(block / 8)))
            let program = (0..<block).map { Float(0.25 * sin(Double($0) * 0.031)) }
            baseline.capture(program)
            withShadow.capture(program)
            let expected = baseline.render(frames: block)
            let actual = withShadow.render(frames: block)
            mismatchedSamples += zip(expected, actual).filter { $0.bitPattern != $1.bitPattern }.count
        }
        let halted = N60FFDeadlineBridgeGetSnapshot(shadowBridge)
        XCTAssertTrue(halted.halted, "\(sampleRate) Hz")
        XCTAssertTrue(halted.simulatedBypassReached, "\(sampleRate) Hz")
        XCTAssertFalse(halted.outputConnected, "\(sampleRate) Hz: halted shadow reports a live output")
        XCTAssertFalse(halted.liveANCQualified, "\(sampleRate) Hz: halted shadow reports live ANC qualification")

        XCTAssertEqual(mismatchedSamples, 0, "\(sampleRate) Hz: shadow path changed live output")
        XCTAssertEqual(renderedSamples, blocks * block * 2)
        XCTAssertGreaterThan(livePeak, 0.25, "\(sampleRate) Hz: live path rendered no program")
    }

    private func makeLiveBridge(sampleRate: Double) throws -> InterleavedStereoIOProcHarness {
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(4_096))
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, N60DSPGraphSnapshotMakeUnity(sampleRate)))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, UInt32(2 * block), 64)
        return InterleavedStereoIOProcHarness(bridge: bridge)
    }
}

/// Drives the stereo bridge's capture and output IOProcs with interleaved
/// stereo buffers and returns both rendered channels.
private final class InterleavedStereoIOProcHarness {
    let bridge: OpaquePointer

    init(bridge: OpaquePointer) {
        self.bridge = bridge
    }

    func capture(_ mono: [Float]) {
        var samples = mono.flatMap { [$0, -0.5 * $0] }
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unusedOutput = AudioBufferList()
            var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
            _ = N60CaptureIOProc(
                0, &now, &list, &inputTime, &unusedOutput, &outputTime,
                UnsafeMutableRawPointer(bridge)
            )
        }
    }

    func render(frames: Int) -> [Float] {
        var samples = [Float](repeating: -1, count: frames * 2)
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 2,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unusedInput = AudioBufferList()
            var now = AudioTimeStamp(), inputTime = AudioTimeStamp(), outputTime = AudioTimeStamp()
            _ = N60OutputIOProc(
                0, &now, &unusedInput, &inputTime, &list, &outputTime,
                UnsafeMutableRawPointer(bridge)
            )
        }
        return samples
    }
}
