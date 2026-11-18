import XCTest
@testable import NotchSixty

/// E33 S7: the loudness card's maxima, 10 minute history and target, and the one gain-reduction reader with its total.
@MainActor
final class LoudnessAndGainReductionTests: XCTestCase {
    private func makeMonitor() -> GainReductionMonitor { GainReductionMonitor(hub: { nil }, clock: { 0 }) }

    private func feed(_ monitor: GainReductionMonitor, _ values: [GainReductionSource: Float], now: Double = 1) {
        var readings: [String: MeterChannelReading] = [:]
        for (source, db) in values {
            readings[source.channelID] = MeterChannelReading(peakLinear: db, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)
        }
        monitor.ingest(readings, now: now)
    }

    // MARK: Loudness maxima (C5)

    func testTech3341SineGivesBothMaximaWithinTenthOfALUAtEveryRate() {
        for rate in LoudnessMeterTests.rates {
            var meter = LoudnessMeter(sampleRate: rate)
            var tone = LoudnessMeterTests.ToneFeeder()
            tone.feed(&meter, levels: [-23, -23], seconds: 20)
            let r = meter.exactReadout()
            XCTAssertEqual(r.momentaryMax ?? .nan, -23, accuracy: 0.1, "M max \(rate)")
            XCTAssertEqual(r.shortTermMax ?? .nan, -23, accuracy: 0.1, "S max \(rate)")
        }
    }

    // MARK: History (C6)

    func testHistoryHoldsTenMinutesAtOnePointPerSecond() {
        var history = LoudnessShortTermHistory()
        for second in 0..<1_000 { history.ingest(-20, at: Double(second)) }
        XCTAssertEqual(history.points.count, LoudnessShortTermHistory.capacity)
        XCTAssertEqual(history.points.count, 600)
        XCTAssertEqual(history.points.last?.time, 999)
        XCTAssertGreaterThan(history.points.first?.time ?? 0, 999 - LoudnessShortTermHistory.windowSeconds)
    }

    func testHistoryThinsFastFeedsKeepsGapsAndResets() {
        var history = LoudnessShortTermHistory()
        for i in 0..<100 { history.ingest(-20, at: Double(i) * 0.1) }
        XCTAssertEqual(history.points.count, 10, "ten seconds at a 10 Hz feed is ten points")
        history.ingest(nil, at: 20)
        XCTAssertNil(history.points.last?.lufs)
        history.ingest(.nan, at: 21)
        XCTAssertNil(history.points.last?.lufs)
        history.reset()
        XCTAssertTrue(history.points.isEmpty)
    }

    func testTargetFollowsLoudnessMatchWhenOnElseTheChosenValue() {
        let on = LoudnessHistoryTarget.lufs(matchEnabled: true, matchTarget: -18.5, chosen: .minus14)
        XCTAssertEqual(on.lufs, -18.5); XCTAssertTrue(on.fromMatch)
        let off = LoudnessHistoryTarget.lufs(matchEnabled: false, matchTarget: -18.5, chosen: .minus23)
        XCTAssertEqual(off.lufs, -23); XCTAssertFalse(off.fromMatch)
        XCTAssertEqual(Set(LoudnessHistoryTarget.allCases.map(\.rawValue)), [-14, -16, -23])
    }

    func testLabelsSeparateTheMatchDetectorFromShortTerm() {
        XCTAssertEqual(LoudnessHistoryText.matchDetectorLabel, "Match detector (3 s smoothed)")
        XCTAssertEqual(LoudnessHistoryText.integratedNote, "Integrated: last 24 h")
        XCTAssertTrue(LoudnessHistoryText.target((-16, true)).contains("Loudness Match"))
    }

    // MARK: One reader, total (B2b, C7)

    func testTotalEqualsTheSumOfActiveSourcesAndIgnoresOffProcessors() {
        let monitor = makeMonitor()
        feed(monitor, [.compressor: 3, .limiter: 2, .deEsser: 4, .expander: 1.5])
        var d = DynamicsConfiguration()
        d.compressor.enabled = true
        d.limiter.enabled = true
        d.deEsser.enabled = false
        d.expander.enabled = false
        let result = TotalGainReduction.compute(configuration: d, latest: { monitor.latest($0) })
        XCTAssertEqual(result.totalDB, 5, accuracy: 1e-5)
        XCTAssertEqual(Set(result.counted), [.compressor, .limiter])
        d.deEsser.enabled = true
        XCTAssertEqual(TotalGainReduction.compute(configuration: d, latest: { monitor.latest($0) }).totalDB, 9, accuracy: 1e-5)
    }

    func testMultibandCountsOnlyTheBandsOfTheSplit() {
        let monitor = makeMonitor()
        feed(monitor, [.multibandLow: 1, .multibandMid: 1, .multibandHigh: 1, .multibandBand4: 1, .multibandBand5: 1])
        var d = DynamicsConfiguration()
        d.multibandCompressor.enabled = true
        d.multibandCompressor.setBandCount(3)
        XCTAssertEqual(TotalGainReduction.compute(configuration: d, latest: { monitor.latest($0) }).totalDB, 3, accuracy: 1e-5)
        d.multibandCompressor.setBandCount(5)
        XCTAssertEqual(TotalGainReduction.compute(configuration: d, latest: { monitor.latest($0) }).totalDB, 5, accuracy: 1e-5)
    }

    func testProcessorsWithoutTelemetryAreListedNotCounted() {
        var d = DynamicsConfiguration()
        d.gainRider.enabled = true
        d.loudnessMatch.enabled = true
        let result = TotalGainReduction.compute(configuration: d, latest: { _ in 9 })
        XCTAssertEqual(result.totalDB, 0)
        XCTAssertEqual(result.notCounted, ["Gain rider", "Loudness Match"])
        XCTAssertEqual(TotalGainReduction.note(result), "Not counted (no gain-reduction reading): Gain rider, Loudness Match.")
        XCTAssertNil(TotalGainReduction.note(TotalGainReduction.compute(configuration: DynamicsConfiguration(), latest: { _ in 0 })))
    }

    func testBothPagesReadEqualReductionFromOneHubFeed() {
        // Meters > Dynamics and the Dynamics page both read `GainReductionMonitor.latest`, so one feed gives one number.
        let monitor = makeMonitor()
        feed(monitor, [.compressor: 6.25, .limiter: 1.5])
        for source in GainReductionSource.allCases {
            let dynamicsPage = monitor.latest(source)
            let metersPage = monitor.history(source).latest
            XCTAssertEqual(dynamicsPage, metersPage)
        }
        XCTAssertEqual(monitor.latest(.compressor), 6.25)
        XCTAssertEqual(monitor.latest(.limiter), 1.5)
    }

    func testStoppedReadsDashNotAStaleTotal() {
        XCTAssertEqual(TotalGainReduction.text(nil), "—")
        XCTAssertEqual(TotalGainReduction.text(.init(totalDB: 4.5, counted: [], notCounted: [])), "4.5 dB")
    }
}
