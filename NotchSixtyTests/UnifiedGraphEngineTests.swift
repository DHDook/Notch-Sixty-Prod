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
        snapshot.crossover.frequencyHz = 0  // not a crossover the core can design
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

    func testBridgeWithoutAGraphLeavesTheKernelPathAlone() throws {
        XCTAssertFalse(FeatureFlag.legacyKernel.defaultEnabled)
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

    /// E6 S8c follow-up: switching the limiter off while the graph renders makes the limiter readbacks
    /// read zero (no reduction, no guard, no peaks) and the diagnostics row carry them; switching it
    /// back on brings them back. The flag is a topology change, so `apply` publishes.
    @MainActor
    func testLimiterBypassedDuringPlaybackReadsZeroAtEveryRate() throws {
        for rate in Self.rates {
            func configuration(limiter: Bool) throws -> UnifiedGraphConfiguration {
                var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
                snapshot.protection.limiterEnabled = limiter
                snapshot.protection.truePeakGuardEnabled = true
                snapshot.protection.limiterCeilingLinear = 0.5
                return try XCTUnwrap(
                    UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate), "rate \(rate)")
            }
            let host = try UnifiedGraphHost(spec: try configuration(limiter: true).makeSpec())
            let loud = sine(1_000, rate: rate, frames: Int(rate * 0.3), amplitude: 0.9)
            func render(_ from: Int, _ blocks: Int) throws {
                for b in 0..<blocks {
                    let start = (from + b * 512) % (loud.count - 512)
                    let chunk = Array(loud[start..<start + 512])
                    _ = try host.processOffline(input: [chunk, chunk], frames: 512)
                }
            }
            try render(0, Int(rate * 0.3) / 512)
            let active = try XCTUnwrap(host.dynamicsReadings(), "rate \(rate)")
            XCTAssertGreaterThan(active.limiterGainReductionDB, 1, "limiter working, rate \(rate)")
            XCTAssertTrue(active.truePeakGuardActive, "guard on, rate \(rate)")

            XCTAssertEqual(try host.apply(try configuration(limiter: false).makeSpec()), .published, "rate \(rate)")
            try render(0, 8)
            _ = host.dynamicsReadings()  // discard what the swap-over block measured
            try render(0, 8)
            let bypassed = try XCTUnwrap(host.dynamicsReadings(), "rate \(rate)")
            XCTAssertEqual(bypassed.limiterGainReductionDB, 0, "bypassed reduction, rate \(rate)")
            XCTAssertFalse(bypassed.truePeakGuardActive, "bypassed guard, rate \(rate)")
            XCTAssertEqual(bypassed.inputTruePeakLinear, 0, "bypassed input peak, rate \(rate)")
            XCTAssertEqual(bypassed.outputTruePeakLinear, 0, "bypassed output peak, rate \(rate)")
            try render(0, 2)
            let record = try XCTUnwrap(UnifiedGraphDiagnostics(host: host, programChannelCount: 2))
            XCTAssertEqual(record.dynamics?.limiterGainReductionDB, 0, "diagnostics record, rate \(rate)")

            XCTAssertEqual(try host.apply(try configuration(limiter: true).makeSpec()), .published, "rate \(rate)")
            try render(0, Int(rate * 0.3) / 512)
            let back = try XCTUnwrap(host.dynamicsReadings(), "rate \(rate)")
            XCTAssertGreaterThan(back.limiterGainReductionDB, 1, "limiter back on, rate \(rate)")
            XCTAssertTrue(back.truePeakGuardActive, "guard back on, rate \(rate)")
        }
    }

    /// E6 S8c follow-up: two diagnostics readers and a renderer running at once. Over-range counts are
    /// read-and-reset behind the host lock, so every clipped sample is counted by exactly one reader.
    @MainActor
    func testConcurrentReadersSeeEveryOverRangeSampleOnce() throws {
        let rate = 48_000.0
        var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
        snapshot.protection.limiterEnabled = true
        snapshot.protection.limiterCeilingLinear = 0.5
        let configuration = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        let blocks = 400
        let clipped = [Float](repeating: 1.5, count: 512)
        let total = LockedCounter()
        let renderDone = LockedFlag()
        let readers = DispatchGroup()
        for _ in 0..<2 {
            readers.enter()
            DispatchQueue.global().async {
                repeat {
                    var d = N60RenderKernelDiagnostics()
                    host.overlayStereoReadbacks(&d, latencyFrames: 0, includeOutput: true)
                    total.add(d.inputMeter.overRangeSamples)
                    _ = host.dynamicsReadings()
                    _ = host.meter(stageId: N60_LSTAGE_FINAL_METER, lane: 0)
                } while !renderDone.isSet
                readers.leave()
            }
        }
        for _ in 0..<blocks { _ = try host.processOffline(input: [clipped, clipped], frames: 512) }
        renderDone.set()
        readers.wait()
        var last = N60RenderKernelDiagnostics()
        host.overlayStereoReadbacks(&last, latencyFrames: 0, includeOutput: true)
        total.add(last.inputMeter.overRangeSamples)
        // Two lanes of 512 clipped samples per block.
        XCTAssertEqual(total.value, UInt64(blocks * 512 * 2))
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

    /// The profile travels with the hand-over in both directions. The kernel captures, the graph takes over and
    /// must hold that profile (not capture again); it goes back to the kernel and again to the graph, still held.
    func testHandOverKeepsTheDenoiserProfileAtEveryRate() throws {
        for rate in Self.rates {
            var snapshot = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
                &snapshot.dynamics, rate, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
                0.7, -50, false, 0, 150, 1, N60DenoiserProfileCommandCapture))
            let bridge = try XCTUnwrap(N60RealtimeAudioBridgeCreate(262_144))
            defer { N60RealtimeAudioBridgeDestroy(bridge) }
            XCTAssertTrue(N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot))
            N60RealtimeAudioBridgeConfigureOutputGate(bridge, 0, 0)
            var mutable = snapshot
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &mutable, sampleRate: rate)
            )
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            let raw = try XCTUnwrap(host.rawGraph)
            let graph = OpaquePointer(raw)
            let state = UnsafeMutablePointer<n60_denoiser_state>.allocate(capacity: 1)
            defer { state.deallocate() }

            var driver = Driver()
            // The kernel captures for about a second of program.
            drive(bridge, rate: rate, blocks: Int(rate * 1.6 / 256) + 8, driver: &driver)
            let settle = Int(rate * 0.3 / 256) + 8

            func assertHeld(_ label: String) {
                memset(state, 0, MemoryLayout<n60_denoiser_state>.size)
                XCTAssertEqual(n60_graph_denoiser_export(graph, state), 1, "\(label) rate \(rate)")
                XCTAssertNotEqual(state.pointee.flags & 1, 0, "\(label): profile ready, rate \(rate)")
                XCTAssertNotEqual(state.pointee.flags & 2, 0, "\(label): captured, rate \(rate)")
                XCTAssertEqual(state.pointee.flags & 4, 0, "\(label): no repeat capture, rate \(rate)")
            }

            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, raw, 256, rate))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            assertHeld("kernel to graph")
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, nil, 0, 0))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            XCTAssertTrue(N60RealtimeAudioBridgeSetUnifiedGraph(bridge, raw, 256, rate))
            drive(bridge, rate: rate, blocks: settle, driver: &driver)
            assertHeld("graph to kernel to graph")
            N60RealtimeAudioBridgeReleaseUnifiedGraph(bridge)
        }
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

    func testIntegerInterChannelDelayMatchesTheKernel() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            // 48 frames: an exact integer at every rate, so the kernel bypasses its all-pass.
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, 48.0 * 1000.0 / rate))
            XCTAssertEqual(s.interChannelDelay.right.order, 0)
            try assertParity(s, rate: rate, "integer delay")
            XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, -(48.0 * 1000.0 / rate)))
            try assertParity(s, rate: rate, "negative integer delay")
        }
    }

    /// E6 S8d group 3: the Thiran fractional delay runs as FRAC_DELAY stages and matches the kernel.
    func testFractionalInterChannelDelayMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            for delayMilliseconds in [0.3, -0.713, 6.25] {
                var s = N60DSPGraphSnapshotMakeUnity(rate)
                XCTAssertTrue(N60DSPGraphSnapshotSetInterChannelDelay(&s, delayMilliseconds))
                try assertParity(s, rate: rate, "fractional delay \(delayMilliseconds) ms")
            }
        }
    }

    /// E6 S8d group 3: mixed-phase EQ is all-pass correction sections in the EQ band list.
    func testMixedPhaseEQMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 0, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypePeaking, 1_500, -4, 1.1, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 1, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypeAllPass, 300, 0, 0.7, true))
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 2, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypeAllPass, 4_000, 0, 1.3, true))
            s.mixedPhaseEnabled = true
            s.mixedPhaseCorrectionSectionCount = 2
            try assertParity(s, rate: rate, "mixed phase")
        }
    }

    /// E6 S8d group 4: the stereo crossover (both topologies, every monitor mode, polarity, alignment) matches the kernel.
    func testStereoCrossoverMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            for (topology, mode, align, invert) in [
                (N60CrossoverTopologyLinkwitzRiley24, N60CrossoverMonitorModeRecombined, false, false),
                (N60CrossoverTopologyLinkwitzRiley48, N60CrossoverMonitorModeRecombined, true, true),
                (N60CrossoverTopologyLinkwitzRiley24, N60CrossoverMonitorModeMainsOnly, false, false),
                (N60CrossoverTopologyLinkwitzRiley48, N60CrossoverMonitorModeSubOnly, true, false),
            ] {
                var s = N60DSPGraphSnapshotMakeUnity(rate)
                XCTAssertTrue(N60CrossoverSnapshotMake(rate, 90, topology, mode, 0.7, invert, true, &s.crossover))
                XCTAssertTrue(N60CrossoverSnapshotSetSubPhaseAlignment(rate, 70, 0.8, align, &s.crossover))
                try assertParity(s, rate: rate, tolerance: 0.002, "crossover \(topology.rawValue) \(mode.rawValue)")
            }
        }
    }

    /// E6 S8d group 4: the soft clipper (every curve), alone and in front of the limiter, and the gain rider.
    func testSoftClipperAndGainRiderMatchTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            for curve in [N60ClipperCurveQuadratic, N60ClipperCurveCubic, N60ClipperCurveSine, N60ClipperCurveAsymmetricTube] {
                var s = N60DSPGraphSnapshotMakeUnity(rate)
                XCTAssertTrue(N60ProtectionSnapshotSetSoftClipperAdvanced(&s.protection, true, 6, -2, 0.5, curve, true, 1.0))
                try assertParity(s, rate: rate, amplitude: 0.6, tolerance: 0.01, "clipper curve \(curve.rawValue)")
                XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&s.protection, true, -3, 1, 80, 2, false))
                try assertParity(s, rate: rate, amplitude: 0.6, tolerance: 0.01, "clipper and limiter \(curve.rawValue)")
            }
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60ProtectionSnapshotSetLimiterAdvanced(&s.protection, true, -3, 1, 80, 2, true))
            XCTAssertTrue(N60ProtectionSnapshotSetGainRider(&s.protection, true, 2, 6, N60GainRiderSpeedFast))
            try assertParity(s, rate: rate, sampleWise: false, amplitude: 0.9, tolerance: 0.05, "gain rider")
        }
    }

    func testCrossoverAndProtectionIneligibleCasesKeepTheKernel() {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60CrossoverSnapshotMake(48_000, 90, N60CrossoverTopologyLinkwitzRiley24, N60CrossoverMonitorModeRecombined, 1, false, true, &s.crossover))
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
        // The core has no stereo crossover beside the sub-lane bass management.
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &s, sampleRate: 48_000, subwoofers: [UnifiedGraphSubwoofer()]))
        // Oversampling with neither limiter nor clipper: the kernel adds latency the core does not.
        s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60ProtectionSnapshotSetOversamplingFactor(&s.protection, N60OversamplingFactor4x))
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
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000),
                        "owner decision of 24 Oct 2026: ambient runs after the compressor and expander on every path")
        s = N60DSPGraphSnapshotMakeUnity(48_000)
        s.dynamics.dynamicEQ.enabled = true
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000),
                        "a dynamic EQ with no enabled band is the identity")
        s = dynamicEQSnapshot(rate: 48_000)
        s.eqMidSideMode = true
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000),
                     "the kernel runs the dynamic EQ after the mid/side decode, the core before")
    }

    // MARK: dynamic EQ and spectral denoiser (E6 S8d, first stage group)

    private func dynamicEQSnapshot(
        rate: Double, domain: N60DynamicEQDomain = N60DynamicEQDomainLinkedStereo
    ) -> N60DSPGraphSnapshot {
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetDynamicEQEnabled(&s.dynamics, true))
        XCTAssertTrue(N60DynamicEQSnapshotSetDomain(&s.dynamics.dynamicEQ, domain))
        // A cutting peak band the program exceeds, plus an RMS-detected boosting low shelf.
        XCTAssertTrue(N60DynamicEQSnapshotSetBandForLane(
            &s.dynamics.dynamicEQ, rate, N60DynamicEQLanePrimary, 0, true, N60DynamicEQShapePeak,
            1_000, 1.4, -2, -40, 4, -12, 5, 80, N60DynamicEQDirectionCutOnly, -30, 2, 6,
            N60DynamicEQDetectorPeak, 50))
        XCTAssertTrue(N60DynamicEQSnapshotSetBandForLane(
            &s.dynamics.dynamicEQ, rate, N60DynamicEQLanePrimary, 1, true, N60DynamicEQShapeLowShelf,
            250, 0.8, 1, -20, 2, -6, 10, 200, N60DynamicEQDirectionBoth, -18, 3, 6,
            N60DynamicEQDetectorRMS, 40))
        XCTAssertTrue(N60DynamicEQSnapshotSetBandForLane(
            &s.dynamics.dynamicEQ, rate, N60DynamicEQLanePrimary, 2, true, N60DynamicEQShapeTilt,
            1_700, 1.0, 0, -35, 3, -9, 8, 120, N60DynamicEQDirectionCutOnly, -30, 2, 6,
            N60DynamicEQDetectorPeak, 50))
        return s
    }

    func testDynamicEQMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = dynamicEQSnapshot(rate: rate)
            try assertParity(s, rate: rate, tolerance: 0.02, "linked dynamic EQ")
            // Per-channel detectors, the same band set on both channels.
            s = dynamicEQSnapshot(rate: rate, domain: N60DynamicEQDomainDualMono)
            withUnsafeMutablePointer(to: &s.dynamics.dynamicEQ) { q in
                withUnsafeMutablePointer(to: &q.pointee.secondaryBands) { second in
                    second.withMemoryRebound(to: N60DynamicEQBandSnapshot.self, capacity: 3) { dst in
                        withUnsafeMutablePointer(to: &q.pointee.bands) { first in
                            first.withMemoryRebound(to: N60DynamicEQBandSnapshot.self, capacity: 3) { src in
                                for i in 0..<3 { dst[i] = src[i] }
                            }
                        }
                    }
                }
                q.pointee.secondaryBandCount = 3
            }
            try assertParity(s, rate: rate, tolerance: 0.02, "dual-mono dynamic EQ")
        }
    }

    func testDynamicEQWithAnEQAndDynamicsKeepsKernelOrder() throws {
        for rate in Self.rates {
            var s = dynamicEQSnapshot(rate: rate)
            XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                &s, 0, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypePeaking, 2_500, 4, 1.0, true))
            XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                &s.dynamics, rate, true, -24, 3, 6, 8, 120, 2, N60CompressorTopologyFeedForward, false, 80))
            try assertParity(s, rate: rate, sampleWise: false, tolerance: 0.05, "dynamic EQ, EQ and compressor")
        }
    }

    func testUnrepresentableDynamicEQKeepsTheKernel() {
        var s = dynamicEQSnapshot(rate: 48_000, domain: N60DynamicEQDomainMidSide)
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "mid/side domain")
        // Dual mono whose right channel has a different band set cannot be one core stage.
        s = dynamicEQSnapshot(rate: 48_000, domain: N60DynamicEQDomainDualMono)
        XCTAssertTrue(N60DynamicEQSnapshotSetBandForLane(
            &s.dynamics.dynamicEQ, 48_000, N60DynamicEQLaneSecondary, 0, true, N60DynamicEQShapePeak,
            3_000, 1, 0, -30, 2, -6, 5, 50, N60DynamicEQDirectionCutOnly, -30, 2, 6, N60DynamicEQDetectorPeak, 50))
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "different channel sets")
        // A transition pole other than the kernel's own 5 ms is not what the core reproduces.
        s = dynamicEQSnapshot(rate: 48_000)
        s.dynamics.dynamicEQ.bypassTransitionCoefficient = 0.5
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "transition pole")
        // The kernel skips the dynamic EQ while the EQ is bypassed, so the graph has no stage either.
        s = dynamicEQSnapshot(rate: 48_000)
        s.eqBypassed = true
        var configuration = UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000)
        XCTAssertNotNil(configuration)
        XCTAssertNil(configuration?.stereoStages.dynamicEQ)
        s = dynamicEQSnapshot(rate: 48_000)
        configuration = UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000)
        XCTAssertEqual(configuration?.stereoStages.dynamicEQ?.count, 1 + 15 * 3)
    }

    /// Low-level noise under the program so the denoiser learns a profile.
    private func noisyStimulus(rate: Double, seconds: Double) -> [[Float]] {
        let frames = Int(rate * seconds) / 512 * 512
        var seed: UInt32 = 12_345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.002
        }
        let base = stimulus(rate: rate, amplitude: 0.05)
        let left = (0..<frames).map { base[0][$0 % base[0].count] + noise() }
        let right = (0..<frames).map { base[1][$0 % base[1].count] + noise() }
        return [left, right]
    }

    func testSpectralDenoiserMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
                &s.dynamics, rate, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
                0.7, -50, false, 0, 150, 0, N60DenoiserProfileCommandNone))
            var latencyCopy = s
            let configuration = try XCTUnwrap(
                UnifiedGraphTranslator.stereoConfiguration(snapshot: &latencyCopy, sampleRate: rate)
            )
            let latencyHost = try UnifiedGraphHost(spec: try configuration.makeSpec())
            XCTAssertEqual(latencyHost.latencyFrames, s.latencyFrames + s.dynamics.spectralDenoiser.latencyFrames, "denoiser latency, rate \(rate)")
            let input = noisyStimulus(rate: rate, seconds: 2.5)
            let reference = try kernelRender(s, input)
            let candidate = try graphRender(s, input, rate: rate)
            let start = input[0].count * 3 / 4
            for lane in 0..<2 {
                let expected = rms(reference[lane][start...])
                XCTAssertEqual(rms(candidate[lane][start...]), expected, accuracy: expected * 0.05,
                               "denoiser lane \(lane) rate \(rate)")
                XCTAssertLessThan(rms(candidate[lane][start...]), rms(input[lane][start...]) * 0.999,
                                  "the denoiser should be removing something at \(rate)")
            }
        }
    }

    func testSpectralDenoiserVariantsMatchTheKernel() throws {
        let rate = 48_000.0
        let variants: [(N60DenoiserTuning, N60DenoiserQuality, Bool, UInt32, N60DenoiserProfileCommand)] = [
            (N60DenoiserTuningNatural, N60DenoiserQualityQuality, false, 0, N60DenoiserProfileCommandNone),
            (N60DenoiserTuningAggressive, N60DenoiserQualityUltra, true, 0, N60DenoiserProfileCommandNone),
            (N60DenoiserTuningDehiss, N60DenoiserQualityHigh, false, 3, N60DenoiserProfileCommandReset),
            (N60DenoiserTuningCustom, N60DenoiserQualityHigh, false, 0, N60DenoiserProfileCommandNone),
        ]
        for (tuning, quality, protected, revision, command) in variants {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
                &s.dynamics, rate, true, tuning, quality, 0.9, -45, protected, 0, 400, revision, command))
            let input = noisyStimulus(rate: rate, seconds: 4)
            let reference = try kernelRender(s, input)
            let candidate = try graphRender(s, input, rate: rate)
            let start = input[0].count * 3 / 4
            for lane in 0..<2 {
                let expected = rms(reference[lane][start...])
                XCTAssertEqual(rms(candidate[lane][start...]), expected, accuracy: expected * 0.05,
                               "denoiser \(tuning) \(quality) lane \(lane)")
            }
        }
    }

    func testDenoiserWithEQAndExpanderKeepsKernelOrder() throws {
        let rate = 48_000.0
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, rate, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 0, N60DenoiserProfileCommandNone))
        XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
            &s, 0, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypePeaking, 2_000, -3, 1.2, true))
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, rate, true, -60, 2, -20, 2, 80))
        let input = noisyStimulus(rate: rate, seconds: 3)
        let reference = try kernelRender(s, input)
        let candidate = try graphRender(s, input, rate: rate)
        let start = input[0].count * 3 / 4
        for lane in 0..<2 {
            let expected = rms(reference[lane][start...])
            XCTAssertEqual(rms(candidate[lane][start...]), expected, accuracy: expected * 0.06, "lane \(lane)")
        }
    }

    func testUnrepresentableDenoiserKeepsTheKernel() {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        // A capture while the denoiser is off: the kernel keeps recording, a graph without the stage cannot.
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, false, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 1, N60DenoiserProfileCommandCapture))
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "capture while off")
        // The same command with the denoiser on is carried: the core remembers the revision across rebuilds.
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 1, N60DenoiserProfileCommandCapture))
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "capture while on")
        // Advanced smoothing the core's tuning table does not carry.
        s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 0, N60DenoiserProfileCommandNone))
        s.dynamics.spectralDenoiser.minimumGain = 0.5
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000), "advanced tuning")
        s.dynamics.spectralDenoiser.minimumGain = 0.20
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
    }

    /// A captured profile must sound the same through the graph as through the kernel, at every rate.
    func testCapturedProfileMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            var s = N60DSPGraphSnapshotMakeUnity(rate)
            XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
                &s.dynamics, rate, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
                0.9, -50, false, 0, 150, 1, N60DenoiserProfileCommandCapture))
            let input = noisyStimulus(rate: rate, seconds: 3.0)
            let reference = try kernelRender(s, input)
            let candidate = try graphRender(s, input, rate: rate)
            let start = input[0].count * 3 / 4
            for lane in 0..<2 {
                let expected = rms(reference[lane][start...])
                XCTAssertEqual(rms(candidate[lane][start...]), expected, accuracy: max(expected * 0.05, 2e-5),
                               "captured profile lane \(lane) rate \(rate)")
            }
        }
    }

    /// The denoiser's off view: the quality's FFT size and the profile revision, so the core can keep the
    /// kernel's profile while the stage is absent. A change in it must publish.
    func testDisabledDenoiserCarriesItsParkView() throws {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, false, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 4, N60DenoiserProfileCommandReset))
        let a = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
        let park = try XCTUnwrap(a.denoiserPark)
        XCTAssertEqual(park.revision, 4)
        XCTAssertEqual(park.command, 2)
        XCTAssertTrue([1_024, 2_048, 4_096].contains(park.fftSize))
        let specA = try a.makeSpec()
        XCTAssertEqual(specA.denoiserPark, park)
        XCTAssertTrue(specA.hasSameTopology(as: specA))
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, false, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 5, N60DenoiserProfileCommandReset))
        let b = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
        XCTAssertFalse(specA.hasSameTopology(as: try b.makeSpec()), "a new revision while off must publish")
        // With the denoiser on, the view is not used.
        XCTAssertTrue(N60DynamicsSnapshotSetSpectralDenoiser(
            &s.dynamics, 48_000, true, N60DenoiserTuningStandard, N60DenoiserQualityHigh,
            0.7, -50, false, 0, 150, 5, N60DenoiserProfileCommandNone))
        let on = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
        XCTAssertNil(try on.makeSpec().denoiserPark)
    }

    func testUnrecoverableSmoothingKeepsTheKernel() {
        var s = N60DSPGraphSnapshotMakeUnity(48_000)
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, 48_000, true, -26, 2, -30, 2, 80))
        s.dynamics.expander.attackCoefficient = 0.5  // not what any in-range attack time yields exactly
        s.dynamics.expander.releaseCoefficient = 1.5 // not a valid pole
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: 48_000))
    }
}


