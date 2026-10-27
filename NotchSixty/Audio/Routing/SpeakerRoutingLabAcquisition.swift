import Foundation

// E8 A2b: live protected capture on one routed way. Control plane only; nothing here runs in an audio callback.
//
// The excitation is the S5 offline render of one way (ROUTE, XOVER, DELAY, PROTECTION), band-limited by a sweep that
// starts above the way's high-pass guard and ends below its low-pass guard, then played through the existing protected
// transport on the way's physical channel. This file binds the way's endpoint to that channel (one device or an
// aggregate), builds the capture provenance, and checks that the way did not change between compile and start.

/// Why a routed way cannot be excited right now.
enum SpeakerMeasurementLabRoutedWayError: Error, Equatable, LocalizedError {
    case routingRequired
    case wayNotFound
    case wayNotProtected
    case noProtectedPassband
    case endpointUnresolvable(String)
    case insufficientCarrierRoutes
    case levelOutOfRange(Double)
    case sweepOutsidePassband
    case wayChanged

    var errorDescription: String? {
        switch self {
        case .routingRequired:
            return "Per-driver measurement needs the routing matrix switched on."
        case .wayNotFound:
            return "The driver is not in the routing matrix."
        case .wayNotProtected:
            return "The driver needs a high-pass or low-pass filter and its limiter on before the lab may sweep it."
        case .noProtectedPassband:
            return "The driver's passband is too narrow at this sample rate for a protected sweep (it needs at least 1.7:1 between its guard corners)."
        case .endpointUnresolvable(let reason):
            return "The driver's output cannot be resolved: \(reason)"
        case .insufficientCarrierRoutes:
            return "Protected measurement needs at least two routed physical channels to build the measurement carrier."
        case .levelOutOfRange(let level):
            return "Per-driver sweeps run between -48 and -24 dBFS; \(level) dBFS is outside that range."
        case .sweepOutsidePassband:
            return "The sweep range does not overlap the driver's protected passband."
        case .wayChanged:
            return "The driver, its filters or its output changed after the sweep was prepared; nothing was played."
        }
    }
}

/// The output devices the lab sees, needed to resolve a way's endpoint to a physical channel.
struct SpeakerMeasurementLabRoutedWayEnvironment: Equatable, Sendable {
    var availableOutputs: [AudioOutputDevice]
    var sampleRate: Double
    var selectedOutputUID: String
}

/// A way bound to its physical channel, and the exact state it was bound against.
struct SpeakerMeasurementLabRoutedWayBinding: Equatable, Sendable {
    var wayID: UUID
    /// The way as stored in the routing (real endpoint).
    var way: RoutedWay
    var physicalDestination: PhysicalOutputEndpoint
    var physicalOutputChannelIndex: UInt32
    /// Lets the existing targeted transport recreate the device or aggregate topology. It does not filter anything;
    /// the pre-rendered protected waveform does.
    var carrierRoutePlan: LiveNChannelOutputRoutePlan
    var outputEndpoints: [PhysicalOutputEndpoint]
    var passband: ClosedRange<Double>
    /// The speaker that owns the way, so analysers can pair neighbouring ways of one speaker.
    var speakerID: UUID? = nil

    /// True only when the routing still holds this exact way, with the same set of outputs.
    func matchesCurrentState(routing: SpeakerRoutingConfiguration?) -> Bool {
        guard let routing, routing.enabled,
              let current = routing.speakers.flatMap(\.ways).first(where: { $0.id == wayID }) else { return false }
        return current == way && routing.outputEndpoints == outputEndpoints
    }
}

