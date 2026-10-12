import Foundation

struct CoherentSubwooferAlignmentVerificationOptions:
    Codable, Equatable, Sendable {
    var crossoverBandOctaves: Double = 1.0
    var minimumPointCount: Int = 8
    var minimumEvidenceConfidence: Double = 0.80
    var maximumPhaseTrackingRMSRadians: Double = 0.35
    var maximumMagnitudeTrackingRMSDB: Double = 0.75
    var minimumMeasuredImprovementDB: Double = 0.20
    var maximumPerMainRegressionDB: Double = 0.10
    var minimumFinalCoherenceDB: Double = -1.5

    func validate() -> Bool {
        crossoverBandOctaves.isFinite
            && (0.25...2.0).contains(crossoverBandOctaves)
            && minimumPointCount >= 4
            && minimumPointCount <= 256
            && minimumEvidenceConfidence.isFinite
            && (0.5...1.0).contains(minimumEvidenceConfidence)
            && maximumPhaseTrackingRMSRadians.isFinite
            && (0.05...1.5).contains(maximumPhaseTrackingRMSRadians)
            && maximumMagnitudeTrackingRMSDB.isFinite
            && (0.1...3.0).contains(maximumMagnitudeTrackingRMSDB)
            && minimumMeasuredImprovementDB.isFinite
            && (0...3.0).contains(minimumMeasuredImprovementDB)
            && maximumPerMainRegressionDB.isFinite
            && (0...1.0).contains(maximumPerMainRegressionDB)
            && minimumFinalCoherenceDB.isFinite
            && (-12...0).contains(minimumFinalCoherenceDB)
    }
}

struct CoherentSubwooferAlignmentSourceVerification:
    Codable, Equatable, Sendable {
    var mainRole: OutputProgramRole
    var analyzedFrequencyCount: Int
    var phaseTrackingRMSRadians: Double
    var magnitudeTrackingRMSDB: Double
    var coherenceBeforeDB: Double
    var coherenceAfterDB: Double
    var measuredImprovementDB: Double
    var accepted: Bool
    var blockingReasons: [String]
}

struct CoherentSubwooferAlignmentVerificationReport:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var verificationSessionID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var subwooferIndex: UInt32
    var crossoverFrequencyHz: Double
    var evidenceConfidence: Double
    var sources: [CoherentSubwooferAlignmentSourceVerification]
    var coherenceBeforeDB: Double
    var coherenceAfterDB: Double
    var measuredImprovementDB: Double
    var blockingReasons: [String]
    var warnings: [String]

    var accepted: Bool {
        !sources.isEmpty
            && sources.allSatisfy(\.accepted)
            && blockingReasons.isEmpty
    }

    var shouldRollback: Bool { !accepted }
    var isMeasuredVerification: Bool { true }
}

enum CoherentSubwooferAlignmentVerificationError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case staleOrInvalidApplyReceipt
    case baselineEvidenceMismatch
    case currentStateDrift
    case verificationSessionInvalid
    case verificationNotPostApply
    case verificationIdentityMismatch
    case pairSetMismatch
    case incompatibleFrequencyGrid
    case insufficientCrossoverEvidence

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Coherent Sub alignment verification options are invalid."
        case .staleOrInvalidApplyReceipt:
            return "The coherent Sub alignment Apply receipt is stale or internally inconsistent."
        case .baselineEvidenceMismatch:
            return "Baseline coherent evidence no longer matches the evidence approved for Apply."
        case .currentStateDrift:
            return "The Playback System changed after provisional coherent Sub alignment Apply."
        case .verificationSessionInvalid:
            return "The fresh coherent verification Measurement Lab session is structurally invalid."
        case .verificationNotPostApply:
            return "Every selected coherent verification sweep must be a fresh capture made after Apply."
        case .verificationIdentityMismatch:
            return "Fresh coherent verification must use the same Playback System, route, microphone, sample rate, Main roles and physical Sub."
        case .pairSetMismatch:
            return "Fresh coherent verification needs exactly one linked pair for every commissioned Main role."
        case .incompatibleFrequencyGrid:
            return "Baseline and fresh coherent reports do not share one stable comparison grid."
        case .insufficientCrossoverEvidence:
            return "Fresh verification does not contain enough crossover-band evidence."
        }
    }
}

