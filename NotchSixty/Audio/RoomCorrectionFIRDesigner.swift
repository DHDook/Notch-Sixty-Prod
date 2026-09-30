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
