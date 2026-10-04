#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one patch anchor, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1))


profile_path = ROOT / "NotchSixty/Audio/Routing/OutputDeviceProfileConfiguration.swift"
compiler_path = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
designer_path = ROOT / "NotchSixty/Audio/MultichannelCalibrationDesigner.swift"
analyzer_path = ROOT / "NotchSixty/Audio/RoomCorrectionMeasurementAnalyzer.swift"
project_path = ROOT / "NotchSixty.xcodeproj/project.pbxproj"

# Persist calibration beside the physical assignment it calibrates. Optional fields
# preserve pre-PR64 Codable archives.
replace_once(
    profile_path,
    '''struct SemanticSpeakerOutputAssignment: Codable, Equatable, Sendable {
    var role: OutputProgramRole
    var destination: PhysicalOutputEndpoint
}

/// Explicit physical Sub N destination. `index` is zero-based and must be dense
/// from 0...N-1 so it maps deterministically onto PR55's Sub 1...N outputs.
struct PhysicalSubwooferOutputAssignment: Codable, Equatable, Sendable {
    var index: UInt32
    var destination: PhysicalOutputEndpoint
}
''',
    '''struct SemanticSpeakerOutputAssignment: Codable, Equatable, Sendable {
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
'''
)

replace_once(
    profile_path,
    '''    var synchronizationMode: MultiOutputSynchronizationMode
    var referenceDeviceUID: String?

    init(
        enabled: Bool = false,
        programLayout: OutputProgramLayout = .stereo,
        speakerAssignments: [SemanticSpeakerOutputAssignment] = [],
        subwooferAssignments: [PhysicalSubwooferOutputAssignment] = [],
        synchronizationMode: MultiOutputSynchronizationMode = .automatic,
        referenceDeviceUID: String? = nil
    ) {
        self.enabled = enabled
        self.programLayout = programLayout
        self.speakerAssignments = speakerAssignments
        self.subwooferAssignments = subwooferAssignments
        self.synchronizationMode = synchronizationMode
        self.referenceDeviceUID = referenceDeviceUID
    }
''',
    '''    var synchronizationMode: MultiOutputSynchronizationMode
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
'''
)

replace_once(
    profile_path,
    '''            guard destinations.insert(assignment.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(assignment.destination)
            }
        }

        for role in programLayout.roles where role != .lowFrequencyEffects {
''',
    '''            guard destinations.insert(assignment.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(assignment.destination)
            }
            try assignment.calibration?.validate()
        }

        for role in programLayout.roles where role != .lowFrequencyEffects {
'''
)

replace_once(
    profile_path,
    '''            guard destinations.insert(sub.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(sub.destination)
            }
        }
    }

    func makeLivePlan(
''',
    '''            guard destinations.insert(sub.destination).inserted else {
                throw OutputDeviceProfileError.duplicateDestination(sub.destination)
            }
            try sub.calibration?.validate()
        }
        try calibrationSummary?.validate()
    }

    func makeLivePlan(
'''
)

replace_once(
    profile_path,
    '''        guard sampleRate.isFinite, sampleRate > 0 else {
            throw OutputDeviceProfileError.invalidSampleRate(sampleRate)
        }
        guard synchronizationMode != .softwarePLL else {
''',
    '''        guard sampleRate.isFinite, sampleRate > 0 else {
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
'''
)

replace_once(
    profile_path,
    '''        let plan = LiveNChannelOutputRoutePlan(
            programLayout: programLayout,
            orderedDeviceUIDs: orderedUIDs,
            referenceDeviceUID: reference,
            physicalChannelCount: UInt32(flattenedCount),
            programPhysicalChannels: programPhysical,
            subwooferPhysicalChannels: subPhysical,
            subwooferCount: UInt32(subwooferAssignments.count),
            bassManagementEnabled: bassManagementEnabled
        )
''',
    '''        let speakerCalibrations = Dictionary(
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
'''
)

replace_once(
    profile_path,
    '''    let subwooferCount: UInt32
    let bassManagementEnabled: Bool

    var usesMultiplePhysicalDevices: Bool { orderedDeviceUIDs.count > 1 }
''',
    '''    let subwooferCount: UInt32
    let bassManagementEnabled: Bool
    let speakerCalibrations: [OutputProgramRole: SemanticSpeakerCalibration]
    let subwooferCalibrations: [PhysicalSubwooferCalibration?]

    var usesMultiplePhysicalDevices: Bool { orderedDeviceUIDs.count > 1 }
'''
)

