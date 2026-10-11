struct StereoMeterReading: Equatable, Sendable {
    let peakLeft: Float
    let peakRight: Float
    let rmsLeft: Float
    let rmsRight: Float
    let overRangeSamples: UInt64

    init(_ reading: N60StereoMeterReading) {
        peakLeft = reading.peakLeft
        peakRight = reading.peakRight
        rmsLeft = reading.rmsLeft
        rmsRight = reading.rmsRight
        overRangeSamples = reading.overRangeSamples
    }
}

struct RenderKernelDiagnostics: Equatable, Sendable {
    let renderedFrames: UInt64
    let sanitizedNonFiniteSamples: UInt64
    let flushedDenormalSamples: UInt64
    let snapshotReadMisses: UInt64
    let convolutionProgramMisses: UInt64
    let roomCorrectionProgramMisses: UInt64
    let speakerIRProgramMisses: UInt64
    let publishedGeneration: UInt64
    let latencyFrames: UInt32
    let sampleRate: Double
    let channelCount: UInt32
    let meteringEnabled: Bool
    let bypassed: Bool
    let interChannelDelayMs: Double
    let interChannelAlignmentLatencyFrames: UInt32
    let inputGainLinear: Float
    let headroomGainLinear: Float
    let outputGainLinear: Float
    let balanceGainLeftLinear: Float
    let balanceGainRightLinear: Float
    let eqBypassed: Bool
    let mixedPhaseEnabled: Bool
    let mixedPhaseCorrectionSectionCount: UInt32
    let eqBandCount: UInt32
    let eqLeftBandCount: UInt32
    let eqRightBandCount: UInt32
    let crossoverEnabled: Bool
    let crossoverFrequencyHz: Double
    let crossoverTopology: N60CrossoverTopology
    let crossoverMonitorMode: N60CrossoverMonitorMode
    let crossoverSubGainLinear: Float
    let crossoverSubPolarityInverted: Bool
    let crossoverSectionCount: UInt32
    let mainsDetectedFrequencyHz: Float
    let mainsDetectionConfidence: Float
    let spectralDenoiserEnabled: Bool
    let spectralDenoiserTuning: N60DenoiserTuning
    let spectralDenoiserQuality: N60DenoiserQuality
    let denoiserFFTSize: UInt32
    let denoiserHopSize: UInt32
    let denoiserLatencyFrames: UInt32
    let denoiserProfileReady: Bool
    let denoiserCapturedProfile: Bool
    let denoiserCaptureActive: Bool
    let denoiserCaptureProgress: Float
    let denoiserEstimatedNoiseDBFS: Float
    let denoiserMeanSuppressionDB: Float
    let denoiserMaxSuppressionDB: Float
    let denoiserSpectralFramesProcessed: UInt64
    let deEsserEnabled: Bool
    let deEsserDynamicEQMode: Bool
    let deEsserFrequencyHz: Double
    let multibandCompressorEnabled: Bool
    let multibandLowMidFrequencyHz: Double
    let multibandMidHighFrequencyHz: Double
    let multibandTopology: N60CrossoverTopology
    let deEsserGainReductionDB: Float
    let multibandLowGainReductionDB: Float
    let multibandMidGainReductionDB: Float
    let multibandHighGainReductionDB: Float
    let loudnessShortTermLUFS: Float
    let loudnessMatchGainDB: Float
    let loudnessContourScale: Float
    let dialogueProgramLevelDBFS: Float
    let dialogueBandLevelDBFS: Float
    let dialogueGapDB: Float
    let dialogueVoiceConfidence: Float
    let dialogueBoostDB: Float
    let compressorEnabled: Bool
    let expanderEnabled: Bool
    let pauseGateEnabled: Bool
    let compressorGainReductionDB: Float
    let expanderAttenuationDB: Float
    let pauseGateGain: Float
    let pauseGateOpen: Bool
    let softClipperEnabled: Bool
    let limiterEnabled: Bool
    let oversamplingFactor: N60OversamplingFactor
    let effectiveOversamplingFactor: N60OversamplingFactor
    let inputTruePeakLinear: Float
    let outputTruePeakLinear: Float
    let limiterGainReductionDB: Float
    let gainRiderAttenuationDB: Float
    let sustainedLimiterGainReductionDB: Float
    let truePeakGuardActive: Bool
    let limiterSafetyClampSamples: UInt64
    let convolutionEnabled: Bool
    let convolutionProgramSlot: UInt32
    let convolutionProgramGeneration: UInt64
    let convolutionTapCount: UInt32
    let convolutionPartitionCount: UInt32
    let convolutionEngineLatencyFrames: UInt32
    let convolutionDeclaredLatencyFrames: UInt32
    let roomCorrectionEnabled: Bool
    let roomCorrectionProgramSlot: UInt32
    let roomCorrectionProgramGeneration: UInt64
    let roomCorrectionTapCount: UInt32
    let roomCorrectionPartitionCount: UInt32
    let roomCorrectionEngineLatencyFrames: UInt32
    let roomCorrectionDeclaredLatencyFrames: UInt32
    let speakerIREnabled: Bool
    let speakerIRProgramSlot: UInt32
    let speakerIRProgramGeneration: UInt64
    let speakerIRTapCount: UInt32
    let speakerIRPartitionCount: UInt32
    let speakerIREngineLatencyFrames: UInt32
    let speakerIRDeclaredLatencyFrames: UInt32
    let inputMeter: StereoMeterReading
    let postEQMeter: StereoMeterReading
    let outputMeter: StereoMeterReading

