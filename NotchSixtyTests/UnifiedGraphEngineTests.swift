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
        snapshot.crossover.enabled = true
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

    func testStereoDiagnosticsOverlayComesFromTheGraphAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            snapshot.masterGainLinear = 0.5
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate)
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let tone = sine(1_000, rate: rate, frames: 4_096, amplitude: 0.5)
            _ = try host.processOffline(input: [tone, tone], frames: 4_096)
            var diagnostics = N60RenderKernelDiagnostics()
            diagnostics.latencyFrames = 12_345
            diagnostics.inputMeter.peakLeft = 9
            host.overlayStereoReadbacks(&diagnostics, latencyFrames: 77, includeOutput: true)
            XCTAssertEqual(diagnostics.inputMeter.peakLeft, 0.5, accuracy: 0.01, "input rate \(rate)")
            XCTAssertEqual(diagnostics.inputMeter.peakRight, 0.5, accuracy: 0.01, "input rate \(rate)")
            XCTAssertEqual(diagnostics.postEQMeter.peakLeft, 0.5, accuracy: 0.01, "postEQ rate \(rate)")
            XCTAssertEqual(diagnostics.outputMeter.peakLeft, 0.25, accuracy: 0.01, "output rate \(rate)")
            XCTAssertEqual(diagnostics.latencyFrames, 77)
            // includeOutput false leaves the bridge VU's output reading alone.
            diagnostics.outputMeter.peakLeft = 3
            _ = try host.processOffline(input: [tone, tone], frames: 4_096)
            host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: false)
            XCTAssertEqual(diagnostics.outputMeter.peakLeft, 3)
        }
    }

    /// E6 S8c: gain reduction, true peaks, the guard flag and over-range counts come from the core
    /// at every rate, through the stereo overlay and through `UnifiedGraphDiagnostics`.
    @MainActor
    func testDynamicsReadbacksComeFromTheGraphAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                &snapshot.dynamics, rate, true, -24, 4, 0, 5, 80, 0, N60CompressorTopologyFeedForward, false, 0))
            snapshot.protection.limiterEnabled = true
            snapshot.protection.truePeakGuardEnabled = true
            snapshot.protection.limiterCeilingLinear = 0.5
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate), "rate \(rate)")
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let loud = sine(1_000, rate: rate, frames: Int(rate * 0.3), amplitude: 1.5)
            var block = 0
            while block + 512 <= loud.count {
                let chunk = Array(loud[block..<block + 512])
                _ = try host.processOffline(input: [chunk, chunk], frames: 512)
                block += 512
            }
            var diagnostics = N60RenderKernelDiagnostics()
            host.overlayStereoReadbacks(&diagnostics, latencyFrames: 0, includeOutput: true)
            XCTAssertGreaterThan(diagnostics.inputMeter.overRangeSamples, 0, "over-range rate \(rate)")
            XCTAssertGreaterThan(diagnostics.compressorGainReductionDB, 1, "compressor GR rate \(rate)")
            XCTAssertGreaterThan(diagnostics.limiterGainReductionDB, 1, "limiter GR rate \(rate)")
            XCTAssertGreaterThan(diagnostics.inputTruePeakLinear, 0.5, "input true peak rate \(rate)")
            XCTAssertLessThanOrEqual(diagnostics.outputTruePeakLinear, 0.55, "output true peak rate \(rate)")
            XCTAssertTrue(diagnostics.truePeakGuardActive, "guard rate \(rate)")
            // Reads reset: with silence in, the next reading is back at rest.
            let silence = [Float](repeating: 0, count: 512)
            _ = try host.processOffline(input: [silence, silence], frames: 512)
            var rest = N60RenderKernelDiagnostics()
            host.overlayStereoReadbacks(&rest, latencyFrames: 0, includeOutput: true)
            XCTAssertEqual(rest.inputMeter.overRangeSamples, 0, "reset rate \(rate)")
            // The diagnostics record carries the same values for any session type.
            let chunk = Array(loud[0..<512])
            _ = try host.processOffline(input: [chunk, chunk], frames: 512)
            let record = try XCTUnwrap(UnifiedGraphDiagnostics(host: host, programChannelCount: 2))
            let dynamics = try XCTUnwrap(record.dynamics, "dynamics rate \(rate)")
            XCTAssertTrue(dynamics.truePeakGuardActive)
            XCTAssertGreaterThan(dynamics.inputTruePeakLinear, 0.05)
        }
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

    /// E6 S8b2c: the kernel snapshot's latency and the graph's readback agree for the eligible
    /// integer inter-channel delay, so a translated setup needs no fade alignment, and the
    /// bridge latches zero. A published graph latency larger than the kernel's is latched as
    /// the alignment, with the fade still step-free.
    func testFadeAlignmentUsesGraphMinusKernelLatencyAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&snapshot, 48.0 * 1000.0 / rate))
            var mutable = snapshot
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &mutable, sampleRate: rate)
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            // The graph reports the kernel's per-lane integer taps as latency; the session removes
            // them (they are applied by both paths), leaving the kernel-reported figure.
            let taps = configuration.lanes.map(\.interChannelTapFrames).max() ?? 0
            XCTAssertGreaterThan(taps, 0, "rate \(rate)")
            let pathLatency = host.latencyFrames - min(host.latencyFrames, taps)
            XCTAssertEqual(pathLatency, snapshot.latencyFrames, "readback vs kernel, rate \(rate)")

            let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(262_144))
            defer { N60RealtimeAudioBridgeDestroy(bridge) }
            XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot))
            N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0, 0)
            let settle = Int(rate * 0.2 / 256) + 8
            let slope = Float(0.4 * 2.0 * .pi * 1_000.0 / rate)
            var driver = Driver()
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, host.rawGraph, 256, rate))
            N60RealtimeAudioBridgeSetUnifiedGraphLatency(bridge, pathLatency)
            driver.maxStep = 0
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertEqual(N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(bridge), 0, "rate \(rate)")
            XCTAssertLessThan(driver.maxStep, 4 * slope + 1e-4, "rate \(rate)")

            // Report 24 frames more graph latency than the kernel declares and fade back and forth.
            N60RealtimeAudioBridgeSetUnifiedGraphLatency(bridge, pathLatency + 24)
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, nil, 0, 0))
            driver.maxStep = 0
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, host.rawGraph, 256, rate))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertEqual(N60RealtimeAudioBridgeUnifiedGraphAlignmentFrames(bridge), 24, "rate \(rate)")
            XCTAssertLessThan(driver.maxStep, 4 * slope + 1e-4, "aligned fade, rate \(rate)")
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


