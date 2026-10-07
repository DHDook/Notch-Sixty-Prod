import Foundation

enum RoomCorrectionTargetDesignError: Error, Equatable, LocalizedError {
    case emptyTarget
    case malformedTargetLine(Int)
    case invalidTargetFrequency(Int)
    case invalidTargetGain(Int)
    case insufficientTargetPoints
    case invalidTargetCurve
    case invalidResponse
    case mismatchedResponseGrid
    case invalidSmoothing(Double)
    case invalidCorrectionRange(low: Double, high: Double)
    case invalidMaximumBoost(Double)
    case invalidMaximumCut(Double)
    case invalidTapCount(Int)
    case invalidUsableRange(low: Double, high: Double)
    case noUsableCorrectionRange

    var errorDescription: String? {
        switch self {
        case .emptyTarget:
            return "The target file does not contain any target points."
        case .malformedTargetLine(let line):
            return "Target line \(line) must contain exactly two numeric columns: frequency in Hz and gain in dB."
        case .invalidTargetFrequency(let line):
            return "Target line \(line) contains an invalid frequency."
        case .invalidTargetGain(let line):
            return "Target line \(line) contains an invalid gain value."
        case .insufficientTargetPoints:
            return "A room-correction target requires at least two unique frequency points."
        case .invalidTargetCurve:
            return "The room-correction target must contain finite, strictly increasing frequency/gain points."
        case .invalidResponse:
            return "The aggregate room response is invalid or contains non-finite data."
        case .mismatchedResponseGrid:
            return "Left and right aggregate room responses must use the same frequency grid."
        case .invalidSmoothing(let value):
            return "Room-correction smoothing \(value) octaves is invalid."
        case .invalidCorrectionRange(let low, let high):
            return "Room-correction range \(low)...\(high) Hz is invalid."
        case .invalidMaximumBoost(let value):
            return "Room-correction maximum boost \(value) dB is invalid."
        case .invalidMaximumCut(let value):
            return "Room-correction maximum cut \(value) dB is invalid."
        case .invalidTapCount(let value):
            return "Room-correction FIR tap count \(value) is outside the supported 1...\(Int(N60_CONVOLUTION_MAX_TAPS)) range."
        case .invalidUsableRange(let low, let high):
            return "Measured usable range \(low)...\(high) Hz is invalid."
        case .noUsableCorrectionRange:
            return "The requested correction range does not overlap the measured usable range."
        }
    }
}

enum RoomCorrectionBuiltInTarget: String, CaseIterable, Identifiable, Sendable {
    case flat
    case gentleDownwardTilt
    case bassShelfAndTilt

    var id: String { rawValue }

    var curve: RoomCorrectionTargetCurve {
        switch self {
        case .flat:
            return RoomCorrectionTargetCurve(
                id: UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000101")!,
                name: "Flat",
                points: [
                    RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 0),
                    RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: 0),
                ]
            )
        case .gentleDownwardTilt:
            return RoomCorrectionTargetCurve(
                id: UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000102")!,
                name: "Gentle Downward Tilt",
                points: [
                    RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 1.0),
                    RoomCorrectionTargetPoint(frequencyHz: 1_000, gainDB: 0),
                    RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: -2.5),
                ]
            )
        case .bassShelfAndTilt:
            return RoomCorrectionTargetCurve(
                id: UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000103")!,
                name: "Bass Shelf + Tilt",
                points: [
                    RoomCorrectionTargetPoint(frequencyHz: 20, gainDB: 4.0),
                    RoomCorrectionTargetPoint(frequencyHz: 80, gainDB: 4.0),
                    RoomCorrectionTargetPoint(frequencyHz: 200, gainDB: 1.0),
                    RoomCorrectionTargetPoint(frequencyHz: 1_000, gainDB: 0),
                    RoomCorrectionTargetPoint(frequencyHz: 20_000, gainDB: -2.5),
                ]
            )
        }
    }
}

struct RoomCorrectionTargetCurveParser: Sendable {
    func parse(
        _ text: String,
        name proposedName: String = "Imported Target",
        id: UUID = UUID()
    ) throws -> RoomCorrectionTargetCurve {
        var pointsByFrequency: [Double: (sum: Double, count: Int)] = [:]
        var sawDataLine = false

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let lineNumber = offset + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("#") || line.hasPrefix(";") || line.hasPrefix("*") || line.hasPrefix("//") {
                continue
            }
            sawDataLine = true
            let fields = line
                .replacingOccurrences(of: ",", with: " ")
                .split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2,
                  let frequency = Double(fields[0]),
                  let gain = Double(fields[1]) else {
                throw RoomCorrectionTargetDesignError.malformedTargetLine(lineNumber)
            }
            guard frequency.isFinite, frequency > 0 else {
                throw RoomCorrectionTargetDesignError.invalidTargetFrequency(lineNumber)
            }
            guard gain.isFinite else {
                throw RoomCorrectionTargetDesignError.invalidTargetGain(lineNumber)
            }
            let existing = pointsByFrequency[frequency] ?? (0, 0)
            pointsByFrequency[frequency] = (existing.sum + gain, existing.count + 1)
        }