    init(_ diagnostics: N60RenderKernelDiagnostics) {
        renderedFrames = diagnostics.renderedFrames
        sanitizedNonFiniteSamples = diagnostics.sanitizedNonFiniteSamples
        flushedDenormalSamples = diagnostics.flushedDenormalSamples
        snapshotReadMisses = diagnostics.snapshotReadMisses
        convolutionProgramMisses = diagnostics.convolutionProgramMisses
        roomCorrectionProgramMisses = diagnostics.roomCorrectionProgramMisses
        speakerIRProgramMisses = diagnostics.speakerIRProgramMisses
        publishedGeneration = diagnostics.publishedGeneration
        latencyFrames = diagnostics.latencyFrames
        sampleRate = diagnostics.sampleRate
        channelCount = diagnostics.channelCount
        meteringEnabled = diagnostics.meteringEnabled
        bypassed = diagnostics.bypassed
        interChannelDelayMs = diagnostics.interChannelDelayMs
        interChannelAlignmentLatencyFrames = diagnostics.interChannelAlignmentLatencyFrames
        inputGainLinear = diagnostics.inputGainLinear
        headroomGainLinear = diagnostics.headroomGainLinear
        outputGainLinear = diagnostics.outputGainLinear
        balanceGainLeftLinear = diagnostics.balanceGainLeftLinear
        balanceGainRightLinear = diagnostics.balanceGainRightLinear
        eqBypassed = diagnostics.eqBypassed
        mixedPhaseEnabled = diagnostics.mixedPhaseEnabled
        mixedPhaseCorrectionSectionCount = diagnostics.mixedPhaseCorrectionSectionCount
        eqBandCount = diagnostics.eqBandCount
        eqLeftBandCount = diagnostics.eqLeftBandCount
        eqRightBandCount = diagnostics.eqRightBandCount
        crossoverEnabled = diagnostics.crossoverEnabled
        crossoverFrequencyHz = diagnostics.crossoverFrequencyHz
        crossoverTopology = diagnostics.crossoverTopology
        crossoverMonitorMode = diagnostics.crossoverMonitorMode
        crossoverSubGainLinear = diagnostics.crossoverSubGainLinear
        crossoverSubPolarityInverted = diagnostics.crossoverSubPolarityInverted
        crossoverSectionCount = diagnostics.crossoverSectionCount
        mainsDetectedFrequencyHz = diagnostics.mainsDetectedFrequencyHz
        mainsDetectionConfidence = diagnostics.mainsDetectionConfidence
        spectralDenoiserEnabled = diagnostics.spectralDenoiserEnabled
        spectralDenoiserTuning = diagnostics.spectralDenoiserTuning
        spectralDenoiserQuality = diagnostics.spectralDenoiserQuality
        denoiserFFTSize = diagnostics.denoiserFFTSize
        denoiserHopSize = diagnostics.denoiserHopSize
        denoiserLatencyFrames = diagnostics.denoiserLatencyFrames
        denoiserProfileReady = diagnostics.denoiserProfileReady
        denoiserCapturedProfile = diagnostics.denoiserCapturedProfile
        denoiserCaptureActive = diagnostics.denoiserCaptureActive
        denoiserCaptureProgress = diagnostics.denoiserCaptureProgress
        denoiserEstimatedNoiseDBFS = diagnostics.denoiserEstimatedNoiseDBFS
        denoiserMeanSuppressionDB = diagnostics.denoiserMeanSuppressionDB
        denoiserMaxSuppressionDB = diagnostics.denoiserMaxSuppressionDB
        denoiserSpectralFramesProcessed = diagnostics.denoiserSpectralFramesProcessed
        deEsserEnabled = diagnostics.deEsserEnabled
        deEsserDynamicEQMode = diagnostics.deEsserDynamicEQMode
        deEsserFrequencyHz = diagnostics.deEsserFrequencyHz
        multibandCompressorEnabled = diagnostics.multibandCompressorEnabled
        multibandLowMidFrequencyHz = diagnostics.multibandLowMidFrequencyHz
        multibandMidHighFrequencyHz = diagnostics.multibandMidHighFrequencyHz
        multibandTopology = diagnostics.multibandTopology
        deEsserGainReductionDB = diagnostics.deEsserGainReductionDB
        multibandLowGainReductionDB = diagnostics.multibandLowGainReductionDB
        multibandMidGainReductionDB = diagnostics.multibandMidGainReductionDB
        multibandHighGainReductionDB = diagnostics.multibandHighGainReductionDB
        loudnessShortTermLUFS = diagnostics.loudnessShortTermLUFS
        loudnessMatchGainDB = diagnostics.loudnessMatchGainDB
        loudnessContourScale = diagnostics.loudnessContourScale
        dialogueProgramLevelDBFS = diagnostics.dialogueProgramLevelDBFS
        dialogueBandLevelDBFS = diagnostics.dialogueBandLevelDBFS
        dialogueGapDB = diagnostics.dialogueGapDB
        dialogueVoiceConfidence = diagnostics.dialogueVoiceConfidence
        dialogueBoostDB = diagnostics.dialogueBoostDB
        compressorEnabled = diagnostics.compressorEnabled
        expanderEnabled = diagnostics.expanderEnabled
        pauseGateEnabled = diagnostics.pauseGateEnabled
        compressorGainReductionDB = diagnostics.compressorGainReductionDB
        expanderAttenuationDB = diagnostics.expanderAttenuationDB
        pauseGateGain = diagnostics.pauseGateGain
        pauseGateOpen = diagnostics.pauseGateOpen
        softClipperEnabled = diagnostics.softClipperEnabled
        limiterEnabled = diagnostics.limiterEnabled
        oversamplingFactor = diagnostics.oversamplingFactor
        effectiveOversamplingFactor = diagnostics.effectiveOversamplingFactor
        inputTruePeakLinear = diagnostics.inputTruePeakLinear
        outputTruePeakLinear = diagnostics.outputTruePeakLinear
        limiterGainReductionDB = diagnostics.limiterGainReductionDB
        gainRiderAttenuationDB = diagnostics.gainRiderAttenuationDB
        sustainedLimiterGainReductionDB = diagnostics.sustainedLimiterGainReductionDB
        truePeakGuardActive = diagnostics.truePeakGuardActive
        limiterSafetyClampSamples = diagnostics.limiterSafetyClampSamples
        convolutionEnabled = diagnostics.convolutionEnabled
        convolutionProgramSlot = diagnostics.convolutionProgramSlot
        convolutionProgramGeneration = diagnostics.convolutionProgramGeneration
        convolutionTapCount = diagnostics.convolutionTapCount
        convolutionPartitionCount = diagnostics.convolutionPartitionCount
        convolutionEngineLatencyFrames = diagnostics.convolutionEngineLatencyFrames
        convolutionDeclaredLatencyFrames = diagnostics.convolutionDeclaredLatencyFrames
        roomCorrectionEnabled = diagnostics.roomCorrectionEnabled
        roomCorrectionProgramSlot = diagnostics.roomCorrectionProgramSlot
        roomCorrectionProgramGeneration = diagnostics.roomCorrectionProgramGeneration
        roomCorrectionTapCount = diagnostics.roomCorrectionTapCount
        roomCorrectionPartitionCount = diagnostics.roomCorrectionPartitionCount
        roomCorrectionEngineLatencyFrames = diagnostics.roomCorrectionEngineLatencyFrames
        roomCorrectionDeclaredLatencyFrames = diagnostics.roomCorrectionDeclaredLatencyFrames
        speakerIREnabled = diagnostics.speakerIREnabled
        speakerIRProgramSlot = diagnostics.speakerIRProgramSlot
        speakerIRProgramGeneration = diagnostics.speakerIRProgramGeneration
        speakerIRTapCount = diagnostics.speakerIRTapCount
        speakerIRPartitionCount = diagnostics.speakerIRPartitionCount
        speakerIREngineLatencyFrames = diagnostics.speakerIREngineLatencyFrames
        speakerIRDeclaredLatencyFrames = diagnostics.speakerIRDeclaredLatencyFrames
        inputMeter = StereoMeterReading(diagnostics.inputMeter)
        postEQMeter = StereoMeterReading(diagnostics.postEQMeter)
        outputMeter = StereoMeterReading(diagnostics.outputMeter)
    }
}

