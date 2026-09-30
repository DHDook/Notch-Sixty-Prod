import Accelerate
import Foundation

struct RoomCorrectionMeasurementAnalysis: Equatable, Sendable {
    var sampleRate: Double
    var left: RoomCorrectionChannelMeasurement
    var right: RoomCorrectionChannelMeasurement
}

enum RoomCorrectionMeasurementAnalysisError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case captureLength(pass: RoomCorrectionMeasurementPass, expected: Int, actual: Int)
    case nonFiniteCapture(pass: RoomCorrectionMeasurementPass)
    case invalidSweep
    case transformTooLarge(required: Int)
    case transformSetupFailed(Int)
    case unusableExcitation
    case directArrivalNotFound(pass: RoomCorrectionMeasurementPass)
    case invalidMicrophoneCalibration

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let sampleRate):
            return "Room measurement analysis sample rate \(sampleRate) Hz is invalid."
        case .captureLength(let pass, let expected, let actual):
            return "Room measurement \(pass.rawValue) capture contains \(actual) frames; \(expected) were expected."
        case .nonFiniteCapture(let pass):
            return "Room measurement \(pass.rawValue) capture contains non-finite samples."
        case .invalidSweep:
            return "Room measurement sweep data is invalid or incomplete."
        case .transformTooLarge(let required):
            return "Room measurement analysis requires an unsupported FFT size for \(required) frames."
        case .transformSetupFailed(let size):
            return "Room measurement analysis could not create an Accelerate transform of \(size) frames."
        case .unusableExcitation:
            return "Room measurement excitation does not contain enough spectral energy for deconvolution."
        case .directArrivalNotFound(let pass):
            return "Room measurement \(pass.rawValue) response does not contain a reliable direct arrival."
        case .invalidMicrophoneCalibration:
            return "The selected microphone calibration curve is invalid."
        }
    }
}

/// Offline analysis for one paired room-measurement capture. Nothing in this
/// type runs on the Core Audio callback. It uses regularized frequency-domain
/// deconvolution of the exact ESS program that produced the capture, derives a
/// time-domain impulse response, removes bulk acoustic delay from reported
/// transfer-function phase, and emits the persistence models used by the room
/// correction project.
struct RoomCorrectionMeasurementAnalyzer: Sendable {
    static let responsePointCount = 512
    static let maximumTransformSize = 8_388_608
    static let regularizationPowerRatio: Float = 1.0e-10
    static let directArrivalThresholdRatio: Float = 0.10
    static let lowSNRWarningDB = 20.0

    func analyze(
        capture: RoomCorrectionCalibrationCapture,
        plan: RoomCorrectionMeasurementPlan,
        microphoneCalibration: RoomCorrectionMicrophoneCalibration? = nil,
        capturedAt: Date = Date()
    ) throws -> RoomCorrectionMeasurementAnalysis {
        let sampleRate = plan.program.sampleRate
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSampleRate(sampleRate)
        }
        try validateProgram(plan.program)
        try validateCalibration(microphoneCalibration)