        guard sawDataLine else { throw RoomCorrectionTargetDesignError.emptyTarget }
        let points = pointsByFrequency
            .map { frequency, accumulation in
                RoomCorrectionTargetPoint(
                    frequencyHz: frequency,
                    gainDB: accumulation.sum / Double(accumulation.count)
                )
            }
            .sorted { $0.frequencyHz < $1.frequencyHz }
        guard points.count >= 2 else {
            throw RoomCorrectionTargetDesignError.insufficientTargetPoints
        }

        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        return RoomCorrectionTargetCurve(
            id: id,
            name: trimmedName.isEmpty ? "Imported Target" : trimmedName,
            points: points
        )
    }
}

extension RoomCorrectionTargetCurve {
    func interpolatedGainDB(at frequencyHz: Double) throws -> Double {
        try RoomCorrectionTargetMath.validateTarget(self)
        guard frequencyHz.isFinite, frequencyHz > 0 else {
            throw RoomCorrectionTargetDesignError.invalidTargetCurve
        }
        guard let first = points.first, let last = points.last else {
            throw RoomCorrectionTargetDesignError.invalidTargetCurve
        }
        if frequencyHz <= first.frequencyHz { return first.gainDB }
        if frequencyHz >= last.frequencyHz { return last.gainDB }

        for index in 0..<(points.count - 1) {
            let lower = points[index]
            let upper = points[index + 1]
            guard frequencyHz <= upper.frequencyHz else { continue }
            let lowerLog = log(lower.frequencyHz)
            let upperLog = log(upper.frequencyHz)
            let fraction = (log(frequencyHz) - lowerLog) / (upperLog - lowerLog)
            return lower.gainDB + fraction * (upper.gainDB - lower.gainDB)
        }
        return last.gainDB
    }
}

struct RoomCorrectionMagnitudeSmoother: Sendable {
    func smooth(
        _ response: RoomCorrectionFrequencyResponse,
        octaves: Double
    ) throws -> RoomCorrectionFrequencyResponse {
        try RoomCorrectionTargetMath.validateResponse(response)
        guard octaves.isFinite, octaves >= 0 else {
            throw RoomCorrectionTargetDesignError.invalidSmoothing(octaves)
        }
        guard octaves > 0 else {
            return RoomCorrectionFrequencyResponse(
                frequenciesHz: response.frequenciesHz,
                magnitudeDB: response.magnitudeDB,
                phaseRadians: nil
            )
        }

        let halfWidth = octaves * 0.5
        var smoothed = [Double](repeating: 0, count: response.magnitudeDB.count)
        for index in response.frequenciesHz.indices {
            let center = response.frequenciesHz[index]
            var weightedSum = 0.0
            var totalWeight = 0.0
            for neighbor in response.frequenciesHz.indices {
                let distance = abs(log2(response.frequenciesHz[neighbor] / center))
                guard distance <= halfWidth else { continue }
                let normalized = halfWidth > 0 ? min(distance / halfWidth, 1) : 0
                let weight = 0.5 * (1.0 + cos(Double.pi * normalized))
                guard weight > 0 else { continue }
                weightedSum += response.magnitudeDB[neighbor] * weight
                totalWeight += weight
            }
            smoothed[index] = totalWeight > 0
                ? weightedSum / totalWeight
                : response.magnitudeDB[index]
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: response.frequenciesHz,
            magnitudeDB: smoothed,
            phaseRadians: nil
        )
    }
}


enum IntelligentTargetPreference: String, CaseIterable, Identifiable, Sendable {
    case neutral
    case warm
    case studio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral: return "Neutral"
        case .warm: return "Warm"
        case .studio: return "Studio"
        }
    }

    fileprivate var nominalBassShelfDB: Double {
        switch self {
        case .neutral: return 2.0
        case .warm: return 3.0
        case .studio: return 1.0
        }
    }

    fileprivate var nominalTrebleAt20KDB: Double {
        switch self {
        case .neutral: return -2.5
        case .warm: return -3.0
        case .studio: return -1.5
        }
    }

    fileprivate var stableTargetID: UUID {
        switch self {
        case .neutral:
            return UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000201")!
        case .warm:
            return UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000202")!
        case .studio:
            return UUID(uuidString: "6A782AB6-492B-46C9-A0A0-000000000203")!
        }
    }
}

struct IntelligentTargetEvidenceSample: Sendable {
    var label: String
    var response: RoomCorrectionFrequencyResponse
    var quality: RoomCorrectionMeasurementQuality
    var weight: Double
}

struct IntelligentTargetGenerationReport: Equatable, Sendable {
    var preference: IntelligentTargetPreference
    var target: RoomCorrectionTargetCurve
    var confidence: Double
    var referenceLevelDB: Double
    var estimatedBassExtensionHz: Double
    var generatedBassShelfDB: Double
    var generatedTrebleAt20KDB: Double
    var effectiveLowHz: Double
    var effectiveHighHz: Double
    var meanSpatialDeviationDB: Double
    var maximumRequestedBoostDB: Double
    var maximumRequestedCutDB: Double
    var fallbackUsed: Bool
    var clampDecisions: [String]
    var warnings: [String]
}

