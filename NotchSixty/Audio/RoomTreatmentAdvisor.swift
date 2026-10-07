import Foundation

enum RoomTreatmentAdvisorRemedy:
    String, CaseIterable, Equatable, Hashable, Sendable, Identifiable
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
    case lowFrequencyRinging
    case boundaryInterferenceCandidate
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
    var decaySeconds: Double?
}

struct RoomTreatmentAdvisorActionPriority:
    Identifiable, Equatable, Sendable
{
    var remedy: RoomTreatmentAdvisorRemedy
    var score: Double
    var rationale: String

    var id: String { remedy.rawValue }
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
    var actionPriorities:
        [RoomTreatmentAdvisorActionPriority]

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
    static let minimumDecayFitR2 = 0.82
    static let lowFrequencyDecayRatioThreshold = 1.55
    static let minimumLowFrequencyRingingSeconds = 0.38
    static let resonantResponseContrastDB = 4.0
    static let boundaryCandidateLowHz = 70.0
    static let boundaryCandidateHighHz = 250.0

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
        let decay = decaySummary(included)
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

            if let ringing = decay.longestLowFrequency,
               let baseline = decay.midbandMedianSeconds,
               ringing.rt60Seconds
                    >= max(
                        Self.minimumLowFrequencyRingingSeconds,
                        baseline
                            * Self.lowFrequencyDecayRatioThreshold
                    ) {
                let contrast = aggregateLocalResponseContrast(
                    included,
                    frequencyHz: ringing.frequencyHz
                )
                let responseSupportsResonance =
                    (contrast ?? 0)
                    >= Self.resonantResponseContrastDB
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "low-frequency-ringing",
                        kind: .lowFrequencyRinging,
                        severity: .important,
                        title: String(
                            format:
                                "Low-frequency ringing near %.0f Hz",
                            ringing.frequencyHz
                        ),
                        measuredEvidence: String(
                            format:
                                "T20-derived decay is %.2f s near %.0f Hz versus a %.2f s midband baseline (fit R² %.2f).",
                            ringing.rt60Seconds,
                            ringing.frequencyHz,
                            baseline,
                            ringing.fitR2
                        ),
                        interpretation:
                            responseSupportsResonance
                                ? "The unusually long decay coincides with elevated response energy, which is consistent with resonant/modal-like room behavior. Geometry is still required before naming a specific room mode."
                                : "The room stores low-frequency energy substantially longer than it stores midband energy. EQ can reduce excitation, but it does not directly remove the room's acoustic decay.",
                        recommendation:
                            responseSupportsResonance
                                ? "Prioritize bass trapping and speaker/listener placement experiments. Use bounded DSP only for residual level error after the decay problem is addressed."
                                : "Investigate substantial low-frequency absorption and placement before relying on EQ. Re-measure after any physical change to confirm shorter decay.",
                        primaryRemedy: .passiveTreatment,
                        secondaryRemedies: [
                            .placement,
                            .dspCorrection,
                        ],
                        confidence:
                            responseSupportsResonance
                                ? 0.90
                                : 0.84,
                        frequencyHz: ringing.frequencyHz,
                        decaySeconds: ringing.rt60Seconds
                    )
                )
            }

            if let cancellation = deepestBassCancellation(
                included
            ),
               cancellation.frequencyHz
                    >= Self.boundaryCandidateLowHz,
               cancellation.frequencyHz
                    <= Self.boundaryCandidateHighHz,
               cancellation.depthDB <= -6.0,
               let baseline = decay.midbandMedianSeconds,
               let nearbyDecay = decay.nearest(
                    to: cancellation.frequencyHz
               ),
               nearbyDecay.rt60Seconds
                    <= baseline * 1.25 {
                findings.append(
                    RoomTreatmentAdvisorFinding(
                        id: "boundary-interference-candidate",
                        kind: .boundaryInterferenceCandidate,
                        severity: .opportunity,
                        title: String(
                            format:
                                "Boundary-interference candidate near %.0f Hz",
                            cancellation.frequencyHz
                        ),
                        measuredEvidence: String(
                            format:
                                "A %.1f dB cancellation near %.0f Hz is not accompanied by unusually long decay (%.2f s versus %.2f s midband).",
                            abs(cancellation.depthDB),
                            cancellation.frequencyHz,
                            nearbyDecay.rt60Seconds,
                            baseline
                        ),
                        interpretation:
                            "A deep response null without matching excess decay is more consistent with destructive path interference than with stored resonant energy. Without room geometry this remains an SBIR/boundary-interference candidate, not a unique diagnosis.",
                        recommendation:
                            "Prioritize speaker and listening-position movement and re-measure. Avoid large EQ boost into the null. PR93 room geometry can test likely boundary path lengths.",
                        primaryRemedy: .placement,
                        secondaryRemedies: [.measureMore],
                        confidence:
                            included.count > 1 ? 0.78 : 0.64,
                        frequencyHz:
                            cancellation.frequencyHz,
                        decaySeconds:
                            nearbyDecay.rt60Seconds
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
                        "The current PR92 checks did not cross the spatial-bass, deep-null, early-reflection, or excess-decay thresholds.",
                    interpretation:
                        "This is not a claim that the room needs no treatment. The current measurements simply do not show a strong problem in the validated checks.",
                    recommendation:
                        "Keep the current measurements as a baseline. PR93 room geometry can add placement and reflection-path specificity without changing this measurement record.",
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

        let actionPriorities =
            prioritizedActions(from: findings)

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
            findings: findings,
            actionPriorities: actionPriorities
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
                guard neighborhood.count >= 6 else {
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

    private struct DecayEstimate: Sendable {
        var frequencyHz: Double
        var rt60Seconds: Double
        var fitR2: Double
        var positionName: String
        var channelName: String
    }

    private struct DecaySummary: Sendable {
        var estimates: [DecayEstimate]
        var midbandMedianSeconds: Double?
        var longestLowFrequency: DecayEstimate?

        func nearest(
            to frequencyHz: Double
        ) -> DecayEstimate? {
            estimates.min {
                abs(log($0.frequencyHz / frequencyHz))
                    < abs(log($1.frequencyHz / frequencyHz))
            }
        }
    }

    private func decaySummary(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> DecaySummary {
        let centers = [
            63.0, 80, 100, 125, 160, 200,
            500, 1_000, 2_000,
        ]
        var estimates: [DecayEstimate] = []

        for position in positions {
            for (channelName, measurement) in [
                ("Left", position.left),
                ("Right", position.right),
            ] {
                guard let directSeconds =
                        measurement.quality
                            .directArrivalSeconds,
                      directSeconds.isFinite,
                      directSeconds >= 0 else {
                    continue
                }
                let directIndex = Int(
                    (
                        directSeconds
                        * position.sampleRate
                    ).rounded()
                )
                guard directIndex >= 0,
                      directIndex
                        < measurement.impulseResponse.count
                else {
                    continue
                }

                for center in centers {
                    guard center
                            < position.sampleRate * 0.45,
                          let estimate =
                            t20DerivedDecay(
                                impulse:
                                    measurement
                                        .impulseResponse,
                                sampleRate:
                                    position.sampleRate,
                                directIndex: directIndex,
                                centerFrequencyHz:
                                    center
                            ) else {
                        continue
                    }
                    estimates.append(
                        DecayEstimate(
                            frequencyHz: center,
                            rt60Seconds:
                                estimate.rt60Seconds,
                            fitR2: estimate.fitR2,
                            positionName: position.name,
                            channelName: channelName
                        )
                    )
                }
            }
        }

        let midband = estimates
            .filter {
                $0.frequencyHz >= 500
                    && $0.frequencyHz <= 2_000
                    && $0.fitR2
                        >= Self.minimumDecayFitR2
            }
            .map(\.rt60Seconds)
        let low = estimates
            .filter {
                $0.frequencyHz >= 63
                    && $0.frequencyHz <= 200
                    && $0.fitR2
                        >= Self.minimumDecayFitR2
            }
        return DecaySummary(
            estimates: estimates,
            midbandMedianSeconds:
                midband.isEmpty
                    ? nil
                    : median(midband),
            longestLowFrequency:
                low.max {
                    $0.rt60Seconds < $1.rt60Seconds
                }
        )
    }

    private func t20DerivedDecay(
        impulse: [Float],
        sampleRate: Double,
        directIndex: Int,
        centerFrequencyHz: Double
    ) -> (
        rt60Seconds: Double,
        fitR2: Double
    )? {
        guard sampleRate.isFinite,
              sampleRate > 0,
              centerFrequencyHz.isFinite,
              centerFrequencyHz > 0,
              directIndex >= 0,
              directIndex < impulse.count,
              impulse.count - directIndex
                >= Int(sampleRate * 0.06)
        else {
            return nil
        }

        let filtered = bandpass(
            impulse,
            sampleRate: sampleRate,
            centerFrequencyHz:
                centerFrequencyHz,
            q: 4.318
        )
        guard filtered.count == impulse.count else {
            return nil
        }

        var integrated = [Double](
            repeating: 0,
            count: filtered.count
        )
        var running = 0.0
        if directIndex < filtered.count {
            for index in stride(
                from: filtered.count - 1,
                through: directIndex,
                by: -1
            ) {
                let value = filtered[index]
                running += value * value
                integrated[index] = running
            }
        }

        let reference = integrated[directIndex]
        guard reference.isFinite,
              reference > 1.0e-18 else {
            return nil
        }

        var times: [Double] = []
        var levels: [Double] = []
        for index in directIndex..<integrated.count {
            let ratio =
                max(integrated[index] / reference, 1.0e-15)
            let db = 10 * log10(ratio)
            if db <= -5, db >= -25 {
                times.append(
                    Double(index - directIndex)
                        / sampleRate
                )
                levels.append(db)
            }
        }

        guard times.count >= 24,
              let first = times.first,
              let last = times.last,
              last - first >= 0.025
        else {
            return nil
        }

        let fit = linearRegression(
            x: times,
            y: levels
        )
        guard fit.slope.isFinite,
              fit.slope < -1,
              fit.r2 >= Self.minimumDecayFitR2 else {
            return nil
        }

        let rt60 = -60 / fit.slope
        guard rt60.isFinite,
              rt60 >= 0.05,
              rt60 <= 5 else {
            return nil
        }
        return (rt60, fit.r2)
    }

    private func bandpass(
        _ samples: [Float],
        sampleRate: Double,
        centerFrequencyHz: Double,
        q: Double
    ) -> [Double] {
        guard !samples.isEmpty,
              sampleRate > 0,
              centerFrequencyHz > 0,
              centerFrequencyHz
                < sampleRate * 0.5,
              q > 0 else {
            return []
        }

        let omega =
            2 * Double.pi
            * centerFrequencyHz / sampleRate
        let alpha = sin(omega) / (2 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0
        let b1 = 0.0
        let b2 = -alpha / a0
        let a1 = -2 * cos(omega) / a0
        let a2 = (1 - alpha) / a0

        var result = [Double](
            repeating: 0,
            count: samples.count
        )
        var x1 = 0.0
        var x2 = 0.0
        var y1 = 0.0
        var y2 = 0.0
        for index in samples.indices {
            let x0 = Double(samples[index])
            let y0 =
                b0 * x0
                + b1 * x1
                + b2 * x2
                - a1 * y1
                - a2 * y2
            result[index] = y0
            x2 = x1
            x1 = x0
            y2 = y1
            y1 = y0
        }
        return result
    }

    private func linearRegression(
        x: [Double],
        y: [Double]
    ) -> (
        slope: Double,
        r2: Double
    ) {
        guard x.count == y.count,
              x.count >= 2 else {
            return (.nan, 0)
        }
        let count = Double(x.count)
        let meanX = x.reduce(0, +) / count
        let meanY = y.reduce(0, +) / count
        var numerator = 0.0
        var denominator = 0.0
        var totalY = 0.0
        for index in x.indices {
            let dx = x[index] - meanX
            let dy = y[index] - meanY
            numerator += dx * dy
            denominator += dx * dx
            totalY += dy * dy
        }
        guard denominator > 1.0e-18,
              totalY > 1.0e-18 else {
            return (.nan, 0)
        }
        let slope = numerator / denominator
        let intercept = meanY - slope * meanX
        var residual = 0.0
        for index in x.indices {
            let predicted =
                intercept + slope * x[index]
            let error = y[index] - predicted
            residual += error * error
        }
        return (
            slope,
            max(0, min(1, 1 - residual / totalY))
        )
    }

    private func aggregateLocalResponseContrast(
        _ positions: [RoomCorrectionMeasurementPosition],
        frequencyHz: Double
    ) -> Double? {
        let values = positions.compactMap {
            localResponseContrast(
                position: $0,
                frequencyHz: frequencyHz
            )
        }
        guard !values.isEmpty else { return nil }
        return median(values)
    }

    private func localResponseContrast(
        position: RoomCorrectionMeasurementPosition,
        frequencyHz: Double
    ) -> Double? {
        guard let center = stereoMagnitude(
            position: position,
            frequencyHz: frequencyHz
        ),
        let response = position.left.transferFunction
        else {
            return nil
        }
        let lower = frequencyHz / sqrt(2)
        let upper = frequencyHz * sqrt(2)
        let neighborhood =
            response.frequenciesHz
                .filter {
                    $0 >= lower
                        && $0 <= upper
                }
                .compactMap {
                    stereoMagnitude(
                        position: position,
                        frequencyHz: $0
                    )
                }
        guard neighborhood.count >= 6 else {
            return nil
        }
        return center - median(neighborhood)
    }

    private func prioritizedActions(
        from findings: [RoomTreatmentAdvisorFinding]
    ) -> [RoomTreatmentAdvisorActionPriority] {
        var scores:
            [RoomTreatmentAdvisorRemedy: Double] = [:]
        var rationales:
            [RoomTreatmentAdvisorRemedy: String] = [:]

        for finding in findings {
            guard finding.primaryRemedy != .noAction else {
                continue
            }
            let severityWeight: Double
            switch finding.severity {
            case .important: severityWeight = 3
            case .opportunity: severityWeight = 2
            case .information: severityWeight = 1
            }
            var primaryScore =
                severityWeight
                * max(finding.confidence, 0.1)
            if finding.kind == .measurementQuality {
                primaryScore += 6
            } else if finding.kind
                        == .measurementReadiness,
                      finding.primaryRemedy == .measureMore {
                primaryScore += 2
            }
            scores[finding.primaryRemedy, default: 0]
                += primaryScore
            if rationales[finding.primaryRemedy] == nil {
                rationales[finding.primaryRemedy] =
                    finding.recommendation
            }

            for remedy in finding.secondaryRemedies
                where remedy != .noAction {
                scores[remedy, default: 0]
                    += primaryScore * 0.30
                if rationales[remedy] == nil {
                    rationales[remedy] =
                        finding.recommendation
                }
            }
        }

        return scores
            .map {
                RoomTreatmentAdvisorActionPriority(
                    remedy: $0.key,
                    score: $0.value,
                    rationale:
                        rationales[$0.key]
                        ?? "Supported by the current measured findings."
                )
            }
            .sorted {
                if $0.score != $1.score {
                    return $0.score > $1.score
                }
                return $0.remedy.rawValue
                    < $1.remedy.rawValue
            }
            .prefix(3)
            .map { $0 }
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
