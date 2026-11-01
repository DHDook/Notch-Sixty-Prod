import Foundation

/// E4 S25c: places the reference microphone onto the output clock for the live feed-forward ring.
/// 4-point Lagrange interpolation at a fractional position of the reference's own frame counter. When
/// the reference runs faster than the output it first averages `averaging` neighbouring reference
/// samples (a boxcar centred on the position, no added delay), so content above the few hundred Hz
/// the filter uses cannot fold down. Pure arithmetic, control plane only.
enum FeedForwardReferenceResampler {
    /// Number of reference samples averaged for one output sample.
    static func averaging(referenceRate: Double, outputRate: Double) -> Int {
        guard referenceRate.isFinite, outputRate.isFinite, referenceRate > 0, outputRate > 0 else { return 1 }
        return min(max(Int((referenceRate / outputRate).rounded(.up)), 1), 16)
    }

    /// Whole samples needed on each side of a position (Lagrange reach plus half the average).
    static func halfWidth(averaging k: Int) -> Int64 {
        Int64(((k - 1) + 1) / 2) + 2
    }

    /// The value at `position` (absolute reference index), or nil when `x` (first absolute index `base`)
    /// does not cover the whole neighbourhood.
    static func value(_ x: [Float], base: Int64, position: Double, averaging k: Int) -> Float? {
        guard position.isFinite else { return nil }
        let half = halfWidth(averaging: k)
        let centre = Int64(position.rounded(.down))
        guard centre - half >= base, centre + half <= base + Int64(x.count) - 1 else { return nil }
        if k <= 1 {
            return CrossDevicePairCapture.lagrange(x, base: base, j: centre, mu: Float(position - Double(centre)))
        }
        var sum: Float = 0
        let offset = Double(k - 1) / 2
        for m in 0..<k {
            let p = position + Double(m) - offset
            let j = Int64(p.rounded(.down))
            sum += CrossDevicePairCapture.lagrange(x, base: base, j: j, mu: Float(p - Double(j)))
        }
        return sum / Float(k)
    }
}

/// Where the pump writes: the live feed-forward ring behind the render bridge.
@MainActor
protocol FeedForwardLiveReferenceSink: AnyObject {
    /// The output index the render thread has reached, nil when the live filter is not attached.
    func liveReferenceOutputIndex() -> UInt64?
    func pushLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64?
    func markLiveReferenceLost()
}

@MainActor
extension AudioIOEngine: FeedForwardLiveReferenceSink {
    func liveReferenceOutputIndex() -> UInt64? {
        guard let status = feedForwardLiveStatus(), status.attached else { return nil }
        return status.outputIndex
    }

    func pushLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        pushFeedForwardLiveReference(startIndex: startIndex, samples: samples)
    }

    func markLiveReferenceLost() { markFeedForwardLiveReferenceLost() }
}

/// E4 S25c: the reference pump. Reads the one-channel reference capture (its own device and clock),
/// fits host time against the reference frame counter and against the output index (from the render
/// callbacks' anchors), resamples the reference onto the output clock and writes it into the kernel's
/// reference ring ahead of the render thread.
///
/// Timing. Output frame `i` plays at host time `outFit(i)`. Ring frame `i` holds the reference as it was
/// `delaySeconds` earlier, corrected for the capture device's reported input latency:
/// `refFit.index(at: outFit(i) - delaySeconds + referenceLatencySeconds)`. The delay must exceed the
/// output latency plus the capture's buffering, or the sample has not been captured when the render
/// thread needs it (the kernel counts that as an underrun); it is spent from the S24 lead budget, so the
/// arm gate must be given `lead - delaySeconds`.
///
/// Safety. The pump refuses to run (stops and marks the reference lost, which fades the filter out) when
/// the relative drift exceeds 100 ppm, either fit's residual exceeds 0.5 ms, the reference loses
/// samples, the output index goes backwards, or the capture throws. A restart is the owner's decision.
/// It never arms anything and does nothing while the live filter is detached.
///
/// Threads. Main actor, driven by the caller every few milliseconds with the anchors it has read (the
/// drive ring has one consumer, so the caller forwards them). Realtime impact: none, nothing here runs
/// in an audio callback; the ring write is the S25b single-producer push. Latency: `delaySeconds`.
/// Sample rates: any reference and output rate up to 384 kHz.
@MainActor
final class FeedForwardLiveReferencePump {
    static let maximumDriftPPM = FeedForwardDriveAligner.maximumDriftPPM
    static let maximumResidualSeconds = FeedForwardDriveAligner.maximumResidualSeconds
    /// How far ahead of the render thread the pump keeps the ring filled.
    static let writeAheadSeconds = 0.04
    /// Where the first write lands beyond the render thread, so it is not already late.
    static let startMarginSeconds = 0.005
    static let maximumReadFrames = 16_384

