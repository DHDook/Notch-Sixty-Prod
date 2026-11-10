import Foundation

// E13 S7 (G1): the per-pass signal-to-noise and clipping check for BRIR capture.
//
// Control plane only (runs on a task after a pass finishes). A pass that clips an ear microphone or
// whose impulse response barely rises above the noise floor is rejected so the user can retry it;
// nothing from a rejected pass is kept.

struct BRIRPassQuality: Equatable, Sendable {
    /// Peak of the deconvolved response over the RMS of its late, noise-only tail, per ear, in dB.
    static let minimumSNRDB = 30.0
    /// A sample at or above this magnitude counts as clipped.
    static let clipThreshold: Float = 0.98
    /// A stray full-scale sample is tolerated; a run of them is clipping.
    static let allowedClippedSamples = 2

    /// The worse ear.
    var snrDB: Double
    var clippedSamples: Int

    var isClipped: Bool { clippedSamples > Self.allowedClippedSamples }
    var isTooNoisy: Bool { snrDB < Self.minimumSNRDB }
    var isAcceptable: Bool { !isClipped && !isTooNoisy }

    /// What to tell the user, or nil when the pass is fine.
    var problem: String? {
        if isClipped { return "A microphone clipped. Lower the microphone gain or the playback level and capture again." }
        if isTooNoisy {
            return "The room was too noisy for a clean response (\(Int(snrDB.rounded())) dB, need \(Int(Self.minimumSNRDB)) dB). Wait for quiet and capture again."
        }
        return nil
    }
}

enum BRIRPassQualityAssessor {
    /// `captures` are the raw ear recordings, `records` the matching deconvolved ear records.
    static func assess(captures: [[Float]], records: [MultiMicSeatRecord]) -> BRIRPassQuality {
        var clipped = 0
        for capture in captures {
            for sample in capture where abs(sample) >= BRIRPassQuality.clipThreshold { clipped += 1 }
        }
        let snr = records.map { snrDB(of: $0.impulseResponse) }.min() ?? 0
        return BRIRPassQuality(snrDB: snr, clippedSamples: clipped)
    }

    /// The circular result holds positive time in its first half. Its last quarter, long after any
    /// room decay worth keeping, is taken as the noise floor.
    static func snrDB(of response: [Float]) -> Double {
        let half = response.count / 2
        guard half >= 64 else { return 0 }
        let tail = response[(half - half / 4)..<half]
        let noise = sqrt(tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count))
        let peak = response[0..<half].reduce(0.0) { max($0, Double(abs($1))) }
        guard peak > 0, peak.isFinite else { return 0 }
        guard noise > 0 else { return .infinity }
        return 20 * log10(peak / noise)
    }
}

extension BRIRCaptureProcessor {
    /// One pass with its quality verdict. A pass that fails the verdict still returns its responses
    /// so the caller can show the problem; the caller decides whether to keep it.
    static func captureChecked(
        plan: BRIRCapturePlan,
        pass: MultiMicPass,
        tapCount: Int? = nil,
        timeoutSeconds: Double,
        makeTransport: MultiMicTransportFactory
    ) async throws -> (left: [Float], right: [Float], quality: BRIRPassQuality) {
        let seats = try plan.earPlan()
        let captures = try await MultiMicMeasurementRunner.capture(
            plan: seats, timeoutSeconds: timeoutSeconds, makeTransport: makeTransport)
        let records = try MeasurementCore.processMultiMic(
            captures: captures.map { Optional($0) }, seats: seats.multiMicSeats, mode: seats.mode,
            pass: pass, sampleRate: plan.sampleRate)
        let quality = BRIRPassQualityAssessor.assess(captures: captures, records: records)
        let responses = try process(records: records, tapCount: tapCount ?? plan.tapCount, sampleRate: plan.sampleRate)
        return (responses.left, responses.right, quality)
    }
}
