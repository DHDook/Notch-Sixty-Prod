import Foundation

/// E4 S9c: what the feed-forward shadow (`N60FeedForwardShadow`) starts from,
/// built from the in-app survey (S9b) at the capture's native rate.
///
/// - With an offline design (a physically plausible timing budget), the
///   weights and paths come from `QuietZoneFeedForwardShadowSeedBuilder`, so
///   the shadow starts from the offline solution.
/// - Without one (no E22 bench timing yet), the weights start at zero and the
///   paths are fitted at fd from the seat's position model, so the shadow can
///   run and learn before the design exists.
///
/// Paths: a bulk delay of whole decimated samples (the earlier speaker's
/// impulse-response onset, less a margin) plus a 64-tap fit.
struct QuietZoneFeedForwardShadowPlan: Equatable, Sendable {
    enum SeedSource: Equatable, Sendable {
        case offlineDesign
        case zeroWeights(reason: String)
    }

    var nativeSampleRate: Double
    var decimatedRate: Double
    var seedSource: SeedSource
    /// The offline weights at fd; zero when there is no design.
    var seedLeft: [Float]
    var seedRight: [Float]
    var leftPath: QuietZoneFeedForwardShadowSeed.Path
    var rightPath: QuietZoneFeedForwardShadowSeed.Path
    /// The assembled survey bands (coherent bands only).
    var bands: [QuietZoneVirtualSeatBand]

    var hasOfflineDesign: Bool { seedSource == .offlineDesign }
    var liveDeploymentAuthorized: Bool { false }
}

struct QuietZoneFeedForwardShadowPlanner: Sendable {
    /// The compiler's most (about 16 ms at fd, 4.0–4.4 kHz); the core holds
    /// 128 and adapts them all.
    static let weightTaps = QuietZoneCausalFIRCompiler.maximumTaps
    static let pathTaps = 64
    /// Fewer coherent bands leave the 64-tap path fits poorly determined.
    static let minimumBands = 4
    /// Onset: the first sample within 20 dB of the peak.
    static let onsetFraction: Float = 0.1
    /// Modelled as delay: the onset less this, so the fitted taps hold it.
    static let onsetMarginSeconds = 0.001

    var builder = QuietZoneFeedForwardShadowSeedBuilder()

    func plan(
        bands: [QuietZoneVirtualSeatBand],
        design: QuietZoneVirtualSeatDesign?,
        budget: QuietZoneFeedForwardBudget,
        position: RoomCorrectionMeasurementPosition,
        nativeSampleRate: Double
    ) throws -> QuietZoneFeedForwardShadowPlan {
        let factor = N60AncDecimationFactor(nativeSampleRate)
        guard factor > 0 else { throw QuietZoneFeedForwardShadowSeedError.unsupportedRate }
        let fd = nativeSampleRate / Double(factor)
        guard bands.count >= Self.minimumBands else { throw QuietZoneFeedForwardSurveyError.noCoherentBands }
        let bulkSeconds = Self.pathBulkDelaySeconds(position: position, decimatedRate: fd)
        var zeroReason = "No offline design yet: the shadow starts from zero weights."
        if let design {
            do {
                let seed = try builder.build(
                    design: design, measurements: bands, budget: budget,
                    nativeSampleRate: nativeSampleRate, pathBulkDelaySeconds: bulkSeconds,
                    weightTaps: Self.weightTaps, pathTaps: Self.pathTaps
                )
                return QuietZoneFeedForwardShadowPlan(
                    nativeSampleRate: nativeSampleRate, decimatedRate: fd, seedSource: .offlineDesign,
                    seedLeft: seed.weights.leftTaps, seedRight: seed.weights.rightTaps,
                    leftPath: seed.leftPath, rightPath: seed.rightPath, bands: bands
                )
            } catch {
                zeroReason = "The offline design did not compile at the shadow's rate (\(error.localizedDescription)); the shadow starts from zero weights."
            }
        }
        let model = bands.sorted { $0.frequencyHz < $1.frequencyHz }
        let frequencies = model.map(\.frequencyHz)
        let bulk = Int((bulkSeconds * fd).rounded(.down))
        let zeros = [Float](repeating: 0, count: Self.weightTaps)
        return QuietZoneFeedForwardShadowPlan(
            nativeSampleRate: nativeSampleRate, decimatedRate: fd,
            seedSource: .zeroWeights(reason: zeroReason),
            seedLeft: zeros, seedRight: zeros,
            leftPath: try builder.fitPath(
                model.map(\.leftSecondaryAtListener), at: frequencies,
                decimatedRate: fd, bulkDelay: bulk, taps: Self.pathTaps
            ),
            rightPath: try builder.fitPath(
                model.map(\.rightSecondaryAtListener), at: frequencies,
                decimatedRate: fd, bulkDelay: bulk, taps: Self.pathTaps
            ),
            bands: bands
        )
    }

