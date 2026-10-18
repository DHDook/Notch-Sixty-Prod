import Foundation

/// E4 S9a: the offline feed-forward design refitted for the adaptive shadow
/// (`N60FeedForwardShadow`), which adapts at the decimated rate
/// fd = fs / floor(fs / 4000), about 4 kHz at every native rate.
///
/// - Weights: the causal FIR compiler run at fd on the same complex-frequency
///   design, so the shadow starts from the offline solution itself rather
///   than from a resampled native-rate filter. Every compiler check applies.
/// - Paths: each measured secondary path S(f) at the listener becomes a bulk
///   delay of whole decimated samples plus a causal real-tap fit of
///   S(f) exp(+j 2 pi f delay / fd), the same regularized fit.
///
/// Like the candidate, a seed never authorizes live output.
struct QuietZoneFeedForwardShadowSeed: Equatable, Sendable {
    struct Path: Equatable, Sendable {
        /// Decimated samples before the first tap.
        var bulkDelay: Int
        var taps: [Float]
    }

    var nativeSampleRate: Double
    var decimatedRate: Double
    /// Weights at fd.
    var weights: QuietZoneCausalFIRCandidate
    var leftPath: Path
    var rightPath: Path

    var liveDeploymentAuthorized: Bool { false }
}

enum QuietZoneFeedForwardShadowSeedError: Error, Equatable {
    case unsupportedRate
    case invalidPathDelay
    case invalidPathTaps
}

struct QuietZoneFeedForwardShadowSeedBuilder: Sendable {
    static let maximumPathTaps = Int(N60_FXLMS_MAX_PATH_TAPS)
    static let maximumBulkDelay = Int(N60_FF_SHADOW_MAX_BULK_DELAY)

    var compiler = QuietZoneCausalFIRCompiler()

    /// - Parameter pathBulkDelaySeconds: the part of the secondary path's
    ///   delay to model as a pure delay (output to listener, less a margin so
    ///   the fitted taps hold the onset).
    func build(
        design: QuietZoneVirtualSeatDesign,
        measurements: [QuietZoneVirtualSeatBand],
        budget: QuietZoneFeedForwardBudget,
        nativeSampleRate: Double,
        pathBulkDelaySeconds: Double,
        weightTaps: Int = 32,
        pathTaps: Int = 64
    ) throws -> QuietZoneFeedForwardShadowSeed {
        let factor = N60AncDecimationFactor(nativeSampleRate)
        guard factor > 0 else { throw QuietZoneFeedForwardShadowSeedError.unsupportedRate }
        let fd = nativeSampleRate / Double(factor)
        guard pathBulkDelaySeconds.isFinite, pathBulkDelaySeconds >= 0 else {
            throw QuietZoneFeedForwardShadowSeedError.invalidPathDelay
        }
        let bulkDelay = Int((pathBulkDelaySeconds * fd).rounded(.down))
        guard bulkDelay <= Self.maximumBulkDelay else {
            throw QuietZoneFeedForwardShadowSeedError.invalidPathDelay
        }
        let weights = try compiler.compile(
            design: design, measurements: measurements, budget: budget,
            sampleRate: fd, tapCount: weightTaps
        )
        let model = measurements.sorted { $0.frequencyHz < $1.frequencyHz }
        let frequencies = model.map(\.frequencyHz)
        return QuietZoneFeedForwardShadowSeed(
            nativeSampleRate: nativeSampleRate,
            decimatedRate: fd,
            weights: weights,
            leftPath: try fitPath(
                model.map(\.leftSecondaryAtListener), at: frequencies,
                decimatedRate: fd, bulkDelay: bulkDelay, taps: pathTaps
            ),
            rightPath: try fitPath(
                model.map(\.rightSecondaryAtListener), at: frequencies,
                decimatedRate: fd, bulkDelay: bulkDelay, taps: pathTaps
            )
        )
    }

    /// Bulk delay plus a causal fit of S(f) exp(+j 2 pi f bulkDelay / fd).
    func fitPath(
        _ samples: [ActiveQuietZoneComplex],
        at frequencies: [Double],
        decimatedRate fd: Double,
        bulkDelay: Int,
        taps: Int
    ) throws -> QuietZoneFeedForwardShadowSeed.Path {
        guard (0...Self.maximumBulkDelay).contains(bulkDelay) else {
            throw QuietZoneFeedForwardShadowSeedError.invalidPathDelay
        }
        guard (1...Self.maximumPathTaps).contains(taps), samples.count == frequencies.count else {
            throw QuietZoneFeedForwardShadowSeedError.invalidPathTaps
        }
        let advanced = zip(samples, frequencies).map { s, f in
            let angle = 2 * Double.pi * f * Double(bulkDelay) / fd
            return s * ActiveQuietZoneComplex(real: cos(angle), imaginary: sin(angle))
        }
        let fitted = try compiler.fit(advanced, at: frequencies, sampleRate: fd, taps: taps)
        return .init(bulkDelay: bulkDelay, taps: fitted.map(Float.init))
    }
}
