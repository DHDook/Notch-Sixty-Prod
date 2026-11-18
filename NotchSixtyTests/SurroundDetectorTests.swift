import XCTest
@testable import NotchSixty

/// E33 S13 (G23, G24; graph ABI v45; behind `e33.page-enhancements`): the LFE leaves the compressor and expander detector, and the
/// dialogue leveller follows a centre lane that carries signal. The core behaviour is in `core/tests/test_surround_detector.cpp`;
/// these tests cover the Swift side: the extended blocks, the mapping table and a 5.1 film-like render at the eight rates.
@MainActor
final class SurroundDetectorTests: XCTestCase {
    private func engine(rate: Double) throws -> AudioIOEngine {
        let output = AudioOutputDevice(
            deviceID: 9_433, uid: "surround-out", name: "Out", nominalSampleRate: rate,
            availableSampleRateRanges: [AudioSampleRateRange(minimum: 44_100, maximum: 384_000)], outputChannelCount: 2)
        let engine = AudioIOEngine(deviceCatalog: OfflineOutputCatalog(devices: [output]))
        _ = try engine.refreshOutputDevices()
        try engine.selectOutput(uid: "surround-out")
        return engine
    }

    private func spec(
        _ stereo: UnifiedGraphConfiguration, roles: [OutputProgramRole], rate: Double, surround: Bool
    ) throws -> UnifiedGraphSpec {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: roles))
        var dsp = UnifiedGraphProgramDSP(stereo: stereo, shape: shape, eqMode: .linked)
        dsp.surroundDetector = surround
        var configuration = UnifiedGraphTranslator.multichannelConfiguration(
            sampleRate: rate, programChannels: roles.count, subwoofers: [])
        configuration.orderPolicy = .canonical
        configuration.programDSP = dsp
        return try configuration.makeSpec()
    }

    private func dynamics() -> DynamicsConfiguration {
        var d = DynamicsConfiguration()
        d.compressor.enabled = true
        d.expander.enabled = true
        d.dialogueRelativeLeveler.enabled = true
        return d
    }

    private func render(_ spec: UnifiedGraphSpec, input: [[Float]]) throws -> [[Float]] {
        let host = try UnifiedGraphHost(spec: spec)
        var out = [[Float]](repeating: [], count: input.count)
        var position = 0
        while position < input[0].count {
            let count = min(512, input[0].count - position)
            let result = try host.processOffline(input: input.map { Array($0[position..<position + count]) }, frames: count)
            for lane in 0..<input.count { out[lane] += result[lane] }
            position += count
        }
        return out
    }

    func testExtendedBlocksPadTheShorterOnes() {
        let comp10 = [Float](repeating: 0, count: 10)
        let comp = SurroundDetectorParams.compressor(comp10, excluding: 3)
        XCTAssertEqual(comp.count, 17)
        XCTAssertEqual(comp[16], 4)
        XCTAssertEqual(Array(comp[10...15]), [100, 100, 0, 50, 0, 0])
        XCTAssertEqual(SurroundDetectorParams.compressor([Float](repeating: 0, count: 16), excluding: 3).count, 17)
        XCTAssertEqual(SurroundDetectorParams.compressor(comp10, excluding: nil), comp10)
        for count in [6, 13, 14, 15] {
            let out = SurroundDetectorParams.expander([Float](repeating: 0, count: count), excluding: 3)
            XCTAssertEqual(out.count, 16, "expander \(count)")
            XCTAssertEqual(out[15], 4)
        }
        XCTAssertEqual(SurroundDetectorParams.loudness([Float](repeating: 0, count: 32), centre: 2, pair: [0, 1]).count, 33)
        XCTAssertEqual(SurroundDetectorParams.loudness([Float](repeating: 0, count: 32), centre: 2, pair: [0, 2]).count, 32)
        XCTAssertEqual(SurroundDetectorParams.loudness([Float](repeating: 0, count: 32), centre: nil, pair: [0, 1]).count, 32)
    }

    func testMappingTableNamesTheDetectorLanes() throws {
        for layout in [OutputProgramLayout.fiveOne, .sevenOneFour] {
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: layout.roles))
        let lfe = try XCTUnwrap(shape.lfeLane)
        let centre = try XCTUnwrap(shape.centerLane)
        for module in [ProductionDynamicsModule.compressor, .expander] {
            let on = DynamicsSessionMapping.mapping(for: module, shape: shape, virtualSpeakers: false, surroundDetector: true)
            XCTAssertTrue(on.lanes.contains(lfe), "the LFE still takes the gain")
            XCTAssertFalse(on.detectorLanes.contains(lfe))
            XCTAssertEqual(on.detectorLanes.count, shape.laneCount - 1)
            let off = DynamicsSessionMapping.mapping(for: module, shape: shape, virtualSpeakers: false, surroundDetector: false)
            XCTAssertTrue(off.detectorLanes.contains(lfe))
            XCTAssertTrue(DynamicsSessionMapping.actsOnText(for: module, shape: shape, virtualSpeakers: false, surroundDetector: true)
                .contains("LFE follows the gain"))
        }
        let leveler = DynamicsSessionMapping.mapping(for: .dialogueLeveler, shape: shape, virtualSpeakers: false, surroundDetector: true)
        XCTAssertTrue(leveler.detectorLanes.contains(centre))
        XCTAssertFalse(leveler.lanes.contains(centre), "the stage's pair stays the front pair")
        XCTAssertTrue(DynamicsSessionMapping.actsOnText(for: .dialogueLeveler, shape: shape, virtualSpeakers: false, surroundDetector: true)
            .contains("centre"))
        }
        // A stereo session has no LFE and no centre: the table is unchanged.
        let stereo = try XCTUnwrap(UnifiedGraphLayoutShape(roles: [.frontLeft, .frontRight]))
        for module in ProductionDynamicsModule.allCases {
            XCTAssertEqual(
                DynamicsSessionMapping.mapping(for: module, shape: stereo, virtualSpeakers: false, surroundDetector: true),
                DynamicsSessionMapping.mapping(for: module, shape: stereo, virtualSpeakers: false, surroundDetector: false), "\(module)")
        }
    }

    func testStereoSpecIsIdenticalWithTheFlagOnAndOffAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            try engine.replaceDynamicsConfiguration(dynamics())
            var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
            let stereo = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
            let roles: [OutputProgramRole] = [.frontLeft, .frontRight]
            let off = try spec(stereo, roles: roles, rate: rate, surround: false)
            let on = try spec(stereo, roles: roles, rate: rate, surround: true)
            XCTAssertEqual(on, off, "stereo \(rate)")
            var input = [[Float]](repeating: [], count: 2)
            let frames = Int(rate * 0.4)
            for lane in 0..<2 {
                input[lane] = (0..<frames).map { Float(0.3 * sin(2 * Double.pi * (500 + 300 * Double(lane)) * Double($0) / rate)) }
            }
            let a = try render(off, input: input), b = try render(on, input: input)
            XCTAssertEqual(a, b, "stereo render is bit-identical \(rate)")
        }
    }

    /// A 5.1 film-like signal: speech-band tone on the centre and fronts at a modest level, a loud 60 Hz effect on the LFE.
    /// With the flag on the LFE no longer drives the compressor, so the mains keep their level; with it off they duck.
    func testFilmLikeFiveOneKeepsTheMainsUnderLoudLFEAtEveryRate() throws {
        for rate in EQRenderHarness.rates {
            let engine = try engine(rate: rate)
            var compressorOnly = DynamicsConfiguration()
            compressorOnly.compressor.enabled = true
            try engine.replaceDynamicsConfiguration(compressorOnly)
            var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
            let stereo = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
            let roles = OutputProgramLayout.fiveOne.roles
            let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: roles))
            let lfe = try XCTUnwrap(shape.lfeLane)
            let on = try spec(stereo, roles: roles, rate: rate, surround: true)
            let off = try spec(stereo, roles: roles, rate: rate, surround: false)
            let compressor = try XCTUnwrap(on.stages.first { $0.kind == N60_STAGE_COMPRESSOR.rawValue })
            XCTAssertEqual(compressor.params.last, Float(lfe + 1), "the compressor excludes the LFE \(rate)")
            let offCompressor = try XCTUnwrap(off.stages.first { $0.kind == N60_STAGE_COMPRESSOR.rawValue })
            XCTAssertLessThan(offCompressor.params.count, compressor.params.count)
            let frames = Int(rate * 1.0)
            var input = [[Float]](repeating: [Float](repeating: 0, count: frames), count: roles.count)
            for lane in 0..<roles.count {
                for i in 0..<frames {
                    let t = Double(i) / rate
                    input[lane][i] = lane == lfe ? Float(0.9 * sin(2 * Double.pi * 60 * t)) : Float(0.05 * sin(2 * Double.pi * (800 + 150 * Double(lane)) * t))
                }
            }
            let outOn = try render(on, input: input), outOff = try render(off, input: input)
            let tail = (frames / 2)..<frames
            for lane in 0..<roles.count where lane != lfe {
                let reference = EQRenderHarness.rms(input[lane][tail])
                let kept = EQRenderHarness.rms(outOn[lane][tail]) / reference
                let ducked = EQRenderHarness.rms(outOff[lane][tail]) / reference
                XCTAssertEqual(kept, 1, accuracy: 0.03, "mains keep their level, lane \(lane) at \(rate)")
                XCTAssertLessThan(ducked, 0.9, "the LFE ducks them without the flag, lane \(lane) at \(rate)")
            }
        }
    }

    func testLevelerStageGainsTheCentreLaneOnlyOnLayoutsWithOne() throws {
        let rate = 48_000.0
        let engine = try engine(rate: rate)
        try engine.replaceDynamicsConfiguration(dynamics())
        var snapshot = try engine.stereoTransportStartGraph(sampleRate: rate)
        let stereo = try XCTUnwrap(UnifiedGraphTranslator.stereoConfiguration(snapshot: &snapshot, sampleRate: rate))
        let five = try spec(stereo, roles: OutputProgramLayout.fiveOne.roles, rate: rate, surround: true)
        let loudness = try XCTUnwrap(five.stages.first { $0.kind == N60_STAGE_LOUDNESS.rawValue })
        let shape = try XCTUnwrap(UnifiedGraphLayoutShape(roles: OutputProgramLayout.fiveOne.roles))
        XCTAssertEqual(loudness.params.count, 33)
        XCTAssertEqual(loudness.params.last, Float(try XCTUnwrap(shape.centerLane) + 1))
        let twoLane = try spec(stereo, roles: [.frontLeft, .frontRight], rate: rate, surround: true)
        XCTAssertEqual(twoLane.stages.first { $0.kind == N60_STAGE_LOUDNESS.rawValue }?.params.count, 32)
    }
}