struct AudioDiagnosticsSnapshot: Equatable, Sendable {
    let lifecycleState: AudioLifecycleState
    let selectedOutputUID: String?
    let selectedOutputName: String?
    let selectedOutputPresent: Bool
    let selectedOutputNominalSampleRate: Double?
    let discoveredOutputCount: Int
    let tapSampleRate: Double?
    let outputSampleRate: Double?
    let sessionTransportCounters: AudioTransportCounters
    let lifetimeTransportCounters: AudioTransportCounters
    let renderKernelDiagnostics: RenderKernelDiagnostics?
    let startupGateOpened: Bool?
    let startupGateTargetFrames: UInt32?
    let startupGateActivationFrames: UInt32?
    let sampleRateChangesHandled: UInt64
    let recoveryAttempts: UInt64
    let recoverySuccesses: UInt64
    let recoveryFailures: UInt64
    let lastErrorDescription: String?
}


enum ProductionTransportMeterKind: String, Equatable, Sendable {
    case semanticSpeakers
    case virtualSpeakers

    var displayName: String {
        switch self {
        case .semanticSpeakers: return "Semantic Speakers"
        case .virtualSpeakers: return "Virtual Speakers"
        }
    }
}

struct ProductionTransportChannelMeter: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let channelIndex: UInt32
    let peakLinear: Float
    let rmsLinear: Float
    let overRangeSamples: UInt64
}

