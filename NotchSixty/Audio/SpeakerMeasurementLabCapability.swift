import Foundation

enum SpeakerMeasurementLabMode: String, CaseIterable, Codable, Sendable {
    case wholeSpeakerOnAxis
    case wholeSpeakerOffAxis
    case subwooferNearField
    case protectedDriverNearField
    /// E8 B2: full-band near-field capture of one routed way (a driver of the routing matrix).
    case driverNearField
    case coherentMainsSubTiming
}

struct SpeakerMeasurementLabGeometry: Codable, Equatable, Sendable {
    var distanceMeters: Double
    var horizontalAngleDegrees: Double
    var verticalAngleDegrees: Double
    var speakerRemainedInstalled: Bool

    init(
        distanceMeters: Double,
        horizontalAngleDegrees: Double = 0,
        verticalAngleDegrees: Double = 0,
        speakerRemainedInstalled: Bool = true
    ) {
        self.distanceMeters = distanceMeters
        self.horizontalAngleDegrees = horizontalAngleDegrees
        self.verticalAngleDegrees = verticalAngleDegrees
        self.speakerRemainedInstalled = speakerRemainedInstalled
    }

    func isValid(for mode: SpeakerMeasurementLabMode) -> Bool {
        guard distanceMeters.isFinite,
              horizontalAngleDegrees.isFinite,
              verticalAngleDegrees.isFinite,
              speakerRemainedInstalled else {
            return false
        }

        let horizontal = abs(horizontalAngleDegrees)
        let vertical = abs(verticalAngleDegrees)
        guard horizontal <= 180, vertical <= 90 else { return false }

        switch mode {
        case .wholeSpeakerOnAxis:
            return (0.5...5.0).contains(distanceMeters)
                && horizontal <= 10
                && vertical <= 10
        case .wholeSpeakerOffAxis:
            return (0.5...5.0).contains(distanceMeters)
                && max(horizontal, vertical) >= 10
                && max(horizontal, vertical) <= 90
        case .subwooferNearField:
            return (0.01...0.50).contains(distanceMeters)
        case .protectedDriverNearField, .driverNearField:
            return (0.01...0.50).contains(distanceMeters)
        case .coherentMainsSubTiming:
            return (0.5...10.0).contains(distanceMeters)
        }
    }
}

enum SpeakerMeasurementLabTarget: Codable, Equatable, Sendable {
    case acousticSource(MultichannelCalibrationSource)
    case protectedDriverBus(SpeakerOutputBus)
    /// E8 B2: one `RoutedWay` of the speaker routing matrix, by its id.
    case routedWay(UUID)
    case sourcePair(
        main: MultichannelCalibrationSource,
        subwoofer: MultichannelCalibrationSource
    )
}

enum SpeakerMeasurementLabAnalysisProduct:
    String, CaseIterable, Codable, Equatable, Sendable {
    case magnitudeResponse
    case phaseResponse
    case directArrival
    case earlyWindowMagnitude
    case directivityComparison
    case lowFrequencyNearFieldMagnitude
    case fullBandNearFieldMagnitude
    case relativeArrival
    case relativePhase
}

struct SpeakerMeasurementLabRequest: Codable, Equatable, Sendable {
    static let minimumRepeatCount =
        SpeakerOptimizerMeasurementEvidenceEvaluator.minimumRepeatCount

    var mode: SpeakerMeasurementLabMode
    var target: SpeakerMeasurementLabTarget
    var geometry: SpeakerMeasurementLabGeometry
    var repeatCount: Int = minimumRepeatCount

    func validate() throws {
        guard (Self.minimumRepeatCount...10).contains(repeatCount) else {
            throw SpeakerMeasurementLabError.invalidRepeatCount(repeatCount)
        }
        guard geometry.isValid(for: mode) else {
            throw SpeakerMeasurementLabError.invalidGeometry
        }

        switch (mode, target) {
        case (.wholeSpeakerOnAxis, .acousticSource(.speaker(let role))),
             (.wholeSpeakerOffAxis, .acousticSource(.speaker(let role))):
            guard role != .lowFrequencyEffects else {
                throw SpeakerMeasurementLabError.invalidTarget
            }
        case (.subwooferNearField, .acousticSource(.subwoofer)):
            break
        case (
            .protectedDriverNearField,
            .protectedDriverBus(let bus)
        ):
            guard SpeakerMeasurementLabProtectedDriverRoutePlanner
                    .isProtectedSplitBus(bus) else {
                throw SpeakerMeasurementLabError.invalidTarget
            }
        case (.driverNearField, .routedWay):
            break
        case (
            .coherentMainsSubTiming,
            .sourcePair(
                main: .speaker(let mainRole),
                subwoofer: .subwoofer
            )
        ):
            guard mainRole != .lowFrequencyEffects else {
                throw SpeakerMeasurementLabError.invalidTarget
            }
        default:
            throw SpeakerMeasurementLabError.invalidTarget
        }
    }
}

