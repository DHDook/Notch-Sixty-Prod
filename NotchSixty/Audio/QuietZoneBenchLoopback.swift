import Foundation

/// PR96 bench-calibration evidence. The playback stimulus and microphone
/// capture MUST be clock-aligned by an instrumented route; array offsets
/// without a shared frame-to-host mapping are not absolute delay evidence.
/// A cable loopback measures an ELECTRICAL round trip, not the propagation
/// delay from a speaker to a listening position.
struct QuietZoneBenchLoopbackCapture: Sendable {
    var routeFingerprint: String
    var inputDeviceID: String
    var outputDeviceID: String
    var nominalSampleRate: Double
    var stimulus: [Float]
    var recorded: [Float]
    var stimulusStartHostSeconds: Double
    var firstRecordedFrameHostSeconds: Double
    var clockUncertaintySeconds: Double
    var captureClipped: Bool
}

struct QuietZoneBenchLoopbackResult: Equatable, Sendable {
    var routeFingerprint: String
    var electricalRoundTripSeconds: Double
    var conservativeUpperBoundSeconds: Double
    var worstRepeatDeviationSeconds: Double
    var measuredSNRDB: Double
    var repetitions: Int
    var validatedForElectricalBench: Bool = true
    var acousticFlightTimeMeasured: Bool { false }
    var antiNoiseLatencyVerified: Bool { false }
    var liveANCQualified: Bool { false }
}

enum QuietZoneBenchLoopbackError: Error, Equatable, LocalizedError {
    case incompatibleRoute
    case untrustedClock
    case unusableCapture
    case unstableDelay
    case insufficientRepetitions

    var errorDescription: String? {
        switch self {
        case .incompatibleRoute: return "All electrical loopback captures must use the same sample rate, clock-qualified device pair and route."
        case .untrustedClock: return "The playback launch and captured microphone frames need a calibrated shared host clock."
        case .unusableCapture: return "Loopback probe is clipped, ambiguous, poorly correlated or too noisy."
        case .unstableDelay: return "Loopback arrival varies too much between repetitions."
        case .insufficientRepetitions: return "At least three independently triggered electrical loopback captures are required."
        }
    }
}

/// Deliberately offline: no control path, no microphone activation, no speaker
/// output, and no deployment permissions.
struct QuietZoneBenchLoopbackAnalyzer: Sendable {
    static let minimumRepetitions = 3
    static let maximumCaptureFrames = 65_536
    static let maximumProbeFrames = 1_024
    static let maximumUncertaintySeconds = 0.0005
    static let maximumRepeatVariationSeconds = 0.00075
    static let minimumCorrelation = 0.90
    static let minimumSNRDB = 25.0

