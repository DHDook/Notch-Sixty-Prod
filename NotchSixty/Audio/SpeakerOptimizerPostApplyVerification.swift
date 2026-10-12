import Foundation

struct SpeakerOptimizerPostApplyVerificationOptions:
    Equatable, Sendable {
    var smoothingOctaves: Double = 1.0 / 3.0
    var maximumFilterTrackingRMSDB: Double = 1.25
    var minimumPersistentImprovementDB: Double = 0.10
    var maximumPersistentSeatRegressionDB: Double = 0.50
    var maximumProtectedRegressionDB: Double = 0.35

    func validate() -> Bool {
        smoothingOctaves.isFinite
            && (0.15...1.0).contains(smoothingOctaves)
            && maximumFilterTrackingRMSDB.isFinite
            && (0.25...3.0).contains(maximumFilterTrackingRMSDB)
            && minimumPersistentImprovementDB.isFinite
            && (0...1.0).contains(minimumPersistentImprovementDB)
            && maximumPersistentSeatRegressionDB.isFinite
            && (0...2.0).contains(maximumPersistentSeatRegressionDB)
            && maximumProtectedRegressionDB.isFinite
            && (0...2.0).contains(maximumProtectedRegressionDB)
    }
}

struct SpeakerOptimizerPostApplySourceVerification:
    Equatable, Sendable {
    var source: MultichannelCalibrationSource
    var persistentPointCount: Int
    var protectedPointCount: Int
    var filterTrackingRMSDB: Double
    var persistentRMSEBeforeDB: Double
    var persistentRMSEAfterDB: Double
    var persistentImprovementDB: Double
    var worstPersistentSeatRegressionDB: Double
    var protectedRegressionDB: Double
    var accepted: Bool
    var blockingReasons: [String]
}

struct SpeakerOptimizerPostApplyVerificationReport:
    Equatable, Sendable {
    var applyReceiptID: UUID
    var baselineMeasurementSetID: UUID
    var verificationMeasurementSetID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var evidenceConfidence: Double
    var sources: [SpeakerOptimizerPostApplySourceVerification]
    var blockingReasons: [String]
    var warnings: [String]

    var accepted: Bool {
        !sources.isEmpty
            && sources.allSatisfy(\.accepted)
            && blockingReasons.isEmpty
    }

    var shouldRollback: Bool { !accepted }
    var isMeasuredVerification: Bool { true }
    var canFinalizeDeployment: Bool { accepted }
}

enum SpeakerOptimizerPostApplyVerificationError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case incompatibleIdentity
    case staleOrInvalidApplyReceipt
    case baselineUnqualified
    case verificationUnqualified
    case verificationNotPostApply
    case missingSourceEvidence
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Speaker Optimizer post-Apply verification options are invalid."
        case .incompatibleIdentity:
            return "Baseline and verification measurements do not share the same Playback System, routing, microphone, sample rate, positions and sources."
        case .staleOrInvalidApplyReceipt:
            return "The Speaker Optimizer Apply receipt does not match the deployed PEQ or the measurement evidence."
        case .baselineUnqualified:
            return "The original Speaker Optimizer baseline is not qualified measurement evidence."
        case .verificationUnqualified:
            return "The new post-Apply measurement set is not qualified verification evidence."
        case .verificationNotPostApply:
            return "Every verification sweep must be a new capture made after the Speaker Optimizer Apply receipt."
        case .missingSourceEvidence:
            return "A deployed Speaker Optimizer source does not have matching classification, candidate, baseline and verification evidence."
        case .invalidResponse:
            return "Speaker Optimizer verification responses cannot be safely compared on the required frequency grid."
        }
    }
}

