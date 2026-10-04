import Foundation

/// Semantic program identities owned by an Output Device Profile. These are
/// independent of both Core Audio stream order and physical output channel numbers.
enum OutputProgramRole: String, CaseIterable, Identifiable, Codable, Sendable {
    case frontLeft
    case frontRight
    case frontCenter
    case lowFrequencyEffects
    case sideLeft
    case sideRight
    case rearLeft
    case rearRight
    case wideLeft
    case wideRight
    case topFrontLeft
    case topFrontRight
    case topMiddleLeft
    case topMiddleRight
    case topRearLeft
    case topRearRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frontLeft: return "Front Left"
        case .frontRight: return "Front Right"
        case .frontCenter: return "Center"
        case .lowFrequencyEffects: return "LFE"
        case .sideLeft: return "Side Left"
        case .sideRight: return "Side Right"
        case .rearLeft: return "Rear Left"
        case .rearRight: return "Rear Right"
        case .wideLeft: return "Wide Left"
        case .wideRight: return "Wide Right"
        case .topFrontLeft: return "Top Front Left"
        case .topFrontRight: return "Top Front Right"
        case .topMiddleLeft: return "Top Middle Left"
        case .topMiddleRight: return "Top Middle Right"
        case .topRearLeft: return "Top Rear Left"
        case .topRearRight: return "Top Rear Right"
        }
    }

    var realtimeCType: N60ProgramChannelRole {
        switch self {
        case .frontLeft: return N60ProgramChannelRoleFrontLeft
        case .frontRight: return N60ProgramChannelRoleFrontRight
        case .frontCenter: return N60ProgramChannelRoleFrontCenter
        case .lowFrequencyEffects: return N60ProgramChannelRoleLowFrequencyEffects
        case .sideLeft: return N60ProgramChannelRoleSideLeft
        case .sideRight: return N60ProgramChannelRoleSideRight
        case .rearLeft: return N60ProgramChannelRoleRearLeft
        case .rearRight: return N60ProgramChannelRoleRearRight
        case .wideLeft: return N60ProgramChannelRoleWideLeft
        case .wideRight: return N60ProgramChannelRoleWideRight
        case .topFrontLeft: return N60ProgramChannelRoleTopFrontLeft
        case .topFrontRight: return N60ProgramChannelRoleTopFrontRight
        case .topMiddleLeft: return N60ProgramChannelRoleTopMiddleLeft
        case .topMiddleRight: return N60ProgramChannelRoleTopMiddleRight
        case .topRearLeft: return N60ProgramChannelRoleTopRearLeft
        case .topRearRight: return N60ProgramChannelRoleTopRearRight
        }
    }
}

