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


extension SpeakerMeasurementLabProtectedDriverCaptureProvenance {
    func validatesProtectedPath(
        for targetBus: SpeakerOutputBus
    ) -> Bool {
        guard self.targetBus == targetBus,
              SpeakerMeasurementLabProtectedDriverRoutePlanner
                .isProtectedSplitBus(targetBus),
              routingConfiguration.enabled,
              routingConfiguration.enabledRoutes.filter({
                  $0.bus == targetBus
                    && $0.destination == physicalDestination
              }).count == 1,
              bassManagementConfiguration.enabled,
              let mode =
                bassManagementConfiguration.physicalOutputMode,
              (mode == .biAmp || mode == .triAmp),
              mode.supports(bus: targetBus),
              targetDriverConfiguration.bus == targetBus,
              targetDriverConfiguration.enabled,
              targetDriverConfiguration.limiterEnabled,
              inputPeakDBFS.isFinite,
              inputPeakDBFS <= -24.0 + 1.0e-6,
              renderedPeakDBFS.isFinite,
              renderedPeakDBFS <= 0,
              sourceFrameCount > 0,
              renderedFrameCount >= sourceFrameCount else {
            return false
        }
        return true
    }
}


// MARK: - PR111 Slice 1: protected, recommendation-only per-driver PEQ

/// Reviewable frequency-domain hypothesis. It does NOT create an EQBand,
/// change a Playback System or authorize any crossover/limiter modification.
/// Negative dB only, at most three isolated, broad protected-passband cuts.
struct ProtectedDriverPEQCut: Equatable, Sendable {
    var frequencyHz: Double
    var gainDB: Double
    var q: Double
    var observedBroadPeakDB: Double
}

/// All provenance remains tied to one exact Lab protocol and one already
/// configured protected driver. Future guarded Apply must recheck *current*
/// routing/crossover/limiter state and independently measure the acoustic sum.
struct ProtectedDriverPEQRecommendation: Equatable, Sendable {
    var sessionID: UUID
    var protocolID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var targetBus: SpeakerOutputBus
    var protectedConfiguration: SpeakerDriverBusProcessingConfiguration
    var bassManagement: BassManagementConfiguration
    var sampleRate: Double
    var repeatedCaptureIDs: [UUID]
    var passbandLowHz: Double
    var passbandHighHz: Double
    var cuts: [ProtectedDriverPEQCut]
    var evidenceSummary: String

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canChangeDelayOrPolarity: Bool { false }
    var canAlterCrossoverOrLimiter: Bool { false }
    var requiresNewMeasuredVerification: Bool { true }
}

enum ProtectedDriverPEQRecommendationError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case unsupportedDriverBus
    case protectedPathRequired
    case inadequateRepeatedEvidence
    case incompatibleResponseGrid
    case noUsableCrossoverPassband

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Protected driver measurements must pass session integrity checks."
        case .unsupportedDriverBus:
            return "Per-driver optimization requires one exact Low/Mid/High bus."
        case .protectedPathRequired:
            return "The selected capture must retain the exact active crossover, limiter and physical bus provenance."
        case .inadequateRepeatedEvidence:
            return "At least three repeat-qualified, unclipped protected-driver captures are required."
        case .incompatibleResponseGrid:
            return "The protected driver sweeps need an identical, finite frequency-response grid."
        case .noUsableCrossoverPassband:
            return "No reliable frequency range remains away from mandatory crossover boundaries."
        }
    }
}

/// Deliberately makes no attempt to flatten overall slope, fill nulls, align
/// acoustic centers, recommend polarity, change delay or optimize crossover.
/// A conservative repeat-stable peak *cut* is safer than applying modeled
/// boosts to an individual exposed driver without hardware verification.
struct ProtectedDriverPEQRecommendationAnalyzer: Sendable {
    static let minimumRepeats = 3
    static let minimumSNRDB = 35.0
    static let maximumRepeatSpreadDB = 0.85
    static let minimumPeakDeviationDB = 2.0
    static let maximumCutDB = 2.5
    static let maximumSuggestedBands = 3
    static let maximumBandQ = 1.4

    func recommend(
        session: SpeakerMeasurementLabSession,
        protocolID: UUID
    ) throws -> ProtectedDriverPEQRecommendation {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverPEQRecommendationError.invalidSession }

        guard let protocolItem = session.protocols.first(
            where: { $0.id == protocolID }
        ),
        protocolItem.request.mode == .protectedDriverNearField,
        let bus = protocolItem.protectedDriverBus else {
            throw ProtectedDriverPEQRecommendationError.unsupportedDriverBus
        }
        guard SpeakerMeasurementLabProtectedDriverRoutePlanner
            .isProtectedSplitBus(bus) else {
            throw ProtectedDriverPEQRecommendationError.unsupportedDriverBus
        }