/// PR108 Slice 4: independent measured acceptance of a provisional timing/
/// polarity Apply.
///
/// Verification consumes the real post-Apply Measurement Lab session so capture
/// timestamps can prove freshness. It re-runs the PR106 coherent analyzer; no
/// caller-provided post-Apply report is trusted.
///
/// Because PR108 changes only relative delay/polarity, the expected measured
/// relative-phase delta is exactly:
///
///   -2*pi*f*signedDelay + (togglePolarity ? pi : 0)
///
/// and expected magnitude delta is zero. The verifier separately requires
/// improved coherent Main+Sub summation around crossover.
struct CoherentSubwooferAlignmentPostApplyVerifier: Sendable {
    func verify(
        baselineReports:
            [SpeakerMeasurementLabCoherentTimingReport],
        verificationSession: SpeakerMeasurementLabSession,
        verificationPairIDs: [UUID],
        currentProfile: PlaybackSystemProfile,
        receipt: CoherentSubwooferAlignmentApplyReceipt,
        options:
            CoherentSubwooferAlignmentVerificationOptions = .init()
    ) throws -> CoherentSubwooferAlignmentVerificationReport {
        guard options.validate() else {
            throw CoherentSubwooferAlignmentVerificationError
                .invalidOptions
        }
        try validateReceipt(
            baselineReports: baselineReports,
            currentProfile: currentProfile,
            receipt: receipt
        )

        do {
            try verificationSession.validateStructure()
        } catch {
            throw CoherentSubwooferAlignmentVerificationError
                .verificationSessionInvalid
        }

        let candidate = receipt.candidate
        guard verificationSession.playbackSystemID
                == receipt.playbackSystemID,
              verificationSession.routingSignature
                == candidate.routingSignature,
              verificationSession.microphone
                == candidate.microphone,
              abs(
                verificationSession.sampleRate
                    - candidate.sampleRate
              ) < 0.5 else {
            throw CoherentSubwooferAlignmentVerificationError
                .verificationIdentityMismatch
        }

        let uniquePairIDs = Array(Set(verificationPairIDs))
        guard uniquePairIDs.count == candidate.mainRoles.count,
              uniquePairIDs.count == verificationPairIDs.count,
              !uniquePairIDs.isEmpty else {
            throw CoherentSubwooferAlignmentVerificationError
                .pairSetMismatch
        }

        let baselineSessionIDs = Set(
            baselineReports.map(\.sessionID)
        )
        let baselinePairIDs = Set(
            baselineReports.map(\.coherentPairID)
        )
        guard !baselineSessionIDs.contains(
                    verificationSession.id
              ),
              Set(uniquePairIDs).isDisjoint(
                with: baselinePairIDs
              ) else {
            throw CoherentSubwooferAlignmentVerificationError
                .verificationNotPostApply
        }

        let selectedProtocols = verificationSession.protocols
            .filter {
                $0.request.mode == .coherentMainsSubTiming
                    && $0.coherentPairID.map {
                        Set(uniquePairIDs).contains($0)
                    } == true
            }
        let selectedProtocolIDs = Set(
            selectedProtocols.map(\.id)
        )
        let selectedCaptures = verificationSession.captures
            .filter {
                selectedProtocolIDs.contains($0.protocolID)
            }
        guard !selectedCaptures.isEmpty,
              selectedCaptures.allSatisfy({
                  $0.capturedAt > receipt.appliedAt
              }) else {
            throw CoherentSubwooferAlignmentVerificationError
                .verificationNotPostApply
        }

        var verificationReports:
            [SpeakerMeasurementLabCoherentTimingReport] = []
        verificationReports.reserveCapacity(
            uniquePairIDs.count
        )
        for pairID in uniquePairIDs {
            let report: SpeakerMeasurementLabCoherentTimingReport
            do {
                report =
                    try SpeakerMeasurementLabCoherentTimingAnalyzer()
                        .analyze(
                            session: verificationSession,
                            coherentPairID: pairID
                        )
            } catch {
                throw CoherentSubwooferAlignmentVerificationError
                    .verificationSessionInvalid
            }
            verificationReports.append(report)
        }

        let baselineByRole = try reportsByMainRole(
            baselineReports,
            candidate: candidate
        )
        let verificationByRole = try reportsByMainRole(
            verificationReports,
            candidate: candidate
        )

        let expectedPhaseDelta: (Double) -> Double = {
            frequency in
            -2 * Double.pi * frequency
                * candidate
                    .signedRelativeDelayAdjustmentMilliseconds
                / 1_000
                + (candidate.toggleSubwooferPolarity
                    ? Double.pi : 0)
        }

        var sourceReports:
            [CoherentSubwooferAlignmentSourceVerification] = []
        var globalBlockers: [String] = []
        var beforeEnergy = 0.0
        var afterEnergy = 0.0
        var energyWeight = 0.0
        var minimumConfidence = 1.0

        for role in candidate.mainRoles.sorted(by: {
            $0.rawValue < $1.rawValue
        }) {
            guard let before = baselineByRole[role],
                  let after = verificationByRole[role],
                  gridsMatch(
                    before.frequenciesHz,
                    after.frequenciesHz
                  ) else {
                throw CoherentSubwooferAlignmentVerificationError
                    .incompatibleFrequencyGrid
            }

            minimumConfidence = min(
                minimumConfidence,
                before.evidenceConfidence,
                after.evidenceConfidence
            )
            guard before.evidenceConfidence
                        >= options.minimumEvidenceConfidence,
                  after.evidenceConfidence
                        >= options.minimumEvidenceConfidence else {
                throw CoherentSubwooferAlignmentVerificationError
                    .verificationIdentityMismatch
            }

            let indices = crossoverIndices(
                frequencies: before.frequenciesHz,
                crossoverFrequencyHz:
                    candidate.crossoverFrequencyHz,
                octaves: options.crossoverBandOctaves
            )
            guard indices.count >= options.minimumPointCount else {
                throw CoherentSubwooferAlignmentVerificationError
                    .insufficientCrossoverEvidence
            }

            var phaseErrors: [Double] = []
            var magnitudeErrors: [Double] = []
            var beforeWeighted = 0.0
            var afterWeighted = 0.0
            var weights = 0.0

            for index in indices {
                let frequency = before.frequenciesHz[index]
                let observedPhaseDelta = wrapped(
                    after.wrappedRelativePhaseRadians[index]
                        - before
                            .wrappedRelativePhaseRadians[index]
                )
                let expected = wrapped(
                    expectedPhaseDelta(frequency)
                )
                phaseErrors.append(
                    wrapped(observedPhaseDelta - expected)
                )
                magnitudeErrors.append(
                    after.relativeMagnitudeDB[index]
                        - before.relativeMagnitudeDB[index]
                )

                let weight = crossoverWeight(
                    frequency: frequency,
                    crossoverFrequencyHz:
                        candidate.crossoverFrequencyHz,
                    halfBandOctaves:
                        options.crossoverBandOctaves / 2
                )
                beforeWeighted += weight * coherenceEnergy(
                    magnitudeDB:
                        before.relativeMagnitudeDB[index],
                    phaseRadians:
                        before.wrappedRelativePhaseRadians[index]
                )
                afterWeighted += weight * coherenceEnergy(
                    magnitudeDB:
                        after.relativeMagnitudeDB[index],
                    phaseRadians:
                        after.wrappedRelativePhaseRadians[index]
                )
                weights += weight
            }

            let phaseTracking = rms(phaseErrors)
            let magnitudeTracking = rms(magnitudeErrors)
            let beforeDB = 10 * log10(
                max(1.0e-12, beforeWeighted / weights)
            )
            let afterDB = 10 * log10(
                max(1.0e-12, afterWeighted / weights)
            )
            let improvement = afterDB - beforeDB

            beforeEnergy += beforeWeighted
            afterEnergy += afterWeighted
            energyWeight += weights

            var blockers: [String] = []
            if !phaseTracking.isFinite
                || phaseTracking
                    > options.maximumPhaseTrackingRMSRadians {
                blockers.append(
                    "Measured relative-phase change does not track the applied delay/polarity closely enough (\(format(phaseTracking)) rad RMS)."
                )
            }
            if !magnitudeTracking.isFinite
                || magnitudeTracking
                    > options.maximumMagnitudeTrackingRMSDB {
                blockers.append(
                    "Timing/polarity Apply changed relative crossover magnitude more than expected (\(format(magnitudeTracking)) dB RMS)."
                )
            }
            if improvement
                < -options.maximumPerMainRegressionDB {
                blockers.append(
                    "This Main/Sub pair regressed coherent crossover summation by \(format(-improvement)) dB."
                )
            }

            let accepted = blockers.isEmpty
            if !accepted {
                globalBlockers.append(
                    "\(role.displayName): "
                        + blockers.joined(separator: " ")
                )
            }
            sourceReports.append(
                CoherentSubwooferAlignmentSourceVerification(
                    mainRole: role,
                    analyzedFrequencyCount: indices.count,
                    phaseTrackingRMSRadians: phaseTracking,
                    magnitudeTrackingRMSDB: magnitudeTracking,
                    coherenceBeforeDB: beforeDB,
                    coherenceAfterDB: afterDB,
                    measuredImprovementDB: improvement,
                    accepted: accepted,
                    blockingReasons: blockers
                )
            )
        }

        guard energyWeight > 0 else {
            throw CoherentSubwooferAlignmentVerificationError
                .insufficientCrossoverEvidence
        }
        let overallBefore = 10 * log10(
            max(1.0e-12, beforeEnergy / energyWeight)
        )
        let overallAfter = 10 * log10(
            max(1.0e-12, afterEnergy / energyWeight)
        )
        let overallImprovement =
            overallAfter - overallBefore

        if overallImprovement
            < options.minimumMeasuredImprovementDB {
            globalBlockers.append(
                "Measured crossover coherence improved by only \(format(overallImprovement)) dB; at least \(format(options.minimumMeasuredImprovementDB)) dB is required."
            )
        }
        if overallAfter < options.minimumFinalCoherenceDB {
            globalBlockers.append(
                "Final normalized crossover coherence is \(format(overallAfter)) dB, below the \(format(options.minimumFinalCoherenceDB)) dB acceptance floor."
            )
        }

        return CoherentSubwooferAlignmentVerificationReport(
            applyReceiptID: receipt.id,
            verificationSessionID: verificationSession.id,
            playbackSystemID: receipt.playbackSystemID,
            routingSignature: candidate.routingSignature,
            microphone: candidate.microphone,
            sampleRate: candidate.sampleRate,
            subwooferIndex: candidate.subwooferIndex,
            crossoverFrequencyHz:
                candidate.crossoverFrequencyHz,
            evidenceConfidence: minimumConfidence,
            sources: sourceReports,
            coherenceBeforeDB: overallBefore,
            coherenceAfterDB: overallAfter,
            measuredImprovementDB: overallImprovement,
            blockingReasons: globalBlockers,
            warnings: [
                "This is fresh reference-authenticated post-Apply acoustic evidence; the modeled proposal alone cannot satisfy verification.",
                "Phase tracking verifies the exact applied relative delay/polarity signature; magnitude is expected to remain stable because PR108 does not change gain or EQ.",
                "A rejected report recommends guarded rollback to the immutable pre-Apply Playback System snapshot."
            ]
        )
    }

