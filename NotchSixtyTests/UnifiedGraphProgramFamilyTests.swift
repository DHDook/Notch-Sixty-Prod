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
                           shape.pairs.count + (shape.centerLane == nil ? 0 : 1), "one per pair plus the centre at \(rate)")
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
}