    /// The earlier speaker's onset less the margin, at most the core's bulk
    /// delay. Zero when either impulse response is silent.
    static func pathBulkDelaySeconds(
        position: RoomCorrectionMeasurementPosition, decimatedRate fd: Double
    ) -> Double {
        func onset(_ ir: [Float]) -> Int? {
            let peak = ir.reduce(Float(0)) { max($0, abs($1)) }
            guard peak > 0, peak.isFinite else { return nil }
            return ir.firstIndex { abs($0) >= onsetFraction * peak }
        }
        guard position.sampleRate > 0,
              let left = onset(position.left.impulseResponse),
              let right = onset(position.right.impulseResponse)
        else { return 0 }
        let seconds = Double(min(left, right)) / position.sampleRate - onsetMarginSeconds
        let limit = Double(QuietZoneFeedForwardShadowSeedBuilder.maximumBulkDelay) / fd
        return min(max(seconds, 0), limit)
    }
}

/// Predicted reduction at the seat per third-octave band, from weight
/// snapshots: residual = H + S_L W_L + S_R W_R over H, the compiler's
/// convention. H is the measured reference-to-seat transfer and S the
/// measured secondary paths, at the nearest survey band. Leakage into the
/// reference is left out on both sides, as nothing plays.
struct QuietZoneFeedForwardShadowComparison: Equatable, Sendable {
    struct Band: Identifiable, Equatable, Sendable {
        var centreHz: Double
        var surveyHz: Double
        var shadowReductionDB: Double
        /// Nil without an offline design.
        var offlineReductionDB: Double?
        var id: Double { centreHz }
    }

    static let centresHz: [Double] = [31.5, 40, 50, 63, 80, 100, 125]
    static let targetReductionDB = QuietZoneQualificationTargets.primaryBroadbandBandReductionDB

    var bands: [Band]

    static func compare(
        plan: QuietZoneFeedForwardShadowPlan, shadowLeft: [Float], shadowRight: [Float]
    ) -> QuietZoneFeedForwardShadowComparison {
        let compiler = QuietZoneCausalFIRCompiler()
        let tolerance = pow(2, 1.0 / 12)
        func reduction(_ band: QuietZoneVirtualSeatBand, _ left: [Float], _ right: [Float]) -> Double {
            let f = band.frequencyHz
            let wl = compiler.response(left.map(Double.init), frequency: f, sampleRate: plan.decimatedRate)
            let wr = compiler.response(right.map(Double.init), frequency: f, sampleRate: plan.decimatedRate)
            let disturbance = band.sourceToListener / band.sourceToReference
            let residual = disturbance + band.leftSecondaryAtListener * wl + band.rightSecondaryAtListener * wr
            return 20 * log10(disturbance.magnitude / max(residual.magnitude, 1.0e-15))
        }
        let rows = centresHz.compactMap { centre -> Band? in
            guard let band = plan.bands.min(by: {
                abs(log($0.frequencyHz / centre)) < abs(log($1.frequencyHz / centre))
            }), band.frequencyHz / centre <= tolerance, centre / band.frequencyHz <= tolerance
            else { return nil }
            return Band(
                centreHz: centre, surveyHz: band.frequencyHz,
                shadowReductionDB: reduction(band, shadowLeft, shadowRight),
                offlineReductionDB: plan.hasOfflineDesign
                    ? reduction(band, plan.seedLeft, plan.seedRight) : nil
            )
        }
        return QuietZoneFeedForwardShadowComparison(bands: rows)
    }
}
