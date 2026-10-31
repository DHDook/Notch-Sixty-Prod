import Foundation

/// E4 S22b2: how the speakers leak into the reference microphone, at the feed-forward core's
/// decimated rate fd, with a per-tap error bound from repeated sweeps.
///
/// Allocation and threading: control plane only (built after a measurement, read when a shadow
/// starts). Nothing here runs on an audio thread.
struct FeedForwardEchoPath: Codable, Equatable, Sendable {
    /// Whole fd samples of delay before the first tap.
    var bulkDelay: Int
    /// Mean of the repeats.
    var taps: [Float]
    /// Largest deviation across the repeats plus three sigma of the pre-arrival noise, per tap.
    /// All zero when only one repeat exists (a v1 store).
    var bound: [Float]

    var l1: Double { taps.reduce(0.0) { $0 + abs(Double($1)) } }
    var upperL1: Double { zip(taps, bound).reduce(0.0) { $0 + abs(Double($1.0)) + Double($1.1) } }
}

struct FeedForwardEchoModel: Codable, Equatable, Sendable {
    /// fd, Hz.
    var sampleRate: Double
    var nativeSampleRate: Double
    var repeats: Int
    var left: FeedForwardEchoPath
    var right: FeedForwardEchoPath
    /// Smallest per-band coherence of the repeats over 25-150 Hz; nil for one repeat.
    var coherence: Double?
    /// Sum of repeat deviations over sum of mean magnitudes, the worse speaker.
    var repeatDeviation: Double?
    var capturedAt: Date

    static let maximumTaps = 512
    static let maximumBulkDelay = 512
    static let minimumRepeats = 3
    static let onsetFraction: Float = 0.1
    static let tailFraction: Float = 0.0316  // 30 dB below the peak
    static let onsetMarginSeconds = 0.001
    static let sigmaMultiplier = 3.0
    static let minimumCoherence = 0.85
}

enum FeedForwardEchoModelError: Error, Equatable, LocalizedError {
    case unsupportedRate
    case repeatsMissing
    case silentLeakage
    case delayTooLong

    var errorDescription: String? {
        switch self {
        case .unsupportedRate: return "The leakage measurement's sample rate is not supported."
        case .repeatsMissing: return "Each speaker needs the same number of repeated leakage sweeps."
        case .silentLeakage: return "A speaker's leakage into the reference microphone was silent."
        case .delayTooLong: return "The speaker to reference delay is longer than the echo model allows."
        }
    }
}

enum FeedForwardEchoModelBuilder {
    /// `left` and `right` hold one native-rate impulse response per sweep.
    static func build(
        left: [[Float]], right: [[Float]], nativeSampleRate: Double, capturedAt: Date
    ) throws -> FeedForwardEchoModel {
        let factor = Int(N60AncDecimationFactor(nativeSampleRate))
        guard factor > 0 else { throw FeedForwardEchoModelError.unsupportedRate }
        guard !left.isEmpty, left.count == right.count else { throw FeedForwardEchoModelError.repeatsMissing }
        let fd = nativeSampleRate / Double(factor)
        let l = try side(left, nativeSampleRate: nativeSampleRate, factor: factor, fd: fd)
        let r = try side(right, nativeSampleRate: nativeSampleRate, factor: factor, fd: fd)
        return FeedForwardEchoModel(
            sampleRate: fd, nativeSampleRate: nativeSampleRate, repeats: left.count,
            left: l.path, right: r.path,
            coherence: left.count > 1 ? min(l.coherence, r.coherence) : nil,
            repeatDeviation: left.count > 1 ? max(l.deviation, r.deviation) : nil,
            capturedAt: capturedAt
        )
    }

    /// An impulse response to fd: the core's own decimation filter, with its delay removed.
    /// Output j is the response at native time D j - 1 (to within one native frame).
    static func decimate(_ ir: [Float], nativeSampleRate: Double) -> [Float] {
        guard let decimator = N60AncDecimatorCreate(nativeSampleRate) else { return [] }
        defer { N60AncDecimatorDestroy(decimator) }
        let factor = Int(N60AncDecimationFactor(nativeSampleRate))
        let padded = ir.map { $0.isFinite ? $0 : 0 } + [Float](repeating: 0, count: 16 * factor)
        var out = [Float](repeating: 0, count: padded.count / factor + 2)
        let written = Int(N60AncDecimatorProcess(
            decimator, padded, UInt32(padded.count), &out, UInt32(out.count)
        ))
        // The filter's group delay is 8 D native frames: the first 7 outputs precede time zero.
        let skip = 7
        guard written > skip else { return [] }
        // Subsampling an impulse response divides its DC gain by D: scale it back so the fd path
        // has the loudspeaker-to-microphone gain the programme actually sees.
        let gain = Float(factor)
        return out[skip..<written].map { $0 * gain }
    }

