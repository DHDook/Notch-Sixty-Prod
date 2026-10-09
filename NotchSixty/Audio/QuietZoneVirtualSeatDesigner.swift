import Foundation

/// One frequency of *measured* controlled-source transfer. The complex values
/// must be anchored to the same source stimulus, clock and sampling rate.
/// No sequential recording of unknown/random hallway noise can satisfy this.
struct QuietZoneVirtualSeatBand: Equatable, Sendable, Identifiable {
    var frequencyHz: Double
    /// Source -> physical upstream reference microphone.
    var sourceToReference: ActiveQuietZoneComplex
    /// Same fixed source -> virtual listener position.
    var sourceToListener: ActiveQuietZoneComplex
    /// Anti-noise L/R loudspeaker -> listener, same microphone reference.
    var leftSecondaryAtListener: ActiveQuietZoneComplex
    var rightSecondaryAtListener: ActiveQuietZoneComplex
    /// How much anti-noise will leak back into the upstream reference mic.
    var leftLeakageAtReference: ActiveQuietZoneComplex
    var rightLeakageAtReference: ActiveQuietZoneComplex
    /// Repeated-capture coherence, supplied by the calibrated measurement
    /// protocol; not inferred from a single FFT.
    var measuredCoherence: Double

    var id: Double { frequencyHz }
}

struct QuietZoneVirtualSeatBandResult: Equatable, Sendable, Identifiable {
    var frequencyHz: Double
    var disturbanceTransfer: ActiveQuietZoneComplex
    var leftFilter: ActiveQuietZoneComplex
    var rightFilter: ActiveQuietZoneComplex
    var predictedResidual: ActiveQuietZoneComplex
    var modeledReductionDB: Double
    var predictedReferenceLeakageFraction: Double

    var id: Double { frequencyHz }
}

struct QuietZoneVirtualSeatDesign: Equatable, Sendable {
    var bands: [QuietZoneVirtualSeatBandResult]
    var worstModeledReductionDB: Double
    var minimumMeasuredCoherence: Double
    var safePreviewOnly: Bool = true
}

enum QuietZoneVirtualSeatError: Error, LocalizedError, Equatable {
    case inadequateMeasurements
    case invalidAcousticModel
    case insufficientCoherence
    case insufficientActuatorAuthority
    case excessiveReferenceLeakage
    case insufficientExpectedBenefit
    case budgetUnavailable

    var errorDescription: String? {
        switch self {
        case .inadequateMeasurements:
            return "An ordered and synchronized set of LF transfer measurements is required."
        case .invalidAcousticModel:
            return "Transfer values, frequency grid or model provenance are invalid."
        case .insufficientCoherence:
            return "The source-to-seat transfer is not repeatable enough for feed-forward control."
        case .insufficientActuatorAuthority:
            return "The speakers cannot produce reliable corrective pressure at the virtual seat."
        case .excessiveReferenceLeakage:
            return "Own-speaker leakage into the hallway reference microphone is too large without verified echo cancellation."
        case .insufficientExpectedBenefit:
            return "The bounded candidate is not predicted to improve every modeled frequency."
        case .budgetUnavailable:
            return "Measured positive causality reserve is required before designing an anti-noise preview."
        }
    }
}

/// A reproducible, *offline* regularized per-band candidate optimizer.
/// It is a plant-model preflight, NOT a causal FIR filter and NOT an arm permit.
/// Producing a usable causal FIR requires a later constrained FIR compiler with
/// actual sample-clock alignment, jitter bounds and hardware remeasurement.
struct QuietZoneVirtualSeatDesigner: Sendable {
    static let minimumCoherence = 0.85
    static let maximumLeakageFraction = 0.10
    static let minimumModeledReductionDB = 0.25
    static let minimumAuthority = 1.0e-5

