import XCTest
@testable import NotchSixty

/// E33 S5a: the expander lookahead reaches the core only with the page flag on, as the 14-value block; it is counted in the
/// reported latency and is a lookahead-only (linear fade) rebuild.
final class ExpanderLookaheadTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]

    func testFlagOffPublishesTheThirteenValueBlockWhateverIsStored() {
        var e = ExpanderConfiguration()
        e.lookaheadMs = 5
        XCTAssertEqual(e.coreExtras(sampleRate: 48_000, lookahead: false).count, 7)
        XCTAssertEqual(e.coreExtras(sampleRate: 48_000, lookahead: false), ExpanderConfiguration().coreExtras())
    }

    func testLookaheadFramesAtEveryRate() {
        for rate in rates {
            var e = ExpanderConfiguration()
            XCTAssertEqual(e.coreExtras(sampleRate: rate, lookahead: true).last, 0, "\(rate): off is 0 frames")
            e.lookaheadMs = 5
            let extras = e.coreExtras(sampleRate: rate, lookahead: true)
            XCTAssertEqual(extras.count, 8)
            XCTAssertEqual(Int(extras[7]), CompressorConfiguration.lookaheadFrames(ms: 5, sampleRate: rate))
            XCTAssertGreaterThan(extras[7], 0)
        }
    }

    func testTranslatorAcceptsTheEighthExtra() throws {
        var d = DynamicsConfiguration()
        d.expander.enabled = true
        d.expander.lookaheadMs = 4
        let frames = CompressorConfiguration.lookaheadFrames(ms: 4, sampleRate: 48_000)
        let block = [Float(-120), 2, -12, 5, 100, 1] + d.expander.coreExtras(sampleRate: 48_000, lookahead: true)
        XCTAssertEqual(block.count, 14)
        XCTAssertEqual(Int(block[13]), frames)
    }

    func testLatencyCountsTheExpanderOnlyWithTheFlag() {
        for rate in rates {
            var d = DynamicsConfiguration()
            d.expander.enabled = true
            d.expander.lookaheadMs = 6
            let frames = CompressorConfiguration.lookaheadFrames(ms: 6, sampleRate: rate)
            XCTAssertEqual(DynamicsLatency.programFrames(d, sampleRate: rate, flagOn: true, expanderLookahead: true), frames)
            XCTAssertEqual(DynamicsLatency.stages(d, sampleRate: rate, flagOn: true, expanderLookahead: true).map(\.name), ["Expander lookahead"])
            XCTAssertEqual(DynamicsLatency.programFrames(d, sampleRate: rate, flagOn: true, expanderLookahead: false), 0)
            d.expander.enabled = false
            XCTAssertEqual(DynamicsLatency.programFrames(d, sampleRate: rate, flagOn: true, expanderLookahead: true), 0)
        }
    }

    func testExpanderLookaheadEditIsALookaheadOnlyRebuild() {
        var a = DynamicsConfiguration(), b = DynamicsConfiguration()
        a.expander.lookaheadMs = 3
        b.expander.lookaheadMs = 7
        XCTAssertTrue(a.differsOnlyInLookahead(from: b))
        b.expander.thresholdDB = -40
        XCTAssertFalse(a.differsOnlyInLookahead(from: b))
    }

    func testOldProfilesDecodeAsOffAndRangeIsValidated() throws {
        let e = try JSONDecoder().decode(ExpanderConfiguration.self, from: Data(#"{"enabled":true,"thresholdDB":-35,"ratio":1.5,"rangeDB":-12,"attackMs":5,"releaseMs":200}"#.utf8))
        XCTAssertNil(e.lookaheadMs)
        XCTAssertFalse(e.lookaheadOn)
        var bad = ExpanderConfiguration()
        bad.lookaheadMs = 11
        XCTAssertThrowsError(try bad.validate())
        bad.lookaheadMs = 10
        XCTAssertNoThrow(try bad.validate())
    }
}
