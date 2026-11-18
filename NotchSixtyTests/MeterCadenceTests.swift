import XCTest
@testable import NotchSixty

/// E32 S3: meter loop cadence, gain-reduction monitor rates and idling, token-based analysis demand, the loudness
/// histograms, the peak label rule and the clip latch after a counter reset.
@MainActor
final class MeterCadenceTests: XCTestCase {
    private final class FakeVisibility: MeterVisibilityProviding {
        var metersAreVisible = true
    }

    private func makeHub(visibility: FakeVisibility, processing: @escaping () -> Bool = { true }) -> MeterReadbackHub<ProductionMeterContext> {
        MeterReadbackHub<ProductionMeterContext>(visibility: visibility, isProcessing: processing, source: { nil })
    }

    // MARK: Policy (R15)

    func testPolicyTableHiddenStoppedRunningAndEachPage() {
        for page in ProductionMetersPage.allCases {
            for running in [false, true] {
                XCTAssertEqual(MeterPollPolicy.schedule(windowVisible: false, isRunning: running, page: page), .idle,
                               "hidden is idle whatever the lifecycle (\(page), running \(running))")
            }
            XCTAssertEqual(MeterPollPolicy.schedule(windowVisible: true, isRunning: false, page: page), .once,
                           "stopped and visible draws once (\(page))")
        }
        let expected: [ProductionMetersPage: Double] = [.levels: 60, .stereo: 60, .spectrum: 20, .dynamics: 8, .transport: 4]
        for (page, hertz) in expected {
            XCTAssertEqual(MeterPollPolicy.schedule(windowVisible: true, isRunning: true, page: page), .every(hertz: hertz))
        }
    }

    // MARK: Hub rate and monitor (R16, R17)

    func testHubPollsAtEightHertzWithOnlyThePageAndAtThirtyWithTheMonitor() {
        let visibility = FakeVisibility()
        let hub = makeHub(visibility: visibility)
        let page = hub.subscribe(hertz: MeterPollPolicy.hertz(for: .dynamics))
        XCTAssertEqual(hub.currentHertz, 8)
        let monitor = GainReductionMonitor(hub: { hub }, clock: { 0 })
        let a = monitor.attach(hertz: GainReductionMonitor.pageHertz)
        XCTAssertEqual(hub.currentHertz, 30, "Meters > Dynamics bars ask for 30 Hz")
        let row = monitor.attach(hertz: GainReductionMonitor.rowHertz)
        XCTAssertEqual(hub.subscriberCount, 2, "one hub subscription for the monitor however many views attach")
        monitor.detach(a)
        XCTAssertEqual(hub.currentHertz, 10, "the fastest remaining client sets the rate")
        monitor.detach(row)
        XCTAssertEqual(hub.currentHertz, 8)
        XCTAssertEqual(hub.subscriberCount, 1)
        hub.unsubscribe(page)
    }

    func testMonitorLoopDoesNoWorkWhileTheHubIsNotPolling() {
        let visibility = FakeVisibility()
        var processing = true
        let hub = makeHub(visibility: visibility, processing: { processing })
        var now = 0.0
        let monitor = GainReductionMonitor(hub: { hub }, clock: { now })
        let id = monitor.attach()
        visibility.metersAreVisible = false
        let before = monitor.textRevision
        for _ in 0..<20 { XCTAssertFalse(monitor.tick(), "hidden window") }
        visibility.metersAreVisible = true
        processing = false
        for _ in 0..<20 { XCTAssertFalse(monitor.tick(), "audio stopped") }
        XCTAssertEqual(monitor.textRevision, before)
        XCTAssertTrue(monitor.timelinesPaused)
        processing = true
        now = 1
        XCTAssertTrue(monitor.tick())
        monitor.detach(id)
    }

    func testTimelinesPauseAtRestAndWakeOnReduction() {
        let monitor = GainReductionMonitor(hub: { nil }, clock: { 0 })
        func reading(_ db: Float) -> [String: MeterChannelReading] {
            [GainReductionSource.limiter.channelID: MeterChannelReading(peakLinear: db, rmsLinear: 0, overRangeSamples: nil, truePeakLinear: nil)]
        }
        monitor.ingest([:], now: 0)
        XCTAssertTrue(monitor.isAtRest)
        let revision = monitor.textRevision
        monitor.ingest(reading(5), now: 0.01)
        XCTAssertFalse(monitor.isAtRest)
        XCTAssertGreaterThan(monitor.textRevision, revision, "the change is published at once")
        // 10 s of silence at 30 Hz: the history and the 1 s hold are empty again.
        var t = 0.01
        for _ in 0..<400 { t += 1.0 / 30; monitor.ingest([:], now: t) }
        XCTAssertTrue(monitor.isAtRest)
    }

    // MARK: Demand tokens (R21)

