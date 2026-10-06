import Accelerate
import Foundation

struct MIMORoomTreatmentFIRCompileConfiguration: Equatable, Sendable {
    var tapCount = 4_096
    var transitionWidthHz = 15.0
    var maximumEdgeEnergyFraction = 0.12
    var maximumCoefficientOvershootDB = 0.35
    var maximumColumnPowerOvershootDB = 0.35
    var maximumPerSourcePowerOvershootDB = 0.35

    static let conservative = MIMORoomTreatmentFIRCompileConfiguration()
}

struct MIMORoomTreatmentFIRCompileDiagnostics: Equatable, Sendable {
    let maximumEdgeEnergyFraction: Double
    let maximumCoefficientMagnitude: Double
    let maximumColumnPower: Double
    let maximumPerSourcePower: Double
    let maximumCoefficientOvershootDB: Double
    let maximumColumnPowerOvershootDB: Double
    let maximumPerSourcePowerOvershootDB: Double
}

struct MIMORoomTreatmentFIRProgram: Equatable, Sendable {
    let sampleRate: Double
    let sources: [MultichannelCalibrationSource]
    let tapCount: Int
    let declaredLatencyFrames: Int
    let engineLatencyFrames: Int
    /// Flattened [output source][input target][tap].
    let taps: [Float]
    let diagnostics: MIMORoomTreatmentFIRCompileDiagnostics

    var totalLatencyFrames: Int {
        declaredLatencyFrames + engineLatencyFrames
    }

    var simulationOnly: Bool { true }

    func tap(
        outputSourceIndex: Int,
        inputTargetIndex: Int,
        tapIndex: Int
    ) -> Float? {
        let count = sources.count
        guard outputSourceIndex >= 0,
              outputSourceIndex < count,
              inputTargetIndex >= 0,
              inputTargetIndex < count,
              tapIndex >= 0,
              tapIndex < tapCount else {
            return nil
        }
        let offset =
            ((outputSourceIndex * count + inputTargetIndex) * tapCount)
            + tapIndex
        return taps[offset]
    }
}

enum MIMORoomTreatmentFIRCompileError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case sourceCountUnsupported(Int)
    case invalidTapCount(Int)
    case invalidFrequencyGrid
    case invalidConfiguration
    case transformSetupFailed(Int)
    case edgeEnergyTooHigh(actual: Double, maximum: Double)
    case denseSafetyViolation(kind: String, actualDB: Double, maximumDB: Double)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let value):
            return "MIMO FIR compiler sample rate \(value) Hz is invalid."
        case .sourceCountUnsupported(let count):
            return "MIMO FIR compiler supports 1–\(Int(N60_MIMO_FIR_MAX_CHANNELS)) treatment actuators; received \(count)."
        case .invalidTapCount(let count):
            return "MIMO FIR compiler tap count \(count) is unsupported."
        case .invalidFrequencyGrid:
            return "MIMO FIR compiler received an invalid PR73 frequency grid."
        case .invalidConfiguration:
            return "MIMO FIR compiler configuration is invalid."
        case .transformSetupFailed(let size):
            return "MIMO FIR compiler could not create a \(size)-point Accelerate transform."
        case .edgeEnergyTooHigh(let actual, let maximum):
            return "MIMO FIR impulse energy near the causal window edges is \(actual), above \(maximum)."
        case .denseSafetyViolation(let kind, let actualDB, let maximumDB):
            return "MIMO FIR compiled \(kind) overshoot is \(actualDB) dB, above \(maximumDB) dB."
        }
    }
}

