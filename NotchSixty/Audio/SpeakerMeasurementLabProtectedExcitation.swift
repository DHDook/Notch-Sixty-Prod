import Foundation

struct SpeakerMeasurementLabProtectedExcitationOptions:
    Equatable, Sendable {
    /// Direct-driver lab excitation is intentionally more conservative than
    /// ordinary whole-speaker Lab sweeps.
    var maximumInputPeakDBFS: Double = -24
    /// Flush configured driver delay and crossover IIR ring-out into the
    /// pre-rendered excitation rather than truncating the protected path.
    var flushSeconds: Double = 0.25

    func validate() -> Bool {
        maximumInputPeakDBFS.isFinite
            && (-42.0 ... -18.0).contains(maximumInputPeakDBFS)
            && flushSeconds.isFinite
            && (0.05...0.50).contains(flushSeconds)
    }
}


/// Decode-only record of the bus-based protected capture, kept so sessions recorded before E8 A2a/A2c still open.
/// Nothing acts on it: the Lab neither plans nor analyses a `.protectedDriverBus` capture any more.
struct SpeakerMeasurementLabProtectedDriverCaptureProvenance:
    Codable, Equatable, Sendable {
    var targetBus: SpeakerOutputBus
    var physicalDestination: PhysicalOutputEndpoint
    var routingConfiguration: MultiOutputRoutingConfiguration
    var bassManagementConfiguration: BassManagementConfiguration
    var targetDriverConfiguration:
        SpeakerDriverBusProcessingConfiguration
    var inputPeakDBFS: Double
    var renderedPeakDBFS: Double
    var sourceFrameCount: Int
    var renderedFrameCount: Int

    var crossoverPreserved: Bool { true }
    var limiterPreserved: Bool {
        targetDriverConfiguration.enabled
            && targetDriverConfiguration.limiterEnabled
    }
}

// MARK: - Way pairing

/// Which two ways meet at a crossover. The corner comes from the ways' own filter specs: the lower way's low-pass
/// corner, matched to the upper way's effective high-pass corner (a migrated tri-amp high way carries its upper
/// high-pass as an EQ section, which `effectiveHighPassHz` includes).
enum ProtectedWayPairing {
    /// Corners closer than this fraction count as the same crossover.
    static let cornerTolerance = 0.01

    static func crossoverHz(
        _ a: SpeakerMeasurementLabRoutedWayCaptureProvenance,
        _ b: SpeakerMeasurementLabRoutedWayCaptureProvenance
    ) -> Double? {
        guard let speaker = a.speakerID, speaker == b.speakerID,
              a.way.id != b.way.id else { return nil }
        return crossoverHz(a.way, b.way) ?? crossoverHz(b.way, a.way)
    }

    /// `lower` hands over to `upper`.
    static func crossoverHz(_ lower: RoutedWay, _ upper: RoutedWay) -> Double? {
        guard let corner = lower.lowPass?.cornerHz, corner.isFinite, corner > 0,
              let upperCorner = upper.effectiveHighPassHz else { return nil }
        return abs(corner - upperCorner) / corner <= cornerTolerance ? corner : nil
    }
}


// MARK: - PR111 Slice 1: protected, recommendation-only per-driver PEQ

/// Reviewable frequency-domain hypothesis. It does NOT create an EQBand,
/// change a Playback System or authorize any crossover/limiter modification.
/// Negative dB only, at most three isolated, broad protected-passband cuts.
struct ProtectedDriverPEQCut: Equatable, Sendable {
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
    var observedBroadPeakDB: Double
}

/// All provenance remains tied to one exact Lab protocol and one already
/// configured protected driver. Future guarded Apply must recheck *current*
/// routing/crossover/limiter state and independently measure the acoustic sum.
struct ProtectedDriverPEQRecommendation: Equatable, Sendable {
    var sessionID: UUID
    var protocolID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var wayID: UUID
    /// The way exactly as it was rendered for the capture (its filters supply the guard corners).
    var way: RoutedWay
    var sampleRate: Double
    var repeatedCaptureIDs: [UUID]
    var passbandLowHz: Double
    var passbandHighHz: Double
    var cuts: [ProtectedDriverPEQCut]
    var evidenceSummary: String

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canChangeDelayOrPolarity: Bool { false }
    var canAlterCrossoverOrLimiter: Bool { false }
    var requiresNewMeasuredVerification: Bool { true }
}

enum ProtectedDriverPEQRecommendationError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case unsupportedDriverWay
    case inadequateRepeatedEvidence
    case incompatibleResponseGrid
    case noUsableCrossoverPassband

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Protected driver measurements must pass session integrity checks."
        case .unsupportedDriverWay:
            return "Per-driver optimization requires one routed driver (way) with its filters and limiter."
        case .inadequateRepeatedEvidence:
            return "At least three repeat-qualified, unclipped protected-driver captures are required."
        case .incompatibleResponseGrid:
            return "The protected driver sweeps need an identical, finite frequency-response grid."
        case .noUsableCrossoverPassband:
            return "No reliable frequency range remains away from mandatory crossover boundaries."
        }
    }
}

/// Deliberately makes no attempt to flatten overall slope, fill nulls, align
/// acoustic centers, recommend polarity, change delay or optimize crossover.
/// A conservative repeat-stable peak *cut* is safer than applying modeled
/// boosts to an individual exposed driver without hardware verification.
struct ProtectedDriverPEQRecommendationAnalyzer: Sendable {
    static let minimumRepeats = 3
    static let minimumSNRDB = 35.0
    static let maximumRepeatSpreadDB = 0.85
    static let minimumPeakDeviationDB = 2.0
    static let maximumCutDB = 2.5
    static let maximumSuggestedBands = 3
    static let maximumBandQ = 1.4

    func recommend(
        session: SpeakerMeasurementLabSession,
        protocolID: UUID
    ) throws -> ProtectedDriverPEQRecommendation {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverPEQRecommendationError.invalidSession }

        guard let protocolItem = session.protocols.first(
            where: { $0.id == protocolID }
        ),
        protocolItem.request.mode == .protectedDriverNearField,
        let wayID = protocolItem.protectedRoutedWayID else {
            throw ProtectedDriverPEQRecommendationError.unsupportedDriverWay
        }