        let captures = session.captures.filter {
            $0.protocolID == protocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard captures.count >= Self.minimumRepeats,
              captures.count == protocolItem.request.repeatCount,
              captures.map(\.repeatIndex) == Array(0..<captures.count),
              let provenance = captures.first?.protectedDriverProvenance,
              provenance.validatesProtectedPath(for: bus),
              captures.allSatisfy({
                  $0.protectedDriverProvenance == provenance
                      && $0.quality.sweepComplete
                      && !$0.quality.clipped
                      && $0.quality.estimatedSNRDB.map({
                          $0.isFinite && $0 >= Self.minimumSNRDB
                      }) == true
              }) else {
            throw ProtectedDriverPEQRecommendationError
                .inadequateRepeatedEvidence
        }
        let reference = captures[0].transferFunction
        let grid = reference.frequenciesHz
        guard grid.count >= 48,
              grid.count == reference.magnitudeDB.count,
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              captures.allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                  && $0.transferFunction.magnitudeDB.count == grid.count
                  && $0.transferFunction.magnitudeDB.allSatisfy(\.isFinite)
              }) else {
            throw ProtectedDriverPEQRecommendationError
                .incompatibleResponseGrid
        }
        let bass = provenance.bassManagementConfiguration
        guard bass.enabled,
              let physicalMode = bass.physicalOutputMode,
              (physicalMode == .biAmp || physicalMode == .triAmp),
              physicalMode.supports(bus: bus) else {
            throw ProtectedDriverPEQRecommendationError.protectedPathRequired
        }
        let fc = bass.frequencyHz
        let upper = bass.upperFrequencyHz ?? 0
        let nyquistCeiling = min(16_000.0, session.sampleRate * 0.42)
        var low = 30.0
        var high = nyquistCeiling
        switch bus {
        case .leftLow, .rightLow:
            high = min(high, fc / 1.5)
        case .leftMid, .rightMid:
            low = max(low, fc * 1.5)
            high = min(high, upper / 1.5)
        case .leftHigh, .rightHigh:
            low = max(low, (physicalMode == .triAmp ? upper : fc) * 1.5)
        case .leftFullRange, .rightFullRange, .subMono:
            throw ProtectedDriverPEQRecommendationError.unsupportedDriverBus
        }
        let measuredLow = captures.compactMap {
            $0.quality.usableLowHz
        }.max() ?? .infinity
        let measuredHigh = captures.compactMap {
            $0.quality.usableHighHz
        }.min() ?? 0
        low = max(low, measuredLow)
        high = min(high, measuredHigh)
        guard fc.isFinite, fc > 0, upper.isFinite,
              low.isFinite, high.isFinite,
              high > low * 1.7 else {
            throw ProtectedDriverPEQRecommendationError
                .noUsableCrossoverPassband
        }
        let indices = grid.indices.filter {
            grid[$0] >= low && grid[$0] <= high
        }
        guard indices.count >= 24 else {
            throw ProtectedDriverPEQRecommendationError
                .noUsableCrossoverPassband
        }
        let means = grid.indices.map { i in
            captures.reduce(0.0) {
                $0 + $1.transferFunction.magnitudeDB[i]
            } / Double(captures.count)
        }
        let stable = indices.filter { i in
            let readings = captures.map {
                $0.transferFunction.magnitudeDB[i]
            }
            return (readings.max()! - readings.min()!)
                <= Self.maximumRepeatSpreadDB
        }
        guard stable.count >= 24,
              Double(stable.count) / Double(indices.count) >= 0.90 else {
            throw ProtectedDriverPEQRecommendationError
                .inadequateRepeatedEvidence
        }

        // Only detect local, repeat-stable bumps against surrounding
        // frequencies; never correct broadband tilt or narrow noise bins.
        var possible: [(frequency: Double, deviation: Double)] = []
        for i in stable {
            let center = grid[i]
            let neighbors = stable.filter { j in
                let distance = abs(log2(grid[j] / center))
                return distance >= 0.22 && distance <= 0.80
            }
            guard neighbors.count >= 12,
                  stable.contains(i - 1), stable.contains(i + 1) else {
                continue
            }
            let surround = neighbors.map { means[$0] }
                .reduce(0, +) / Double(neighbors.count)
            let bump = means[i] - surround
            guard bump >= Self.minimumPeakDeviationDB,
                  means[i] >= means[i - 1],
                  means[i] >= means[i + 1] else {
                continue
            }
            possible.append((frequency: center, deviation: bump))
        }
        possible.sort {
            if $0.deviation != $1.deviation {
                return $0.deviation > $1.deviation
            }
            return $0.frequency < $1.frequency
        }
        var cuts: [ProtectedDriverPEQCut] = []
        for candidate in possible {
            guard cuts.count < Self.maximumSuggestedBands else { break }
            let separated = cuts.allSatisfy {
                abs(log2($0.frequencyHz / candidate.frequency)) >= 0.55
            }
            guard separated else { continue }
            cuts.append(
                ProtectedDriverPEQCut(
                    frequencyHz: candidate.frequency,
                    gainDB: -min(Self.maximumCutDB,
                                 candidate.deviation * 0.55),
                    q: Self.maximumBandQ,
                    observedBroadPeakDB: candidate.deviation
                )
            )
        }
        return ProtectedDriverPEQRecommendation(
            sessionID: session.id,
            protocolID: protocolID,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            targetBus: bus,
            protectedConfiguration: provenance.targetDriverConfiguration,
            bassManagement: bass,
            sampleRate: session.sampleRate,
            repeatedCaptureIDs: captures.map(\.id),
            passbandLowHz: low,
            passbandHighHz: high,
            cuts: cuts,
            evidenceSummary:
                "Protected \(bus.displayName) near-field repeated sweeps; " +
                "0–3 cut-only, bounded peak hypotheses in the guarded passband. " +
                "No active driver EQ, delay, polarity, limiter or crossover change."
        )
    }
}


// MARK: - PR111 Slice 3: shared-reference driver timing hypotheses

enum ProtectedDriverTimingPolarityHypothesis:
    String, Equatable, Sendable {
    case retainCurrent
    case invertComparedDriver
    case inconclusive
}

/// Recommendation-only evidence for ONE adjacent protected driver pair.
/// The measured captures already include the installed crossover, current
/// per-driver delay and polarity. Any suggested delay is therefore an
/// *additional* bounded adjustment to the earlier driver, never an absolute
/// acoustic-center value or a command to mutate the DSP.
struct ProtectedDriverTimingRecommendation: Equatable, Sendable {
    var sessionID: UUID
    var firstProtocolID: UUID
    var secondProtocolID: UUID
    var playbackSystemID: UUID
    var routingSignature: String
    var firstBus: SpeakerOutputBus
    var secondBus: SpeakerOutputBus
    var crossoverFrequencyHz: Double
    /// second minus first after subtracting each simultaneous electrical
    /// reference arrival. Positive means the second acoustic path is later.
    var relativeArrivalMilliseconds: Double
    var referenceArrivalSpreadMilliseconds: Double
    var referenceMagnitudeRepeatabilityRMSDB: Double
    var referencePhaseConsistency: Double
    var wrappedRelativePhaseAtCrossoverRadians: Double
    var delayBus: SpeakerOutputBus?
    var additionalDelayMilliseconds: Double?
    var polarityHypothesis: ProtectedDriverTimingPolarityHypothesis
    var evidenceConfidence: Double
    var warnings: [String]

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canChangeCrossoverOrLimiter: Bool { false }
    var requiresCombinedDriverVerification: Bool { true }
}

enum ProtectedDriverTimingRecommendationError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case invalidPair
    case protectedPathMismatch
    case sharedReferenceRequired
    case referencePathUnstable
    case inadequateRepeatedEvidence
    case incompatibleFrequencyGrid
    case crossoverBandUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Protected driver timing requires a structurally valid Measurement Lab session."
        case .invalidPair:
            return "Select two adjacent Low/Mid/High buses on the same physical speaker."
        case .protectedPathMismatch:
            return "Both drivers must share the same protected routing and active crossover topology."
        case .sharedReferenceRequired:
            return "Every repeat requires a qualified simultaneous electrical reference on the same ADC timeline."
        case .referencePathUnstable:
            return "The electrical reference changed too much across the driver sweeps to authenticate cross-driver timing."
        case .inadequateRepeatedEvidence:
            return "Each driver needs at least three complete, unclipped, stable protected sweeps."
        case .incompatibleFrequencyGrid:
            return "Both protected drivers and their reference captures need one identical finite frequency grid."
        case .crossoverBandUnavailable:
            return "The pair lacks sufficient qualified measured evidence around its protected crossover."
        }
    }
}

struct ProtectedDriverTimingRecommendationAnalyzer: Sendable {
    static let minimumRepeats = 3
    static let minimumSNRDB = 35.0
    static let maximumReferenceArrivalSpreadMilliseconds = 0.25
    static let maximumReferenceMagnitudeRepeatabilityRMSDB = 0.50
    static let minimumReferencePhaseConsistency = 0.98
    static let maximumAdditionalDelayMilliseconds = 2.0
    static let minimumMeaningfulDelayMilliseconds = 0.05
    static let polarityDecisionMarginRadians = Double.pi / 4

