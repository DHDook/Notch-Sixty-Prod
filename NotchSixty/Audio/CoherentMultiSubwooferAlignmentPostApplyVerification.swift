import Foundation

struct CoherentMultiSubwooferAlignmentSourceVerification:
    Codable, Equatable, Sendable {
    var subwooferIndex: UInt32
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

struct CoherentMultiSubwooferAlignmentVerificationReport:
    Codable, Equatable, Sendable {
    var applyReceiptID: UUID
    var verificationSessionID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var microphone: SpeakerOptimizerMicrophoneIdentity
    var sampleRate: Double
    var subwooferIndices: [UInt32]
    var crossoverFrequencyHz: Double
    var evidenceConfidence: Double
    var sources:
        [CoherentMultiSubwooferAlignmentSourceVerification]
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

enum CoherentMultiSubwooferAlignmentVerificationError:
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
            return "Coordinated multi-Sub verification options are invalid."
        case .staleOrInvalidApplyReceipt:
            return "The coordinated multi-Sub Apply receipt is stale or internally inconsistent."
        case .baselineEvidenceMismatch:
            return "Baseline coordinated coherent evidence no longer matches the evidence approved for Apply."
        case .currentStateDrift:
            return "The Playback System changed after provisional coordinated multi-Sub Apply."
        case .verificationSessionInvalid:
            return "The fresh coordinated verification Measurement Lab session is structurally invalid."
        case .verificationNotPostApply:
            return "Every coordinated verification sweep must be a fresh capture made after Apply."
        case .verificationIdentityMismatch:
            return "Fresh coordinated verification must use the same Playback System, route, microphone, sample rate, Main roles and physical Subs."
        case .pairSetMismatch:
            return "Fresh coordinated verification needs exactly one linked coherent pair for every commissioned Main/Sub combination."
        case .incompatibleFrequencyGrid:
            return "Baseline and fresh coordinated coherent reports do not share one stable comparison grid."
        case .insufficientCrossoverEvidence:
            return "Fresh coordinated verification does not contain enough crossover-band evidence."
        }
    }
}