    private func validateReceipt(
        baselineReports:
            [SpeakerMeasurementLabCoherentTimingReport],
        currentProfile: PlaybackSystemProfile,
        receipt: CoherentSubwooferAlignmentApplyReceipt
    ) throws {
        let commissioning =
            CoherentSubwooferAlignmentCommissioningPlanner()
        guard receipt.schemaVersion
                == CoherentSubwooferAlignmentApplyReceipt
                    .currentSchemaVersion,
              receipt.playbackSystemID == currentProfile.id,
              currentProfile.state
                == receipt.expectedAppliedState,
              commissioning.fingerprintReports(baselineReports)
                == receipt.evidenceFingerprint,
              commissioning.fingerprintCandidate(
                    receipt.candidate
                ) == receipt.candidateFingerprint,
              receipt.rollbackSnapshot.playbackSystemID
                == receipt.playbackSystemID,
              receipt.expectedAppliedState
                != receipt.rollbackSnapshot.playbackSystemState else {
            if currentProfile.state != receipt.expectedAppliedState {
                throw CoherentSubwooferAlignmentVerificationError
                    .currentStateDrift
            }
            if commissioning.fingerprintReports(baselineReports)
                != receipt.evidenceFingerprint {
                throw CoherentSubwooferAlignmentVerificationError
                    .baselineEvidenceMismatch
            }
            throw CoherentSubwooferAlignmentVerificationError
                .staleOrInvalidApplyReceipt
        }
    }

