import Foundation

enum RoomTreatmentVerificationChange: String, Equatable, Sendable {
    case improved
    case regressed
    case inconclusive

    var title: String {
        switch self {
        case .improved: return "Improved"
        case .regressed: return "Regressed"
        case .inconclusive: return "Small / inconclusive"
        }
    }
}

struct RoomTreatmentVerificationMetric: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var baseline: Double
    var followUp: Double
    var unit: String
    var lowerIsBetter: Bool
    var meaningfulThreshold: Double
    var explanation: String

    var delta: Double { followUp - baseline }
    var change: RoomTreatmentVerificationChange {
        let difference = lowerIsBetter ? -delta : delta
        if difference > meaningfulThreshold { return .improved }
        if difference < -meaningfulThreshold { return .regressed }
        return .inconclusive
    }
}

struct RoomTreatmentVerificationReport: Equatable, Sendable {
    var baselineProjectName: String
    var followUpProjectName: String
    var comparable: Bool
    var warnings: [String]
    var matchedPositionCount: Int
    var metrics: [RoomTreatmentVerificationMetric]

    var improvements: Int { metrics.filter { $0.change == .improved }.count }
    var regressions: Int { metrics.filter { $0.change == .regressed }.count }
}

struct RoomTreatmentVerifier: Sendable {
    private let analyzer = RoomTreatmentAdvisorAnalyzer()
    private let frequencies = [63.0, 80, 100, 125, 160, 200]