/// PR108 Slice 9: fresh measured acceptance for the atomic multi-Sub Apply.
///
/// One coherent pair is required for every Main x physical-Sub combination.
/// Every pair must track its Sub plan's own signed delay/polarity phase delta,
/// while the aggregate coordinated system must improve crossover summation.
struct CoherentMultiSubwooferAlignmentPostApplyVerifier:
    Sendable {
    func verify(
        baselineEvidenceGroups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup],
        verificationSession: SpeakerMeasurementLabSession,
        verificationPairIDsBySubwoofer:
            [UInt32: [UUID]],
        currentProfile: PlaybackSystemProfile,
        receipt: CoherentMultiSubwooferAlignmentApplyReceipt,
        options:
            CoherentSubwooferAlignmentVerificationOptions = .init()
    ) throws
        -> CoherentMultiSubwooferAlignmentVerificationReport {
        guard options.validate() else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .invalidOptions
        }
        try validateReceipt(
            baselineEvidenceGroups: baselineEvidenceGroups,
            currentProfile: currentProfile,
            receipt: receipt
        )

        do {
            try verificationSession.validateStructure()
        } catch {
            throw CoherentMultiSubwooferAlignmentVerificationError
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
            throw CoherentMultiSubwooferAlignmentVerificationError
                .verificationIdentityMismatch
        }

        let expectedSubIndices =
            candidate.subwoofers.map(\.subwooferIndex).sorted()
        guard verificationPairIDsBySubwoofer.keys.sorted()
                == expectedSubIndices else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .pairSetMismatch
        }

        var allPairIDs: [UUID] = []
        for index in expectedSubIndices {
            guard let pairIDs =
                    verificationPairIDsBySubwoofer[index],
                  pairIDs.count == candidate.mainRoles.count,
                  Set(pairIDs).count == pairIDs.count else {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .pairSetMismatch
            }
            allPairIDs.append(contentsOf: pairIDs)
        }
        guard Set(allPairIDs).count == allPairIDs.count,
              !allPairIDs.isEmpty else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .pairSetMismatch
        }

        let baselineReports =
            baselineEvidenceGroups.flatMap(\.reports)
        let baselineSessionIDs =
            Set(baselineReports.map(\.sessionID))
        let baselinePairIDs =
            Set(baselineReports.map(\.coherentPairID))
        guard !baselineSessionIDs.contains(
                    verificationSession.id
              ),
              Set(allPairIDs).isDisjoint(
                with: baselinePairIDs
              ) else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .verificationNotPostApply
        }

        let pairSet = Set(allPairIDs)
        let selectedProtocols = verificationSession.protocols
            .filter {
                $0.request.mode == .coherentMainsSubTiming
                    && $0.coherentPairID.map {
                        pairSet.contains($0)
                    } == true
            }
        let selectedProtocolIDs =
            Set(selectedProtocols.map(\.id))
        let selectedCaptures = verificationSession.captures
            .filter {
                selectedProtocolIDs.contains($0.protocolID)
            }
        guard selectedProtocols.count
                == allPairIDs.count * 2,
              !selectedCaptures.isEmpty,
              selectedCaptures.allSatisfy({
                  $0.capturedAt > receipt.appliedAt
              }) else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .verificationNotPostApply
        }

        var verificationReports:
            [SpeakerMeasurementLabCoherentTimingReport] = []
        verificationReports.reserveCapacity(allPairIDs.count)
        for pairID in allPairIDs {
            do {
                verificationReports.append(
                    try SpeakerMeasurementLabCoherentTimingAnalyzer()
                        .analyze(
                            session: verificationSession,
                            coherentPairID: pairID
                        )
                )
            } catch {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .verificationSessionInvalid
            }
        }

        let baselineByKey = try reportsByKey(
            baselineReports,
            candidate: candidate
        )
        let verificationByKey = try reportsByKey(
            verificationReports,
            candidate: candidate
        )
        guard baselineByKey.keys == verificationByKey.keys else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .pairSetMismatch
        }

        let planBySub = Dictionary(
            uniqueKeysWithValues:
                candidate.subwoofers.map {
                    ($0.subwooferIndex, $0)
                }
        )

        var sourceReports:
            [CoherentMultiSubwooferAlignmentSourceVerification] = []
        var globalBlockers: [String] = []
        var beforeEnergy = 0.0
        var afterEnergy = 0.0
        var totalWeight = 0.0
        var minimumConfidence = 1.0

        for key in baselineByKey.keys.sorted(by: {
            if $0.subwooferIndex != $1.subwooferIndex {
                return $0.subwooferIndex < $1.subwooferIndex
            }
            return $0.mainRole.rawValue < $1.mainRole.rawValue
        }) {
            guard let before = baselineByKey[key],
                  let after = verificationByKey[key],
                  let plan = planBySub[key.subwooferIndex],
                  gridsMatch(
                    before.frequenciesHz,
                    after.frequenciesHz
                  ) else {
                throw CoherentMultiSubwooferAlignmentVerificationError
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
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .verificationIdentityMismatch
            }

            let indices = crossoverIndices(
                frequencies: before.frequenciesHz,
                crossoverFrequencyHz:
                    candidate.crossoverFrequencyHz,
                octaves: options.crossoverBandOctaves
            )
            guard indices.count >= options.minimumPointCount else {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .insufficientCrossoverEvidence
            }

            var phaseErrors: [Double] = []
            var magnitudeErrors: [Double] = []
            var localBefore = 0.0
            var localAfter = 0.0
            var localWeight = 0.0

            for index in indices {
                let frequency = before.frequenciesHz[index]
                let expectedPhaseDelta =
                    -2 * Double.pi * frequency
                    * plan
                        .signedRelativeDelayAdjustmentMilliseconds
                    / 1_000
                    + (plan.toggleSubwooferPolarity
                        ? Double.pi : 0)
                let observedPhaseDelta = wrapped(
                    after.wrappedRelativePhaseRadians[index]
                        - before
                            .wrappedRelativePhaseRadians[index]
                )
                phaseErrors.append(
                    wrapped(
                        observedPhaseDelta
                            - wrapped(expectedPhaseDelta)
                    )
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
                localBefore += weight * coherenceEnergy(
                    magnitudeDB:
                        before.relativeMagnitudeDB[index],
                    phaseRadians:
                        before.wrappedRelativePhaseRadians[index]
                )
                localAfter += weight * coherenceEnergy(
                    magnitudeDB:
                        after.relativeMagnitudeDB[index],
                    phaseRadians:
                        after.wrappedRelativePhaseRadians[index]
                )
                localWeight += weight
            }

            let phaseTracking = rms(phaseErrors)
            let magnitudeTracking = rms(magnitudeErrors)
            let beforeDB = 10 * log10(
                max(1.0e-12, localBefore / localWeight)
            )
            let afterDB = 10 * log10(
                max(1.0e-12, localAfter / localWeight)
            )
            let improvement = afterDB - beforeDB

            beforeEnergy += localBefore
            afterEnergy += localAfter
            totalWeight += localWeight

            var blockers: [String] = []
            if !phaseTracking.isFinite
                || phaseTracking
                    > options.maximumPhaseTrackingRMSRadians {
                blockers.append(
                    "Measured relative-phase change does not track this Sub's applied delay/polarity closely enough (\(format(phaseTracking)) rad RMS)."
                )
            }
            if !magnitudeTracking.isFinite
                || magnitudeTracking
                    > options.maximumMagnitudeTrackingRMSDB {
                blockers.append(
                    "Timing/polarity Apply changed this Main/Sub crossover magnitude more than expected (\(format(magnitudeTracking)) dB RMS)."
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
                    "Sub \(key.subwooferIndex + 1) / \(key.mainRole.displayName): "
                        + blockers.joined(separator: " ")
                )
            }
            sourceReports.append(
                CoherentMultiSubwooferAlignmentSourceVerification(
                    subwooferIndex: key.subwooferIndex,
                    mainRole: key.mainRole,
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

        guard totalWeight > 0 else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .insufficientCrossoverEvidence
        }
        let overallBefore = 10 * log10(
            max(1.0e-12, beforeEnergy / totalWeight)
        )
        let overallAfter = 10 * log10(
            max(1.0e-12, afterEnergy / totalWeight)
        )
        let overallImprovement =
            overallAfter - overallBefore

        if overallImprovement
            < options.minimumMeasuredImprovementDB {
            globalBlockers.append(
                "Measured coordinated crossover coherence improved by only \(format(overallImprovement)) dB; at least \(format(options.minimumMeasuredImprovementDB)) dB is required."
            )
        }
        if overallAfter < options.minimumFinalCoherenceDB {
            globalBlockers.append(
                "Final coordinated normalized crossover coherence is \(format(overallAfter)) dB, below the \(format(options.minimumFinalCoherenceDB)) dB acceptance floor."
            )
        }

        return CoherentMultiSubwooferAlignmentVerificationReport(
            applyReceiptID: receipt.id,
            verificationSessionID: verificationSession.id,
            playbackSystemID: receipt.playbackSystemID,
            routingSignature: candidate.routingSignature,
            microphone: candidate.microphone,
            sampleRate: candidate.sampleRate,
            subwooferIndices: expectedSubIndices,
            crossoverFrequencyHz:
                candidate.crossoverFrequencyHz,
            evidenceConfidence: minimumConfidence,
            sources: sourceReports,
            coherenceBeforeDB: overallBefore,
            coherenceAfterDB: overallAfter,
            measuredImprovementDB: overallImprovement,
            blockingReasons: globalBlockers,
            warnings: [
                "This report requires fresh reference-authenticated post-Apply evidence for every commissioned Main/Sub pair.",
                "Each physical Sub is checked against its own signed delay/polarity phase signature while aggregate crossover coherence is evaluated across the coordinated set.",
                "A rejected coordinated report recommends guarded rollback to the immutable pre-Apply Playback System snapshot."
            ]
        )
    }

    private struct PairKey: Hashable {
        var subwooferIndex: UInt32
        var mainRole: OutputProgramRole
    }

    private func validateReceipt(
        baselineEvidenceGroups:
            [CoherentMultiSubwooferAlignmentEvidenceGroup],
        currentProfile: PlaybackSystemProfile,
        receipt: CoherentMultiSubwooferAlignmentApplyReceipt
    ) throws {
        let commissioning =
            CoherentMultiSubwooferAlignmentCommissioningPlanner()
        if currentProfile.state != receipt.expectedAppliedState {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .currentStateDrift
        }
        guard receipt.schemaVersion
                == CoherentMultiSubwooferAlignmentApplyReceipt
                    .currentSchemaVersion,
              receipt.playbackSystemID == currentProfile.id,
              commissioning.fingerprintEvidenceGroups(
                    baselineEvidenceGroups
                ) == receipt.evidenceFingerprint,
              commissioning.fingerprintCandidate(
                    receipt.candidate
                ) == receipt.candidateFingerprint,
              receipt.rollbackSnapshot.playbackSystemID
                == receipt.playbackSystemID,
              let deployment =
                receipt.expectedAppliedState.outputDeviceProfile?
                    .coherentMultiSubwooferAlignment,
              deployment.applyReceiptID == receipt.id,
              deployment.proposalID == receipt.proposalID,
              deployment.evidenceFingerprint
                == receipt.evidenceFingerprint,
              deployment.candidateFingerprint
                == receipt.candidateFingerprint else {
            if commissioning.fingerprintEvidenceGroups(
                    baselineEvidenceGroups
                ) != receipt.evidenceFingerprint {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .baselineEvidenceMismatch
            }
            throw CoherentMultiSubwooferAlignmentVerificationError
                .staleOrInvalidApplyReceipt
        }
    }

    private func reportsByKey(
        _ reports: [SpeakerMeasurementLabCoherentTimingReport],
        candidate: CoherentMultiSubwooferAlignmentCandidate
    ) throws -> [PairKey:
        SpeakerMeasurementLabCoherentTimingReport] {
        let expectedSubs =
            Set(candidate.subwoofers.map(\.subwooferIndex))
        let expectedRoles = Set(candidate.mainRoles)
        guard reports.count
                == expectedSubs.count * expectedRoles.count else {
            throw CoherentMultiSubwooferAlignmentVerificationError
                .pairSetMismatch
        }

        var result:
            [PairKey:
                SpeakerMeasurementLabCoherentTimingReport] = [:]
        for report in reports {
            guard report.crossSourceClockProvenanceAuthenticated,
                  report.playbackSystemID
                    == candidate.playbackSystemID,
                  report.routingSignature
                    == candidate.routingSignature,
                  report.microphone == candidate.microphone,
                  abs(
                    report.sampleRate
                        - candidate.sampleRate
                  ) < 0.5,
                  case .subwoofer(let subIndex)
                    = report.subwoofer,
                  expectedSubs.contains(subIndex),
                  case .speaker(let role) = report.main,
                  expectedRoles.contains(role),
                  report.relativeMagnitudeDB.count
                    == report.frequenciesHz.count,
                  report.wrappedRelativePhaseRadians.count
                    == report.frequenciesHz.count,
                  report.relativeMagnitudeDB
                    .allSatisfy(\.isFinite),
                  report.wrappedRelativePhaseRadians
                    .allSatisfy(\.isFinite) else {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .verificationIdentityMismatch
            }
            let key = PairKey(
                subwooferIndex: subIndex,
                mainRole: role
            )
            guard result[key] == nil else {
                throw CoherentMultiSubwooferAlignmentVerificationError
                    .pairSetMismatch
            }
            result[key] = report
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