enum SpeakerMeasurementLabBlockReason: Equatable, Sendable {
    case transport(SpeakerOptimizerMeasurementTransportBlockReason)
    case protectedDriverTransportRequired(SpeakerOutputBus)
    case authenticatedSharedClockRequired
    /// The routed way is not in the routing matrix, or its live acquisition path is not available yet.
    case routedWayAcquisitionUnavailable(UUID)

    var message: String {
        switch self {
        case .transport(let reason):
            return reason.message
        case .protectedDriverTransportRequired(let bus):
            return "\(bus.displayName) requires a crossover-preserving protected excitation path before the lab may sweep that driver."
        case .authenticatedSharedClockRequired:
            return "Coherent mains/sub timing requires authenticated shared playback/capture clock provenance; independent source sweeps are not sufficient."
        case .routedWayAcquisitionUnavailable:
            return "Live per-driver acquisition needs a band-limited, limiter-protected sweep to a single routed way; that path is not available yet, so the lab only analyses captures already in a session."
        }
    }
}

enum SpeakerMeasurementLabError: Error, Equatable, LocalizedError {
    case invalidRepeatCount(Int)
    case invalidGeometry
    case invalidTarget

    var errorDescription: String? {
        switch self {
        case .invalidRepeatCount(let count):
            return "Advanced Speaker Measurement Lab requires at least \(SpeakerMeasurementLabRequest.minimumRepeatCount) repeats and at most 10; requested \(count)."
        case .invalidGeometry:
            return "Measurement geometry is invalid for the selected lab mode."
        case .invalidTarget:
            return "Measurement target is incompatible with the selected lab mode."
        }
    }
}

struct SpeakerMeasurementLabPlan: Equatable, Sendable {
    var request: SpeakerMeasurementLabRequest
    var delegatedTransportPlans: [SpeakerOptimizerMeasurementTransportPlan]
    var analysisProducts: [SpeakerMeasurementLabAnalysisProduct]
    var blockReasons: [SpeakerMeasurementLabBlockReason]
    var warnings: [String]
    var phaseReferenceAuthenticated: Bool
    /// Non-nil only for PR106's dedicated crossover/limiter-preserving path.
    /// It never falls through to the legacy raw physical-lane planner.
    var protectedDriverBus: SpeakerOutputBus? = nil

    var canStartMeasurement: Bool {
        guard blockReasons.isEmpty else { return false }
        if protectedDriverBus != nil {
            return delegatedTransportPlans.isEmpty
        }
        return delegatedTransportPlans.count == 1
            && delegatedTransportPlans.allSatisfy(\.canStartMeasurement)
    }

    var measurementOnly: Bool { true }
    var canDeploy: Bool { false }
    var canMutateDSP: Bool { false }
}

struct SpeakerMeasurementLabCapabilityPlanner: Sendable {
    private let transportPlanner =
        SpeakerOptimizerMeasurementTransportPlanner()