/// E6 S8b2a: each newly eligible kernel stage renders through libn60core the way the kernel
/// renders it, at every standard rate. The kernel is the reference: the same snapshot goes to
/// a real `N60RenderKernel` and to the translated graph, and the settled output is compared.
final class UnifiedGraphStageParityTests: XCTestCase {
    private static let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    private func tone(_ hz: Double, rate: Double, frames: Int, amplitude: Float) -> [Float] {
        (0..<frames).map { Float(Double(amplitude) * sin(2.0 * .pi * hz * Double($0) / rate)) }
    }

    /// Two different program signals so a channel mix-up cannot pass.
    private func stimulus(rate: Double, amplitude: Float = 0.25) -> [[Float]] {
        let frames = Int(rate * 0.4) / 512 * 512
        let left = zip(tone(1_000, rate: rate, frames: frames, amplitude: amplitude),
                       tone(310, rate: rate, frames: frames, amplitude: amplitude * 0.5)).map { $0 + $1 }
        let right = tone(1_700, rate: rate, frames: frames, amplitude: amplitude * 0.8)
        return [left, right]
    }

    private func kernelRender(_ snapshot: N60DSPGraphSnapshot, _ input: [[Float]]) throws -> [[Float]] {
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, snapshot))
        var left = [Float](repeating: 0, count: input[0].count)
        var right = left
        for i in 0..<left.count {
            N60RenderKernelProcessStereoFrame(kernel, input[0][i], input[1][i], &left[i], &right[i])
        }
        return [left, right]
    }

    private func graphRender(_ snapshot: N60DSPGraphSnapshot, _ input: [[Float]], rate: Double) throws -> [[Float]] {
        var snapshot = snapshot
        let configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate),
            "snapshot should be eligible at \(rate)"
        )
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        var out: [[Float]] = [[], []]
        var position = 0
        while position + 512 <= input[0].count {
            let chunk = input.map { Array($0[position..<position + 512]) }
            let rendered = try host.processOffline(input: chunk, frames: 512)
            out[0] += rendered[0]
            out[1] += rendered[1]
            position += 512
        }
        return out
    }

    private func rms(_ x: ArraySlice<Float>) -> Double {
        sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(x.count, 1)))
    }

    /// Final quarter: sample-wise difference (linear stages) or RMS ratio (dynamics).
    private func assertParity(
        _ snapshot: N60DSPGraphSnapshot, rate: Double, sampleWise: Bool = true,
        amplitude: Float = 0.25, tolerance: Double = 0.01, _ label: String
    ) throws {
        let input = stimulus(rate: rate, amplitude: amplitude)
        let reference = try kernelRender(snapshot, input)
        let candidate = try graphRender(snapshot, input, rate: rate)
        let start = input[0].count * 3 / 4
        for lane in 0..<2 {
            let ref = reference[lane][start...]
            let got = candidate[lane][start...]
            if sampleWise {
                var worst: Float = 0
                for (a, b) in zip(ref, got) { worst = max(worst, abs(a - b)) }
                XCTAssertLessThan(Double(worst), tolerance * max(rms(ref) * 4, 0.05), "\(label) lane \(lane) rate \(rate)")
            } else {
                let expected = rms(ref)
                XCTAssertEqual(rms(got), expected, accuracy: max(expected * tolerance, 1e-5),
                               "\(label) lane \(lane) rate \(rate)")
            }
        }
    }

    func testMidSideEQMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 0, UInt8(N60_EQ_CHANNEL_LEFT), N60BiquadFilterTypePeaking, 1_000, 6, 1.0, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 1, UInt8(N60_EQ_CHANNEL_RIGHT), N60BiquadFilterTypeHighShelf, 4_000, -4, 0.707, true))
            s.eqMidSideMode = true
            try assertParity(s, rate: rate, "mid/side EQ")
        }
    }

    func testSymmetryCrossfeedAndCrosstalkMatchTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetSymmetryBalance(&s, 0.4, true))
            try assertParity(s, rate: rate, "symmetry")
            s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerCrossfeed(&s, 0.3, true))
            try assertParity(s, rate: rate, "crossfeed")
            s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetCrosstalkCancellation(&s, 0.5, 700, true))
            try assertParity(s, rate: rate, "crosstalk")
        }
    }

    func testIntegerInterChannelDelayMatchesTheKernelAndFractionalKeepsTheKernel() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            // 48 frames: an exact integer at every rate, so the kernel bypasses its all-pass.
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, 48.0 * 1000.0 / rate))
            XCTAssertEqual(s.interChannelDelay.right.order, 0)
            try assertParity(s, rate: rate, "integer delay")
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, -(48.0 * 1000.0 / rate)))
            try assertParity(s, rate: rate, "negative integer delay")
        }
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, 0.3))
        XCTAssertGreaterThan(s.interChannelDelay.right.order, 0)
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
    }

    func testAmbientCompensationMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetAmbientCompensation(&s, 2, 1.5, 1, 0.5, true))
            try assertParity(s, rate: rate, "ambient")
        }
    }

    func testCompressorMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                &s.dynamics, rate, true, -24, 3, 6, 8, 120, 2, N60CompressorTopologyFeedForward, false, 80))
            try assertParity(s, rate: rate, sampleWise: false, tolerance: 0.05, "compressor")
            XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                &s.dynamics, rate, true, -18, 2, 0, 3, 60, 0, N60CompressorTopologyFeedBack, true, 0))
            try assertParity(s, rate: rate, sampleWise: false, tolerance: 0.05, "feedback compressor")
        }
    }

    func testExpanderMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, rate, true, -26, 2, -30, 2, 80))
            try assertParity(s, rate: rate, sampleWise: false, amplitude: 0.04, tolerance: 0.05, "expander")
        }
    }

    func testPauseGateMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetPauseGate(&s.dynamics, rate, true, -50, 20, 2, 10, 6))
            s.masterGainLinear = 0.5
            // Loud passes, quiet is gated away; both must agree with the kernel.
            try assertParity(s, rate: rate, sampleWise: false, amplitude: 0.25, "pause gate open")
            try assertParity(s, rate: rate, sampleWise: false, amplitude: 0.001, tolerance: 0.2, "pause gate closed")
        }
    }

    func testCombinedStageChainMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 0, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypePeaking, 2_000, -3, 1.2, true))
            s.eqMidSideMode = true
            XCTAssertTrue(N60DSPGraphSnapshotSetSymmetryBalance(&s, -0.2, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerCrossfeed(&s, 0.2, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, 24.0 * 1000.0 / rate))
            s.outputGainLinear = 0.8
            try assertParity(s, rate: rate, "combined chain")
        }
    }

    func testOrderingConflictsKeepTheKernel() {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DSPGraphSnapshotSetAmbientCompensation(&s, 2, 1.5, 1, 0.5, true))
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, 48_000, true, -26, 2, -30, 2, 80))
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000),
                     "the kernel runs ambient before its expander, the core after")
        s = N60DSPGraphSnapshotMakeUnity(48_000)
        s.mixedPhaseEnabled = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
        s = N60DSPGraphSnapshotMakeUnity(48_000)
        s.dynamics.dynamicEQ.enabled = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
    }

    func testUnrecoverableSmoothingKeepsTheKernel() {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, 48_000, true, -26, 2, -30, 2, 80))
        s.dynamics.expander.attackCoefficient = 0.5  // not what any in-range attack time yields exactly
        s.dynamics.expander.releaseCoefficient = 1.5 // not a valid pole
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
    }
}