// MARK: program FIR, room FIR and speaker IR (E6 S8d, second stage group)

extension UnifiedGraphStageParityTests {
    private struct Prepared {
        var info: N60ConvolutionProgramInfo
        var program: UnifiedGraphFIRProgram
    }

    private func taps(count: Int, seed: Double, scale: Float = 0.5) -> [Float] {
        (0..<count).map { i in
            let t = Double(i)
            return scale * Float(exp(-t / (Double(count) * 0.25)) * sin(seed * t + 0.3 * seed) / 8.0)
        }
    }

    private func prepare(
        _ kernel: OpaquePointer, kind: UnifiedGraphProgramKind, slot: UInt32,
        left: [Float], right: [Float]?, declared: UInt32
    ) throws -> Prepared {
        var info = N60ConvolutionProgramInfo()
        let count = UInt32(left.count)
        let ok: Bool = left.withUnsafeBufferPointer { l in
            func call(_ r: UnsafePointer<Float>?) -> Bool {
                switch kind {
                case .convolution:
                    return N60RenderKernelPrepareConvolutionProgram(kernel, slot, l.baseAddress!, r, count, declared, &info)
                case .roomCorrection:
                    return N60RenderKernelPrepareRoomCorrectionProgram(kernel, slot, l.baseAddress!, r, count, declared, &info)
                case .speakerIR:
                    return N60RenderKernelPrepareSpeakerIRProgram(kernel, slot, l.baseAddress!, r, count, declared, &info)
                }
            }
            if let right { return right.withUnsafeBufferPointer { call($0.baseAddress) } }
            return call(nil)
        }
        XCTAssertTrue(ok)
        return Prepared(info: info, program: UnifiedGraphFIRProgram(
            generation: info.generation, left: left, right: right, declaredLatencyFrames: declared))
    }