/// PR74 control-plane compiler.
///
/// Converts the accepted/rejected PR73 frequency-domain matrix into a causal,
/// finite, immutable FIR matrix. Rejected PR73 bins are already exact identity.
/// The compiler additionally tapers treatment strength to identity at the
/// treatment-band edges, enforces Hermitian symmetry, circularly delays the
/// impulse by half the FIR length, applies a short edge taper, then validates
/// the realized dense frequency response against PR73's unity safety envelope.
///
/// There is intentionally no live graph/apply API in PR74.
struct MIMORoomTreatmentFIRCompiler: Sendable {
    func compile(
        plan: MIMORoomTreatmentPlan,
        configuration: MIMORoomTreatmentFIRCompileConfiguration = .conservative
    ) throws -> MIMORoomTreatmentFIRProgram {
        guard plan.sampleRate.isFinite, plan.sampleRate > 0 else {
            throw MIMORoomTreatmentFIRCompileError.invalidSampleRate(
                plan.sampleRate
            )
        }
        let channelCount = plan.sources.count
        guard channelCount > 0,
              channelCount <= Int(N60_MIMO_FIR_MAX_CHANNELS) else {
            throw MIMORoomTreatmentFIRCompileError.sourceCountUnsupported(
                channelCount
            )
        }
        guard configuration.tapCount >= 512,
              configuration.tapCount <= Int(N60_MIMO_FIR_MAX_TAPS),
              configuration.tapCount.isMultiple(of: 2),
              configuration.tapCount.nonzeroBitCount == 1 else {
            throw MIMORoomTreatmentFIRCompileError.invalidTapCount(
                configuration.tapCount
            )
        }
        guard configuration.transitionWidthHz.isFinite,
              configuration.transitionWidthHz > 0,
              configuration.maximumEdgeEnergyFraction.isFinite,
              configuration.maximumEdgeEnergyFraction >= 0,
              configuration.maximumEdgeEnergyFraction <= 1,
              configuration.maximumCoefficientOvershootDB.isFinite,
              configuration.maximumCoefficientOvershootDB >= 0,
              configuration.maximumColumnPowerOvershootDB.isFinite,
              configuration.maximumColumnPowerOvershootDB >= 0,
              configuration.maximumPerSourcePowerOvershootDB.isFinite,
              configuration.maximumPerSourcePowerOvershootDB >= 0 else {
            throw MIMORoomTreatmentFIRCompileError.invalidConfiguration
        }

        try validatePlan(plan)
        let size = configuration.tapCount
        let half = size / 2
        let declaredLatency = half
        let dft = try MIMOFIRDFT(size: size)
        var taps = [Float](
            repeating: 0,
            count: channelCount * channelCount * size
        )

        for output in 0..<channelCount {
            for input in 0..<channelCount {
                var real = [Float](repeating: 0, count: size)
                var imaginary = [Float](repeating: 0, count: size)

                for bin in 0...half {
                    let frequency =
                        Double(bin) * plan.sampleRate / Double(size)
                    let value = response(
                        plan: plan,
                        output: output,
                        input: input,
                        frequencyHz: frequency,
                        transitionWidthHz: configuration.transitionWidthHz
                    )
                    real[bin] = Float(value.real)
                    imaginary[bin] = Float(value.imaginary)
                }

                // Real-valued impulse response requires conjugate symmetry.
                if half > 1 {
                    for bin in 1..<half {
                        real[size - bin] = real[bin]
                        imaginary[size - bin] = -imaginary[bin]
                    }
                }
                imaginary[0] = 0
                imaginary[half] = 0

                let periodicImpulse = dft.inverse(
                    real: real,
                    imaginary: imaginary
                )

                // Delay the periodic impulse by N/2 so the non-causal content
                // around time zero is centered inside a finite causal window.
                var shifted = [Float](repeating: 0, count: size)
                for index in 0..<size {
                    shifted[(index + declaredLatency) % size] =
                        periodicImpulse[index]
                }

                applyEdgeTaper(&shifted)
                for tap in 0..<size {
                    taps[
                        tapOffset(
                            channelCount: channelCount,
                            tapCount: size,
                            output: output,
                            input: input,
                            tap: tap
                        )
                    ] = shifted[tap]
                }
            }
        }

        let edgeEnergy = maximumEdgeEnergyFraction(
            taps: taps,
            channelCount: channelCount,
            tapCount: size
        )
        guard edgeEnergy <= configuration.maximumEdgeEnergyFraction else {
            throw MIMORoomTreatmentFIRCompileError.edgeEnergyTooHigh(
                actual: edgeEnergy,
                maximum: configuration.maximumEdgeEnergyFraction
            )
        }

        let dense = try denseSafetyDiagnostics(
            taps: taps,
            channelCount: channelCount,
            tapCount: size,
            sampleRate: plan.sampleRate,
            dft: dft,
            edgeEnergyFraction: edgeEnergy
        )
        try enforceDenseSafety(
            dense,
            configuration: configuration
        )

        return MIMORoomTreatmentFIRProgram(
            sampleRate: plan.sampleRate,
            sources: plan.sources,
            tapCount: size,
            declaredLatencyFrames: declaredLatency,
            engineLatencyFrames: Int(N60_MIMO_FIR_PARTITION_FRAMES),
            taps: taps,
            diagnostics: dense
        )
    }