struct SpeakerMeasurementLabRoutedWayRoutePlanner: Sendable {
    func plan(
        wayID: UUID,
        routing: SpeakerRoutingConfiguration?,
        environment: SpeakerMeasurementLabRoutedWayEnvironment
    ) throws -> SpeakerMeasurementLabRoutedWayBinding {
        guard let routing, routing.enabled else { throw SpeakerMeasurementLabRoutedWayError.routingRequired }
        guard let owner = routing.speakers.first(where: { $0.ways.contains { $0.id == wayID } }),
              let way = owner.ways.first(where: { $0.id == wayID }) else {
            throw SpeakerMeasurementLabRoutedWayError.wayNotFound
        }
        guard way.isProtectedMeasurementCandidate else { throw SpeakerMeasurementLabRoutedWayError.wayNotProtected }
        guard let passband = way.protectedPassband(sampleRate: environment.sampleRate) else {
            throw SpeakerMeasurementLabRoutedWayError.noProtectedPassband
        }
        let endpoints = routing.outputEndpoints
        guard let index = endpoints.firstIndex(of: way.endpoint) else {
            throw SpeakerMeasurementLabRoutedWayError.endpointUnresolvable("it is not one of the routing's outputs.")
        }
        let live: LiveNChannelOutputRoutePlan
        do {
            live = try routing.makeLivePlan(
                programLayout: .stereo,
                availableDevices: environment.availableOutputs,
                sampleRate: environment.sampleRate,
                selectedOutputUID: environment.selectedOutputUID,
                bassManagementEnabled: routing.subwooferSourceCount > 0)
        } catch {
            throw SpeakerMeasurementLabRoutedWayError.endpointUnresolvable(
                (error as? LocalizedError)?.errorDescription ?? "\(error)")
        }
        let channels = live.routedOutputPhysicalChannels
        guard channels.count == endpoints.count, index < channels.count else {
            throw SpeakerMeasurementLabRoutedWayError.endpointUnresolvable("the output plan does not match the routing.")
        }
        let target = channels[index]
        guard target < live.physicalChannelCount else {
            throw SpeakerMeasurementLabRoutedWayError.endpointUnresolvable("its channel is beyond the device.")
        }
        var unique: [UInt32] = []
        for channel in channels where !unique.contains(channel) { unique.append(channel) }
        guard unique.count >= 2 else { throw SpeakerMeasurementLabRoutedWayError.insufficientCarrierRoutes }
        let carrier = LiveNChannelOutputRoutePlan(
            programLayout: .stereo,
            orderedDeviceUIDs: live.orderedDeviceUIDs,
            referenceDeviceUID: live.referenceDeviceUID,
            physicalChannelCount: live.physicalChannelCount,
            programPhysicalChannels: Array(unique.prefix(2)),
            subwooferPhysicalChannels: [],
            subwooferCount: 0,
            bassManagementEnabled: false,
            speakerCalibrations: [:],
            subwooferCalibrations: [],
            speakerOptimizerPEQ: [:])
        do { _ = try carrier.makeRealtimeOutputMap() } catch {
            throw SpeakerMeasurementLabRoutedWayError.endpointUnresolvable("the measurement carrier cannot be built.")
        }
        return SpeakerMeasurementLabRoutedWayBinding(
            wayID: wayID, way: way, physicalDestination: way.endpoint, physicalOutputChannelIndex: target,
            carrierRoutePlan: carrier, outputEndpoints: endpoints, passband: passband, speakerID: owner.id)
    }
}

/// Receipt stored with every capture of a routed way: the way as rendered, where it played and how hot it was.
struct SpeakerMeasurementLabRoutedWayCaptureProvenance: Codable, Equatable, Sendable {
    /// The way as rendered (its endpoint is the offline render's stand-in, see `physicalDestination`).
    var way: RoutedWay
    /// The owning speaker. Absent in sessions recorded before A2c; those cannot be paired.
    var speakerID: UUID? = nil
    var physicalDestination: PhysicalOutputEndpoint
    var passbandLowHz: Double
    var passbandHighHz: Double
    var inputPeakDBFS: Double
    var renderedPeakDBFS: Double
    var sourceFrameCount: Int
    var renderedFrameCount: Int

    var limiterPreserved: Bool { way.limiter != nil }

    func validates(wayID: UUID) -> Bool {
        way.id == wayID
            && way.isProtectedMeasurementCandidate
            && passbandLowHz.isFinite && passbandHighHz.isFinite
            && passbandLowHz > 0 && passbandHighHz > passbandLowHz
            && inputPeakDBFS.isFinite && inputPeakDBFS <= -24.0 + 1.0e-6
            && renderedPeakDBFS.isFinite && renderedPeakDBFS <= 0
            && sourceFrameCount > 0 && renderedFrameCount >= sourceFrameCount
    }
}