    private func select(_ s: inout N60DSPGraphSnapshot, kind: UnifiedGraphProgramKind, slot: UInt32, _ p: Prepared) {
        switch kind {
        case .convolution: XCTAssertTrue(N60DSPGraphSnapshotSetConvolutionProgram(&s, slot, p.info, true))
        case .roomCorrection: XCTAssertTrue(N60DSPGraphSnapshotSetRoomCorrectionProgram(&s, slot, p.info, true))
        case .speakerIR: XCTAssertTrue(N60DSPGraphSnapshotSetSpeakerIRProgram(&s, slot, p.info, true))
        }
    }

    private func lookup(_ kind: UnifiedGraphProgramKind, _ all: [Prepared]) -> UnifiedGraphProgramLookup {
        { k, g in k == kind ? all.first { $0.info.generation == g }?.program : nil }
    }

    private func firRate(_ rate: Double) -> Int { Int(rate * 0.4) / 512 * 512 }

    private func runKernel(_ kernel: OpaquePointer, _ input: [[Float]], from: Int, to: Int, into out: inout [[Float]]) {
        for i in from..<to {
            var l: Float = 0, r: Float = 0
            N60RenderKernelProcessStereoFrame(kernel, input[0][i], input[1][i], &l, &r)
            out[0][i] = l
            out[1][i] = r
        }
    }