/// Program-channel layout. Physical subwoofer count is deliberately not encoded
/// here: e.g. 2.1/2.2 are `.stereo` plus one/two physical sub assignments, while
/// 5.2/7.2 are `.fiveOne`/`.sevenOne` plus two physical sub assignments.
enum OutputProgramLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case stereo
    case threeOne
    case fiveOne
    case sevenOne
    case fiveOneTwo
    case fiveOneFour
    case sevenOneFour
    case nineOneSix

    var id: String { rawValue }

    /// Program/source-layout nomenclature. A Playback System's user-facing name
    /// is derived separately from its physical subwoofer assignment count.
    var displayName: String {
        switch self {
        case .stereo: return "2.0"
        case .threeOne: return "3.1"
        case .fiveOne: return "5.1"
        case .sevenOne: return "7.1"
        case .fiveOneTwo: return "5.1.2"
        case .fiveOneFour: return "5.1.4"
        case .sevenOneFour: return "7.1.4"
        case .nineOneSix: return "9.1.6"
        }
    }

    var bedChannelCount: Int {
        switch self {
        case .stereo: return 2
        case .threeOne: return 3
        case .fiveOne, .fiveOneTwo, .fiveOneFour: return 5
        case .sevenOne, .sevenOneFour: return 7
        case .nineOneSix: return 9
        }
    }

    var heightChannelCount: Int {
        switch self {
        case .stereo, .threeOne, .fiveOne, .sevenOne: return 0
        case .fiveOneTwo: return 2
        case .fiveOneFour, .sevenOneFour: return 4
        case .nineOneSix: return 6
        }
    }

    var roles: [OutputProgramRole] {
        switch self {
        case .stereo:
            return [.frontLeft, .frontRight]
        case .threeOne:
            return [.frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects]
        case .fiveOne:
            return [.frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects, .sideLeft, .sideRight]
        case .sevenOne:
            return [
                .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects,
                .sideLeft, .sideRight, .rearLeft, .rearRight,
            ]
        case .fiveOneTwo:
            return [
                .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects,
                .sideLeft, .sideRight, .topMiddleLeft, .topMiddleRight,
            ]
        case .fiveOneFour:
            return [
                .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects,
                .sideLeft, .sideRight,
                .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight,
            ]
        case .sevenOneFour:
            return [
                .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects,
                .sideLeft, .sideRight, .rearLeft, .rearRight,
                .topFrontLeft, .topFrontRight, .topRearLeft, .topRearRight,
            ]
        case .nineOneSix:
            return [
                .frontLeft, .frontRight, .frontCenter, .lowFrequencyEffects,
                .sideLeft, .sideRight, .rearLeft, .rearRight, .wideLeft, .wideRight,
                .topFrontLeft, .topFrontRight, .topMiddleLeft, .topMiddleRight,
                .topRearLeft, .topRearRight,
            ]
        }
    }

    var containsLFE: Bool { roles.contains(.lowFrequencyEffects) }

    var realtimeLayout: N60ProgramChannelLayout {
        switch self {
        case .stereo:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo)
        case .fiveOne:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne)
        case .sevenOne:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOne)
        case .fiveOneTwo:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOneTwo)
        case .fiveOneFour:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOneFour)
        case .sevenOneFour:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOneFour)
        case .nineOneSix:
            return N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutNineOneSix)
        case .threeOne:
            var cRoles = roles.map(\.realtimeCType)
            return cRoles.withUnsafeBufferPointer { buffer in
                N60ProgramChannelLayoutMakeCustom(buffer.baseAddress, UInt32(buffer.count))
            }
        }
    }
}

struct SemanticSpeakerOutputAssignment: Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var destination: PhysicalOutputEndpoint
    var calibration: SemanticSpeakerCalibration?

    init(
        role: OutputProgramRole,
        destination: PhysicalOutputEndpoint,
        calibration: SemanticSpeakerCalibration? = nil
    ) {
        self.role = role
        self.destination = destination
        self.calibration = calibration
    }
}

/// Explicit physical Sub N destination. `index` is zero-based and must be dense
/// from 0...N-1 so it maps deterministically onto PR55's Sub 1...N outputs.
struct PhysicalSubwooferOutputAssignment: Codable, Equatable, Sendable {
    var index: UInt32
    var destination: PhysicalOutputEndpoint
    var calibration: PhysicalSubwooferCalibration?

    init(
        index: UInt32,
        destination: PhysicalOutputEndpoint,
        calibration: PhysicalSubwooferCalibration? = nil
    ) {
        self.index = index
        self.destination = destination
        self.calibration = calibration
    }
}

enum OutputDeviceProfileError: Error, Equatable, LocalizedError {
    case profileDisabled
    case missingSpeaker(OutputProgramRole)
    case duplicateSpeaker(OutputProgramRole)
    case unexpectedSpeaker(OutputProgramRole)
    case lfeMustBeUnmappedWhenBassManaged
    case lfePhysicalOutputRequired
    case physicalSubwooferRequired
    case physicalSubwoofersRequireBassManagement
    case tooManyPhysicalSubwoofers(Int)
    case invalidPhysicalSubwooferIndex(UInt32)
    case duplicateDestination(PhysicalOutputEndpoint)
    case emptyDeviceUID
    case outputDeviceUnavailable(String)
    case outputChannelUnavailable(deviceUID: String, channelIndex: UInt32, channelCount: UInt32)
    case sampleRateUnsupported(deviceUID: String, sampleRate: Double)
    case invalidSampleRate(Double)
    case selectedOutputNotRouted(String)
    case referenceDeviceNotRouted(String)
    case softwarePLLSuperseded
    case physicalChannelCountOverflow
    case realtimeOutputMapCompilationFailed
    case legacyPhysicalRoutingConflict

