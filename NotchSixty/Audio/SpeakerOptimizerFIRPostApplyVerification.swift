import Foundation

/// Independent measured acceptance for a provisional Speaker Optimizer FIR.
///
/// The verifier is intentionally separate from the PEQ verifier so the mature
/// PEQ path stays unchanged. It applies the same acoustic acceptance rules, but
/// derives the expected filter delta from the exact deployed Float FIR taps.
struct SpeakerOptimizerFIRPostApplyVerifier: Sendable {
    func verify(
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        receipt: SpeakerOptimizerFIRApplyReceipt,
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

        var reports: [SpeakerOptimizerPostApplySourceVerification] = []
        var reportBlockers: [String] = []

        for deployed in receipt.deployment.sources.sorted(by: {
            $0.role.rawValue < $1.role.rawValue
        }) {
            let source =
                MultichannelCalibrationSource.speaker(deployed.role)
            guard let classified =
                    plan.classification.sources.first(
                        where: { $0.source == source }
                    ),
                  let candidate =
                    plan.candidate.sources.first(
                        where: {
                            $0.source == source
                                && $0.acceptedForPreview
                                && !$0.taps.isEmpty
                        }
                    ),
                  classified.points.count >= 8 else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .missingSourceEvidence
            }

            try validateCandidateBinding(
                candidate: candidate,
                deployed: deployed,
                tapCount: receipt.deployment.tapCount
            )

            let frequencies =
                classified.points.map(\.frequencyHz)
            guard frequencies.count
                    == classified.frequenciesHz.count,
                  zip(
                    frequencies,
                    classified.frequenciesHz
                  ).allSatisfy({
                      abs($0.0 - $0.1)
                          <= max(
                              1.0e-6,
                              abs($0.0) * 1.0e-9
                          )
                  }) else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .invalidResponse
            }

            let persistent =
                classified.points.indices.filter {
                    classified.points[$0].classification
                        == .speakerPersistent
                }
            let protected =
                classified.points.indices.filter {
                    classified.points[$0].classification
                        != .speakerPersistent
                }
            guard !persistent.isEmpty else {
                throw SpeakerOptimizerPostApplyVerificationError
                    .missingSourceEvidence
            }

            let expectedDelta = try expectedFIRMagnitude(
                deployed.taps,
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
                trackingErrors.append(
                    contentsOf:
                        zip(
                            observedDelta,
                            expectedDelta
                        ).map {
                            $0.0 - levelOffset - $0.1
                        }
                )

                baselineResiduals.append(
                    localResidual(
                        frequencies: frequencies,
                        magnitudes: before,
                        smoothingOctaves:
                            options.smoothingOctaves
                    )
                )
                verificationResiduals.append(
                    localResidual(
                        frequencies: frequencies,
                        magnitudes: after,
                        smoothingOctaves:
                            options.smoothingOctaves
                    )
                )
            }

            let tracking = rms(trackingErrors)
            let persistentBefore = indexedRMS(
                baselineResiduals,
                indices: persistent
            )
            let persistentAfter = indexedRMS(
                verificationResiduals,
                indices: persistent
            )
            let improvement =
                persistentBefore - persistentAfter

            var worstSeatRegression = -Double.infinity
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
                : indexedRMS(
                    baselineResiduals,
                    indices: protected
                )
            let protectedAfter = protected.isEmpty
                ? 0
                : indexedRMS(
                    verificationResiduals,
                    indices: protected
                )
            let protectedRegression =
                protectedAfter - protectedBefore