enum IntelligentTargetGenerationError: Error, Equatable, LocalizedError {
    case noEvidence
    case invalidEvidence(String)
    case noUsableBand
    case invalidParameters

    var errorDescription: String? {
        switch self {
        case .noEvidence:
            return "Automatic target generation requires measured acoustic evidence."
        case .invalidEvidence(let label):
            return "Automatic target generation found invalid response data for \(label)."
        case .noUsableBand:
            return "Automatic target generation could not find a trustworthy common correction band."
        case .invalidParameters:
            return "Automatic target generation received invalid correction limits."
        }
    }
}

/// Deterministic, explainable target generation from measured acoustic evidence.
///
/// The generator deliberately models only broad tonal trend. It uses heavy
/// smoothing and robust statistics so room modes, combing and narrow nulls do
/// not become target features. The output is an ordinary editable
/// RoomCorrectionTargetCurve and remains subject to PR86 verification.
struct IntelligentRoomTargetGenerator: Sendable {
    static let analysisSmoothingOctaves = 2.0 / 3.0
    static let minimumConfidence = 0.70
    static let maximumBassShelfDB = 4.0
    static let minimumTrebleAt20KDB = -4.0
    static let maximumTrebleAt20KDB = -1.0
    static let bassRollOffThresholdDB = -6.0
    static let referenceBandLowHz = 300.0
    static let referenceBandHighHz = 2_000.0

    private let smoother = RoomCorrectionMagnitudeSmoother()

    func generate(
        aggregate: RoomCorrectionAggregateResponse,
        positions: [RoomCorrectionMeasurementPosition],
        parameters: RoomCorrectionDesignParameters,
        preference: IntelligentTargetPreference
    ) throws -> IntelligentTargetGenerationReport {
        try RoomCorrectionTargetMath.validateResponse(aggregate.leftResponse)
        try RoomCorrectionTargetMath.validateResponse(aggregate.rightResponse)
        guard RoomCorrectionTargetMath.frequencyGridsMatch(
            aggregate.leftResponse.frequenciesHz,
            aggregate.rightResponse.frequenciesHz
        ) else {
            throw IntelligentTargetGenerationError
                .invalidEvidence("room aggregate")
        }

        let samples = positions
            .filter { $0.included && $0.weight.isFinite && $0.weight > 0 }
            .flatMap { position -> [IntelligentTargetEvidenceSample] in
                var result: [IntelligentTargetEvidenceSample] = []
                if let left = position.left.transferFunction {
                    result.append(
                        IntelligentTargetEvidenceSample(
                            label: "\(position.name) Left",
                            response: left,
                            quality: position.left.quality,
                            weight: position.weight * 0.5
                        )
                    )
                }
                if let right = position.right.transferFunction {
                    result.append(
                        IntelligentTargetEvidenceSample(
                            label: "\(position.name) Right",
                            response: right,
                            quality: position.right.quality,
                            weight: position.weight * 0.5
                        )
                    )
                }
                return result
            }

        let combined = RoomCorrectionFrequencyResponse(
            frequenciesHz: aggregate.leftResponse.frequenciesHz,
            magnitudeDB: zip(
                aggregate.leftResponse.magnitudeDB,
                aggregate.rightResponse.magnitudeDB
            ).map { ($0 + $1) * 0.5 },
            phaseRadians: nil
        )
        return try generate(
            aggregate: combined,
            samples: samples,
            parameters: parameters,
            preference: preference
        )
    }

    func generate(
        samples: [IntelligentTargetEvidenceSample],
        parameters: RoomCorrectionDesignParameters,
        preference: IntelligentTargetPreference
    ) throws -> IntelligentTargetGenerationReport {
        guard let first = samples.first else {
            throw IntelligentTargetGenerationError.noEvidence
        }
        try validate(sample: first)
        let referenceFrequencies = first.response.frequenciesHz
        let totalWeight = samples.reduce(0.0) { partial, sample in
            partial + max(sample.weight, 0)
        }
        guard totalWeight.isFinite, totalWeight > 0 else {
            throw IntelligentTargetGenerationError.noEvidence
        }

        var aggregateMagnitude = [Double](
            repeating: 0,
            count: referenceFrequencies.count
        )
        for sample in samples {
            try validate(sample: sample)
            let normalizedWeight = max(sample.weight, 0) / totalWeight
            for index in referenceFrequencies.indices {
                let value = try Self.interpolate(
                    sample.response,
                    at: referenceFrequencies[index]
                )
                aggregateMagnitude[index] += value * normalizedWeight
            }
        }
        let aggregate = RoomCorrectionFrequencyResponse(
            frequenciesHz: referenceFrequencies,
            magnitudeDB: aggregateMagnitude,
            phaseRadians: nil
        )
        return try generate(
            aggregate: aggregate,
            samples: samples,
            parameters: parameters,
            preference: preference
        )
    }