        let captures = session.captures.filter {
            $0.protocolID == protocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard captures.count >= Self.minimumRepeats,
              captures.count == protocolItem.request.repeatCount,
              captures.map(\.repeatIndex) == Array(0..<captures.count),
              let provenance = captures.first?.routedWayProvenance,
              provenance.validates(wayID: wayID),
              captures.allSatisfy({
                  $0.routedWayProvenance == provenance
                      && $0.quality.sweepComplete
                      && !$0.quality.clipped
                      && $0.quality.estimatedSNRDB.map({
                          $0.isFinite && $0 >= Self.minimumSNRDB
                      }) == true
              }) else {
            throw ProtectedDriverPEQRecommendationError
                .inadequateRepeatedEvidence
        }
        let reference = captures[0].transferFunction
        let grid = reference.frequenciesHz
        guard grid.count >= 48,
              grid.count == reference.magnitudeDB.count,
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              captures.allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                  && $0.transferFunction.magnitudeDB.count == grid.count
                  && $0.transferFunction.magnitudeDB.allSatisfy(\.isFinite)
              }) else {
            throw ProtectedDriverPEQRecommendationError
                .incompatibleResponseGrid
        }
        // The guard corners come from the way's own filter specs: nothing here reads a bus or a crossover mode.
        guard let guarded = provenance.way.protectedPassband(
            sampleRate: session.sampleRate
        ) else {
            throw ProtectedDriverPEQRecommendationError
                .noUsableCrossoverPassband
        }
        var low = guarded.lowerBound
        var high = guarded.upperBound
        let measuredLow = captures.compactMap {
            $0.quality.usableLowHz
        }.max() ?? .infinity
        let measuredHigh = captures.compactMap {
            $0.quality.usableHighHz
        }.min() ?? 0
        low = max(low, measuredLow)
        high = min(high, measuredHigh)
        guard low.isFinite, high.isFinite,
              high > low * 1.7 else {
            throw ProtectedDriverPEQRecommendationError
                .noUsableCrossoverPassband
        }
        let indices = grid.indices.filter {
            grid[$0] >= low && grid[$0] <= high
        }
        guard indices.count >= 24 else {
            throw ProtectedDriverPEQRecommendationError
                .noUsableCrossoverPassband
        }
        let means = grid.indices.map { i in
            captures.reduce(0.0) {
                $0 + $1.transferFunction.magnitudeDB[i]
            } / Double(captures.count)
        }
        let stable = indices.filter { i in
            let readings = captures.map {
                $0.transferFunction.magnitudeDB[i]
            }
            return (readings.max()! - readings.min()!)
                <= Self.maximumRepeatSpreadDB
        }
        guard stable.count >= 24,
              Double(stable.count) / Double(indices.count) >= 0.90 else {
            throw ProtectedDriverPEQRecommendationError
                .inadequateRepeatedEvidence
        }

        // Only detect local, repeat-stable bumps against surrounding
        // frequencies; never correct broadband tilt or narrow noise bins.
        var possible: [(frequency: Double, deviation: Double)] = []
        for i in stable {
            let center = grid[i]
            let neighbors = stable.filter { j in
                let distance = abs(log2(grid[j] / center))
                return distance >= 0.22 && distance <= 0.80
            }
            guard neighbors.count >= 12,
                  stable.contains(i - 1), stable.contains(i + 1) else {
                continue
            }
            let surround = neighbors.map { means[$0] }
                .reduce(0, +) / Double(neighbors.count)
            let bump = means[i] - surround
            guard bump >= Self.minimumPeakDeviationDB,
                  means[i] >= means[i - 1],
                  means[i] >= means[i + 1] else {
                continue
            }
            possible.append((frequency: center, deviation: bump))
        }
        possible.sort {
            if $0.deviation != $1.deviation {
                return $0.deviation > $1.deviation
            }
            return $0.frequency < $1.frequency
        }
        var cuts: [ProtectedDriverPEQCut] = []
        for candidate in possible {
            guard cuts.count < Self.maximumSuggestedBands else { break }
            let separated = cuts.allSatisfy {
                abs(log2($0.frequencyHz / candidate.frequency)) >= 0.55
            }
            guard separated else { continue }
            cuts.append(
                ProtectedDriverPEQCut(
                    frequencyHz: candidate.frequency,
                    gainDB: -min(Self.maximumCutDB,
                                 candidate.deviation * 0.55),
                    q: Self.maximumBandQ,
                    observedBroadPeakDB: candidate.deviation
                )
            )
        }
        return ProtectedDriverPEQRecommendation(
            sessionID: session.id,
            protocolID: protocolID,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            wayID: wayID,
            way: provenance.way,
            sampleRate: session.sampleRate,
            repeatedCaptureIDs: captures.map(\.id),
            passbandLowHz: low,
            passbandHighHz: high,
            cuts: cuts,
            evidenceSummary:
                "Protected \(provenance.way.name) near-field repeated sweeps; " +
                "0–3 cut-only, bounded peak hypotheses in the guarded passband. " +
                "No active driver EQ, delay, polarity, limiter or crossover change."
        )
    }
}


// MARK: - PR111 Slice 3: shared-reference driver timing hypotheses

enum ProtectedDriverTimingPolarityHypothesis:
    String, Equatable, Sendable {
    case retainCurrent
    case invertComparedDriver
    case inconclusive
}

/// Recommendation-only evidence for ONE adjacent protected driver pair.
/// The measured captures already include the installed crossover, current
/// per-driver delay and polarity. Any suggested delay is therefore an
/// *additional* bounded adjustment to the earlier driver, never an absolute
/// acoustic-center value or a command to mutate the DSP.
struct ProtectedDriverTimingRecommendation: Equatable, Sendable {
    var sessionID: UUID
    var firstProtocolID: UUID
    var secondProtocolID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var firstWayID: UUID
    var secondWayID: UUID
    var crossoverFrequencyHz: Double
    /// second minus first after subtracting each simultaneous electrical
    /// reference arrival. Positive means the second acoustic path is later.
    var relativeArrivalMilliseconds: Double
    var referenceArrivalSpreadMilliseconds: Double
    var referenceMagnitudeRepeatabilityRMSDB: Double
    var referencePhaseConsistency: Double
    var wrappedRelativePhaseAtCrossoverRadians: Double
    var delayWayID: UUID?
    var additionalDelayMilliseconds: Double?
    var polarityHypothesis: ProtectedDriverTimingPolarityHypothesis
    var evidenceConfidence: Double
    var warnings: [String]

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canChangeCrossoverOrLimiter: Bool { false }
    var requiresCombinedDriverVerification: Bool { true }
}

