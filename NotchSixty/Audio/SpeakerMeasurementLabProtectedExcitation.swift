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


// MARK: - Slice 8B protected physical-route binding

struct SpeakerMeasurementLabProtectedDriverRouteBinding:
    Equatable, Sendable {
    var targetBus: SpeakerOutputBus
    var physicalDestination: PhysicalOutputEndpoint
    var physicalOutputChannelIndex: UInt32
    /// Carrier used only to let the existing targeted Core Audio transport
    /// recreate the exact device/aggregate topology. It does NOT determine
    /// excitation filtering; the pre-rendered protected waveform does.
    var carrierRoutePlan: LiveNChannelOutputRoutePlan
    var routingConfiguration: MultiOutputRoutingConfiguration
    var bassManagementConfiguration: BassManagementConfiguration
    var targetDriverConfiguration:
        SpeakerDriverBusProcessingConfiguration

    func matchesCurrentState(
        routing: MultiOutputRoutingConfiguration?,
        bassManagement: BassManagementConfiguration,
        driverProcessing: SpeakerDriverProcessingConfiguration?
    ) -> Bool {
        guard routing == routingConfiguration,
              bassManagement == bassManagementConfiguration,
              let driverProcessing else {
            return false
        }
        return driverProcessing.configuration(for: targetBus)
            == targetDriverConfiguration
    }
}

struct SpeakerMeasurementLabProtectedDriverCaptureProvenance:
    Codable, Equatable, Sendable {
    var targetBus: SpeakerOutputBus
    var physicalDestination: PhysicalOutputEndpoint
    var routingConfiguration: MultiOutputRoutingConfiguration
    var bassManagementConfiguration: BassManagementConfiguration
    var targetDriverConfiguration:
        SpeakerDriverBusProcessingConfiguration
    var inputPeakDBFS: Double
    var renderedPeakDBFS: Double
    var sourceFrameCount: Int
    var renderedFrameCount: Int

    var crossoverPreserved: Bool { true }
    var limiterPreserved: Bool {
        targetDriverConfiguration.enabled
            && targetDriverConfiguration.limiterEnabled
    }
}

enum SpeakerMeasurementLabProtectedDriverRouteError:
    Error, Equatable, LocalizedError {
    case invalidTargetBus
    case routingRequired
    case targetRouteMissing
    case targetRouteAmbiguous
    case physicalCrossoverRequired
    case targetUnsupportedByCrossover
    case targetLimiterRequired
    case invalidPhysicalRoute
    case insufficientCarrierRoutes

    var errorDescription: String? {
        switch self {
        case .invalidTargetBus:
            return "Protected measurement supports only split Low/Mid/High driver buses."
        case .routingRequired:
            return "Protected-driver measurement requires enabled physical multi-output routing."
        case .targetRouteMissing:
            return "The protected driver bus does not have an enabled physical output route."
        case .targetRouteAmbiguous:
            return "The protected driver bus is routed more than once; measurement requires one exact physical destination."
        case .physicalCrossoverRequired:
            return "Protected-driver measurement requires an enabled Bi-Amp or Tri-Amp physical crossover."
        case .targetUnsupportedByCrossover:
            return "The active physical crossover does not produce the requested protected driver bus."
        case .targetLimiterRequired:
            return "The requested driver path must be enabled and limiter-protected immediately before measurement."
        case .invalidPhysicalRoute:
            return "The current physical output routing cannot be compiled safely for protected measurement."
        case .insufficientCarrierRoutes:
            return "Protected measurement requires at least two valid routed physical channels to construct the measurement carrier topology."
        }
    }
}

