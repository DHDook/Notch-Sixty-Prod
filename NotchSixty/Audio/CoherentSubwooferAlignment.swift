import Foundation

enum CoherentSubwooferAlignmentError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case profileInvalid
    case bassManagementRequired
    case evidenceRequired
    case evidenceIdentityMismatch
    case unsupportedSource
    case incompatibleFrequencyGrid
    case insufficientCrossoverEvidence
    case delayCapacityExceeded

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Coherent subwoofer-alignment options are invalid."
        case .profileInvalid:
            return "Coherent subwoofer alignment requires a valid enabled Output Device Profile."
        case .bassManagementRequired:
            return "Physical subwoofer alignment requires bass management and an assigned physical subwoofer."
        case .evidenceRequired:
            return "At least one authenticated coherent Main/Sub timing report is required."
        case .evidenceIdentityMismatch:
            return "Coherent Main/Sub reports must describe the same Playback System, route, microphone, sample rate, and physical subwoofer."
        case .unsupportedSource:
            return "Coherent subwoofer alignment only accepts whole-speaker Main sources paired with one physical Sub source."
        case .incompatibleFrequencyGrid:
            return "Coherent Main/Sub reports do not share one stable frequency grid."
        case .insufficientCrossoverEvidence:
            return "Not enough qualified coherent evidence exists around the active crossover."
        case .delayCapacityExceeded:
            return "The required relative-delay alignment would exceed the existing speaker/subwoofer calibration delay budget."
        }
    }
}

struct CoherentSubwooferAlignmentOptions:
    Equatable, Sendable {
    /// Total optimization span around crossover. 1.0 means +/- 0.5 octave.
    var crossoverBandOctaves: Double = 1.0
    /// Signed relative adjustment search bound. Positive delays the sub;
    /// negative delays the speaker program by the opposite amount.
    var maximumRelativeAdjustmentMilliseconds: Double = 20.0
    var delayStepMilliseconds: Double = 0.02
    var minimumPointCount: Int = 8
    var minimumEvidenceConfidence: Double = 0.80
    var minimumPredictedImprovementDB: Double = 0.20

    func validate() -> Bool {
        crossoverBandOctaves.isFinite
            && (0.25...2.0).contains(crossoverBandOctaves)
            && maximumRelativeAdjustmentMilliseconds.isFinite
            && (1.0...80.0).contains(maximumRelativeAdjustmentMilliseconds)
            && delayStepMilliseconds.isFinite
            && (0.005...0.25).contains(delayStepMilliseconds)
            && minimumPointCount >= 4
            && minimumPointCount <= 256
            && minimumEvidenceConfidence.isFinite
            && (0.5...1.0).contains(minimumEvidenceConfidence)
            && minimumPredictedImprovementDB.isFinite
            && (0...3.0).contains(minimumPredictedImprovementDB)
    }
}

struct CoherentSubwooferAlignmentCandidate:
    Codable, Equatable, Sendable {
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var subwooferIndex: UInt32
    var mainRoles: [OutputProgramRole]
    var crossoverFrequencyHz: Double
    var analyzedFrequencyCount: Int

    /// Positive means add delay to the physical subwoofer. Negative means the
    /// sub would need advancing, which is realized safely by adding the
    /// opposite common delay to all non-LFE speaker lanes.
    var signedRelativeDelayAdjustmentMilliseconds: Double
    var subwooferDelayAdjustmentMilliseconds: Double
    var speakerCommonDelayAdjustmentMilliseconds: Double
    var toggleSubwooferPolarity: Bool
    var resultingSubwooferPolarityInverted: Bool

    /// 0 dB is perfect coherent summation after normalizing by |Main|+|Sub|.
    /// More-negative values indicate increasing cancellation.
    var predictedCoherenceBeforeDB: Double
    var predictedCoherenceAfterDB: Double
    var predictedImprovementDB: Double
    var evidenceConfidence: Double
    var acceptedForPreview: Bool
    var blockingReasons: [String]

    var previewOnly: Bool { true }
    var canDeploy: Bool { false }
    var isMeasuredVerification: Bool { false }
}