enum ProtectedDriverTimingRecommendationError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case invalidPair
    case protectedPathMismatch
    case sharedReferenceRequired
    case referencePathUnstable
    case inadequateRepeatedEvidence
    case incompatibleFrequencyGrid
    case crossoverBandUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Protected driver timing requires a structurally valid Measurement Lab session."
        case .invalidPair:
            return "Select two adjacent drivers (ways) of the same speaker, one crossing over into the other."
        case .protectedPathMismatch:
            return "Each driver's captures must carry one unchanged protected render of that way."
        case .sharedReferenceRequired:
            return "Every repeat requires a qualified simultaneous electrical reference on the same ADC timeline."
        case .referencePathUnstable:
            return "The electrical reference changed too much across the driver sweeps to authenticate cross-driver timing."
        case .inadequateRepeatedEvidence:
            return "Each driver needs at least three complete, unclipped, stable protected sweeps."
        case .incompatibleFrequencyGrid:
            return "Both protected drivers and their reference captures need one identical finite frequency grid."
        case .crossoverBandUnavailable:
            return "The pair lacks sufficient qualified measured evidence around its protected crossover."
        }
    }
}

struct ProtectedDriverTimingRecommendationAnalyzer: Sendable {
    static let minimumRepeats = 3
    static let minimumSNRDB = 35.0
    static let maximumReferenceArrivalSpreadMilliseconds = 0.25
    static let maximumReferenceMagnitudeRepeatabilityRMSDB = 0.50
    static let minimumReferencePhaseConsistency = 0.98
    static let maximumAdditionalDelayMilliseconds = 2.0
    static let minimumMeaningfulDelayMilliseconds = 0.05
    static let polarityDecisionMarginRadians = Double.pi / 4

    func recommend(
        session: SpeakerMeasurementLabSession,
        firstProtocolID: UUID,
        secondProtocolID: UUID
    ) throws -> ProtectedDriverTimingRecommendation {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverTimingRecommendationError.invalidSession }
        guard session.sharedClockReferenceConfiguration != nil,
              let firstProtocol = session.protocols.first(
                where: { $0.id == firstProtocolID }
              ),
              let secondProtocol = session.protocols.first(
                where: { $0.id == secondProtocolID }
              ),
              firstProtocol.request.mode == .protectedDriverNearField,
              secondProtocol.request.mode == .protectedDriverNearField,
              let firstWayID = firstProtocol.protectedRoutedWayID,
              let secondWayID = secondProtocol.protectedRoutedWayID,
              firstWayID != secondWayID else {
            throw ProtectedDriverTimingRecommendationError.invalidPair
        }
        let first = session.captures.filter {
            $0.protocolID == firstProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        let second = session.captures.filter {
            $0.protocolID == secondProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard first.count >= Self.minimumRepeats,
              second.count >= Self.minimumRepeats,
              first.count == firstProtocol.request.repeatCount,
              second.count == secondProtocol.request.repeatCount,
              first.map(\.repeatIndex) == Array(0..<first.count),
              second.map(\.repeatIndex) == Array(0..<second.count) else {
            throw ProtectedDriverTimingRecommendationError
                .inadequateRepeatedEvidence
        }
        guard let firstProvenance = first.first?.routedWayProvenance,
              let secondProvenance = second.first?.routedWayProvenance,
              firstProvenance.validates(wayID: firstWayID),
              secondProvenance.validates(wayID: secondWayID),
              first.allSatisfy({
                  $0.routedWayProvenance == firstProvenance
              }),
              second.allSatisfy({
                  $0.routedWayProvenance == secondProvenance
              }) else {
            throw ProtectedDriverTimingRecommendationError
                .protectedPathMismatch
        }
        guard let crossover = ProtectedWayPairing.crossoverHz(
            firstProvenance, secondProvenance
        ), crossover.isFinite, crossover > 0 else {
            throw ProtectedDriverTimingRecommendationError.invalidPair
        }

        let captures = first + second
        guard captures.allSatisfy({
            $0.quality.sweepComplete
                && !$0.quality.clipped
                && $0.quality.estimatedSNRDB.map({
                    $0.isFinite && $0 >= Self.minimumSNRDB
                }) == true
                && $0.quality.directArrivalSeconds?.isFinite == true
                && $0.sharedClockReference?.sharedTimeOriginQualified == true
        }) else {
            throw ProtectedDriverTimingRecommendationError
                .inadequateRepeatedEvidence
        }
        guard let grid = captures.first?.transferFunction.frequenciesHz,
              grid.count >= 48,
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              captures.allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                    && $0.transferFunction.magnitudeDB.count == grid.count
                    && $0.transferFunction.phaseRadians?.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.frequenciesHz == grid
                    && $0.sharedClockReference?
                        .transferFunction.magnitudeDB.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.phaseRadians?.count == grid.count
              }) else {
            throw ProtectedDriverTimingRecommendationError
                .incompatibleFrequencyGrid
        }

        let lower = crossover / 1.35
        let upper = crossover * 1.35
        let indices = grid.indices.filter {
            grid[$0] >= lower && grid[$0] <= upper
        }
        guard indices.count >= 8,
              captures.allSatisfy({
                  ($0.quality.usableLowHz ?? .infinity) <= lower
                    && ($0.quality.usableHighHz ?? 0) >= upper
              }) else {
            throw ProtectedDriverTimingRecommendationError
                .crossoverBandUnavailable
        }

        let references = captures.compactMap(\.sharedClockReference)
        guard references.count == captures.count else {
            throw ProtectedDriverTimingRecommendationError
                .sharedReferenceRequired
        }
        let referenceArrivals = references.map(\.directArrivalSeconds)
        let referenceArrivalSpread = (
            (referenceArrivals.max() ?? .infinity)
                - (referenceArrivals.min() ?? -.infinity)
        ) * 1_000
        let referenceMagnitudeRMS = rmsDeviationFromMean(
            references.map { reference in
                indices.map {
                    reference.transferFunction.magnitudeDB[$0]
                }
            }
        )
        let referencePhaseConsistency = circularConsistency(
            references.map { reference in
                indices.map {
                    reference.transferFunction.phaseRadians![$0]
                }
            }
        )
        guard referenceArrivalSpread.isFinite,
              referenceArrivalSpread
                <= Self.maximumReferenceArrivalSpreadMilliseconds,
              referenceMagnitudeRMS.isFinite,
              referenceMagnitudeRMS
                <= Self.maximumReferenceMagnitudeRepeatabilityRMSDB,
              referencePhaseConsistency.isFinite,
              referencePhaseConsistency
                >= Self.minimumReferencePhaseConsistency else {
            throw ProtectedDriverTimingRecommendationError
                .referencePathUnstable
        }

        let firstArrival = try correctedArrival(first)
        let secondArrival = try correctedArrival(second)
        let relativeArrival = (secondArrival - firstArrival) * 1_000
        let firstPhase = try correctedPhase(
            first, indices: indices, grid: grid
        )
        let secondPhase = try correctedPhase(
            second, indices: indices, grid: grid
        )
        // correctedPhase() has already removed each acoustic arrival
        // against its simultaneous electrical reference. Compare only the
        // remaining residual phase; do not subtract the timing slope twice.
        let relativePhases = zip(secondPhase, firstPhase).map {
            wrap($0.0 - $0.1)
        }
        let relativePhase = circularMean(relativePhases)