    func compare(
        baseline: RoomCorrectionProject,
        followUp: RoomCorrectionProject
    ) -> RoomTreatmentVerificationReport {
        var problems: [String] = []
        if baseline.id == followUp.id {
            problems.append("Choose a different follow-up measurement project.")
        }
        if baseline.playbackSystemID != followUp.playbackSystemID {
            problems.append("Different Playback System identities; measurements are not comparable.")
        }
        if baseline.microphone == nil || followUp.microphone == nil ||
            baseline.microphone != followUp.microphone {
            problems.append("The same measurement microphone, input channel and calibration must be recorded in both projects.")
        }
        if baseline.sweep == nil || followUp.sweep == nil ||
            baseline.sweep != followUp.sweep {
            problems.append("Sweep sample rate, level and timing settings must match.")
        }

        let beforePositions = baseline.measurements.filter { $0.included && $0.weight > 0 }
        let afterPositions = followUp.measurements.filter { $0.included && $0.weight > 0 }
        func canonicalName(_ name: String) -> String {
            name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let namesBefore = beforePositions.map { canonicalName($0.name) }
        let namesAfter = afterPositions.map { canonicalName($0.name) }
        if namesBefore.isEmpty || namesBefore.count != namesAfter.count ||
            Set(namesBefore) != Set(namesAfter) ||
            Set(namesBefore).count != namesBefore.count ||
            Set(namesAfter).count != namesAfter.count {
            problems.append("Include the same uniquely named microphone positions in both captures.")
        }
        // Avoid Dictionary(uniqueKeysWithValues:) on corrupt/duplicate names:
        // validation must fail closed, not trap.
        var afterByName: [String: RoomCorrectionMeasurementPosition] = [:]
        for position in afterPositions {
            afterByName[canonicalName(position.name)] = position
        }
        // Check only matched positions, but reject unequal sets above.
        for position in beforePositions {
            guard let other = afterByName[canonicalName(position.name)] else { continue }
            if position.sampleRate != other.sampleRate {
                problems.append("\(position.name): sample rates do not match.")
            }
            for channel in [position.left, position.right, other.left, other.right] {
                let q = channel.quality
                if q.clipped || !q.sweepComplete ||
                    q.estimatedSNRDB == nil ||
                    (q.estimatedSNRDB ?? 0) < RoomTreatmentAdvisorAnalyzer.minimumAdvisorySNRDB ||
                    !q.warnings.isEmpty {
                    problems.append("Clipped, incomplete or noisy sweeps: re-measure \(position.name).")
                    break
                }
            }
        }
        // Quality/identity must pass before potentially expensive decay analysis.
        if !problems.isEmpty {
            return RoomTreatmentVerificationReport(
                baselineProjectName: baseline.name, followUpProjectName: followUp.name,
                comparable: false, warnings: Array(Set(problems)).sorted(),
                matchedPositionCount: 0, metrics: []
            )
        }
        let beforeReport = analyzer.analyze(project: baseline)
        let afterReport = analyzer.analyze(project: followUp)
        if !beforeReport.qualityWarnings.isEmpty || !afterReport.qualityWarnings.isEmpty {
            problems.append("The Room Advisor flagged measurement-quality warnings.")
        }
        if !problems.isEmpty {
            return RoomTreatmentVerificationReport(
                baselineProjectName: baseline.name, followUpProjectName: followUp.name,
                comparable: false, warnings: Array(Set(problems)).sorted(),
                matchedPositionCount: 0, metrics: []
            )
        }

        var metrics: [RoomTreatmentVerificationMetric] = []
        // Seat variation compares identical microphone coordinates and frequencies.
        if beforePositions.count >= 2,
           let beforeSpread = meanSeatSpread(beforePositions),
           let afterSpread = meanSeatSpread(afterPositions) {
            metrics.append(RoomTreatmentVerificationMetric(
                id: "seat-spread", title: "Average bass seat-to-seat spread (63–200 Hz)",
                baseline: beforeSpread, followUp: afterSpread,
                unit: "dB", lowerIsBetter: true, meaningfulThreshold: 1.0,
                explanation: "Average max−min response difference over identical low-frequency bins. Lower means more consistent bass across included seats."
            ))
        }

        // Band-limited Schroeder decay: only compare identical location/channel/band fits.
        let afterDecay = afterReport.bandDecayMeasurements
        var pairedDecay: [(Double, Double)] = []
        for before in beforeReport.bandDecayMeasurements where before.frequencyHz >= 63 &&
            before.frequencyHz <= 200 &&
            before.fitR2 >= RoomTreatmentAdvisorAnalyzer.minimumDecayFitR2 {
            if let after = afterDecay.first(where: {
                canonicalName($0.positionName) == canonicalName(before.positionName)
                    && $0.channelName == before.channelName
                    && $0.frequencyHz == before.frequencyHz
                    && $0.fitR2 >= RoomTreatmentAdvisorAnalyzer.minimumDecayFitR2
            }) {
                pairedDecay.append((before.t20DerivedRT60Seconds, after.t20DerivedRT60Seconds))
            }
        }
        if !pairedDecay.isEmpty {
            let count = Double(pairedDecay.count)
            metrics.append(RoomTreatmentVerificationMetric(
                id: "lf-decay", title: "Matched low-frequency T20-derived decay",
                baseline: pairedDecay.reduce(0) { $0 + $1.0 } / count,
                followUp: pairedDecay.reduce(0) { $0 + $1.1 } / count,
                unit: "s", lowerIsBetter: true, meaningfulThreshold: 0.05,
                explanation: "\(pairedDecay.count) matching position/channel/frequency fits passed R² gates in both sweeps. This is a derived RT60 estimate, not a directly measured 60 dB decay."
            ))
        }

        // A measured strong reflection supplies the time window to remeasure.
        if let delay = beforeReport.findings.first(where: { $0.kind == .earlyReflection })?.delayMilliseconds,
           let b = reflectionPeak(beforePositions, at: delay),
           let a = reflectionPeak(afterPositions, at: delay) {
            metrics.append(RoomTreatmentVerificationMetric(
                id: "early-reflection", title: String(format: "Early-reflection peak near %.1f ms", delay),
                baseline: b, followUp: a, unit: "dB vs direct",
                lowerIsBetter: true, meaningfulThreshold: 1.5,
                explanation: "Peak in a ±0.5 ms arrival-relative window, normalized against the direct arrival at matching positions. More negative means less reflected energy."
            ))
        }

        // Tracked baseline problem frequencies (observed normalized magnitude, not an
        // automatic improvement verdict: target/causality cannot be inferred from magnitude).
        for finding in beforeReport.findings where
            finding.kind == .deepBassCancellation ||
            finding.kind == .boundaryInterferenceCandidate ||
            finding.kind == .spatialBassVariation {
            guard let frequency = finding.frequencyHz,
                  let b = normalizedMeanMagnitude(beforePositions, frequency: frequency),
                  let a = normalizedMeanMagnitude(afterPositions, frequency: frequency)
            else { continue }
            metrics.append(RoomTreatmentVerificationMetric(
                id: "response-\(finding.id)",
                title: String(format: "Relative response near %.0f Hz", frequency),
                baseline: abs(b), followUp: abs(a), unit: "dB deviation",
                lowerIsBetter: true, meaningfulThreshold: 1.5,
                explanation: "Absolute deviation from the 500–2000 Hz reference at the same matched positions. Smaller is flatter, but flatter alone does not prove better sound."
            ))
        }
        if metrics.isEmpty {
            return RoomTreatmentVerificationReport(
                baselineProjectName: baseline.name, followUpProjectName: followUp.name,
                comparable: false,
                warnings: ["No shared valid decay, reflection, spatial or problem-frequency metric was available. Repeat higher-quality comparable measurements."],
                matchedPositionCount: beforePositions.count, metrics: []
            )
        }
        return RoomTreatmentVerificationReport(
            baselineProjectName: baseline.name, followUpProjectName: followUp.name,
            comparable: true,
            warnings: [
                "Observed differences do not by themselves prove that the installed treatment caused the change. Keep microphone positions, playback gain, routing and room conditions fixed.",
                "The project identity and capture metadata can be checked, but Notch cannot prove that the hardware or DSP settings stayed unchanged."
            ],
            matchedPositionCount: beforePositions.count, metrics: metrics
        )
    }

    private func interpolated(
        _ response: RoomCorrectionFrequencyResponse?,
        at frequency: Double
    ) -> Double? {
        guard let response,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.frequenciesHz.count >= 2,
              let minHz = response.frequenciesHz.first,
              let maxHz = response.frequenciesHz.last,
              frequency >= minHz, frequency <= maxHz else { return nil }
        for i in 1..<response.frequenciesHz.count {
            let upper = response.frequenciesHz[i]
            let lower = response.frequenciesHz[i - 1]
            guard upper > lower else { return nil }
            if frequency <= upper {
                let a = response.magnitudeDB[i - 1]
                let b = response.magnitudeDB[i]
                let ratio = log(frequency / lower) / log(upper / lower)
                let value = a + (b - a) * ratio
                return value.isFinite ? value : nil
            }
        }
        return nil
    }

    private func stereo(
        _ position: RoomCorrectionMeasurementPosition,
        at frequency: Double
    ) -> Double? {
        guard let l = interpolated(position.left.transferFunction, at: frequency),
              let r = interpolated(position.right.transferFunction, at: frequency)
        else { return nil }
        return (l + r) / 2
    }

    private func meanSeatSpread(
        _ positions: [RoomCorrectionMeasurementPosition]
    ) -> Double? {
        let spreads = frequencies.compactMap { frequency -> Double? in
            let values = positions.compactMap { stereo($0, at: frequency) }
            guard values.count == positions.count,
                  let small = values.min(), let large = values.max() else { return nil }
            return large - small
        }
        guard spreads.count == frequencies.count else { return nil }
        return spreads.reduce(0, +) / Double(spreads.count)
    }

    private func normalizedMeanMagnitude(
        _ positions: [RoomCorrectionMeasurementPosition],
        frequency: Double
    ) -> Double? {
        var values: [Double] = []
        for position in positions {
            guard let value = stereo(position, at: frequency) else { return nil }
            let reference = [500.0, 1000, 2000].compactMap { stereo(position, at: $0) }
            guard reference.count == 3 else { return nil }
            values.append(value - reference.reduce(0, +) / 3)
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func reflectionPeak(
        _ positions: [RoomCorrectionMeasurementPosition],
        at delayMs: Double
    ) -> Double? {
        var levels: [Double] = []
        for position in positions {
            for channel in [position.left, position.right] {
                guard let arrival = channel.quality.directArrivalSeconds,
                      arrival.isFinite, arrival >= 0,
                      position.sampleRate.isFinite, position.sampleRate > 0 else { return nil }
                let index = Int((arrival * position.sampleRate).rounded())
                let count = channel.impulseResponse.count
                let radius = max(1, Int((0.001 * position.sampleRate).rounded()))
                let start = max(0, index - radius)
                let end = min(count, index + radius + 1)
                guard start < end else { return nil }
                let direct = channel.impulseResponse[start..<end]
                    .map { abs(Double($0)) }.max() ?? 0
                let arrivalIndex = index + Int((delayMs / 1000 * position.sampleRate).rounded())
                let width = max(1, Int((0.0005 * position.sampleRate).rounded()))
                let reflectionStart = max(0, arrivalIndex - width)
                let reflectionEnd = min(count, arrivalIndex + width + 1)
                guard direct > 1.0e-12, reflectionStart < reflectionEnd else { return nil }
                let reflected = channel.impulseResponse[reflectionStart..<reflectionEnd]
                    .map { abs(Double($0)) }.max() ?? 0
                levels.append(20 * log10(max(reflected / direct, 1.0e-9)))
            }
        }
        guard !levels.isEmpty else { return nil }
        return levels.reduce(0, +) / Double(levels.count)
    }
}
