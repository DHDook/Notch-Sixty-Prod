import Foundation

/// E11 S4: the gated (quasi-anechoic) view of one captured impulse response: a down-sampled
/// peak envelope for the IR plot, the gate markers, and the lowest frequency the gate can
/// resolve. The numbers follow `SpeakerMeasurementLabQuasiAnechoicAnalyzer` exactly: the gate
/// opens `preArrivalMilliseconds` before the direct arrival, closes `reflectionFreePostArrival`
/// after it, and the reliable band starts at `minimumCycles / post` (1 / gate length when one
/// cycle is enough).
struct MeasurementGatedPlot: Equatable, Sendable {
    var sampleRate: Double
    /// Display range in seconds on the impulse response's own time axis.
    var displayStartSeconds: Double
    var displayEndSeconds: Double
    /// Peak |h| per bucket, normalised so the largest is 1.
    var envelope: [Float]
    var gateStartSeconds: Double
    var arrivalSeconds: Double
    var taperStartSeconds: Double
    var gateEndSeconds: Double
    /// Post-arrival length of the gate (the reflection-free time the owner assumed).
    var gateLengthSeconds: Double
    /// 1 / gate length.
    var oneOverGateHz: Double
    /// Lowest frequency with `minimumCycles` full cycles in the gate; what the analyser reports as its floor.
    var lowestValidFrequencyHz: Double

    init?(
        impulseResponse: [Float], sampleRate: Double, directArrivalSeconds: Double,
        window: SpeakerMeasurementLabQuasiAnechoicWindow = .init(), maxPoints: Int = 600
    ) {
        guard window.validate(), sampleRate.isFinite, sampleRate > 0, maxPoints >= 8,
              directArrivalSeconds.isFinite, directArrivalSeconds >= 0,
              impulseResponse.count > 8,
              Int((directArrivalSeconds * sampleRate).rounded()) < impulseResponse.count else { return nil }
        let pre = window.preArrivalMilliseconds / 1000
        let post = window.reflectionFreePostArrivalMilliseconds / 1000
        let fade = window.fadeOutMilliseconds / 1000
        self.sampleRate = sampleRate
        arrivalSeconds = directArrivalSeconds
        gateStartSeconds = max(0, directArrivalSeconds - pre)
        gateEndSeconds = directArrivalSeconds + post
        taperStartSeconds = max(directArrivalSeconds, gateEndSeconds - fade)
        gateLengthSeconds = post
        oneOverGateHz = 1 / post
        lowestValidFrequencyHz = window.minimumCyclesForReliableMagnitude / post
        let duration = Double(impulseResponse.count) / sampleRate
        displayStartSeconds = max(0, directArrivalSeconds - max(0.002, 3 * pre))
        displayEndSeconds = min(duration, directArrivalSeconds + 2.5 * post)
        let first = Int((displayStartSeconds * sampleRate).rounded(.down))
        let last = min(impulseResponse.count, Int((displayEndSeconds * sampleRate).rounded(.up)))
        guard last - first >= 8 else { return nil }
        let buckets = min(maxPoints, last - first)
        var peaks = [Float](repeating: 0, count: buckets)
        for index in first..<last {
            let bucket = min(buckets - 1, (index - first) * buckets / (last - first))
            peaks[bucket] = max(peaks[bucket], abs(impulseResponse[index]))
        }
        let top = peaks.max() ?? 0
        envelope = top > 0 ? peaks.map { $0 / top } : peaks
    }

    /// Position of a time on the display axis, 0...1 (clamped).
    func fraction(of seconds: Double) -> Double {
        let span = displayEndSeconds - displayStartSeconds
        guard span > 0 else { return 0 }
        return min(1, max(0, (seconds - displayStartSeconds) / span))
    }
}