            var blockers: [String] = []
            if !tracking.isFinite
                || tracking
                    > options.maximumFilterTrackingRMSDB {
                blockers.append(
                    "Measured acoustic delta does not track the deployed FIR closely enough (\(format(tracking)) dB RMS)."
                )
            }
            if !improvement.isFinite
                || improvement
                    < options.minimumPersistentImprovementDB {
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
                    "\(source.displayName): "
                        + blockers.joined(separator: " ")
                )
            }
            reports.append(
                SpeakerOptimizerPostApplySourceVerification(
                    source: source,
                    persistentPointCount:
                        persistent.count,
                    protectedPointCount:
                        protected.count,
                    filterTrackingRMSDB: tracking,
                    persistentRMSEBeforeDB:
                        persistentBefore,
                    persistentRMSEAfterDB:
                        persistentAfter,
                    persistentImprovementDB:
                        improvement,
                    worstPersistentSeatRegressionDB:
                        worstSeatRegression,
                    protectedRegressionDB:
                        protectedRegression,
                    accepted: accepted,
                    blockingReasons: blockers
                )
            )
        }

        return SpeakerOptimizerPostApplyVerificationReport(
            applyReceiptID: receipt.id,
            baselineMeasurementSetID: baseline.id,
            verificationMeasurementSetID:
                verification.id,
            playbackSystemID:
                baseline.playbackSystemID,
            routingSignature:
                baseline.routingSignature,
            evidenceConfidence: min(
                baselineEvidence.confidence,
                verificationEvidence.confidence
            ),
            sources: reports,
            blockingReasons: reportBlockers,
            warnings: [
                "This report is independent post-Apply microphone evidence; modeled FIR improvement alone cannot satisfy it.",
                "Expected acoustic delta is computed from the exact persisted FIR taps, not the preview response cache.",
                "A constant measurement-level offset is removed only from filter-tracking delta. Spectral acceptance still depends on measured response shape.",
                "Failure recommends rollback to the immutable pre-Apply snapshot; rollback remains guarded against unrelated post-Apply state drift."
            ]
        )
    }

    private func validateIdentity(
        baseline: SpeakerOptimizerMeasurementSet,
        verification: SpeakerOptimizerMeasurementSet,
        plan: SpeakerOptimizerClassificationAwareFIRPlan,
        receipt: SpeakerOptimizerFIRApplyReceipt
    ) throws {
        guard baseline.role == .baseline,
              verification.role == .verification,
              baseline.id != verification.id,
              baseline.id
                == receipt.baselineMeasurementSetID,
              plan.candidate.baselineMeasurementSetID
                == baseline.id,
              plan.classification.listeningMeasurementSetID
                == baseline.id,
              plan.classification
                .characterizationMeasurementSetID
                == receipt.characterizationMeasurementSetID,
              baseline.playbackSystemID
                == receipt.playbackSystemID,
              verification.playbackSystemID
                == baseline.playbackSystemID,
              plan.candidate.playbackSystemID
                == baseline.playbackSystemID,
              baseline.routingSignature
                == receipt.routingSignature,
              verification.routingSignature
                == baseline.routingSignature,
              plan.candidate.routingSignature
                == baseline.routingSignature,
              baseline.microphone
                == verification.microphone,
              abs(
                baseline.sampleRate
                    - verification.sampleRate
              ) < 0.5,
              abs(
                baseline.sampleRate
                    - receipt.deployment.sampleRate
              ) < 0.5,
              baseline.positions
                == verification.positions,
              baseline.plannedSources
                == verification.plannedSources else {
            throw SpeakerOptimizerPostApplyVerificationError
                .incompatibleIdentity
        }

        guard receipt.deployment.proposalID
                == receipt.proposalID,
              receipt.deployment.baselineMeasurementSetID
                == baseline.id,
              receipt.deployment
                .characterizationMeasurementSetID
                == receipt.characterizationMeasurementSetID,
              receipt.deployment.routingSignature
                == receipt.routingSignature,
              receipt.deployment
                .aggregateCandidateFingerprint
                == receipt.aggregateCandidateFingerprint,
              receipt.expectedAppliedState
                .outputDeviceProfile?
                .speakerOptimizerFIR
                == receipt.deployment else {
            throw SpeakerOptimizerPostApplyVerificationError
                .staleOrInvalidApplyReceipt
        }

        let baselineIDs =
            Set(baseline.captures.map(\.id))
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
        candidate: SpeakerOptimizerFIRSourceCandidate,
        deployed: SpeakerOptimizerFIRSourceDeployment,
        tapCount: Int
    ) throws {
        guard candidate.acceptedForPreview,
              candidate.taps.count == tapCount,
              candidate.taps == deployed.taps,
              abs(
                candidate.maximumPositiveGainDB
                    - deployed.maximumPositiveGainDB
              ) <= 1.0e-9,
              abs(
                candidate.recommendedHeadroomDB
                    - deployed.recommendedHeadroomDB
              ) <= 1.0e-9 else {
            throw SpeakerOptimizerPostApplyVerificationError
                .staleOrInvalidApplyReceipt
        }
    }

    private func expectedFIRMagnitude(
        _ taps: [Float],
        frequencies: [Double],
        sampleRate: Double
    ) throws -> [Double] {
        guard sampleRate.isFinite, sampleRate > 0,
              !taps.isEmpty,
              taps.allSatisfy(\.isFinite),
              frequencies.allSatisfy({
                  $0.isFinite
                    && $0 > 0
                    && $0 < sampleRate * 0.5
              }) else {
            throw SpeakerOptimizerPostApplyVerificationError
                .invalidResponse
        }

        return frequencies.map { frequency in
            let omega =
                2 * Double.pi * frequency / sampleRate
            var real = 0.0
            var imaginary = 0.0
            for (index, tap) in taps.enumerated() {
                let phase =
                    omega * Double(index)
                real += Double(tap) * cos(phase)
                imaginary -=
                    Double(tap) * sin(phase)
            }
            let magnitude = hypot(real, imaginary)
            return 20 * log10(max(magnitude, 1.0e-12))
        }
    }

    private func meanResponse(
        set: SpeakerOptimizerMeasurementSet,
        positionID: UUID,
        source: MultichannelCalibrationSource,
        frequencies: [Double]
    ) throws -> [Double] {
        let captures = set.captures.filter {
            $0.positionID == positionID
                && $0.source == source
        }
        guard captures.count
                >= SpeakerOptimizerMeasurementEvidenceEvaluator
                    .minimumRepeatCount else {
            throw SpeakerOptimizerPostApplyVerificationError
                .missingSourceEvidence
        }
        return try frequencies.map { frequency in
            try captures.reduce(0.0) {
                sum, capture in
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
              f.allSatisfy({
                  $0.isFinite && $0 > 0
              }),
              m.allSatisfy(\.isFinite),
              zip(
                f,
                f.dropFirst()
              ).allSatisfy({
                  $0.0 < $0.1
              }),
              let first = f.first,
              let last = f.last,
              frequencyHz >= first,
              frequencyHz <= last else {
            throw SpeakerOptimizerPostApplyVerificationError
                .invalidResponse
        }
        if frequencyHz == first { return m[0] }
        if frequencyHz == last {
            return m[m.count - 1]
        }
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
        let fraction =
            log(frequencyHz / f[low])
                / log(f[high] / f[low])
        return m[low]
            + fraction * (m[high] - m[low])
    }

    private func localResidual(
        frequencies: [Double],
        magnitudes: [Double],
        smoothingOctaves: Double
    ) -> [Double] {
        let logs = frequencies.map(log2)
        let smoothed = frequencies.indices.map {
            index in
            var weighted = 0.0
            var weightSum = 0.0
            for neighbor in frequencies.indices {
                let distance =
                    (logs[neighbor] - logs[index])
                        / smoothingOctaves
                guard abs(distance) <= 4 else {
                    continue
                }
                let weight =
                    exp(-0.5 * distance * distance)
                weighted +=
                    magnitudes[neighbor] * weight
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
        guard !seats.isEmpty,
              !indices.isEmpty else {
            return 0
        }
        var values: [Double] = []
        values.reserveCapacity(
            seats.count * indices.count
        )
        for seat in seats {
            for index in indices
            where seat.indices.contains(index) {
                values.append(seat[index])
            }
        }
        return rms(values)
    }

    private func rms(
        _ values: [Double]
    ) -> Double {
        guard !values.isEmpty,
              values.allSatisfy(\.isFinite) else {
            return .infinity
        }
        return sqrt(
            values.reduce(0.0) {
                $0 + $1 * $1
            } / Double(values.count)
        )
    }

    private func median(
        _ values: [Double]
    ) -> Double {
        guard !values.isEmpty else {
            return 0
        }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (
                sorted[middle - 1]
                    + sorted[middle]
            ) / 2
        }
        return sorted[middle]
    }

    private func format(
        _ value: Double
    ) -> String {
        value.isFinite
            ? String(format: "%.2f", value)
            : "∞"
    }
}