    private func generate(
        aggregate: RoomCorrectionFrequencyResponse,
        samples: [IntelligentTargetEvidenceSample],
        parameters: RoomCorrectionDesignParameters,
        preference: IntelligentTargetPreference
    ) throws -> IntelligentTargetGenerationReport {
        guard parameters.correctionLowHz.isFinite,
              parameters.correctionHighHz.isFinite,
              parameters.correctionLowHz > 0,
              parameters.correctionHighHz > parameters.correctionLowHz,
              parameters.maximumBoostDB.isFinite,
              parameters.maximumBoostDB >= 0,
              parameters.maximumCutDB.isFinite,
              parameters.maximumCutDB >= 0 else {
            throw IntelligentTargetGenerationError.invalidParameters
        }
        guard !samples.isEmpty else {
            throw IntelligentTargetGenerationError.noEvidence
        }
        try RoomCorrectionTargetMath.validateResponse(aggregate)

        var usableLow = max(
            parameters.correctionLowHz,
            aggregate.frequenciesHz.first ?? parameters.correctionLowHz
        )
        var usableHigh = min(
            parameters.correctionHighHz,
            aggregate.frequenciesHz.last ?? parameters.correctionHighHz
        )
        for sample in samples {
            if let low = sample.quality.usableLowHz, low.isFinite {
                usableLow = max(usableLow, low)
            }
            if let high = sample.quality.usableHighHz, high.isFinite {
                usableHigh = min(usableHigh, high)
            }
        }
        guard usableHigh > usableLow else {
            throw IntelligentTargetGenerationError.noUsableBand
        }

        let smoothed = try smoother.smooth(
            aggregate,
            octaves: Self.analysisSmoothingOctaves
        )
        let referenceValues = zip(
            smoothed.frequenciesHz,
            smoothed.magnitudeDB
        )
        .filter {
            $0.0 >= max(Self.referenceBandLowHz, usableLow)
                && $0.0 <= min(Self.referenceBandHighHz, usableHigh)
        }
        .map(\.1)
        let referenceLevel = Self.median(
            referenceValues.isEmpty
                ? smoothed.magnitudeDB
                : referenceValues
        )

        let normalizedMagnitude = smoothed.magnitudeDB.map {
            $0 - referenceLevel
        }
        let normalized = RoomCorrectionFrequencyResponse(
            frequenciesHz: smoothed.frequenciesHz,
            magnitudeDB: normalizedMagnitude,
            phaseRadians: nil
        )

        let spatialDeviation = try meanSpatialDeviation(
            samples: samples,
            frequencies: normalized.frequenciesHz,
            low: usableLow,
            high: usableHigh
        )
        let confidence = measurementConfidence(
            samples: samples,
            low: usableLow,
            high: usableHigh,
            spatialDeviation: spatialDeviation
        )
        let fallback = confidence < Self.minimumConfidence
        var warnings: [String] = []
        var decisions: [String] = []
        if fallback {
            warnings.append(
                "Measurement confidence is below 70%; target aggressiveness was reduced."
            )
        }
        if spatialDeviation > 3.0 {
            warnings.append(
                "Listening-position variance is high; broad target shaping was reduced."
            )
        }

        let bassExtension = try estimateBassExtension(
            normalized: normalized,
            low: usableLow,
            high: usableHigh
        )
        if bassExtension > 80 {
            warnings.append(
                "Measured bass extension is limited; the generated low-frequency shelf was reduced."
            )
        }

        let bassTrend = try robustBandLevel(
            normalized,
            low: max(usableLow, 40),
            high: min(usableHigh, 160)
        ) ?? 0
        let support = Self.clamp(
            (120.0 - bassExtension) / 80.0,
            low: 0,
            high: 1
        )
        let varianceAggressiveness = Self.clamp(
            1.0 - max(spatialDeviation - 1.5, 0) / 8.0,
            low: 0.45,
            high: 1
        )
        let confidenceAggressiveness = 0.45 + 0.55 * confidence
        let measuredBassPrior = Self.clamp(
            bassTrend,
            low: 0,
            high: Self.maximumBassShelfDB
        )
        var bassShelf = (
            preference.nominalBassShelfDB * 0.75
                + measuredBassPrior * 0.25
        ) * support * varianceAggressiveness * confidenceAggressiveness
        if preference == .warm, support > 0.60, confidence >= 0.60 {
            bassShelf = max(bassShelf, 0.5)
        }
        bassShelf = Self.clamp(
            bassShelf,
            low: 0,
            high: Self.maximumBassShelfDB
        )

        let measuredTreble = try robustBandLevel(
            normalized,
            low: max(usableLow, 4_000),
            high: min(usableHigh, 12_000)
        ) ?? preference.nominalTrebleAt20KDB
        let measuredTrebleBounded = Self.clamp(
            measuredTreble,
            low: Self.minimumTrebleAt20KDB,
            high: Self.maximumTrebleAt20KDB
        )
        var trebleAt20K = (
            preference.nominalTrebleAt20KDB * 0.70
                + measuredTrebleBounded * 0.30
        )
        let tonalAggressiveness = varianceAggressiveness
            * confidenceAggressiveness
        trebleAt20K = Self.maximumTrebleAt20KDB
            + (
                trebleAt20K - Self.maximumTrebleAt20KDB
            ) * tonalAggressiveness
        trebleAt20K = Self.clamp(
            trebleAt20K,
            low: Self.minimumTrebleAt20KDB,
            high: Self.maximumTrebleAt20KDB
        )

        var anchors = [
            usableLow, 40, 80, 200, 300, 1_000, 4_000, 10_000, usableHigh,
        ]
        anchors = Array(
            Set(
                anchors
                    .filter { $0 >= usableLow && $0 <= usableHigh }
                    .map { ($0 * 1_000).rounded() / 1_000 }
            )
        ).sorted()
        if anchors.count < 2 {
            anchors = [usableLow, usableHigh]
        }

        var points: [RoomCorrectionTargetPoint] = []
        var maximumBoost = 0.0
        var maximumCut = 0.0
        for frequency in anchors {
            let desired = Self.desiredGainDB(
                frequency: frequency,
                bassShelfDB: bassShelf,
                trebleAt20KDB: trebleAt20K
            )
            let measured = try Self.interpolate(normalized, at: frequency)
            let minimumFeasible = measured - parameters.maximumCutDB
            let maximumFeasible = measured + parameters.maximumBoostDB
            let feasible = Self.clamp(
                desired,
                low: minimumFeasible,
                high: maximumFeasible
            )
            if abs(feasible - desired) > 0.05 {
                decisions.append(
                    "\(Self.frequencyLabel(frequency)) target was clamped from \(Self.db(desired)) to \(Self.db(feasible)) to respect correction limits."
                )
            }
            maximumBoost = max(maximumBoost, feasible - measured)
            maximumCut = max(maximumCut, measured - feasible)
            points.append(
                RoomCorrectionTargetPoint(
                    frequencyHz: frequency,
                    gainDB: feasible
                )
            )
        }

        // Keep the broad target itself perceptually bounded after feasibility
        // clamping. If a boundary cannot be met without exceeding correction
        // limits, move the effective boundary inward instead of inventing a
        // pathological target shape.
        while points.count > 2,
              let first = points.first,
              (first.gainDB < -0.5
                || first.gainDB > Self.maximumBassShelfDB + 0.5) {
            decisions.append(
                "Low-frequency target boundary moved upward because the measured response cannot reach a bounded target within configured correction limits."
            )
            points.removeFirst()
            usableLow = points[0].frequencyHz
        }
        while points.count > 2,
              let last = points.last,
              (last.gainDB < Self.minimumTrebleAt20KDB - 0.5
                || last.gainDB > 0.5) {
            decisions.append(
                "High-frequency target boundary moved downward because the measured response cannot reach a bounded target within configured correction limits."
            )
            points.removeLast()
            usableHigh = points[points.count - 1].frequencyHz
        }

        let target = RoomCorrectionTargetCurve(
            id: preference.stableTargetID,
            name: "Adaptive \(preference.displayName)",
            points: points
        )
        try RoomCorrectionTargetMath.validateTarget(target)

        if maximumBoost > parameters.maximumBoostDB + 0.001
            || maximumCut > parameters.maximumCutDB + 0.001 {
            warnings.append(
                "Generated target required safety clamping at one or more frequencies."
            )
        }

        return IntelligentTargetGenerationReport(
            preference: preference,
            target: target,
            confidence: confidence,
            referenceLevelDB: referenceLevel,
            estimatedBassExtensionHz: bassExtension,
            generatedBassShelfDB: bassShelf,
            generatedTrebleAt20KDB: trebleAt20K,
            effectiveLowHz: usableLow,
            effectiveHighHz: usableHigh,
            meanSpatialDeviationDB: spatialDeviation,
            maximumRequestedBoostDB: maximumBoost,
            maximumRequestedCutDB: maximumCut,
            fallbackUsed: fallback,
            clampDecisions: Self.unique(decisions),
            warnings: Self.unique(warnings)
        )
    }

