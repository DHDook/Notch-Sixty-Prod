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

        let effectiveLow = max(parameters.correctionLowHz, measuredLow, firstFrequency)
        let effectiveHigh = min(parameters.correctionHighHz, measuredHigh, lastFrequency)
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
            leftCorrection.magnitudeDB.max() ?? 0,
            rightCorrection.magnitudeDB.max() ?? 0,
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