        let delayMagnitude = abs(relativeArrival)
        let delayWayID: UUID?
        let additionalDelay: Double?
        if delayMagnitude >= Self.minimumMeaningfulDelayMilliseconds,
           delayMagnitude <= Self.maximumAdditionalDelayMilliseconds {
            // Delay whichever acoustic path currently arrives first.
            delayWayID = relativeArrival > 0 ? firstWayID : secondWayID
            additionalDelay = delayMagnitude
        } else {
            delayWayID = nil
            additionalDelay = nil
        }

        let currentDistance = abs(wrap(relativePhase))
        let invertedDistance = abs(wrap(relativePhase + .pi))
        let polarity: ProtectedDriverTimingPolarityHypothesis
        if invertedDistance + Self.polarityDecisionMarginRadians
            < currentDistance {
            polarity = .invertComparedDriver
        } else if currentDistance + Self.polarityDecisionMarginRadians
                    < invertedDistance {
            polarity = .retainCurrent
        } else {
            polarity = .inconclusive
        }

        let captureConfidence = captures.map {
            min(
                1.0,
                max(
                    0.0,
                    (($0.quality.estimatedSNRDB ?? Self.minimumSNRDB)
                        - Self.minimumSNRDB) / 30.0
                )
            )
        }.min() ?? 0
        return ProtectedDriverTimingRecommendation(
            sessionID: session.id,
            firstProtocolID: firstProtocolID,
            secondProtocolID: secondProtocolID,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            firstWayID: firstWayID,
            secondWayID: secondWayID,
            crossoverFrequencyHz: crossover,
            relativeArrivalMilliseconds: relativeArrival,
            referenceArrivalSpreadMilliseconds: referenceArrivalSpread,
            referenceMagnitudeRepeatabilityRMSDB: referenceMagnitudeRMS,
            referencePhaseConsistency: referencePhaseConsistency,
            wrappedRelativePhaseAtCrossoverRadians: relativePhase,
            delayWayID: delayWayID,
            additionalDelayMilliseconds: additionalDelay,
            polarityHypothesis: polarity,
            evidenceConfidence: min(
                captureConfidence, referencePhaseConsistency
            ),
            warnings: [
                "Reference-aligned driver timing is valid only for this exact protected routing, crossover, microphone/reference input, sample rate and session.",
                "Delay is a bounded additional hypothesis for the currently earlier driver; it is not an absolute acoustic-center distance.",
                "Polarity is a phase-comparison hypothesis only. Combined-driver crossover summation must be measured before any Apply.",
                "No driver delay, polarity, crossover, limiter, PEQ or live route is changed by this analysis."
            ]
        )
    }

    private func correctedArrival(
        _ captures: [SpeakerMeasurementLabCapture]
    ) throws -> Double {
        let values = try captures.map { capture -> Double in
            guard let acoustic = capture.quality.directArrivalSeconds,
                  let reference = capture.sharedClockReference?
                    .directArrivalSeconds else {
                throw ProtectedDriverTimingRecommendationError
                    .sharedReferenceRequired
            }
            return acoustic - reference
        }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite else {
            throw ProtectedDriverTimingRecommendationError
                .sharedReferenceRequired
        }
        return mean
    }

    private func correctedPhase(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int],
        grid: [Double]
    ) throws -> [Double] {
        var real = Array(repeating: 0.0, count: indices.count)
        var imag = Array(repeating: 0.0, count: indices.count)
        for capture in captures {
            guard let acousticPhase =
                    capture.transferFunction.phaseRadians,
                  let acousticArrival =
                    capture.quality.directArrivalSeconds,
                  let reference = capture.sharedClockReference,
                  let referencePhase =
                    reference.transferFunction.phaseRadians else {
                throw ProtectedDriverTimingRecommendationError
                    .sharedReferenceRequired
            }
            for (out, index) in indices.enumerated() {
                let frequency = grid[index]
                let acousticAbsolute = acousticPhase[index]
                    - 2 * .pi * frequency * acousticArrival
                let referenceAbsolute = referencePhase[index]
                    - 2 * .pi * frequency
                        * reference.directArrivalSeconds
                let corrected = acousticAbsolute - referenceAbsolute
                real[out] += cos(corrected) / Double(captures.count)
                imag[out] += sin(corrected) / Double(captures.count)
            }
        }
        return zip(real, imag).map { atan2($0.1, $0.0) }
    }

    private func rmsDeviationFromMean(
        _ rows: [[Double]]
    ) -> Double {
        guard let count = rows.first?.count,
              count > 0,
              rows.allSatisfy({ $0.count == count }) else {
            return .infinity
        }
        var squared = 0.0
        var samples = 0
        for index in 0..<count {
            let values = rows.map { $0[index] }
            let mean = values.reduce(0, +) / Double(values.count)
            for value in values {
                squared += pow(value - mean, 2)
                samples += 1
            }
        }
        return samples > 0 ? sqrt(squared / Double(samples)) : .infinity
    }

    private func circularConsistency(
        _ rows: [[Double]]
    ) -> Double {
        let values = rows.flatMap { $0 }
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            return 0
        }
        let real = values.map(cos).reduce(0, +) / Double(values.count)
        let imag = values.map(sin).reduce(0, +) / Double(values.count)
        return hypot(real, imag)
    }

    private func circularMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let real = values.map(cos).reduce(0, +) / Double(values.count)
        let imag = values.map(sin).reduce(0, +) / Double(values.count)
        return atan2(imag, real)
    }

    private func wrap(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }
}


// MARK: - PR111 Slice 4: reference-aligned crossover-sum model

enum ProtectedDriverCrossoverSumHypothesis:
    String, Codable, Equatable, Sendable {
    case retainCurrent
    case addBoundedDelay
    case invertComparedDriver
    case addDelayAndInvertComparedDriver
}

/// Offline model of the two measured protected driver responses around one
/// crossover. This evaluates cancellation/coherence in the *captured* complex
/// responses. It is not a real combined-driver measurement and cannot verify
/// amplifier polarity, driver safety, radiation geometry or room response.
struct ProtectedDriverCrossoverSumModel: Equatable, Sendable {
    var sessionID: UUID
    var firstProtocolID: UUID
    var secondProtocolID: UUID
    var firstWayID: UUID
    var secondWayID: UUID
    var crossoverFrequencyHz: Double
    var frequencyPointCount: Int
    var currentMeanCoherenceDeficitDB: Double
    var candidateMeanCoherenceDeficitDB: Double
    var modeledDeficitReductionDB: Double
    var bestHypothesis: ProtectedDriverCrossoverSumHypothesis
    var modeledAdditionalDelayMilliseconds: Double?
    var modeledInvertsComparedDriver: Bool
    var evidenceConfidence: Double
    var warnings: [String]

