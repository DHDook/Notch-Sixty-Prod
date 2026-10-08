import Foundation

/// A HAL sample-clock observation obtained *while a device is running*.
/// Host timestamps must be converted to a shared monotonic seconds timebase
/// using the platform's host-clock conversion before building this record.
/// This is a diagnostic for clock drift and discontinuity, not an ADC/DAC
/// or room acoustic latency measurement.
struct QuietZoneHALClockObservation: Codable, Equatable, Sendable {
    var hostTimeSeconds: Double
    var sampleFrame: Double
}

struct QuietZoneHALClockTrace: Codable, Equatable, Sendable {
    var inputDeviceID: String
    var outputDeviceID: String
    var nominalSampleRate: Double
    var inputObservations: [QuietZoneHALClockObservation]
    var outputObservations: [QuietZoneHALClockObservation]
}

struct QuietZoneHALClockHealth: Equatable, Sendable {
    var measuredInputRateHz: Double
    var measuredOutputRateHz: Double
    var relativeDriftPPM: Double
    var worstInputResidualSeconds: Double
    var worstOutputResidualSeconds: Double
    var observationDurationSeconds: Double
    var qualifiedForLoopbackBench: Bool

    /// This is *never* evidence that sound arrives before a disturbance.
    var physicalLatencyMeasured: Bool { false }
    var liveANCQualified: Bool { false }
}

enum QuietZoneHALClockError: Error, Equatable, LocalizedError {
    case insufficientObservation
    case invalidTimebase
    case clockDiscontinuity
    case excessiveDrift
    case excessiveJitter

    var errorDescription: String? {
        switch self {
        case .insufficientObservation:
            return "Capture at least eight callbacks per clock over a two-second interval."
        case .invalidTimebase:
            return "Input/output timestamps must share a monotonic host timebase with a matching nominal rate."
        case .clockDiscontinuity:
            return "The input or output HAL sample clock jumped, reversed or stalled."
        case .excessiveDrift:
            return "The input and output sample clocks drift too far apart for uncompensated feed-forward timing."
        case .excessiveJitter:
            return "The HAL timestamps are not consistent with a stable sample-rate timeline."
        }
    }
}

/// Offline analysis of REAL timestamp traces. Trace provenance must be tied to
/// the actual selected devices/route by the caller, not an arbitrary clock ID.
struct QuietZoneHALClockAnalyzer: Sendable {
    static let minimumObservations = 8
    static let minimumObservationDuration = 2.0
    static let maximumRelativeDriftPPM = 100.0
    static let maximumNominalRateErrorPPM = 200.0
    static let maximumWorstResidualSeconds = 0.0005

    func analyze(_ trace: QuietZoneHALClockTrace) throws
        -> QuietZoneHALClockHealth {
        guard !trace.inputDeviceID.isEmpty,
              !trace.outputDeviceID.isEmpty,
              trace.nominalSampleRate.isFinite,
              (8_000...192_000).contains(trace.nominalSampleRate)
        else { throw QuietZoneHALClockError.invalidTimebase }

        let input = try evaluate(trace.inputObservations)
        let output = try evaluate(trace.outputObservations)
        let inputStart = trace.inputObservations[0].hostTimeSeconds
        let outputStart = trace.outputObservations[0].hostTimeSeconds
        let inputEnd = trace.inputObservations[trace.inputObservations.count - 1]
            .hostTimeSeconds
        let outputEnd = trace.outputObservations[trace.outputObservations.count - 1]
            .hostTimeSeconds
        let overlap = min(inputEnd, outputEnd) - max(inputStart, outputStart)
        // Independent, non-overlapping captures are not proof that two
        // devices maintained clock stability at the same point in time.
        guard overlap >= Self.minimumObservationDuration else {
            throw QuietZoneHALClockError.invalidTimebase
        }
        let duration = overlap
        let relative = abs(input.rate - output.rate)
            / trace.nominalSampleRate * 1_000_000
        let inputOffset = abs(input.rate - trace.nominalSampleRate)
            / trace.nominalSampleRate * 1_000_000
        let outputOffset = abs(output.rate - trace.nominalSampleRate)
            / trace.nominalSampleRate * 1_000_000

        // Diagnose clock timestamp instability first: large jitter can bias
        // a finite-window rate fit, making an unstable clock appear to drift.
        guard input.worstResidual <= Self.maximumWorstResidualSeconds,
              output.worstResidual <= Self.maximumWorstResidualSeconds else {
            throw QuietZoneHALClockError.excessiveJitter
        }

        guard relative <= Self.maximumRelativeDriftPPM,
              inputOffset <= Self.maximumNominalRateErrorPPM,
              outputOffset <= Self.maximumNominalRateErrorPPM else {
            throw QuietZoneHALClockError.excessiveDrift
        }
        return QuietZoneHALClockHealth(
            measuredInputRateHz: input.rate,
            measuredOutputRateHz: output.rate,
            relativeDriftPPM: relative,
            worstInputResidualSeconds: input.worstResidual,
            worstOutputResidualSeconds: output.worstResidual,
            observationDurationSeconds: duration,
            qualifiedForLoopbackBench: true
        )
    }