/// Independent measured acceptance for a provisional PEQ deployment.
///
/// This does not trust the modeled candidate's claimed RMSE improvement. It
/// requires new post-Apply microphone captures, re-runs measurement quality
/// qualification, and compares what the room actually changed.
///
/// A constant dB offset is fitted out of observed-vs-expected DELTA only. That
/// prevents a small microphone/playback-level offset from masquerading as
/// filter failure while preserving the deployed PEQ's spectral shape.
struct SpeakerOptimizerPostApplyVerifier: Sendable {
    func verify(
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        receipt: SpeakerOptimizerPEQApplyReceipt,
        options: SpeakerOptimizerPostApplyVerificationOptions = .init()
    ) throws -> SpeakerOptimizerPostApplyVerificationReport {
        guard options.validate() else {
            throw SpeakerOptimizerPostApplyVerificationError.invalidOptions
        }
        try validateIdentity(
            baseline: baseline,
            verification: verification,
            plan: plan,
            receipt: receipt
        )

        let baselineEvidence =
            try SpeakerOptimizerMeasurementEvidenceEvaluator()
                .evaluate(baseline)
        guard baselineEvidence.optimizerReady else {
            throw SpeakerOptimizerPostApplyVerificationError
                .baselineUnqualified
        }
        let verificationEvidence =
            try SpeakerOptimizerMeasurementEvidenceEvaluator()
                .evaluate(verification)
        guard verificationEvidence.optimizerReady else {
            throw SpeakerOptimizerPostApplyVerificationError
                .verificationUnqualified
        }

        let deployedByRole = receipt.deployment.bandsByRole
        var reports: [SpeakerOptimizerPostApplySourceVerification] = []
        var reportBlockers: [String] = []

        for (role, deployedBands) in deployedByRole.sorted(by: {
            $0.key.rawValue < $1.key.rawValue
        }) {
            let source = MultichannelCalibrationSource.speaker(role)
            guard let classified = plan.classification.sources.first(
                    where: { $0.source == source }
                  ),
                  let candidate = plan.candidate.sources.first(
                    where: { $0.source == source && !$0.bands.isEmpty }
                  ),
                  !deployedBands.isEmpty,
                  classified.points.count >= 8 else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .missingSourceEvidence
            }

            try validateCandidateBinding(
                candidate: candidate,
                deployedBands: deployedBands,
                sampleRate: receipt.deployment.sampleRate
            )

            let frequencies = classified.points.map(\.frequencyHz)
            guard frequencies.count == classified.frequenciesHz.count,
                  zip(frequencies, classified.frequenciesHz).allSatisfy({
                      abs($0.0 - $0.1)
                          <= max(1.0e-6, abs($0.0) * 1.0e-9)
                  }) else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .invalidResponse
            }