    private func validatePlan(_ plan: MIMORoomTreatmentPlan) throws {
        guard plan.frequenciesHz.count >= 2,
              plan.frequencyResults.count == plan.frequenciesHz.count else {
            throw MIMORoomTreatmentFIRCompileError.invalidFrequencyGrid
        }
        let expectedCoefficientCount =
            plan.frequenciesHz.count * plan.sources.count * plan.sources.count
        guard plan.coefficients.count == expectedCoefficientCount else {
            throw MIMORoomTreatmentFIRCompileError.invalidFrequencyGrid
        }

        var previous = 0.0
        for frequency in plan.frequenciesHz {
            guard frequency.isFinite,
                  frequency > previous,
                  frequency < plan.sampleRate * 0.5 else {
                throw MIMORoomTreatmentFIRCompileError.invalidFrequencyGrid
            }
            previous = frequency
        }
    }

    private func response(
        plan: MIMORoomTreatmentPlan,
        output: Int,
        input: Int,
        frequencyHz: Double,
        transitionWidthHz: Double
    ) -> (real: Double, imaginary: Double) {
        let identity = (
            real: output == input ? 1.0 : 0.0,
            imaginary: 0.0
        )
        guard let low = plan.frequenciesHz.first,
              let high = plan.frequenciesHz.last,
              frequencyHz > low,
              frequencyHz < high else {
            return identity
        }

        let candidate = interpolatedCoefficient(
            plan: plan,
            output: output,
            input: input,
            frequencyHz: frequencyHz
        )
        let lower = Self.smoothstep(
            min(max((frequencyHz - low) / transitionWidthHz, 0), 1)
        )
        let upper = Self.smoothstep(
            min(max((high - frequencyHz) / transitionWidthHz, 0), 1)
        )
        let amount = min(lower, upper)
        return (
            identity.real + (candidate.real - identity.real) * amount,
            identity.imaginary
                + (candidate.imaginary - identity.imaginary) * amount
        )
    }

    private func interpolatedCoefficient(
        plan: MIMORoomTreatmentPlan,
        output: Int,
        input: Int,
        frequencyHz: Double
    ) -> MIMORoomTreatmentComplexCoefficient {
        let frequencies = plan.frequenciesHz
        if frequencyHz <= frequencies[0] {
            return plan.coefficient(
                frequencyIndex: 0,
                sourceIndex: output,
                targetIndex: input
            )!
        }
        if frequencyHz >= frequencies[frequencies.count - 1] {
            return plan.coefficient(
                frequencyIndex: frequencies.count - 1,
                sourceIndex: output,
                targetIndex: input
            )!
        }

        var lower = 0
        var upper = frequencies.count - 1
        while upper - lower > 1 {
            let midpoint = (lower + upper) / 2
            if frequencies[midpoint] <= frequencyHz {
                lower = midpoint
            } else {
                upper = midpoint
            }
        }
        let lowHz = frequencies[lower]
        let highHz = frequencies[upper]
        let fraction = (frequencyHz - lowHz) / (highHz - lowHz)
        let lhs = plan.coefficient(
            frequencyIndex: lower,
            sourceIndex: output,
            targetIndex: input
        )!
        let rhs = plan.coefficient(
            frequencyIndex: upper,
            sourceIndex: output,
            targetIndex: input
        )!
        return MIMORoomTreatmentComplexCoefficient(
            real: lhs.real + (rhs.real - lhs.real) * fraction,
            imaginary: lhs.imaginary
                + (rhs.imaginary - lhs.imaginary) * fraction
        )
    }