struct ProductionRoomTreatmentDiagnostics: Equatable, Sendable {
    let authorized: Bool
    let armRequested: Bool
    let active: Bool
    let transitioning: Bool
    let faulted: Bool
    let treatmentMix: Float
    let treatmentSourceCount: UInt32
    let latencyFrames: UInt32
    let processedFrames: UInt64
    let protectionClampSamples: UInt64
    let integrationFailures: UInt64
}

struct ProductionTransportMeterSnapshot: Equatable, Sendable {
    let kind: ProductionTransportMeterKind
    let displayName: String
    let programLayoutName: String
    let sampleRate: Double
    let latencyFrames: UInt64
    let meteringEnabled: Bool
    let programChannels: [ProductionTransportChannelMeter]
    let physicalOutputs: [ProductionTransportChannelMeter]
    let inputTruePeakLinear: Float?
    let outputTruePeakLinear: Float?
    let roomTreatment: ProductionRoomTreatmentDiagnostics?
    let renderFailures: UInt64
    let outputWriteFailures: UInt64
}


// MARK: - PR101 full-system reliability acceptance

enum FullSystemReliabilityEvidenceAuthority: Int, CaseIterable, Equatable, Sendable {
    case deterministicSimulation = 0
    case macOSCI = 1
    case physicalHardware = 2
    case independentPhysicalReview = 3

