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