    var errorDescription: String? {
        switch self {
        case .profileDisabled:
            return "Enable the Output Device Profile before compiling a live N-channel route plan."
        case .missingSpeaker(let role):
            return "Output Device Profile is missing \(role.displayName)."
        case .duplicateSpeaker(let role):
            return "Output Device Profile assigns \(role.displayName) more than once."
        case .unexpectedSpeaker(let role):
            return "\(role.displayName) is not part of the selected program layout."
        case .lfeMustBeUnmappedWhenBassManaged:
            return "Bass-managed layouts route native LFE through the explicit LFE-to-subwoofer matrix; do not map LFE directly to a physical speaker channel."
        case .lfePhysicalOutputRequired:
            return "With bass management bypassed, a layout containing LFE requires an explicit physical LFE output."
        case .physicalSubwooferRequired:
            return "Enable and assign at least one physical subwoofer for bass-managed playback."
        case .physicalSubwoofersRequireBassManagement:
            return "Physical Sub outputs require bass management; otherwise semantic LFE remains an ordinary program output."
        case .tooManyPhysicalSubwoofers(let count):
            return "At most \(Int(N60_MAX_SUBWOOFER_OUTPUTS)) physical subwoofers are supported; profile contains \(count)."
        case .invalidPhysicalSubwooferIndex(let index):
            return "Physical subwoofer indices must be contiguous from Sub 1; found index \(index + 1)."
        case .duplicateDestination(let endpoint):
            return "Physical output \(endpoint.deviceUID) channel \(endpoint.channelIndex + 1) is assigned more than once."
        case .emptyDeviceUID:
            return "Every Output Device Profile assignment must identify a physical output device."
        case .outputDeviceUnavailable(let uid):
            return "A profile output device is not currently available: \(uid)."
        case .outputChannelUnavailable(let uid, let channelIndex, let channelCount):
            return "Output device \(uid) has \(channelCount) channels; channel \(channelIndex + 1) cannot be assigned."
        case .sampleRateUnsupported(let uid, let sampleRate):
            return "Output device \(uid) does not support \(sampleRate) Hz natively."
        case .invalidSampleRate(let sampleRate):
            return "Output Device Profile sample rate \(sampleRate) Hz is invalid."
        case .selectedOutputNotRouted(let uid):
            return "The selected output device \(uid) is not used by the Output Device Profile."
        case .referenceDeviceNotRouted(let uid):
            return "The synchronization reference device \(uid) is not used by the Output Device Profile."
        case .softwarePLLSuperseded:
            return "Software PLL mode is superseded by the Core Audio Aggregate Device clock domain with HAL drift compensation."
        case .physicalChannelCountOverflow:
            return "The flattened physical output map exceeds the live N-channel engine's channel limit."
        case .realtimeOutputMapCompilationFailed:
            return "Unable to compile the Output Device Profile into the live N-channel physical output map."
        case .legacyPhysicalRoutingConflict:
            return "Disable legacy stereo physical-output routing before enabling the semantic Output Device Profile."
        }
    }
}

/// Persistent hardware/calibration-layer routing owned by a Playback System.
/// Listening/Content Presets intentionally do not own this state.
struct OutputDeviceProfileConfiguration: Codable, Equatable, Sendable {
    var enabled: Bool
    var programLayout: OutputProgramLayout
    var speakerAssignments: [SemanticSpeakerOutputAssignment]
    var subwooferAssignments: [PhysicalSubwooferOutputAssignment]
    var synchronizationMode: MultiOutputSynchronizationMode
    var referenceDeviceUID: String?
    var calibrationSummary: MultichannelCalibrationDeploymentSummary?

