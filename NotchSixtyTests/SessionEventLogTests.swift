import XCTest
@testable import NotchSixty

final class SessionEventLogTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    private func sample(_ at: TimeInterval, _ edit: (inout SessionEventSample) -> Void = { _ in }) -> SessionEventSample {
        var s = SessionEventSample(now: t0 + at)
        edit(&s)
        return s
    }

    func testClipAndTruePeakAppearOncePerEpisodeAndMerge() {
        var log = SessionEventLog()
        log.observe(sample(0) { $0.clipSamples = ["Input L": 3]; $0.truePeakLinear = ["Output": 1.2] })
        log.observe(sample(0.5) { $0.clipSamples = ["Input L": 2]; $0.truePeakLinear = ["Output": 1.4] })
        XCTAssertEqual(log.events.count, 2)
        let clip = log.events.first { $0.kind == .clip }
        XCTAssertEqual(clip?.count, 2)
        XCTAssertEqual(clip?.amount, 3, "merged clip keeps the largest burst")
        let tp = log.events.first { $0.kind == .truePeakOver }
        XCTAssertEqual(tp?.amount ?? 0, 20 * log10(1.4), accuracy: 1e-5)
        // Outside the merge window a new event starts.
        log.observe(sample(10) { $0.clipSamples = ["Input L": 1] })
        XCTAssertEqual(log.events.filter { $0.kind == .clip }.count, 2)
        // A different channel is a different event.
        log.observe(sample(10.1) { $0.clipSamples = ["Input R": 1] })
        XCTAssertEqual(log.events.filter { $0.kind == .clip }.count, 3)
    }

    func testLimiterEpisodeIsOneEventWithPeakAndDuration() {
        var log = SessionEventLog()
        log.observe(sample(0) { $0.limiterReductionDB = 2 })
        XCTAssertTrue(log.events.isEmpty, "below the 3 dB depth")
        for (i, db) in [Float(3.5), 6.0, 4.0].enumerated() {
            log.observe(sample(1 + Double(i) * 0.25) { $0.limiterReductionDB = db })
        }
        log.observe(sample(2) { $0.limiterReductionDB = 0 })
        XCTAssertEqual(log.events.count, 1)
        XCTAssertEqual(log.events[0].amount, 6, accuracy: 1e-6)
        XCTAssertEqual(log.events[0].lastTime.timeIntervalSince(log.events[0].time), 0.5, accuracy: 1e-9)
        XCTAssertFalse(log.events[0].episodeOpen)
        // A second episode far later is its own event.
        log.observe(sample(30) { $0.limiterReductionDB = 5 })
        log.observe(sample(31) { $0.limiterReductionDB = 0 })
        XCTAssertEqual(log.events.count, 2)
    }

    func testProtectionDropoutRecoveryAndRateChange() {
        var log = SessionEventLog()
        log.observe(sample(0) { $0.underrunFrames = 10; $0.recoveryAttempts = 0; $0.sampleRate = 48_000 })
        XCTAssertTrue(log.events.isEmpty, "first sample is the baseline")
        log.observe(sample(1) {
            $0.underrunFrames = 10 + 512; $0.overrunFrames = 128; $0.protectionReductionDB = ["Output 2": 1.5]
            $0.recoveryAttempts = 1; $0.recoverySuccesses = 1; $0.sampleRate = 96_000
        })
        let kinds = Set(log.events.map(\.kind))
        XCTAssertEqual(kinds, [.dropout, .protection, .deviceLoss, .deviceRecovered, .rateChange])
        XCTAssertEqual(log.events.first { $0.kind == .dropout }?.amount, 640)
        XCTAssertEqual(log.events.first { $0.kind == .protection }?.place, "Output 2")
        // Counters falling (a new transport session) make no dropout.
        log.observe(sample(20) { $0.underrunFrames = 0 })
        XCTAssertEqual(log.events.filter { $0.kind == .dropout }.count, 1)
    }

    func testCapDropsOldestAndSinceFilter() {
        var log = SessionEventLog()
        for i in 0..<(SessionEventLog.capacity + 20) {
            log.observe(sample(Double(i) * 10) { $0.clipSamples = ["Input L": UInt64(i + 1)] })
        }
        XCTAssertEqual(log.events.count, SessionEventLog.capacity)
        XCTAssertEqual(log.events.first?.amount, 21, "the oldest twenty were dropped")
        let since = t0 + Double(SessionEventLog.capacity + 10) * 10
        XCTAssertEqual(log.events(since: since).count, 10)
        log.clear()
        XCTAssertTrue(log.events.isEmpty)
    }

    func testSampleBuilderMapsFramesAndSkipsGainReductionChannels() {
        let channels: [String: MeterChannelReading] = [
            "input.L": MeterChannelReading(peakLinear: 1, rmsLinear: 0, overRangeSamples: 4, truePeakLinear: 1.1),
            "input.R": MeterChannelReading(peakLinear: 1, rmsLinear: 0, overRangeSamples: 0, truePeakLinear: 1.1),
            "gr.limiter": MeterChannelReading(peakLinear: 9, rmsLinear: 0, overRangeSamples: 7, truePeakLinear: nil),
        ]
        XCTAssertEqual(SessionEventSample.placeName("postEQ.R"), "Post-EQ R")
        XCTAssertEqual(SessionEventSample.placeName("output.truePeak"), "Output")
        var s = SessionEventSample(now: t0)
        for (id, r) in channels where !id.hasPrefix("gr.") {
            if let o = r.overRangeSamples, o > 0 { s.clipSamples[SessionEventSample.placeName(id)] = o }
        }
        XCTAssertEqual(s.clipSamples, ["Input L": 4])
    }

    @MainActor
    func testHistoryPersistsPreviousSessionAndKeepsDropoutCounterAcrossReads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("n60-events-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SessionEventStore(url: url)
        let first = SessionEventHistory(store: store)
        first.observe(sample(0) { $0.clipSamples = ["Input L": 1]; $0.underrunFrames = 5 })
        first.observe(sample(1) { $0.underrunFrames = 5 })
        first.observe(sample(2) { $0.underrunFrames = 105 })
        XCTAssertEqual(first.dropouts.events, 1, "the hub-held counter counts from session start")
        XCTAssertEqual(first.dropouts.frames, 100)
        first.noteStopped()
        XCTAssertEqual(first.dropouts.events, 0, "a new session resets it")
        let second = SessionEventHistory(store: store)
        XCTAssertEqual(second.previous.count, 2, "clip and dropout events survive relaunch as the previous session")
        XCTAssertTrue(second.log.events.isEmpty)
        XCTAssertTrue(second.exportText().contains("Input L"))
        XCTAssertTrue(second.exportText().contains("Previous session"))
    }

    func testRowSummaryIsAReadableSentence() {
        let e = SessionEvent(id: UUID(), time: t0, lastTime: t0, kind: .dropout, place: "", amount: 640, count: 3)
        XCTAssertEqual(e.summary(timeText: "12:00:00"), "12:00:00 · Dropout · 640 frames (x3)")
    }
}