    private func checkParity(_ ref: [[Float]], _ got: [[Float]], tolerance: Double, _ label: String) {
        let start = ref[0].count * 3 / 4
        for lane in 0..<2 {
            let a = ref[lane][start...], b = got[lane][start...]
            var worst: Float = 0
            for (x, y) in zip(a, b) { worst = max(worst, abs(x - y)) }
            XCTAssertLessThan(Double(worst), tolerance * max(rms(a) * 4, 0.05), "\(label) lane \(lane)")
        }
    }

    private func firCase(
        rate: Double, kind: UnifiedGraphProgramKind, stereoTaps: Bool, tapCount: Int, declared: UInt32,
        order: UnifiedGraphOrderPolicy = .canonical,
        extra: (inout N60DSPGraphSnapshot) -> Void = { _ in }, _ label: String
    ) throws {
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        let left = taps(count: tapCount, seed: 0.21)
        let right = stereoTaps ? taps(count: tapCount, seed: 0.37) : nil
        let prepared = try prepare(kernel, kind: kind, slot: 0, left: left, right: right, declared: declared)
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        select(&s, kind: kind, slot: 0, prepared)
        extra(&s)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, s))
        let input = stimulus(rate: rate)
        var ref: [[Float]] = [[Float](repeating: 0, count: input[0].count), [Float](repeating: 0, count: input[0].count)]
        runKernel(kernel, input, from: 0, to: input[0].count, into: &ref)

        var graphSnapshot = s
        var configuration = try XCTUnwrap(
            UnifiedGraphTranslator.stereoConfiguration(
                snapshot: &graphSnapshot, sampleRate: rate, programs: lookup(kind, [prepared])),
            "\(label) should be eligible at \(rate)")
        configuration.orderPolicy = order
        let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
        XCTAssertEqual(host.latencyFrames, prepared.info.engineLatencyFrames + prepared.info.declaredLatencyFrames,
                       "\(label) latency at \(rate)")
        var got: [[Float]] = [[], []]
        var position = 0
        while position + 512 <= input[0].count {
            let r = try host.processOffline(input: input.map { Array($0[position..<position + 512]) }, frames: 512)
            got[0] += r[0]; got[1] += r[1]
            position += 512
        }
        checkParity(ref, got, tolerance: 0.02, "\(label) rate \(rate)")
    }

    func testProgramFIRMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            try firCase(rate: rate, kind: .convolution, stereoTaps: false, tapCount: 700, declared: 5, "program FIR mono")
            try firCase(rate: rate, kind: .convolution, stereoTaps: true, tapCount: 1_500, declared: 0, "program FIR stereo")
        }
    }

    func testRoomFIRMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            try firCase(rate: rate, kind: .roomCorrection, stereoTaps: false, tapCount: 900, declared: 12, "room FIR mono")
            try firCase(rate: rate, kind: .roomCorrection, stereoTaps: true, tapCount: 2_000, declared: 3, "room FIR stereo")
        }
    }

    func testSpeakerIRMatchesTheKernelAtEveryRate() throws {
        for rate in Self.rates {
            try firCase(rate: rate, kind: .speakerIR, stereoTaps: true, tapCount: 1_100, declared: 7, "speaker IR")
        }
    }

    /// E6 S11 parity exception: stereo is `.canonical` by default, which puts the compressor before the room
    /// convolver; the frozen kernel puts it after. The kernel order stays reachable (`.kernelParity`) and is pinned here.
    func testRoomFIRWithCompressorKeepsKernelOrderAtEveryRate() throws {
        for rate in Self.rates {
            try firCase(rate: rate, kind: .roomCorrection, stereoTaps: true, tapCount: 800, declared: 0, order: .kernelParity, extra: { s in
                XCTAssertTrue(N60DynamicsSnapshotSetCompressorAdvanced(
                    &s.dynamics, rate, true, -24, 3, 6, 8, 120, 2, N60CompressorTopologyFeedForward, false, 80))
            }, "room FIR and compressor")
        }
    }

    func testProgramFIRWithEQMatchesTheKernel() throws {
        for rate in Self.rates {
            try firCase(rate: rate, kind: .convolution, stereoTaps: false, tapCount: 600, declared: 0, extra: { s in
                XCTAssertTrue(N60DSPGraphSnapshotSetEQBandForChannels(
                    &s, 0, UInt8(N60_EQ_CHANNEL_STEREO), N60BiquadFilterTypePeaking, 2_500, 4, 1.0, true))
            }, "EQ then program FIR")
        }
    }

    func testConvolverFallbackCasesKeepTheKernel() throws {
        let rate = 48_000.0
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        let p = try prepare(kernel, kind: .roomCorrection, slot: 0, left: taps(count: 500, seed: 0.2), right: nil, declared: 0)
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        select(&s, kind: .roomCorrection, slot: 0, p)
        XCTAssertNotNil(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &s, sampleRate: rate, programs: lookup(.roomCorrection, [p])))
        // The control plane did not retain the taps.
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(snapshot: &s, sampleRate: rate))
        // Retained under another generation.
        var other = p
        other.program.generation &+= 1
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &s, sampleRate: rate, programs: { _, _ in other.program }))
        // Wrong kind.
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &s, sampleRate: rate, programs: lookup(.speakerIR, [p])))
        // Room FIR before the expander.
        XCTAssertTrue(N60DynamicsSnapshotSetExpander(&s.dynamics, rate, true, -26, 2, -30, 2, 80))
        XCTAssertNil(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &s, sampleRate: rate, programs: lookup(.roomCorrection, [p])))
    }

    /// An IR change on the kernel ducks 8 ms and cuts to a cold runtime; the graph rebuilds with a fully warm filter
    /// and a 20 ms equal-power crossfade. Both must settle on the new filter, and the graph must not click.
    func testIRChangeSettlesOnTheNewFilterWithoutClicksAtEveryRate() throws {
        for rate in Self.rates {
            let kernel = try XCTUnwrap(N60RenderKernelCreate())
            defer { N60RenderKernelDestroy(kernel) }
            let first = try prepare(kernel, kind: .roomCorrection, slot: 0,
                                    left: taps(count: 900, seed: 0.21), right: nil, declared: 0)
            let second = try prepare(kernel, kind: .roomCorrection, slot: 1,
                                     left: taps(count: 1_300, seed: 0.55, scale: 0.8), right: nil, declared: 0)
            var s0 = N60DSPGraphSnapshotMakeUnity(rate)
            select(&s0, kind: .roomCorrection, slot: 0, first)
            var s1 = N60DSPGraphSnapshotMakeUnity(rate)
            select(&s1, kind: .roomCorrection, slot: 1, second)
            let input = stimulus(rate: rate)
            let n = input[0].count
            let switchAt = n / 2 / 512 * 512
            var ref: [[Float]] = [[Float](repeating: 0, count: n), [Float](repeating: 0, count: n)]
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, s0))
            runKernel(kernel, input, from: 0, to: switchAt, into: &ref)
            XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, s1))
            runKernel(kernel, input, from: switchAt, to: n, into: &ref)

            let all = [first, second]
            var g0 = s0, g1 = s1
            let c0 = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
                snapshot: &g0, sampleRate: rate, programs: lookup(.roomCorrection, all)))
            let c1 = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
                snapshot: &g1, sampleRate: rate, programs: lookup(.roomCorrection, all)))
            let host = try UnifiedGraphHost(spec: try c0.makeSpec())
            var got: [[Float]] = [[], []]
            var position = 0
            while position + 512 <= n {
                if position == switchAt {
                    XCTAssertEqual(try host.apply(try c1.makeSpec()), .published)
                }
                let r = try host.processOffline(input: input.map { Array($0[position..<position + 512]) }, frames: 512)
                got[0] += r[0]; got[1] += r[1]
                position += 512
            }
            checkParity(ref, got, tolerance: 0.02, "IR change rate \(rate)")
            // No click: the crossfade moves smoothly, so the largest step stays near the steady-state step.
            for lane in 0..<2 {
                var steady: Float = 0, around: Float = 0
                for i in 1..<n {
                    let d = abs(got[lane][i] - got[lane][i - 1])
                    if i < switchAt - 1_024 || i > n * 3 / 4 { steady = max(steady, d) } else { around = max(around, d) }
                }
                XCTAssertLessThan(around, steady * 3 + 0.01, "IR change click, lane \(lane) rate \(rate)")
            }
        }
    }

    /// Hand-over: a kernel that was not rendering holds old audio in its convolver. Marking it idle restarts the
    /// runtime from silence in O(block) work, so no ghost of that audio reaches the output.
    func testIdleKernelConvolverRestartsFromSilence() throws {
        let rate = 48_000.0
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        var impulse = [Float](repeating: 0, count: 3_000)
        impulse[2_000] = 1
        let p = try prepare(kernel, kind: .roomCorrection, slot: 0, left: impulse, right: nil, declared: 0)
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        select(&s, kind: .roomCorrection, slot: 0, p)
        XCTAssertTrue(N60RenderKernelPublishSnapshot(kernel, s))
        let tone = tone(1_000, rate: rate, frames: 6_000, amplitude: 0.5)
        let silence = [Float](repeating: 0, count: 6_000)
        var out: [[Float]] = [[Float](repeating: 0, count: 6_000), [Float](repeating: 0, count: 6_000)]
        runKernel(kernel, [tone, tone], from: 0, to: 6_000, into: &out)
        N60RenderKernelMarkIdle(kernel)
        runKernel(kernel, [silence, silence], from: 0, to: 6_000, into: &out)
        XCTAssertLessThan(out[0].max() ?? 1, 1e-6)
        XCTAssertLessThan(out[1].max() ?? 1, 1e-6)
        // And it renders normally afterwards.
        runKernel(kernel, [tone, tone], from: 0, to: 6_000, into: &out)
        XCTAssertGreaterThan(out[0].map { abs($0) }.max() ?? 0, 0.1)
    }

    func testUnchangedFIRKeepsItsStateAcrossAnUnrelatedRebuild() throws {
        let rate = 48_000.0
        let kernel = try XCTUnwrap(N60RenderKernelCreate())
        defer { N60RenderKernelDestroy(kernel) }
        let p = try prepare(kernel, kind: .convolution, slot: 0, left: taps(count: 4_000, seed: 0.3), right: nil, declared: 0)
        var s = N60DSPGraphSnapshotMakeUnity(rate)
        select(&s, kind: .convolution, slot: 0, p)
        var a = s
        let c0 = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &a, sampleRate: rate, programs: lookup(.convolution, [p])))
        XCTAssertTrue(N60DSPGraphSnapshotSetSymmetryBalance(&s, 0.4, true))
        var b = s
        let c1 = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(
            snapshot: &b, sampleRate: rate, programs: lookup(.convolution, [p])))
        XCTAssertFalse(try c1.makeSpec().hasSameTopology(as: try c0.makeSpec()))
        let host = try UnifiedGraphHost(spec: try c0.makeSpec())
        let input = stimulus(rate: rate)
        var peakBefore: Float = 0, peakAfter: Float = 0
        var position = 0
        let switchAt = 9_216
        while position + 512 <= input[0].count {
            if position == switchAt { _ = try host.apply(try c1.makeSpec()) }
            let r = try host.processOffline(input: input.map { Array($0[position..<position + 512]) }, frames: 512)
            let m = r[0].map { abs($0) }.max() ?? 0
            if position < switchAt && position > switchAt - 4_096 { peakBefore = max(peakBefore, m) }
            if position >= switchAt && position < switchAt + 4_096 { peakAfter = max(peakAfter, m) }
            position += 512
        }
        // The filter's tail is carried, so the level does not dip to a cold restart.
        XCTAssertGreaterThan(peakAfter, peakBefore * 0.5)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count: UInt64 = 0
    func add(_ n: UInt64) { lock.lock(); count &+= n; lock.unlock() }
    var value: UInt64 { lock.lock(); defer { lock.unlock() }; return count }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
