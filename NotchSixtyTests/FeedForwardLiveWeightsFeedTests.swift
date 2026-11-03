import XCTest
@testable import NotchSixty

/// E4 S25 follow-up: the policy that publishes the shadow's weights to the live mailbox.
@MainActor
final class FeedForwardLiveWeightsFeedTests: XCTestCase {
    private final class Sink: FeedForwardLiveWeightsSink {
        var accepts = true
        var sets: [([Float], [Float])] = []
        func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
            guard accepts else { return false }
            sets.append((left, right))
            return true
        }
    }

    private func weights(_ scale: Float, count: Int = 512) -> [Float] {
        (0..<count).map { scale * Float(sin(Double($0) * 0.1)) }
    }

    private func settle(_ feed: inout FeedForwardLiveWeightsFeed, sink: Sink, polls: Int = FeedForwardLiveWeightsFeed.minimumPolls) {
        for _ in 0..<polls { _ = feed.offer(left: [], right: [], guardState: .arming, sink: sink) }
    }

    func testFirstClearSetIsPublishedAndNothingElseUntilItChanges() {
        let sink = Sink()
        var feed = FeedForwardLiveWeightsFeed()
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .arming, sink: sink), .skipped("shadow watch is not clear"))
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: sink), .published)
        settle(&feed, sink: sink)
        XCTAssertEqual(feed.offer(left: weights(1.001), right: weights(1.001), guardState: .clear, sink: sink), .skipped("unchanged"))
        XCTAssertEqual(feed.offer(left: weights(1.05), right: weights(1), guardState: .clear, sink: sink), .published)
        XCTAssertEqual(sink.sets.count, 2)
    }

    func testRateLimitedToOneSetPerSecondOfPolls() {
        let sink = Sink()
        var feed = FeedForwardLiveWeightsFeed()
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: sink), .published)
        for i in 1..<FeedForwardLiveWeightsFeed.minimumPolls {
            XCTAssertEqual(
                feed.offer(left: weights(2), right: weights(2), guardState: .clear, sink: sink), .skipped("too soon"), "poll \(i)"
            )
        }
        XCTAssertEqual(feed.offer(left: weights(2), right: weights(2), guardState: .clear, sink: sink), .published)
    }

    func testTrippedOrBadWeightsAreNeverPublished() {
        let sink = Sink()
        var feed = FeedForwardLiveWeightsFeed()
        XCTAssertEqual(
            feed.offer(left: weights(1), right: weights(1), guardState: .wouldHaveTripped("growth"), sink: sink),
            .skipped("shadow watch is not clear")
        )
        var bad = weights(1)
        bad[7] = .nan
        XCTAssertEqual(feed.offer(left: bad, right: weights(1), guardState: .clear, sink: sink), .skipped("non-finite weights"))
        XCTAssertEqual(feed.offer(left: weights(1, count: 513), right: weights(1, count: 513), guardState: .clear, sink: sink), .skipped("weight count out of range"))
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1, count: 4), guardState: .clear, sink: sink), .skipped("weight count out of range"))
        XCTAssertEqual(feed.offer(left: [], right: [], guardState: .clear, sink: sink), .skipped("weight count out of range"))
        XCTAssertTrue(sink.sets.isEmpty)
    }

    func testARefusingSinkIsRetriedAndResetStartsOver() {
        let sink = Sink()
        sink.accepts = false
        var feed = FeedForwardLiveWeightsFeed()
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: sink), .skipped("no live filter attached"))
        sink.accepts = true
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: sink), .published)
        feed.reset()
        XCTAssertEqual(feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: sink), .published)
        XCTAssertEqual(sink.sets.count, 2)
    }

    func testEngineRefusesWeightsWhileTheFlagIsOffAndPublishingNeverArms() {
        let engine = AudioIOEngine()
        XCTAssertFalse(engine.speakerDriveFeatureEnabled)
        var feed = FeedForwardLiveWeightsFeed()
        XCTAssertEqual(
            feed.offer(left: weights(1), right: weights(1), guardState: .clear, sink: engine), .skipped("no live filter attached")
        )
        XCTAssertNil(engine.feedForwardLiveStatus())
    }
}