    init(
        enabled: Bool = false,
        programLayout: OutputProgramLayout = .stereo,
        speakerAssignments: [SemanticSpeakerOutputAssignment] = [],
        subwooferAssignments: [PhysicalSubwooferOutputAssignment] = [],
        synchronizationMode: MultiOutputSynchronizationMode = .automatic,
        referenceDeviceUID: String? = nil,
        calibrationSummary: MultichannelCalibrationDeploymentSummary? = nil
    ) {
        self.enabled = enabled
        self.programLayout = programLayout
        self.speakerAssignments = speakerAssignments
        self.subwooferAssignments = subwooferAssignments
        self.synchronizationMode = synchronizationMode
        self.referenceDeviceUID = referenceDeviceUID
        self.calibrationSummary = calibrationSummary
    }

    var requiredDeviceUIDs: Set<String> {
        Set((speakerAssignments.map(\.destination.deviceUID)
            + subwooferAssignments.map(\.destination.deviceUID)))
    }

    var physicalSubwooferCount: Int { subwooferAssignments.count }

    /// User-facing physical speaker-system nomenclature. Native LFE is a program
    /// channel, while Sub N assignments are physical outputs; when subs are
    /// explicitly assigned they replace the middle program-layout "1" in the
    /// display label (e.g. 9.1.6 program + two subs -> 9.2.6).
    var systemDisplayName: String {
        let displayedSubwooferCount = subwooferAssignments.isEmpty
            ? (programLayout.containsLFE ? 1 : 0)
            : subwooferAssignments.count
        if programLayout.heightChannelCount > 0 {
            return "\(programLayout.bedChannelCount).\(displayedSubwooferCount).\(programLayout.heightChannelCount)"
        }
        return "\(programLayout.bedChannelCount).\(displayedSubwooferCount)"
    }

    func validateStructure(bassManagementEnabled: Bool) throws {
        guard subwooferAssignments.count <= Int(N60_MAX_SUBWOOFER_OUTPUTS) else {
            throw OutputDeviceProfileError.tooManyPhysicalSubwoofers(subwooferAssignments.count)
        }

        let layoutRoles = Set(programLayout.roles)
        var seenRoles = Set<OutputProgramRole>()
        var destinations = Set<PhysicalOutputEndpoint>()
        for assignment in speakerAssignments {
            guard layoutRoles.contains(assignment.role) else {
                throw OutputDeviceProfileError.unexpectedSpeaker(assignment.role)
            }
            guard seenRoles.insert(assignment.role).inserted else {
                throw OutputDeviceProfileError.duplicateSpeaker(assignment.role)
            }
            guard !assignment.destination.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OutputDeviceProfileError.emptyDeviceUID
            }
            guard destinations.insert(assignment.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(assignment.destination)
            }
            try assignment.calibration?.validate()
        }

        for role in programLayout.roles where role != .lowFrequencyEffects {
            guard seenRoles.contains(role) else {
                throw OutputDeviceProfileError.missingSpeaker(role)
            }
        }

        if bassManagementEnabled {
            guard !seenRoles.contains(.lowFrequencyEffects) else {
                throw OutputDeviceProfileError.lfeMustBeUnmappedWhenBassManaged
            }
            guard !subwooferAssignments.isEmpty else {
                throw OutputDeviceProfileError.physicalSubwooferRequired
            }
        } else {
            guard subwooferAssignments.isEmpty else {
                throw OutputDeviceProfileError.physicalSubwoofersRequireBassManagement
            }
            if programLayout.containsLFE, !seenRoles.contains(.lowFrequencyEffects) {
                throw OutputDeviceProfileError.lfePhysicalOutputRequired
            }
        }

