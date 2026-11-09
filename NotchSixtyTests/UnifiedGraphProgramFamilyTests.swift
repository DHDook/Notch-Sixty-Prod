import XCTest
@testable import NotchSixty

/// E6 S12g4 (G8, G12, G17): the clean-up, stereo image, loudness, de-esser and multiband stages follow the stereo
/// settings onto N-channel and Virtual Speakers sessions instead of being dropped. Real graphs, real blocks, eight rates.
@MainActor
final class UnifiedGraphProgramFamilyTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_414, uid: "family-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "family-out")
        return engine
    }

    private func stereoStages(_ engine: AudioIOEngine, rate: Double) throws -> UnifiedGraphConfiguration {
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        return try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
    }

    private func render(
        _ stereo: UnifiedGraphConfiguration, layout: OutputProgramLayout, rate: Double, input: [[Float]]
    ) throws -> (UnifiedGraphSpec, [[Float]]) {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
        let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        let spec = try configuration.makeSpec()
        let host = try UnifiedGraphHost(spec: spec)
        var out = [[Float]](repeating: [], count: input.count)
        var position = 0
        while position < input[0].count {
            let count = min(512, input[0].count - position)
            let chunk = input.map { Array($0[position..<position + count]) }
            let result = try host.processOffline(input: chunk, frames: count)
            for lane in 0..<input.count { out[lane] += result[lane] }
            position += count
        }
        return (spec, out)
    }

    func testCleanupRunsOnEveryPairAndTrueMonoOnTheFrontPairAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var dynamics = DynamicsConfiguration()
            dynamics.dcOffsetFilter.enabled = true
            dynamics.stereoMode = .trueMono
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(engine, rate: rate)
            XCTAssertNotNil(stereo.stereoStages.cleanup)
            XCTAssertNotNil(stereo.stereoStages.image)
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            let frames = Int(rate * 1.2)
            // DC plus a tone on every lane; the front left lane alone carries the tone for the true-mono check.
            var input = [[Float]](repeating: [Float](repeating: 0.2, count: frames), count: layout.roles.count)
            let fl = try XCTUnwrap(shape.frontLeft), fr = try XCTUnwrap(shape.frontRight)
            input[fl] = (0..<frames).map { 0.2 + 0.4 * Float(sin(2 * Double.pi * 1_000 * Double($0) / rate)) }
            input[fr] = [Float](repeating: 0.2, count: frames)
            let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_CLEANUP.rawValue }.count,
                           shape.pairs.count + (layout.roles.count - 2 * shape.pairs.count),
                           "one per pair plus one single-lane instance for each unpaired lane (centre, LFE) at \(rate)")
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_IMAGE.rawValue }.count, 1)
            let tailStart = frames * 3 / 4
            for pair in shape.pairs {
                for lane in [pair.a, pair.b] where lane != fl && lane != fr {
                    let mean = out[lane][tailStart...].reduce(0.0) { $0 + Double($1) } / Double(frames - tailStart)
                    XCTAssertEqual(mean, 0, accuracy: 0.01, "DC removed on lane \(lane) at \(rate)")
                }
            }
            for index in tailStart..<frames {
                XCTAssertEqual(out[fl][index], out[fr][index], accuracy: 1e-3, "true mono: front L equals R at \(rate)")
            }
        }
    }

    func testImageStagesNeedAFrontPairAndNameTheReason() throws {
        let engine = try engine(rate: 48_000)
        var dynamics = DynamicsConfiguration()
        dynamics.stereoMode = .trueMono
        try engine.replaceDynamicsConfiguration(dynamics)
        let stereo = try stereoStages(engine, rate: 48_000)
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontCenter]))
        let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
        var spec = try UnifiedGraphConfiguration(
            sampleRate: 48_000, lanes: [UnifiedGraphLane()]).makeSpec()
        XCTAssertThrowsError(try dsp.apply(to: &spec)) {
            XCTAssertEqual($0 as? UnifiedGraphFallbackReason, .noFrontPair)
        }
    }
    private func rms(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return 0 }
        return sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(x.count))
    }

    private func tone(_ rate: Double, _ hz: Double, _ frames: Int) -> [Float] {
        (0..<frames).map { Float(0.5 * sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    /// G44: loudness and multiband reach the front pair of a 5.1 session and leave the rear pair alone, at every rate.
    func testLoudnessAndMultibandActOnTheFrontPairOnlyAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            let fl = try XCTUnwrap(shape.frontLeft), fr = try XCTUnwrap(shape.frontRight)
            let frames = Int(rate * 0.6)
            let input = (0..<layout.roles.count).map { _ in tone(rate, 1_000, frames) }
            let tail = frames / 2

            let plain = try engine(rate: rate)
            let (_, base) = try render(try stereoStages(plain, rate: rate), layout: layout, rate: rate, input: input)

            var dynamics = DynamicsConfiguration()
            dynamics.multibandCompressor.enabled = true
            dynamics.multibandCompressor.midThresholdDB = -40
            dynamics.multibandCompressor.midRatio = 10
            dynamics.multibandCompressor.lowThresholdDB = -40
            dynamics.multibandCompressor.lowRatio = 10
            dynamics.multibandCompressor.highThresholdDB = -40
            dynamics.multibandCompressor.highRatio = 10
            dynamics.loudnessMatch.enabled = true
            let loud = try engine(rate: rate)
            try loud.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(loud, rate: rate)
            XCTAssertNotNil(stereo.stereoStages.multiband)
            XCTAssertNotNil(stereo.stereoStages.loudness)
            let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_MULTIBAND.rawValue }.count, 1)
            XCTAssertEqual(spec.stages.filter { $0.kind == N60_STAGE_LOUDNESS.rawValue }.count, 1)
            XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "finite at \(rate)")
            let frontBase = rms(base[fl][tail...]), frontNow = rms(out[fl][tail...])
            XCTAssertLessThan(frontNow, frontBase * 0.9, "multiband compresses the front pair at \(rate)")
            XCTAssertEqual(rms(out[fl][tail...]), rms(out[fr][tail...]), accuracy: frontNow * 0.02, "front pair stays matched at \(rate)")
            for lane in 0..<layout.roles.count where lane != fl && lane != fr {
                XCTAssertEqual(rms(out[lane][tail...]), rms(base[lane][tail...]), accuracy: rms(base[lane][tail...]) * 0.01,
                               "lane \(lane) is not touched at \(rate)")
            }
        }
    }

    /// G42: every program layout, with every stage family on, builds into a real graph at every rate (no legacy fallback).
    func testEveryLayoutWithEveryStageFamilyAttachesTheGraphAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            var dynamics = DynamicsConfiguration()
            dynamics.dcOffsetFilter.enabled = true
            dynamics.stereoMode = .trueMono
            dynamics.multibandCompressor.enabled = true
            dynamics.loudnessMatch.enabled = true
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(dynamics)
            let stereo = try stereoStages(engine, rate: rate)
            for layout in OutputProgramLayout.allCases where layout.roles.count > 2 {
                let frames = 2_048
                let input = (0..<layout.roles.count).map { _ in tone(rate, 997, frames) }
                let (spec, out) = try render(stereo, layout: layout, rate: rate, input: input)
                XCTAssertGreaterThan(spec.stages.filter { $0.kind == N60_STAGE_CLEANUP.rawValue }.count, 0, "\(layout) at \(rate)")
                XCTAssertTrue(out.allSatisfy { $0.allSatisfy(\.isFinite) }, "\(layout) finite at \(rate)")
            }
        }
    }

    /// G41: an optimizer FIR composes with a program FIR; every lane lands on the summed latency.
    func testOptimizerFIRComposesWithProgramFIRAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let layout = OutputProgramLayout.fiveOne
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
            var stereo = UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()])
            stereo.stereoStages.programFIR = UnifiedGraphFIRProgram(
                generation: 1, left: [0, 0, 1, 0, 0], right: nil, declaredLatencyFrames: 2)
            let dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
            XCTAssertTrue(dsp.hasProgramLatency)
            var configuration = UnifiedGraphTranslator.multichannelConfiguration(
                sampleRate: rate, programChannels: layout.roles.count, subwoofers: [])
            configuration.orderPolicy = .canonical
            configuration.programDSP = dsp
            configuration.optimizerFIR = UnifiedGraphOptimizerFIR(
                declaredLatencyFrames: 2, taps: [0: [0, 0, 1, 0, 0], 1: [0, 0, 1, 0, 0]])
            let host = try UnifiedGraphHost(spec: try configuration.makeSpec())
            var input = [[Float]](repeating: [Float](repeating: 0, count: 2_048), count: layout.roles.count)
            for lane in 0..<layout.roles.count { input[lane][0] = 0.5 }
            let out = try host.processOffline(input: input, frames: 2_048)
            let peaks = out.map { lane in lane.indices.max { abs(lane[$0]) < abs(lane[$1]) } ?? -1 }
            XCTAssertEqual(Set(peaks).count, 1, "every lane lands on the same sample at \(rate): \(peaks)")
            XCTAssertEqual(peaks[0], 2 * (256 + 2), "program plus optimizer latency at \(rate)")
        }
    }
}