    func testPageSwitchKeepsTheNewPagesDemandWhicheverTeardownRunsFirst() {
        var applied: [UInt32] = []
        let ledger = AnalysisDemandLedger { applied.append($0) }
        let levels: UInt32 = 0b0011
        let spectrum: UInt32 = 0b0100
        let stereo: UInt32 = 0b1000
        // Levels -> Spectrum: the new task acquires before the old one releases.
        let l = ledger.acquire(levels)
        let s = ledger.acquire(spectrum)
        ledger.release(l)
        XCTAssertEqual(ledger.effective, spectrum)
        // Spectrum -> Dynamics (no demand, so no token): the old task's release clears it.
        ledger.release(s)
        XCTAssertEqual(ledger.effective, 0)
        XCTAssertEqual(applied.last, 0)
        // Old teardown after the new acquire, in the other order, and a repeated release.
        let a = ledger.acquire(spectrum)
        let b = ledger.acquire(stereo)
        ledger.release(b)
        XCTAssertEqual(ledger.effective, spectrum)
        ledger.release(b)
        XCTAssertEqual(ledger.effective, spectrum, "an unknown or repeated token changes nothing")
        ledger.release(a)
        XCTAssertEqual(ledger.effective, 0)
    }

    // MARK: Loudness histograms (R18)

    func testHistoryTrimPlusTwoHundredSecondsMatchesTheExactSortAndKeepsUpdating() {
        var meter = LoudnessMeter(sampleRate: 48_000)
        // The 24 h limit is lowered so the debug build stays quick; the trim path is the same code.
        meter.historyLimit = 150_000
        let blocks = meter.historyLimit + 1_000 + 2_000   // past the first trim, then 200 s more
        func powers(_ i: Int) -> (Double, Double) {
            let x = Double(i)
            let block = -23 + 7 * sin(x * 0.0007) + 3 * sin(x * 0.013) - (i % 5000 < 300 ? 18 : 0)
            let short = -23 + 5 * sin(x * 0.0005) + 2 * sin(x * 0.011) - (i % 7000 < 800 ? 25 : 0)
            return (LoudnessMeter.power(loudness: block), LoudnessMeter.power(loudness: short))
        }
        let tail = 2_000
        for i in 0..<(blocks - tail) {
            let (b, s) = powers(i)
            meter.appendSyntheticForTesting(blockPower: b, shortTermPower: s)
        }
        var changes = 0
        var last = meter.readout()
        for i in (blocks - tail)..<blocks {
            let (b, s) = powers(i)
            meter.appendSyntheticForTesting(blockPower: b, shortTermPower: s)
            let now = meter.readout()
            if now.integrated != last.integrated || now.range != last.range { changes += 1 }
            last = now
        }
        XCTAssertGreaterThanOrEqual(changes, tail / 20, "I and LRA refresh every 10 blocks after the trim")
        let fast = meter.readout()
        let exact = meter.exactReadout()
        XCTAssertEqual(fast.integrated ?? .nan, exact.integrated ?? .infinity, accuracy: 0.01)
        XCTAssertEqual(fast.range ?? .nan, exact.range ?? .infinity, accuracy: 0.01)
    }

    func testHistogramMatchesTheExactGateOnAShortProgramAndResets() {
        var meter = LoudnessMeter(sampleRate: 48_000)
        for i in 0..<3_000 {
            let loud = -20 + 8 * sin(Double(i) * 0.01) - (i % 400 < 120 ? 30 : 0)
            meter.appendSyntheticForTesting(
                blockPower: LoudnessMeter.power(loudness: loud), shortTermPower: LoudnessMeter.power(loudness: loud - 1))
        }
        let fast = meter.readout()
        let exact = meter.exactReadout()
        XCTAssertEqual(fast.integrated ?? .nan, exact.integrated ?? .infinity, accuracy: 0.01)
        XCTAssertEqual(fast.range ?? .nan, exact.range ?? .infinity, accuracy: 0.01)
        meter.reset()
        XCTAssertNil(meter.readout().integrated)
        XCTAssertNil(meter.readout().range)
    }

    // MARK: Labels (R20) and latch (R22)

    func testPeakLabelAtTheEightRatesAndFactors() {
        let rates = [44_100.0, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
        for rate in rates {
            for factor in [1, 2, 4] {
                let expected = rate * Double(factor) >= 176_400 ? "dBTP" : "dBFS peak"
                XCTAssertEqual(PeakLabel.suffix(sampleRate: rate, detectionFactor: factor), expected, "\(rate) x\(factor)")
            }
        }
        XCTAssertEqual(PeakLabel.suffix(sampleRate: 44_100, detectionFactor: 4), "dBTP", "4x at 44.1 kHz is the BS.1770-4 case")
        XCTAssertEqual(PeakLabel.suffix(sampleRate: 48_000, detectionFactor: 1), "dBFS peak")
    }

    func testLatchSurvivesACounterReset() {
        var latch = MeterClipLatch()
        latch.update(overRangeCount: 40, truePeakDBTP: nil)   // baseline
        latch.update(overRangeCount: 0, truePeakDBTP: nil)    // Stop/Start reset
        XCTAssertFalse(latch.isLatched, "a reset to zero is not a clip")
        latch.update(overRangeCount: 3, truePeakDBTP: nil)
        XCTAssertTrue(latch.isLatched, "clips counted since the reset latch even though 3 is below the old 40")
        var other = MeterClipLatch()
        other.update(overRangeCount: 50, truePeakDBTP: nil)
        other.update(overRangeCount: 2, truePeakDBTP: nil)
        XCTAssertTrue(other.isLatched, "a lower non-zero count is a reset with clips")
    }
}