/// PR108 Slice 1: proposal-only coherent Main/Sub delay/polarity optimizer.
///
/// PR106 already authenticates the cross-source time origin by dividing each
/// acoustic sweep by a simultaneous electrical reference. This planner turns
/// that measurement-only evidence into a bounded candidate without mutating
/// speaker/subwoofer calibration.
///
/// The search models the full relative phase as:
///
/// residual reference-aligned phase
///   - 2*pi*f*(measured sub-minus-main arrival + signed adjustment)
///   + optional pi polarity toggle
///
/// A positive signed adjustment delays Sub. A negative result is never
/// represented as an impossible negative Sub delay; a later Apply transaction
/// will add the opposite common delay to all non-LFE speaker lanes.
struct CoherentSubwooferAlignmentPlanner: Sendable {
    func propose(
        reports: [SpeakerMeasurementLabCoherentTimingReport],
        profile: OutputDeviceProfileConfiguration,
        bassManagementEnabled: Bool,
        crossoverFrequencyHz: Double,
        options: CoherentSubwooferAlignmentOptions = .init()
    ) throws -> CoherentSubwooferAlignmentCandidate {
        guard options.validate(),
              crossoverFrequencyHz.isFinite,
              crossoverFrequencyHz > 0 else {
            throw CoherentSubwooferAlignmentError.invalidOptions
        }
        do {
            try profile.validateStructure(
                bassManagementEnabled: bassManagementEnabled
            )
        } catch {
            throw CoherentSubwooferAlignmentError.profileInvalid
        }
        guard profile.enabled else {
            throw CoherentSubwooferAlignmentError.profileInvalid
        }
        guard bassManagementEnabled,
              !profile.subwooferAssignments.isEmpty else {
            throw CoherentSubwooferAlignmentError.bassManagementRequired
        }
        guard let first = reports.first else {
            throw CoherentSubwooferAlignmentError.evidenceRequired
        }
        guard first.crossSourceClockProvenanceAuthenticated,
              first.evidenceConfidence >= options.minimumEvidenceConfidence,
              first.sampleRate.isFinite, first.sampleRate > 0,
              crossoverFrequencyHz < first.sampleRate * 0.48 else {
            throw CoherentSubwooferAlignmentError.evidenceRequired
        }
        guard case .speaker(let firstMain) = first.main,
              firstMain != .lowFrequencyEffects,
              case .subwoofer(let subIndex) = first.subwoofer else {
            throw CoherentSubwooferAlignmentError.unsupportedSource
        }

        let referenceGrid = first.frequenciesHz
        guard gridValid(referenceGrid),
              first.relativeMagnitudeDB.count == referenceGrid.count,
              first.wrappedRelativePhaseRadians.count == referenceGrid.count else {
            throw CoherentSubwooferAlignmentError.incompatibleFrequencyGrid
        }

        var mainRoles: [OutputProgramRole] = []
        for report in reports {
            guard report.crossSourceClockProvenanceAuthenticated,
                  report.playbackSystemID == first.playbackSystemID,
                  report.routingSignature == first.routingSignature,
                  report.microphone == first.microphone,
                  abs(report.sampleRate - first.sampleRate) < 0.5,
                  report.subwoofer == first.subwoofer,
                  report.evidenceConfidence >= options.minimumEvidenceConfidence,
                  gridsMatch(referenceGrid, report.frequenciesHz),
                  report.relativeMagnitudeDB.count == referenceGrid.count,
                  report.wrappedRelativePhaseRadians.count == referenceGrid.count,
                  report.relativeMagnitudeDB.allSatisfy(\.isFinite),
                  report.wrappedRelativePhaseRadians.allSatisfy(\.isFinite),
                  report.relativeArrivalMilliseconds.isFinite else {
                throw CoherentSubwooferAlignmentError.evidenceIdentityMismatch
            }
            guard case .speaker(let role) = report.main,
                  role != .lowFrequencyEffects,
                  profile.programLayout.roles.contains(role),
                  profile.speakerAssignments.contains(where: {
                      $0.role == role
                  }) else {
                throw CoherentSubwooferAlignmentError.unsupportedSource
            }
            if !mainRoles.contains(role) { mainRoles.append(role) }
        }
        guard mainRoles.contains(firstMain),
              Set(mainRoles).count == reports.count else {
            throw CoherentSubwooferAlignmentError.evidenceIdentityMismatch
        }
        guard profile.multichannelCalibrationRoutingSignature
                == first.routingSignature,
              let subAssignment = profile.subwooferAssignments.first(where: {
                  $0.index == subIndex
              }) else {
            throw CoherentSubwooferAlignmentError.evidenceIdentityMismatch
        }

        let halfOctaves = options.crossoverBandOctaves / 2
        let low = crossoverFrequencyHz / pow(2, halfOctaves)
        let high = crossoverFrequencyHz * pow(2, halfOctaves)
        let indices = referenceGrid.indices.filter {
            referenceGrid[$0] >= low && referenceGrid[$0] <= high
        }
        guard indices.count >= options.minimumPointCount else {
            throw CoherentSubwooferAlignmentError
                .insufficientCrossoverEvidence
        }

        let before = coherenceScoreDB(
            reports: reports,
            indices: indices,
            crossoverFrequencyHz: crossoverFrequencyHz,
            signedAdjustmentMilliseconds: 0,
            togglePolarity: false
        )

        let maxAdjustment =
            options.maximumRelativeAdjustmentMilliseconds
        let step = options.delayStepMilliseconds
        let steps = Int(floor((2 * maxAdjustment) / step))
        var bestAdjustment = 0.0
        var bestToggle = false
        var bestScore = before

        for stepIndex in 0...steps {
            let adjustment = -maxAdjustment
                + Double(stepIndex) * step
            for toggle in [false, true] {
                guard delayFits(
                    signedAdjustmentMilliseconds: adjustment,
                    profile: profile,
                    subwooferIndex: subIndex,
                    sampleRate: first.sampleRate
                ) else {
                    continue
                }
                let score = coherenceScoreDB(
                    reports: reports,
                    indices: indices,
                    crossoverFrequencyHz: crossoverFrequencyHz,
                    signedAdjustmentMilliseconds: adjustment,
                    togglePolarity: toggle
                )
                if better(
                    score: score,
                    adjustment: adjustment,
                    toggle: toggle,
                    than: bestScore,
                    bestAdjustment: bestAdjustment,
                    bestToggle: bestToggle
                ) {
                    bestScore = score
                    bestAdjustment = adjustment
                    bestToggle = toggle
                }
            }
        }

        guard delayFits(
            signedAdjustmentMilliseconds: bestAdjustment,
            profile: profile,
            subwooferIndex: subIndex,
            sampleRate: first.sampleRate
        ) else {
            throw CoherentSubwooferAlignmentError.delayCapacityExceeded
        }

        let improvement = bestScore - before
        var blockers: [String] = []
        if improvement + 1.0e-9
            < options.minimumPredictedImprovementDB {
            blockers.append(
                "No meaningful crossover-band coherence improvement is predicted by bounded delay/polarity search."
            )
        }

        let currentPolarity =
            subAssignment.calibration?.polarityInverted ?? false
        return CoherentSubwooferAlignmentCandidate(
            playbackSystemID: first.playbackSystemID,
            routingSignature: first.routingSignature,
            microphone: first.microphone,
            sampleRate: first.sampleRate,
            subwooferIndex: subIndex,
            mainRoles: mainRoles.sorted {
                $0.rawValue < $1.rawValue
            },
            crossoverFrequencyHz: crossoverFrequencyHz,
            analyzedFrequencyCount: indices.count * reports.count,
            signedRelativeDelayAdjustmentMilliseconds:
                bestAdjustment,
            subwooferDelayAdjustmentMilliseconds:
                max(0, bestAdjustment),
            speakerCommonDelayAdjustmentMilliseconds:
                max(0, -bestAdjustment),
            toggleSubwooferPolarity: bestToggle,
            resultingSubwooferPolarityInverted:
                currentPolarity != bestToggle,
            predictedCoherenceBeforeDB: before,
            predictedCoherenceAfterDB: bestScore,
            predictedImprovementDB: improvement,
            evidenceConfidence:
                reports.map(\.evidenceConfidence).min() ?? 0,
            acceptedForPreview: blockers.isEmpty,
            blockingReasons: blockers
        )
    }