    var measurementOnly: Bool { true }
    var modelOnly: Bool { true }
    var canDeploy: Bool { false }
    var combinedDriverCaptureVerified: Bool { false }
    var requiresPhysicalCombinedDriverCapture: Bool { true }
}

enum ProtectedDriverCrossoverSumModelError:
    Error, Equatable, LocalizedError {
    case timingEvidenceUnavailable
    case incompatibleComplexResponse
    case insufficientCrossoverEvidence

    var errorDescription: String? {
        switch self {
        case .timingEvidenceUnavailable:
            return "Reference-authenticated adjacent-driver timing evidence is required before modeling crossover summation."
        case .incompatibleComplexResponse:
            return "Both driver and electrical-reference sweeps need matching finite magnitude/phase grids."
        case .insufficientCrossoverEvidence:
            return "The protected pair lacks enough shared measured points around its crossover."
        }
    }
}

struct ProtectedDriverCrossoverSumModelAnalyzer: Sendable {
    static let minimumPointCount = 8
    static let minimumModeledImprovementDB = 0.25

    func analyze(
        session: SpeakerMeasurementLabSession,
        firstProtocolID: UUID,
        secondProtocolID: UUID
    ) throws -> ProtectedDriverCrossoverSumModel {
        let timing: ProtectedDriverTimingRecommendation
        do {
            timing = try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: firstProtocolID,
                    secondProtocolID: secondProtocolID
                )
        } catch {
            throw ProtectedDriverCrossoverSumModelError
                .timingEvidenceUnavailable
        }
        let first = session.captures.filter {
            $0.protocolID == firstProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        let second = session.captures.filter {
            $0.protocolID == secondProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard let grid = first.first?.transferFunction.frequenciesHz,
              !grid.isEmpty,
              (first + second).allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                    && $0.transferFunction.magnitudeDB.count == grid.count
                    && $0.transferFunction.phaseRadians?.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.frequenciesHz == grid
                    && $0.sharedClockReference?
                        .transferFunction.magnitudeDB.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.phaseRadians?.count == grid.count
              }) else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        let lower = timing.crossoverFrequencyHz / 1.35
        let upper = timing.crossoverFrequencyHz * 1.35
        let indices = grid.indices.filter {
            grid[$0] >= lower && grid[$0] <= upper
        }
        guard indices.count >= Self.minimumPointCount else {
            throw ProtectedDriverCrossoverSumModelError
                .insufficientCrossoverEvidence
        }

        let firstMean = try referenceAlignedMean(
            first, indices: indices
        )
        let secondMean = try referenceAlignedMean(
            second, indices: indices
        )
        guard firstMean.count == secondMean.count,
              firstMean.count == indices.count else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }

        let current = meanCoherenceDeficit(
            firstMean, secondMean
        )
        var candidates: [(
            ProtectedDriverCrossoverSumHypothesis,
            Double,
            Double?,
            Bool
        )] = [
            (.retainCurrent, current, nil, false)
        ]

        if let delay = timing.additionalDelayMilliseconds,
           let delayWayID = timing.delayWayID {
            let delayed = modeledPair(
                firstMean,
                secondMean,
                indices: indices,
                grid: grid,
                delayMilliseconds: delay,
                delayWayID: delayWayID,
                firstWayID: timing.firstWayID,
                invertSecond: false
            )
            candidates.append((
                .addBoundedDelay,
                meanCoherenceDeficit(delayed.0, delayed.1),
                delay,
                false
            ))
        }

        if timing.polarityHypothesis == .invertComparedDriver {
            let inverted = modeledPair(
                firstMean,
                secondMean,
                indices: indices,
                grid: grid,
                delayMilliseconds: nil,
                delayWayID: nil,
                firstWayID: timing.firstWayID,
                invertSecond: true
            )
            candidates.append((
                .invertComparedDriver,
                meanCoherenceDeficit(inverted.0, inverted.1),
                nil,
                true
            ))
            if let delay = timing.additionalDelayMilliseconds,
               let delayWayID = timing.delayWayID {
                let combined = modeledPair(
                    firstMean,
                    secondMean,
                    indices: indices,
                    grid: grid,
                    delayMilliseconds: delay,
                    delayWayID: delayWayID,
                    firstWayID: timing.firstWayID,
                    invertSecond: true
                )
                candidates.append((
                    .addDelayAndInvertComparedDriver,
                    meanCoherenceDeficit(combined.0, combined.1),
                    delay,
                    true
                ))
            }
        }

        let lowest = candidates.min {
            if abs($0.1 - $1.1) > 1.0e-9 {
                return $0.1 < $1.1
            }
            return $0.0.rawValue < $1.0.rawValue
        }!
        let improvement = current - lowest.1
        let selected = improvement >= Self.minimumModeledImprovementDB
            ? lowest
            : candidates[0]

        return ProtectedDriverCrossoverSumModel(
            sessionID: session.id,
            firstProtocolID: firstProtocolID,
            secondProtocolID: secondProtocolID,
            firstWayID: timing.firstWayID,
            secondWayID: timing.secondWayID,
            crossoverFrequencyHz: timing.crossoverFrequencyHz,
            frequencyPointCount: indices.count,
            currentMeanCoherenceDeficitDB: current,
            candidateMeanCoherenceDeficitDB: selected.1,
            modeledDeficitReductionDB: current - selected.1,
            bestHypothesis: selected.0,
            modeledAdditionalDelayMilliseconds: selected.2,
            modeledInvertsComparedDriver: selected.3,
            evidenceConfidence: timing.evidenceConfidence,
            warnings: [
                "MODEL ONLY: complex protected-driver measurements are summed mathematically; the two drivers were not measured playing together.",
                "A lower coherence-deficit value means less modeled cancellation relative to the sum of the two measured magnitudes. It is not a target-curve, SPL or sound-quality score.",
                "Any candidate must be verified by a new safe combined-driver crossover capture before delay, polarity, PEQ, crossover or limiter state can change.",
                "Mandatory crossover and limiter state from the protected captures remain authoritative; this model cannot weaken either."
            ]
        )
    }

    private struct ComplexSample: Equatable {
        var real: Double
        var imag: Double

        var magnitude: Double { hypot(real, imag) }
    }

    private func referenceAlignedMean(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int]
    ) throws -> [ComplexSample] {
        guard !captures.isEmpty else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        var real = Array(repeating: 0.0, count: indices.count)
        var imag = Array(repeating: 0.0, count: indices.count)
        for capture in captures {
            guard let phase = capture.transferFunction.phaseRadians,
                  let reference = capture.sharedClockReference,
                  let referencePhase =
                    reference.transferFunction.phaseRadians else {
                throw ProtectedDriverCrossoverSumModelError
                    .incompatibleComplexResponse
            }
            for (out, index) in indices.enumerated() {
                let relativeDB =
                    capture.transferFunction.magnitudeDB[index]
                    - reference.transferFunction.magnitudeDB[index]
                let magnitude = pow(10.0, relativeDB / 20.0)
                let relativePhase = atan2(
                    sin(phase[index] - referencePhase[index]),
                    cos(phase[index] - referencePhase[index])
                )
                real[out] += magnitude * cos(relativePhase)
                    / Double(captures.count)
                imag[out] += magnitude * sin(relativePhase)
                    / Double(captures.count)
            }
        }
        let result = zip(real, imag).map {
            ComplexSample(real: $0.0, imag: $0.1)
        }
        guard result.allSatisfy({
            $0.real.isFinite && $0.imag.isFinite
                && $0.magnitude.isFinite
        }) else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        return result
    }

    private func modeledPair(
        _ first: [ComplexSample],
        _ second: [ComplexSample],
        indices: [Int],
        grid: [Double],
        delayMilliseconds: Double?,
        delayWayID: UUID?,
        firstWayID: UUID,
        invertSecond: Bool
    ) -> ([ComplexSample], [ComplexSample]) {
        var lhs = first
        var rhs = second
        if let delayMilliseconds, let delayWayID {
            let seconds = delayMilliseconds / 1_000
            for offset in lhs.indices {
                let frequency = grid[indices[offset]]
                let phase = 2 * Double.pi * frequency * seconds
                if delayWayID == firstWayID {
                    lhs[offset] = rotated(lhs[offset], phase)
                } else {
                    rhs[offset] = rotated(rhs[offset], phase)
                }
            }
        }
        if invertSecond {
            for offset in rhs.indices {
                rhs[offset].real *= -1
                rhs[offset].imag *= -1
            }
        }
        return (lhs, rhs)
    }

    private func rotated(
        _ sample: ComplexSample,
        _ radians: Double
    ) -> ComplexSample {
        ComplexSample(
            real: sample.real * cos(radians)
                - sample.imag * sin(radians),
            imag: sample.real * sin(radians)
                + sample.imag * cos(radians)
        )
    }

    private func meanCoherenceDeficit(
        _ first: [ComplexSample],
        _ second: [ComplexSample]
    ) -> Double {
        let values = zip(first, second).map { lhs, rhs -> Double in
            let ideal = max(lhs.magnitude + rhs.magnitude, 1.0e-12)
            let summed = max(
                hypot(lhs.real + rhs.real, lhs.imag + rhs.imag),
                1.0e-12
            )
            return max(0, 20 * log10(ideal / summed))
        }
        return values.reduce(0, +) / Double(values.count)
    }
}