# Deploy calibration into PR54 lanes and PR55 physical-sub processing at graph build.
old_compiler = '''        let combinedGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard combinedGain.isFinite, combinedGain >= 0, combinedGain <= 16 else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
        for channel in 0..<layout.channelCount {
            guard N60ProgramLaneGraphSetGain(&lanes, channel, combinedGain) else {
                throw LiveNChannelTransportError.renderGraphInvalid
            }
        }
        guard N60ProgramLaneGraphFinalize(&lanes) else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
'''
new_compiler = '''        let combinedGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard combinedGain.isFinite, combinedGain >= 0, combinedGain <= 16 else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
        let programRoles = routePlan.programLayout.roles
        for channel in 0..<layout.channelCount {
            let role = programRoles[Int(channel)]
            let calibration = routePlan.speakerCalibrations[role]
            let calibratedGain = combinedGain * DSPGainConfiguration.linearGain(
                forDB: calibration?.trimDB ?? 0
            )
            guard N60ProgramLaneGraphSetGain(&lanes, channel, calibratedGain),
                  N60ProgramLaneGraphSetPolarityInverted(
                    &lanes,
                    channel,
                    calibration?.polarityInverted ?? false
                  ),
                  N60ProgramLaneGraphSetDelayMs(
                    &lanes,
                    channel,
                    calibration?.delayMilliseconds ?? 0
                  ) else {
                throw LiveNChannelTransportError.renderGraphInvalid
            }
            if let calibration {
                for (bandIndex, band) in calibration.eqBands.enumerated() {
                    guard N60ProgramLaneGraphSetEQBand(
                        &lanes,
                        channel,
                        UInt32(bandIndex),
                        N60BiquadFilterTypePeaking,
                        band.frequencyHz,
                        band.gainDB,
                        band.q,
                        true
                    ) else {
                        throw LiveNChannelTransportError.renderGraphInvalid
                    }
                }
            }
        }
        guard N60ProgramLaneGraphFinalize(&lanes) else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
'''
replace_once(compiler_path, old_compiler, new_compiler)

replace_once(
    compiler_path,
    '''            let routeGain = 1.0 / Float(max(routePlan.subwooferCount, 1))
            let programRoles = routePlan.programLayout.roles
            for channel in 0..<layout.channelCount {
''',
    '''            let routeGain = 1.0 / Float(max(routePlan.subwooferCount, 1))
            for channel in 0..<layout.channelCount {
'''
)

replace_once(
    compiler_path,
    '''            for sub in 0..<routePlan.subwooferCount {
                guard N60MultichannelBassManagementSetLFERoute(&bass, sub, routeGain),
                      N60SubwooferOutputSetGain(
                        &bass,
                        sub,
                        DSPGainConfiguration.linearGain(forDB: bassManagementConfiguration.subGainDB)
                      ),
                      N60SubwooferOutputSetPolarityInverted(
                        &bass,
                        sub,
                        bassManagementConfiguration.subPolarityInverted
                      ) else {
                    throw LiveNChannelTransportError.renderGraphInvalid
                }
            }
''',
    '''            for sub in 0..<routePlan.subwooferCount {
                let calibration = routePlan.subwooferCalibrations[Int(sub)]
                let calibratedGainDB = bassManagementConfiguration.subGainDB
                    + (calibration?.gainDB ?? 0)
                let calibratedPolarity = bassManagementConfiguration.subPolarityInverted
                    != (calibration?.polarityInverted ?? false)
                guard N60MultichannelBassManagementSetLFERoute(&bass, sub, routeGain),
                      N60SubwooferOutputSetGain(
                        &bass,
                        sub,
                        DSPGainConfiguration.linearGain(forDB: calibratedGainDB)
                      ),
                      N60SubwooferOutputSetPolarityInverted(
                        &bass,
                        sub,
                        calibratedPolarity
                      ),
                      N60SubwooferOutputSetDelayMs(
                        &bass,
                        sub,
                        calibration?.delayMilliseconds ?? 0
                      ) else {
                    throw LiveNChannelTransportError.renderGraphInvalid
                }
                if let calibration {
                    for (bandIndex, band) in calibration.eqBands.enumerated() {
                        guard N60SubwooferOutputSetUserEQBand(
                            &bass,
                            sub,
                            UInt32(bandIndex),
                            N60BiquadFilterTypePeaking,
                            band.frequencyHz,
                            band.gainDB,
                            band.q,
                            true
                        ) else {
                            throw LiveNChannelTransportError.renderGraphInvalid
                        }
                    }
                }
            }
'''
)