    private func applyEdgeTaper(_ taps: inout [Float]) {
        let edge = max(8, taps.count / 20)
        guard edge * 2 < taps.count else { return }
        for index in 0..<edge {
            let phase = Double(index) / Double(edge)
            let gain = 0.5 - 0.5 * cos(Double.pi * phase)
            taps[index] *= Float(gain)
            taps[taps.count - 1 - index] *= Float(gain)
        }
    }

    private func maximumEdgeEnergyFraction(
        taps: [Float],
        channelCount: Int,
        tapCount: Int
    ) -> Double {
        let edge = max(8, tapCount / 20)
        var maximum = 0.0
        for output in 0..<channelCount {
            for input in 0..<channelCount {
                var total = 0.0
                var edgeEnergy = 0.0
                for tap in 0..<tapCount {
                    let value = Double(taps[
                        tapOffset(
                            channelCount: channelCount,
                            tapCount: tapCount,
                            output: output,
                            input: input,
                            tap: tap
                        )
                    ])
                    let power = value * value
                    total += power
                    if tap < edge || tap >= tapCount - edge {
                        edgeEnergy += power
                    }
                }
                if total > 1.0e-24 {
                    maximum = max(maximum, edgeEnergy / total)
                }
            }
        }
        return maximum
    }

    private func denseSafetyDiagnostics(
        taps: [Float],
        channelCount: Int,
        tapCount: Int,
        sampleRate: Double,
        dft: MIMOFIRDFT,
        edgeEnergyFraction: Double
    ) throws -> MIMORoomTreatmentFIRCompileDiagnostics {
        var spectra: [[MIMOFIRComplexValue]] = []
        spectra.reserveCapacity(channelCount * channelCount)
        for output in 0..<channelCount {
            for input in 0..<channelCount {
                var path = [Float](repeating: 0, count: tapCount)
                for tap in 0..<tapCount {
                    path[tap] = taps[
                        tapOffset(
                            channelCount: channelCount,
                            tapCount: tapCount,
                            output: output,
                            input: input,
                            tap: tap
                        )
                    ]
                }
                spectra.append(dft.forwardReal(path))
            }
        }

        var maxCoefficient = 0.0
        var maxColumnPower = 0.0
        var maxSourcePower = 0.0
        for bin in 0...(tapCount / 2) {
            let frequency = Double(bin) * sampleRate / Double(tapCount)
            // Only the room-treatment region and its 15 Hz transition margin
            // need the PR73 unity safety envelope. Outside, identity dominates.
            guard frequency <= 180 else { break }

            for output in 0..<channelCount {
                var rowPower = 0.0
                for input in 0..<channelCount {
                    let value = spectra[
                        output * channelCount + input
                    ][bin]
                    let power = value.real * value.real
                        + value.imaginary * value.imaginary
                    rowPower += power
                    maxCoefficient = max(maxCoefficient, sqrt(power))
                }
                maxSourcePower = max(maxSourcePower, rowPower)
            }
            for input in 0..<channelCount {
                var columnPower = 0.0
                for output in 0..<channelCount {
                    let value = spectra[
                        output * channelCount + input
                    ][bin]
                    columnPower += value.real * value.real
                        + value.imaginary * value.imaginary
                }
                maxColumnPower = max(maxColumnPower, columnPower)
            }
        }

        return MIMORoomTreatmentFIRCompileDiagnostics(
            maximumEdgeEnergyFraction: edgeEnergyFraction,
            maximumCoefficientMagnitude: maxCoefficient,
            maximumColumnPower: maxColumnPower,
            maximumPerSourcePower: maxSourcePower,
            maximumCoefficientOvershootDB: Self.powerSafeAmplitudeDB(
                maxCoefficient
            ),
            maximumColumnPowerOvershootDB: Self.powerDB(maxColumnPower),
            maximumPerSourcePowerOvershootDB: Self.powerDB(maxSourcePower)
        )
    }

