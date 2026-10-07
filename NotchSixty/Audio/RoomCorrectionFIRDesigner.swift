import Accelerate
import Foundation

enum RoomCorrectionFIRDesignError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case correctionRangeExceedsNyquist(high: Double, nyquist: Double)
    case aggregateFrequencyExceedsNyquist(Double)
    case transformTooLarge(required: Int)
    case transformSetupFailed(Int)
    case nonFiniteFilter
    case nonFiniteResponse
    case invalidDeploymentHeadroom(Double)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let sampleRate):
            return "Room-correction FIR sample rate \(sampleRate) Hz is invalid."
        case .correctionRangeExceedsNyquist(let high, let nyquist):
            return "Room-correction high frequency \(high) Hz must remain below the \(nyquist) Hz Nyquist frequency."
        case .aggregateFrequencyExceedsNyquist(let frequency):
            return "Aggregate room response frequency \(frequency) Hz exceeds the output Nyquist frequency."
        case .transformTooLarge(let required):
            return "Room-correction FIR design requires a transform larger than the supported \(required)-frame request."
        case .transformSetupFailed(let size):
            return "Could not prepare the \(size)-point room-correction FIR transform."
        case .nonFiniteFilter:
            return "Generated room-correction FIR taps are non-finite."
        case .nonFiniteResponse:
            return "Generated room-correction FIR response is non-finite."
        case .invalidDeploymentHeadroom(let headroom):
            return "Room-correction deployment headroom \(headroom) dB is invalid."
        }
    }
}

struct RoomCorrectionFIRDesignResult: Equatable, Sendable {
    var design: RoomCorrectionDesign
    var leftFilterResponse: RoomCorrectionFrequencyResponse
    var rightFilterResponse: RoomCorrectionFrequencyResponse
    var maximumPositiveFilterGainDB: Double
}

/// Offline magnitude-focused room-correction FIR synthesis.
///
/// The desired correction magnitude is converted to a causal minimum-phase
/// response with a real-cepstrum construction. Large transform buffers are
/// owned only by this control-plane operation; the realtime graph receives the
/// finished `RoomCorrectionFilter` through its existing program lifecycle.
struct RoomCorrectionFIRDesigner: Sendable {
    static let algorithmVersion = "n60-room-minphase-v1"
    static let minimumTransformSize = 4_096
    static let maximumTransformSize = Int(N60_CONVOLUTION_MAX_TAPS) * 2

    private let previewDesigner = RoomCorrectionCorrectionPreviewDesigner()

    func design(
        aggregate: RoomCorrectionAggregateResponse,
        target: RoomCorrectionTargetCurve,
        parameters: RoomCorrectionDesignParameters,
        sampleRate: Double,
        usableLowHz: Double? = nil,
        usableHighHz: Double? = nil,
        sourcePositions: [RoomCorrectionDesignSourcePosition]? = nil,
        name proposedName: String = "Room Correction",
        createdAt: Date = Date(),
        id: UUID = UUID()
    ) throws -> RoomCorrectionFIRDesignResult {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw RoomCorrectionFIRDesignError.invalidSampleRate(sampleRate)
        }
        let nyquist = sampleRate * 0.5
        guard parameters.correctionHighHz < nyquist else {
            throw RoomCorrectionFIRDesignError.correctionRangeExceedsNyquist(
                high: parameters.correctionHighHz,
                nyquist: nyquist
            )
        }
        for frequency in aggregate.leftResponse.frequenciesHz + aggregate.rightResponse.frequenciesHz {
            guard frequency < nyquist else {
                throw RoomCorrectionFIRDesignError.aggregateFrequencyExceedsNyquist(frequency)
            }
        }

        let preview = try previewDesigner.preview(
            aggregate: aggregate,
            target: target,
            parameters: parameters,
            usableLowHz: usableLowHz,
            usableHighHz: usableHighHz
        )
        let transformSize = try Self.transformSize(forTapCount: parameters.requestedTapCount)
        let transform = try RoomCorrectionFIRDFT(size: transformSize)

        let leftSynthesis = try synthesize(
            desiredCorrection: preview.leftCorrectionResponse,
            effectiveLowHz: preview.effectiveCorrectionLowHz,
            effectiveHighHz: preview.effectiveCorrectionHighHz,
            sampleRate: sampleRate,
            tapCount: parameters.requestedTapCount,
            transform: transform
        )
        let rightSynthesis = try synthesize(
            desiredCorrection: preview.rightCorrectionResponse,
            effectiveLowHz: preview.effectiveCorrectionLowHz,
            effectiveHighHz: preview.effectiveCorrectionHighHz,
            sampleRate: sampleRate,
            tapCount: parameters.requestedTapCount,
            transform: transform
        )

