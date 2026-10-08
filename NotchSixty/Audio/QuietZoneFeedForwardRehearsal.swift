import Foundation

struct QuietZoneFeedForwardRehearsalSnapshot: Equatable {
    var processedReferenceFrames: Int
    var lastInputSampleTime: Double?
    var maximumProcessingBatchNanoseconds: UInt64
    var saturatedSamples: UInt64
    var sanitizedSamples: UInt64
    var timingFaults: Int
    var outputConnected: Bool = false
}

/// Consumes actual Core Audio callback samples but only runs the two-speaker
/// FIR into discarded scratch values. Never alters the audio render graph.
/// This does not measure ADC→DAC delay, hardware drift, or speaker-to-seat
/// propagation. Those require an instrumented output and physical microphone.
final class QuietZoneFeedForwardRehearsal {
    private var processor: OpaquePointer?
    private var sampleRate: Double
    private var lastSampleTime: Double?
    private var lastHostTime: UInt64?
    private var framesProcessed = 0
    private var maximumBatchNanoseconds: UInt64 = 0
    private var timingFaults = 0
    private var stopped = false

    init(candidate: QuietZoneCausalFIRCandidate) throws {
        guard !candidate.leftTaps.isEmpty,
              candidate.leftTaps.count == candidate.rightTaps.count,
              candidate.leftTaps.count <= 64,
              candidate.sampleRate.isFinite,
              candidate.sampleRate >= 8_000 else {
            throw QuietZoneCausalFIRError.invalidModel
        }
        sampleRate = candidate.sampleRate
        guard let processor = N60FeedForwardPreviewFIRCreate() else {
            throw QuietZoneCausalFIRError.invalidModel
        }
        self.processor = processor
        let configured = candidate.leftTaps.withUnsafeBufferPointer { left in
            candidate.rightTaps.withUnsafeBufferPointer { right in
                N60FeedForwardPreviewFIRConfigure(
                    processor,
                    left.baseAddress!,
                    right.baseAddress!,
                    UInt32(left.count)
                )
            }
        }
        if !configured {
            N60FeedForwardPreviewFIRDestroy(processor)
            self.processor = nil
            throw QuietZoneCausalFIRError.excessiveGain
        }
    }

    deinit { stop() }

    func stop() {
        guard !stopped else { return }
        stopped = true
        if let processor {
            N60FeedForwardPreviewFIRReset(processor)
            N60FeedForwardPreviewFIRDestroy(processor)
            self.processor = nil
        }
    }

    /// Off the hardware callback. Throws and stops on a missed frame, clock
    /// rewind or invalid timestamp; never masks discontinuities with extrapolated
    /// input. No rendering/output action is available on this type.
    func rehearse(
        _ frames: [N60FeedForwardReferenceFrame]
    ) throws -> QuietZoneFeedForwardRehearsalSnapshot {
        guard !stopped, let processor else {
            throw QuietZoneFeedForwardError.noLiveTransport
        }
        let start = DispatchTime.now().uptimeNanoseconds
        for frame in frames {
            let sampleTime = frame.firstFrameSampleTime
                + Double(frame.frameOffset)
            let hostTime = frame.firstFrameHostTime
            guard sampleTime.isFinite, sampleTime >= 0,
                  hostTime > 0,
                  lastSampleTime.map({ abs(sampleTime - $0 - 1.0) < 0.01 }) ?? true,
                  lastHostTime.map({ hostTime >= $0 }) ?? true else {
                timingFaults += 1
                stop()
                throw QuietZoneFeedForwardError.incompatibleClock
            }
            var left: Float = 0
            var right: Float = 0
            N60FeedForwardPreviewFIRProcessFrame(
                processor, frame.sample, &left, &right
            )
            guard left.isFinite, right.isFinite else {
                timingFaults += 1
                stop()
                throw QuietZoneFeedForwardError.invalidPath
            }
            // Deliberately DISCARD computed anti-noise samples.
            lastSampleTime = sampleTime
            lastHostTime = hostTime
            framesProcessed += 1
        }
        let elapsed = DispatchTime.now().uptimeNanoseconds - start
        maximumBatchNanoseconds = max(maximumBatchNanoseconds, elapsed)
        return snapshot()
    }

    func drain(
        referenceTransport: FeedForwardReferenceTransport,
        maximumFrames: Int = 256
    ) throws -> QuietZoneFeedForwardRehearsalSnapshot {
        guard abs(referenceTransport.sampleRate - sampleRate) < 0.5
        else { throw QuietZoneFeedForwardError.incompatibleClock }
        return try rehearse(referenceTransport.read(maximumFrames: maximumFrames))
    }

    func snapshot() -> QuietZoneFeedForwardRehearsalSnapshot {
        let s = processor.map(N60FeedForwardPreviewFIRGetSnapshot)
        return QuietZoneFeedForwardRehearsalSnapshot(
            processedReferenceFrames: framesProcessed,
            lastInputSampleTime: lastSampleTime,
            maximumProcessingBatchNanoseconds: maximumBatchNanoseconds,
            saturatedSamples: s?.limitedOutputFrames ?? 0,
            sanitizedSamples: s?.sanitizedInputs ?? 0,
            timingFaults: timingFaults
        )
    }
}
