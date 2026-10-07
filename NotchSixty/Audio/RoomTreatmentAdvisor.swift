import Foundation

enum RoomTreatmentAdvisorRemedy:
    String, CaseIterable, Equatable, Sendable, Identifiable
{
    case measureMore
    case placement
    case passiveTreatment
    case dspCorrection
    case activeRoomTreatment
    case activeQuietZone
    case noAction

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .measureMore: return "Measure More"
        case .placement: return "Placement"
        case .passiveTreatment: return "Passive Treatment"
        case .dspCorrection: return "DSP Correction"
        case .activeRoomTreatment: return "Active Room Treatment"
        case .activeQuietZone: return "Active Quiet Zone"
        case .noAction: return "No Action"
        }
    }
}

enum RoomTreatmentAdvisorSeverity:
    Int, Equatable, Sendable
{
    case information = 0
    case opportunity = 1
    case important = 2
}

enum RoomTreatmentAdvisorFindingKind:
    String, Equatable, Sendable
{
    case measurementReadiness
    case measurementQuality
    case spatialBassVariation
    case deepBassCancellation
    case earlyReflection
    case noInitialFlag
}

struct RoomTreatmentAdvisorFinding:
    Identifiable, Equatable, Sendable
{
    var id: String
    var kind: RoomTreatmentAdvisorFindingKind
    var severity: RoomTreatmentAdvisorSeverity
    var title: String
    var measuredEvidence: String
    var interpretation: String
    var recommendation: String
    var primaryRemedy: RoomTreatmentAdvisorRemedy
    var secondaryRemedies: [RoomTreatmentAdvisorRemedy] = []
    var confidence: Double
    var frequencyHz: Double?
    var delayMilliseconds: Double?
}

enum RoomTreatmentAdvisorAnalysisMode:
    String, Equatable, Sendable
{
    case unavailable
    case singlePosition
    case multiPosition

    var displayName: String {
        switch self {
        case .unavailable: return "No Measurements"
        case .singlePosition: return "Single Position"
        case .multiPosition: return "Multi-Position"
        }
    }
}

struct RoomTreatmentAdvisorReport:
    Equatable, Sendable
{
    var projectID: UUID
    var projectName: String
    var retainedMeasurementCount: Int
    var includedMeasurementCount: Int
    var analysisMode: RoomTreatmentAdvisorAnalysisMode
    var microphoneName: String?
    var calibratedMicrophone: Bool
    var qualityWarnings: [String]
    var findings: [RoomTreatmentAdvisorFinding]

    var actionableFindings: [RoomTreatmentAdvisorFinding] {
        findings.filter {
            $0.primaryRemedy != .noAction
        }
    }
}

/// Offline/read-only acoustic advisor.
///
/// This type consumes already-retained room measurements. It owns no transport,
/// publishes no DSP graph, writes no profile state, and has no method capable of
/// applying a recommendation.
struct RoomTreatmentAdvisorAnalyzer: Sendable {
    static let lowFrequencyRangeHz = 35.0...200.0
    static let spatialSpreadThresholdDB = 6.0
    static let deepCancellationThresholdDB = -8.0
    static let strongEarlyReflectionThresholdDB = -12.0
    static let minimumAdvisorySNRDB = 20.0

    func analyze(
        project: RoomCorrectionProject
    ) -> RoomTreatmentAdvisorReport {
        let included = project.measurements.filter {
            $0.included && $0.weight > 0
        }
        let mode: RoomTreatmentAdvisorAnalysisMode
        switch included.count {
        case 0: mode = .unavailable
        case 1: mode = .singlePosition
        default: mode = .multiPosition
        }

        let warnings = measurementWarnings(included)
        var findings: [RoomTreatmentAdvisorFinding] = []

        if included.isEmpty {
            findings.append(
                RoomTreatmentAdvisorFinding(
                    id: "measurement-readiness",
                    kind: .measurementReadiness,
                    severity: .important,
                    title: "Measurements required",
                    measuredEvidence:
                        "This project has no included measurement positions.",
                    interpretation:
                        "The Advisor needs at least one retained sweep before it can distinguish response, reflection, or spatial problems.",
                    recommendation:
                        "Create a room measurement, then return here. One microphone is sufficient.",
                    primaryRemedy: .measureMore,
                    confidence: 1
                )
            )
        } else {
            if included.count == 1 {
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "single-position-confidence",
                        kind: .measurementReadiness,
                        severity: .information,
                        title: "Single-position diagnosis",
                        measuredEvidence:
                            "One listening position is available.",
                        interpretation:
                            "Frequency-response and reflection clues are usable, but a single position cannot establish whether a bass problem is local to that seat or spatially persistent.",
                        recommendation:
                            "For placement or bass-treatment decisions, move the same microphone to one or two nearby positions and measure again.",
                        primaryRemedy: .measureMore,
                        confidence: 0.95
                    )
                )
            }