    func plan(
        _ request: SpeakerMeasurementLabRequest,
        routePlan: LiveNChannelOutputRoutePlan,
        multiOutputRouting: MultiOutputRoutingConfiguration?,
        speakerDriverProcessing: SpeakerDriverProcessingConfiguration?,
        bassManagementConfiguration: BassManagementConfiguration? = nil,
        speakerRouting: SpeakerRoutingConfiguration? = nil,
        coherentLeg: SpeakerMeasurementLabCoherentLeg? = nil,
        sharedClockReferenceAvailable: Bool = false
    ) throws -> SpeakerMeasurementLabPlan {
        try request.validate()

        switch (request.mode, request.target) {
        case (
            .wholeSpeakerOnAxis,
            .acousticSource(let source)
        ):
            return acousticPlan(
                request: request,
                source: source,
                products: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                    .earlyWindowMagnitude,
                ],
                warnings: [
                    "On-axis installed-room measurement is not an anechoic or free-field loudspeaker specification."
                ],
                routePlan: routePlan,
                multiOutputRouting: multiOutputRouting,
                speakerDriverProcessing: speakerDriverProcessing
            )
        case (
            .wholeSpeakerOffAxis,
            .acousticSource(let source)
        ):
            return acousticPlan(
                request: request,
                source: source,
                products: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                    .earlyWindowMagnitude,
                    .directivityComparison,
                ],
                warnings: [
                    "Off-axis angle is user-entered geometry and must be physically positioned or verified; software does not infer the microphone angle."
                ],
                routePlan: routePlan,
                multiOutputRouting: multiOutputRouting,
                speakerDriverProcessing: speakerDriverProcessing
            )
        case (
            .subwooferNearField,
            .acousticSource(let source)
        ):
            return acousticPlan(
                request: request,
                source: source,
                products: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                    .lowFrequencyNearFieldMagnitude,
                ],
                warnings: [
                    "Near-field subwoofer response is a diagnostic of the local radiator or port field and does not replace listening-position room-integration measurement."
                ],
                routePlan: routePlan,
                multiOutputRouting: multiOutputRouting,
                speakerDriverProcessing: speakerDriverProcessing
            )
        case (
            .protectedDriverNearField,
            .protectedDriverBus(let bus)
        ):
            let routeReady =
                multiOutputRouting?.enabled == true
                && multiOutputRouting?.enabledRoutes.filter {
                    $0.bus == bus
                }.count == 1
            let crossoverReady: Bool
            if let bass = bassManagementConfiguration,
               bass.enabled,
               let mode = bass.physicalOutputMode,
               (mode == .biAmp || mode == .triAmp) {
                crossoverReady = mode.supports(bus: bus)
            } else {
                crossoverReady = false
            }
            let protectionReady: Bool
            if let speakerDriverProcessing {
                let target = speakerDriverProcessing.configuration(
                    for: bus
                )
                protectionReady =
                    target.enabled && target.limiterEnabled
            } else {
                protectionReady = false
            }
            let blockers: [SpeakerMeasurementLabBlockReason] =
                routeReady && crossoverReady && protectionReady
                ? []
                : [.protectedDriverTransportRequired(bus)]
            return SpeakerMeasurementLabPlan(
                request: request,
                delegatedTransportPlans: [],
                analysisProducts: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                ],
                blockReasons: blockers,
                warnings: [
                    "Protected-driver response includes the active production crossover plus configured driver EQ/trim/polarity/delay/limiter path; it is not a bare-driver specification.",
                    "Live acquisition still revalidates the exact physical route, crossover and target limiter immediately before playback."
                ],
                phaseReferenceAuthenticated: false,
                protectedDriverBus: blockers.isEmpty ? bus : nil
            )
        case (
            .driverNearField,
            .routedWay(let wayID)
        ):
            // Never sweeps a driver here: an unknown way and the unwired live path both block, so no
            // full-band excitation can reach a tweeter or midrange through this plan.
            _ = speakerRouting
            return SpeakerMeasurementLabPlan(
                request: request,
                delegatedTransportPlans: [],
                analysisProducts: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                    .fullBandNearFieldMagnitude,
                ],
                blockReasons: [.routedWayAcquisitionUnavailable(wayID)],
                warnings: [
                    "Near-field driver response is the driver at the microphone, close to the cone; it is not a listening-position response.",
                    "Each driver is captured alone, with the sweep limited to its passband and the way's limiter active; this protocol analyses stored captures and never mutates routing."
                ],
                phaseReferenceAuthenticated: false
            )
        case (
            .coherentMainsSubTiming,
            .sourcePair(let main, let subwoofer)
        ):
            guard sharedClockReferenceAvailable,
                  let coherentLeg else {
                return SpeakerMeasurementLabPlan(
                    request: request,
                    delegatedTransportPlans: [],
                    analysisProducts: [.relativeArrival, .relativePhase],
                    blockReasons: [.authenticatedSharedClockRequired],
                    warnings: [
                        "A linked Main/Sub Lab pair must capture a simultaneous electrical reference on every sweep before coherent diagnostics can run."
                    ],
                    phaseReferenceAuthenticated: false
                )
            }
            let source = coherentLeg == .main ? main : subwoofer
            return acousticPlan(
                request: request,
                source: source,
                products: [
                    .magnitudeResponse,
                    .phaseResponse,
                    .directArrival,
                    .relativeArrival,
                    .relativePhase,
                ],
                warnings: [
                    "Live acquisition is only one leg of a linked coherent pair. Cross-source clock provenance is authenticated later from BOTH qualified reference-captured groups.",
                    "No delay, polarity or crossover state is mutated by the Lab."
                ],
                routePlan: routePlan,
                multiOutputRouting: multiOutputRouting,
                speakerDriverProcessing: speakerDriverProcessing
            )
        default:
            throw SpeakerMeasurementLabError.invalidTarget
        }
    }

    private func acousticPlan(
        request: SpeakerMeasurementLabRequest,
        source: MultichannelCalibrationSource,
        products: [SpeakerMeasurementLabAnalysisProduct],
        warnings: [String],
        routePlan: LiveNChannelOutputRoutePlan,
        multiOutputRouting: MultiOutputRoutingConfiguration?,
        speakerDriverProcessing: SpeakerDriverProcessingConfiguration?
    ) -> SpeakerMeasurementLabPlan {
        let delegated = transportPlanner.plan(
            target: .acousticSource(source),
            routePlan: routePlan,
            multiOutputRouting: multiOutputRouting,
            speakerDriverProcessing: speakerDriverProcessing
        )
        let blockers: [SpeakerMeasurementLabBlockReason] =
            delegated.blockReason.map { [.transport($0)] } ?? []

        return SpeakerMeasurementLabPlan(
            request: request,
            delegatedTransportPlans: [delegated],
            analysisProducts: products,
            blockReasons: blockers,
            warnings: warnings,
            phaseReferenceAuthenticated: false
        )
    }
}