    func recommend(
        session: SpeakerMeasurementLabSession,
        firstProtocolID: UUID,
        secondProtocolID: UUID
    ) throws -> ProtectedDriverTimingRecommendation {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverTimingRecommendationError.invalidSession }
        guard session.sharedClockReferenceConfiguration != nil,
              let firstProtocol = session.protocols.first(
                where: { $0.id == firstProtocolID }
              ),
              let secondProtocol = session.protocols.first(
                where: { $0.id == secondProtocolID }
              ),
              firstProtocol.request.mode == .protectedDriverNearField,
              secondProtocol.request.mode == .protectedDriverNearField,
              let firstBus = firstProtocol.protectedDriverBus,
              let secondBus = secondProtocol.protectedDriverBus,
              SpeakerMeasurementLabProtectedDriverRoutePlanner
                .isProtectedSplitBus(firstBus),
              SpeakerMeasurementLabProtectedDriverRoutePlanner
                .isProtectedSplitBus(secondBus),
              sameSpeakerSide(firstBus, secondBus) else {
            throw ProtectedDriverTimingRecommendationError.invalidPair
        }
        let first = session.captures.filter {
            $0.protocolID == firstProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        let second = session.captures.filter {
            $0.protocolID == secondProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard first.count >= Self.minimumRepeats,
              second.count >= Self.minimumRepeats,
              first.count == firstProtocol.request.repeatCount,
              second.count == secondProtocol.request.repeatCount,
              first.map(\.repeatIndex) == Array(0..<first.count),
              second.map(\.repeatIndex) == Array(0..<second.count) else {
            throw ProtectedDriverTimingRecommendationError
                .inadequateRepeatedEvidence
        }
        guard let firstProvenance = first.first?.protectedDriverProvenance,
              let secondProvenance = second.first?.protectedDriverProvenance,
              firstProvenance.validatesProtectedPath(for: firstBus),
              secondProvenance.validatesProtectedPath(for: secondBus),
              first.allSatisfy({
                  $0.protectedDriverProvenance == firstProvenance
              }),
              second.allSatisfy({
                  $0.protectedDriverProvenance == secondProvenance
              }),
              sameProtectedRoutingTopology(
                  firstProvenance.routingConfiguration,
                  secondProvenance.routingConfiguration
              ),
              firstProvenance.bassManagementConfiguration
                == secondProvenance.bassManagementConfiguration else {
            throw ProtectedDriverTimingRecommendationError
                .protectedPathMismatch
        }
        let bass = firstProvenance.bassManagementConfiguration
        guard bass.enabled,
              let mode = bass.physicalOutputMode,
              (mode == .biAmp || mode == .triAmp),
              mode.supports(bus: firstBus),
              mode.supports(bus: secondBus),
              adjacent(firstBus, secondBus, mode: mode),
              let crossover = crossoverFrequency(
                firstBus, secondBus, bass
              ),
              crossover.isFinite, crossover > 0 else {
            throw ProtectedDriverTimingRecommendationError.invalidPair
        }

        let captures = first + second
        guard captures.allSatisfy({
            $0.quality.sweepComplete
                && !$0.quality.clipped
                && $0.quality.estimatedSNRDB.map({
                    $0.isFinite && $0 >= Self.minimumSNRDB
                }) == true
                && $0.quality.directArrivalSeconds?.isFinite == true
                && $0.sharedClockReference?.sharedTimeOriginQualified == true
        }) else {
            throw ProtectedDriverTimingRecommendationError
                .inadequateRepeatedEvidence
        }
        guard let grid = captures.first?.transferFunction.frequenciesHz,
              grid.count >= 48,
              grid.allSatisfy({ $0.isFinite && $0 > 0 }),
              zip(grid, grid.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
              captures.allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                    && $0.transferFunction.magnitudeDB.count == grid.count
                    && $0.transferFunction.phaseRadians?.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.frequenciesHz == grid
                    && $0.sharedClockReference?
                        .transferFunction.magnitudeDB.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.phaseRadians?.count == grid.count
              }) else {
            throw ProtectedDriverTimingRecommendationError
                .incompatibleFrequencyGrid
        }

        let lower = crossover / 1.35
        let upper = crossover * 1.35
        let indices = grid.indices.filter {
            grid[$0] >= lower && grid[$0] <= upper
        }
        guard indices.count >= 8,
              captures.allSatisfy({
                  ($0.quality.usableLowHz ?? .infinity) <= lower
                    && ($0.quality.usableHighHz ?? 0) >= upper
              }) else {
            throw ProtectedDriverTimingRecommendationError
                .crossoverBandUnavailable
        }

        let references = captures.compactMap(\.sharedClockReference)
        guard references.count == captures.count else {
            throw ProtectedDriverTimingRecommendationError
                .sharedReferenceRequired
        }
        let referenceArrivals = references.map(\.directArrivalSeconds)
        let referenceArrivalSpread = (
            (referenceArrivals.max() ?? .infinity)
                - (referenceArrivals.min() ?? -.infinity)
        ) * 1_000
        let referenceMagnitudeRMS = rmsDeviationFromMean(
            references.map { reference in
                indices.map {
                    reference.transferFunction.magnitudeDB[$0]
                }
            }
        )
        let referencePhaseConsistency = circularConsistency(
            references.map { reference in
                indices.map {
                    reference.transferFunction.phaseRadians![$0]
                }
            }
        )
        guard referenceArrivalSpread.isFinite,
              referenceArrivalSpread
                <= Self.maximumReferenceArrivalSpreadMilliseconds,
              referenceMagnitudeRMS.isFinite,
              referenceMagnitudeRMS
                <= Self.maximumReferenceMagnitudeRepeatabilityRMSDB,
              referencePhaseConsistency.isFinite,
              referencePhaseConsistency
                >= Self.minimumReferencePhaseConsistency else {
            throw ProtectedDriverTimingRecommendationError
                .referencePathUnstable
        }

        let firstArrival = try correctedArrival(first)
        let secondArrival = try correctedArrival(second)
        let relativeArrival = (secondArrival - firstArrival) * 1_000
        let firstPhase = try correctedPhase(
            first, indices: indices, grid: grid
        )
        let secondPhase = try correctedPhase(
            second, indices: indices, grid: grid
        )
        // correctedPhase() has already removed each acoustic arrival
        // against its simultaneous electrical reference. Compare only the
        // remaining residual phase; do not subtract the timing slope twice.
        let relativePhases = zip(secondPhase, firstPhase).map {
            wrap($0.0 - $0.1)
        }
        let relativePhase = circularMean(relativePhases)

        let delayMagnitude = abs(relativeArrival)
        let delayBus: SpeakerOutputBus?
        let additionalDelay: Double?
        if delayMagnitude >= Self.minimumMeaningfulDelayMilliseconds,
           delayMagnitude <= Self.maximumAdditionalDelayMilliseconds {
            // Delay whichever acoustic path currently arrives first.
            delayBus = relativeArrival > 0 ? firstBus : secondBus
            additionalDelay = delayMagnitude
        } else {
            delayBus = nil
            additionalDelay = nil
        }

        let currentDistance = abs(wrap(relativePhase))
        let invertedDistance = abs(wrap(relativePhase + .pi))
        let polarity: ProtectedDriverTimingPolarityHypothesis
        if invertedDistance + Self.polarityDecisionMarginRadians
            < currentDistance {
            polarity = .invertComparedDriver
        } else if currentDistance + Self.polarityDecisionMarginRadians
                    < invertedDistance {
            polarity = .retainCurrent
        } else {
            polarity = .inconclusive
        }

        let captureConfidence = captures.map {
            min(
                1.0,
                max(
                    0.0,
                    (($0.quality.estimatedSNRDB ?? Self.minimumSNRDB)
                        - Self.minimumSNRDB) / 30.0
                )
            )
        }.min() ?? 0
        return ProtectedDriverTimingRecommendation(
            sessionID: session.id,
            firstProtocolID: firstProtocolID,
            secondProtocolID: secondProtocolID,
            playbackSystemID: session.playbackSystemID,
            routingSignature: session.routingSignature,
            firstBus: firstBus,
            secondBus: secondBus,
            crossoverFrequencyHz: crossover,
            relativeArrivalMilliseconds: relativeArrival,
            referenceArrivalSpreadMilliseconds: referenceArrivalSpread,
            referenceMagnitudeRepeatabilityRMSDB: referenceMagnitudeRMS,
            referencePhaseConsistency: referencePhaseConsistency,
            wrappedRelativePhaseAtCrossoverRadians: relativePhase,
            delayBus: delayBus,
            additionalDelayMilliseconds: additionalDelay,
            polarityHypothesis: polarity,
            evidenceConfidence: min(
                captureConfidence, referencePhaseConsistency
            ),
            warnings: [
                "Reference-aligned driver timing is valid only for this exact protected routing, crossover, microphone/reference input, sample rate and session.",
                "Delay is a bounded additional hypothesis for the currently earlier driver; it is not an absolute acoustic-center distance.",
                "Polarity is a phase-comparison hypothesis only. Combined-driver crossover summation must be measured before any Apply.",
                "No driver delay, polarity, crossover, limiter, PEQ or live route is changed by this analysis."
            ]
        )
    }

