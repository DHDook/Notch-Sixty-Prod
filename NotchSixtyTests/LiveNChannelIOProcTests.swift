import CoreAudio
import XCTest
@testable import NotchSixty

/// Drives the live N-channel capture and output IOProcs with synthetic buffer
/// lists: semantic input reorder -> lanes -> physical map, at matched rates and
/// through the adaptive SRC.
final class LiveNChannelIOProcTests: XCTestCase {
    private static let standardSampleRates: [Double] = [
        44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000
    ]
    private static let capacityFrames: UInt32 = 16_384
    private static let block = 256

    // The tap delivers channels in a different order from the canonical 5.1
    // layout, so the input map has to reorder them by label.
    private static let streamLabels: [AudioChannelLabel] = [
        kAudioChannelLabel_Left, kAudioChannelLabel_Right,
        kAudioChannelLabel_LeftSurround, kAudioChannelLabel_RightSurround,
        kAudioChannelLabel_Center, kAudioChannelLabel_LFEScreen,
    ]
    // Canonical 5.1 role order: FL FR C LFE SL SR.
    private static let streamToCanonical = [0, 1, 4, 5, 2, 3]
    // Program role k is wired to physical channel 5 - k.
    private static let programPhysicalChannels: [UInt32] = [5, 4, 3, 2, 1, 0]
    private static let lfeInBandGain = Float(pow(10.0, 0.5))

    private func programValue(_ role: Int) -> Float { Float(role + 1) * 0.02 }

    private func expectedPhysical() -> [Float] {
        var expected = [Float](repeating: 0, count: 6)
        for role in 0..<6 {
            let gain: Float = role == 3 ? Self.lfeInBandGain : 1
            expected[Int(Self.programPhysicalChannels[role])] = programValue(role) * gain
        }
        return expected
    }

    func testMatchedRateRoutesEverySemanticChannelToItsPhysicalOutput() throws {
        for sampleRate in Self.standardSampleRates {
            let bridge = try makeBridge(sampleRate: sampleRate, gateFrames: 512)
            defer { N60LiveNChannelBridgeDestroy(bridge) }

            capture(bridge, frames: 512)
            var output: [[Float]] = []
            for _ in 0..<40 {
                output = render(bridge, frames: Self.block)
                capture(bridge, frames: Self.block)
            }
            assertFrame(output[Self.block - 1], matches: expectedPhysical(), "\(sampleRate) Hz")

            let snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
            XCTAssertTrue(snapshot.outputGateOpen, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.renderFailures, 0, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.outputWriteFailures, 0, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.transport.underrunFrames, 0, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.transport.unsupportedBufferLayouts, 0, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.safetyLimiterEngagedSamples, 0, "\(sampleRate) Hz")
            XCTAssertEqual(snapshot.renderedFrames, UInt64(40 * Self.block), "\(sampleRate) Hz")
        }
    }

    func testAdaptiveRateLocksAndPreservesRoutingAcrossRatePairs() throws {
        let pairs: [(input: Double, output: Double)] = [
            (48_000, 96_000), (44_100, 48_000), (192_000, 48_000), (96_000, 384_000),
        ]
        for pair in pairs {
            let label = "\(pair.input) -> \(pair.output) Hz"
            let target: UInt32 = 2_048
            let gate = target + 1_024 + N60_ADAPTIVE_SRC_DEFAULT_TAPS / 2
            let bridge = try makeBridge(sampleRate: pair.output, gateFrames: gate)
            defer { N60LiveNChannelBridgeDestroy(bridge) }
            XCTAssertTrue(
                N60LiveNChannelBridgeConfigureAdaptiveSampleRate(bridge, pair.input, pair.output, target),
                label
            )

            let ratio = pair.input / pair.output
            capture(bridge, frames: Int(gate) + 512)
            var renderedTotal = 0
            var capturedTotal = 0
            var output: [[Float]] = []
            for _ in 0..<300 {
                output = render(bridge, frames: Self.block)
                renderedTotal += Self.block
                let due = Int((Double(renderedTotal) * ratio).rounded()) - capturedTotal
                if due > 0 {
                    capture(bridge, frames: due)
                    capturedTotal += due
                }
            }
            assertFrame(output[Self.block - 1], matches: expectedPhysical(), label, accuracy: 2.0e-3)

            let snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
            XCTAssertTrue(snapshot.adaptiveSampleRateEnabled, label)
            XCTAssertTrue(snapshot.outputGateOpen, label)
            XCTAssertEqual(snapshot.renderFailures, 0, label)
            XCTAssertEqual(snapshot.outputWriteFailures, 0, label)
            XCTAssertGreaterThan(snapshot.adaptiveTransportLatencyFrames, 0, label)
        }
    }