extension SpeakerRoutingProtectedExcitation {
    func makeCaptureProvenance(
        binding: SpeakerMeasurementLabRoutedWayBinding
    ) throws -> SpeakerMeasurementLabRoutedWayCaptureProvenance {
        guard binding.wayID == wayID, let passband else { throw SpeakerMeasurementLabRoutedWayError.wayChanged }
        return SpeakerMeasurementLabRoutedWayCaptureProvenance(
            way: way, speakerID: binding.speakerID, physicalDestination: binding.physicalDestination,
            passbandLowHz: passband.lowerBound, passbandHighHz: passband.upperBound,
            inputPeakDBFS: inputPeakDBFS, renderedPeakDBFS: renderedPeakDBFS,
            sourceFrameCount: sourceFrameCount, renderedFrameCount: renderedSamples.count)
    }

    /// The original sweep stays the deconvolution reference; its capture tail grows by the render's flush frames, so the
    /// measured response includes the way's crossover, EQ, delay and limiter.
    func makeAnalysisProgram(from source: RoomCorrectionSweepProgram) throws -> RoomCorrectionSweepProgram {
        guard source.sweepSamples.count == sourceFrameCount, abs(source.sampleRate - sampleRate) < 0.5,
              renderedSamples.count >= sourceFrameCount else {
            throw SpeakerRoutingProtectedExcitationError.invalidExcitation
        }
        let extra = renderedSamples.count - sourceFrameCount
        guard source.tailFrames <= Int.max - extra else { throw RoomCorrectionSweepGenerationError.frameCountOverflow }
        var result = source
        result.tailFrames += extra
        return result
    }
}

/// Everything a live capture of one way needs, prepared before any hardware starts.
struct SpeakerMeasurementLabRoutedWayAcquisition: Equatable, Sendable {
    var binding: SpeakerMeasurementLabRoutedWayBinding
    var excitation: SpeakerRoutingProtectedExcitation
    var provenance: SpeakerMeasurementLabRoutedWayCaptureProvenance
    /// The sweep as generated, limited to the way's passband.
    var sweepProgram: RoomCorrectionSweepProgram
    /// The sweep with its tail extended for the render's flush.
    var analysisProgram: RoomCorrectionSweepProgram
}

struct SpeakerMeasurementLabRoutedWayAcquisitionPlanner: Sendable {
    static let levelRange: ClosedRange<Double> = -48.0 ... -24.0

    func prepare(
        wayID: UUID,
        routing: SpeakerRoutingConfiguration?,
        environment: SpeakerMeasurementLabRoutedWayEnvironment,
        sweep: RoomCorrectionSweepSettings
    ) throws -> SpeakerMeasurementLabRoutedWayAcquisition {
        guard Self.levelRange.contains(sweep.levelDBFS) else {
            throw SpeakerMeasurementLabRoutedWayError.levelOutOfRange(sweep.levelDBFS)
        }
        let binding = try SpeakerMeasurementLabRoutedWayRoutePlanner().plan(
            wayID: wayID, routing: routing, environment: environment)
        var limited = sweep
        limited.sampleRate = environment.sampleRate
        limited.startFrequencyHz = max(sweep.startFrequencyHz, binding.passband.lowerBound)
        limited.endFrequencyHz = min(sweep.endFrequencyHz, binding.passband.upperBound)
        guard limited.endFrequencyHz > limited.startFrequencyHz * 1.2 else {
            throw SpeakerMeasurementLabRoutedWayError.sweepOutsidePassband
        }
        let program = try RoomCorrectionSweepGenerator().makeProgram(settings: limited)
        guard let routing else { throw SpeakerMeasurementLabRoutedWayError.routingRequired }
        let excitation = try SpeakerRoutingProtectedExcitationCompiler().compile(
            monoSamples: program.sweepSamples, sampleRate: program.sampleRate, routing: routing, wayID: wayID)
        return SpeakerMeasurementLabRoutedWayAcquisition(
            binding: binding, excitation: excitation,
            provenance: try excitation.makeCaptureProvenance(binding: binding),
            sweepProgram: program, analysisProgram: try excitation.makeAnalysisProgram(from: program))
    }
}