    private func sameProtectedRoutingTopology(
        _ lhs: MultiOutputRoutingConfiguration,
        _ rhs: MultiOutputRoutingConfiguration
    ) -> Bool {
        guard lhs.enabled == rhs.enabled,
              lhs.synchronizationMode == rhs.synchronizationMode,
              lhs.resolvedReferenceDeviceUID
                == rhs.resolvedReferenceDeviceUID else {
            return false
        }
        let left = lhs.enabledRoutes.map {
            ($0.bus.rawValue, $0.destination.deviceUID,
             $0.destination.channelIndex)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        let right = rhs.enabledRoutes.map {
            ($0.bus.rawValue, $0.destination.deviceUID,
             $0.destination.channelIndex)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        return left.elementsEqual(right) {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        }
    }

    private func sameSpeakerSide(
        _ first: SpeakerOutputBus,
        _ second: SpeakerOutputBus
    ) -> Bool {
        let left: Set<String> = [
            SpeakerOutputBus.leftLow.rawValue,
            SpeakerOutputBus.leftMid.rawValue,
            SpeakerOutputBus.leftHigh.rawValue,
        ]
        let right: Set<String> = [
            SpeakerOutputBus.rightLow.rawValue,
            SpeakerOutputBus.rightMid.rawValue,
            SpeakerOutputBus.rightHigh.rawValue,
        ]
        return (left.contains(first.rawValue) && left.contains(second.rawValue))
            || (right.contains(first.rawValue)
                && right.contains(second.rawValue))
    }

    private func adjacent(
        _ first: SpeakerOutputBus,
        _ second: SpeakerOutputBus,
        mode: SpeakerCrossoverMode
    ) -> Bool {
        switch mode {
        case .biAmp:
            switch (first, second) {
            case (.leftLow, .leftHigh), (.leftHigh, .leftLow),
                 (.rightLow, .rightHigh), (.rightHigh, .rightLow):
                return true
            default:
                return false
            }
        case .triAmp:
            switch (first, second) {
            case (.leftLow, .leftMid), (.leftMid, .leftLow),
                 (.leftMid, .leftHigh), (.leftHigh, .leftMid),
                 (.rightLow, .rightMid), (.rightMid, .rightLow),
                 (.rightMid, .rightHigh), (.rightHigh, .rightMid):
                return true
            default:
                return false
            }
        default:
            return false
        }
    }

    private func crossoverFrequency(
        _ first: SpeakerOutputBus,
        _ second: SpeakerOutputBus,
        _ bass: BassManagementConfiguration
    ) -> Double? {
        switch (first, second) {
        case (.leftLow, .leftHigh), (.leftHigh, .leftLow),
             (.rightLow, .rightHigh), (.rightHigh, .rightLow),
             (.leftLow, .leftMid), (.leftMid, .leftLow),
             (.rightLow, .rightMid), (.rightMid, .rightLow):
            return bass.frequencyHz
        case (.leftMid, .leftHigh), (.leftHigh, .leftMid),
             (.rightMid, .rightHigh), (.rightHigh, .rightMid):
            return bass.upperFrequencyHz
        default:
            return nil
        }
    }

    private func correctedArrival(
        _ captures: [SpeakerMeasurementLabCapture]
    ) throws -> Double {
        let values = try captures.map { capture -> Double in
            guard let acoustic = capture.quality.directArrivalSeconds,
                  let reference = capture.sharedClockReference?
                    .directArrivalSeconds else {
                throw ProtectedDriverTimingRecommendationError
                    .sharedReferenceRequired
            }
            return acoustic - reference
        }
        let mean = values.reduce(0, +) / Double(values.count)
        guard mean.isFinite else {
            throw ProtectedDriverTimingRecommendationError
                .sharedReferenceRequired
        }
        return mean
    }

    private func correctedPhase(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int],
        grid: [Double]
    ) throws -> [Double] {
        var real = Array(repeating: 0.0, count: indices.count)
        var imag = Array(repeating: 0.0, count: indices.count)
        for capture in captures {
            guard let acousticPhase =
                    capture.transferFunction.phaseRadians,
                  let acousticArrival =
                    capture.quality.directArrivalSeconds,
                  let reference = capture.sharedClockReference,
                  let referencePhase =
                    reference.transferFunction.phaseRadians else {
                throw ProtectedDriverTimingRecommendationError
                    .sharedReferenceRequired
            }
            for (out, index) in indices.enumerated() {
                let frequency = grid[index]
                let acousticAbsolute = acousticPhase[index]
                    - 2 * .pi * frequency * acousticArrival
                let referenceAbsolute = referencePhase[index]
                    - 2 * .pi * frequency
                        * reference.directArrivalSeconds
                let corrected = acousticAbsolute - referenceAbsolute
                real[out] += cos(corrected) / Double(captures.count)
                imag[out] += sin(corrected) / Double(captures.count)
            }
        }
        return zip(real, imag).map { atan2($0.1, $0.0) }
    }

    private func rmsDeviationFromMean(
        _ rows: [[Double]]
    ) -> Double {
        guard let count = rows.first?.count,
              count > 0,
              rows.allSatisfy({ $0.count == count }) else {
            return .infinity
        }
        var squared = 0.0
        var samples = 0
        for index in 0..<count {
            let values = rows.map { $0[index] }
            let mean = values.reduce(0, +) / Double(values.count)
            for value in values {
                squared += pow(value - mean, 2)
                samples += 1
            }
        }
        return samples > 0 ? sqrt(squared / Double(samples)) : .infinity
    }

    private func circularConsistency(
        _ rows: [[Double]]
    ) -> Double {
        let values = rows.flatMap { $0 }
        guard !values.isEmpty, values.allSatisfy(\.isFinite) else {
            return 0
        }
        let real = values.map(cos).reduce(0, +) / Double(values.count)
        let imag = values.map(sin).reduce(0, +) / Double(values.count)
        return hypot(real, imag)
    }

    private func circularMean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return .nan }
        let real = values.map(cos).reduce(0, +) / Double(values.count)
        let imag = values.map(sin).reduce(0, +) / Double(values.count)
        return atan2(imag, real)
    }

    private func wrap(_ value: Double) -> Double {
        atan2(sin(value), cos(value))
    }
}


