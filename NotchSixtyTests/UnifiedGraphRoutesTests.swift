import XCTest
import CoreAudio
@testable import NotchSixty

/// E6 S8e: the AU rack (the graph's EXTERNAL stage, hosted by the bridge) and the same-device and
/// aggregate output-map routes render through libn60core the way the kernel renders them, at every
/// standard rate. The kernel is the reference: two real bridges get the same snapshot, rack and map,
/// one renders through the graph, and the settled outputs are compared.
final class UnifiedGraphRoutesTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private static let block = 256

    private func snapshot(rate: Double) -> N60DSPGraphSnapshot {
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
            &s, 0, UInt8(N60_EQ_CHANNEL_LEFT), N60BiquadFilterTypePeaking, 1_000, 6, 1.0, true))
        XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
            &s, 1, UInt8(N60_EQ_CHANNEL_RIGHT), N60BiquadFilterTypeHighShelf, 4_000, -4, 0.707, true))
        return s
    }

    /// A test rack: scales every sample by the float behind `context`.
    private static let gainProcess: N60AudioUnitLiveRackProcessFunction = { context, input, output, frames, channels, _ in
        let gain = context!.assumingMemoryBound(to: Float.self).pointee
        for i in 0..<Int(frames * channels) { output[i] = input[i] * gain }
        return true
    }

    private struct Rig {
        var bridge: OpaquePointer
        var host: UnifiedGraphHost?
        var gain: UnsafeMutablePointer<Float>?
    }

    private func makeRig(
        rate: Double, rackGain: Float?, outputMap: (channels: UInt32, routes: [(N60SpeakerOutputBus, UInt32)])?,
        throughGraph: Bool
    ) throws -> Rig {
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(262_144))
        var s = snapshot(rate: rate)
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, s))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0, 0)
        var gainPointer: UnsafeMutablePointer<Float>?
        if let rackGain {
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: 1)
            pointer.pointee = rackGain
            gainPointer = pointer
            let processor = N60AudioUnitLiveRackProcessor(
                context: UnsafeMutableRawPointer(pointer), process: Self.gainProcess, faultLatch: nil,
                channelCount: 2, maximumFramesPerSlice: 512, latencyFrames: 0)
            XCTAssertTrue(N60RealtimeAudioBridgeConfigureAudioUnitRack(bridge, processor))
        }
        if let outputMap {
            let descriptors = outputMap.routes.map { bus, channel -> N60SpeakerOutputRouteDescriptor in
                var d = N60SpeakerOutputRouteDescriptor()
                d.bus = bus
                d.physicalChannelIndex = channel
                return d
            }
            var map = N60SameDeviceOutputMap()
            XCTAssertTrue(descriptors.withUnsafeBufferPointer {
                N60SameDeviceOutputMapCompile(outputMap.channels, $0.baseAddress!, UInt32($0.count), &map)
            })
            XCTAssertTrue(N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, map))
        }
        var host: UnifiedGraphHost?
        if throughGraph {
            let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: rate))
            var spec = try configuration.makeSpec()
            if rackGain != nil { spec = spec.insertingExternalRackStage(latencyFrames: 0) }
            let built = try UnifiedGraphHost(spec: spec)
            host = built
            let raw = try XCTUnwrap(built.rawGraph)
            if rackGain != nil { XCTAssertTrue(N60RealtimeAudioBridgeBindRackToGraph(bridge, raw)) }
            N60RealtimeAudioBridgeSetUnifiedGraphLatency(bridge, built.latencyFrames)
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, raw, 512, rate))
        }
        return Rig(bridge: bridge, host: host, gain: gainPointer)
    }

    private func destroy(_ rig: Rig) {
        N60RealtimeAudioBridgeReleaseUnifiedGraph(rig.bridge)
        if rig.host != nil { N60RealtimeAudioBridgeUnbindRackFromGraph(rig.bridge, rig.host?.rawGraph) }
        N60RealtimeAudioBridgeDestroy(rig.bridge)
        rig.gain?.deallocate()
    }

    /// Drives `blocks` capture + output callbacks and returns the final `keep` blocks of every output channel.
    private func drive(
        _ bridge: OpaquePointer, rate: Double, blocks: Int, outputChannels: Int, keep: Int = 2
    ) -> [[Float]] {
        let frames = Self.block
        var input = [Float](repeating: 0, count: frames * 2)
        var output = [Float](repeating: 0, count: frames * outputChannels)
        var kept = [[Float]](repeating: [], count: outputChannels)
        for b in 0..<blocks {
            for i in 0..<frames {
                let t = Double(b * frames + i)
                input[i * 2] = Float(0.25 * sin(2.0 * .pi * 1_000.0 * t / rate) + 0.1 * sin(2.0 * .pi * 310.0 * t / rate))
                input[i * 2 + 1] = Float(0.2 * sin(2.0 * .pi * 1_700.0 * t / rate))
            }
            input.withUnsafeMutableBytes { inBytes in
                output.withUnsafeMutableBytes { outBytes in
                    var inList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress))
                    var outList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: UInt32(outputChannels), mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress))
                    var stamp = AudioTimeStamp()
                    stamp.mFlags = .sampleTimeValid
                    stamp.mSampleTime = Double(b * frames)
                    _ = N60CaptureIOProc(0, &stamp, &inList, &stamp, &outList, &stamp, UnsafeMutableRawPointer(bridge))
                    _ = N60OutputIOProc(0, &stamp, &inList, &stamp, &outList, &stamp, UnsafeMutableRawPointer(bridge))
                }
            }
            if b >= blocks - keep {
                for c in 0..<outputChannels { kept[c] += (0..<frames).map { output[$0 * outputChannels + c] } }
            }
        }
        return kept
    }

    private func settleBlocks(_ rate: Double) -> Int { Int(rate * 0.3 / Double(Self.block)) + 12 }

    private func assertMatch(_ a: [[Float]], _ b: [[Float]], channels: [Int], _ label: String) {
        for c in channels {
            var worst: Float = 0
            var peak: Float = 0
            for (x, y) in zip(a[c], b[c]) {
                worst = max(worst, abs(x - y))
                peak = max(peak, abs(x))
            }
            XCTAssertGreaterThan(peak, 0.01, "\(label): channel \(c) carries signal")
            XCTAssertLessThan(worst, 0.004 * max(peak, 0.05) + 1e-4, "\(label): channel \(c)")
        }
    }

    // MARK: Rack

    func testRackRouteThroughTheGraphMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            for gain: Float in [1.0, 0.5] {
                let reference = try makeRig(rate: rate, rackGain: gain, outputMap: nil, throughGraph: false)
                let candidate = try makeRig(rate: rate, rackGain: gain, outputMap: nil, throughGraph: true)
                defer { destroy(reference); destroy(candidate) }
                let blocks = settleBlocks(rate)
                let expected = drive(reference.bridge, rate: rate, blocks: blocks, outputChannels: 2)
                let got = drive(candidate.bridge, rate: rate, blocks: blocks, outputChannels: 2)
                XCTAssertGreaterThan(N60RealtimeAudioBridgeUnifiedGraphMix(candidate.bridge), 0.999, "rate \(rate)")
                assertMatch(expected, got, channels: [0, 1], "rack gain \(gain), rate \(rate)")
                var calls: UInt64 = 0, faults: UInt64 = 0
                n60_graph_external_stats(candidate.host?.rawGraph.map { OpaquePointer($0) }, &calls, &faults)
                XCTAssertGreaterThan(calls, 0, "the rack ran inside the graph, rate \(rate)")
                XCTAssertEqual(faults, 0, "rate \(rate)")
            }
        }
    }

    func testRackStageDeclaresItsLatencyAndSitsAtTheKernelSeam() throws {
        for rate in Self.rates {
            var s = snapshot(rate: rate)
            let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: rate))
            let plain = try configuration.makeSpec()
            let racked = plain.insertingExternalRackStage(latencyFrames: 96)
            XCTAssertEqual(racked.stages.count, plain.stages.count + 1)
            let host = try UnifiedGraphHost(spec: racked)
            let base = try UnifiedGraphHost(spec: plain)
            XCTAssertEqual(host.latencyFrames, base.latencyFrames + 96, "rate \(rate)")
            let index = try XCTUnwrap(racked.stages.firstIndex { $0.kind == N60_STAGE_EXTERNAL.rawValue })
            XCTAssertEqual(racked.stages[index - 1].kind, N60_STAGE_METER_OUT.rawValue, "after the post-EQ meter")
        }
    }

    // MARK: Same-device and aggregate output maps

    func testSameDeviceRouteThroughTheGraphMatchesTheKernelAtEveryRate() throws {
        let routes: [(N60SpeakerOutputBus, UInt32)] = [
            (N60SpeakerOutputBusLeftFullRange, 0), (N60SpeakerOutputBusRightFullRange, 1),
        ]
        for rate in Self.rates {
            let reference = try makeRig(rate: rate, rackGain: nil, outputMap: (8, routes), throughGraph: false)
            let candidate = try makeRig(rate: rate, rackGain: nil, outputMap: (8, routes), throughGraph: true)
            defer { destroy(reference); destroy(candidate) }
            let blocks = settleBlocks(rate)
            let expected = drive(reference.bridge, rate: rate, blocks: blocks, outputChannels: 8)
            let got = drive(candidate.bridge, rate: rate, blocks: blocks, outputChannels: 8)
            XCTAssertGreaterThan(N60RealtimeAudioBridgeUnifiedGraphMix(candidate.bridge), 0.999, "rate \(rate)")
            assertMatch(expected, got, channels: [0, 1], "same-device, rate \(rate)")
            for c in 2..<8 { XCTAssertEqual(got[c].map { abs($0) }.max() ?? 0, 0, "unrouted channel \(c), rate \(rate)") }
        }
    }

    func testAggregateRouteThroughTheGraphMatchesTheKernelAtEveryRate() throws {
        // An aggregate maps the buses onto non-contiguous channels of a wider device.
        let routes: [(N60SpeakerOutputBus, UInt32)] = [
            (N60SpeakerOutputBusLeftFullRange, 5), (N60SpeakerOutputBusRightFullRange, 2),
        ]
        for rate in Self.rates {
            let reference = try makeRig(rate: rate, rackGain: nil, outputMap: (12, routes), throughGraph: false)
            let candidate = try makeRig(rate: rate, rackGain: nil, outputMap: (12, routes), throughGraph: true)
            defer { destroy(reference); destroy(candidate) }
            let blocks = settleBlocks(rate)
            let expected = drive(reference.bridge, rate: rate, blocks: blocks, outputChannels: 12)
            let got = drive(candidate.bridge, rate: rate, blocks: blocks, outputChannels: 12)
            XCTAssertGreaterThan(N60RealtimeAudioBridgeUnifiedGraphMix(candidate.bridge), 0.999, "rate \(rate)")
            assertMatch(expected, got, channels: [5, 2], "aggregate, rate \(rate)")
        }
    }

    func testSameDeviceRouteWithARackRendersThroughTheGraph() throws {
        let routes: [(N60SpeakerOutputBus, UInt32)] = [
            (N60SpeakerOutputBusLeftFullRange, 0), (N60SpeakerOutputBusRightFullRange, 1),
        ]
        for rate in [48_000.0, 96_000.0, 384_000.0] {
            let reference = try makeRig(rate: rate, rackGain: 0.5, outputMap: (8, routes), throughGraph: false)
            let candidate = try makeRig(rate: rate, rackGain: 0.5, outputMap: (8, routes), throughGraph: true)
            defer { destroy(reference); destroy(candidate) }
            let blocks = settleBlocks(rate)
            let expected = drive(reference.bridge, rate: rate, blocks: blocks, outputChannels: 8)
            let got = drive(candidate.bridge, rate: rate, blocks: blocks, outputChannels: 8)
            assertMatch(expected, got, channels: [0, 1], "same-device with rack, rate \(rate)")
        }
    }

    /// A rack that fails makes the graph output silence for the block and count a fault; the next
    /// healthy block recovers (the kernel route zeroes the output on a rack failure too).
    func testFailingRackSilencesTheGraphBlockAndCountsAFault() throws {
        let rate = 48_000.0
        let rig = try makeRig(rate: rate, rackGain: .nan, outputMap: nil, throughGraph: true)
        defer { destroy(rig) }
        let out = drive(rig.bridge, rate: rate, blocks: settleBlocks(rate), outputChannels: 2)
        XCTAssertTrue(out[0].allSatisfy { $0.isFinite }, "non-finite rack output never reaches the device")
    }
}