    private func coherenceScoreDB(
        reports: [SpeakerMeasurementLabCoherentTimingReport],
        indices: [Int],
        crossoverFrequencyHz: Double,
        signedAdjustmentMilliseconds: Double,
        togglePolarity: Bool
    ) -> Double {
        var weightedEnergy = 0.0
        var totalWeight = 0.0
        let delaySeconds =
            signedAdjustmentMilliseconds / 1_000

        for report in reports {
            let arrivalSeconds =
                report.relativeArrivalMilliseconds / 1_000
            for index in indices {
                let frequency = report.frequenciesHz[index]
                let magnitudeRatio = pow(
                    10,
                    report.relativeMagnitudeDB[index] / 20
                )
                let phase =
                    report.wrappedRelativePhaseRadians[index]
                    - 2 * Double.pi * frequency
                        * (arrivalSeconds + delaySeconds)
                    + (togglePolarity ? Double.pi : 0)
                let combinedPower =
                    1 + magnitudeRatio * magnitudeRatio
                    + 2 * magnitudeRatio * cos(phase)
                let idealPower =
                    (1 + magnitudeRatio)
                    * (1 + magnitudeRatio)
                let normalized = max(
                    1.0e-12,
                    combinedPower / max(idealPower, 1.0e-12)
                )
                let octaveDistance = abs(
                    log2(frequency / crossoverFrequencyHz)
                )
                let halfSpan = max(0.125, 0.5)
                let weight = max(
                    0.05,
                    1 - octaveDistance / halfSpan
                )
                weightedEnergy += weight * normalized
                totalWeight += weight
            }
        }
        guard totalWeight > 0 else { return -.infinity }
        return 10 * log10(
            max(1.0e-12, weightedEnergy / totalWeight)
        )
    }