    // MARK: Fixtures

    private func makeBridge(
        sampleRate: Double,
        gateFrames: UInt32
    ) throws -> UnsafeMutablePointer<N60LiveNChannelBridge> {
        let plan = LiveNChannelOutputRoutePlan(
            programLayout: .fiveOne,
            orderedDeviceUIDs: ["interface"],
            referenceDeviceUID: "interface",
            physicalChannelCount: 6,
            programPhysicalChannels: Self.programPhysicalChannels,
            subwooferPhysicalChannels: [],
            subwooferCount: 0,
            bassManagementEnabled: false,
            speakerCalibrations: [:],
            subwooferCalibrations: []
        )
        let graph = try LiveNChannelRenderGraphCompiler.makeGraph(
            routePlan: plan,
            sampleRate: sampleRate,
            gainConfiguration: DSPGainConfiguration(),
            bassManagementConfiguration: BassManagementConfiguration(enabled: false)
        )
        let descriptions = Self.streamLabels.map {
            AudioChannelDescription(
                mChannelLabel: $0,
                mChannelFlags: [],
                mCoordinates: (0, 0, 0)
            )
        }
        var inputMap = N60ProgramInputMap()
        let mapped = descriptions.withUnsafeBufferPointer {
            N60ProgramInputMapCompile($0.baseAddress!, UInt32($0.count), graph.programLayout, &inputMap)
        }
        XCTAssertTrue(mapped)
        return try XCTUnwrap(
            N60LiveNChannelBridgeCreate(Self.capacityFrames, inputMap, graph, gateFrames, 1)
        )
    }

    private func capture(_ bridge: UnsafeMutablePointer<N60LiveNChannelBridge>, frames: Int) {
        var samples = [Float](repeating: 0, count: frames * 6)
        for frame in 0..<frames {
            for stream in 0..<6 {
                samples[frame * 6 + stream] = programValue(Self.streamToCanonical[stream])
            }
        }
        var timestamp = AudioTimeStamp()
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 6,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unused = AudioBufferList()
            _ = N60LiveNChannelCaptureIOProc(
                0, &timestamp, &list, &timestamp, &unused, &timestamp,
                UnsafeMutableRawPointer(bridge)
            )
        }
    }

    private func render(_ bridge: UnsafeMutablePointer<N60LiveNChannelBridge>, frames: Int) -> [[Float]] {
        var samples = [Float](repeating: -1, count: frames * 6)
        var timestamp = AudioTimeStamp()
        samples.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: 6,
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)
                )
            )
            var unused = AudioBufferList()
            _ = N60LiveNChannelOutputIOProc(
                0, &timestamp, &unused, &timestamp, &list, &timestamp,
                UnsafeMutableRawPointer(bridge)
            )
        }
        return (0..<frames).map { Array(samples[($0 * 6)..<($0 * 6 + 6)]) }
    }

    private func assertFrame(
        _ frame: [Float],
        matches expected: [Float],
        _ label: String,
        accuracy: Float = 1.0e-5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for physical in 0..<expected.count {
            XCTAssertEqual(
                frame[physical], expected[physical], accuracy: accuracy,
                "\(label): physical channel \(physical)", file: file, line: line
            )
        }
    }
}