    private struct Fit {
        var rate: Double
        var duration: Double
        var worstResidual: Double
    }

    private func evaluate(
        _ observations: [QuietZoneHALClockObservation]
    ) throws -> Fit {
        guard observations.count >= Self.minimumObservations,
              observations.count <= 4_096 else {
            throw QuietZoneHALClockError.insufficientObservation
        }
        let firstTime = observations[0].hostTimeSeconds
        let firstFrame = observations[0].sampleFrame
        guard firstTime.isFinite, firstFrame.isFinite,
              firstTime >= 0, firstFrame >= 0 else {
            throw QuietZoneHALClockError.invalidTimebase
        }
        for i in observations.indices {
            let obs = observations[i]
            guard obs.hostTimeSeconds.isFinite,
                  obs.sampleFrame.isFinite,
                  obs.hostTimeSeconds >= 0,
                  obs.sampleFrame >= 0 else {
                throw QuietZoneHALClockError.invalidTimebase
            }
            if i > 0 {
                guard obs.hostTimeSeconds > observations[i-1].hostTimeSeconds,
                      obs.sampleFrame > observations[i-1].sampleFrame else {
                    throw QuietZoneHALClockError.clockDiscontinuity
                }
            }
        }
        let finalTime = observations[observations.count - 1]
            .hostTimeSeconds
        let duration = finalTime - firstTime
        guard duration >= Self.minimumObservationDuration else {
            throw QuietZoneHALClockError.insufficientObservation
        }

        // Fit against time deltas to preserve precision with large host
        // uptime values and sample-frame counters.
        let deltas = observations.map {
            (
                $0.hostTimeSeconds - firstTime,
                $0.sampleFrame - firstFrame
            )
        }
        let count = Double(deltas.count)
        let meanTime = deltas.reduce(0.0) { $0 + $1.0 } / count
        let meanFrame = deltas.reduce(0.0) { $0 + $1.1 } / count
        var numerator = 0.0
        var denominator = 0.0
        for (time, frame) in deltas {
            numerator += (time - meanTime) * (frame - meanFrame)
            denominator += (time - meanTime) * (time - meanTime)
        }
        guard denominator > 1.0e-12 else {
            throw QuietZoneHALClockError.invalidTimebase
        }
        let rate = numerator / denominator
        let intercept = meanFrame - rate * meanTime
        guard rate.isFinite, rate > 0 else {
            throw QuietZoneHALClockError.invalidTimebase
        }

        let worst = deltas.reduce(0.0) { current, sample in
            max(current,
                abs(sample.1 - (intercept + rate * sample.0)) / rate)
        }
        guard worst.isFinite else {
            throw QuietZoneHALClockError.invalidTimebase
        }
        return Fit(rate: rate, duration: duration, worstResidual: worst)
    }
}
