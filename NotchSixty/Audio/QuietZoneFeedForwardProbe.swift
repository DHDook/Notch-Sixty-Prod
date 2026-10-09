import Foundation

/// A matched-filter front end for controlled external-source calibration.
/// It does NOT establish a shared clock: upstream callers must supply actual
/// input-sample/launch timing from synchronized or cross-calibrated hardware.
struct QuietZoneFeedForwardProbeCapture: Sendable {
    var position: QuietZoneFeedForwardPosition
    var emittedProbe: [Float]
    var recordedSamples: [Float]
    var sampleRate: Double
    var firstInputFrameAfterTriggerSeconds: Double
    var triggerClockUncertaintySeconds: Double
    var sourceTriggerID: String
    var synchronizedClockID: String
    var microphoneDeviceID: String
    var microphoneChannel: Int
    var routeFingerprint: String
}

struct QuietZoneFeedForwardProbeDetector: Sendable {
    static let maximumFrames = 65_536
    static let minimumCorrelation = 0.80
    static let minimumRecoveredSNRDB = 24.0

    func detect(
        _ capture: QuietZoneFeedForwardProbeCapture
    ) throws -> QuietZoneFeedForwardArrival {
        let probe = capture.emittedProbe
        let recorded = capture.recordedSamples
        guard probe.count >= 64, probe.count <= 2_048,
              recorded.count >= probe.count + 64,
              recorded.count <= Self.maximumFrames,
              capture.sampleRate.isFinite, capture.sampleRate >= 8_000,
              capture.firstInputFrameAfterTriggerSeconds.isFinite,
              abs(capture.firstInputFrameAfterTriggerSeconds) < 1,
              capture.triggerClockUncertaintySeconds.isFinite,
              capture.triggerClockUncertaintySeconds >= 0,
              capture.triggerClockUncertaintySeconds < 0.00075,
              !capture.sourceTriggerID.isEmpty,
              !capture.synchronizedClockID.isEmpty,
              !capture.microphoneDeviceID.isEmpty,
              !capture.routeFingerprint.isEmpty,
              capture.microphoneChannel >= 0,
              probe.allSatisfy({ $0.isFinite }),
              recorded.allSatisfy({ $0.isFinite && abs($0) < 0.99 })
        else { throw QuietZoneFeedForwardError.poorQuality }

        let probeMean = probe.reduce(0.0) { $0 + Double($1) }
            / Double(probe.count)
        let reference = probe.map { Double($0) - probeMean }
        let referencePower = reference.reduce(0.0) { $0 + $1 * $1 }
        guard referencePower > 1.0e-7
        else { throw QuietZoneFeedForwardError.poorQuality }

        var scores: [Double] = []
        scores.reserveCapacity(recorded.count - probe.count + 1)
        var bestScore = 0.0
        for offset in 0...(recorded.count - probe.count) {
            var dot = 0.0
            var samplePower = 0.0
            var sampleMean = 0.0
            for i in reference.indices {
                sampleMean += Double(recorded[offset + i])
            }
            sampleMean /= Double(reference.count)
            for i in reference.indices {
                let y = Double(recorded[offset + i]) - sampleMean
                dot += reference[i] * y
                samplePower += y * y
            }
            let score = abs(dot)
                / sqrt(max(referencePower * samplePower, 1.0e-20))
            scores.append(score)
            bestScore = max(bestScore, score)
        }
        guard bestScore >= Self.minimumCorrelation
        else { throw QuietZoneFeedForwardError.poorQuality }

        // Choose the first strong correlated onset instead of assuming the
        // largest late reflected peak is the first sound arrival.
        let threshold = max(Self.minimumCorrelation, bestScore * 0.90)
        guard let onset = scores.firstIndex(where: { $0 >= threshold })
        else { throw QuietZoneFeedForwardError.poorQuality }

        let eventRMS = sqrt(
            recorded[onset..<(onset + probe.count)]
                .reduce(0.0) { $0 + Double($1) * Double($1) }
                / Double(probe.count)
        )
        let preNoise: Double
        if onset >= 64 {
            let before = recorded[0..<onset]
            preNoise = sqrt(
                before.reduce(0.0) {
                    $0 + Double($1) * Double($1)
                } / Double(before.count)
            )
        } else {
            // The capture did not include a trustworthy pre-event noise floor.
            throw QuietZoneFeedForwardError.poorQuality
        }
        let snr = 20 * log10(eventRMS / max(preNoise, 1.0e-8))
        guard snr.isFinite, snr >= Self.minimumRecoveredSNRDB
        else { throw QuietZoneFeedForwardError.poorQuality }

        let relativeArrival = capture.firstInputFrameAfterTriggerSeconds
            + Double(onset) / capture.sampleRate
        guard relativeArrival >= 0, relativeArrival <= 2
        else { throw QuietZoneFeedForwardError.incompatibleClock }

        return QuietZoneFeedForwardArrival(
            position: capture.position,
            sourceTriggerID: capture.sourceTriggerID,
            synchronizedClockID: capture.synchronizedClockID,
            microphoneDeviceID: capture.microphoneDeviceID,
            microphoneChannel: capture.microphoneChannel,
            routeFingerprint: capture.routeFingerprint,
            sampleRate: capture.sampleRate,
            arrivalAfterTriggerSeconds: relativeArrival,
            oneSigmaTimingUncertaintySeconds:
                capture.triggerClockUncertaintySeconds
                + 0.5 / capture.sampleRate,
            snrDB: snr
        )
    }
}
