import Foundation

struct SpeakerMeasurementLabProtocolDraft: Equatable, Sendable {
    var name: String = "On-Axis"
    var mode: SpeakerMeasurementLabMode = .wholeSpeakerOnAxis
    var speakerRole: OutputProgramRole = .frontLeft
    var subwooferIndex: UInt32 = 0
    var protectedDriverBus: SpeakerOutputBus = .leftLow
    /// E8 B2: the routed way a `driverNearField` draft measures (set by the linearisation UI, B3).
    var routedWayID: UUID?
    /// E8 A2b: a protected-driver draft targets a routed way (`e8.lab-routed-ways` on) instead of a legacy bus.
    var usesRoutedWays = false
    var distanceMeters: Double = 1.0
    var horizontalAngleDegrees: Double = 0
    var verticalAngleDegrees: Double = 0
    var repeatCount: Int =
        SpeakerMeasurementLabRequest.minimumRepeatCount
    var usesExplicitExcitationLevel = false
    var excitationLevelDBFS: Double = -30
    var nearFieldComponentKind:
        SpeakerMeasurementLabNearFieldComponentKind = .radiator
    var nearFieldComponentLabel = ""

    mutating func applyModeDefaults(
        _ newMode: SpeakerMeasurementLabMode
    ) {
        mode = newMode
        switch newMode {
        case .wholeSpeakerOnAxis:
            name = "On-Axis"
            distanceMeters = 1.0
            horizontalAngleDegrees = 0
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = false
        case .wholeSpeakerOffAxis:
            name = "Off-Axis 30°"
            distanceMeters = 1.0
            horizontalAngleDegrees = 30
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = false
        case .subwooferNearField:
            name = "Sub Near-Field"
            distanceMeters = 0.05
            horizontalAngleDegrees = 0
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = false
        case .protectedDriverNearField:
            name = "Protected Driver Near-Field"
            distanceMeters = 0.05
            horizontalAngleDegrees = 0
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = true
            excitationLevelDBFS = min(excitationLevelDBFS, -24)
        case .driverNearField:
            name = "Driver Near-Field"
            distanceMeters = 0.03
            horizontalAngleDegrees = 0
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = true
            excitationLevelDBFS = min(excitationLevelDBFS, -30)
        case .coherentMainsSubTiming:
            name = "Coherent Main / Sub"
            distanceMeters = 2.5
            horizontalAngleDegrees = 0
            verticalAngleDegrees = 0
            usesExplicitExcitationLevel = true
            excitationLevelDBFS = min(excitationLevelDBFS, -12)
        }
    }

    func makeProtocols(
        idFactory: () -> UUID = UUID.init
    ) throws -> [SpeakerMeasurementLabProtocol] {
        let geometry = SpeakerMeasurementLabGeometry(
            distanceMeters: distanceMeters,
            horizontalAngleDegrees: horizontalAngleDegrees,
            verticalAngleDegrees: verticalAngleDegrees,
            speakerRemainedInstalled: true
        )
        let explicitLevel: Double? =
            (usesExplicitExcitationLevel
                || mode == .protectedDriverNearField
                || mode == .driverNearField
                || mode == .coherentMainsSubTiming)
            ? excitationLevelDBFS : nil

        let protocols: [SpeakerMeasurementLabProtocol]
        switch mode {
        case .wholeSpeakerOnAxis, .wholeSpeakerOffAxis:
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: name,
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: .acousticSource(.speaker(speakerRole)),
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel
                )
            ]

        case .subwooferNearField:
            let trimmed = nearFieldComponentLabel
                .trimmingCharacters(in: .whitespacesAndNewlines)
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: name,
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: .acousticSource(
                            .subwoofer(subwooferIndex)
                        ),
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel,
                    nearFieldComponent:
                        SpeakerMeasurementLabNearFieldComponent(
                            kind: nearFieldComponentKind,
                            label: trimmed.isEmpty ? nil : trimmed,
                            effectiveRadiatingAreaSquareMeters: nil
                        )
                )
            ]

        case .protectedDriverNearField where usesRoutedWays:
            guard let routedWayID else {
                throw SpeakerMeasurementLabError.invalidTarget
            }
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: name,
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: .protectedRoutedWay(routedWayID),
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel,
                    driverCaptureSource: .speaker(speakerRole)
                )
            ]

        case .protectedDriverNearField:
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: name,
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: .protectedDriverBus(
                            protectedDriverBus
                        ),
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel
                )
            ]

        case .driverNearField:
            guard let routedWayID else {
                throw SpeakerMeasurementLabError.invalidTarget
            }
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: name,
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: .routedWay(routedWayID),
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel,
                    driverCaptureSource: .speaker(speakerRole)
                )
            ]

        case .coherentMainsSubTiming:
            let pairID = idFactory()
            let target = SpeakerMeasurementLabTarget.sourcePair(
                main: .speaker(speakerRole),
                subwoofer: .subwoofer(subwooferIndex)
            )
            protocols = [
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: "\(name) · Main",
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: target,
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel,
                    coherentPairID: pairID,
                    coherentLeg: .main
                ),
                SpeakerMeasurementLabProtocol(
                    id: idFactory(),
                    name: "\(name) · Sub",
                    request: SpeakerMeasurementLabRequest(
                        mode: mode,
                        target: target,
                        geometry: geometry,
                        repeatCount: repeatCount
                    ),
                    excitationLevelDBFS: explicitLevel,
                    coherentPairID: pairID,
                    coherentLeg: .subwoofer
                ),
            ]
        }

        for labProtocol in protocols {
            try labProtocol.validateForAcquisition()
        }
        return protocols
    }
}