    private func validate(
        sample: IntelligentTargetEvidenceSample
    ) throws {
        guard sample.weight.isFinite, sample.weight >= 0 else {
            throw IntelligentTargetGenerationError
                .invalidEvidence(sample.label)
        }
        do {
            try RoomCorrectionTargetMath.validateResponse(sample.response)
        } catch {
            throw IntelligentTargetGenerationError
                .invalidEvidence(sample.label)
        }
    }

    private func meanSpatialDeviation(
        samples: [IntelligentTargetEvidenceSample],
        frequencies: [Double],
        low: Double,
        high: Double
    ) throws -> Double {
        let selected = frequencies.filter { $0 >= low && $0 <= high }
        guard !selected.isEmpty else { return 0 }
        var deviations: [Double] = []
        for frequency in selected {
            var values: [(Double, Double)] = []
            for sample in samples where sample.weight > 0 {
                values.append(
                    (
                        try Self.interpolate(sample.response, at: frequency),
                        sample.weight
                    )
                )
            }
            let total = values.reduce(0) { $0 + $1.1 }
            guard total > 0 else { continue }
            let mean = values.reduce(0) {
                $0 + $1.0 * $1.1 / total
            }
            let variance = values.reduce(0) {
                $0 + pow($1.0 - mean, 2) * $1.1 / total
            }
            deviations.append(sqrt(max(variance, 0)))
        }
        return deviations.isEmpty
            ? 0
            : deviations.reduce(0, +) / Double(deviations.count)
    }