# Give the offline analyzer a single-source entry point for targeted campaigns.
replace_once(
    analyzer_path,
    '''        return RoomCorrectionMeasurementAnalysis(
            sampleRate: sampleRate,
            left: left,
            right: right
        )
    }

    private func analyzeChannel(
''',
    '''        return RoomCorrectionMeasurementAnalysis(
            sampleRate: sampleRate,
            left: left,
            right: right
        )
    }

    func analyzeSingleChannel(
        rawCapture: [Float],
        program: RoomCorrectionSweepProgram,
        microphoneCalibration: RoomCorrectionMicrophoneCalibration? = nil,
        capturedAt: Date = Date()
    ) throws -> RoomCorrectionChannelMeasurement {
        guard program.sampleRate.isFinite, program.sampleRate > 0 else {
            throw RoomCorrectionMeasurementAnalysisError.invalidSampleRate(program.sampleRate)
        }
        try validateProgram(program)
        try validateCalibration(microphoneCalibration)
        return try analyzeChannel(
            rawCapture: rawCapture,
            pass: .left,
            expectedFrameCount: program.captureFrameCount,
            program: program,
            calibration: microphoneCalibration,
            capturedAt: capturedAt
        )
    }

    private func analyzeChannel(
'''
)

# Restrict the multi-sub optimizer to a dedicated LF matrix while speaker design
# keeps the full audible matrix.
replace_once(
    designer_path,
    '''        var subResult: N60MultiSubOptimizationResult?
        if bassManagementEnabled, !profile.subwooferAssignments.isEmpty {
            var settings = N60MultiSubOptimizationSettingsMakeDefault()
            settings.maximumGainDB = 0
            settings.minimumGainDB = -12
            settings.maximumEQDB = 0
            settings.minimumEQDB = -8
            var result = N60MultiSubOptimizationResult()
            let optimized = targetMagnitude.withUnsafeBufferPointer { targetBuffer in
                N60MultiSubOptimize(
                    &matrix,
                    UInt32(profile.subwooferAssignments.count),
                    targetBuffer.baseAddress,
                    settings,
                    &result
                )
            }
            guard optimized else {
                throw OutputDeviceCalibrationError.designFailed("multi-sub optimization failed")
            }
            subResult = result
        }
''',
    '''        var subResult: N60MultiSubOptimizationResult?
        var subOptimizationFrequencies = frequencies
        if bassManagementEnabled, !profile.subwooferAssignments.isEmpty {
            let subFrequencies = Self.logFrequencyGrid(
                minimumHz: Self.minimumFrequencyHz,
                maximumHz: min(
                    Self.subwooferMaximumFrequencyHz,
                    sampleRate * 0.48
                ),
                count: Self.frequencyBinCount
            )
            var subMatrix = subFrequencies.withUnsafeBufferPointer { buffer in
                N60MultichannelCalibrationMatrixMake(
                    sampleRate,
                    profile.programLayout.realtimeLayout,
                    UInt32(profile.subwooferAssignments.count),
                    UInt32(includedSeats.count),
                    buffer.baseAddress,
                    UInt32(buffer.count)
                )
            }
            guard subMatrix.sourceCount > 0 else {
                throw OutputDeviceCalibrationError.designFailed("low-frequency calibration matrix could not be created")
            }
            for (seatIndex, seat) in includedSeats.enumerated() {
                guard N60MultichannelCalibrationSetSeat(
                    &subMatrix,
                    UInt32(seatIndex),
                    true,
                    Float(seat.weight)
                ) else {
                    throw OutputDeviceCalibrationError.designFailed("low-frequency seat weighting failed")
                }
                for role in profile.programLayout.roles where role != .lowFrequencyEffects {
                    let item = try measurement(
                        seatID: seat.id,
                        source: .speaker(role),
                        measurements: measurements,
                        expectedSampleRate: sampleRate
                    )
                    let sourceIndex = N60MultichannelCalibrationSourceIndexForRole(
                        &subMatrix,
                        role.realtimeCType
                    )
                    guard sourceIndex >= 0 else {
                        throw OutputDeviceCalibrationError.designFailed("low-frequency speaker source is missing")
                    }
                    try install(
                        measurement: item,
                        frequencies: subFrequencies,
                        sourceIndex: UInt32(sourceIndex),
                        seatIndex: UInt32(seatIndex),
                        into: &subMatrix
                    )
                }
                for sub in profile.subwooferAssignments.sorted(by: { $0.index < $1.index }) {
                    let item = try measurement(
                        seatID: seat.id,
                        source: .subwoofer(sub.index),
                        measurements: measurements,
                        expectedSampleRate: sampleRate
                    )
                    let sourceIndex = N60MultichannelCalibrationSourceIndexForSubwoofer(
                        &subMatrix,
                        sub.index
                    )
                    guard sourceIndex >= 0 else {
                        throw OutputDeviceCalibrationError.designFailed("low-frequency subwoofer source is missing")
                    }
                    try install(
                        measurement: item,
                        frequencies: subFrequencies,
                        sourceIndex: UInt32(sourceIndex),
                        seatIndex: UInt32(seatIndex),
                        into: &subMatrix
                    )
                }
            }
            guard N60MultichannelCalibrationMatrixIsValid(
                &subMatrix,
                UInt32(profile.subwooferAssignments.count)
            ) else {
                throw OutputDeviceCalibrationError.designFailed("low-frequency measurement matrix is incomplete")
            }
            let subTargetMagnitude = subFrequencies.map {
                Float(alignment.commonLevelDB) + Float(Self.targetGainDB(target, at: Double($0)))
            }
            var settings = N60MultiSubOptimizationSettingsMakeDefault()
            settings.maximumGainDB = 0
            settings.minimumGainDB = -12
            settings.maximumEQDB = 0
            settings.minimumEQDB = -8
            var result = N60MultiSubOptimizationResult()
            let optimized = subTargetMagnitude.withUnsafeBufferPointer { targetBuffer in
                N60MultiSubOptimize(
                    &subMatrix,
                    UInt32(profile.subwooferAssignments.count),
                    targetBuffer.baseAddress,
                    settings,
                    &result
                )
            }
            guard optimized else {
                throw OutputDeviceCalibrationError.designFailed("multi-sub optimization failed")
            }
            subOptimizationFrequencies = subFrequencies
            subResult = result
        }
'''
)