// MARK: - PR111 Slice 5: hardware-blocked commissioning draft


// MARK: - Commissioning draft (routed ways)

struct ProtectedDriverCommissioningTimingReview:
    Codable, Equatable, Sendable {
    var firstWayID: UUID
    var secondWayID: UUID
    var crossoverFrequencyHz: Double
    var bestHypothesis: ProtectedDriverCrossoverSumHypothesis
    var modeledDeficitReductionDB: Double
    var modeledAdditionalDelayMilliseconds: Double?
    var modeledInvertsComparedDriver: Bool
    var combinedDriverCaptureVerified: Bool
}

/// A reviewable preview of cut-only driver EQ on the measured ways. The rollback state is the exact Playback System at
/// the time; the legacy bus fields in it are never touched. There is still no Apply.
struct ProtectedDriverCommissioningDraft:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 2

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var playbackSystemID: UUID
    var sessionID: UUID
    var routingSignature: String
    var sampleRate: Double
    var rollbackPlaybackSystemState: PlaybackSystemState
    /// The routing with the review cuts appended to the affected ways' EQ.
    var previewRouting: SpeakerRoutingConfiguration
    var affectedWayIDs: [UUID]
    var sourceProtocolIDs: [UUID]
    var sourceCaptureIDs: [UUID]
    var timingReviews: [ProtectedDriverCommissioningTimingReview]
    var evidenceSummary: String

    var approvalRequired: Bool { true }
    var physicalCombinedDriverVerificationComplete: Bool {
        !timingReviews.isEmpty
            && timingReviews.allSatisfy(\.combinedDriverCaptureVerified)
    }
    /// PR111 remote closeout intentionally has no Apply transaction. PR112
    /// must replace this hard false only after physical combined-driver
    /// verification and exposed-driver safety acceptance exist.
    var readyForApproval: Bool { false }
    var canApply: Bool { false }
    var canDeploy: Bool { false }
    var rollbackSnapshotAvailable: Bool { true }
    var stateDriftCheckRequired: Bool { true }
    var requiresPhysicalCombinedDriverCapture: Bool { true }

    /// Peaking is code 0 in a routing EQ section.
    static let peakingType = 0

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion,
              sampleRate.isFinite, sampleRate > 0,
              !routingSignature.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty,
              Set(sourceProtocolIDs).count == sourceProtocolIDs.count,
              Set(sourceCaptureIDs).count == sourceCaptureIDs.count,
              Set(affectedWayIDs).count == affectedWayIDs.count,
              timingReviews.allSatisfy({
                  !$0.combinedDriverCaptureVerified
                      && $0.crossoverFrequencyHz.isFinite
                      && $0.crossoverFrequencyHz > 0
                      && $0.modeledDeficitReductionDB.isFinite
              }),
              !canApply, !canDeploy, !readyForApproval,
              rollbackSnapshotAvailable,
              stateDriftCheckRequired,
              requiresPhysicalCombinedDriverCapture,
              let baseline = rollbackPlaybackSystemState.speakerRouting else {
            throw ProtectedDriverCommissioningError.invalidPreview
        }
        // Everything except the affected ways' EQ must equal the baseline.
        guard previewRouting.speakers.count == baseline.speakers.count else {
            throw ProtectedDriverCommissioningError.invalidPreview
        }
        var stripped = previewRouting
        var changed = Set<UUID>()
        for (si, speaker) in previewRouting.speakers.enumerated() {
            let base = baseline.speakers[si]
            guard speaker.ways.count == base.ways.count else {
                throw ProtectedDriverCommissioningError.invalidPreview
            }
            for (wi, way) in speaker.ways.enumerated() {
                let before = base.ways[wi]
                guard way.id == before.id,
                      way.eq.count >= before.eq.count,
                      way.eq.count <= Int(N60_PEQ_MAX_SECTIONS),
                      Array(way.eq.prefix(before.eq.count)) == before.eq
                else {
                    throw ProtectedDriverCommissioningError.invalidPreview
                }
                let added = Array(way.eq.dropFirst(before.eq.count))
                guard added.allSatisfy({
                    $0.type == Self.peakingType
                        && $0.frequencyHz.isFinite
                        && $0.frequencyHz > 0
                        && $0.gainDB.isFinite
                        && $0.gainDB < 0
                        && $0.gainDB >=
                            -ProtectedDriverPEQRecommendationAnalyzer
                                .maximumCutDB
                        && $0.q.isFinite
                        && $0.q > 0
                        && $0.q <=
                            ProtectedDriverPEQRecommendationAnalyzer
                                .maximumBandQ
                }) else {
                    throw ProtectedDriverCommissioningError.invalidPreview
                }
                if !added.isEmpty { changed.insert(way.id) }
                stripped.speakers[si].ways[wi].eq = before.eq
            }
        }
        guard stripped == baseline, changed == Set(affectedWayIDs) else {
            throw ProtectedDriverCommissioningError.invalidPreview
        }
        return self
    }
}