        let leftFilterResponse = try response(
            spectrum: leftSynthesis.spectrum,
            frequenciesHz: aggregate.leftResponse.frequenciesHz,
            sampleRate: sampleRate
        )
        let rightFilterResponse = try response(
            spectrum: rightSynthesis.spectrum,
            frequenciesHz: aggregate.rightResponse.frequenciesHz,
            sampleRate: sampleRate
        )
        let maximumPositive = max(
            maximumPositiveGainDB(leftSynthesis.spectrum),
            maximumPositiveGainDB(rightSynthesis.spectrum)
        )
        guard maximumPositive.isFinite else {
            throw RoomCorrectionFIRDesignError.nonFiniteResponse
        }
        let recommendedHeadroom = maximumPositive > 0
            ? ceil((maximumPositive + 0.25) * 2.0) / 2.0
            : 0

        let leftPredicted = try predictedResponse(
            measured: aggregate.leftResponse,
            filter: leftFilterResponse
        )
        let rightPredicted = try predictedResponse(
            measured: aggregate.rightResponse,
            filter: rightFilterResponse
        )
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "Room Correction" : trimmedName
        let filter = RoomCorrectionFilter(
            name: name,
            sampleRate: sampleRate,
            leftTaps: leftSynthesis.taps,
            rightTaps: rightSynthesis.taps,
            declaredLatencyFrames: 0
        )
        let design = RoomCorrectionDesign(
            id: id,
            name: name,
            createdAt: createdAt,
            sampleRate: sampleRate,
            parameters: parameters,
            target: target,
            sourcePositions: sourcePositions,
            effectiveCorrectionLowHz: preview.effectiveCorrectionLowHz,
            effectiveCorrectionHighHz: preview.effectiveCorrectionHighHz,
            filter: filter,
            predictedLeftResponse: leftPredicted,
            predictedRightResponse: rightPredicted,
            recommendedHeadroomDB: recommendedHeadroom,
            algorithmVersion: Self.algorithmVersion
        )
        return RoomCorrectionFIRDesignResult(
            design: design,
            leftFilterResponse: leftFilterResponse,
            rightFilterResponse: rightFilterResponse,
            maximumPositiveFilterGainDB: maximumPositive
        )
    }

    private func synthesize(
        desiredCorrection: RoomCorrectionFrequencyResponse,
        effectiveLowHz: Double,
        effectiveHighHz: Double,
        sampleRate: Double,
        tapCount: Int,
        transform: RoomCorrectionFIRDFT
    ) throws -> (taps: [Float], spectrum: RoomCorrectionFIRSpectrum) {
        let size = transform.size
        let half = size / 2
        var logMagnitude = [Float](repeating: 0, count: size)
        let naturalLogPerDB = log(10.0) / 20.0

        for bin in 0...half {
            let frequency = Double(bin) * sampleRate / Double(size)
            let gainDB = desiredCorrectionDB(
                at: frequency,
                response: desiredCorrection,
                low: effectiveLowHz,
                high: effectiveHighHz
            )
            let value = gainDB * naturalLogPerDB
            guard value.isFinite else { throw RoomCorrectionFIRDesignError.nonFiniteResponse }
            logMagnitude[bin] = Float(value)
            if bin > 0, bin < half {
                logMagnitude[size - bin] = Float(value)
            }
        }

        let zeroImaginary = [Float](repeating: 0, count: size)
        let cepstrum = transform.inverse(real: logMagnitude, imaginary: zeroImaginary)
        var minimumPhaseCepstrum = [Float](repeating: 0, count: size)
        minimumPhaseCepstrum[0] = cepstrum[0]
        if half > 1 {
            for index in 1..<half {
                minimumPhaseCepstrum[index] = 2 * cepstrum[index]
            }
        }
        minimumPhaseCepstrum[half] = cepstrum[half]

        let complexLogSpectrum = transform.forward(minimumPhaseCepstrum)
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        for index in 0..<size {
            let amplitude = exp(Double(complexLogSpectrum.real[index]))
            let phase = Double(complexLogSpectrum.imaginary[index])
            let realValue = amplitude * cos(phase)
            let imaginaryValue = amplitude * sin(phase)
            guard realValue.isFinite, imaginaryValue.isFinite,
                  abs(realValue) <= Double(Float.greatestFiniteMagnitude),
                  abs(imaginaryValue) <= Double(Float.greatestFiniteMagnitude) else {
                throw RoomCorrectionFIRDesignError.nonFiniteResponse
            }
            real[index] = Float(realValue)
            imaginary[index] = Float(imaginaryValue)
        }

        let impulse = transform.inverse(real: real, imaginary: imaginary)
        let taps = Array(impulse.prefix(tapCount))
        guard taps.count == tapCount, taps.allSatisfy(\.isFinite) else {
            throw RoomCorrectionFIRDesignError.nonFiniteFilter
        }
        let actualSpectrum = transform.forward(taps)
        guard actualSpectrum.real.allSatisfy(\.isFinite),
              actualSpectrum.imaginary.allSatisfy(\.isFinite) else {
            throw RoomCorrectionFIRDesignError.nonFiniteResponse
        }
        return (taps, actualSpectrum)
    }

    private func desiredCorrectionDB(
        at frequencyHz: Double,
        response: RoomCorrectionFrequencyResponse,
        low: Double,
        high: Double
    ) -> Double {
        guard frequencyHz > low, frequencyHz < high,
              frequencyHz > 0,
              let first = response.frequenciesHz.first,
              let last = response.frequenciesHz.last,
              frequencyHz >= first,
              frequencyHz <= last else {
            return 0
        }
        if frequencyHz == first { return response.magnitudeDB[0] }
        if frequencyHz == last { return response.magnitudeDB[response.magnitudeDB.count - 1] }

        var upperIndex = 1
        while upperIndex < response.frequenciesHz.count,
              response.frequenciesHz[upperIndex] < frequencyHz {
            upperIndex += 1
        }
        guard upperIndex < response.frequenciesHz.count else { return 0 }
        let lowerIndex = upperIndex - 1
        let lowerFrequency = response.frequenciesHz[lowerIndex]
        let upperFrequency = response.frequenciesHz[upperIndex]
        let denominator = log(upperFrequency) - log(lowerFrequency)
        guard denominator > 0 else { return response.magnitudeDB[lowerIndex] }
        let fraction = (log(frequencyHz) - log(lowerFrequency)) / denominator
        return response.magnitudeDB[lowerIndex]
            + fraction * (response.magnitudeDB[upperIndex] - response.magnitudeDB[lowerIndex])
    }

    private func response(
        spectrum: RoomCorrectionFIRSpectrum,
        frequenciesHz: [Double],
        sampleRate: Double
    ) throws -> RoomCorrectionFrequencyResponse {
        var magnitudeDB = [Double]()
        magnitudeDB.reserveCapacity(frequenciesHz.count)
        for frequency in frequenciesHz {
            let bin = frequency / sampleRate * Double(spectrum.real.count)
            let lower = max(0, min(Int(floor(bin)), spectrum.real.count / 2))
            let upper = min(lower + 1, spectrum.real.count / 2)
            let fraction = max(0, min(bin - Double(lower), 1))
            let lowerMagnitude = hypot(
                Double(spectrum.real[lower]),
                Double(spectrum.imaginary[lower])
            )
            let upperMagnitude = hypot(
                Double(spectrum.real[upper]),
                Double(spectrum.imaginary[upper])
            )
            let magnitude = lowerMagnitude + fraction * (upperMagnitude - lowerMagnitude)
            let db = 20.0 * log10(max(magnitude, 1.0e-12))
            guard db.isFinite else { throw RoomCorrectionFIRDesignError.nonFiniteResponse }
            magnitudeDB.append(db)
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: frequenciesHz,
            magnitudeDB: magnitudeDB,
            phaseRadians: nil
        )
    }

    private func predictedResponse(
        measured: RoomCorrectionFrequencyResponse,
        filter: RoomCorrectionFrequencyResponse
    ) throws -> RoomCorrectionFrequencyResponse {
        guard measured.frequenciesHz == filter.frequenciesHz,
              measured.magnitudeDB.count == filter.magnitudeDB.count else {
            throw RoomCorrectionFIRDesignError.nonFiniteResponse
        }
        var magnitudes = [Double](repeating: 0, count: measured.magnitudeDB.count)
        for index in magnitudes.indices {
            let value = measured.magnitudeDB[index] + filter.magnitudeDB[index]
            guard value.isFinite else { throw RoomCorrectionFIRDesignError.nonFiniteResponse }
            magnitudes[index] = value
        }
        return RoomCorrectionFrequencyResponse(
            frequenciesHz: measured.frequenciesHz,
            magnitudeDB: magnitudes,
            phaseRadians: nil
        )
    }

    private func maximumPositiveGainDB(_ spectrum: RoomCorrectionFIRSpectrum) -> Double {
        var maximum = 0.0
        let half = spectrum.real.count / 2
        for index in 0...half {
            let magnitude = hypot(
                Double(spectrum.real[index]),
                Double(spectrum.imaginary[index])
            )
            guard magnitude.isFinite, magnitude > 0 else { continue }
            maximum = max(maximum, 20.0 * log10(magnitude))
        }
        return maximum
    }

    private static func transformSize(forTapCount tapCount: Int) throws -> Int {
        guard tapCount > 0, tapCount <= Int(N60_CONVOLUTION_MAX_TAPS) else {
            throw RoomCorrectionTargetDesignError.invalidTapCount(tapCount)
        }
        let required = max(minimumTransformSize, tapCount * 2)
        guard required <= maximumTransformSize else {
            throw RoomCorrectionFIRDesignError.transformTooLarge(required: required)
        }
        var size = 1
        while size < required { size <<= 1 }
        guard size <= maximumTransformSize else {
            throw RoomCorrectionFIRDesignError.transformTooLarge(required: required)
        }
        return size
    }
}