        let sortedSubs = subwooferAssignments.sorted { $0.index < $1.index }
        for (expected, sub) in sortedSubs.enumerated() {
            guard sub.index == UInt32(expected) else {
                throw OutputDeviceProfileError.invalidPhysicalSubwooferIndex(sub.index)
            }
            guard !sub.destination.deviceUID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw OutputDeviceProfileError.emptyDeviceUID
            }
            guard destinations.insert(sub.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(sub.destination)
            }
            try sub.calibration?.validate()
        }
        try calibrationSummary?.validate()
    }

    func makeLivePlan(
        availableDevices: [AudioOutputDevice],
        sampleRate: Double,
        selectedOutputUID: String,
        bassManagementEnabled: Bool
    ) throws -> LiveNChannelOutputRoutePlan {
        guard enabled else {
            throw OutputDeviceProfileError.profileDisabled
        }
        try validateStructure(bassManagementEnabled: bassManagementEnabled)
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OutputDeviceProfileError.invalidSampleRate(sampleRate)
        }
        for assignment in speakerAssignments {
            try assignment.calibration?.validate(sampleRate: sampleRate)
        }
        for assignment in subwooferAssignments {
            try assignment.calibration?.validate(sampleRate: sampleRate)
        }
        if let summary = calibrationSummary {
            try summary.validate()
            guard abs(summary.sampleRate - sampleRate) < 0.5 else {
                throw OutputDeviceCalibrationError.sampleRateMismatch(
                    expected: summary.sampleRate,
                    actual: sampleRate
                )
            }
        }
        guard synchronizationMode != .softwarePLL else {
            throw OutputDeviceProfileError.softwarePLLSuperseded
        }
        let requiredUIDs = requiredDeviceUIDs
        guard requiredUIDs.contains(selectedOutputUID) else {
            throw OutputDeviceProfileError.selectedOutputNotRouted(selectedOutputUID)
        }
        if let referenceDeviceUID, !requiredUIDs.contains(referenceDeviceUID) {
            throw OutputDeviceProfileError.referenceDeviceNotRouted(referenceDeviceUID)
        }

        let byUID = Dictionary(uniqueKeysWithValues: availableDevices.map { ($0.uid, $0) })
        for uid in requiredUIDs {
            guard let device = byUID[uid] else {
                throw OutputDeviceProfileError.outputDeviceUnavailable(uid)
            }
            guard device.supports(sampleRate: sampleRate) else {
                throw OutputDeviceProfileError.sampleRateUnsupported(
                    deviceUID: uid,
                    sampleRate: sampleRate
                )
            }
        }
        for endpoint in speakerAssignments.map(\.destination) + subwooferAssignments.map(\.destination) {
            guard let device = byUID[endpoint.deviceUID] else {
                throw OutputDeviceProfileError.outputDeviceUnavailable(endpoint.deviceUID)
            }
            guard endpoint.channelIndex < device.outputChannelCount else {
                throw OutputDeviceProfileError.outputChannelUnavailable(
                    deviceUID: endpoint.deviceUID,
                    channelIndex: endpoint.channelIndex,
                    channelCount: device.outputChannelCount
                )
            }
        }

        let reference = referenceDeviceUID ?? selectedOutputUID
        var orderedUIDs = [reference]
        for assignment in speakerAssignments where !orderedUIDs.contains(assignment.destination.deviceUID) {
            orderedUIDs.append(assignment.destination.deviceUID)
        }
        for assignment in subwooferAssignments where !orderedUIDs.contains(assignment.destination.deviceUID) {
            orderedUIDs.append(assignment.destination.deviceUID)
        }

        var offsets: [String: UInt32] = [:]
        var flattenedCount: UInt64 = 0
        for uid in orderedUIDs {
            guard let device = byUID[uid] else {
                throw OutputDeviceProfileError.outputDeviceUnavailable(uid)
            }
            guard flattenedCount <= UInt64(UInt32.max) else {
                throw OutputDeviceProfileError.physicalChannelCountOverflow
            }
            offsets[uid] = UInt32(flattenedCount)
            flattenedCount += UInt64(device.outputChannelCount)
            guard flattenedCount <= UInt64(N60_LIVE_MAX_PHYSICAL_CHANNELS) else {
                throw OutputDeviceProfileError.physicalChannelCountOverflow
            }
        }

        func flattened(_ endpoint: PhysicalOutputEndpoint) throws -> UInt32 {
            guard let offset = offsets[endpoint.deviceUID] else {
                throw OutputDeviceProfileError.outputDeviceUnavailable(endpoint.deviceUID)
            }
            return offset + endpoint.channelIndex
        }

        var programPhysical = [UInt32](
            repeating: UInt32.max,
            count: Int(N60_MAX_PROGRAM_CHANNELS)
        )
        for assignment in speakerAssignments {
            guard let programIndex = programLayout.roles.firstIndex(of: assignment.role) else {
                throw OutputDeviceProfileError.unexpectedSpeaker(assignment.role)
            }
            programPhysical[programIndex] = try flattened(assignment.destination)
        }

        var subPhysical = [UInt32](
            repeating: UInt32.max,
            count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
        )
        for assignment in subwooferAssignments {
            subPhysical[Int(assignment.index)] = try flattened(assignment.destination)
        }

        let speakerCalibrations = Dictionary(
            uniqueKeysWithValues: speakerAssignments.compactMap { assignment in
                assignment.calibration.map { (assignment.role, $0) }
            }
        )
        var subwooferCalibrations = [PhysicalSubwooferCalibration?](
            repeating: nil,
            count: Int(N60_MAX_SUBWOOFER_OUTPUTS)
        )
        for assignment in subwooferAssignments {
            subwooferCalibrations[Int(assignment.index)] = assignment.calibration
        }

        let plan = LiveNChannelOutputRoutePlan(
            programLayout: programLayout,
            orderedDeviceUIDs: orderedUIDs,
            referenceDeviceUID: reference,
            physicalChannelCount: UInt32(flattenedCount),
            programPhysicalChannels: programPhysical,
            subwooferPhysicalChannels: subPhysical,
            subwooferCount: UInt32(subwooferAssignments.count),
            bassManagementEnabled: bassManagementEnabled,
            speakerCalibrations: speakerCalibrations,
            subwooferCalibrations: subwooferCalibrations
        )
        _ = try plan.makeRealtimeOutputMap()
        return plan
    }
}

