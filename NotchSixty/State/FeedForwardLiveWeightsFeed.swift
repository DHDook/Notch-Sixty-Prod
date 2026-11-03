import Foundation

/// Where the shadow's weights go: the live feed-forward mailbox in the render kernel
/// (`AudioIOEngine` conforms). Control plane only; the kernel crossfades to a new set.
protocol FeedForwardLiveWeightsSink: AnyObject {
    /// False when the transport has no live filter attached (nothing is stored).
    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool
}

extension AudioIOEngine: FeedForwardLiveWeightsSink {}

/// E4 S25 follow-up: decides when the feed-forward shadow's weights are published to the live
/// mailbox. Publishing never arms anything: with no arm the kernel stays silent, and arming goes
/// only through `FeedForwardLiveArmGate`. Pure policy, driven once per shadow poll.
///
/// A set is published when all hold:
/// - the shadow watch is clear (adapted at least 3 s, not tripped, no gap since);
/// - the weights are finite and 1 to 512 taps per speaker;
/// - at least `minimumPolls` polls (1 s) passed since the last publish;
/// - the set differs from the last published one by at least `changeFraction` (2 %) of its norm
///   (the first set after a shadow is created is published as soon as the watch is clear).
/// A sink that refuses (no filter attached) is retried on the next poll.
/// Realtime: none of this runs on the audio thread. Allocation: copies the two weight arrays
/// on publish. Sample rate: weights are at fd; the kernel owns the native-rate conversion.
struct FeedForwardLiveWeightsFeed: Equatable, Sendable {
    static let minimumPolls = 10
    static let changeFraction: Float = 0.02
    static let maximumTaps = 512

    enum Outcome: Equatable, Sendable {
        case published
        case skipped(String)
    }

    private var lastLeft: [Float] = []
    private var lastRight: [Float] = []
    private var pollsSincePublish = Int.max / 2
    private(set) var publishedCount = 0

    /// A new shadow (device, rate, channel or survey change) starts from nothing.
    mutating func reset() {
        lastLeft = []
        lastRight = []
        pollsSincePublish = Int.max / 2
    }

    mutating func offer(
        left: [Float], right: [Float], guardState: AdaptiveQuietZoneShadowStatus.Guard,
        sink: any FeedForwardLiveWeightsSink
    ) -> Outcome {
        pollsSincePublish = pollsSincePublish >= Int.max / 2 ? pollsSincePublish : pollsSincePublish + 1
        guard guardState == .clear else { return .skipped("shadow watch is not clear") }
        guard left.count == right.count, (1...Self.maximumTaps).contains(left.count) else {
            return .skipped("weight count out of range")
        }
        guard left.allSatisfy(\.isFinite), right.allSatisfy(\.isFinite) else {
            return .skipped("non-finite weights")
        }
        guard pollsSincePublish >= Self.minimumPolls else { return .skipped("too soon") }
        if !lastLeft.isEmpty, lastLeft.count == left.count {
            let delta = Self.energy(left, minus: lastLeft) + Self.energy(right, minus: lastRight)
            let base = Self.energy(lastLeft, minus: nil) + Self.energy(lastRight, minus: nil)
            let limit = Self.changeFraction * Self.changeFraction * base
            guard delta > limit || (base == 0 && delta > 0) else { return .skipped("unchanged") }
        }
        guard sink.setFeedForwardLiveWeights(left: left, right: right) else {
            return .skipped("no live filter attached")
        }
        lastLeft = left
        lastRight = right
        pollsSincePublish = 0
        publishedCount += 1
        return .published
    }

    private static func energy(_ a: [Float], minus b: [Float]?) -> Float {
        var sum: Float = 0
        for i in a.indices {
            let d = a[i] - (b?[i] ?? 0)
            sum += d * d
        }
        return sum
    }
}