// MARK: - PR111 Slice 4: reference-aligned crossover-sum model

enum ProtectedDriverCrossoverSumHypothesis:
    String, Codable, Equatable, Sendable {
    case retainCurrent
    case addBoundedDelay
    case invertComparedDriver
    case addDelayAndInvertComparedDriver
}

/// Offline model of the two measured protected driver responses around one
/// crossover. This evaluates cancellation/coherence in the *captured* complex
/// responses. It is not a real combined-driver measurement and cannot verify
/// amplifier polarity, driver safety, radiation geometry or room response.
struct ProtectedDriverCrossoverSumModel: Equatable, Sendable {
    var sessionID: UUID
    var firstProtocolID: UUID
    var secondProtocolID: UUID
    var firstBus: SpeakerOutputBus
    var secondBus: SpeakerOutputBus
    var crossoverFrequencyHz: Double
    var frequencyPointCount: Int
    var currentMeanCoherenceDeficitDB: Double
    var candidateMeanCoherenceDeficitDB: Double
    var modeledDeficitReductionDB: Double
    var bestHypothesis: ProtectedDriverCrossoverSumHypothesis
    var modeledAdditionalDelayMilliseconds: Double?
    var modeledInvertsComparedDriver: Bool
    var evidenceConfidence: Double
    var warnings: [String]

    var measurementOnly: Bool { true }
    var modelOnly: Bool { true }
    var canDeploy: Bool { false }
    var combinedDriverCaptureVerified: Bool { false }
    var requiresPhysicalCombinedDriverCapture: Bool { true }
}

enum ProtectedDriverCrossoverSumModelError:
    Error, Equatable, LocalizedError {
    case timingEvidenceUnavailable
    case incompatibleComplexResponse
    case insufficientCrossoverEvidence

    var errorDescription: String? {
        switch self {
        case .timingEvidenceUnavailable:
            return "Reference-authenticated adjacent-driver timing evidence is required before modeling crossover summation."
        case .incompatibleComplexResponse:
            return "Both driver and electrical-reference sweeps need matching finite magnitude/phase grids."
        case .insufficientCrossoverEvidence:
            return "The protected pair lacks enough shared measured points around its crossover."
        }
    }
}

struct ProtectedDriverCrossoverSumModelAnalyzer: Sendable {
    static let minimumPointCount = 8
    static let minimumModeledImprovementDB = 0.25

    func analyze(
        session: SpeakerMeasurementLabSession,
        firstProtocolID: UUID,
        secondProtocolID: UUID
    ) throws -> ProtectedDriverCrossoverSumModel {
        let timing: ProtectedDriverTimingRecommendation
        do {
            timing = try ProtectedDriverTimingRecommendationAnalyzer()
                .recommend(
                    session: session,
                    firstProtocolID: firstProtocolID,
                    secondProtocolID: secondProtocolID
                )
        } catch {
            throw ProtectedDriverCrossoverSumModelError
                .timingEvidenceUnavailable
        }
        let first = session.captures.filter {
            $0.protocolID == firstProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        let second = session.captures.filter {
            $0.protocolID == secondProtocolID
        }.sorted { $0.repeatIndex < $1.repeatIndex }
        guard let grid = first.first?.transferFunction.frequenciesHz,
              !grid.isEmpty,
              (first + second).allSatisfy({
                  $0.transferFunction.frequenciesHz == grid
                    && $0.transferFunction.magnitudeDB.count == grid.count
                    && $0.transferFunction.phaseRadians?.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.frequenciesHz == grid
                    && $0.sharedClockReference?
                        .transferFunction.magnitudeDB.count == grid.count
                    && $0.sharedClockReference?
                        .transferFunction.phaseRadians?.count == grid.count
              }) else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        let lower = timing.crossoverFrequencyHz / 1.35
        let upper = timing.crossoverFrequencyHz * 1.35
        let indices = grid.indices.filter {
            grid[$0] >= lower && grid[$0] <= upper
        }
        guard indices.count >= Self.minimumPointCount else {
            throw ProtectedDriverCrossoverSumModelError
                .insufficientCrossoverEvidence
        }

        let firstMean = try referenceAlignedMean(
            first, indices: indices
        )
        let secondMean = try referenceAlignedMean(
            second, indices: indices
        )
        guard firstMean.count == secondMean.count,
              firstMean.count == indices.count else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }

        let current = meanCoherenceDeficit(
            firstMean, secondMean
        )
        var candidates: [(
            ProtectedDriverCrossoverSumHypothesis,
            Double,
            Double?,
            Bool
        )] = [
            (.retainCurrent, current, nil, false)
        ]

        if let delay = timing.additionalDelayMilliseconds,
           let delayBus = timing.delayBus {
            let delayed = modeledPair(
                firstMean,
                secondMean,
                indices: indices,
                grid: grid,
                delayMilliseconds: delay,
                delayBus: delayBus,
                firstBus: timing.firstBus,
                invertSecond: false
            )
            candidates.append((
                .addBoundedDelay,
                meanCoherenceDeficit(delayed.0, delayed.1),
                delay,
                false
            ))
        }

        if timing.polarityHypothesis == .invertComparedDriver {
            let inverted = modeledPair(
                firstMean,
                secondMean,
                indices: indices,
                grid: grid,
                delayMilliseconds: nil,
                delayBus: nil,
                firstBus: timing.firstBus,
                invertSecond: true
            )
            candidates.append((
                .invertComparedDriver,
                meanCoherenceDeficit(inverted.0, inverted.1),
                nil,
                true
            ))
            if let delay = timing.additionalDelayMilliseconds,
               let delayBus = timing.delayBus {
                let combined = modeledPair(
                    firstMean,
                    secondMean,
                    indices: indices,
                    grid: grid,
                    delayMilliseconds: delay,
                    delayBus: delayBus,
                    firstBus: timing.firstBus,
                    invertSecond: true
                )
                candidates.append((
                    .addDelayAndInvertComparedDriver,
                    meanCoherenceDeficit(combined.0, combined.1),
                    delay,
                    true
                ))
            }
        }

        let lowest = candidates.min {
            if abs($0.1 - $1.1) > 1.0e-9 {
                return $0.1 < $1.1
            }
            return $0.0.rawValue < $1.0.rawValue
        }!
        let improvement = current - lowest.1
        let selected = improvement >= Self.minimumModeledImprovementDB
            ? lowest
            : candidates[0]

        return ProtectedDriverCrossoverSumModel(
            sessionID: session.id,
            firstProtocolID: firstProtocolID,
            secondProtocolID: secondProtocolID,
            firstBus: timing.firstBus,
            secondBus: timing.secondBus,
            crossoverFrequencyHz: timing.crossoverFrequencyHz,
            frequencyPointCount: indices.count,
            currentMeanCoherenceDeficitDB: current,
            candidateMeanCoherenceDeficitDB: selected.1,
            modeledDeficitReductionDB: current - selected.1,
            bestHypothesis: selected.0,
            modeledAdditionalDelayMilliseconds: selected.2,
            modeledInvertsComparedDriver: selected.3,
            evidenceConfidence: timing.evidenceConfidence,
            warnings: [
                "MODEL ONLY: complex protected-driver measurements are summed mathematically; the two drivers were not measured playing together.",
                "A lower coherence-deficit value means less modeled cancellation relative to the sum of the two measured magnitudes. It is not a target-curve, SPL or sound-quality score.",
                "Any candidate must be verified by a new safe combined-driver crossover capture before delay, polarity, PEQ, crossover or limiter state can change.",
                "Mandatory crossover and limiter state from the protected captures remain authoritative; this model cannot weaken either."
            ]
        )
    }