/// E4 S22b3: the policy that publishes the leakage model to the live echo stage.
@MainActor
final class FeedForwardLiveEchoFeedTests: XCTestCase {
    private final class Sink: FeedForwardLiveEchoSink {
        var rate: Double? = 48_000
        var accepts = true
        var sets: [FeedForwardLiveEchoPayload?] = []
        var liveEchoRate: Double? { rate }
        func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?) -> Bool {
            guard accepts else { return false }
            sets.append(payload)
            return true
        }
    }

    private func model(fd: Double = 4_000, repeats: Int = 3, taps: Int = 64, bulk: Int = 20) -> FeedForwardEchoModel {
        let path = FeedForwardEchoPath(
            bulkDelay: bulk, taps: (0..<taps).map { Float(0.5 * exp(-Double($0) / 12)) }, bound: [Float](repeating: 0, count: taps))
        return FeedForwardEchoModel(
            sampleRate: fd, nativeSampleRate: 48_000, repeats: repeats, left: path, right: path,
            coherence: 0.95, repeatDeviation: 0.05, capturedAt: Date(timeIntervalSince1970: 0))
    }

    func testPublishesOnceAndClearsWhenBlocked() {
        let sink = Sink()
        var feed = FeedForwardLiveEchoFeed()
        XCTAssertEqual(feed.offer(model: model(), blockedReason: nil, sink: sink), .published)
        XCTAssertEqual(feed.offer(model: model(), blockedReason: nil, sink: sink), .skipped("unchanged"))
        XCTAssertEqual(feed.offer(model: model(), blockedReason: "subwoofer", sink: sink), .cleared)
        XCTAssertEqual(sink.sets.count, 2)
        XCTAssertNil(sink.sets[1])
        XCTAssertEqual(feed.offer(model: model(), blockedReason: "subwoofer", sink: sink), .skipped("subwoofer"))
    }

    func testAV1ModelWithoutRepeatsNeverPublishes() {
        let sink = Sink()
        var feed = FeedForwardLiveEchoFeed()
        guard case .skipped = feed.offer(model: model(repeats: 1), blockedReason: nil, sink: sink) else {
            return XCTFail("a model without repeats must not publish")
        }
        XCTAssertTrue(sink.sets.isEmpty)
    }

    func testNoRateOrARefusingSinkIsRetried() {
        let sink = Sink()
        var feed = FeedForwardLiveEchoFeed()
        sink.rate = nil
        guard case .skipped = feed.offer(model: model(), blockedReason: nil, sink: sink) else { return XCTFail() }
        sink.rate = 48_000
        sink.accepts = false
        XCTAssertEqual(feed.offer(model: model(), blockedReason: nil, sink: sink), .skipped("echo stage not ready"))
        sink.accepts = true
        XCTAssertEqual(feed.offer(model: model(), blockedReason: nil, sink: sink), .published)
        feed.reset()
        XCTAssertEqual(feed.offer(model: model(), blockedReason: nil, sink: sink), .published)
    }

    func testEqualFdCopiesAndOtherRatesKeepTimeAndGain() throws {
        // 48 kHz: D = 12, fd = 4000, so a 4 kHz model is copied unchanged.
        let same = try XCTUnwrap(FeedForwardLiveEchoFeed.payload(model: model(), liveRate: 48_000))
        XCTAssertEqual(same.left, model().left.taps)
        XCTAssertEqual(same.bulk, [20, 20])
        // 44.1 kHz: D = 11, fd = 4009.09. The bulk delay keeps its time and the DC gain is kept.
        let other = try XCTUnwrap(FeedForwardLiveEchoFeed.payload(model: model(), liveRate: 44_100))
        let fdLive = 44_100.0 / 11
        XCTAssertEqual(Double(other.bulk[0]), 20 * fdLive / 4_000, accuracy: 1)
        let gainIn = model().left.taps.reduce(0, +)
        let gainOut = other.left.reduce(0, +)
        XCTAssertEqual(Double(gainOut), Double(gainIn), accuracy: 0.05 * Double(gainIn))
        for rate in [88_200.0, 96_000, 176_400, 192_000, 352_800, 384_000] {
            XCTAssertNotNil(FeedForwardLiveEchoFeed.payload(model: model(), liveRate: rate), "\(rate)")
        }
    }

    func testEngineRefusesWhileTheFlagIsOff() {
        let engine = AudioIOEngine()
        var feed = FeedForwardLiveEchoFeed()
        XCTAssertEqual(
            feed.offer(model: model(), blockedReason: nil, sink: engine), .skipped("no live filter attached"))
        XCTAssertFalse(engine.setFeedForwardLiveEcho(FeedForwardLiveEchoPayload(bulk: [0, 0], left: [1], right: [1])))
    }
}