extension RoomCorrectionDesign {
    /// Returns the exact filter deployed to the Playback System. The sidecar
    /// design remains unscaled for reproducibility; deployment embeds the
    /// design's explicit safety headroom in the room-owned FIR rather than
    /// mutating Content Preset headroom.
    func deploymentFilter() throws -> RoomCorrectionFilter {
        guard recommendedHeadroomDB.isFinite, recommendedHeadroomDB >= 0 else {
            throw RoomCorrectionFIRDesignError.invalidDeploymentHeadroom(recommendedHeadroomDB)
        }
        let scale = pow(10.0, -recommendedHeadroomDB / 20.0)
        guard scale.isFinite, scale > 0, scale <= 1 else {
            throw RoomCorrectionFIRDesignError.invalidDeploymentHeadroom(recommendedHeadroomDB)
        }
        func scaled(_ taps: [Float]) throws -> [Float] {
            let output = taps.map { Float(Double($0) * scale) }
            guard output.allSatisfy(\.isFinite) else {
                throw RoomCorrectionFIRDesignError.nonFiniteFilter
            }
            return output
        }
        return RoomCorrectionFilter(
            name: filter.name,
            sampleRate: filter.sampleRate,
            leftTaps: try scaled(filter.leftTaps),
            rightTaps: try filter.rightTaps.map(scaled),
            declaredLatencyFrames: filter.declaredLatencyFrames
        )
    }
}