enum ProtectedDriverCommissioningError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case playbackSystemMismatch
    case outputProfileRequired
    case protectedStateDrift
    case noQualifiedProtectedDriverEvidence
    case insufficientEQCapacity
    case invalidPreview
    case currentStateDrift
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Per-driver commissioning requires a valid protected Measurement Lab session."
        case .playbackSystemMismatch:
            return "The Lab session does not belong to the selected Playback System."
        case .outputProfileRequired:
            return "An enabled Output Device Profile is required for per-driver commissioning review."
        case .protectedStateDrift:
            return "The routing matrix, a driver's filters, or its limiter changed after the protected measurements."
        case .noQualifiedProtectedDriverEvidence:
            return "No protected driver protocol produced repeat-qualified commissioning evidence."
        case .insufficientEQCapacity:
            return "The driver's EQ has no free sections for the bounded review cuts."
        case .invalidPreview:
            return "The generated per-driver preview does not satisfy the routing limits."
        case .currentStateDrift:
            return "The Playback System changed after commissioning review; regenerate the draft before any future Apply."
        case .unsupportedSchema:
            return "Saved per-driver commissioning draft uses an unsupported schema version."
        }
    }
}

/// Re-runs the analysis from the persisted Lab session instead of trusting
/// caller-supplied cut/timing values. The output is a reviewable configuration
/// snapshot only. It has no reference to the live engine or profile-controller
/// mutation APIs and cannot deploy anything.
struct ProtectedDriverCommissioningPlanner: Sendable {
    func draft(
        profile: PlaybackSystemProfile,
        session: SpeakerMeasurementLabSession,
        createdAt: Date = Date()
    ) throws -> ProtectedDriverCommissioningDraft {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverCommissioningError.invalidSession }

        guard profile.id == session.playbackSystemID else {
            throw ProtectedDriverCommissioningError
                .playbackSystemMismatch
        }
        guard let output = profile.state.outputDeviceProfile,
              output.enabled,
              output.multichannelCalibrationRoutingSignature
                == session.routingSignature else {
            throw ProtectedDriverCommissioningError
                .outputProfileRequired
        }
        guard let baseline = profile.state.speakerRouting,
              baseline.enabled else {
            throw ProtectedDriverCommissioningError
                .protectedStateDrift
        }

        let protectedProtocols = session.protocols.filter {
            $0.request.mode == .protectedDriverNearField
                && $0.protectedRoutedWayID != nil
        }
        guard !protectedProtocols.isEmpty else {
            throw ProtectedDriverCommissioningError
                .noQualifiedProtectedDriverEvidence
        }

        // Every measured way must still be the way that was measured.
        let currentWays = Dictionary(
            uniqueKeysWithValues: baseline.speakers.flatMap(\.ways).map {
                ($0.id, $0)
            }
        )
        for labProtocol in protectedProtocols {
            let captures = session.captures.filter {
                $0.protocolID == labProtocol.id
            }
            guard let wayID = labProtocol.protectedRoutedWayID,
                  !captures.isEmpty,
                  captures.allSatisfy({
                      guard let provenance = $0.routedWayProvenance else {
                          return false
                      }
                      return currentWays[wayID] == provenance.way
                  }) else {
                throw ProtectedDriverCommissioningError
                    .protectedStateDrift
            }
        }

        var preview = baseline
        var affected = Set<UUID>()
        var qualifiedProtocolIDs: [UUID] = []
        var qualifiedCaptureIDs: [UUID] = []

        for labProtocol in protectedProtocols {
            guard let wayID = labProtocol.protectedRoutedWayID else {
                continue
            }
            let recommendation: ProtectedDriverPEQRecommendation
            do {
                recommendation =
                    try ProtectedDriverPEQRecommendationAnalyzer()
                        .recommend(
                            session: session,
                            protocolID: labProtocol.id
                        )
            } catch {
                continue
            }
            qualifiedProtocolIDs.append(labProtocol.id)
            qualifiedCaptureIDs.append(
                contentsOf: recommendation.repeatedCaptureIDs
            )
            guard !recommendation.cuts.isEmpty else { continue }

            guard let location = preview.locateWay(wayID) else { continue }
            var way = preview.speakers[location.speaker]
                .ways[location.way]
            guard way.limiter != nil,
                  way.eq.count + recommendation.cuts.count
                    <= Int(N60_PEQ_MAX_SECTIONS) else {
                throw ProtectedDriverCommissioningError
                    .insufficientEQCapacity
            }
            for cut in recommendation.cuts {
                way.eq.append(
                    RoutingEQSection(
                        type: ProtectedDriverCommissioningDraft
                            .peakingType,
                        frequencyHz: cut.frequencyHz,
                        gainDB: cut.gainDB,
                        q: cut.q
                    )
                )
            }
            preview.speakers[location.speaker].ways[location.way] = way
            affected.insert(wayID)
        }
        guard !qualifiedProtocolIDs.isEmpty else {
            throw ProtectedDriverCommissioningError
                .noQualifiedProtectedDriverEvidence
        }

        let timingReviews = makeTimingReviews(
            session: session,
            routing: baseline,
            protectedProtocols: protectedProtocols
        )

