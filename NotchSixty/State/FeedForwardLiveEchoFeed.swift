import Foundation

/// E4 S22b3: the leakage model as the live echo stage takes it: per speaker a bulk delay and up to 512
/// taps, all at the live filter's fd (`liveRate / floor(liveRate / 4000)`).
struct FeedForwardLiveEchoPayload: Equatable, Sendable {
    var bulk: [UInt32]
    var left: [Float]
    var right: [Float]

    var isValid: Bool {
        bulk.count == 2 && bulk.allSatisfy { $0 <= UInt32(FeedForwardEchoModel.maximumBulkDelay) }
            && (1...FeedForwardEchoModel.maximumTaps).contains(left.count)
            && (1...FeedForwardEchoModel.maximumTaps).contains(right.count)
            && left.allSatisfy(\.isFinite) && right.allSatisfy(\.isFinite)
    }
}

/// Where the model goes: the live feed-forward echo stage in the render kernel (`AudioIOEngine`
/// conforms). Control plane only; the kernel applies a model while the filter is idle.
@MainActor
protocol FeedForwardLiveEchoSink: AnyObject {
    /// The output rate the live filter runs at; nil when the transport has none.
    var liveEchoRate: Double? { get }
    /// Nil clears the stage. False when the transport refused (no filter, subwoofer, no pump delay yet).
    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?) -> Bool
}

extension AudioIOEngine: FeedForwardLiveEchoSink {
    var liveEchoRate: Double? { ambientPlaybackReferenceSampleRate }
}

/// Decides what the live echo stage is told about the leakage model. Publishing never arms anything.
///
/// The model is published once per (model, rate) when all hold: the model has repeats from at least
/// three sweeps (a v1 store has none, so the stage stays off), nothing blocks it (flag, subwoofer or bass
/// management: question 18), and the live rate is known. Anything else clears a model that was
/// published. A sink that refuses is retried on the next poll.
/// Realtime: none of this runs on the audio thread. Allocation: one resampled copy per publish.
struct FeedForwardLiveEchoFeed: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case published
        case cleared
        case skipped(String)
    }

    private struct Key: Equatable, Sendable {
        var model: FeedForwardEchoModel
        var rate: Double
    }

    private var published: Key?
    private(set) var publishedCount = 0

    var isPublished: Bool { published != nil }

    /// A new shadow starts from nothing; the next offer publishes again.
    mutating func reset() { published = nil }

    @MainActor
    mutating func offer(
        model: FeedForwardEchoModel?, blockedReason: String?, sink: any FeedForwardLiveEchoSink
    ) -> Outcome {
        guard let model, blockedReason == nil, model.repeats >= FeedForwardEchoModel.minimumRepeats else {
            return clear(
                sink: sink,
                why: blockedReason
                    ?? (model == nil ? "no leakage model" : "the leakage model needs measuring again"))
        }
        guard let rate = sink.liveEchoRate, let payload = Self.payload(model: model, liveRate: rate) else {
            return clear(sink: sink, why: "no live filter attached")
        }
        let key = Key(model: model, rate: rate)
        if published == key { return .skipped("unchanged") }
        guard sink.setFeedForwardLiveEcho(payload) else { return .skipped("echo stage not ready") }
        published = key
        publishedCount += 1
        return .published
    }

    @MainActor
    private mutating func clear(sink: any FeedForwardLiveEchoSink, why: String) -> Outcome {
        guard published != nil else { return .skipped(why) }
        // A refusing sink keeps the old model; the next poll tries again.
        guard sink.setFeedForwardLiveEcho(nil) else { return .skipped(why) }
        published = nil
        return .cleared
    }

    // MARK: - Resampling

    /// fd of a live filter at `rate`: the C core's decimation factor, `floor(rate / 4000)`.
    static func liveFd(rate: Double) -> Double? {
        let factor = (rate / 4000).rounded(.down)
        return factor >= 1 ? rate / factor : nil
    }

    /// The model at the live filter's fd. Equal fds copy; otherwise taps are interpolated with a
    /// Hann-windowed sinc (half width 8) and scaled by the fd ratio, so a tap stays "impulse response
    /// per fd sample". The bulk delay keeps its time.
    static func payload(model: FeedForwardEchoModel, liveRate: Double) -> FeedForwardLiveEchoPayload? {
        guard let fdLive = liveFd(rate: liveRate), model.sampleRate > 0, model.sampleRate.isFinite else { return nil }
        let left = resample(model.left, from: model.sampleRate, to: fdLive)
        let right = resample(model.right, from: model.sampleRate, to: fdLive)
        guard let left, let right else { return nil }
        let payload = FeedForwardLiveEchoPayload(bulk: [left.bulk, right.bulk], left: left.taps, right: right.taps)
        return payload.isValid ? payload : nil
    }

    private static func resample(
        _ path: FeedForwardEchoPath, from fdModel: Double, to fdLive: Double
    ) -> (bulk: UInt32, taps: [Float])? {
        let ratio = fdModel / fdLive  // source samples per output sample
        let bulk = (Double(path.bulkDelay) / ratio).rounded()
        guard bulk >= 0, bulk <= Double(FeedForwardEchoModel.maximumBulkDelay), !path.taps.isEmpty else { return nil }
        if abs(ratio - 1) < 1e-9 { return (UInt32(bulk), path.taps) }
        let count = min(FeedForwardEchoModel.maximumTaps, max(1, Int((Double(path.taps.count) / ratio).rounded())))
        let half = 8.0
        var out = [Float](repeating: 0, count: count)
        for j in 0..<count {
            let position = Double(j) * ratio
            let lo = max(0, Int((position - half).rounded(.up)))
            let hi = min(path.taps.count - 1, Int((position + half).rounded(.down)))
            guard lo <= hi else { continue }
            var sum = 0.0
            for k in lo...hi {
                let x = position - Double(k)
                let sinc = x == 0 ? 1.0 : sin(Double.pi * x) / (Double.pi * x)
                let window = 0.5 * (1 + cos(Double.pi * x / half))
                sum += Double(path.taps[k]) * sinc * window
            }
            out[j] = Float(sum * ratio)
        }
        return (UInt32(bulk), out)
    }
}