private struct RoomCorrectionFIRSpectrum {
    var real: [Float]
    var imaginary: [Float]
}

private final class RoomCorrectionFIRDFT {
    let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let zeroImaginary: [Float]

    init(size: Int) throws {
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            throw RoomCorrectionFIRDesignError.transformSetupFailed(size)
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw RoomCorrectionFIRDesignError.transformSetupFailed(size)
        }
        self.size = size
        forwardSetup = forward
        inverseSetup = inverse
        zeroImaginary = [Float](repeating: 0, count: size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(_ source: [Float]) -> RoomCorrectionFIRSpectrum {
        precondition(source.count <= size)
        var padded = [Float](repeating: 0, count: size)
        for index in source.indices { padded[index] = source[index] }
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        padded.withUnsafeBufferPointer { inputReal in
            zeroImaginary.withUnsafeBufferPointer { inputImaginary in
                real.withUnsafeMutableBufferPointer { outputReal in
                    imaginary.withUnsafeMutableBufferPointer { outputImaginary in
                        vDSP_DFT_Execute(
                            forwardSetup,
                            inputReal.baseAddress!,
                            inputImaginary.baseAddress!,
                            outputReal.baseAddress!,
                            outputImaginary.baseAddress!
                        )
                    }
                }
            }
        }
        return RoomCorrectionFIRSpectrum(real: real, imaginary: imaginary)
    }

    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        precondition(real.count == size && imaginary.count == size)
        var outputReal = [Float](repeating: 0, count: size)
        var outputImaginary = [Float](repeating: 0, count: size)
        real.withUnsafeBufferPointer { inputReal in
            imaginary.withUnsafeBufferPointer { inputImaginary in
                outputReal.withUnsafeMutableBufferPointer { resultReal in
                    outputImaginary.withUnsafeMutableBufferPointer { resultImaginary in
                        vDSP_DFT_Execute(
                            inverseSetup,
                            inputReal.baseAddress!,
                            inputImaginary.baseAddress!,
                            resultReal.baseAddress!,
                            resultImaginary.baseAddress!
                        )
                    }
                }
            }
        }
        let scale = 1.0 / Float(size)
        for index in outputReal.indices { outputReal[index] *= scale }
        return outputReal
    }
}


// MARK: - PR86 independent room-correction deployment verification

struct RoomCorrectionDesignVerificationPositionReport: Equatable, Sendable {
    var positionID: UUID
    var positionName: String
    var rmsErrorBeforeDB: Double
    var rmsErrorAfterDB: Double
    var improvementDB: Double
    var maximumAbsoluteErrorAfterDB: Double
    var stereoMismatchBeforeDB: Double
    var stereoMismatchAfterDB: Double
    var confidence: Double
}

struct RoomCorrectionDesignVerificationReport: Equatable, Sendable {
    var designID: UUID
    var confidence: Double
    var rmsErrorBeforeDB: Double
    var rmsErrorAfterDB: Double
    var improvementDB: Double
    var maximumAbsoluteErrorAfterDB: Double
    var worstPositionRegressionDB: Double
    var stereoMismatchBeforeDB: Double
    var stereoMismatchAfterDB: Double
    var maximumUnscaledFilterGainDB: Double
    var maximumDeploymentFilterGainDB: Double
    var maximumOutOfBandDeviationDB: Double
    var storedPredictionDisagreementDB: Double?
    var positionReports: [RoomCorrectionDesignVerificationPositionReport]
    var blockingReasons: [String]
    var warnings: [String]

    var accepted: Bool { blockingReasons.isEmpty }
}

enum RoomCorrectionDesignVerificationError: Error, Equatable, LocalizedError {
    case invalidDesign
    case noSourcePositions
    case sourcePositionMissing(UUID)
    case invalidMeasurement(UUID)
    case invalidCorrectionBand
    case invalidFilter

