import XCTest
@testable import NotchSixty

final class SignalGeneratorSettingsTests: XCTestCase {
    func testDefaultsAreSafe() {
        let s = SignalGeneratorSettings()
        XCTAssertEqual(s.levelDB, -20)
        XCTAssertEqual(s.ceilingDB, -6)
        XCTAssertEqual(s.autoStopSeconds, 600)
        XCTAssertTrue(s.stopOnOutputChange)
        XCTAssertEqual(s.stageParams(active: true, sampleRate: 48_000)?.count, 11)
    }

    func testLevelIsClampedToCeiling() {
        var s = SignalGeneratorSettings()
        s.levelDB = 0
        XCTAssertEqual(s.effectiveLevelDB, -6)
        s.ceilingDB = -30
        XCTAssertEqual(s.effectiveLevelDB, -30)
    }

    func testRejectsCeilingAboveHardLimitAndLongAutoStop() {
        var s = SignalGeneratorSettings()
        s.ceilingDB = -3
        XCTAssertNil(s.stageParams(active: true, sampleRate: 48_000))
        s = SignalGeneratorSettings()
        s.autoStopSeconds = 601
        XCTAssertNil(s.stageParams(active: true, sampleRate: 48_000))
    }

    func testOctaveAndThirdOctaveEdges() {
        let o = SignalGeneratorSettings.bandEdges(centerHz: 1000, bandFraction: 1)
        XCTAssertEqual(o.high / o.low, 2, accuracy: 1e-9)
        let t = SignalGeneratorSettings.bandEdges(centerHz: 1000, bandFraction: 3)
        XCTAssertEqual(t.high / t.low, pow(2, 1.0 / 3.0), accuracy: 1e-9)
        XCTAssertEqual((o.low * o.high).squareRoot(), 1000, accuracy: 1e-9)
    }

    func testBandAndSineLimitsFollowSampleRate() {
        var s = SignalGeneratorSettings()
        s.selectBand(centerHz: 16_000, bandFraction: 1)
        for rate in [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000] {
            XCTAssertEqual(s.stageParams(active: true, sampleRate: rate) != nil, s.highHz <= 0.45 * rate, "\(rate)")
        }
        s.kind = .sine
        s.sineHz = 30_000
        XCTAssertNil(s.stageParams(active: true, sampleRate: 48_000))
        XCTAssertNotNil(s.stageParams(active: true, sampleRate: 96_000))
    }

    func testSpecContainsGeneratorAfterInputGain() throws {
        var config = UnifiedGraphConfiguration(
            sampleRate: 48_000, lanes: [UnifiedGraphLane(outputGain: 1, eq: []), UnifiedGraphLane(outputGain: 1, eq: [])])
        config.generatorParams = SignalGeneratorSettings().stageParams(active: true, sampleRate: 48_000)
        let spec = try config.makeSpec()
        let kinds = spec.stages.map(\.kind)
        let gen = try XCTUnwrap(kinds.firstIndex(of: N60_STAGE_GENERATOR.rawValue))
        let gain = try XCTUnwrap(spec.stages.firstIndex { $0.stageId == N60_LSTAGE_INPUT_GAIN })
        XCTAssertEqual(gen, gain + 1)
        config.generatorParams = [1, 2]
        XCTAssertThrowsError(try config.makeSpec())
    }
}