    private static func side(
        _ repeats: [[Float]], nativeSampleRate: Double, factor: Int, fd: Double
    ) throws -> (path: FeedForwardEchoPath, coherence: Double, deviation: Double) {
        let decimated = repeats.map { decimate($0, nativeSampleRate: nativeSampleRate) }
        let length = decimated.map(\.count).min() ?? 0
        guard length > 0 else { throw FeedForwardEchoModelError.silentLeakage }
        let n = Double(decimated.count)
        let mean = (0..<length).map { t in
            Float(decimated.reduce(0.0) { $0 + Double($1[t]) } / n)
        }
        let peak = mean.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0, peak.isFinite, let onset = mean.firstIndex(where: { abs($0) >= FeedForwardEchoModel.onsetFraction * peak })
        else { throw FeedForwardEchoModelError.silentLeakage }
        let margin = Int((FeedForwardEchoModel.onsetMarginSeconds * fd).rounded())
        let bulk = max(onset - margin, 0)
        guard bulk <= FeedForwardEchoModel.maximumBulkDelay else { throw FeedForwardEchoModelError.delayTooLong }
        let tail = mean.lastIndex(where: { abs($0) >= FeedForwardEchoModel.tailFraction * peak }) ?? onset
        let end = min(tail + 1, bulk + FeedForwardEchoModel.maximumTaps, length)
        let range = bulk..<max(end, bulk + 1)

        // sigma: the pre-arrival noise of each repeat, or its last quarter when that is too short.
        func sigma(_ h: [Float]) -> Double {
            let window = onset >= 8 ? Array(h[0..<(onset - 1)]) : Array(h[(length * 3 / 4)..<length])
            guard !window.isEmpty else { return 0 }
            return (window.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(window.count)).squareRoot()
        }
        let sigmaMax = decimated.count > 1 ? decimated.map(sigma).max() ?? 0 : 0
        var bound = [Float](), taps = [Float]()
        var deviation = 0.0, magnitude = 0.0
        for t in range {
            let m = Double(mean[t])
            let d = decimated.map { abs(Double($0[t]) - m) }.max() ?? 0
            taps.append(mean[t])
            bound.append(decimated.count > 1 ? Float(d + FeedForwardEchoModel.sigmaMultiplier * sigmaMax) : 0)
            deviation += d
            magnitude += abs(m)
        }
        return (
            FeedForwardEchoPath(bulkDelay: bulk, taps: taps, bound: bound),
            decimated.count > 1 ? coherence(decimated, fd: fd) : 1,
            decimated.count > 1 ? deviation / max(magnitude, 1.0e-9) : 0
        )
    }

    /// |sum H_i|^2 / (N sum |H_i|^2) per band over 25-150 Hz: 1 when the repeats agree in
    /// magnitude and phase. Bands with almost no energy are left out.
    private static func coherence(_ repeats: [[Float]], fd: Double) -> Double {
        var perBand: [(energy: Double, value: Double)] = []
        for f in QuietZoneFeedForwardSurveyGrid.frequenciesHz {
            let h = repeats.map { QuietZoneFeedForwardBandAssembler.response($0, f, fd) }
            let sumRe = h.reduce(0.0) { $0 + $1.real }, sumIm = h.reduce(0.0) { $0 + $1.imaginary }
            let energy = h.reduce(0.0) { $0 + $1.real * $1.real + $1.imaginary * $1.imaginary }
            perBand.append((energy, energy > 0 ? (sumRe * sumRe + sumIm * sumIm) / (Double(h.count) * energy) : 0))
        }
        let top = perBand.map(\.energy).max() ?? 0
        let kept = perBand.filter { $0.energy > 1.0e-6 * top }
        return kept.map(\.value).min() ?? 0
    }
}

/// The leakage stability check (E4 S22b2). PR98's maths (repeat deviation at most 0.10, and the
/// sum over speakers of the inflated path L1 times the weight L1 at most 0.10) on the in-app
/// echo model and the current shadow weights.
enum FeedForwardLeakageStabilityCheck {
    static let maximumRepeatDeviation = 0.10
    static let maximumLoopGain = 0.10

    enum Verdict: Equatable, Sendable {
        case passed(loopGain: Double)
        case notChecked(String)
        case refused(String)

        var wouldBeRefused: Bool { if case .refused = self { return true } else { return false } }
    }

    static func evaluate(model: FeedForwardEchoModel?, weightsLeft: [Float], weightsRight: [Float]) -> Verdict {
        guard let model else { return .notChecked("not checked: measure leakage again") }
        guard model.repeats >= FeedForwardEchoModel.minimumRepeats,
              let coherence = model.coherence, let deviation = model.repeatDeviation
        else { return .notChecked("not checked: measure leakage again") }
        guard coherence >= FeedForwardEchoModel.minimumCoherence else {
            return .refused(String(format: "leakage: repeats not coherent (%.2f)", coherence))
        }
        guard deviation <= maximumRepeatDeviation else {
            return .refused(String(format: "leakage: repeats differ by %.0f%%", deviation * 100))
        }
        let l1 = { (w: [Float]) in w.reduce(0.0) { $0 + abs(Double($1)) } }
        let loop = model.left.upperL1 * l1(weightsLeft) + model.right.upperL1 * l1(weightsRight)
        guard loop.isFinite, loop <= maximumLoopGain else {
            return .refused(String(format: "leakage: loop gain %.3f over %.2f", loop, maximumLoopGain))
        }
        return .passed(loopGain: loop)
    }
}