    func satisfies(_ minimum: FullSystemReliabilityEvidenceAuthority) -> Bool {
        rawValue >= minimum.rawValue
    }
}

enum FullSystemReliabilityRequirementID: String, CaseIterable, Identifiable, Equatable, Sendable {
    case stereoTransport
    case semanticMultichannel
    case headphoneSpatialRuntime
    case audioUnitFaultContainment
    case roomTreatmentFailClosed
    case activeAcousticsFailClosed
    case lifecycleRecoveryModel
    case dspCorrectnessRegression
    case resourceStability
    case dropoutRecoveryStress
    case physicalDeviceRecovery
    case sleepWakeRecovery
    case prolongedThermalRuntime
    case speakerSafety
    case acousticAcceptance

    var id: String { rawValue }
}

struct FullSystemReliabilityRequirement: Identifiable, Equatable, Sendable {
    let id: FullSystemReliabilityRequirementID
    let title: String
    let minimumEvidence: FullSystemReliabilityEvidenceAuthority
    let hardwareOnly: Bool
    let detail: String
}

enum FullSystemReliabilityRequirementCatalog {
    static let standard: [FullSystemReliabilityRequirement] = [
        .init(
            id: .stereoTransport,
            title: "Stereo transport stability",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Sustained stereo render and transport tests must remain finite, bounded, and free of unexpected dropouts."
        ),
        .init(
            id: .semanticMultichannel,
            title: "Semantic multichannel stability",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "N-channel routing, DSP lanes, bass management, and semantic output simulation must survive sustained regression stress."
        ),
        .init(
            id: .headphoneSpatialRuntime,
            title: "Headphone and spatial runtime stability",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Correction, binaural rendering, and head-tracking state transitions must remain deterministic and finite."
        ),
        .init(
            id: .audioUnitFaultContainment,
            title: "Audio Unit fault containment",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Plug-in faults and transactional rack mutations must fail closed without corrupting the live graph."
        ),
        .init(
            id: .roomTreatmentFailClosed,
            title: "Room Treatment fail-closed runtime",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Room Treatment faults must preserve the latency-matched identity or zero-output safety boundary."
        ),
        .init(
            id: .activeAcousticsFailClosed,
            title: "Active Acoustics fail-closed boundary",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Synthetic or software-only evidence must never authorize speaker-connected feed-forward ANC."
        ),
        .init(
            id: .lifecycleRecoveryModel,
            title: "Lifecycle recovery model",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Deterministic route, rate, starvation, restart, and recovery-state simulations must converge without illegal lifecycle transitions."
        ),
        .init(
            id: .dspCorrectnessRegression,
            title: "DSP correctness regression",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "The cumulative DSP suite must retain numerical correctness across stereo, multichannel, headphone, and acoustic-processing paths."
        ),
        .init(
            id: .resourceStability,
            title: "CPU and memory stress instrumentation",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Automated stress runs must publish bounded resource telemetry with no crashes, assertion failures, or unbounded-growth signal."
        ),
        .init(
            id: .dropoutRecoveryStress,
            title: "Dropout and fault recovery stress",
            minimumEvidence: .macOSCI,
            hardwareOnly: false,
            detail: "Injected transport faults may occur, but every injected event must recover without an unexpected dropout, non-finite sample, or unrecovered fault."
        ),
        .init(
            id: .physicalDeviceRecovery,
            title: "Real device unplug / replug recovery",
            minimumEvidence: .physicalHardware,
            hardwareOnly: true,
            detail: "Physical output and input device removal/reappearance must be measured on a real Mac and real devices."
        ),
        .init(
            id: .sleepWakeRecovery,
            title: "Real sleep / wake recovery",
            minimumEvidence: .physicalHardware,
            hardwareOnly: true,
            detail: "System sleep/wake and device-clock reacquisition require real macOS hardware evidence."
        ),
        .init(
            id: .prolongedThermalRuntime,
            title: "Prolonged thermal and runtime stability",
            minimumEvidence: .physicalHardware,
            hardwareOnly: true,
            detail: "Long-duration CPU, memory, thermal, and dropout behavior must be observed on production-class hardware."
        ),
        .init(
            id: .speakerSafety,
            title: "Speaker and emergency-mute safety",
            minimumEvidence: .independentPhysicalReview,
            hardwareOnly: true,
            detail: "Real output levels, protection behavior, and emergency shutdown require independently reviewed physical evidence."
        ),
        .init(
            id: .acousticAcceptance,
            title: "Final acoustic acceptance",
            minimumEvidence: .independentPhysicalReview,
            hardwareOnly: true,
            detail: "Measured room, headphone, speaker, treatment, and Active Acoustics performance must be independently reviewed on physical systems."
        ),
    ]