            if !warnings.isEmpty {
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "measurement-quality",
                        kind: .measurementQuality,
                        severity: .important,
                        title: "Measurement quality needs attention",
                        measuredEvidence:
                            "\(warnings.count) quality warning\(warnings.count == 1 ? "" : "s") were found in the included measurements.",
                        interpretation:
                            "Clipping, incomplete sweeps, or low signal-to-noise can make acoustic recommendations unreliable.",
                        recommendation:
                            "Resolve the measurement-quality warnings before acting on subtle findings.",
                        primaryRemedy: .measureMore,
                        confidence: 1
                    )
                )
            }

            if let variation = strongestSpatialBassVariation(
                included
            ),
               variation.spreadDB
                    >= Self.spatialSpreadThresholdDB {
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "spatial-bass-variation",
                        kind: .spatialBassVariation,
                        severity: .important,
                        title: "Bass changes substantially across seats",
                        measuredEvidence: String(
                            format:
                                "Seat-to-seat spread reaches %.1f dB near %.0f Hz across %d included positions.",
                            variation.spreadDB,
                            variation.frequencyHz,
                            included.count
                        ),
                        interpretation:
                            "A response that moves strongly with microphone position is primarily a spatial acoustic problem. A large single-seat EQ boost risks over-correcting other seats.",
                        recommendation:
                            "Try speaker/listener placement changes first. If the variation remains across useful positions, the existing multi-seat Active Room Treatment workflow is a better fit than aggressive single-seat EQ.",
                        primaryRemedy: .placement,
                        secondaryRemedies: [
                            .activeRoomTreatment,
                            .passiveTreatment,
                        ],
                        confidence: min(
                            0.95,
                            0.58 + 0.10 * Double(included.count)
                        ),
                        frequencyHz: variation.frequencyHz
                    )
                )
            }

            if let cancellation = deepestBassCancellation(
                included
            ),
               cancellation.depthDB
                    <= Self.deepCancellationThresholdDB {
                let multi = included.count > 1
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "deep-bass-cancellation",
                        kind: .deepBassCancellation,
                        severity: .important,
                        title: String(
                            format:
                                "Deep bass cancellation near %.0f Hz",
                            cancellation.frequencyHz
                        ),
                        measuredEvidence: String(
                            format:
                                "%@ is %.1f dB below its local low-frequency baseline.",
                            cancellation.positionName,
                            abs(cancellation.depthDB)
                        ),
                        interpretation:
                            "A deep acoustic cancellation is a poor candidate for brute-force boost because additional electrical energy may not fill the null at the listening position.",
                        recommendation:
                            multi
                                ? "Treat this primarily as a placement/acoustic problem. Compare nearby positions before considering any bounded DSP correction."
                                : "Measure one or two nearby positions first. If the null shifts strongly, prioritize speaker/listener placement rather than EQ boost.",
                        primaryRemedy:
                            multi ? .placement : .measureMore,
                        secondaryRemedies:
                            multi
                                ? [.passiveTreatment, .activeRoomTreatment]
                                : [.placement],
                        confidence: multi ? 0.82 : 0.62,
                        frequencyHz: cancellation.frequencyHz
                    )
                )
            }

            if let reflection = strongestEarlyReflection(
                included
            ),
               reflection.relativeLevelDB
                    >= Self.strongEarlyReflectionThresholdDB {
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "strong-early-reflection",
                        kind: .earlyReflection,
                        severity: .opportunity,
                        title: "Strong early reflection",
                        measuredEvidence: String(
                            format:
                                "%@ %@ shows a reflection %.1f ms after the direct arrival at %.1f dB relative to the direct sound.",
                            reflection.positionName,
                            reflection.channelName,
                            reflection.delayMilliseconds,
                            reflection.relativeLevelDB
                        ),
                        interpretation:
                            "This is measured time-domain evidence of an early reflection, but a single microphone cannot uniquely identify which wall or surface caused it.",
                        recommendation:
                            "Investigate speaker/listener placement and likely first-reflection surfaces. Broadband treatment may help after the reflection path is confirmed; PR93 room geometry will make that localization more specific.",
                        primaryRemedy: .passiveTreatment,
                        secondaryRemedies: [.placement],
                        confidence: 0.78,
                        delayMilliseconds:
                            reflection.delayMilliseconds
                    )
                )
            }
        }

        let meaningful = findings.contains {
            $0.kind != .measurementReadiness
                && $0.kind != .measurementQuality
        }
        if !included.isEmpty,
           warnings.isEmpty,
           !meaningful {
            findings.append(
                RoomTreatmentAdvisorFinding(
                    id: "no-initial-flag",
                    kind: .noInitialFlag,
                    severity: .information,
                    title: "No major issue in the initial checks",
                    measuredEvidence:
                        "The current PR92 checks did not cross the spatial-bass, deep-null, or early-reflection thresholds.",
                    interpretation:
                        "This is not a claim that the room needs no treatment. Frequency-dependent decay and geometry-assisted diagnosis are intentionally not inferred until those estimators are implemented and validated.",
                    recommendation:
                        "Keep the current measurements as a baseline. Later PR92/PR93 analysis can add validated decay and room-geometry evidence.",
                    primaryRemedy: .noAction,
                    confidence: 0.75
                )
            )
        }

        findings.sort {
            if $0.severity.rawValue != $1.severity.rawValue {
                return $0.severity.rawValue
                    > $1.severity.rawValue
            }
            return $0.title < $1.title
        }

        return RoomTreatmentAdvisorReport(
            projectID: project.id,
            projectName: project.name,
            retainedMeasurementCount: project.measurements.count,
            includedMeasurementCount: included.count,
            analysisMode: mode,
            microphoneName: project.microphone?.displayName,
            calibratedMicrophone:
                project.microphone?.calibration != nil,
            qualityWarnings: warnings,
            findings: findings
        )
    }

    private func measurementWarnings(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> [String] {
        var result: [String] = []
        for position in positions {
            for (label, measurement) in [
                ("Left", position.left),
                ("Right", position.right),
            ] {
                if measurement.quality.clipped {
                    result.append(
                        "\(position.name) \(label): capture clipped."
                    )
                }
                if !measurement.quality.sweepComplete {
                    result.append(
                        "\(position.name) \(label): sweep is incomplete."
                    )
                }
                if let snr =
                    measurement.quality.estimatedSNRDB,
                   snr < Self.minimumAdvisorySNRDB {
                    result.append(
                        String(
                            format:
                                "%@ %@: estimated SNR %.1f dB is below %.0f dB.",
                            position.name,
                            label,
                            snr,
                            Self.minimumAdvisorySNRDB
                        )
                    )
                }
                for warning in measurement.quality.warnings {
                    result.append(
                        "\(position.name) \(label): \(warning)"
                    )
                }
            }
        }
        return Array(Set(result)).sorted()
    }

    private func strongestSpatialBassVariation(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> (frequencyHz: Double, spreadDB: Double)? {
        guard positions.count >= 2,
              let reference =
                positions.first?.left.transferFunction else {
            return nil
        }

        var best: (Double, Double)?
        for frequency in reference.frequenciesHz
            where Self.lowFrequencyRangeHz.contains(frequency) {
            let values = positions.compactMap {
                stereoMagnitude(
                    position: $0,
                    frequencyHz: frequency
                )
            }
            guard values.count == positions.count,
                  let minimum = values.min(),
                  let maximum = values.max() else {
                continue
            }
            let spread = maximum - minimum
            if best == nil || spread > best!.1 {
                best = (frequency, spread)
            }
        }
        return best.map {
            (frequencyHz: $0.0, spreadDB: $0.1)
        }
    }

    private func deepestBassCancellation(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> (
        frequencyHz: Double,
        depthDB: Double,
        positionName: String
    )? {
        var best: (
            frequencyHz: Double,
            depthDB: Double,
            positionName: String
        )?

        for position in positions {
            guard let reference =
                    position.left.transferFunction else {
                continue
            }
            let candidateFrequencies =
                reference.frequenciesHz.filter {
                    $0 >= 40 && $0 <= 180
                }

            for frequency in candidateFrequencies {
                guard let value = stereoMagnitude(
                    position: position,
                    frequencyHz: frequency
                ) else {
                    continue
                }
                let lower = frequency / sqrt(2)
                let upper = frequency * sqrt(2)
                let neighborhood = candidateFrequencies
                    .filter {
                        $0 >= lower && $0 <= upper
                    }
                    .compactMap {
                        stereoMagnitude(
                            position: position,
                            frequencyHz: $0
                        )
                    }
                guard neighborhood.count >= 8 else {
                    continue
                }
                let baseline = median(neighborhood)
                let depth = value - baseline
                if best == nil || depth < best!.depthDB {
                    best = (
                        frequency,
                        depth,
                        position.name
                    )
                }
            }
        }
        return best
    }

    private func strongestEarlyReflection(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> (
        delayMilliseconds: Double,
        relativeLevelDB: Double,
        positionName: String,
        channelName: String
    )? {
        var best: (
            delayMilliseconds: Double,
            relativeLevelDB: Double,
            positionName: String,
            channelName: String
        )?

        for position in positions {
            let channels: [(String, RoomCorrectionChannelMeasurement)] = [
                ("Left", position.left),
                ("Right", position.right),
            ]
            for (channelName, measurement) in channels {
                guard let directSeconds =
                        measurement.quality.directArrivalSeconds,
                      directSeconds.isFinite,
                      directSeconds >= 0,
                      !measurement.impulseResponse.isEmpty else {
                    continue
                }
                let rate = position.sampleRate
                let directIndex = Int(
                    (directSeconds * rate).rounded()
                )
                guard directIndex >= 0,
                      directIndex < measurement
                        .impulseResponse.count else {
                    continue
                }

                let directRadius = max(
                    1,
                    Int((rate * 0.001).rounded())
                )
                let directStart = max(
                    0,
                    directIndex - directRadius
                )
                let directEnd = min(
                    measurement.impulseResponse.count,
                    directIndex + directRadius + 1
                )
                let directPeak =
                    measurement.impulseResponse[
                        directStart..<directEnd
                    ]
                    .map { abs(Double($0)) }
                    .max()
                    ?? 0
                guard directPeak > 1.0e-12 else {
                    continue
                }

                let reflectionStart = min(
                    measurement.impulseResponse.count,
                    directIndex
                        + max(
                            1,
                            Int((rate * 0.002).rounded())
                        )
                )
                let reflectionEnd = min(
                    measurement.impulseResponse.count,
                    directIndex
                        + max(
                            2,
                            Int((rate * 0.020).rounded())
                        )
                )
                guard reflectionStart < reflectionEnd else {
                    continue
                }

                var reflectionPeak = 0.0
                var reflectionIndex = reflectionStart
                for index in reflectionStart..<reflectionEnd {
                    let magnitude = abs(
                        Double(
                            measurement.impulseResponse[index]
                        )
                    )
                    if magnitude > reflectionPeak {
                        reflectionPeak = magnitude
                        reflectionIndex = index
                    }
                }
                guard reflectionPeak > 1.0e-12 else {
                    continue
                }

                let relative =
                    20 * log10(reflectionPeak / directPeak)
                let delayMilliseconds =
                    Double(reflectionIndex - directIndex)
                    / rate * 1_000

                if best == nil
                    || relative > best!.relativeLevelDB {
                    best = (
                        delayMilliseconds,
                        relative,
                        position.name,
                        channelName
                    )
                }
            }
        }
        return best
    }

    private func stereoMagnitude(
        position: RoomCorrectionMeasurementPosition,
        frequencyHz: Double
    ) -> Double? {
        guard let left = position.left.transferFunction,
              let right = position.right.transferFunction,
              let leftDB = interpolatedMagnitude(
                left,
                frequencyHz: frequencyHz
              ),
              let rightDB = interpolatedMagnitude(
                right,
                frequencyHz: frequencyHz
              ) else {
            return nil
        }
        return (leftDB + rightDB) * 0.5
    }

    private func interpolatedMagnitude(
        _ response: RoomCorrectionFrequencyResponse,
        frequencyHz: Double
    ) -> Double? {
        guard response.frequenciesHz.count
                == response.magnitudeDB.count,
              response.frequenciesHz.count >= 2,
              let first = response.frequenciesHz.first,
              let last = response.frequenciesHz.last,
              frequencyHz >= first,
              frequencyHz <= last else {
            return nil
        }

        if frequencyHz == first {
            return response.magnitudeDB[0]
        }
        for upperIndex in 1..<response.frequenciesHz.count {
            let upperFrequency =
                response.frequenciesHz[upperIndex]
            guard frequencyHz <= upperFrequency else {
                continue
            }
            let lowerIndex = upperIndex - 1
            let lowerFrequency =
                response.frequenciesHz[lowerIndex]
            let span =
                log(upperFrequency / lowerFrequency)
            guard span.isFinite, span > 0 else {
                return nil
            }
            let fraction =
                log(frequencyHz / lowerFrequency) / span
            return response.magnitudeDB[lowerIndex]
                + (
                    response.magnitudeDB[upperIndex]
                    - response.magnitudeDB[lowerIndex]
                ) * fraction
        }
        return response.magnitudeDB.last
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (
                sorted[middle - 1] + sorted[middle]
            ) * 0.5
        }
        return sorted[middle]
    }
}