        let left = try analyzeChannel(
            rawCapture: capture.left,
            pass: .left,
            expectedFrameCount: plan.leftPass.captureFrameCount,
            program: plan.program,
            calibration: microphoneCalibration,
            capturedAt: capturedAt
        )
        let right = try analyzeChannel(
            rawCapture: capture.right,
            pass: .right,
            expectedFrameCount: plan.rightPass.captureFrameCount,
            program: plan.program,
            calibration: microphoneCalibration,
            capturedAt: capturedAt
        )
        return RoomCorrectionMeasurementAnalysis(
            sampleRate: sampleRate,
            left: left,
            right: right
        )
    }

    private func analyzeChannel(
        rawCapture: [Float],
        pass: RoomCorrectionMeasurementPass,
        expectedFrameCount: Int,
        program: RoomCorrectionSweepProgram,
        calibration: RoomCorrectionMicrophoneCalibration?,
        capturedAt: Date
    ) throws -> RoomCorrectionChannelMeasurement {
        guard rawCapture.count == expectedFrameCount else {
            throw RoomCorrectionMeasurementAnalysisError.captureLength(
                pass: pass,
                expected: expectedFrameCount,
                actual: rawCapture.count
            )
        }
        guard rawCapture.allSatisfy(\.isFinite) else {
            throw RoomCorrectionMeasurementAnalysisError.nonFiniteCapture(pass: pass)
        }

        let sweepStart = program.leadInFrames
        let sweepEnd = sweepStart + program.sweepSamples.count
        guard sweepStart >= 0,
              sweepEnd <= rawCapture.count,
              sweepStart < rawCapture.count else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }

        // Lead-in is excluded from the transfer estimate but retained in rawCapture
        // so it can provide an environmental/electrical noise-floor estimate.
        let observed = Array(rawCapture[sweepStart...])
        guard observed.count >= program.sweepSamples.count else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
        var excitation = [Float](repeating: 0, count: observed.count)
        for index in program.sweepSamples.indices {
            excitation[index] = program.sweepSamples[index]
        }

        let transformSize = try Self.transformSize(requiredFrames: observed.count)
        let dft = try RoomCorrectionDFT(size: transformSize)
        let excitationSpectrum = dft.forward(excitation)
        let observedSpectrum = dft.forward(observed)

        var maximumExcitationPower: Float = 0
        for index in 0..<transformSize {
            let real = excitationSpectrum.real[index]
            let imaginary = excitationSpectrum.imaginary[index]
            maximumExcitationPower = max(
                maximumExcitationPower,
                real * real + imaginary * imaginary
            )
        }
        guard maximumExcitationPower.isFinite, maximumExcitationPower > Float.leastNonzeroMagnitude else {
            throw RoomCorrectionMeasurementAnalysisError.unusableExcitation
        }

        let regularization = max(
            maximumExcitationPower * Self.regularizationPowerRatio,
            Float.leastNonzeroMagnitude
        )
        var transferReal = [Float](repeating: 0, count: transformSize)
        var transferImaginary = [Float](repeating: 0, count: transformSize)
        for index in 0..<transformSize {
            let sourceReal = excitationSpectrum.real[index]
            let sourceImaginary = excitationSpectrum.imaginary[index]
            let measuredReal = observedSpectrum.real[index]
            let measuredImaginary = observedSpectrum.imaginary[index]
            let sourcePower = sourceReal * sourceReal + sourceImaginary * sourceImaginary
            let denominator = sourcePower + regularization

            // Y * conj(X) / (|X|^2 + lambda)
            transferReal[index] = (
                measuredReal * sourceReal + measuredImaginary * sourceImaginary
            ) / denominator
            transferImaginary[index] = (
                measuredImaginary * sourceReal - measuredReal * sourceImaginary
            ) / denominator
        }

        let fullImpulse = dft.inverse(real: transferReal, imaginary: transferImaginary)
        let arrivalFrame = try directArrivalFrame(
            impulse: fullImpulse,
            sampleRate: program.sampleRate,
            tailFrames: program.tailFrames,
            pass: pass
        )

        let impulseFrameCount = min(
            fullImpulse.count / 2,
            max(
                arrivalFrame + program.tailFrames,
                Int((program.sampleRate * 0.5).rounded())
            )
        )
        let impulseResponse = Array(fullImpulse.prefix(max(1, impulseFrameCount)))
        let response = try makeFrequencyResponse(
            transferReal: transferReal,
            transferImaginary: transferImaginary,
            transformSize: transformSize,
            sampleRate: program.sampleRate,
            settings: program.settings,
            directArrivalFrame: arrivalFrame,
            calibration: calibration
        )
        let quality = makeQuality(
            rawCapture: rawCapture,
            program: program,
            arrivalFrame: arrivalFrame
        )

        return RoomCorrectionChannelMeasurement(
            capturedAt: capturedAt,
            rawCapture: rawCapture,
            impulseResponse: impulseResponse,
            transferFunction: response,
            quality: quality
        )
    }

    private func validateProgram(_ program: RoomCorrectionSweepProgram) throws {
        guard program.sampleRate.isFinite,
              program.sampleRate > 0,
              !program.sweepSamples.isEmpty,
              program.sweepSamples.allSatisfy(\.isFinite),
              program.leadInFrames >= 0,
              program.tailFrames >= 0,
              program.settings.sampleRate.isFinite,
              abs(program.settings.sampleRate - program.sampleRate) < 0.5 else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
    }

    private func validateCalibration(_ calibration: RoomCorrectionMicrophoneCalibration?) throws {
        guard let calibration else { return }
        guard calibration.schemaVersion == RoomCorrectionMicrophoneCalibration.currentSchemaVersion,
              calibration.points.count >= 2 else {
            throw RoomCorrectionMeasurementAnalysisError.invalidMicrophoneCalibration
        }
        var previousFrequency = 0.0
        for point in calibration.points {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz > previousFrequency,
                  point.gainDB.isFinite else {
                throw RoomCorrectionMeasurementAnalysisError.invalidMicrophoneCalibration
            }
            previousFrequency = point.frequencyHz
        }
    }

    private func directArrivalFrame(
        impulse: [Float],
        sampleRate: Double,
        tailFrames: Int,
        pass: RoomCorrectionMeasurementPass
    ) throws -> Int {
        let minimumSearch = Int((sampleRate * 0.25).rounded())
        let searchCount = min(
            impulse.count / 2,
            max(tailFrames, minimumSearch, 1)
        )
        guard searchCount > 0 else {
            throw RoomCorrectionMeasurementAnalysisError.directArrivalNotFound(pass: pass)
        }

        var peak: Float = 0
        var globalPeakIndex = 0
        for index in 0..<searchCount {
            let magnitude = abs(impulse[index])
            if magnitude > peak {
                peak = magnitude
                globalPeakIndex = index
            }
        }
        guard peak.isFinite, peak > 1.0e-8 else {
            throw RoomCorrectionMeasurementAnalysisError.directArrivalNotFound(pass: pass)
        }

        // Prefer the earliest credible onset rather than a later reflection that
        // happens to be the largest peak. The short local-peak search rejects a
        // single threshold-crossing sample while keeping the direct wavefront.
        let threshold = peak * Self.directArrivalThresholdRatio
        let onset = (0..<searchCount).first { abs(impulse[$0]) >= threshold }
            ?? globalPeakIndex
        let localPeakSpan = max(1, Int((sampleRate * 0.003).rounded()))
        let localEnd = min(searchCount, onset + localPeakSpan)
        var arrival = onset
        var arrivalMagnitude = abs(impulse[onset])
        if onset + 1 < localEnd {
            for index in (onset + 1)..<localEnd {
                let magnitude = abs(impulse[index])
                if magnitude > arrivalMagnitude {
                    arrivalMagnitude = magnitude
                    arrival = index
                }
            }
        }
        return arrival
    }

    private func makeFrequencyResponse(
        transferReal: [Float],
        transferImaginary: [Float],
        transformSize: Int,
        sampleRate: Double,
        settings: RoomCorrectionSweepSettings,
        directArrivalFrame: Int,
        calibration: RoomCorrectionMicrophoneCalibration?
    ) throws -> RoomCorrectionFrequencyResponse {
        let nyquist = sampleRate * 0.5
        let minimumFrequency = max(
            settings.startFrequencyHz,
            sampleRate / Double(transformSize)
        )
        let maximumFrequency = min(
            settings.endFrequencyHz,
            nyquist * 0.98
        )
        guard minimumFrequency.isFinite,
              maximumFrequency.isFinite,
              minimumFrequency > 0,
              maximumFrequency > minimumFrequency else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }

        let pointCount = Self.responsePointCount
        let ratio = maximumFrequency / minimumFrequency
        var frequencies = [Double](repeating: 0, count: pointCount)
        var magnitudes = [Double](repeating: 0, count: pointCount)
        var wrappedPhases = [Double](repeating: 0, count: pointCount)

        for point in 0..<pointCount {
            let fraction = Double(point) / Double(pointCount - 1)
            let frequency = minimumFrequency * pow(ratio, fraction)
            let binPosition = frequency * Double(transformSize) / sampleRate
            let bin = min(
                transformSize / 2,
                max(1, Int(binPosition.rounded()))
            )
            let real = Double(transferReal[bin])
            let imaginary = Double(transferImaginary[bin])
            let magnitude = hypot(real, imaginary)
            var magnitudeDB = 20.0 * log10(max(magnitude, 1.0e-12))
            if let calibration {
                do {
                    // Calibration points are stored as correction gain, so they
                    // are added to the measured transfer magnitude.
                    magnitudeDB += try calibration.gainDB(at: frequency)
                } catch {
                    throw RoomCorrectionMeasurementAnalysisError.invalidMicrophoneCalibration
                }
            }

            // Remove only bulk propagation/device delay. Acoustic phase relative
            // to the direct arrival remains available for later mixed-phase design.
            let delayCorrection = 2.0 * Double.pi
                * Double(bin) * Double(directArrivalFrame) / Double(transformSize)
            let phase = Self.wrapPhase(atan2(imaginary, real) + delayCorrection)

            frequencies[point] = frequency
            magnitudes[point] = magnitudeDB
            wrappedPhases[point] = phase
        }

        return RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: Self.unwrapPhases(wrappedPhases)
        )
    }

    private func makeQuality(
        rawCapture: [Float],
        program: RoomCorrectionSweepProgram,
        arrivalFrame: Int
    ) -> RoomCorrectionMeasurementQuality {
        let playbackPeak = Self.peakDBFS(program.sweepSamples)
        let capturePeak = Self.peakDBFS(rawCapture)
        let clipped = rawCapture.contains { abs($0) >= 0.999 }

        let leadCount = min(program.leadInFrames, rawCapture.count)
        let noiseRMS = leadCount > 0
            ? Self.rms(Array(rawCapture.prefix(leadCount)))
            : nil
        let sweepStart = min(program.leadInFrames, rawCapture.count)
        let sweepEnd = min(sweepStart + program.sweepSamples.count, rawCapture.count)
        let signalRMS = sweepStart < sweepEnd
            ? Self.rms(Array(rawCapture[sweepStart..<sweepEnd]))
            : nil

        let noiseFloor = noiseRMS.flatMap(Self.amplitudeDBFS)
        let signalLevel = signalRMS.flatMap(Self.amplitudeDBFS)
        let snr: Double? = if let signalLevel, let noiseFloor {
            signalLevel - noiseFloor
        } else {
            nil
        }

        var warnings: [String] = []
        if clipped {
            warnings.append("Capture reached digital full scale; lower sweep level or microphone gain and measure again.")
        }
        if let snr, snr < Self.lowSNRWarningDB {
            warnings.append("Estimated measurement SNR is below \(Int(Self.lowSNRWarningDB)) dB.")
        }
        if leadCount == 0 {
            warnings.append("No lead-in interval was available for a noise-floor estimate.")
        }
        if program.tailFrames > 0,
           arrivalFrame > Int(Double(program.tailFrames) * 0.8) {
            warnings.append("Direct arrival is unusually late in the capture window; verify device synchronization and microphone routing.")
        }

        return RoomCorrectionMeasurementQuality(
            clipped: clipped,
            playbackPeakDBFS: playbackPeak,
            capturePeakDBFS: capturePeak,
            estimatedNoiseFloorDBFS: noiseFloor,
            estimatedSNRDB: snr,
            sweepComplete: true,
            directArrivalSeconds: Double(arrivalFrame) / program.sampleRate,
            usableLowHz: program.settings.startFrequencyHz,
            usableHighHz: min(
                program.settings.endFrequencyHz,
                program.sampleRate * 0.5 * 0.98
            ),
            warnings: warnings
        )
    }

    private static func transformSize(requiredFrames: Int) throws -> Int {
        guard requiredFrames > 1 else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSweep
        }
        var size = 1
        while size < requiredFrames {
            guard size <= Self.maximumTransformSize / 2 else {
                throw RoomCorrectionMeasurementAnalysisError.transformTooLarge(required: requiredFrames)
            }
            size <<= 1
        }
        guard size <= Self.maximumTransformSize else {
            throw RoomCorrectionMeasurementAnalysisError.transformTooLarge(required: requiredFrames)
        }
        return size
    }

    private static func peakDBFS(_ samples: [Float]) -> Double? {
        guard let peak = samples.lazy.map({ abs(Double($0)) }).max(), peak > 0 else { return nil }
        return 20.0 * log10(peak)
    }

    private static func rms(_ samples: [Float]) -> Double? {
        guard !samples.isEmpty else { return nil }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        let value = sqrt(sum / Double(samples.count))
        return value.isFinite ? value : nil
    }

    private static func amplitudeDBFS(_ amplitude: Double) -> Double? {
        guard amplitude.isFinite, amplitude > 0 else { return nil }
        return 20.0 * log10(amplitude)
    }

    private static func wrapPhase(_ phase: Double) -> Double {
        var result = phase
        while result > .pi { result -= 2.0 * .pi }
        while result < -.pi { result += 2.0 * .pi }
        return result
    }

    private static func unwrapPhases(_ phases: [Double]) -> [Double] {
        guard !phases.isEmpty else { return [] }
        var result = phases
        for index in 1..<result.count {
            var current = result[index]
            let previous = result[index - 1]
            while current - previous > .pi { current -= 2.0 * .pi }
            while current - previous < -.pi { current += 2.0 * .pi }
            result[index] = current
        }
        return result
    }
}

private struct RoomCorrectionSpectrum {
    var real: [Float]
    var imaginary: [Float]
}

/// Small retained wrapper around Accelerate's out-of-place complex DFT. It is
/// intentionally local to the offline analyzer; realtime DSP never owns or
/// touches these large transform buffers.
private final class RoomCorrectionDFT {
    let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let zeroImaginary: [Float]

    init(size: Int) throws {
        guard let forward = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            throw RoomCorrectionMeasurementAnalysisError.transformSetupFailed(size)
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .INVERSE) else {
            vDSP_DFT_DestroySetup(forward)
            throw RoomCorrectionMeasurementAnalysisError.transformSetupFailed(size)
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

    func forward(_ source: [Float]) -> RoomCorrectionSpectrum {
        precondition(source.count <= size)
        var padded = [Float](repeating: 0, count: size)
        for index in source.indices {
            padded[index] = source[index]
        }
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
        return RoomCorrectionSpectrum(real: real, imaginary: imaginary)
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
        for index in outputReal.indices {
            outputReal[index] *= scale
        }
        return outputReal
    }
}