    private func measurementConfidence(
        samples: [IntelligentTargetEvidenceSample],
        low: Double,
        high: Double,
        spatialDeviation: Double
    ) -> Double {
        var weighted = 0.0
        var totalWeight = 0.0
        for sample in samples where sample.weight > 0 {
            let quality = sample.quality
            let base: Double
            if quality.clipped || !quality.sweepComplete {
                base = 0
            } else {
                let snr = quality.estimatedSNRDB.map {
                    Self.clamp(($0 - 20) / 30, low: 0, high: 1)
                } ?? 0.55
                let qLow = quality.usableLowHz ?? low
                let qHigh = quality.usableHighHz ?? high
                let requested = max(log2(high / low), 1.0e-9)
                let overlapLow = max(low, qLow)
                let overlapHigh = min(high, qHigh)
                let overlap = overlapHigh > overlapLow
                    ? log2(overlapHigh / overlapLow) : 0
                let coverage = Self.clamp(
                    overlap / requested,
                    low: 0,
                    high: 1
                )
                let arrival = quality.directArrivalSeconds == nil
                    ? 0.75 : 1.0
                base = 0.55 * snr + 0.35 * coverage + 0.10 * arrival
            }
            weighted += base * sample.weight
            totalWeight += sample.weight
        }
        guard totalWeight > 0 else { return 0 }
        let evidence = weighted / totalWeight
        let sampleFactor = min(
            1.0,
            0.85 + 0.025 * Double(max(samples.count - 1, 0))
        )
        let spatialFactor = Self.clamp(
            1.0 - max(spatialDeviation - 2.0, 0) / 12.0,
            low: 0.65,
            high: 1
        )
        return Self.clamp(
            evidence * sampleFactor * spatialFactor,
            low: 0,
            high: 1
        )
    }

    private func estimateBassExtension(
        normalized: RoomCorrectionFrequencyResponse,
        low: Double,
        high: Double
    ) throws -> Double {
        let upper = min(high, 200)
        let candidates = normalized.frequenciesHz.filter {
            $0 >= low && $0 <= upper
        }
        for frequency in candidates {
            let level = try Self.interpolate(normalized, at: frequency)
            if level >= Self.bassRollOffThresholdDB {
                return frequency
            }
        }
        return min(max(low, upper), high)
    }

    private func robustBandLevel(
        _ response: RoomCorrectionFrequencyResponse,
        low: Double,
        high: Double
    ) throws -> Double? {
        guard high > low else { return nil }
        let values = zip(
            response.frequenciesHz,
            response.magnitudeDB
        )
        .filter { $0.0 >= low && $0.0 <= high }
        .map(\.1)
        guard !values.isEmpty else { return nil }
        return Self.median(values)
    }

    private static func desiredGainDB(
        frequency: Double,
        bassShelfDB: Double,
        trebleAt20KDB: Double
    ) -> Double {
        if frequency <= 80 {
            return bassShelfDB
        }
        if frequency < 300 {
            let fraction = log(frequency / 80) / log(300.0 / 80.0)
            return bassShelfDB * (1 - clamp(fraction, low: 0, high: 1))
        }
        if frequency <= 1_000 {
            return 0
        }
        let fraction = log(frequency / 1_000)
            / log(20_000.0 / 1_000.0)
        return trebleAt20KDB * clamp(fraction, low: 0, high: 1)
    }

