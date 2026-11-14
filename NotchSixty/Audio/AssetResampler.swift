import Foundation

/// E7 S2: Swift face of the core's control-plane resampler (`n60/resample.h`, Kaiser sinc in double precision).
/// Control plane only: never call from an audio callback. The one resampler for imported assets: binaural profiles
/// (standard kernel, bit-compatible with the Swift copy it replaced) and speaker impulse responses (precise kernel).
enum AssetResampler {
    enum Quality: Int32, Sendable {
        /// The binaural kernel: 32 zero crossings, beta 8.6.
        case standard = 0
        /// For assets whose response matters to the dB: flat to 0.01 dB at 0.9 x the lower Nyquist, 100 dB rejection.
        case precise = 1
    }

    /// ceil(count x target / source), at least 1; `count` for an unusable rate.
    static func outputCount(_ count: Int, from source: Double, to target: Double) -> Int {
        guard count > 0, count <= Int(UInt32.max) else { return count }
        return Int(n60_resample_output_count(UInt32(count), source, target))
    }

    /// Converts equal-length signals from `source` to `target`; nil for an argument the core refuses. Amplitudes
    /// are scaled by source/target so each signal, read as an impulse response, keeps its frequency response.
    static func resample(
        _ signals: [[Float]], from source: Double, to target: Double, quality: Quality
    ) -> [[Float]]? {
        guard let first = signals.first, !first.isEmpty, signals.allSatisfy({ $0.count == first.count }),
              first.count <= Int(UInt32.max), signals.count <= Int(UInt32.max) else { return nil }
        let inCount = first.count
        let outCount = outputCount(inCount, from: source, to: target)
        guard outCount > 0, outCount < Int(UInt32.max) else { return nil }
        var flat = [Float]()
        flat.reserveCapacity(inCount * signals.count)
        for signal in signals { flat.append(contentsOf: signal) }
        var out = [Float](repeating: 0, count: outCount * signals.count)
        let ok = flat.withUnsafeBufferPointer { input in
            out.withUnsafeMutableBufferPointer { output in
                n60_resample_batch(
                    input.baseAddress, UInt32(inCount), UInt32(signals.count), source, target,
                    quality.rawValue, output.baseAddress, UInt64(output.count))
            }
        }
        guard ok == 1 else { return nil }
        return (0..<signals.count).map { Array(out[($0 * outCount)..<(($0 + 1) * outCount)]) }
    }
}

/// E7 S2 (`e7.rate-adapt`): a speaker impulse response that carries a rate is resampled when it is activated at
/// another rate. The stored filter is never changed (the original is kept); the adapted copy is cached per
/// (filter, rate) so a repeat activation, a Stop/Start or a rate round trip does no work. Control plane only
/// (the engine calls it while building a graph or a convolution program, never from the render path). Measurements
/// used for design or verification still refuse a rate mismatch (they are re-measured, not resampled).
final class SpeakerIRRateAdapter: @unchecked Sendable {
    static let shared = SpeakerIRRateAdapter()

    private struct Entry {
        var source: SpeakerIRFilter
        var rate: Double
        var adapted: SpeakerIRFilter
    }

    private let capacity: Int
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var conversions = 0

    init(capacity: Int = 4) { self.capacity = max(1, capacity) }

    /// Number of conversions performed (cache misses), for tests and diagnostics.
    var conversionCount: Int {
        lock.lock(); defer { lock.unlock() }
        return conversions
    }

    /// The rate `filter` was captured at when it will be resampled for `outputSampleRate`; nil when it plays as is.
    static func sourceRate(of filter: SpeakerIRFilter?, outputSampleRate: Double, enabled: Bool) -> Double? {
        guard enabled, let filter, let rate = filter.sampleRate, rate.isFinite, rate > 0,
              outputSampleRate.isFinite, outputSampleRate > 0, abs(rate - outputSampleRate) >= 0.5 else { return nil }
        return rate
    }

    /// "Resampled from 48 kHz" for the row of an impulse response that will be resampled; nil otherwise.
    static func rowNote(for filter: SpeakerIRFilter?, outputSampleRate: Double, enabled: Bool) -> String? {
        sourceRate(of: filter, outputSampleRate: outputSampleRate, enabled: enabled).map(resampledNote(fromHz:))
    }

    static func resampledNote(fromHz rate: Double) -> String {
        let khz = rate / 1_000
        let text = abs(khz - khz.rounded()) < 0.005 ? String(format: "%.0f", khz) : String(format: "%g", (khz * 10).rounded() / 10)
        return "Resampled from \(text) kHz"
    }

    /// `filter` ready to play at `outputSampleRate`: itself when the flag is off, it carries no rate or the rates
    /// match; otherwise the cached or freshly resampled copy. If the core refuses the conversion the filter comes
    /// back unchanged, so the normal rate-mismatch refusal applies. The caller still validates the tap count.
    func adapted(_ filter: SpeakerIRFilter, outputSampleRate: Double, enabled: Bool) -> SpeakerIRFilter {
        guard let source = Self.sourceRate(of: filter, outputSampleRate: outputSampleRate, enabled: enabled) else {
            return filter
        }
        lock.lock()
        if let index = entries.firstIndex(where: { abs($0.rate - outputSampleRate) < 0.5 && $0.source == filter }) {
            let entry = entries.remove(at: index)
            entries.append(entry)
            lock.unlock()
            return entry.adapted
        }
        lock.unlock()

        var signals = [filter.leftTaps]
        if let right = filter.rightTaps { signals.append(right) }
        guard let converted = AssetResampler.resample(signals, from: source, to: outputSampleRate, quality: .precise)
        else { return filter }
        var result = filter
        result.sampleRate = outputSampleRate
        result.leftTaps = converted[0]
        result.rightTaps = filter.rightTaps == nil ? nil : converted[1]
        // The filter's own group delay scales with the rate; it must stay inside the filter.
        let scaled = (Double(filter.declaredLatencyFrames) * outputSampleRate / source).rounded()
        result.declaredLatencyFrames = UInt32(max(0, min(scaled, Double(max(0, converted[0].count - 1)))))

        lock.lock(); defer { lock.unlock() }
        conversions += 1
        entries.append(Entry(source: filter, rate: outputSampleRate, adapted: result))
        while entries.count > capacity { entries.removeFirst() }
        return result
    }

    /// Validates `filter` for playback at `outputSampleRate` (tap count, finite taps, rate, declared latency) and
    /// returns the filter that plays: the adapted copy when `adapted` resampled it. Throws as the engine always did.
    func validated(_ filter: SpeakerIRFilter, outputSampleRate: Double, enabled: Bool) throws -> SpeakerIRFilter {
        let filter = adapted(filter, outputSampleRate: outputSampleRate, enabled: enabled)
        let tapCount = filter.leftTaps.count
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw SpeakerIRConfigurationError.invalidTapCount(tapCount)
        }
        if let rightTaps = filter.rightTaps, rightTaps.count != tapCount {
            throw SpeakerIRConfigurationError.mismatchedStereoTapCount(left: tapCount, right: rightTaps.count)
        }
        guard filter.leftTaps.allSatisfy(\.isFinite), filter.rightTaps?.allSatisfy(\.isFinite) ?? true else {
            throw SpeakerIRConfigurationError.nonFiniteTap
        }
        try filter.validateSampleRate(forOutputSampleRate: outputSampleRate)
        guard filter.declaredLatencyFrames < UInt32(tapCount) else {
            throw SpeakerIRConfigurationError.invalidDeclaredLatency(filter.declaredLatencyFrames)
        }
        return filter
    }
}