    enum State: Equatable {
        case aligning
        case running
        case stopped(String)
    }

    struct Report: Equatable {
        var state: State
        var framesWritten: Int
        var driftPPM: Double?
        var residualSeconds: Double?
    }

    let referenceRate: Double
    let outputRate: Double
    let delaySeconds: Double
    private let reference: QuietZoneFeedForwardSingleCapturing
    private let sink: FeedForwardLiveReferenceSink
    private let referenceLatencySeconds: Double
    private let hostSeconds: (UInt64) -> Double
    private let averaging: Int
    private var referenceFit = FeedForwardClockFit()
    private var outputFit = FeedForwardClockFit()
    private var samples: [Float] = []
    private var baseIndex: Int64 = 0
    private var lastAnchorIndex: UInt64?
    private var nextIndex: UInt64?
    private var started = false
    private(set) var state: State = .aligning
    /// Times the pump found itself behind the render thread and skipped ahead.
    private(set) var lateJumps = 0
    private(set) var totalFramesWritten: UInt64 = 0

    init(
        reference: QuietZoneFeedForwardSingleCapturing, sink: FeedForwardLiveReferenceSink,
        outputRate: Double, delaySeconds: Double, referenceLatencySeconds: Double = 0,
        hostSeconds: @escaping (UInt64) -> Double = CrossDevicePairCapture.machSeconds
    ) {
        self.reference = reference
        self.sink = sink
        self.referenceRate = reference.sampleRate
        self.outputRate = outputRate
        self.delaySeconds = delaySeconds
        self.referenceLatencySeconds = referenceLatencySeconds
        self.hostSeconds = hostSeconds
        averaging = FeedForwardReferenceResampler.averaging(referenceRate: reference.sampleRate, outputRate: outputRate)
    }

    func start() throws {
        guard !started else { return }
        guard referenceRate > 0, outputRate > 0, delaySeconds.isFinite, delaySeconds >= 0 else {
            throw CrossDeviceCaptureError.clockRefused("invalid rate or delay")
        }
        try reference.start()
        started = true
    }

    /// Closes the capture and silences the filter (it fades out and trips on the missing reference).
    func stop(_ reason: String = "stopped") {
        if case .stopped = state { return }
        state = .stopped(reason)
        reference.close()
        sink.markLiveReferenceLost()
    }