    private static func interpolate(
        _ response: RoomCorrectionFrequencyResponse,
        at frequency: Double
    ) throws -> Double {
        let frequencies = response.frequenciesHz
        let values = response.magnitudeDB
        guard frequencies.count == values.count,
              frequencies.count >= 2,
              frequency.isFinite,
              frequency > 0 else {
            throw IntelligentTargetGenerationError
                .invalidEvidence("frequency response")
        }
        if frequency <= frequencies[0] { return values[0] }
        if frequency >= frequencies[frequencies.count - 1] {
            return values[values.count - 1]
        }
        var low = 0
        var high = frequencies.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if frequencies[middle] <= frequency {
                low = middle
            } else {
                high = middle
            }
        }
        let denominator = log(frequencies[high] / frequencies[low])
        guard denominator > 0 else { return values[low] }
        let fraction = log(frequency / frequencies[low]) / denominator
        return values[low] + (values[high] - values[low]) * fraction
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) * 0.5
        }
        return sorted[middle]
    }

    private static func clamp(
        _ value: Double,
        low: Double,
        high: Double
    ) -> Double {
        min(max(value, low), high)
    }

    private static func db(_ value: Double) -> String {
        String(format: "%.2f dB", value)
    }

    private static func frequencyLabel(_ value: Double) -> String {
        if value >= 1_000 {
            return String(format: "%.1f kHz", value / 1_000)
        }
        return String(format: "%.0f Hz", value)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

struct RoomCorrectionCorrectionPreview: Equatable, Sendable {
    var targetResponse: RoomCorrectionFrequencyResponse
    var smoothedLeftResponse: RoomCorrectionFrequencyResponse
    var smoothedRightResponse: RoomCorrectionFrequencyResponse
    var leftCorrectionResponse: RoomCorrectionFrequencyResponse
    var rightCorrectionResponse: RoomCorrectionFrequencyResponse
    var effectiveCorrectionLowHz: Double
    var effectiveCorrectionHighHz: Double
    var maximumPositiveCorrectionDB: Double
    var estimatedHeadroomDB: Double
}

struct RoomCorrectionCorrectionPreviewDesigner: Sendable {
    static let narrowNullProtectionStartDB = 6.0
    static let edgeTaperOctaves = 1.0 / 6.0

    private let smoother = RoomCorrectionMagnitudeSmoother()

    func preview(
        aggregate: RoomCorrectionAggregateResponse,
        target: RoomCorrectionTargetCurve,
        parameters: RoomCorrectionDesignParameters,
        usableLowHz: Double? = nil,
        usableHighHz: Double? = nil
    ) throws -> RoomCorrectionCorrectionPreview {
        try RoomCorrectionTargetMath.validateResponse(aggregate.leftResponse)
        try RoomCorrectionTargetMath.validateResponse(aggregate.rightResponse)
        guard RoomCorrectionTargetMath.frequencyGridsMatch(
            aggregate.leftResponse.frequenciesHz,
            aggregate.rightResponse.frequenciesHz
        ) else {
            throw RoomCorrectionTargetDesignError.mismatchedResponseGrid
        }
        try RoomCorrectionTargetMath.validateTarget(target)
        try validateParameters(parameters)

        let frequencies = aggregate.leftResponse.frequenciesHz
        guard let firstFrequency = frequencies.first, let lastFrequency = frequencies.last else {
            throw RoomCorrectionTargetDesignError.invalidResponse
        }
        let measuredLow = usableLowHz ?? firstFrequency
        let measuredHigh = usableHighHz ?? lastFrequency
        guard measuredLow.isFinite, measuredLow > 0,
              measuredHigh.isFinite, measuredHigh > measuredLow else {
            throw RoomCorrectionTargetDesignError.invalidUsableRange(
                low: measuredLow,
                high: measuredHigh
            )
        }

        let effectiveLow = max(max(parameters.correctionLowHz, measuredLow), firstFrequency)
        let effectiveHigh = min(min(parameters.correctionHighHz, measuredHigh), lastFrequency)
        guard effectiveHigh > effectiveLow else {
            throw RoomCorrectionTargetDesignError.noUsableCorrectionRange
        }

        let smoothedLeft = try smoother.smooth(
            aggregate.leftResponse,
            octaves: parameters.smoothingOctaves
        )
        let smoothedRight = try smoother.smooth(
            aggregate.rightResponse,
            octaves: parameters.smoothingOctaves
        )
        var targetMagnitudes = [Double](repeating: 0, count: frequencies.count)
        for index in frequencies.indices {
            targetMagnitudes[index] = try target.interpolatedGainDB(at: frequencies[index])
        }
        let targetResponse = RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: targetMagnitudes,
            phaseRadians: nil
        )

        let leftCorrection = makeCorrection(
            raw: aggregate.leftResponse,
            smoothed: smoothedLeft,
            target: targetResponse,
            parameters: parameters,
            effectiveLow: effectiveLow,
            effectiveHigh: effectiveHigh
        )
        let rightCorrection = makeCorrection(
            raw: aggregate.rightResponse,
            smoothed: smoothedRight,
            target: targetResponse,
            parameters: parameters,
            effectiveLow: effectiveLow,
            effectiveHigh: effectiveHigh
        )
        let maximumPositive = max(
            max(
                leftCorrection.magnitudeDB.max() ?? 0,
                rightCorrection.magnitudeDB.max() ?? 0
            ),
            0
        )
        let estimatedHeadroom = maximumPositive > 0
            ? ceil((maximumPositive + 0.25) * 2.0) / 2.0
            : 0

        return RoomCorrectionCorrectionPreview(
            targetResponse: targetResponse,
            smoothedLeftResponse: smoothedLeft,
            smoothedRightResponse: smoothedRight,
            leftCorrectionResponse: leftCorrection,
            rightCorrectionResponse: rightCorrection,
            effectiveCorrectionLowHz: effectiveLow,
            effectiveCorrectionHighHz: effectiveHigh,
            maximumPositiveCorrectionDB: maximumPositive,
            estimatedHeadroomDB: estimatedHeadroom
        )
    }

    private func validateParameters(_ parameters: RoomCorrectionDesignParameters) throws {
        guard parameters.correctionLowHz.isFinite,
              parameters.correctionHighHz.isFinite,
              parameters.correctionLowHz > 0,
              parameters.correctionHighHz > parameters.correctionLowHz else {
            throw RoomCorrectionTargetDesignError.invalidCorrectionRange(
                low: parameters.correctionLowHz,
                high: parameters.correctionHighHz
            )
        }
        guard parameters.smoothingOctaves.isFinite, parameters.smoothingOctaves >= 0 else {
            throw RoomCorrectionTargetDesignError.invalidSmoothing(parameters.smoothingOctaves)
        }
        guard parameters.maximumBoostDB.isFinite, parameters.maximumBoostDB >= 0 else {
            throw RoomCorrectionTargetDesignError.invalidMaximumBoost(parameters.maximumBoostDB)
        }
        guard parameters.maximumCutDB.isFinite, parameters.maximumCutDB >= 0 else {
            throw RoomCorrectionTargetDesignError.invalidMaximumCut(parameters.maximumCutDB)
        }
        guard parameters.requestedTapCount > 0,
              parameters.requestedTapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionTargetDesignError.invalidTapCount(parameters.requestedTapCount)
        }
    }

    private func makeCorrection(
        raw: RoomCorrectionFrequencyResponse,
        smoothed: RoomCorrectionFrequencyResponse,
        target: RoomCorrectionFrequencyResponse,
        parameters: RoomCorrectionDesignParameters,
        effectiveLow: Double,
        effectiveHigh: Double
    ) -> RoomCorrectionFrequencyResponse {
        var correction = [Double](repeating: 0, count: raw.magnitudeDB.count)
        for index in raw.frequenciesHz.indices {
            let frequency = raw.frequenciesHz[index]
            guard frequency >= effectiveLow, frequency <= effectiveHigh else { continue }

            var requested = target.magnitudeDB[index] - smoothed.magnitudeDB[index]
            requested = min(max(requested, -parameters.maximumCutDB), parameters.maximumBoostDB)

            if requested > 0 {
                let narrowNullDepth = max(
                    0,
                    smoothed.magnitudeDB[index] - raw.magnitudeDB[index]
                )
                if narrowNullDepth > Self.narrowNullProtectionStartDB {
                    let protectedBoost = max(
                        0,
                        parameters.maximumBoostDB
                            - (narrowNullDepth - Self.narrowNullProtectionStartDB)
                    )
                    requested = min(requested, protectedBoost)
                }
            }

            correction[index] = requested * edgeTaper(
                frequency: frequency,
                low: effectiveLow,
                high: effectiveHigh
            )
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: raw.frequenciesHz,
            magnitudeDB: correction,
            phaseRadians: nil
        )
    }

    private func edgeTaper(frequency: Double, low: Double, high: Double) -> Double {
        guard frequency > low, frequency < high else { return 0 }
        let totalOctaves = log2(high / low)
        let taperWidth = min(Self.edgeTaperOctaves, max(totalOctaves * 0.25, 1.0e-9))
        let distance = min(log2(frequency / low), log2(high / frequency))
        guard distance < taperWidth else { return 1 }
        let normalized = min(max(distance / taperWidth, 0), 1)
        return 0.5 - 0.5 * cos(Double.pi * normalized)
    }
}