    private struct ComplexSample: Equatable {
        var real: Double
        var imag: Double

        var magnitude: Double { hypot(real, imag) }
    }

    private func referenceAlignedMean(
        _ captures: [SpeakerMeasurementLabCapture],
        indices: [Int]
    ) throws -> [ComplexSample] {
        guard !captures.isEmpty else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        var real = Array(repeating: 0.0, count: indices.count)
        var imag = Array(repeating: 0.0, count: indices.count)
        for capture in captures {
            guard let phase = capture.transferFunction.phaseRadians,
                  let reference = capture.sharedClockReference,
                  let referencePhase =
                    reference.transferFunction.phaseRadians else {
                throw ProtectedDriverCrossoverSumModelError
                    .incompatibleComplexResponse
            }
            for (out, index) in indices.enumerated() {
                let relativeDB =
                    capture.transferFunction.magnitudeDB[index]
                    - reference.transferFunction.magnitudeDB[index]
                let magnitude = pow(10.0, relativeDB / 20.0)
                let relativePhase = atan2(
                    sin(phase[index] - referencePhase[index]),
                    cos(phase[index] - referencePhase[index])
                )
                real[out] += magnitude * cos(relativePhase)
                    / Double(captures.count)
                imag[out] += magnitude * sin(relativePhase)
                    / Double(captures.count)
            }
        }
        let result = zip(real, imag).map {
            ComplexSample(real: $0.0, imag: $0.1)
        }
        guard result.allSatisfy({
            $0.real.isFinite && $0.imag.isFinite
                && $0.magnitude.isFinite
        }) else {
            throw ProtectedDriverCrossoverSumModelError
                .incompatibleComplexResponse
        }
        return result
    }

    private func modeledPair(
        _ first: [ComplexSample],
        _ second: [ComplexSample],
        indices: [Int],
        grid: [Double],
        delayMilliseconds: Double?,
        delayBus: SpeakerOutputBus?,
        firstBus: SpeakerOutputBus,
        invertSecond: Bool
    ) -> ([ComplexSample], [ComplexSample]) {
        var lhs = first
        var rhs = second
        if let delayMilliseconds, let delayBus {
            let seconds = delayMilliseconds / 1_000
            for offset in lhs.indices {
                let frequency = grid[indices[offset]]
                let phase = 2 * Double.pi * frequency * seconds
                if delayBus == firstBus {
                    lhs[offset] = rotated(lhs[offset], phase)
                } else {
                    rhs[offset] = rotated(rhs[offset], phase)
                }
            }
        }
        if invertSecond {
            for offset in rhs.indices {
                rhs[offset].real *= -1
                rhs[offset].imag *= -1
            }
        }
        return (lhs, rhs)
    }

    private func rotated(
        _ sample: ComplexSample,
        _ radians: Double
    ) -> ComplexSample {
        ComplexSample(
            real: sample.real * cos(radians)
                - sample.imag * sin(radians),
            imag: sample.real * sin(radians)
                + sample.imag * cos(radians)
        )
    }

    private func meanCoherenceDeficit(
        _ first: [ComplexSample],
        _ second: [ComplexSample]
    ) -> Double {
        let values = zip(first, second).map { lhs, rhs -> Double in
            let ideal = max(lhs.magnitude + rhs.magnitude, 1.0e-12)
            let summed = max(
                hypot(lhs.real + rhs.real, lhs.imag + rhs.imag),
                1.0e-12
            )
            return max(0, 20 * log10(ideal / summed))
        }
        return values.reduce(0, +) / Double(values.count)
    }
}


// MARK: - PR111 Slice 5: hardware-blocked commissioning draft

struct ProtectedDriverCommissioningTimingReview:
    Codable, Equatable, Sendable {
    var firstBus: SpeakerOutputBus
    var secondBus: SpeakerOutputBus
    var crossoverFrequencyHz: Double
    var bestHypothesis: ProtectedDriverCrossoverSumHypothesis
    var modeledDeficitReductionDB: Double
    var modeledAdditionalDelayMilliseconds: Double?
    var modeledInvertsComparedDriver: Bool
    var combinedDriverCaptureVerified: Bool
}