    /// One pump cycle. `anchors` are the render callbacks read since the last cycle, oldest first.
    @discardableResult
    func step(anchors: [N60SpeakerDriveAnchor]) -> Report {
        if case .stopped = state { return report(0, nil, nil) }
        do {
            let frames = try reference.readFrames(maximumFrames: Self.maximumReadFrames)
            try ingestReference(frames)
        } catch {
            stop("reference capture failed: \(error.localizedDescription)")
            return report(0, nil, nil)
        }
        for anchor in anchors { if !ingest(anchor: anchor) { break } }
        if case .stopped = state { return report(0, nil, nil) }

        guard let refLine = referenceFit.line(), let outLine = outputFit.line(),
              let outputIndex = sink.liveReferenceOutputIndex()
        else {
            state = .aligning
            // Keep at most 3 s of reference while the clock lines form.
            let excess = samples.count - Int(3 * referenceRate)
            if excess > 0 {
                samples.removeFirst(excess)
                baseIndex += Int64(excess)
            }
            return report(0, nil, nil)
        }
        let residual = max(refLine.maximumResidualSeconds, outLine.maximumResidualSeconds)
        let measuredRatio = (1 / outLine.slope) / (1 / refLine.slope)
        let drift = (measuredRatio / (outputRate / referenceRate) - 1) * 1.0e6
        guard residual <= Self.maximumResidualSeconds else {
            stop(String(format: "clock fit residual %.2f ms over 0.5 ms", residual * 1000))
            return report(0, drift, residual)
        }
        guard abs(drift) <= Self.maximumDriftPPM else {
            stop(String(format: "clock drift %.0f ppm over %.0f ppm", drift, Self.maximumDriftPPM))
            return report(0, drift, residual)
        }

        let margin = UInt64(Self.startMarginSeconds * outputRate)
        var next = nextIndex ?? outputIndex + margin
        if next < outputIndex {
            lateJumps += 1
            next = outputIndex + margin
        }
        let limit = outputIndex + UInt64(Self.writeAheadSeconds * outputRate)
        var block: [Float] = []
        if next < limit { block.reserveCapacity(Int(limit - next)) }
        var i = next
        while i < limit {
            let stamp = outLine.seconds(at: Double(i)) - delaySeconds + referenceLatencySeconds
            let position = refLine.index(at: stamp)
            if samples.isEmpty { break }
            if let value = FeedForwardReferenceResampler.value(samples, base: baseIndex, position: position, averaging: averaging) {
                block.append(value)
            } else if Int64(position.rounded(.down)) + FeedForwardReferenceResampler.halfWidth(averaging: averaging)
                        > baseIndex + Int64(samples.count) - 1 {
                break  // the reference has not reached this sound yet
            } else {
                block.append(0)  // before the capture began, or already trimmed: silence
            }
            i += 1
        }
        var written = 0
        if !block.isEmpty {
            if let returned = sink.pushLiveReference(startIndex: next, samples: block) {
                nextIndex = returned
                written = block.count
                totalFramesWritten += UInt64(written)
            } else {
                nextIndex = next
            }
        } else {
            nextIndex = next
        }
        trim(before: outLine, refLine: refLine, from: nextIndex ?? next)
        state = .running
        return report(written, drift, residual)
    }

    private func report(_ written: Int, _ drift: Double?, _ residual: Double?) -> Report {
        Report(state: state, framesWritten: written, driftPPM: drift, residualSeconds: residual)
    }

    private func ingestReference(_ frames: [N60FeedForwardReferenceFrame]) throws {
        for frame in frames {
            let index = Int64((frame.firstFrameSampleTime + Double(frame.frameOffset)).rounded())
            if samples.isEmpty {
                baseIndex = index
            } else if index != baseIndex + Int64(samples.count) {
                throw CrossDeviceCaptureError.monitorGap
            }
            if frame.frameOffset == 0 {
                referenceFit.add(index: Double(index), seconds: hostSeconds(frame.firstFrameHostTime))
            }
            samples.append(frame.sample)
        }
    }

    /// Returns false when the anchor stream broke and the pump stopped.
    private func ingest(anchor: N60SpeakerDriveAnchor) -> Bool {
        guard anchor.outputHostTime != 0, anchor.frames > 0 else { return true }
        let near = lastAnchorIndex ?? sink.liveReferenceOutputIndex() ?? UInt64(anchor.reserved)
        let index = Self.unwrap(low: anchor.reserved, near: near)
        if let last = lastAnchorIndex, index < last {
            stop("output index went backwards")
            return false
        }
        lastAnchorIndex = index
        outputFit.add(index: Double(index), seconds: hostSeconds(anchor.outputHostTime))
        return true
    }

    /// The 64-bit index nearest `near` whose low 32 bits are `low`.
    static func unwrap(low: UInt32, near: UInt64) -> UInt64 {
        let span: UInt64 = 1 << 32
        let candidate = (near & ~(span - 1)) | UInt64(low)
        if candidate > near, candidate - near > span / 2, candidate >= span { return candidate - span }
        if candidate < near, near - candidate > span / 2 { return candidate + span }
        return candidate
    }

    /// Drops reference samples the next write can no longer reach.
    private func trim(before outLine: FeedForwardClockFit.Line, refLine: FeedForwardClockFit.Line, from next: UInt64) {
        let stamp = outLine.seconds(at: Double(next)) - delaySeconds + referenceLatencySeconds
        let keepFrom = Int64(refLine.index(at: stamp).rounded(.down)) - FeedForwardReferenceResampler.halfWidth(averaging: averaging) - 16
        let drop = Int(min(max(keepFrom - baseIndex, 0), Int64(samples.count)))
        if drop > 0 {
            samples.removeFirst(drop)
            baseIndex += Int64(drop)
        }
    }
}