private enum RoomCorrectionTargetMath {
    static func validateTarget(_ target: RoomCorrectionTargetCurve) throws {
        guard target.points.count >= 2 else {
            throw RoomCorrectionTargetDesignError.insufficientTargetPoints
        }
        var previous = 0.0
        for point in target.points {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz > previous,
                  point.gainDB.isFinite else {
                throw RoomCorrectionTargetDesignError.invalidTargetCurve
            }
            previous = point.frequencyHz
        }
    }

    static func validateResponse(_ response: RoomCorrectionFrequencyResponse) throws {
        guard !response.frequenciesHz.isEmpty,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.phaseRadians == nil || response.phaseRadians?.count == response.frequenciesHz.count else {
            throw RoomCorrectionTargetDesignError.invalidResponse
        }
        var previous = 0.0
        for index in response.frequenciesHz.indices {
            let frequency = response.frequenciesHz[index]
            guard frequency.isFinite,
                  frequency > previous,
                  response.magnitudeDB[index].isFinite else {
                throw RoomCorrectionTargetDesignError.invalidResponse
            }
            if let phase = response.phaseRadians, !phase[index].isFinite {
                throw RoomCorrectionTargetDesignError.invalidResponse
            }
            previous = frequency
        }
    }

    static func frequencyGridsMatch(_ lhs: [Double], _ rhs: [Double]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in lhs.indices {
            let tolerance = max(1.0e-6, abs(lhs[index]) * 1.0e-9)
            if abs(lhs[index] - rhs[index]) > tolerance { return false }
        }
        return true
    }
}