    private func enforceDenseSafety(
        _ diagnostics: MIMORoomTreatmentFIRCompileDiagnostics,
        configuration: MIMORoomTreatmentFIRCompileConfiguration
    ) throws {
        if diagnostics.maximumCoefficientOvershootDB
            > configuration.maximumCoefficientOvershootDB {
            throw MIMORoomTreatmentFIRCompileError.denseSafetyViolation(
                kind: "coefficient",
                actualDB: diagnostics.maximumCoefficientOvershootDB,
                maximumDB: configuration.maximumCoefficientOvershootDB
            )
        }
        if diagnostics.maximumColumnPowerOvershootDB
            > configuration.maximumColumnPowerOvershootDB {
            throw MIMORoomTreatmentFIRCompileError.denseSafetyViolation(
                kind: "column-power",
                actualDB: diagnostics.maximumColumnPowerOvershootDB,
                maximumDB: configuration.maximumColumnPowerOvershootDB
            )
        }
        if diagnostics.maximumPerSourcePowerOvershootDB
            > configuration.maximumPerSourcePowerOvershootDB {
            throw MIMORoomTreatmentFIRCompileError.denseSafetyViolation(
                kind: "source-power",
                actualDB: diagnostics.maximumPerSourcePowerOvershootDB,
                maximumDB: configuration.maximumPerSourcePowerOvershootDB
            )
        }
    }

    private func tapOffset(
        channelCount: Int,
        tapCount: Int,
        output: Int,
        input: Int,
        tap: Int
    ) -> Int {
        ((output * channelCount + input) * tapCount) + tap
    }

    private static func smoothstep(_ x: Double) -> Double {
        x * x * (3 - 2 * x)
    }

    private static func powerSafeAmplitudeDB(_ amplitude: Double) -> Double {
        guard amplitude > 1.0 else { return 0 }
        return 20.0 * log10(amplitude)
    }

    private static func powerDB(_ power: Double) -> Double {
        guard power > 1.0 else { return 0 }
        return 10.0 * log10(power)
    }
}

private struct MIMOFIRComplexValue {
    let real: Double
    let imaginary: Double
}

private final class MIMOFIRDFT {
    private let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let zeroImaginary: [Float]

    init(size: Int) throws {
        guard let forward = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(size),
            .FORWARD
        ) else {
            throw MIMORoomTreatmentFIRCompileError.transformSetupFailed(size)
        }
        guard let inverse = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(size),
            .INVERSE
        ) else {
            vDSP_DFT_DestroySetup(forward)
            throw MIMORoomTreatmentFIRCompileError.transformSetupFailed(size)
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

    func forwardReal(_ input: [Float]) -> [MIMOFIRComplexValue] {
        precondition(input.count == size)
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        input.withUnsafeBufferPointer { inputReal in
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
        return zip(real, imaginary).map {
            MIMOFIRComplexValue(
                real: Double($0.0),
                imaginary: Double($0.1)
            )
        }
    }

    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        precondition(real.count == size && imaginary.count == size)
        var outputReal = [Float](repeating: 0, count: size)
        var outputImaginary = [Float](repeating: 0, count: size)
        real.withUnsafeBufferPointer { inputReal in
            imaginary.withUnsafeBufferPointer { inputImaginary in
                outputReal.withUnsafeMutableBufferPointer { realResult in
                    outputImaginary.withUnsafeMutableBufferPointer { imaginaryResult in
                        vDSP_DFT_Execute(
                            inverseSetup,
                            inputReal.baseAddress!,
                            inputImaginary.baseAddress!,
                            realResult.baseAddress!,
                            imaginaryResult.baseAddress!
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