    private func reportsByMainRole(
        _ reports: [SpeakerMeasurementLabCoherentTimingReport],
        candidate: CoherentSubwooferAlignmentCandidate
    ) throws -> [OutputProgramRole:
        SpeakerMeasurementLabCoherentTimingReport] {
        guard reports.count == candidate.mainRoles.count else {
            throw CoherentSubwooferAlignmentVerificationError
                .pairSetMismatch
        }
        var result:
            [OutputProgramRole:
                SpeakerMeasurementLabCoherentTimingReport] = [:]
        for report in reports {
            guard report.crossSourceClockProvenanceAuthenticated,
                  report.playbackSystemID
                    == candidate.playbackSystemID,
                  report.routingSignature
                    == candidate.routingSignature,
                  report.microphone == candidate.microphone,
                  abs(report.sampleRate
                        - candidate.sampleRate) < 0.5,
                  report.subwoofer
                    == .subwoofer(candidate.subwooferIndex),
                  case .speaker(let role) = report.main,
                  candidate.mainRoles.contains(role),
                  result[role] == nil,
                  report.relativeMagnitudeDB.count
                    == report.frequenciesHz.count,
                  report.wrappedRelativePhaseRadians.count
                    == report.frequenciesHz.count,
                  report.relativeMagnitudeDB
                    .allSatisfy(\.isFinite),
                  report.wrappedRelativePhaseRadians
                    .allSatisfy(\.isFinite) else {
                throw CoherentSubwooferAlignmentVerificationError
                    .verificationIdentityMismatch
            }
            result[role] = report
        }
        guard Set(result.keys)
                == Set(candidate.mainRoles) else {
            throw CoherentSubwooferAlignmentVerificationError
                .pairSetMismatch
        }
        return result
    }