    private func better(
        score: Double,
        adjustment: Double,
        toggle: Bool,
        than bestScore: Double,
        bestAdjustment: Double,
        bestToggle: Bool
    ) -> Bool {
        let epsilon = 1.0e-9
        if score > bestScore + epsilon { return true }
        if abs(score - bestScore) <= epsilon {
            if abs(adjustment) < abs(bestAdjustment) - epsilon {
                return true
            }
            if abs(abs(adjustment) - abs(bestAdjustment)) <= epsilon,
               bestToggle, !toggle {
                return true
            }
        }
        return false
    }

    private func delayFits(
        signedAdjustmentMilliseconds: Double,
        profile: OutputDeviceProfileConfiguration,
        subwooferIndex: UInt32,
        sampleRate: Double
    ) -> Bool {
        if signedAdjustmentMilliseconds >= 0 {
            guard let sub = profile.subwooferAssignments.first(where: {
                $0.index == subwooferIndex
            }) else { return false }
            let current =
                sub.calibration?.delayMilliseconds ?? 0
            let proposed =
                current + signedAdjustmentMilliseconds
            guard PhysicalSubwooferCalibration
                    .delayRangeMilliseconds.contains(proposed) else {
                return false
            }
            let frames = proposed * sampleRate / 1_000
            return frames.isFinite
                && frames
                    <= Double(N60_SUBWOOFER_MAX_DELAY_FRAMES)
        }

        let speakerIncrement =
            -signedAdjustmentMilliseconds
        for assignment in profile.speakerAssignments
        where assignment.role != .lowFrequencyEffects {
            let current =
                assignment.calibration?.delayMilliseconds ?? 0
            let proposed = current + speakerIncrement
            guard SemanticSpeakerCalibration
                    .delayRangeMilliseconds.contains(proposed) else {
                return false
            }
            let frames = proposed * sampleRate / 1_000
            guard frames.isFinite,
                  frames
                    <= Double(N60_PROGRAM_LANE_MAX_DELAY_FRAMES) else {
                return false
            }
        }
        return true
    }

    private func gridValid(_ grid: [Double]) -> Bool {
        grid.count >= 8
            && grid.allSatisfy {
                $0.isFinite && $0 > 0
            }
            && zip(grid, grid.dropFirst()).allSatisfy {
                $0.0 < $0.1
            }
    }

    private func gridsMatch(
        _ lhs: [Double],
        _ rhs: [Double]
    ) -> Bool {
        lhs.count == rhs.count
            && zip(lhs, rhs).allSatisfy {
                abs($0.0 - $0.1)
                    <= max(1.0e-6, abs($0.0) * 1.0e-9)
            }
    }
}