    var errorDescription: String? {
        switch self {
        case .invalidDesign:
            return "Room-correction verification found invalid design metadata."
        case .noSourcePositions:
            return "Room-correction verification requires the measurements used to create the design."
        case .sourcePositionMissing(let id):
            return "Room-correction verification cannot find source measurement \(id.uuidString)."
        case .invalidMeasurement(let id):
            return "Room-correction verification found invalid response data for \(id.uuidString)."
        case .invalidCorrectionBand:
            return "Room-correction verification found an invalid effective correction range."
        case .invalidFilter:
            return "Room-correction verification found invalid or non-finite FIR data."
        }
    }
}

/// Recomputes the response of the exact FIR taps that will be deployed and
/// applies those responses independently to every source listening position.
/// The designer's stored predicted responses are used only as cross-check
/// evidence, never as the verification source of truth.
struct RoomCorrectionDesignPredictionVerifier: Sendable {
    static let gridPointCount = 128
    static let filterAuditPointCount = 512
    static let minimumConfidence = 0.70
    static let minimumMeaningfulImprovementDB = 0.25
    static let excellentResidualDB = 0.75
    static let maximumPositionRegressionDB = 0.75
    static let maximumAbsoluteResidualDB = 12.0
    static let maximumStereoMismatchRegressionDB = 0.50
    static let maximumOutOfBandDeviationDB = 1.0
    static let maximumStoredPredictionDisagreementDB = 0.75
    static let headroomToleranceDB = 0.10

