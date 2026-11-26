import CoreAudio
import XCTest
@testable import NotchSixty

/// E23 K1c (G38): Virtual Speakers with an Audio Unit rack renders on the unified graph. The rack is the graph's EXTERNAL
/// stage over every program lane (after program gain/EQ/dynamics, before the binaural renderer), called through the
/// N-lane adapter `N60GraphAudioUnitRack`. These tests drive the real binaural bridge (capture and output IOProcs), the
/// real graph and a fake rack (gain plus an integer delay, or a clipper), at the eight standard rates.
@MainActor
final class BinauralGraphRackTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    nonisolated private static let block = 512
    private static let capacity: UInt32 = 65_536

    // MARK: Fake rack

    /// A rack that scales by `gain`, delays by `delay` frames (state carried across calls), optionally clips to ±`clip`
    /// and can fail one call. Interleaved, like an Audio Unit render block.
    private final class FakeRack {
        let channels: Int
        let gain: Float
        let delay: Int
        let clip: Float?
        var failOnCall: Int?
        private(set) var calls = 0
        private(set) var largestSlice = 0
        private(set) var sampleTimes: [Double] = []
        private var history: [Float]
        private var head = 0

        init(channels: Int, gain: Float = 1, delay: Int = 0, clip: Float? = nil, failOnCall: Int? = nil) {
            self.channels = channels
            self.gain = gain
            self.delay = delay
            self.clip = clip
            self.failOnCall = failOnCall
            history = [Float](repeating: 0, count: max(delay, 1) * channels)
        }

        func render(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, frames: Int, time: Double) -> Bool {
            calls += 1
            largestSlice = max(largestSlice, frames)
            sampleTimes.append(time)
            if let failOnCall, calls == failOnCall { return false }
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let index = frame * channels + channel
                    var value = input[index]
                    if delay > 0 {
                        let slot = head * channels + channel
                        let delayed = history[slot]
                        history[slot] = value
                        value = delayed
                    }
                    value *= gain
                    if let clip { value = min(clip, max(-clip, value)) }
                    output[index] = value
                }
                if delay > 0 { head = (head + 1) % delay }
            }
            return true
        }

        func processor(maximumFramesPerSlice: UInt32) -> N60AudioUnitLiveRackProcessor {
            N60AudioUnitLiveRackProcessor(
                context: Unmanaged.passUnretained(self).toOpaque(),
                process: { context, input, output, frames, _, sampleTime in
                    let rack = Unmanaged<FakeRack>.fromOpaque(context!).takeUnretainedValue()
                    return rack.render(input, output, frames: Int(frames), time: sampleTime)
                },
                faultLatch: nil,
                channelCount: UInt32(channels),
                maximumFramesPerSlice: maximumFramesPerSlice,
                latencyFrames: UInt64(delay)
            )
        }
    }

    // MARK: Fixture

    private struct Program {
        let identifier: N60ProgramLayoutIdentifier
        let layoutId: UInt32
        let labels: [AudioChannelLabel]
        var channels: Int { labels.count }
    }

    private static let stereo = Program(
        identifier: N60ProgramLayoutStereo, layoutId: UInt32(N60_LAYOUT_STEREO.rawValue),
        labels: [kAudioChannelLabel_Left, kAudioChannelLabel_Right])
    private static let fiveOne = Program(
        identifier: N60ProgramLayoutFiveOne, layoutId: UInt32(N60_LAYOUT_5_1.rawValue),
        labels: [
            kAudioChannelLabel_Left, kAudioChannelLabel_Right, kAudioChannelLabel_Center,
            kAudioChannelLabel_LFEScreen, kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        ])

    private var hosts: [UnifiedGraphHost] = []
    private var bridges: [UnsafeMutablePointer<N60BinauralHeadphoneBridge>] = []

    override func tearDown() {
        // Bridges first (the rack adapter clears its callback), then the graphs they pointed at.
        bridges.forEach { N60BinauralHeadphoneBridgeDestroy($0) }
        bridges.removeAll()
        hosts.forEach { $0.release() }
        hosts.removeAll()
        super.tearDown()
    }

    /// Responses for `orientations` sets: set o, channel c, ear e has one tap of `0.4 * (1 + 0.5 * o * ±1)`.
    private func responses(_ program: Program, taps: Int, orientations: Int) -> [Float] {
        var values = [Float](repeating: 0, count: orientations * program.channels * 2 * taps)
        for orientation in 0..<orientations {
            for channel in 0..<program.channels {
                for ear in 0..<2 {
                    let sign: Float = ear == 0 ? 1 : -1
                    values[((orientation * program.channels + channel) * 2 + ear) * taps] =
                        0.4 * (1 + 0.5 * Float(orientation) * sign)
                }
            }
        }
        return values
    }

    private func baseSpec(_ program: Program, rate: Double, orientations: Int = 1, gain: Float = 1) throws -> UnifiedGraphSpec {
        let taps: UInt32 = 4
        let spec = try UnifiedGraphTranslator.layoutSpec(
            layoutIdentifier: program.layoutId, sampleRate: rate,
            binaural: UnifiedGraphTranslator.BinauralProfile(
                taps: taps, orientations: UInt32(orientations), yawStartDeg: orientations > 1 ? -30 : 0,
                yawStepDeg: orientations > 1 ? 30 : 0, wrap: 0, equalEarChannel: -1,
                responses: responses(program, taps: Int(taps), orientations: orientations)),
            protection: false)
        switch UnifiedGraphTranslator.binauralApplyProgram(
            base: spec, programDSP: nil, programGain: gain, outputProtection: nil) {
        case .success(let applied): return applied
        case .failure(let reason): throw XCTSkip("binaural base spec refused: \(reason)")
        }
    }

    /// A real binaural bridge (the same one the session builds), with an optional rack, attached to a graph of `spec`.
    private func makeBridge(
        _ program: Program, rate: Double, spec: UnifiedGraphSpec, rack: FakeRack? = nil, rackSlice: UInt32 = 8_192,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> (UnsafeMutablePointer<N60BinauralHeadphoneBridge>, UnifiedGraphHost) {
        let layout = N60ProgramChannelLayoutMakeStandard(program.identifier)
        var descriptor = N60BinauralProfileDescriptor()
        descriptor.sampleRate = rate
        descriptor.programLayout = layout
        descriptor.kind = N60BinauralProfileKindHRTF
        descriptor.lfeMode = N60BinauralLFEModeEqualEar
        descriptor.tapCount = 4
        withUnsafeMutableBytes(of: &descriptor.sources) { raw in
            let sources = raw.bindMemory(to: N60BinauralSourcePosition.self)
            withUnsafeBytes(of: layout.channels) { roles in
                let roleValues = roles.bindMemory(to: N60ProgramChannelRole.self)
                for index in 0..<Int(layout.channelCount) {
                    sources[index] = N60BinauralDefaultPositionForRole(roleValues[index])
                }
            }
        }
        let descriptions = program.labels.map {
            AudioChannelDescription(mChannelLabel: $0, mChannelFlags: [], mCoordinates: (0, 0, 0))
        }
        var inputMap = N60ProgramInputMap()
        XCTAssertTrue(descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), layout, &inputMap)
        }, file: file, line: line)
        let irs = [Float](repeating: 0, count: program.channels * 4)
        var protection = N60ProtectionSnapshotMakeBypassed(rate)
        XCTAssertTrue(N60ProtectionSnapshotIsValid(&protection), file: file, line: line)
        let created: UnsafeMutablePointer<N60BinauralHeadphoneBridge>? = irs.withUnsafeBufferPointer { ir in
            N60BinauralHeadphoneBridgeCreate(
                Self.capacity, inputMap, descriptor, ir.baseAddress!, ir.baseAddress!,
                N60HeadphoneDSPSnapshotMakeUnity(rate), protection, 1, 1, 1)
        }
        let bridge = try XCTUnwrap(created, file: file, line: line)
        bridges.append(bridge)
        var startSpec = spec
        if let rack {
            XCTAssertTrue(N60BinauralHeadphoneBridgeConfigureAudioUnitRack(
                bridge, rack.processor(maximumFramesPerSlice: rackSlice)), file: file, line: line)
            startSpec = try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: spec, latencyFrames: rack.delay, laneCount: program.channels)
        }
        switch CoreAudioBinauralHeadphoneTransportSession.makeUnifiedGraph(
            spec: startSpec, bridge: bridge, sampleRate: rate, laneCount: program.channels,
            outputBufferFrames: UInt32(spec.maxBlockFrames)) {
        case .success(let host):
            hosts.append(host)
            return (bridge, host)
        case .failure(let reason):
            throw XCTSkip("graph refused: \(reason) at \(rate)")
        }
    }

    /// One capture plus one output callback per block; returns the ears. `streams[s][n]` is stream s, frame n.
    private func render(
        _ bridge: UnsafeMutablePointer<N60BinauralHeadphoneBridge>, streams: [[Float]], block: Int = 512,
        sampleTimeStart: Double = 0
    ) -> [[Float]] {
        let channels = streams.count
        let frames = streams[0].count
        var ears: [[Float]] = [[], []]
        var position = 0
        while position < frames {
            let count = min(block, frames - position)
            var input = [Float](repeating: 0, count: count * channels)
            for frame in 0..<count {
                for stream in 0..<channels { input[frame * channels + stream] = streams[stream][position + frame] }
            }
            var stamp = AudioTimeStamp()
            input.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels), mDataByteSize: UInt32(buffer.count * 4),
                        mData: UnsafeMutableRawPointer(buffer.baseAddress)))
                var unused = AudioBufferList()
                _ = N60BinauralHeadphoneCaptureIOProc(
                    0, &stamp, &list, &stamp, &unused, &stamp, UnsafeMutableRawPointer(bridge))
            }
            var out = [Float](repeating: -9, count: count * 2)
            var outputStamp = AudioTimeStamp()
            outputStamp.mFlags = .sampleTimeValid
            outputStamp.mSampleTime = sampleTimeStart + Double(position)
            out.withUnsafeMutableBufferPointer { buffer in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: 2, mDataByteSize: UInt32(buffer.count * 4),
                        mData: UnsafeMutableRawPointer(buffer.baseAddress)))
                var unused = AudioBufferList()
                _ = N60BinauralHeadphoneOutputIOProc(
                    0, &stamp, &unused, &stamp, &list, &outputStamp, UnsafeMutableRawPointer(bridge))
            }
            for frame in 0..<count {
                ears[0].append(out[frame * 2])
                ears[1].append(out[frame * 2 + 1])
            }
            position += count
        }
        return ears
    }

    private func program(_ channels: Int, rate: Double, frames: Int, amplitude: Float = 0.25) -> [[Float]] {
        (0..<channels).map { channel in
            (0..<frames).map { Float(Double(amplitude) * sin(2 * .pi * (190 + 53 * Double(channel)) * Double($0) / rate)) }
        }
    }

    /// The rack's processed program, computed independently of the fake: `gain * x[n - delay]`.
    private func processed(_ streams: [[Float]], gain: Float, delay: Int, clip: Float? = nil) -> [[Float]] {
        streams.map { stream in
            stream.indices.map { index in
                var value = (index >= delay ? stream[index - delay] : 0) * gain
                if let clip { value = min(clip, max(-clip, value)) }
                return value
            }
        }
    }

    private func externalStats(_ host: UnifiedGraphHost) throws -> (calls: UInt64, faults: UInt64) {
        let raw = try XCTUnwrap(host.rawGraph)
        var calls: UInt64 = 0, faults: UInt64 = 0
        n60_graph_external_stats(OpaquePointer(raw), &calls, &faults)
        return (calls, faults)
    }

    private func maxDifference(_ a: [[Float]], _ b: [[Float]]) -> Float {
        var worst: Float = 0
        for (x, y) in zip(a, b) { for (p, q) in zip(x, y) { worst = max(worst, abs(p - q)) } }
        return worst
    }

    // MARK: Tests

    /// Stereo and 5.1 programs at every rate: the ears equal the rack-free graph fed the rack's processed program, the
    /// rack ran once per block with no faults, and its latency is counted once.
    func testRackThroughTheGraphMatchesTheProcessedProgramAndCountsLatencyOnce() throws {
        for rate in Self.rates {
            for program in [Self.stereo, Self.fiveOne] {
                for delay in [64, Int((rate * 0.001).rounded())] {
                    let label = "\(program.channels) ch rate \(rate) delay \(delay)"
                    let spec = try baseSpec(program, rate: rate)
                    let blocks = 6
                    let frames = Self.block * blocks
                    let streams = self.program(program.channels, rate: rate, frames: frames)
                    let rack = FakeRack(channels: program.channels, gain: 0.5, delay: delay)
                    let (racked, rackedHost) = try makeBridge(program, rate: rate, spec: spec, rack: rack)
                    let (plain, plainHost) = try makeBridge(program, rate: rate, spec: spec)
                    let rackedEars = render(racked, streams: streams)
                    let plainEars = render(plain, streams: processed(streams, gain: 0.5, delay: delay))
                    XCTAssertGreaterThan(plainEars[0].map { abs($0) }.max() ?? 0, 0.01, "signal present, \(label)")
                    XCTAssertLessThan(maxDifference(rackedEars, plainEars), 1e-6, label)
                    let stats = try externalStats(rackedHost)
                    XCTAssertEqual(stats.calls, UInt64(blocks), "one rack call per block, \(label)")
                    XCTAssertEqual(stats.faults, 0, label)
                    XCTAssertEqual(rack.calls, blocks, "no slicing at \(Self.block) frames, \(label)")
                    XCTAssertEqual(
                        N60BinauralHeadphoneBridgeGetSnapshot(racked).algorithmicLatencyFrames,
                        N60BinauralHeadphoneBridgeGetSnapshot(plain).algorithmicLatencyFrames + UInt64(delay),
                        "rack latency counted once, \(label)")
                    XCTAssertEqual(
                        UInt64(rackedHost.latencyFrames), UInt64(plainHost.latencyFrames) + UInt64(delay), label)
                }
            }
        }
    }

    /// The rack sees the output of the program gain stage (rank 3, ahead of it) and feeds the binaural renderer: a gain of 4
    /// before a clipper at 0.5 gives the ears of the plain graph fed `clip(4x)`, not `4 * clip(x)`. The stage sits after every
    /// stage of rank below 12.5 and before BINAURAL.
    func testRackSitsAfterTheProgramStagesAndBeforeTheBinauralRenderer() throws {
        for rate in Self.rates {
            let program = Self.fiveOne
            let loud = try baseSpec(program, rate: rate, gain: 4)
            let unity = try baseSpec(program, rate: rate, gain: 1)
            let streams = self.program(program.channels, rate: rate, frames: Self.block * 4, amplitude: 0.4)
            let rack = FakeRack(channels: program.channels, clip: 0.5)
            let (racked, _) = try makeBridge(program, rate: rate, spec: loud, rack: rack)
            let (plain, _) = try makeBridge(program, rate: rate, spec: unity)
            let rackedEars = render(racked, streams: streams)
            let expected = render(plain, streams: processed(streams.map { $0.map { $0 * 4 } }, gain: 1, delay: 0, clip: 0.5))
            let wrongOrder = render(plain, streams: processed(streams, gain: 1, delay: 0, clip: 0.5).map { $0.map { $0 * 4 } })
            XCTAssertLessThan(maxDifference(rackedEars, expected), 1e-6, "gain ahead of the rack, rate \(rate)")
            XCTAssertGreaterThan(maxDifference(rackedEars, wrongOrder), 0.01, "rack not ahead of the gain, rate \(rate)")

            let staged = try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: loud, latencyFrames: 0, laneCount: program.channels)
            let order = staged.stages.map { $0.stageId }
            let rackIndex = try XCTUnwrap(order.firstIndex(of: UnifiedGraphSpec.externalRackStageId))
            XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: N60_LSTAGE_INPUT_GAIN)), rackIndex)
            XCTAssertLessThan(rackIndex, try XCTUnwrap(order.firstIndex(of: N60_LSTAGE_BINAURAL)))
            let rackStage = staged.stages[rackIndex]
            XCTAssertEqual(rackStage.laneMask, (UInt64(1) << UInt64(program.channels)) - 1, "every program lane")
        }
    }

    /// A rack slice of 256 frames against 4,096-frame blocks is bit-identical to an unsliced rack, and each slice is at most
    /// 256 frames with the host sample time advanced by the slice start.
    func testSlicingIsBitIdenticalToAnUnslicedRackAndAdvancesTheSampleTime() throws {
        for rate in Self.rates {
            let program = Self.fiveOne
            let spec = try baseSpec(program, rate: rate)
            let streams = self.program(program.channels, rate: rate, frames: 4_096 * 3)
            let sliced = FakeRack(channels: program.channels, gain: 0.7, delay: 64)
            let whole = FakeRack(channels: program.channels, gain: 0.7, delay: 64)
            let (slicedBridge, slicedHost) = try makeBridge(program, rate: rate, spec: spec, rack: sliced, rackSlice: 256)
            let (wholeBridge, _) = try makeBridge(program, rate: rate, spec: spec, rack: whole, rackSlice: 8_192)
            let slicedEars = render(slicedBridge, streams: streams, block: 4_096, sampleTimeStart: 1_000)
            let wholeEars = render(wholeBridge, streams: streams, block: 4_096)
            XCTAssertEqual(maxDifference(slicedEars, wholeEars), 0, "bit-identical at \(rate)")
            XCTAssertLessThanOrEqual(sliced.largestSlice, 256)
            XCTAssertEqual(sliced.calls, 3 * (4_096 / 256), "rate \(rate)")
            XCTAssertEqual(whole.calls, 3)
            XCTAssertEqual(try externalStats(slicedHost).calls, 3, "the graph calls the adapter once per block")
            XCTAssertEqual(sliced.sampleTimes[0], 1_000, accuracy: 0)
            XCTAssertEqual(sliced.sampleTimes[1], 1_256, accuracy: 0)
            XCTAssertEqual(sliced.sampleTimes[16], 1_000 + 4_096, accuracy: 0)
        }
    }

    /// A rack that fails one block gives a silent block, one fault, and the next block is processed again.
    func testARackFaultSilencesThatBlockAndRecoversOnTheNext() throws {
        for rate in Self.rates {
            let program = Self.fiveOne
            let spec = try baseSpec(program, rate: rate)
            let rack = FakeRack(channels: program.channels, gain: 1, failOnCall: 1)
            let (bridge, host) = try makeBridge(program, rate: rate, spec: spec, rack: rack)
            let ears = render(bridge, streams: self.program(program.channels, rate: rate, frames: Self.block * 4))
            let blockRange = { (index: Int) in (index * Self.block)..<((index + 1) * Self.block) }
            for ear in 0..<2 {
                XCTAssertEqual(ears[ear][blockRange(0)].map { abs($0) }.max() ?? 1, 0, "failed first block is silent, rate \(rate)")
                XCTAssertGreaterThan(ears[ear][blockRange(2)].map { abs($0) }.max() ?? 0, 0.01, "recovers, rate \(rate)")
            }
            let stats = try externalStats(host)
            XCTAssertEqual(stats.calls, 4)
            XCTAssertEqual(stats.faults, 1)
        }
    }

    /// A live gain republish and a head-yaw post keep the stage and the binding: the rack still runs exactly once per block
    /// and the image moves with the pose.
    func testRepublishAndHeadYawKeepTheRackStageAndBinding() throws {
        for rate in Self.rates {
            let program = Self.fiveOne
            let spec = try baseSpec(program, rate: rate, orientations: 3)
            let rack = FakeRack(channels: program.channels, gain: 1)
            let (bridge, host) = try makeBridge(program, rate: rate, spec: spec, rack: rack)
            let raw = try XCTUnwrap(host.rawGraph)
            let streams = self.program(program.channels, rate: rate, frames: Self.block * 8)
            let before = render(bridge, streams: streams)

            // An EQ-style republish (the session re-inserts the stage into the spec it is given).
            let again = try baseSpec(program, rate: rate, orientations: 3, gain: 0.5)
            let republished = try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: again, latencyFrames: 0, laneCount: program.channels)
            _ = try host.apply(republished)
            XCTAssertEqual(host.rawGraph, raw, "same graph, so the adapter stays bound")
            XCTAssertNotNil(host.spec.stages.first { $0.stageId == UnifiedGraphSpec.externalRackStageId })
            let callsBefore = rack.calls
            let halved = render(bridge, streams: streams)
            XCTAssertEqual(rack.calls - callsBefore, 8, "one rack call per block after the republish")
            let lastBlock = { (ear: [Float]) in sqrt(ear.suffix(Self.block).reduce(0) { $0 + $1 * $1 } / Float(Self.block)) }
            XCTAssertLessThan(
                abs(lastBlock(halved[0]) / max(lastBlock(before[0]), 1e-9) - 0.5), 0.1,
                "the republished gain reached the ears")

            _ = try host.setBinauralPose(yaw: 30, pitch: 0, roll: 0)
            let settled = render(bridge, streams: self.program(program.channels, rate: rate, frames: Self.block * 6))
            let tail = settled[0].suffix(Self.block)
            let tailRight = settled[1].suffix(Self.block)
            XCTAssertNotEqual(tail.map { abs($0) }.max() ?? 0, tailRight.map { abs($0) }.max() ?? 0, "image moved, rate \(rate)")
            XCTAssertEqual(try externalStats(host).faults, 0)
            XCTAssertEqual(rack.calls, 8 + 8 + 6, "no second rack call per block")
        }
    }

    /// The session's rack insertion refuses by name: a spec that already has an EXTERNAL stage, and a rack latency over the
    /// graph's delay limit. A plain spec accepts a rack at every rate.
    func testInsertingTheRackRefusesByName() throws {
        for rate in Self.rates {
            let spec = try baseSpec(Self.fiveOne, rate: rate)
            let withRack = try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: spec, latencyFrames: 64, laneCount: 6)
            XCTAssertThrowsError(try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: withRack, latencyFrames: 64, laneCount: 6)) {
                guard case LiveNChannelTransportError.unifiedGraphRejected(let reason) = $0 else {
                    return XCTFail("wrong error \($0)")
                }
                XCTAssertEqual(reason, .externalStageInUse)
            }
            XCTAssertThrowsError(try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: spec, latencyFrames: Int(N60_GRAPH_MAX_DELAY_FRAMES) + 1, laneCount: 6)) {
                guard case CoreAudioTransportError.audioUnitRackConfigurationFailed = $0 else {
                    return XCTFail("wrong error \($0)")
                }
            }
            XCTAssertNoThrow(try CoreAudioBinauralHeadphoneTransportSession.insertingRackStage(
                into: spec, latencyFrames: Int(N60_GRAPH_MAX_DELAY_FRAMES), laneCount: 6))
        }
    }
}