struct SpeakerMeasurementLabProtectedDriverRoutePlanner: Sendable {
    func plan(
        targetBus: SpeakerOutputBus,
        routing: MultiOutputRoutingConfiguration?,
        bassManagement: BassManagementConfiguration,
        driverProcessing: SpeakerDriverProcessingConfiguration?,
        availableOutputs: [AudioOutputDevice],
        sampleRate: Double,
        selectedOutputUID: String
    ) throws -> SpeakerMeasurementLabProtectedDriverRouteBinding {
        guard Self.isProtectedSplitBus(targetBus) else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .invalidTargetBus
        }
        guard let routing, routing.enabled else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .routingRequired
        }
        let matching = routing.enabledRoutes.filter {
            $0.bus == targetBus
        }
        guard !matching.isEmpty else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .targetRouteMissing
        }
        guard matching.count == 1, let targetRoute = matching.first else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .targetRouteAmbiguous
        }
        guard bassManagement.enabled,
              let crossoverMode = bassManagement.physicalOutputMode,
              crossoverMode == .biAmp || crossoverMode == .triAmp else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .physicalCrossoverRequired
        }
        guard crossoverMode.supports(bus: targetBus) else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .targetUnsupportedByCrossover
        }
        guard let driverProcessing else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .targetLimiterRequired
        }
        let targetDriver = driverProcessing.configuration(for: targetBus)
        guard targetDriver.enabled, targetDriver.limiterEnabled else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .targetLimiterRequired
        }

        do {
            try routing.validate(
                availableDevices: availableOutputs,
                sampleRate: sampleRate
            )

            let orderedUIDs: [String]
            let referenceUID: String
            let physicalChannelCount: UInt32
            let routeChannels: [UInt32]
            let targetPhysical: UInt32

            if routing.usesMultiplePhysicalDevices {
                let aggregate = try routing.makeAggregateDevicePlan(
                    availableDevices: availableOutputs,
                    sampleRate: sampleRate
                )
                try aggregate.validateForC4LiveTransport(
                    selectedOutputUID: selectedOutputUID,
                    crossoverMode: crossoverMode
                )
                orderedUIDs = aggregate.orderedDeviceUIDs
                referenceUID = aggregate.referenceDeviceUID
                physicalChannelCount = aggregate.physicalChannelCount
                routeChannels = aggregate.mappedRoutes.map(
                    \.aggregateChannelIndex
                )
                guard let mapped = aggregate.mappedRoutes.first(
                    where: { $0.route.id == targetRoute.id }
                ) else {
                    throw SpeakerMeasurementLabProtectedDriverRouteError
                        .invalidPhysicalRoute
                }
                targetPhysical = mapped.aggregateChannelIndex
            } else {
                let same = try routing.makeSameDevicePlan(
                    availableDevices: availableOutputs,
                    sampleRate: sampleRate
                )
                try same.validateForC4LiveTransport(
                    selectedOutputUID: selectedOutputUID,
                    crossoverMode: crossoverMode
                )
                orderedUIDs = [same.deviceUID]
                referenceUID = same.deviceUID
                physicalChannelCount = same.physicalChannelCount
                routeChannels = same.routes.map(
                    \.destination.channelIndex
                )
                targetPhysical = targetRoute.destination.channelIndex
            }

            let uniqueCarrierChannels = routeChannels.reduce(
                into: [UInt32]()
            ) { result, channel in
                if !result.contains(channel) {
                    result.append(channel)
                }
            }
            guard uniqueCarrierChannels.count >= 2 else {
                throw SpeakerMeasurementLabProtectedDriverRouteError
                    .insufficientCarrierRoutes
            }

            let carrier = LiveNChannelOutputRoutePlan(
                programLayout: .stereo,
                orderedDeviceUIDs: orderedUIDs,
                referenceDeviceUID: referenceUID,
                physicalChannelCount: physicalChannelCount,
                programPhysicalChannels:
                    Array(uniqueCarrierChannels.prefix(2)),
                subwooferPhysicalChannels: [],
                subwooferCount: 0,
                bassManagementEnabled: false,
                speakerCalibrations: [:],
                subwooferCalibrations: [],
                speakerOptimizerPEQ: [:]
            )
            _ = try carrier.makeRealtimeOutputMap()
            guard targetPhysical < physicalChannelCount else {
                throw SpeakerMeasurementLabProtectedDriverRouteError
                    .invalidPhysicalRoute
            }

            return SpeakerMeasurementLabProtectedDriverRouteBinding(
                targetBus: targetBus,
                physicalDestination: targetRoute.destination,
                physicalOutputChannelIndex: targetPhysical,
                carrierRoutePlan: carrier,
                routingConfiguration: routing,
                bassManagementConfiguration: bassManagement,
                targetDriverConfiguration: targetDriver
            )
        } catch let error as SpeakerMeasurementLabProtectedDriverRouteError {
            throw error
        } catch {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .invalidPhysicalRoute
        }
    }

    static func isProtectedSplitBus(
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

extension SpeakerMeasurementLabProtectedExcitation {
    func makeCaptureProvenance(
        binding: SpeakerMeasurementLabProtectedDriverRouteBinding
    ) throws -> SpeakerMeasurementLabProtectedDriverCaptureProvenance {
        guard binding.targetBus == targetBus,
              binding.bassManagementConfiguration
                == bassManagementConfiguration,
              binding.targetDriverConfiguration
                == targetDriverConfiguration else {
            throw SpeakerMeasurementLabProtectedDriverRouteError
                .invalidPhysicalRoute
        }
        return SpeakerMeasurementLabProtectedDriverCaptureProvenance(
            targetBus: targetBus,
            physicalDestination: binding.physicalDestination,
            routingConfiguration: binding.routingConfiguration,
            bassManagementConfiguration: bassManagementConfiguration,
            targetDriverConfiguration: targetDriverConfiguration,
            inputPeakDBFS: inputPeakDBFS,
            renderedPeakDBFS: renderedPeakDBFS,
            sourceFrameCount: sourceFrameCount,
            renderedFrameCount: renderedSamples.count
        )
    }

    /// Keep the ORIGINAL upstream ESS as the deconvolution reference but extend
    /// its capture tail by exactly the protected renderer's flush frames.
    /// Therefore the measured transfer includes crossover + driver protection
    /// rather than mathematically dividing those stages away.
    func makeAnalysisProgram(
        from sourceProgram: RoomCorrectionSweepProgram
    ) throws -> RoomCorrectionSweepProgram {
        guard sourceProgram.sweepSamples.count == sourceFrameCount,
              abs(sourceProgram.sampleRate - sampleRate) < 0.5,
              renderedSamples.count >= sourceFrameCount else {
            throw SpeakerMeasurementLabProtectedExcitationError
                .invalidExcitation
        }
        let extraFrames = renderedSamples.count - sourceFrameCount
        guard sourceProgram.tailFrames <= Int.max - extraFrames else {
            throw RoomCorrectionSweepGenerationError.frameCountOverflow
        }
        var result = sourceProgram
        result.tailFrames += extraFrames
        return result
    }
}
