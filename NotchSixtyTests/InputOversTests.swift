import XCTest
@testable import NotchSixty

/// E33 S10: the input-over reading through the production host (UnifiedGraphHost over the real core), the card model
/// and the History event.
final class InputOversTests: XCTestCase {
    private let rates: [Double] = [44_100, 48_000, 88_200, 96_000, 176_400, 192_000, 352_800, 384_000]
    private let block = 512

    private func host(rate: Double) throws -> UnifiedGraphHost {
        var spec = try UnifiedGraphConfiguration(sampleRate: rate, lanes: [UnifiedGraphLane(), UnifiedGraphLane()]).makeSpec()
        // The translator adds the detector parameters with the flag on; the test wants them whatever the process flag is.
        let index = try XCTUnwrap(spec.stages.firstIndex { $0.stageId == UInt32(N60_LSTAGE_METER_IN) })
        spec.stages[index].params = [0, 0]
        return try UnifiedGraphHost(spec: spec)
    }

    /// fs/4 sine at 45 degrees: samples at 0.707 of the peak, so the sample peak stays below 0 dBFS at a +1.5 dBTP peak.
    private func render(_ host: UnifiedGraphHost, rate: Double, peakDB: Double, seconds: Double = 0.2) throws {
        let amp = pow(10, peakDB / 20)
        let factor = InputOversReading.factor(sampleRate: rate)
        let frames = Int(seconds * rate) / block * block
        var position = 0
        while position < frames {
            let samples: [Float] = (0..<block).map { i in
                let n = Double(position + i)
                return factor > 1 ? Float(amp * sin(0.5 * .pi * n + 0.25 * .pi)) : Float(amp * sin(2 * .pi * 1_000 * n / rate))
            }
            _ = try host.processOffline(input: [samples, samples], frames: block)
            position += block
        }
    }

    func testDetectorCountsOnlyWhileSwitchedOnAndResets() throws {
        for rate in rates {
            let host = try host(rate: rate)
            try render(host, rate: rate, peakDB: 1.5)
            XCTAssertEqual(host.inputOvers(lanes: 2), [0, 0], "detect off counts nothing at \(rate)")
            XCTAssertTrue(host.setInputOverDetect(true))
            try render(host, rate: rate, peakDB: -1)
            XCTAssertEqual(host.inputOvers(lanes: 2), [0, 0], "-1 dBTP counts zero at \(rate)")
            try render(host, rate: rate, peakDB: 1.5)
            let counts = try XCTUnwrap(host.inputOvers(lanes: 2))
            XCTAssertGreaterThan(counts[0], 0, "+1.5 dBTP counts at \(rate)")
            XCTAssertEqual(counts[0], counts[1])
            XCTAssertEqual(host.inputOvers(lanes: 2), counts, "a read does not clear")
            // A spec applied later keeps the live detector state and the counts.
            let spec = host.spec
            _ = try host.apply(spec)
            // Silence first, so the tone's reconstruction ring-down (a few overs after the step) is not counted after the clear.
            let silence = [Float](repeating: 0, count: block)
            for _ in 0..<2 { _ = try host.processOffline(input: [silence, silence], frames: block) }
            host.resetInputOvers()
            for _ in 0..<2 { _ = try host.processOffline(input: [silence, silence], frames: block) }
            XCTAssertEqual(host.inputOvers(lanes: 2), [0, 0], "a new generation clears at \(rate)")
            host.release()
        }
    }

    func testGraphWithoutDetectorHasNoReading() throws {
        let spec = try UnifiedGraphConfiguration(sampleRate: 48_000, lanes: [UnifiedGraphLane(), UnifiedGraphLane()]).makeSpec()
        var plain = spec
        if let index = plain.stages.firstIndex(where: { $0.stageId == UInt32(N60_LSTAGE_METER_IN) }) { plain.stages[index].params = [] }
        let host = try UnifiedGraphHost(spec: plain)
        XCTAssertNil(host.inputOvers(lanes: 2))
        XCTAssertFalse(host.setInputOverDetect(true))
        host.release()
    }

    func testReadingModelBaselinesResetsAndLabelsHighRates() {
        var reading = InputOversReading()
        let t = Date(timeIntervalSince1970: 100)
        reading.update(counts: [5, 7], sampleRate: 48_000, now: t)
        XCTAssertEqual(reading.total, 0, "counts before the page was shown are not shown")
        reading.update(counts: [8, 7], sampleRate: 48_000, now: t)
        XCTAssertEqual(reading.perLane, [3, 0])
        XCTAssertEqual(reading.title, "Input overs")
        reading.reset()
        XCTAssertEqual(reading.total, 0)
        reading.update(counts: [0, 0], sampleRate: 192_000, now: t)  // core generation reset
        XCTAssertEqual(reading.total, 0)
        XCTAssertEqual(reading.title, "Sample overs")
        XCTAssertTrue(reading.note.contains("0.56 dB"))
        for (rate, factor) in zip(rates, [4, 4, 2, 2, 1, 1, 1, 1] as [UInt32]) {
            XCTAssertEqual(InputOversReading.factor(sampleRate: rate), factor)
        }
    }

    func testHistoryRecordsAnInputOverEventPerLane() {
        var log = SessionEventLog()
        let t = Date(timeIntervalSince1970: 1_000)
        log.observeInputOvers(counts: [4, 0], at: t)
        XCTAssertTrue(log.events.isEmpty, "the first reading is the baseline")
        log.observeInputOvers(counts: [9, 0], at: t + 1)
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events[0].kind, .inputOver)
        XCTAssertEqual(log.events[0].place, "Input 1")
        XCTAssertEqual(log.events[0].amount, 5)
        log.observeInputOvers(counts: [0, 0], at: t + 2)  // reset: no event
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events[0].detail, "5 overs")
    }
}