struct ProtectedDriverCommissioningDraft:
    Identifiable, Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = currentSchemaVersion
    var id: UUID = UUID()
    var createdAt: Date = Date()
    var playbackSystemID: UUID
    var sessionID: UUID
    var routingSignature: String
    var sampleRate: Double
    var rollbackPlaybackSystemState: PlaybackSystemState
    var previewDriverProcessing: SpeakerDriverProcessingConfiguration
    var affectedBuses: [SpeakerOutputBus]
    var sourceProtocolIDs: [UUID]
    var sourceCaptureIDs: [UUID]
    var timingReviews: [ProtectedDriverCommissioningTimingReview]
    var evidenceSummary: String

    var approvalRequired: Bool { true }
    var physicalCombinedDriverVerificationComplete: Bool {
        !timingReviews.isEmpty
            && timingReviews.allSatisfy(\.combinedDriverCaptureVerified)
    }
    /// PR111 remote closeout intentionally has no Apply transaction. PR112
    /// must replace this hard false only after physical combined-driver
    /// verification and exposed-driver safety acceptance exist.
    var readyForApproval: Bool { false }
    var canApply: Bool { false }
    var canDeploy: Bool { false }
    var rollbackSnapshotAvailable: Bool { true }
    var stateDriftCheckRequired: Bool { true }
    var requiresPhysicalCombinedDriverCapture: Bool { true }
}

enum ProtectedDriverCommissioningError:
    Error, Equatable, LocalizedError {
    case invalidSession
    case playbackSystemMismatch
    case outputProfileRequired
    case protectedStateDrift
    case noQualifiedProtectedDriverEvidence
    case insufficientEQCapacity
    case invalidPreview
    case currentStateDrift
    case unsupportedSchema

    var errorDescription: String? {
        switch self {
        case .invalidSession:
            return "Per-driver commissioning requires a valid protected Measurement Lab session."
        case .playbackSystemMismatch:
            return "The Lab session does not belong to the selected Playback System."
        case .outputProfileRequired:
            return "An enabled Output Device Profile is required for per-driver commissioning review."
        case .protectedStateDrift:
            return "Routing, crossover, limiter, or per-driver processing changed after the protected measurements."
        case .noQualifiedProtectedDriverEvidence:
            return "No protected driver protocol produced repeat-qualified commissioning evidence."
        case .insufficientEQCapacity:
            return "The existing per-driver EQ has no safe free slots for the bounded review cuts."
        case .invalidPreview:
            return "The generated per-driver preview does not satisfy the existing realtime processing limits."
        case .currentStateDrift:
            return "The Playback System changed after commissioning review; regenerate the draft before any future Apply."
        case .unsupportedSchema:
            return "Saved per-driver commissioning draft uses an unsupported schema version."
        }
    }
}

/// Re-runs PR111 analysis from the persisted Lab session instead of trusting
/// caller-supplied cut/timing values. The output is a reviewable configuration
/// snapshot only. It has no reference to AudioIOEngine or ProductProfile
/// mutation APIs and cannot deploy anything.
struct ProtectedDriverCommissioningPlanner: Sendable {
    func draft(
        profile: PlaybackSystemProfile,
        session: SpeakerMeasurementLabSession,
        createdAt: Date = Date()
    ) throws -> ProtectedDriverCommissioningDraft {
        do { try session.validateStructure() }
        catch { throw ProtectedDriverCommissioningError.invalidSession }

        guard profile.id == session.playbackSystemID else {
            throw ProtectedDriverCommissioningError
                .playbackSystemMismatch
        }
        guard let output = profile.state.outputDeviceProfile,
              output.enabled,
              output.multichannelCalibrationRoutingSignature
                == session.routingSignature else {
            throw ProtectedDriverCommissioningError
                .outputProfileRequired
        }
        guard let baselineProcessing =
                profile.state.speakerDriverProcessing,
              profile.state.bassManagement.enabled,
              profile.state.outputRouting?.enabled == true else {
            throw ProtectedDriverCommissioningError
                .protectedStateDrift
        }

        let protectedProtocols = session.protocols.filter {
            $0.request.mode == .protectedDriverNearField
                && $0.protectedDriverBus != nil
        }
        guard !protectedProtocols.isEmpty else {
            throw ProtectedDriverCommissioningError
                .noQualifiedProtectedDriverEvidence
        }

        // Every measured protocol must still describe the exact current
        // route, bass-management/crossover and driver-processing snapshot.
        for labProtocol in protectedProtocols {
            let captures = session.captures.filter {
                $0.protocolID == labProtocol.id
            }
            guard !captures.isEmpty,
                  captures.allSatisfy({
                      guard let provenance =
                            $0.protectedDriverProvenance,
                            let currentRouting =
                            profile.state.outputRouting else {
                          return false
                      }
                      return sameRoutingTopology(
                          provenance.routingConfiguration,
                          currentRouting
                      )
                        && provenance.bassManagementConfiguration
                            == profile.state.bassManagement
                        && provenance.targetDriverConfiguration
                            == baselineProcessing.configuration(
                                for: labProtocol.protectedDriverBus!
                            )
                  }) else {
                throw ProtectedDriverCommissioningError
                    .protectedStateDrift
            }
        }

        var preview = baselineProcessing
        var affected = Set<SpeakerOutputBus>()
        var qualifiedProtocolIDs: [UUID] = []
        var qualifiedCaptureIDs: [UUID] = []

        for labProtocol in protectedProtocols {
            guard let bus = labProtocol.protectedDriverBus else { continue }
            let recommendation: ProtectedDriverPEQRecommendation
            do {
                recommendation =
                    try ProtectedDriverPEQRecommendationAnalyzer()
                        .recommend(
                            session: session,
                            protocolID: labProtocol.id
                        )
            } catch {
                continue
            }
            qualifiedProtocolIDs.append(labProtocol.id)
            qualifiedCaptureIDs.append(
                contentsOf: recommendation.repeatedCaptureIDs
            )
            guard !recommendation.cuts.isEmpty else { continue }

            var busConfiguration = preview.configuration(for: bus)
            guard busConfiguration.limiterEnabled,
                  busConfiguration.eqBands.count
                    + recommendation.cuts.count
                    <= SpeakerDriverBusProcessingConfiguration
                        .maximumEQBandCount else {
                throw ProtectedDriverCommissioningError
                    .insufficientEQCapacity
            }
            for cut in recommendation.cuts {
                busConfiguration.eqBands.append(
                    EQBand(
                        enabled: true,
                        type: .peaking,
                        frequencyHz: cut.frequencyHz,
                        gainDB: cut.gainDB,
                        q: cut.q,
                        slope: .db12
                    )
                )
            }
            // Never modify these protection/alignment fields in remote draft.
            guard busConfiguration.trimDB
                    == recommendation.protectedConfiguration.trimDB,
                  busConfiguration.polarityInverted
                    == recommendation.protectedConfiguration
                        .polarityInverted,
                  busConfiguration.delayMilliseconds
                    == recommendation.protectedConfiguration
                        .delayMilliseconds,
                  busConfiguration.limiterEnabled
                    == recommendation.protectedConfiguration
                        .limiterEnabled,
                  busConfiguration.limiterThresholdDBFS
                    == recommendation.protectedConfiguration
                        .limiterThresholdDBFS else {
                throw ProtectedDriverCommissioningError
                    .invalidPreview
            }
            preview.replace(busConfiguration)
            affected.insert(bus)
        }
        guard !qualifiedProtocolIDs.isEmpty else {
            throw ProtectedDriverCommissioningError
                .noQualifiedProtectedDriverEvidence
        }
        do { try preview.validateStructure() }
        catch { throw ProtectedDriverCommissioningError.invalidPreview }

        let timingReviews = makeTimingReviews(
            session: session,
            protectedProtocols: protectedProtocols
        )

        return ProtectedDriverCommissioningDraft(
            createdAt: createdAt,
            playbackSystemID: profile.id,
            sessionID: session.id,
            routingSignature: session.routingSignature,
            sampleRate: session.sampleRate,
            rollbackPlaybackSystemState: profile.state,
            previewDriverProcessing: preview,
            affectedBuses: affected.sorted {
                $0.rawValue < $1.rawValue
            },
            sourceProtocolIDs: qualifiedProtocolIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            sourceCaptureIDs: qualifiedCaptureIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            timingReviews: timingReviews,
            evidenceSummary:
                "Remote commissioning draft only: cut-only PEQ preview plus model-only adjacent-driver timing reviews. " +
                "Exact Playback System rollback snapshot retained. No Apply until fresh physical combined-driver verification and PR112 hardware acceptance."
        )
    }