replace_once(
    designer_path,
    '''            frequencies: frequencies,
            count: profile.subwooferAssignments.count,
''',
    '''            frequencies: subOptimizationFrequencies,
            count: profile.subwooferAssignments.count,
'''
)

# Register the two PR64 model/compiler files in the explicit Xcode target.
project = project_path.read_text()

def project_insert(anchor: str, addition: str) -> None:
    global project
    count = project.count(anchor)
    if count != 1:
        raise SystemExit(f"project.pbxproj expected one anchor, found {count}: {anchor}")
    project = project.replace(anchor, anchor + addition, 1)

project_insert(
    '\t\tF62000000000000000000001 /* OutputDeviceProfileConfiguration.swift in Sources */ = {isa = PBXBuildFile; fileRef = F62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */; };\n',
    '\t\tF64000000000000000000001 /* OutputDeviceCalibration.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000011 /* OutputDeviceCalibration.swift */; };\n'
    '\t\tF64000000000000000000002 /* MultichannelCalibrationDesigner.swift in Sources */ = {isa = PBXBuildFile; fileRef = F64000000000000000000012 /* MultichannelCalibrationDesigner.swift */; };\n'
)
project_insert(
    '\t\tF62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OutputDeviceProfileConfiguration.swift; sourceTree = "<group>"; };\n',
    '\t\tF64000000000000000000011 /* OutputDeviceCalibration.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = OutputDeviceCalibration.swift; sourceTree = "<group>"; };\n'
    '\t\tF64000000000000000000012 /* MultichannelCalibrationDesigner.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = MultichannelCalibrationDesigner.swift; sourceTree = "<group>"; };\n'
)
project_insert(
    '\t\t\t\tF62000000000000000000011 /* OutputDeviceProfileConfiguration.swift */,\n',
    '\t\t\t\tF64000000000000000000011 /* OutputDeviceCalibration.swift */,\n'
)
# Designer belongs in the Audio group next to existing standalone audio model files.
project_insert(
    '\t\t\t\tA20000000000000000000029 /* DynamicsConfiguration.swift */,\n',
    '\t\t\t\tF64000000000000000000012 /* MultichannelCalibrationDesigner.swift */,\n'
)
project_insert(
    '\t\t\t\tF62000000000000000000001 /* OutputDeviceProfileConfiguration.swift in Sources */,\n',
    '\t\t\t\tF64000000000000000000001 /* OutputDeviceCalibration.swift in Sources */,\n'
    '\t\t\t\tF64000000000000000000002 /* MultichannelCalibrationDesigner.swift in Sources */,\n'
)
project_path.write_text(project)

print("PR64 calibration integration patch applied")