/// Immutable control-plane result consumed by the PR61 live bridge/session layer.
struct LiveNChannelOutputRoutePlan: Equatable, Sendable {
    let programLayout: OutputProgramLayout
    let orderedDeviceUIDs: [String]
    let referenceDeviceUID: String
    let physicalChannelCount: UInt32
    let programPhysicalChannels: [UInt32]
    let subwooferPhysicalChannels: [UInt32]
    let subwooferCount: UInt32
    let bassManagementEnabled: Bool
    let speakerCalibrations: [OutputProgramRole: SemanticSpeakerCalibration]
    let subwooferCalibrations: [PhysicalSubwooferCalibration?]

    var usesMultiplePhysicalDevices: Bool { orderedDeviceUIDs.count > 1 }

    func makeRealtimeOutputMap() throws -> N60LiveNChannelOutputMap {
        var result = N60LiveNChannelOutputMap()
        let compiled: Bool = programPhysicalChannels.withUnsafeBufferPointer { programBuffer in
            if bassManagementEnabled {
                return subwooferPhysicalChannels.withUnsafeBufferPointer { subBuffer in
                    N60LiveNChannelOutputMapCompile(
                        programLayout.realtimeLayout,
                        physicalChannelCount,
                        programBuffer.baseAddress!,
                        true,
                        subwooferCount,
                        subBuffer.baseAddress,
                        &result
                    )
                }
            }
            return N60LiveNChannelOutputMapCompile(
                programLayout.realtimeLayout,
                physicalChannelCount,
                programBuffer.baseAddress!,
                false,
                0,
                nil,
                &result
            )
        }
        guard compiled else {
            throw OutputDeviceProfileError.realtimeOutputMapCompilationFailed
        }
        return result
    }
}