    func design(
        measurements: [QuietZoneVirtualSeatBand],
        budget: QuietZoneFeedForwardBudget,
        configuration rawConfiguration: ActiveQuietZoneConfiguration =
            .init()
    ) throws -> QuietZoneVirtualSeatDesign {
        let configuration = try rawConfiguration.validated()
        guard budget.readiness == .physicallyPlausible,
              let reserve = budget.conservativeReserveSeconds,
              reserve.isFinite, reserve >= 0.002 else {
            throw QuietZoneVirtualSeatError.budgetUnavailable
        }
        guard !measurements.isEmpty,
              measurements.count <= 64 else {
            throw QuietZoneVirtualSeatError.inadequateMeasurements
        }
        let ordered = measurements.sorted { $0.frequencyHz < $1.frequencyHz }
        for (index, band) in ordered.enumerated() {
            let components = [
                band.sourceToReference,
                band.sourceToListener,
                band.leftSecondaryAtListener,
                band.rightSecondaryAtListener,
                band.leftLeakageAtReference,
                band.rightLeakageAtReference,
            ]
            guard band.frequencyHz.isFinite,
                  band.frequencyHz >= configuration.minimumFrequencyHz,
                  band.frequencyHz <= configuration.maximumFrequencyHz,
                  (index == 0
                    || band.frequencyHz > ordered[index - 1].frequencyHz + 0.01),
                  components.allSatisfy({
                      $0.real.isFinite && $0.imaginary.isFinite
                  }),
                  band.sourceToReference.magnitude > 1.0e-7,
                  band.sourceToListener.magnitude > 1.0e-7,
                  band.measuredCoherence.isFinite else {
                throw QuietZoneVirtualSeatError.invalidAcousticModel
            }
            guard band.measuredCoherence >= Self.minimumCoherence,
                  band.measuredCoherence <= 1 else {
                throw QuietZoneVirtualSeatError.insufficientCoherence
            }
        }

        // First synthesize per-unit-reference complex controls, then apply a
        // conservative *joint* magnitude budget across the entire frequency
        // grid. This avoids representing 64 independent maxima as safe.
        var unscaled: [(
            band: QuietZoneVirtualSeatBand,
            disturbance: ActiveQuietZoneComplex,
            left: ActiveQuietZoneComplex,
            right: ActiveQuietZoneComplex
        )] = []

        for band in ordered {
            let h = band.sourceToListener / band.sourceToReference
            let left = band.leftSecondaryAtListener
            let right = band.rightSecondaryAtListener
            let authority = left.magnitude * left.magnitude
                + right.magnitude * right.magnitude
            guard authority.isFinite,
                  authority > Self.minimumAuthority else {
                throw QuietZoneVirtualSeatError.insufficientActuatorAuthority
            }
            // Damped minimum-energy stereo least squares solution for
            // h + Sl*Ul + Sr*Ur = 0, normalized to a unit upstream input.
            let lambda = max(authority * 0.035, 1.0e-9)
            let l = -(left.conjugate * h) / (authority + lambda)
            let r = -(right.conjugate * h) / (authority + lambda)
            guard l.real.isFinite, l.imaginary.isFinite,
                  r.real.isFinite, r.imaginary.isFinite else {
                throw QuietZoneVirtualSeatError.invalidAcousticModel
            }
            unscaled.append((band, h, l, r))
        }

        let sumL = unscaled.reduce(0) { $0 + $1.left.magnitude }
        let sumR = unscaled.reduce(0) { $0 + $1.right.magnitude }
        let capPerSource = pow(
            10, configuration.maximumPerSourceTonePeakDBFS / 20
        )
        let capAggregate = pow(
            10, configuration.maximumAggregateSourcePeakDBFS / 20
        )
        let peak = max(
            unscaled.map { $0.left.magnitude }.max() ?? 0,
            unscaled.map { $0.right.magnitude }.max() ?? 0
        )
        guard sumL.isFinite, sumR.isFinite, peak.isFinite else {
            throw QuietZoneVirtualSeatError.invalidAcousticModel
        }
        let scale = min(
            1,
            capPerSource / max(peak, 1.0e-12),
            capAggregate / max(sumL, 1.0e-12),
            capAggregate / max(sumR, 1.0e-12)
        )

        var results: [QuietZoneVirtualSeatBandResult] = []
        var worst = Double.infinity
        for candidate in unscaled {
            let leftFilter = candidate.left * scale
            let rightFilter = candidate.right * scale
            let response = candidate.disturbance
                + candidate.band.leftSecondaryAtListener * leftFilter
                + candidate.band.rightSecondaryAtListener * rightFilter
            let benefit = 20 * log10(
                candidate.disturbance.magnitude
                  / max(response.magnitude, 1.0e-15)
            )
            let echo = candidate.band.leftLeakageAtReference * leftFilter
                + candidate.band.rightLeakageAtReference * rightFilter
            let fraction = echo.magnitude
            guard benefit.isFinite, fraction.isFinite else {
                throw QuietZoneVirtualSeatError.invalidAcousticModel
            }
            // Without active reference-leakage compensation, input pollution
            // above 10% of the unit reference could undermine stability.
            guard fraction <= Self.maximumLeakageFraction else {
                throw QuietZoneVirtualSeatError.excessiveReferenceLeakage
            }
            guard benefit >= Self.minimumModeledReductionDB else {
                throw QuietZoneVirtualSeatError.insufficientExpectedBenefit
            }
            worst = min(worst, benefit)
            results.append(
                QuietZoneVirtualSeatBandResult(
                    frequencyHz: candidate.band.frequencyHz,
                    disturbanceTransfer: candidate.disturbance,
                    leftFilter: leftFilter,
                    rightFilter: rightFilter,
                    predictedResidual: response,
                    modeledReductionDB: benefit,
                    predictedReferenceLeakageFraction: fraction
                )
            )
        }

        return QuietZoneVirtualSeatDesign(
            bands: results,
            worstModeledReductionDB: worst,
            minimumMeasuredCoherence:
                ordered.map(\.measuredCoherence).min() ?? 0
        )
    }
}