    func verify(
        design: RoomCorrectionDesign,
        positions: [RoomCorrectionMeasurementPosition]
    ) throws -> RoomCorrectionDesignVerificationReport {
        guard design.sampleRate.isFinite,
              design.sampleRate > 0,
              design.recommendedHeadroomDB.isFinite,
              design.recommendedHeadroomDB >= 0 else {
            throw RoomCorrectionDesignVerificationError.invalidDesign
        }
        let low = design.effectiveCorrectionLowHz
            ?? design.parameters.correctionLowHz
        let high = design.effectiveCorrectionHighHz
            ?? design.parameters.correctionHighHz
        guard low.isFinite, high.isFinite,
              low > 0, high > low,
              high < design.sampleRate * 0.5 else {
            throw RoomCorrectionDesignVerificationError.invalidCorrectionBand
        }

        let sourcePositions = design.sourcePositions
            ?? positions.filter { $0.included && $0.weight > 0 }.map {
                RoomCorrectionDesignSourcePosition(id: $0.id, weight: $0.weight)
            }
        guard !sourcePositions.isEmpty else {
            throw RoomCorrectionDesignVerificationError.noSourcePositions
        }

        let unscaledLeft = design.filter.leftTaps
        let unscaledRight = design.filter.rightTaps ?? unscaledLeft
        guard !unscaledLeft.isEmpty, !unscaledRight.isEmpty,
              unscaledLeft.allSatisfy(\.isFinite),
              unscaledRight.allSatisfy(\.isFinite),
              abs(design.filter.sampleRate - design.sampleRate) < 0.5 else {
            throw RoomCorrectionDesignVerificationError.invalidFilter
        }
        let deployed = try design.deploymentFilter()
        let deployedLeft = deployed.leftTaps
        let deployedRight = deployed.rightTaps ?? deployedLeft

        let grid = Self.logGrid(
            low: low,
            high: high,
            count: Self.gridPointCount
        )
        let leftDeployGain = try Self.firMagnitudeDB(
            taps: deployedLeft,
            frequencies: grid,
            sampleRate: design.sampleRate
        )
        let rightDeployGain = try Self.firMagnitudeDB(
            taps: deployedRight,
            frequencies: grid,
            sampleRate: design.sampleRate
        )
        let target = design.target ?? RoomCorrectionBuiltInTarget.flat.curve

        var reports: [RoomCorrectionDesignVerificationPositionReport] = []
        var beforeSquares = 0.0
        var afterSquares = 0.0
        var mismatchBeforeSquares = 0.0
        var mismatchAfterSquares = 0.0
        var totalWeight = 0.0
        var confidenceWeighted = 0.0
        var maximumResidual = 0.0
        var worstRegression = 0.0
        var blocking: [String] = []
        var warnings: [String] = []

        for source in sourcePositions {
            guard source.weight.isFinite, source.weight > 0,
                  let position = positions.first(where: { $0.id == source.id }) else {
                throw RoomCorrectionDesignVerificationError
                    .sourcePositionMissing(source.id)
            }
            let evaluated = try evaluatePosition(
                position,
                target: target,
                frequencies: grid,
                leftFilterGainDB: leftDeployGain,
                rightFilterGainDB: rightDeployGain
            )
            let weight = source.weight
            reports.append(
                RoomCorrectionDesignVerificationPositionReport(
                    positionID: position.id,
                    positionName: position.name,
                    rmsErrorBeforeDB: evaluated.rmsBefore,
                    rmsErrorAfterDB: evaluated.rmsAfter,
                    improvementDB: evaluated.rmsBefore - evaluated.rmsAfter,
                    maximumAbsoluteErrorAfterDB: evaluated.maximumAfter,
                    stereoMismatchBeforeDB: evaluated.stereoBefore,
                    stereoMismatchAfterDB: evaluated.stereoAfter,
                    confidence: evaluated.confidence
                )
            )
            beforeSquares += evaluated.rmsBefore * evaluated.rmsBefore * weight
            afterSquares += evaluated.rmsAfter * evaluated.rmsAfter * weight
            mismatchBeforeSquares += evaluated.stereoBefore
                * evaluated.stereoBefore * weight
            mismatchAfterSquares += evaluated.stereoAfter
                * evaluated.stereoAfter * weight
            totalWeight += weight
            confidenceWeighted += evaluated.confidence * weight
            maximumResidual = max(maximumResidual, evaluated.maximumAfter)
            worstRegression = max(
                worstRegression,
                evaluated.rmsAfter - evaluated.rmsBefore
            )

            if evaluated.rmsAfter
                > evaluated.rmsBefore + Self.maximumPositionRegressionDB {
                blocking.append(
                    "\(position.name) is predicted to regress by \(Self.db(evaluated.rmsAfter - evaluated.rmsBefore)) RMS."
                )
            }
            if position.left.quality.clipped || position.right.quality.clipped {
                blocking.append(
                    "\(position.name) contains a clipped measurement."
                )
            }
            if !position.left.quality.sweepComplete
                || !position.right.quality.sweepComplete {
                blocking.append(
                    "\(position.name) contains an incomplete sweep."
                )
            }
        }

        guard totalWeight > 0 else {
            throw RoomCorrectionDesignVerificationError.noSourcePositions
        }
        let before = sqrt(beforeSquares / totalWeight)
        let after = sqrt(afterSquares / totalWeight)
        let improvement = before - after
        let stereoBefore = sqrt(mismatchBeforeSquares / totalWeight)
        let stereoAfter = sqrt(mismatchAfterSquares / totalWeight)
        var confidence = confidenceWeighted / totalWeight
        let countFactor = min(
            1.0,
            0.85 + 0.075 * Double(max(0, sourcePositions.count - 1))
        )
        confidence = min(max(confidence * countFactor, 0), 1)

        if confidence < Self.minimumConfidence {
            blocking.append(
                "Room-correction prediction confidence \(Int((confidence * 100).rounded()))% is below the \(Int(Self.minimumConfidence * 100))% deployment threshold."
            )
        }
        let alreadyExcellent = after <= Self.excellentResidualDB
            && after <= before + 0.10
        if improvement < Self.minimumMeaningfulImprovementDB
            && !alreadyExcellent {
            blocking.append(
                "Predicted room-correction RMS improves by only \(Self.db(improvement)); at least \(Self.db(Self.minimumMeaningfulImprovementDB)) is required unless residual error is already excellent."
            )
        }
        if maximumResidual > Self.maximumAbsoluteResidualDB {
            blocking.append(
                "Predicted maximum room-correction target error is \(Self.db(maximumResidual))."
            )
        }
        if stereoAfter
            > stereoBefore + Self.maximumStereoMismatchRegressionDB {
            blocking.append(
                "Stereo response matching is predicted to worsen from \(Self.db(stereoBefore)) to \(Self.db(stereoAfter)) RMS."
            )
        }

        let auditGrid = Self.logGrid(
            low: max(10, design.sampleRate / 131_072),
            high: design.sampleRate * 0.49,
            count: Self.filterAuditPointCount
        )
        let unscaledLGain = try Self.firMagnitudeDB(
            taps: unscaledLeft,
            frequencies: auditGrid,
            sampleRate: design.sampleRate
        )
        let unscaledRGain = try Self.firMagnitudeDB(
            taps: unscaledRight,
            frequencies: auditGrid,
            sampleRate: design.sampleRate
        )
        let deployedLGain = try Self.firMagnitudeDB(
            taps: deployedLeft,
            frequencies: auditGrid,
            sampleRate: design.sampleRate
        )
        let deployedRGain = try Self.firMagnitudeDB(
            taps: deployedRight,
            frequencies: auditGrid,
            sampleRate: design.sampleRate
        )

        let maxUnscaled = max(
            unscaledLGain.max() ?? 0,
            unscaledRGain.max() ?? 0
        )
        let maxDeployed = max(
            deployedLGain.max() ?? 0,
            deployedRGain.max() ?? 0
        )
        if maxUnscaled
            > design.recommendedHeadroomDB + Self.headroomToleranceDB {
            blocking.append(
                "Declared room-correction headroom \(Self.db(design.recommendedHeadroomDB)) is insufficient for the measured \(Self.db(maxUnscaled)) FIR peak."
            )
        }
        if maxDeployed > Self.headroomToleranceDB {
            blocking.append(
                "The actual deployment FIR still contains \(Self.db(maxDeployed)) positive gain after safety attenuation."
            )
        }

        var maximumOutOfBand = 0.0
        for index in auditGrid.indices {
            let frequency = auditGrid[index]
            guard frequency < low || frequency > high else { continue }
            maximumOutOfBand = max(
                maximumOutOfBand,
                abs(unscaledLGain[index]),
                abs(unscaledRGain[index])
            )
        }
        if maximumOutOfBand > Self.maximumOutOfBandDeviationDB {
            blocking.append(
                "FIR leakage outside the correction band reaches \(Self.db(maximumOutOfBand))."
            )
        }

        let disagreement = try storedPredictionDisagreement(
            design: design,
            targetGrid: grid,
            unscaledLeftTaps: unscaledLeft,
            unscaledRightTaps: unscaledRight
        )
        if let disagreement,
           disagreement > Self.maximumStoredPredictionDisagreementDB {
            blocking.append(
                "Stored and independently recomputed FIR predictions disagree by up to \(Self.db(disagreement))."
            )
        } else if disagreement == nil {
            warnings.append(
                "This historical design has no stored predicted response to cross-check."
            )
        }

        blocking = Self.unique(blocking)
        warnings = Self.unique(warnings)

        return RoomCorrectionDesignVerificationReport(
            designID: design.id,
            confidence: confidence,
            rmsErrorBeforeDB: before,
            rmsErrorAfterDB: after,
            improvementDB: improvement,
            maximumAbsoluteErrorAfterDB: maximumResidual,
            worstPositionRegressionDB: worstRegression,
            stereoMismatchBeforeDB: stereoBefore,
            stereoMismatchAfterDB: stereoAfter,
            maximumUnscaledFilterGainDB: maxUnscaled,
            maximumDeploymentFilterGainDB: maxDeployed,
            maximumOutOfBandDeviationDB: maximumOutOfBand,
            storedPredictionDisagreementDB: disagreement,
            positionReports: reports,
            blockingReasons: blocking,
            warnings: warnings
        )
    }