        let draft = ProtectedDriverCommissioningDraft(
            createdAt: createdAt,
            playbackSystemID: profile.id,
            sessionID: session.id,
            routingSignature: session.routingSignature,
            sampleRate: session.sampleRate,
            rollbackPlaybackSystemState: profile.state,
            previewRouting: preview,
            affectedWayIDs: affected.sorted {
                $0.uuidString < $1.uuidString
            },
            sourceProtocolIDs: qualifiedProtocolIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            sourceCaptureIDs: qualifiedCaptureIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            timingReviews: timingReviews,
            evidenceSummary:
                "Remote commissioning draft only: cut-only PEQ preview plus model-only adjacent-driver timing reviews. " +
                "Exact Playback System rollback snapshot retained. No Apply until fresh physical combined-driver verification and PR112 hardware acceptance."
        )
        return try draft.validated()
    }

    func validateCurrentState(
        _ profile: PlaybackSystemProfile,
        against draft: ProtectedDriverCommissioningDraft
    ) throws {
        guard draft.schemaVersion
                == ProtectedDriverCommissioningDraft
                    .currentSchemaVersion else {
            throw ProtectedDriverCommissioningError
                .unsupportedSchema
        }
        guard profile.id == draft.playbackSystemID else {
            throw ProtectedDriverCommissioningError
                .playbackSystemMismatch
        }
        guard profile.state
                == draft.rollbackPlaybackSystemState else {
            throw ProtectedDriverCommissioningError.currentStateDrift
        }
    }

    private func makeTimingReviews(
        session: SpeakerMeasurementLabSession,
        routing: SpeakerRoutingConfiguration,
        protectedProtocols: [SpeakerMeasurementLabProtocol]
    ) -> [ProtectedDriverCommissioningTimingReview] {
        var reviews: [ProtectedDriverCommissioningTimingReview] = []
        let grouped = Dictionary(
            grouping: protectedProtocols
        ) { $0.protectedRoutedWayID! }
        for speaker in routing.speakers {
            for pair in speaker.adjacentWayPairs {
                guard let firstGroup = grouped[pair.lower.id],
                      let secondGroup = grouped[pair.upper.id],
                      firstGroup.count == 1,
                      secondGroup.count == 1,
                      let first = firstGroup.first,
                      let second = secondGroup.first,
                      let model = try? ProtectedDriverCrossoverSumModelAnalyzer()
                        .analyze(
                            session: session,
                            firstProtocolID: first.id,
                            secondProtocolID: second.id
                        ) else {
                    continue
                }
                reviews.append(
                    ProtectedDriverCommissioningTimingReview(
                        firstWayID: model.firstWayID,
                        secondWayID: model.secondWayID,
                        crossoverFrequencyHz:
                            model.crossoverFrequencyHz,
                        bestHypothesis: model.bestHypothesis,
                        modeledDeficitReductionDB:
                            model.modeledDeficitReductionDB,
                        modeledAdditionalDelayMilliseconds:
                            model.modeledAdditionalDelayMilliseconds,
                        modeledInvertsComparedDriver:
                            model.modeledInvertsComparedDriver,
                        combinedDriverCaptureVerified:
                            model.combinedDriverCaptureVerified
                    )
                )
            }
        }
        return reviews.sorted {
            if $0.firstWayID != $1.firstWayID {
                return $0.firstWayID.uuidString < $1.firstWayID.uuidString
            }
            return $0.secondWayID.uuidString < $1.secondWayID.uuidString
        }
    }
}

extension SpeakerRoutingConfiguration {
    func locateWay(_ id: UUID) -> (speaker: Int, way: Int)? {
        for (si, speaker) in speakers.enumerated() {
            if let wi = speaker.ways.firstIndex(where: { $0.id == id }) {
                return (si, wi)
            }
        }
        return nil
    }
}

// MARK: - Drafts saved before the routing matrix

/// Read-only record of a commissioning draft written against the legacy buses (schema 1). It is kept on disk and shown,
/// never applied. It maps to ways through its own rollback state: a legacy route's id is the id of the way the
/// migration created for it. A draft whose buses cannot all be mapped is "not applicable".
struct ProtectedDriverLegacyCommissioningDraft: Codable, Equatable, Sendable {
    var schemaVersion: Int
    var id: UUID
    var createdAt: Date
    var playbackSystemID: UUID
    var sessionID: UUID
    var rollbackPlaybackSystemState: PlaybackSystemState
    var affectedBuses: [SpeakerOutputBus]

    /// The ways the draft's buses became, or nil when any bus has no single enabled route to map through.
    var mappedWayIDs: [UUID]? {
        guard let routes = rollbackPlaybackSystemState.outputRouting?
            .enabledRoutes else { return nil }
        var ids: [UUID] = []
        for bus in affectedBuses {
            let matches = routes.filter { $0.bus == bus }
            guard matches.count == 1 else { return nil }
            ids.append(matches[0].id)
        }
        return ids
    }

    var isApplicable: Bool { mappedWayIDs != nil }

    var statusText: String {
        isApplicable
            ? "Saved before the routing matrix; its drivers map to the current ways. Read-only: regenerate it to review on ways."
            : "Not applicable: this draft was saved against the legacy buses and they cannot be mapped to ways. Kept for the record."
    }
}

enum ProtectedDriverCommissioningDraftEntry: Equatable, Sendable {
    case current(ProtectedDriverCommissioningDraft)
    case legacy(ProtectedDriverLegacyCommissioningDraft)
}

struct ProtectedDriverCommissioningDraftStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? SpeakerMeasurementLabSessionStore()
                .rootDirectory
                .appendingPathComponent(
                    "PR111 Commissioning Drafts",
                    isDirectory: true
                )
    }

    func url(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ draft: ProtectedDriverCommissioningDraft) throws {
        _ = try draft.validated()
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(draft).write(
            to: url(for: draft.sessionID),
            options: .atomic
        )
    }

    /// The current-schema draft for a session; nil when there is none or the saved one is a legacy draft.
    func load(_ sessionID: UUID)
        throws -> ProtectedDriverCommissioningDraft? {
        guard case .current(let draft)? = try entry(sessionID) else {
            return nil
        }
        return draft
    }

    /// Whatever is saved for the session, current or legacy.
    func entry(_ sessionID: UUID) throws
        -> ProtectedDriverCommissioningDraftEntry? {
        let path = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let version = try decoder.decode(SchemaProbe.self, from: data)
            .schemaVersion
        if version == 1 {
            let legacy = try decoder.decode(
                ProtectedDriverLegacyCommissioningDraft.self, from: data
            )
            guard legacy.sessionID == sessionID else {
                throw ProtectedDriverCommissioningError.unsupportedSchema
            }
            return .legacy(legacy)
        }
        let draft = try decoder.decode(
            ProtectedDriverCommissioningDraft.self, from: data
        )
        guard draft.sessionID == sessionID else {
            throw ProtectedDriverCommissioningError.unsupportedSchema
        }
        return .current(try draft.validated())
    }

    private struct SchemaProbe: Decodable { var schemaVersion: Int }
}
