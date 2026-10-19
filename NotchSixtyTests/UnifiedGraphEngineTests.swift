import XCTest
import CoreAudio
@testable import NotchSixty

/// E6 S8: the Swift control plane publishes engine configurations to libn60core and the
/// graph renders them at every standard rate. Behavioural: real graphs, real audio blocks.
final class UnifiedGraphEngineTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func sine(_ hz: Double, rate: Double, frames: Int, amplitude: Float = 0.25) -> [Float] {
        (0..<frames).map { Float(Double(amplitude) * sin(2.0 * .pi * hz * Double($0) / rate)) }
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    /// Renders `seconds` of input in 512-frame blocks (the graph is stateful) and returns
    /// each output lane's RMS over the final quarter, after ramps and filters have settled.
    private func settledRMS(host: UnifiedGraphHost, inputs: [[Float]], rate: Double) throws -> [Double] {
        let block = 512
        let total = inputs[0].count / block * block
        var out = [[Float]](repeating: [], count: Int(host.outputChannels))
        var position = 0
        while position < total {
            let chunk = inputs.map { Array($0[position..<position + block]) }
            let rendered = try host.processOffline(input: chunk, frames: block)
            for lane in 0..<rendered.count { out[lane] += rendered[lane] }
            position += block
        }
        let start = out[0].count * 3 / 4
        return out.map { rms($0[start...]) }
    }

    private func frames(for rate: Double) -> Int { Int(rate * 0.35) }

    // MARK: Stereo

    func testStereoSnapshotGainRendersAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            snapshot.outputGainLinear = 0.5
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
                "rate \(rate)"
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let tone = sine(1_000, rate: rate, frames: frames(for: rate))
            let levels = try settledRMS(host: host, inputs: [tone, tone], rate: rate)
            let expected = rms(tone[(tone.count * 3 / 4)...]) * 0.5
            for level in levels { XCTAssertEqual(level, expected, accuracy: expected * 0.03, "rate \(rate)") }
        }
    }

    func testStoredEQProfileLoadsAndRendersAtEveryRate() throws {
        let eq = EQConfiguration(bands: [
            EQBand(type: .peaking, frequencyHz: 1_000, gainDB: 6, q: 1.0),
            EQBand(type: .highShelf, frequencyHz: 6_000, gainDB: -3, q: 0.707),
        ])
        for rate in Self.rates {
            var snapshot = try eq.makeGraphSnapshot(
                sampleRate: rate,
                gainConfiguration: DSPGainConfiguration(inputPreampDB: 0, headroomAttenuationDB: -1, outputGainDB: 0)
            )
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
                "rate \(rate)"
            )
            XCTAssertEqual(configuration.lanes[0].eq.count, 2)
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let tone = sine(1_000, rate: rate, frames: frames(for: rate))
            let levels = try settledRMS(host: host, inputs: [tone, tone], rate: rate)
            let inputRMS = rms(tone[(tone.count * 3 / 4)...])
            let expected = inputRMS * pow(10, (6.0 - 1.0) / 20.0)
            for level in levels {
                XCTAssertEqual(level, expected, accuracy: expected * 0.06, "rate \(rate)")
            }
        }
    }

    func testIneligibleSnapshotsKeepTheKernelPath() {
        var snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        snapshot.speakerCrossfeed.enabled = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        snapshot.convolution.enabled = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        snapshot.activeQuietZone.enabled = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
        snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000))
    }

    func testFlagOffLeavesTheKernelPathAlone() throws {
        XCTAssertFalse(FeatureFlag.unifiedGraph.defaultEnabled)
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(4_096))
        defer { N60RealtimeAudioBridgeDestroy(bridge) }
        XCTAssertFalse(N60RealtimeAudioBridgeUnifiedGraphActive(bridge))

        var snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000)
        )
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, host.rawGraph, 4_096, 48_000))
        XCTAssertTrue(N60RealtimeAudioBridgeUnifiedGraphActive(bridge))
        XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, nil, 0, 0))
        XCTAssertFalse(N60RealtimeAudioBridgeUnifiedGraphActive(bridge))
    }

    func testParameterOnlyChangesPostInsteadOfRebuilding() throws {
        var snapshot = N60DSPGraphSnapshotMakeUnity(48_000)
        var configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: 48_000)
        )
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        XCTAssertEqual(try host.apply(try configuration.makeSpec()), .unchanged)
        configuration.lanes[0].outputGain = 0.5
        guard case .posted = try host.apply(try configuration.makeSpec()) else {
            return XCTFail("a gain change should be a live post")
        }
        configuration.lanes[1].eq = [UnifiedGraphPEQSection(type: 0, frequencyHz: 1_000, gainDB: 3, q: 1)]
        XCTAssertEqual(try host.apply(try configuration.makeSpec()), .published)
    }

    // MARK: Multichannel, subs, binaural

    func testSubwooferConfigurationsRenderAtEveryRateAndKeepCombinedLevel() throws {
        for rate in Self.rates {
            var combined: [Int: Double] = [:]
            for subCount in [1, 2, 4] {
                let subs = (0..<subCount).map { _ in UnifiedGraphSubwoofer() }
                let configuration = UnifiedGraphTranslator.multichannelConfiguration(
                    sampleRate: rate, programChannels: 2, subwoofers: subs
                )
                let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
                let channels = 2 + subCount
                let tone = sine(40, rate: rate, frames: Int(rate * 0.6))
                var inputs = [[Float]](repeating: [Float](repeating: 0, count: tone.count), count: channels)
                inputs[0] = tone
                inputs[1] = tone
                let levels = try settledRMS(host: host, inputs: inputs, rate: rate)
                // Coherent sum of the sub lanes (identical signals): N x the per-sub level.
                combined[subCount] = levels[2...].reduce(0, +)
                for lane in 2..<channels {
                    XCTAssertEqual(levels[lane], levels[2], accuracy: levels[2] * 0.001 + 1e-9)
                }
                XCTAssertGreaterThan(levels[2], 0.01, "rate \(rate), subs \(subCount)")
            }
            // The shipping engine splits the redirect 1/N across subs; the sum must not grow.
            let one = try XCTUnwrap(combined[1])
            for subCount in [2, 4] {
                let level = try XCTUnwrap(combined[subCount])
                XCTAssertEqual(level, one, accuracy: one * 0.02, "rate \(rate), subs \(subCount)")
            }
        }
    }

    func testSubCalibrationGainAndPolarityMapOntoBassManagement() throws {
        let rate = 48_000.0
        let reference = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: 2, subwoofers: [UnifiedGraphSubwoofer()]
        )
        var trimmed = reference
        trimmed.bassManagement?.subwoofers[0].gainDB = -6
        trimmed.bassManagement?.subwoofers[0].polarityInverted = true
        let tone = sine(40, rate: rate, frames: Int(rate * 0.6))
        let zeros = [Float](repeating: 0, count: tone.count)
        let a = try UnifiedGraphHost(spec: try reference.makeSpec())
        let b = try UnifiedGraphHost(spec: try trimmed.makeSpec())
        let levelA = try settledRMS(host: a, inputs: [tone, tone, zeros], rate: rate)[2]
        let levelB = try settledRMS(host: b, inputs: [tone, tone, zeros], rate: rate)[2]
        XCTAssertEqual(levelB, levelA * pow(10, -6.0 / 20.0), accuracy: levelA * 0.01)
    }

    func testMultichannelWithLFEAndDelaysRendersAtEveryRate() throws {
        for rate in Self.rates {
            let configuration = UnifiedGraphTranslator.multichannelConfiguration(
                sampleRate: rate, programChannels: 6, lfeLane: 3,
                trimsDB: [0, 0, -2, 0, 1, 1], subwoofers: [UnifiedGraphSubwoofer(), UnifiedGraphSubwoofer()],
                delaysMilliseconds: [0, 0, 2.5, 0, 1, 1]
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            XCTAssertEqual(host.outputChannels, 8)
            let tone = sine(500, rate: rate, frames: frames(for: rate))
            let inputs = [[Float]](repeating: tone, count: 8)
            let levels = try settledRMS(host: host, inputs: inputs, rate: rate)
            for level in levels { XCTAssertTrue(level.isFinite) }
            XCTAssertGreaterThan(levels[0], 0.01, "rate \(rate)")
        }
    }

    func testStandardLayoutsAndBinauralRenderAtEveryRate() throws {
        for rate in Self.rates {
            for identifier in [UInt32(N60_LAYOUT_5_1.rawValue), UInt32(N60_LAYOUT_7_1.rawValue)] {
                let spec = try UnifiedGraphTranslator.layoutSpec(layoutIdentifier: identifier, sampleRate: rate)
                let host = try UnifiedGraphHost(spec: spec)
                let tone = sine(800, rate: rate, frames: frames(for: rate))
                let levels = try settledRMS(
                    host: host,
                    inputs: [[Float]](repeating: tone, count: Int(spec.inputChannels)),
                    rate: rate
                )
                XCTAssertTrue(levels.allSatisfy { $0.isFinite }, "layout \(identifier) rate \(rate)")
                XCTAssertGreaterThan(levels[0], 0.001)
            }
            // Binaural 5.1: an identity-like 4-tap response per channel and ear.
            let channels = 6
            let taps: UInt32 = 4
            var responses = [Float](repeating: 0, count: channels * 2 * Int(taps))
            for channel in 0..<channels { for ear in 0..<2 { responses[(channel * 2 + ear) * Int(taps)] = 0.5 } }
            let spec = try UnifiedGraphTranslator.layoutSpec(
                layoutIdentifier: UInt32(N60_LAYOUT_5_1.rawValue), sampleRate: rate,
                binaural: UnifiedGraphTranslator.BinauralProfile(
                    taps: taps, equalEarChannel: 3, responses: responses
                )
            )
            let host = try UnifiedGraphHost(spec: spec)
            let tone = sine(800, rate: rate, frames: frames(for: rate))
            let levels = try settledRMS(
                host: host,
                inputs: [[Float]](repeating: tone, count: Int(spec.inputChannels)),
                rate: rate
            )
            XCTAssertTrue(levels.allSatisfy { $0.isFinite }, "binaural rate \(rate)")
            XCTAssertGreaterThan(levels[0], 0.001, "binaural rate \(rate)")
            XCTAssertGreaterThan(levels[1], 0.001, "binaural rate \(rate)")
        }
    }

    func testMeteringAndLatencyReadbacksComeFromTheCore() throws {
        let rate = 48_000.0
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate)
        )
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let tone = sine(1_000, rate: rate, frames: 4_096, amplitude: 0.5)
        _ = try host.processOffline(input: [tone, tone], frames: 4_096)
        let meter = try XCTUnwrap(host.meter(stageId: N60_LSTAGE_FINAL_METER, lane: 0))
        XCTAssertEqual(meter.peak, 0.5, accuracy: 0.01)
        XCTAssertEqual(host.latencyFrames, 0)
    }

    // MARK: Hand-over between kernel and graph (S8b1)

    /// Runs `blocks` capture+output callbacks of a 1 kHz tone through the bridge. Returns the
    /// output (left channel) and the largest sample-to-sample step seen, continuing from `state`.
    private struct Driver {
        var position = 0
        var lastLeft: Float = 0
        var maxStep: Float = 0
        var output: [Float] = []
    }

    private func drive(_ bridge: OpaquePointer, rate: Double, blocks: Int, driver: inout Driver) {
        let frames = 256
        var input = [Float](repeating: 0, count: frames * 2)
        var output = [Float](repeating: 0, count: frames * 2)
        for _ in 0..<blocks {
            for i in 0..<frames {
                let v = Float(0.4 * sin(2.0 * .pi * 1_000.0 * Double(driver.position + i) / rate))
                input[i * 2] = v
                input[i * 2 + 1] = v
            }
            driver.position += frames
            input.withUnsafeMutableBytes { inBytes in
                output.withUnsafeMutableBytes { outBytes in
                    var inList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(inBytes.count), mData: inBytes.baseAddress)
                    )
                    var outList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(outBytes.count), mData: outBytes.baseAddress)
                    )
                    var stamp = AudioTimeStamp()
                    _ = N60CaptureIOProc(0, &stamp, &inList, &stamp, &outList, &stamp, UnsafeMutableRawPointer(bridge))
                    _ = N60OutputIOProc(0, &stamp, &inList, &stamp, &outList, &stamp, UnsafeMutableRawPointer(bridge))
                }
            }
            for i in 0..<frames {
                let l = output[i * 2]
                driver.maxStep = max(driver.maxStep, abs(l - driver.lastLeft))
                driver.lastLeft = l
            }
            driver.output = Array(output.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element })
        }
    }

    private func makeBridge(rate: Double, gain: Float) throws -> (OpaquePointer, UnifiedGraphHost) {
        let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(262_144))
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        snapshot.masterGainLinear = gain
        XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot))
        N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0, 0)
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate)
        )
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        return (bridge, host)
    }

    func testAttachAndDetachAreClickFreeAtEveryRate() throws {
        for rate in Self.rates {
            // Kernel and graph render the same unity chain, so any step is the hand-over's.
            let (bridge, host) = try makeBridge(rate: rate, gain: 1)
            defer { N60RealtimeAudioBridgeDestroy(bridge) }
            let settle = Int(rate * 0.2 / 256) + 8
            let slope = Float(0.4 * 2.0 * .pi * 1_000.0 / rate)
            var driver = Driver()
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            driver.maxStep = 0
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, host.rawGraph, 256, rate))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertGreaterThan(N60RealtimeAudioBridgeUnifiedGraphMix(bridge), 0.999, "rate \(rate)")
            XCTAssertLessThan(driver.maxStep, 4 * slope + 1e-4, "attach, rate \(rate)")
            driver.maxStep = 0
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, nil, 0, 0))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertLessThan(N60RealtimeAudioBridgeUnifiedGraphMix(bridge), 0.001, "rate \(rate)")
            XCTAssertLessThan(driver.maxStep, 4 * slope + 1e-4, "detach, rate \(rate)")
            N60RealtimeAudioBridgeReleaseUnifiedGraph(bridge)
        }
    }

    func testBridgeWithNoGraphIsBitIdenticalWhetherOrNotDetachWasCalled() throws {
        let rate = 48_000.0
        let (a, _) = try makeBridge(rate: rate, gain: 0.5)
        let (b, _) = try makeBridge(rate: rate, gain: 0.5)
        defer {
            N60RealtimeAudioBridgeDestroy(a)
            N60RealtimeAudioBridgeDestroy(b)
        }
        _ = N60RealtimeAudioBridgeSetUnifiedGraph(b, nil, 0, 0)
        var da = Driver(), db = Driver()
        for _ in 0..<40 {
            drive(a, rate: rate, blocks: 1, driver: &da)
            drive(b, rate: rate, blocks: 1, driver: &db)
            XCTAssertEqual(da.output, db.output)
        }
        XCTAssertEqual(da.output.map(abs).max() ?? 0, 0.2, accuracy: 0.01)
    }
}