    private func evaluatePosition(
        _ position: RoomCorrectionMeasurementPosition,
        target: RoomCorrectionTargetCurve,
        frequencies: [Double],
        leftFilterGainDB: [Double],
        rightFilterGainDB: [Double]
    ) throws -> (
        rmsBefore: Double,
        rmsAfter: Double,
        maximumAfter: Double,
        stereoBefore: Double,
        stereoAfter: Double,
        confidence: Double
    ) {
        guard let left = position.left.transferFunction,
              let right = position.right.transferFunction,
              left.frequenciesHz.count == left.magnitudeDB.count,
              right.frequenciesHz.count == right.magnitudeDB.count,
              left.frequenciesHz.count >= 2,
              right.frequenciesHz.count >= 2 else {
            throw RoomCorrectionDesignVerificationError
                .invalidMeasurement(position.id)
        }

        var leftBefore: [Double] = []
        var rightBefore: [Double] = []
        var leftAfter: [Double] = []
        var rightAfter: [Double] = []
        var targetDB: [Double] = []
        for index in frequencies.indices {
            let frequency = frequencies[index]
            let l = try Self.interpolate(left, at: frequency)
            let r = try Self.interpolate(right, at: frequency)
            leftBefore.append(l)
            rightBefore.append(r)
            leftAfter.append(l + leftFilterGainDB[index])
            rightAfter.append(r + rightFilterGainDB[index])
            targetDB.append(try target.interpolatedGainDB(at: frequency))
        }

        let leftBeforeErrors = Self.levelNormalizedErrors(
            response: leftBefore, target: targetDB
        )
        let rightBeforeErrors = Self.levelNormalizedErrors(
            response: rightBefore, target: targetDB
        )
        let leftAfterErrors = Self.levelNormalizedErrors(
            response: leftAfter, target: targetDB
        )
        let rightAfterErrors = Self.levelNormalizedErrors(
            response: rightAfter, target: targetDB
        )
        let before = Self.rms(leftBeforeErrors + rightBeforeErrors)
        let after = Self.rms(leftAfterErrors + rightAfterErrors)
        let maximumAfter = (leftAfterErrors + rightAfterErrors)
            .map(abs).max() ?? 0
        let stereoBefore = Self.rms(
            zip(leftBefore, rightBefore).map { $0 - $1 }
        )
        let stereoAfter = Self.rms(
            zip(leftAfter, rightAfter).map { $0 - $1 }
        )
        let confidence = (
            Self.measurementConfidence(position.left.quality, frequencies: frequencies)
            + Self.measurementConfidence(position.right.quality, frequencies: frequencies)
        ) * 0.5
        return (
            before, after, maximumAfter,
            stereoBefore, stereoAfter, confidence
        )
    }