    static var remoteRequirementIDs: Set<FullSystemReliabilityRequirementID> {
        Set(standard.filter { !$0.hardwareOnly }.map(\.id))
    }

    static var hardwareRequirementIDs: Set<FullSystemReliabilityRequirementID> {
        Set(standard.filter(\.hardwareOnly).map(\.id))
    }
}

struct FullSystemReliabilityObservation: Equatable, Sendable {
    let requirementID: FullSystemReliabilityRequirementID
    let runID: UUID
    let evidence: FullSystemReliabilityEvidenceAuthority
    let completedIterations: Int
    let injectedFaults: UInt64
    let unexpectedDropouts: UInt64
    let nonFiniteSamples: UInt64
    let unrecoveredFaults: UInt64
    let crashes: UInt64
    let residentMemoryGrowthBytes: Int64?
    let peakProcessCPUPercent: Double?
    let peakCallbackUtilization: Double?

    init(
        requirementID: FullSystemReliabilityRequirementID,
        runID: UUID = UUID(),
        evidence: FullSystemReliabilityEvidenceAuthority,
        completedIterations: Int,
        injectedFaults: UInt64 = 0,
        unexpectedDropouts: UInt64 = 0,
        nonFiniteSamples: UInt64 = 0,
        unrecoveredFaults: UInt64 = 0,
        crashes: UInt64 = 0,
        residentMemoryGrowthBytes: Int64? = nil,
        peakProcessCPUPercent: Double? = nil,
        peakCallbackUtilization: Double? = nil
    ) {
        self.requirementID = requirementID
        self.runID = runID
        self.evidence = evidence
        self.completedIterations = completedIterations
        self.injectedFaults = injectedFaults
        self.unexpectedDropouts = unexpectedDropouts
        self.nonFiniteSamples = nonFiniteSamples
        self.unrecoveredFaults = unrecoveredFaults
        self.crashes = crashes
        self.residentMemoryGrowthBytes = residentMemoryGrowthBytes
        self.peakProcessCPUPercent = peakProcessCPUPercent
        self.peakCallbackUtilization = peakCallbackUtilization
    }