            let persistent = classified.points.indices.filter {
                classified.points[$0].classification
                    == .speakerPersistent
            }
            let protected = classified.points.indices.filter {
                classified.points[$0].classification
                    != .speakerPersistent
            }
            guard !persistent.isEmpty else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .missingSourceEvidence
            }

            let expectedDelta = try expectedFilterMagnitude(
                deployedBands,
                frequencies: frequencies,
                sampleRate: receipt.deployment.sampleRate
            )

            var baselineResiduals: [[Double]] = []
            var verificationResiduals: [[Double]] = []
            var trackingErrors: [Double] = []

            for position in baseline.positions {
                let before = try meanResponse(
                    set: baseline,
                    positionID: position.id,
                    source: source,
                    frequencies: frequencies
                )
                let after = try meanResponse(
                    set: verification,
                    positionID: position.id,
                    source: source,
                    frequencies: frequencies
                )
                let observedDelta = zip(after, before).map(-)
                let levelOffset = median(
                    zip(observedDelta, expectedDelta).map(-)
                )
                trackingErrors.append(contentsOf:
                    zip(observedDelta, expectedDelta).map {
                        $0.0 - levelOffset - $0.1
                    }
                )

                baselineResiduals.append(
                    localResidual(
                        frequencies: frequencies,
                        magnitudes: before,
                        smoothingOctaves: options.smoothingOctaves
                    )
                )
                verificationResiduals.append(
                    localResidual(
                        frequencies: frequencies,
                        magnitudes: after,
                        smoothingOctaves: options.smoothingOctaves
                    )
                )
            }

            let tracking = rms(trackingErrors)
            let persistentBefore = indexedRMS(
                baselineResiduals, indices: persistent
            )
            let persistentAfter = indexedRMS(
                verificationResiduals, indices: persistent
            )
            let improvement = persistentBefore - persistentAfter

            var worstSeatRegression = -.infinity
            for seat in baselineResiduals.indices {
                let before = indexedRMS(
                    [baselineResiduals[seat]],
                    indices: persistent
                )
                let after = indexedRMS(
                    [verificationResiduals[seat]],
                    indices: persistent
                )
                worstSeatRegression = max(
                    worstSeatRegression,
                    after - before
                )
            }
            if !worstSeatRegression.isFinite {
                worstSeatRegression = .infinity
            }

            let protectedBefore = protected.isEmpty
                ? 0
                : indexedRMS(baselineResiduals, indices: protected)
            let protectedAfter = protected.isEmpty
                ? 0
                : indexedRMS(verificationResiduals, indices: protected)
            let protectedRegression = protectedAfter - protectedBefore

            var blockers: [String] = []
            if !tracking.isFinite
                || tracking > options.maximumFilterTrackingRMSDB {
                blockers.append(
                    "Measured acoustic delta does not track the deployed PEQ closely enough (\(format(tracking)) dB RMS)."
                )
            }
            if !improvement.isFinite
                || improvement < options.minimumPersistentImprovementDB {
                blockers.append(
                    "Speaker-persistent spectral error did not improve by the required amount (measured \(format(improvement)) dB)."
                )
            }
            if worstSeatRegression
                > options.maximumPersistentSeatRegressionDB {
                blockers.append(
                    "At least one listening position regressed in the speaker-persistent region by \(format(worstSeatRegression)) dB."
                )
            }
            if protectedRegression
                > options.maximumProtectedRegressionDB {
                blockers.append(
                    "Room/seat-dependent or otherwise protected regions regressed by \(format(protectedRegression)) dB RMS."
                )
            }

            let accepted = blockers.isEmpty
            if !accepted {
                reportBlockers.append(
                    "\(source.displayName): " + blockers.joined(separator: " ")
                )
            }
            reports.append(
                SpeakerOptimizerPostApplySourceVerification(
                    source: source,
                    persistentPointCount: persistent.count,
                    protectedPointCount: protected.count,
                    filterTrackingRMSDB: tracking,
                    persistentRMSEBeforeDB: persistentBefore,
                    persistentRMSEAfterDB: persistentAfter,
                    persistentImprovementDB: improvement,
                    worstPersistentSeatRegressionDB:
                        worstSeatRegression,
                    protectedRegressionDB: protectedRegression,
                    accepted: accepted,
                    blockingReasons: blockers
                )
            )
        }

        return SpeakerOptimizerPostApplyVerificationReport(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID: baseline.id,
            verificationMeasurementSetID: verification.id,
            playbackSystemID: baseline.playbackSystemID,
            routingSignature: baseline.routingSignature,
            evidenceConfidence: min(
                baselineEvidence.confidence,
                verificationEvidence.confidence
            ),
            sources: reports,
            blockingReasons: reportBlockers,
            warnings: [
                "This report is independent post-Apply microphone evidence; modeled candidate improvement alone cannot satisfy it.",
                "A constant measurement-level offset is removed only from filter-tracking delta. Spectral acceptance still depends on measured response shape.",
                "Failure recommends rollback to the immutable pre-Apply snapshot; rollback itself remains guarded against unrelated post-Apply state drift."
            ]
        )
    }

    private func validateIdentity(
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwarePEQPlan,
        receipt: SpeakerOptimizerPEQApplyReceipt
    ) throws {
        guard baseline.role == .baseline,
              verification.role == .verification,
              baseline.id != verification.id,
              baseline.id == receipt.baselineMeasurementSetID,
              plan.candidate.baselineMeasurementSetID == baseline.id,
              plan.classification.listeningMeasurementSetID == baseline.id,
              plan.classification.characterizationMeasurementSetID
                == receipt.characterizationMeasurementSetID,
              baseline.playbackSystemID == receipt.playbackSystemID,
              verification.playbackSystemID == baseline.playbackSystemID,
              plan.candidate.playbackSystemID == baseline.playbackSystemID,
              baseline.routingSignature == receipt.routingSignature,
              verification.routingSignature == baseline.routingSignature,
              plan.candidate.routingSignature == baseline.routingSignature,
              baseline.microphone == verification.microphone,
              abs(baseline.sampleRate - verification.sampleRate) < 0.5,
              abs(baseline.sampleRate - receipt.deployment.sampleRate) < 0.5,
              baseline.positions == verification.positions,
              baseline.plannedSources == verification.plannedSources else {
            throw SpeakerOptimizerPostApplyVerificationError
                .incompatibleIdentity
        }

        guard receipt.deployment.proposalID == receipt.proposalID,
              receipt.deployment.baselineMeasurementSetID == baseline.id,
              receipt.deployment.characterizationMeasurementSetID
                == receipt.characterizationMeasurementSetID,
              receipt.deployment.routingSignature == receipt.routingSignature,
              receipt.deployment.aggregateCandidateFingerprint
                == receipt.aggregateCandidateFingerprint,
              receipt.expectedAppliedState.outputDeviceProfile?
                .speakerOptimizerPEQ == receipt.deployment else {
            throw SpeakerOptimizerPostApplyVerificationError
                .staleOrInvalidApplyReceipt
        }

        let baselineIDs = Set(baseline.captures.map(\.id))
        guard !verification.captures.isEmpty,
              verification.captures.allSatisfy({
                  $0.capturedAt > receipt.appliedAt
                    && !baselineIDs.contains($0.id)
              }) else {
            throw SpeakerOptimizerPostApplyVerificationError
                .verificationNotPostApply
        }
    }

    private func validateCandidateBinding(
        candidate: SpeakerOptimizerPEQSourceCandidate,
        deployedBands: [SpeakerOptimizerDeployedPEQBand],
        sampleRate: Double
    ) throws {
        guard candidate.bands.count == deployedBands.count else {
            throw SpeakerOptimizerPostApplyVerificationError
                .staleOrInvalidApplyReceipt
        }
        for (candidateBand, deployed) in zip(
            candidate.bands, deployedBands
        ) {
            guard abs(candidateBand.centerHz - deployed.frequencyHz)
                    <= max(1.0e-6, abs(deployed.frequencyHz) * 1.0e-9),
                  abs(candidateBand.q - deployed.q) <= 1.0e-9,
                  abs(candidateBand.gainDB - deployed.gainDB) <= 1.0e-9,
                  (try? deployed.validate(sampleRate: sampleRate)) != nil else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .staleOrInvalidApplyReceipt
            }
        }
    }

    private func expectedFilterMagnitude(
        _ bands: [SpeakerOptimizerDeployedPEQBand],
        frequencies: [Double],
        sampleRate: Double
    ) throws -> [Double] {
        let compiled = try bands.map { deployed -> SpeakerOptimizerPEQBand in
            guard let band = SpeakerOptimizerPEQBand.peak(
                centerHz: deployed.frequencyHz,
                q: deployed.q,
                gainDB: deployed.gainDB,
                sampleRate: sampleRate
            ) else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .staleOrInvalidApplyReceipt
            }
            return band
        }
        return frequencies.map { frequency in
            compiled.reduce(0.0) {
                $0 + $1.magnitudeDB(
                    at: frequency,
                    sampleRate: sampleRate
                )
            }
        }
    }

    private func meanResponse(
        set: SpeakerOptimizerMeasurementSet,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        frequencies: [Double]
    ) throws -> [Double] {
        let captures = set.captures.filter {
            $0.positionID == positionID && $0.source == source
        }
        guard captures.count
                >= SpeakerOptimizerMeasurementEvidenceEvaluator
                    .minimumRepeatCount else {
            throw SpeakerOptimizerPostApplyVerificationError
                .missingSourceEvidence
        }
        return try frequencies.map { frequency in
            try captures.reduce(0.0) { sum, capture in
                sum + (try interpolate(
                    capture.response,
                    frequencyHz: frequency
                ))
            } / Double(captures.count)
        }
    }

    private func interpolate(
        _ response: RoomCorrectionFrequencyResponse,
        frequencyHz: Double
    ) throws -> Double {
        let f = response.frequenciesHz
        let m = response.magnitudeDB
        guard f.count == m.count,
              f.count >= 2,
              f.allSatisfy({ $0.isFinite && $0 > 0 }),
              m.allSatisfy(\.isFinite),
              zip(f, f.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              let first = f.first,
              let last = f.last,
              frequencyHz >= first,
              frequencyHz <= last else {
            throw SpeakerOptimizerPostApplyVerificationError
                .invalidResponse
        }
        if frequencyHz == first { return m[0] }
        if frequencyHz == last { return m[m.count - 1] }
        var low = 0
        var high = f.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if f[mid] <= frequencyHz {
                low = mid
            } else {
                high = mid
            }
        }
        let fraction = log(frequencyHz / f[low])
            / log(f[high] / f[low])
        return m[low] + fraction * (m[high] - m[low])
    }

    private func localResidual(
        frequencies: [Double],
        magnitudes: [Double],
        smoothingOctaves: Double
    ) -> [Double] {
        let logs = frequencies.map(log2)
        let smoothed = frequencies.indices.map { index in
            var weighted = 0.0
            var weightSum = 0.0
            for neighbor in frequencies.indices {
                let distance =
                    (logs[neighbor] - logs[index]) / smoothingOctaves
                guard abs(distance) <= 4 else { continue }
                let weight = exp(-0.5 * distance * distance)
                weighted += magnitudes[neighbor] * weight
                weightSum += weight
            }
            return weightSum > 0
                ? weighted / weightSum
                : magnitudes[index]
        }
        return magnitudes.indices.map {
            magnitudes[$0] - smoothed[$0]
        }
    }

    private func indexedRMS(
        _ seats: [[Double]],
        indices: [Int]
    ) -> Double {
        guard !seats.isEmpty, !indices.isEmpty else { return 0 }
        var values: [Double] = []
        values.reserveCapacity(seats.count * indices.count)
        for seat in seats {
            for index in indices where seat.indices.contains(index) {
                values.append(seat[index])
            }
        }
        return rms(values)
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

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func format(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : "∞"
    }
}