    private func storedPredictionDisagreement(
        design: RoomCorrectionDesign,
        targetGrid: [Double],
        unscaledLeftTaps: [Float],
        unscaledRightTaps: [Float]
    ) throws -> Double? {
        guard let storedLeft = design.predictedLeftResponse,
              let storedRight = design.predictedRightResponse,
              let sourceIDs = design.sourcePositions?.map(\.id),
              !sourceIDs.isEmpty else {
            return nil
        }
        // Stored predicted responses were produced from the aggregate and the
        // unscaled FIR. Recompute just the FIR contribution and compare shape;
        // source-measurement verification above remains the deployment truth.
        let leftGain = try Self.firMagnitudeDB(
            taps: unscaledLeftTaps,
            frequencies: targetGrid,
            sampleRate: design.sampleRate
        )
        let rightGain = try Self.firMagnitudeDB(
            taps: unscaledRightTaps,
            frequencies: targetGrid,
            sampleRate: design.sampleRate
        )
        guard storedLeft.frequenciesHz.count >= 2,
              storedRight.frequenciesHz.count >= 2 else {
            return nil
        }
        var disagreement = 0.0
        for index in targetGrid.indices {
            let frequency = targetGrid[index]
            let storedL = try Self.interpolate(storedLeft, at: frequency)
            let storedR = try Self.interpolate(storedRight, at: frequency)
            // We do not have the historical aggregate embedded in the design,
            // so compare left/right correction delta. Common measured level
            // cancels, making this a useful corruption/materialization check.
            let storedDelta = storedL - storedR
            let recomputedDelta = leftGain[index] - rightGain[index]
            disagreement = max(
                disagreement,
                abs(storedDelta - recomputedDelta)
            )
        }
        return disagreement
    }

    private static func firMagnitudeDB(
        taps: [Float],
        frequencies: [Double],
        sampleRate: Double
    ) throws -> [Double] {
        guard !taps.isEmpty, taps.allSatisfy(\.isFinite),
              sampleRate.isFinite, sampleRate > 0 else {
            throw RoomCorrectionDesignVerificationError.invalidFilter
        }
        return try frequencies.map { frequency in
            guard frequency.isFinite, frequency >= 0,
                  frequency < sampleRate * 0.5 else {
                throw RoomCorrectionDesignVerificationError.invalidFilter
            }
            let omega = 2 * Double.pi * frequency / sampleRate
            var real = 0.0
            var imaginary = 0.0
            for index in taps.indices {
                let phase = -omega * Double(index)
                let tap = Double(taps[index])
                real += tap * cos(phase)
                imaginary += tap * sin(phase)
            }
            let magnitude = hypot(real, imaginary)
            guard magnitude.isFinite else {
                throw RoomCorrectionDesignVerificationError.invalidFilter
            }
            return 20 * log10(max(magnitude, 1.0e-12))
        }
    }

    private static func measurementConfidence(
        _ quality: RoomCorrectionMeasurementQuality,
        frequencies: [Double]
    ) -> Double {
        guard !quality.clipped, quality.sweepComplete,
              let first = frequencies.first,
              let last = frequencies.last else {
            return 0
        }
        let snr: Double
        if let value = quality.estimatedSNRDB, value.isFinite {
            snr = min(max((value - 20) / 30, 0), 1)
        } else {
            snr = 0.55
        }
        let usableLow = quality.usableLowHz ?? first
        let usableHigh = quality.usableHighHz ?? last
        let requested = max(log2(last / first), 1.0e-9)
        let overlapLow = max(first, usableLow)
        let overlapHigh = min(last, usableHigh)
        let overlap = overlapHigh > overlapLow
            ? log2(overlapHigh / overlapLow) : 0
        let coverage = min(max(overlap / requested, 0), 1)
        let arrival = quality.directArrivalSeconds == nil ? 0.75 : 1.0
        return min(max(0.60 * snr + 0.30 * coverage + 0.10 * arrival, 0), 1)
    }

    private static func interpolate(
        _ response: RoomCorrectionFrequencyResponse,
        at frequency: Double
    ) throws -> Double {
        let f = response.frequenciesHz
        let v = response.magnitudeDB
        guard f.count == v.count, f.count >= 2,
              f.allSatisfy({ $0.isFinite && $0 > 0 }),
              v.allSatisfy(\.isFinite) else {
            throw RoomCorrectionDesignVerificationError.invalidFilter
        }
        if frequency <= f[0] { return v[0] }
        if frequency >= f[f.count - 1] { return v[v.count - 1] }
        var low = 0
        var high = f.count - 1
        while high - low > 1 {
            let mid = (low + high) / 2
            if f[mid] <= frequency { low = mid } else { high = mid }
        }
        let denominator = log(f[high] / f[low])
        guard denominator > 0 else { return v[low] }
        let fraction = log(frequency / f[low]) / denominator
        return v[low] + (v[high] - v[low]) * fraction
    }

    private static func levelNormalizedErrors(
        response: [Double],
        target: [Double]
    ) -> [Double] {
        guard response.count == target.count, !response.isEmpty else {
            return []
        }
        let raw = zip(response, target).map { $0 - $1 }
        let mean = raw.reduce(0, +) / Double(raw.count)
        return raw.map { $0 - mean }
    }

    private static func rms(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return sqrt(
            values.reduce(0) { $0 + $1 * $1 } / Double(values.count)
        )
    }

    private static func logGrid(
        low: Double, high: Double, count: Int
    ) -> [Double] {
        guard low > 0, high > low, count > 1 else { return [] }
        let ratio = high / low
        return (0..<count).map {
            low * pow(ratio, Double($0) / Double(count - 1))
        }
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }

    private static func db(_ value: Double) -> String {
        String(format: "%.2f dB", value)
    }
}