    private func crossoverIndices(
        frequencies: [Double],
        crossoverFrequencyHz: Double,
        octaves: Double
    ) -> [Int] {
        let half = octaves / 2
        let low = crossoverFrequencyHz / pow(2, half)
        let high = crossoverFrequencyHz * pow(2, half)
        return frequencies.indices.filter {
            frequencies[$0] >= low
                && frequencies[$0] <= high
        }
    }

    private func coherenceEnergy(
        magnitudeDB: Double,
        phaseRadians: Double
    ) -> Double {
        let ratio = pow(10, magnitudeDB / 20)
        let combined =
            1 + ratio * ratio
                + 2 * ratio * cos(phaseRadians)
        let ideal = (1 + ratio) * (1 + ratio)
        return max(
            1.0e-12,
            combined / max(ideal, 1.0e-12)
        )
    }

    private func crossoverWeight(
        frequency: Double,
        crossoverFrequencyHz: Double,
        halfBandOctaves: Double
    ) -> Double {
        let distance = abs(
            log2(frequency / crossoverFrequencyHz)
        )
        return max(
            0.05,
            1 - distance / max(0.125, halfBandOctaves)
        )
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

    private func wrapped(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }

    private func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty,
              values.allSatisfy(\.isFinite) else {
            return .infinity
        }
        return sqrt(
            values.reduce(0.0) { $0 + $1 * $1 }
                / Double(values.count)
        )
    }

    private func format(_ value: Double) -> String {
        value.isFinite
            ? String(format: "%.2f", value)
            : "∞"
    }
}
