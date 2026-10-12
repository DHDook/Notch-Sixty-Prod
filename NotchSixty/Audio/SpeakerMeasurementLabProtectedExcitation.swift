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

struct SpeakerMeasurementLabProtectedExcitation:
    Equatable, Sendable {
    var targetBus: SpeakerOutputBus
    var sampleRate: Double
    var sourceFrameCount: Int
    var renderedSamples: [Float]
    var inputPeakDBFS: Double
    var renderedPeakDBFS: Double
    var bassManagementConfiguration: BassManagementConfiguration
    var driverProcessingConfiguration:
        SpeakerDriverProcessingConfiguration
    var targetDriverConfiguration:
        SpeakerDriverBusProcessingConfiguration

    var preservesMandatoryCrossover: Bool { true }
    var preservesConfiguredDriverProcessing: Bool { true }
    var limiterProtected: Bool {
        targetDriverConfiguration.enabled
            && targetDriverConfiguration.limiterEnabled
    }

    /// Slice 8A proves the program can be rendered safely. It deliberately
    /// does NOT authorize the existing raw physical-lane transport yet.
    var canStartPhysicalMeasurement: Bool { false }
    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
}

enum SpeakerMeasurementLabProtectedExcitationError:
    Error, Equatable, LocalizedError {
    case invalidOptions
    case invalidSampleRate
    case invalidTargetBus
    case physicalCrossoverRequired
    case targetUnsupportedByCrossover
    case targetDriverProcessingRequired
    case targetLimiterRequired
    case excitationTooHot(Double)
    case invalidExcitation
    case renderFailed
    case silentProtectedOutput

    var errorDescription: String? {
        switch self {
        case .invalidOptions:
            return "Protected-driver excitation options are invalid."
        case .invalidSampleRate:
            return "Protected-driver excitation requires a finite supported sample rate."
        case .invalidTargetBus:
            return "Protected-driver excitation supports only split Low/Mid/High buses."
        case .physicalCrossoverRequired:
            return "Enable an explicit Bi-Amp or Tri-Amp physical crossover before protected-driver measurement."
        case .targetUnsupportedByCrossover:
            return "The selected driver bus is not produced by the active physical crossover mode."
        case .targetDriverProcessingRequired:
            return "The selected driver bus must have an enabled per-driver processing path."
        case .targetLimiterRequired:
            return "Protected-driver measurement requires the selected driver's limiter to be enabled."
        case .excitationTooHot(let peak):
            return "Protected-driver excitation peak \(String(format: "%.1f", peak)) dBFS exceeds the configured safety ceiling."
        case .invalidExcitation:
            return "Protected-driver excitation contains invalid, empty, or silent samples."
        case .renderFailed:
            return "The production crossover/driver protection chain could not render the protected excitation."
        case .silentProtectedOutput:
            return "The protected crossover/driver chain produced no usable excitation for this bus."
        }
    }
}

/// Control-plane compiler for future direct-driver measurement.
///
/// The raw physical measurement transport remains blocked in Slice 8A. This
/// compiler first proves that the exact production speaker bus splitter AND
/// target per-driver processor (including its limiter) can transform a bounded
/// mono sweep into a safe target-bus program.
struct SpeakerMeasurementLabProtectedExcitationCompiler: Sendable {
    func compile(
        monoSamples: [Float],
        sampleRate: Double,
        targetBus: SpeakerOutputBus,
        bassManagement: BassManagementConfiguration,
        driverProcessing: SpeakerDriverProcessingConfiguration,
        options: SpeakerMeasurementLabProtectedExcitationOptions = .init()
    ) throws -> SpeakerMeasurementLabProtectedExcitation {
        guard options.validate() else {
            throw SpeakerMeasurementLabProtectedExcitationError.invalidOptions
        }
        guard sampleRate.isFinite,
              (16_000...384_000).contains(sampleRate) else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .invalidSampleRate
        }
        guard isProtectedSplitBus(targetBus) else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .invalidTargetBus
        }
        guard bassManagement.enabled,
              let mode = bassManagement.physicalOutputMode,
              mode == .biAmp || mode == .triAmp else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .physicalCrossoverRequired
        }
        guard mode.supports(bus: targetBus) else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .targetUnsupportedByCrossover
        }

        let targetDriver = driverProcessing.configuration(
            for: targetBus
        )
        guard targetDriver.enabled else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .targetDriverProcessingRequired
        }
        guard targetDriver.limiterEnabled else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .targetLimiterRequired
        }

        guard !monoSamples.isEmpty,
              monoSamples.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .invalidExcitation
        }
        let peak = monoSamples.reduce(Float(0)) {
            max($0, abs($1))
        }
        guard peak.isFinite, peak > 1.0e-8 else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .invalidExcitation
        }
        let peakDBFS = 20 * log10(Double(peak))
        guard peakDBFS <= options.maximumInputPeakDBFS + 1.0e-6 else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .excitationTooHot(peakDBFS)
        }

        let flushFrames = max(
            1,
            Int((options.flushSeconds * sampleRate).rounded(.up))
        )
        var padded = monoSamples
        padded.append(
            contentsOf: repeatElement(Float(0), count: flushFrames)
        )

        var splitter = try bassManagement
            .makeSpeakerBusSplitterSnapshot(sampleRate: sampleRate)
        var driver = try driverProcessing
            .makeRealtimeSnapshot(sampleRate: sampleRate)
        var rendered = [Float](
            repeating: 0,
            count: padded.count
        )

        let success = padded.withUnsafeBufferPointer { input in
            rendered.withUnsafeMutableBufferPointer { output in
                N60ProtectedSpeakerBusRenderProgram(
                    input.baseAddress!,
                    UInt32(input.count),
                    targetBus.realtimeCType,
                    splitter,
                    driver,
                    output.baseAddress!
                )
            }
        }
        guard success else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .renderFailed
        }
        guard rendered.allSatisfy(\.isFinite) else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .renderFailed
        }
        let renderedPeak = rendered.reduce(Float(0)) {
            max($0, abs($1))
        }
        guard renderedPeak.isFinite, renderedPeak > 1.0e-9 else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .silentProtectedOutput
        }

        return SpeakerMeasurementLabProtectedExcitation(
            targetBus: targetBus,
            sampleRate: sampleRate,
            sourceFrameCount: monoSamples.count,
            renderedSamples: rendered,
            inputPeakDBFS: peakDBFS,
            renderedPeakDBFS:
                20 * log10(Double(renderedPeak)),
            bassManagementConfiguration: bassManagement,
            driverProcessingConfiguration: driverProcessing,
            targetDriverConfiguration: targetDriver
        )
    }

    private func isProtectedSplitBus(
        _ bus: SpeakerOutputBus
    ) -> Bool {
        switch bus {
        case .leftLow, .rightLow,
             .leftMid, .rightMid,
             .leftHigh, .rightHigh:
            return true
        case .leftFullRange, .rightFullRange, .subMono:
            return false
        }
    }
}