    func analyze(
        _ captures: [QuietZoneBenchLoopbackCapture],
        clock: QuietZoneHALClockTrace
    ) throws -> QuietZoneBenchLoopbackResult {
        guard captures.count >= Self.minimumRepetitions,
              captures.count <= 20 else {
            throw QuietZoneBenchLoopbackError.insufficientRepetitions
        }
        do { _ = try QuietZoneHALClockAnalyzer().analyze(clock) }
        catch { throw QuietZoneBenchLoopbackError.untrustedClock }

        guard let first = captures.first,
              first.inputDeviceID == clock.inputDeviceID,
              first.outputDeviceID == clock.outputDeviceID,
              !first.routeFingerprint.isEmpty,
              abs(first.nominalSampleRate - clock.nominalSampleRate) < 0.5
        else { throw QuietZoneBenchLoopbackError.incompatibleRoute }

        var delays: [Double] = []
        var minSNR = Double.infinity
        var worstClockUncertainty = 0.0
        for capture in captures {
            guard capture.inputDeviceID == first.inputDeviceID,
                  capture.outputDeviceID == first.outputDeviceID,
                  capture.routeFingerprint == first.routeFingerprint,
                  capture.nominalSampleRate == first.nominalSampleRate else {
                throw QuietZoneBenchLoopbackError.incompatibleRoute
            }
            guard capture.clockUncertaintySeconds.isFinite,
                  (0...Self.maximumUncertaintySeconds)
                    .contains(capture.clockUncertaintySeconds),
                  capture.firstRecordedFrameHostSeconds.isFinite,
                  capture.stimulusStartHostSeconds.isFinite,
                  capture.stimulusStartHostSeconds > 0,
                  capture.firstRecordedFrameHostSeconds > 0 else {
                throw QuietZoneBenchLoopbackError.untrustedClock
            }
            guard !capture.captureClipped,
                  (64...Self.maximumProbeFrames)
                    .contains(capture.stimulus.count),
                  capture.recorded.count >= capture.stimulus.count + 96,
                  capture.recorded.count <= Self.maximumCaptureFrames,
                  capture.stimulus.allSatisfy(\.isFinite),
                  capture.recorded.allSatisfy({ $0.isFinite && abs($0) < 0.99 })
            else { throw QuietZoneBenchLoopbackError.unusableCapture }

            let x = capture.stimulus.map(Double.init)
            let n = x.count
            let mean = x.reduce(0, +) / Double(n)
            let centered = x.map { $0 - mean }
            let energy = centered.reduce(0) { $0 + $1 * $1 }
            guard energy > 0.01 else {
                throw QuietZoneBenchLoopbackError.unusableCapture
            }

            var bestIndex = -1
            var bestScore = 0.0
            var secondBest = 0.0
            for offset in 0...(capture.recorded.count - n) {
                var yMean = 0.0
                for i in 0..<n { yMean += Double(capture.recorded[offset + i]) }
                yMean /= Double(n)
                var dot = 0.0
                var power = 0.0
                for i in 0..<n {
                    let y = Double(capture.recorded[offset + i]) - yMean
                    dot += centered[i] * y
                    power += y * y
                }
                let correlation = abs(dot) / sqrt(max(power * energy, 1.0e-20))
                if correlation > bestScore {
                    // Nearby offsets reflect the same impulse: second-best
                    // only matters after considering a complete probe window.
                    if bestIndex >= 0 && abs(offset - bestIndex) >= n {
                        secondBest = max(secondBest, bestScore)
                    }
                    bestScore = correlation
                    bestIndex = offset
                } else if bestIndex >= 0 && abs(offset - bestIndex) >= n {
                    secondBest = max(secondBest, correlation)
                }
            }
            guard bestIndex >= 96,
                  bestScore >= Self.minimumCorrelation,
                  secondBest < bestScore * 0.92 else {
                throw QuietZoneBenchLoopbackError.unusableCapture
            }

            let prefix = capture.recorded[0..<bestIndex]
            let noisePower = prefix.reduce(0.0) {
                $0 + Double($1) * Double($1)
            } / Double(prefix.count)
            let event = capture.recorded[bestIndex..<(bestIndex + n)]
            let signalPower = event.reduce(0.0) {
                $0 + Double($1) * Double($1)
            } / Double(n)
            let snr = 10 * log10(signalPower / max(noisePower, 1.0e-15))
            guard snr.isFinite, snr >= Self.minimumSNRDB else {
                throw QuietZoneBenchLoopbackError.unusableCapture
            }

            let delay = capture.firstRecordedFrameHostSeconds
                + Double(bestIndex) / capture.nominalSampleRate
                - capture.stimulusStartHostSeconds
            guard delay.isFinite, delay > 0, delay < 0.25 else {
                throw QuietZoneBenchLoopbackError.untrustedClock
            }
            delays.append(delay)
            minSNR = min(minSNR, snr)
            worstClockUncertainty = max(
                worstClockUncertainty, capture.clockUncertaintySeconds
            )
        }

        let sorted = delays.sorted()
        let median = sorted[sorted.count / 2]
        let variation = delays.reduce(0.0) {
            max($0, abs($1 - median))
        }
        guard variation <= Self.maximumRepeatVariationSeconds else {
            throw QuietZoneBenchLoopbackError.unstableDelay
        }

        return QuietZoneBenchLoopbackResult(
            routeFingerprint: first.routeFingerprint,
            electricalRoundTripSeconds: median,
            conservativeUpperBoundSeconds: median
                + variation + 3 * worstClockUncertainty
                + 1 / first.nominalSampleRate,
            worstRepeatDeviationSeconds: variation,
            measuredSNRDB: minSNR,
            repetitions: captures.count
        )
    }
}