    func validateCurrentState(
        _ profile: PlaybackSystemProfile,
        against draft: ProtectedDriverCommissioningDraft
    ) throws {
        guard draft.schemaVersion
                == ProtectedDriverCommissioningDraft
                    .currentSchemaVersion else {
            throw ProtectedDriverCommissioningError
                .unsupportedSchema
        }
        guard profile.id == draft.playbackSystemID else {
            throw ProtectedDriverCommissioningError
                .playbackSystemMismatch
        }
        guard profile.state
                == draft.rollbackPlaybackSystemState else {
            throw ProtectedDriverCommissioningError.currentStateDrift
        }
    }

    private func sameRoutingTopology(
        _ lhs: MultiOutputRoutingConfiguration,
        _ rhs: MultiOutputRoutingConfiguration
    ) -> Bool {
        guard lhs.enabled == rhs.enabled,
              lhs.synchronizationMode == rhs.synchronizationMode,
              lhs.resolvedReferenceDeviceUID
                == rhs.resolvedReferenceDeviceUID else {
            return false
        }
        let left = lhs.enabledRoutes.map {
            ($0.bus.rawValue, $0.destination.deviceUID,
             $0.destination.channelIndex)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        let right = rhs.enabledRoutes.map {
            ($0.bus.rawValue, $0.destination.deviceUID,
             $0.destination.channelIndex)
        }.sorted {
            if $0.0 != $1.0 { return $0.0 < $1.0 }
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.2 < $1.2
        }
        return left.elementsEqual(right) {
            $0.0 == $1.0 && $0.1 == $1.1 && $0.2 == $1.2
        }
    }

    private func makeTimingReviews(
        session: SpeakerMeasurementLabSession,
        protectedProtocols: [SpeakerMeasurementLabProtocol]
    ) -> [ProtectedDriverCommissioningTimingReview] {
        var reviews: [ProtectedDriverCommissioningTimingReview] = []
        let buses = Dictionary(
            uniqueKeysWithValues: protectedProtocols.compactMap {
                protocolItem in
                protocolItem.protectedDriverBus.map {
                    ($0, protocolItem)
                }
            }
        )
        let pairs: [(SpeakerOutputBus, SpeakerOutputBus)] = [
            (.leftLow, .leftMid),
            (.leftMid, .leftHigh),
            (.leftLow, .leftHigh),
            (.rightLow, .rightMid),
            (.rightMid, .rightHigh),
            (.rightLow, .rightHigh),
        ]
        for pair in pairs {
            guard let first = buses[pair.0],
                  let second = buses[pair.1],
                  let model = try? ProtectedDriverCrossoverSumModelAnalyzer()
                    .analyze(
                        session: session,
                        firstProtocolID: first.id,
                        secondProtocolID: second.id
                    ) else {
                continue
            }
            reviews.append(
                ProtectedDriverCommissioningTimingReview(
                    firstBus: model.firstBus,
                    secondBus: model.secondBus,
                    crossoverFrequencyHz:
                        model.crossoverFrequencyHz,
                    bestHypothesis: model.bestHypothesis,
                    modeledDeficitReductionDB:
                        model.modeledDeficitReductionDB,
                    modeledAdditionalDelayMilliseconds:
                        model.modeledAdditionalDelayMilliseconds,
                    modeledInvertsComparedDriver:
                        model.modeledInvertsComparedDriver,
                    combinedDriverCaptureVerified:
                        model.combinedDriverCaptureVerified
                )
            )
        }
        return reviews.sorted {
            if $0.firstBus.rawValue != $1.firstBus.rawValue {
                return $0.firstBus.rawValue < $1.firstBus.rawValue
            }
            return $0.secondBus.rawValue < $1.secondBus.rawValue
        }
    }
}

struct ProtectedDriverCommissioningDraftStore: Sendable {
    let rootDirectory: URL

    init(rootDirectory: URL? = nil) {
        self.rootDirectory = rootDirectory
            ?? SpeakerMeasurementLabSessionStore()
                .rootDirectory
                .appendingPathComponent(
                    "PR111 Commissioning Drafts",
                    isDirectory: true
                )
    }

    func url(for sessionID: UUID) -> URL {
        rootDirectory.appendingPathComponent(
            "\(sessionID.uuidString.lowercased()).json",
            isDirectory: false
        )
    }

    func save(_ draft: ProtectedDriverCommissioningDraft) throws {
        guard draft.schemaVersion
                == ProtectedDriverCommissioningDraft
                    .currentSchemaVersion,
              !draft.canApply,
              !draft.canDeploy,
              draft.requiresPhysicalCombinedDriverCapture,
              draft.rollbackSnapshotAvailable else {
            throw ProtectedDriverCommissioningError.invalidPreview
        }
        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(draft).write(
            to: url(for: draft.sessionID),
            options: .atomic
        )
    }

    func load(_ sessionID: UUID)
        throws -> ProtectedDriverCommissioningDraft? {
        let path = url(for: sessionID)
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let draft = try decoder.decode(
            ProtectedDriverCommissioningDraft.self,
            from: Data(contentsOf: path)
        )
        guard draft.sessionID == sessionID,
              draft.schemaVersion
                == ProtectedDriverCommissioningDraft
                    .currentSchemaVersion,
              !draft.canApply,
              !draft.canDeploy,
              draft.requiresPhysicalCombinedDriverCapture else {
            throw ProtectedDriverCommissioningError
                .unsupportedSchema
        }
        return draft
    }
}