    var hasFailureSignal: Bool {
        unexpectedDropouts > 0
            || nonFiniteSamples > 0
            || unrecoveredFaults > 0
            || crashes > 0
    }

    var isStructurallyValid: Bool {
        guard completedIterations > 0 else { return false }
        if let residentMemoryGrowthBytes,
           residentMemoryGrowthBytes < Int64.min / 2 {
            return false
        }
        if let peakProcessCPUPercent,
           !peakProcessCPUPercent.isFinite || peakProcessCPUPercent < 0 {
            return false
        }
        if let peakCallbackUtilization,
           !peakCallbackUtilization.isFinite || peakCallbackUtilization < 0 {
            return false
        }
        return true
    }
}

enum FullSystemReliabilityRequirementStatus: String, Equatable, Sendable {
    case passed
    case failed
    case missing
    case insufficientEvidence
    case hardwareRequired
}

struct FullSystemReliabilityAcceptanceItem: Equatable, Sendable {
    let requirement: FullSystemReliabilityRequirement
    let status: FullSystemReliabilityRequirementStatus
    let observation: FullSystemReliabilityObservation?
}

struct FullSystemReliabilityAcceptanceReport: Equatable, Sendable {
    let items: [FullSystemReliabilityAcceptanceItem]

    var remoteSoftwareAccepted: Bool {
        items.filter { !$0.requirement.hardwareOnly }
            .allSatisfy { $0.status == .passed }
    }

    var physicalAcceptanceComplete: Bool {
        items.filter(\.requirement.hardwareOnly)
            .allSatisfy { $0.status == .passed }
    }

    var releaseAcceptanceComplete: Bool {
        remoteSoftwareAccepted && physicalAcceptanceComplete
    }

    var hardwarePendingCount: Int {
        items.filter {
            $0.requirement.hardwareOnly && $0.status != .passed
        }.count
    }

    var failedCount: Int {
        items.filter { $0.status == .failed }.count
    }
}

enum FullSystemReliabilityAcceptanceError: Error, Equatable, Sendable {
    case duplicateRunID(UUID)
    case invalidObservation(FullSystemReliabilityRequirementID)
}

struct FullSystemReliabilityAcceptanceEvaluator: Sendable {
    func review(
        observations: [FullSystemReliabilityObservation]
    ) throws -> FullSystemReliabilityAcceptanceReport {
        var runIDs = Set<UUID>()
        for observation in observations {
            guard runIDs.insert(observation.runID).inserted else {
                throw FullSystemReliabilityAcceptanceError
                    .duplicateRunID(observation.runID)
            }
            guard observation.isStructurallyValid else {
                throw FullSystemReliabilityAcceptanceError
                    .invalidObservation(observation.requirementID)
            }
        }

        let items = FullSystemReliabilityRequirementCatalog.standard.map {
            requirement -> FullSystemReliabilityAcceptanceItem in
            let candidates = observations.filter {
                $0.requirementID == requirement.id
            }
            guard !candidates.isEmpty else {
                return .init(
                    requirement: requirement,
                    status: requirement.hardwareOnly
                        ? .hardwareRequired
                        : .missing,
                    observation: nil
                )
            }

            let strongest = candidates.max {
                if $0.evidence.rawValue == $1.evidence.rawValue {
                    return $0.completedIterations < $1.completedIterations
                }
                return $0.evidence.rawValue < $1.evidence.rawValue
            }!

            guard strongest.evidence.satisfies(requirement.minimumEvidence) else {
                return .init(
                    requirement: requirement,
                    status: requirement.hardwareOnly
                        ? .hardwareRequired
                        : .insufficientEvidence,
                    observation: strongest
                )
            }

            return .init(
                requirement: requirement,
                status: strongest.hasFailureSignal ? .failed : .passed,
                observation: strongest
            )
        }

        return FullSystemReliabilityAcceptanceReport(items: items)
    }
}
