import AudioToolbox
import CoreAudio
import Darwin
import Foundation

enum LiveNChannelTransportError: Error, Equatable, LocalizedError {
    case incompatibleProgramChannelCount(tap: UInt32, profile: UInt32)
    case inputChannelLayoutUnavailable(channelCount: UInt32)
    case inputChannelLayoutMismatch
    case realtimeBridgeAllocationFailed
    case renderGraphInvalid
    case ioProcUnavailable(role: String)
    case outputBufferExceedsBridgeCapacity(bufferFrames: UInt32, capacityFrames: UInt32)
    case captureBufferSizeMismatch(capture: UInt32, output: UInt32)
    case aggregateDeviceNotReady
    case unsupportedActiveDSP(String)
    case globalBypassUnsupported
    case roomTreatmentPermitMismatch
    case roomTreatmentSourceUnavailable(String)
    case roomTreatmentConfigurationFailed
    case speakerOptimizerFIRConfigurationFailed
    case configurationChangeRequiresRestart
    /// E6 S9a: stereo-class DSP is active and the unified graph cannot reproduce the setup, so it never starts on a
    /// path that would drop that DSP.
    case unifiedGraphRejected(UnifiedGraphFallbackReason)
    /// E6 S9b: a live edit was refused by the running graph (for example the CPU budget for the fade); the
    /// running graph and the engine state are unchanged.
    case graphRepublishRefused(String)
    /// E8 S4: the routing matrix cannot run on this session, with the reason (legacy kernel, flag off, a sub source
    /// with bass management off, a routing the compiler rejects).
    case routingRefused(String)
    /// E8 A3: the profile has 5 to 8 subwoofers and the session would run on the legacy render kernel, which drives
    /// at most 4. Nothing is truncated; the stored profile is kept.
    case tooManySubwoofersForLegacyKernel(Int)

    var errorDescription: String? {
        switch self {
        case .tooManySubwoofersForLegacyKernel(let count):
            return "The legacy render kernel drives at most \(SubwooferLimit.legacyKernel) subwoofers; this profile has \(count). Turn on the unified graph to use more."
        case .routingRefused(let reason):
            return "The routing matrix cannot start: \(reason)"
        case .incompatibleProgramChannelCount(let tap, let profile):
            return "The captured program has \(tap) channels, but the enabled Output Device Profile expects \(profile)."
        case .inputChannelLayoutUnavailable(let channelCount):
            return "Core Audio did not expose a resolvable semantic channel layout for the \(channelCount)-channel captured program. Multichannel order is never guessed."
        case .inputChannelLayoutMismatch:
            return "The captured Core Audio channel roles do not match the enabled Output Device Profile."
        case .realtimeBridgeAllocationFailed:
            return "Unable to allocate the preallocated live N-channel bridge."
        case .renderGraphInvalid:
            return "Unable to compile the live N-channel render graph."
        case .ioProcUnavailable(let role):
            return "Core Audio created the N-channel \(role) IOProc without returning a usable callback identifier."
        case .outputBufferExceedsBridgeCapacity(let bufferFrames, let capacityFrames):
            return "N-channel startup requires \(bufferFrames) buffered frames but bridge capacity is \(capacityFrames)."
        case .captureBufferSizeMismatch(let capture, let output):
            return "N-channel tap callback quantum is \(capture) frames; expected \(output) to match the physical output."
        case .aggregateDeviceNotReady:
            return "Core Audio created the private N-channel aggregate device but it did not become ready for IO."
        case .unsupportedActiveDSP(let feature):
            return "Live N-channel activation currently requires \(feature) to be bypassed or disabled. Stop processing and use the supported semantic transport subset."
        case .globalBypassUnsupported:
            return "Global DSP Bypass is not yet available for multichannel or Virtual Speakers playback. Turn Bypass off before starting processing."
        case .roomTreatmentPermitMismatch:
            return "The room-treatment activation permit does not match the prepared FIR program or current output sample rate."
        case .roomTreatmentSourceUnavailable(let source):
            return "Room-treatment source \(source) is not mapped to a usable physical output in the active Output Device Profile."
        case .roomTreatmentConfigurationFailed:
            return "The hardware-gated room-treatment runtime could not be prepared."
        case .speakerOptimizerFIRConfigurationFailed:
            return "The persisted Speaker Optimizer FIR could not be bound to the live semantic program graph with its required latency/headroom contract."
        case .configurationChangeRequiresRestart:
            return "Stop N-channel processing before changing DSP or Output Device Profile configuration."
        case .graphRepublishRefused(let detail):
            return "The running graph refused the change and keeps rendering as before (\(detail))."
        case .unifiedGraphRejected(let reason):
            return "The active stereo DSP cannot run on this multichannel or Virtual Speakers setup: \(reason.displayText)."
        }
    }
}

/// Control-plane compiler for PR61's immutable live render graph. The first
/// production activation intentionally supports only processing that already has
/// a semantic N-channel implementation: global gain, PR54 lanes, and PR55 bass
/// management. Stereo-only stages fail closed in AudioIOEngine before this graph
/// is created rather than being silently omitted.
struct LiveMIMORoomTreatmentPreparation: Equatable, Sendable {
    let firProgram: MIMORoomTreatmentFIRProgram
    let permit: MIMORoomTreatmentActivationPermit
    let acceptedProfile: OutputDeviceProfileConfiguration
    let acceptedSelectedOutputUID: String
    let transitionConfiguration: MIMORoomTreatmentTransitionConfiguration

    init(
        firProgram: MIMORoomTreatmentFIRProgram,
        permit: MIMORoomTreatmentActivationPermit,
        acceptedProfile: OutputDeviceProfileConfiguration,
        acceptedSelectedOutputUID: String,
        transitionConfiguration: MIMORoomTreatmentTransitionConfiguration = .conservative
    ) {
        self.firProgram = firProgram
        self.permit = permit
        self.acceptedProfile = acceptedProfile
        self.acceptedSelectedOutputUID = acceptedSelectedOutputUID
        self.transitionConfiguration = transitionConfiguration
    }

    func validate(sampleRate: Double) throws {
        guard sampleRate.isFinite,
              abs(sampleRate - firProgram.sampleRate) < 0.5,
              permit.sampleRate == firProgram.sampleRate,
              permit.sources == firProgram.sources,
              permit.tapCount == firProgram.tapCount,
              permit.declaredLatencyFrames == firProgram.declaredLatencyFrames,
              permit.engineLatencyFrames == firProgram.engineLatencyFrames,
              permit.totalLatencyFrames == firProgram.totalLatencyFrames,
              transitionConfiguration.frameCounts(sampleRate: sampleRate) != nil else {
            throw LiveNChannelTransportError.roomTreatmentPermitMismatch
        }
    }

    func physicalChannels(
        routePlan: LiveNChannelOutputRoutePlan
    ) throws -> [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(firProgram.sources.count)
        for source in firProgram.sources {
            let physical: UInt32
            switch source {
            case .speaker(let role):
                guard let programIndex = routePlan.programLayout.roles.firstIndex(of: role),
                      programIndex < routePlan.programPhysicalChannels.count else {
                    throw LiveNChannelTransportError.roomTreatmentSourceUnavailable(
                        source.displayName
                    )
                }
                physical = routePlan.programPhysicalChannels[programIndex]
            case .subwoofer(let index):
                guard Int(index) < routePlan.subwooferPhysicalChannels.count else {
                    throw LiveNChannelTransportError.roomTreatmentSourceUnavailable(
                        source.displayName
                    )
                }
                physical = routePlan.subwooferPhysicalChannels[Int(index)]
            }
            guard physical != UInt32.max,
                  physical < routePlan.physicalChannelCount else {
                throw LiveNChannelTransportError.roomTreatmentSourceUnavailable(
                    source.displayName
                )
            }
            result.append(physical)
        }
        guard Set(result).count == result.count else {
            throw LiveNChannelTransportError.roomTreatmentConfigurationFailed
        }
        return result
    }
}

enum LiveNChannelRenderGraphCompiler {
    /// Playback-side LFE in-band gain (ITU-R BS.775 / Dolby / DTS convention):
    /// the LFE channel is carried 10 dB below the main channels and must be
    /// restored on playback.
    static let lfeInBandGainDB = 10.0
    /// Band limit applied to the native LFE program channel when bass
    /// management owns the subwoofer feed.
    static let lfeLowPassHz = 120.0

    static func makeGraph(
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration
    ) throws -> N60LiveNChannelRenderGraph {
        // E8 S4: a routed plan renders through the graph only; the legacy core gets silence. Its bass management
        // is the graph's, so the legacy snapshot is never built for it.
        var bassManagementConfiguration = bassManagementConfiguration
        if routePlan.isRouted { bassManagementConfiguration.enabled = false }
        // E8 A3: 5 to 8 subs are graph-only. The legacy bass-management snapshot holds at most 4, so it is not built;
        // the session requires the graph (the engine refuses the legacy kernel by name before this point).
        if Int(routePlan.subwooferCount) > SubwooferLimit.legacyKernel { bassManagementConfiguration.enabled = false }
        let layout = routePlan.programLayout.realtimeLayout
        var lanes = N60ProgramLaneGraphSnapshotMakeUnity(sampleRate, layout)

        let optimizerFIRHeadroomDB =
            routePlan.speakerOptimizerFIR?.requiredHeadroomDB ?? 0
        guard optimizerFIRHeadroomDB.isFinite,
              (0...SpeakerOptimizerFIRDeploymentConfiguration
                    .maximumHeadroomDB)
                .contains(optimizerFIRHeadroomDB) else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
        let combinedGainDB = gainConfiguration.inputPreampDB
            + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
            - optimizerFIRHeadroomDB
        let combinedGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
        guard combinedGain.isFinite, combinedGain >= 0, combinedGain <= 16 else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
        let programRoles = routePlan.programLayout.roles
        for channel in 0..<layout.channelCount {
            let role = programRoles[Int(channel)]
            let calibration = routePlan.speakerCalibrations[role]
            // With bass management enabled, the LFE in-band gain is applied by
            // the LFE→sub matrix; without it, the LFE lane carries the gain to
            // its directly mapped output. Never both.
            let lfeInBandGainDB = role == .lowFrequencyEffects
                && !bassManagementConfiguration.enabled
                ? Self.lfeInBandGainDB
                : 0
            let calibratedGain = combinedGain * DSPGainConfiguration.linearGain(
                forDB: (calibration?.trimDB ?? 0) + lfeInBandGainDB
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
            let calibrationBandCount = calibration?.eqBands.count ?? 0
            if let optimizerBands = routePlan.speakerOptimizerPEQ[role] {
                guard calibrationBandCount + optimizerBands.count
                        <= Int(N60_PROGRAM_LANE_MAX_EQ_SECTIONS) else {
                    throw LiveNChannelTransportError.renderGraphInvalid
                }
                for (offset, band) in optimizerBands.enumerated() {
                    try band.validate(sampleRate: sampleRate)
                    guard N60ProgramLaneGraphSetEQBand(
                        &lanes,
                        channel,
                        UInt32(calibrationBandCount + offset),
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

        let outputMap = try routePlan.makeRealtimeOutputMap()
        var bass = N60MultichannelBassManagementSnapshot()
        if bassManagementConfiguration.enabled {
            bass = N60MultichannelBassManagementSnapshotMake(
                sampleRate,
                layout,
                routePlan.subwooferCount
            )
            let routeGain = 1.0 / Float(max(routePlan.subwooferCount, 1))
            guard N60MultichannelBassManagementSetLFEGain(
                    &bass,
                    DSPGainConfiguration.linearGain(forDB: Self.lfeInBandGainDB)
                  ),
                  N60MultichannelBassManagementSetLFELowPass(
                    &bass,
                    Self.lfeLowPassHz,
                    bassManagementConfiguration.topology.cType,
                    true
                  ) else {
                throw LiveNChannelTransportError.renderGraphInvalid
            }
            for channel in 0..<layout.channelCount {
                if programRoles[Int(channel)] == .lowFrequencyEffects {
                    continue
                }
                guard N60MultichannelBassManagementSetSourceCrossover(
                    &bass,
                    channel,
                    bassManagementConfiguration.frequencyHz,
                    bassManagementConfiguration.topology.cType,
                    true
                ) else {
                    throw LiveNChannelTransportError.renderGraphInvalid
                }
                for sub in 0..<routePlan.subwooferCount {
                    guard N60MultichannelBassManagementSetRedirectedBassRoute(
                        &bass,
                        channel,
                        sub,
                        routeGain
                    ) else {
                        throw LiveNChannelTransportError.renderGraphInvalid
                    }
                }
            }
            for sub in 0..<routePlan.subwooferCount {
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
            guard N60MultichannelBassManagementSnapshotIsValid(&bass) else {
                throw LiveNChannelTransportError.renderGraphInvalid
            }
        }

        var graph = N60LiveNChannelRenderGraph()
        guard N60LiveNChannelRenderGraphMake(
            sampleRate,
            layout,
            lanes,
            bassManagementConfiguration.enabled,
            bass,
            outputMap,
            &graph
        ) else {
            throw LiveNChannelTransportError.renderGraphInvalid
        }
        return graph
    }
}

/// Opt-in PR63 Core Audio owner for PR61's semantic live bridge. It deliberately
/// lives beside, rather than inside, CoreAudioTransportSession so the mature
/// stereo session remains untouched and is still the fallback/default path.
final class CoreAudioNChannelTransportSession {
    static let bridgeCapacityFrames: UInt32 = RateCapacity.fixedRingFrames
    /// Largest Core Audio buffer the graph path renders in one block.
    static let graphMaxBlockFrames: UInt32 = RateCapacity.largestDeviceBufferFrames

    let selectedOutput: AudioOutputDevice
    let routePlan: LiveNChannelOutputRoutePlan
    private(set) var tapFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var outputFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var startupGateTargetFrames: UInt32 = 0
    private(set) var startupGateActivationFrames: UInt32 = 0

    var startupGateOpened: Bool {
        guard let bridge else { return false }
        return N60LiveNChannelBridgeGetSnapshot(bridge).outputGateOpen
    }

    private var bridge: UnsafeMutablePointer<N60LiveNChannelBridge>?
    /// E6 S8b2b: the libn60core graph rendering this session, when `e6.unified-graph` is on and
    /// the setup is one the core reproduces. Created before IO starts and released only after
    /// the bridge is destroyed (see `stop`), so the callback never sees it freed.
    /// E27 S3b: set by the engine while it republishes an EQ change (bypass, A/B, audition), so the
    /// rebuild crossfade uses the linear law. Every other republish keeps the equal-power law.
    var linearFadeForEQRepublish = false
    private var unifiedGraphHost: UnifiedGraphHost?
    /// Why the legacy render core kept this session although the graph was requested; nil when
    /// the graph renders it or was not requested.
    private(set) var unifiedGraphFallbackReason: UnifiedGraphFallbackReason?
    private var audioUnitRack: AudioUnitLiveRackSwitchboard?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var captureIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var isCaptureStarted = false
    private var isOutputStarted = false
    private var stopped = false
    /// E26 S7b2: the host-fed Quiet Zone's actuators and the last configuration published for this graph, under
    /// `ancLock`. nil unless the graph carries the ANC lane feed. `republishGraph` re-applies the actuators, so
    /// engine edits that rebuild the configuration keep the appended lanes, the authorisation and the user volume.
    private let ancLock = NSLock()
    private let ancPublishLock = NSLock()
    /// Graph-guard trips already acted on by `pollQuietZoneGuards` (under `ancLock`).
    private var ancSeenGuardTrips: UInt64 = 0
    private var hostedAnc: UnifiedGraphAncActuators?
    private var hostedConfiguration: UnifiedGraphConfiguration?
    /// E19 S6: the staged MIMO treatment stage the graph carries and the last configuration published (both under
    /// `ancLock`). `republishGraph` re-applies the stage, so engine edits that rebuild the configuration keep it and its
    /// live arm words; only `applyMIMOStage` changes them.
    private var mimoStage: UnifiedGraphMIMOStage?
    private var mimoReadbackHold: n60_mimo_readback?
    private var lastGraphConfiguration: UnifiedGraphConfiguration?
    private var ancManualTrips: UInt64 = 0
    /// A revoke disarmed the feed but its graph publish failed, so the record still says authorised (under `ancLock`).
    /// The next authorisation must then arm the feed itself instead of returning early (G27).
    private var ancFeedNeedsArm = false
    /// Serialises whole `setQuietZoneInjectAuthorised` calls (G31), so interleaved authorise and revoke calls cannot
    /// leave the feed and the graph record disagreeing. Lock order: `ancAuthoriseLock`, `ancPublishLock`, `ancLock`.
    private let ancAuthoriseLock = NSLock()
#if DEBUG
    /// Test seam (G27): the next `republishGraph` throws this once. Compiled out of release builds (G32).
    var testingRepublishFailure: LiveNChannelTransportError?
#endif

    init(
        selectedOutput: AudioOutputDevice,
        routePlan: LiveNChannelOutputRoutePlan,
        renderGraph: N60LiveNChannelRenderGraph,
        outputGain: Float,
        roomTreatment: LiveMIMORoomTreatmentPreparation? = nil,
        audioUnitRack: AudioUnitLiveRackSwitchboard? = nil,
        unifiedGraphConfiguration: UnifiedGraphConfiguration? = nil,
        unifiedGraphIneligibility: UnifiedGraphFallbackReason? = nil,
        unifiedGraphRequired: Bool = false,
        ancFeedSplitter: N60SpeakerBusSplitterSnapshot? = nil
    ) throws {
        self.selectedOutput = selectedOutput
        self.routePlan = routePlan
        self.audioUnitRack = audioUnitRack

        do {
            let processObject = try Self.currentProcessObjectID()
            let description = CATapDescription(
                excludingProcesses: [processObject],
                deviceUID: selectedOutput.uid,
                stream: 0
            )
            description.name = "Notch Sixty Semantic Program"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            description.isMixdown = false
            description.isMono = false

            try Self.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "create semantic process tap"
            )

            let tapASBD = try Self.readStreamFormat(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read semantic tap format"
            )
            let outputASBD = try Self.readStreamFormat(
                objectID: selectedOutput.deviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput,
                operation: "read N-channel output stream format"
            )
            tapFormat = AudioStreamFormatDescription(tapASBD)
            outputFormat = AudioStreamFormatDescription(outputASBD)

            guard tapFormat.isSupportedFloat32TransportFormat else {
                throw CoreAudioTransportError.unsupportedFormat(role: "semantic tap", format: tapFormat)
            }
            guard outputFormat.isSupportedFloat32TransportFormat else {
                throw CoreAudioTransportError.unsupportedFormat(role: "N-channel output reference", format: outputFormat)
            }
            let expectedChannels = renderGraph.programLayout.channelCount
            guard tapFormat.channelCount == expectedChannels else {
                throw LiveNChannelTransportError.incompatibleProgramChannelCount(
                    tap: tapFormat.channelCount,
                    profile: expectedChannels
                )
            }
            let adaptiveSampleRateRequired = abs(tapFormat.sampleRate - outputFormat.sampleRate) >= 0.5
            if adaptiveSampleRateRequired, routePlan.usesMultiplePhysicalDevices {
                // The existing semantic multi-device output uses one HAL
                // Aggregate Device as its output clock domain. PR71 activates
                // adaptive SRC for the independent tap -> physical-output path;
                // multi-device aggregate-clock mismatch remains fail-closed.
                throw CoreAudioTransportError.sampleRateMismatch(
                    tap: tapFormat.sampleRate,
                    output: outputFormat.sampleRate
                )
            }

            let descriptions = try Self.resolveInputChannelDescriptions(
                deviceID: selectedOutput.deviceID,
                channelCount: tapFormat.channelCount
            )
            var inputMap = N60ProgramInputMap()
            let mapped = descriptions.withUnsafeBufferPointer { buffer in
                N60ProgramInputMapCompile(
                    buffer.baseAddress!,
                    UInt32(buffer.count),
                    renderGraph.programLayout,
                    &inputMap
                )
            }
            guard mapped else {
                throw LiveNChannelTransportError.inputChannelLayoutMismatch
            }

            let outputBufferFrames = try Self.readUInt32Property(
                objectID: selectedOutput.deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read N-channel physical output buffer size"
            )
            let gatePolicy = AudioStartupGatePolicy(
                outputBufferFrames: outputBufferFrames,
                sampleRate: outputFormat.sampleRate
            )
            var gateMinimumFrames = gatePolicy.activationBufferedFrames
            var adaptiveTargetInputFrames: UInt32?
            if adaptiveSampleRateRequired {
                let ratio = tapFormat.sampleRate / outputFormat.sampleRate
                let inputFramesPerOutputBuffer = UInt32(
                    min(
                        ceil(Double(outputBufferFrames) * ratio),
                        Double(UInt32.max)
                    )
                )
                let lookahead = UInt32(N60_ADAPTIVE_SRC_DEFAULT_TAPS / 2)
                let target64 = max(
                    UInt64(256),
                    UInt64(inputFramesPerOutputBuffer) * 3 + UInt64(lookahead) * 2
                )
                let activation64 = target64
                    + UInt64(inputFramesPerOutputBuffer)
                    + UInt64(lookahead)
                guard target64 < UInt64(Self.bridgeCapacityFrames),
                      activation64 <= UInt64(Self.bridgeCapacityFrames) else {
                    throw LiveNChannelTransportError.outputBufferExceedsBridgeCapacity(
                        bufferFrames: UInt32(min(activation64, UInt64(UInt32.max))),
                        capacityFrames: Self.bridgeCapacityFrames
                    )
                }
                adaptiveTargetInputFrames = UInt32(target64)
                gateMinimumFrames = UInt32(activation64)
                startupGateTargetFrames = UInt32(target64)
                startupGateActivationFrames = gateMinimumFrames
            } else {
                guard gatePolicy.activationBufferedFrames <= Self.bridgeCapacityFrames else {
                    throw LiveNChannelTransportError.outputBufferExceedsBridgeCapacity(
                        bufferFrames: gatePolicy.activationBufferedFrames,
                        capacityFrames: Self.bridgeCapacityFrames
                    )
                }
                startupGateTargetFrames = gatePolicy.steadyStateTargetFrames
                startupGateActivationFrames = gatePolicy.activationBufferedFrames
            }

            guard let newBridge = N60LiveNChannelBridgeCreate(
                Self.bridgeCapacityFrames,
                inputMap,
                renderGraph,
                gateMinimumFrames,
                gatePolicy.fadeInFrames
            ) else {
                throw LiveNChannelTransportError.realtimeBridgeAllocationFailed
            }
            if let optimizerFIR = routePlan.speakerOptimizerFIR {
                do {
                    try optimizerFIR.validateLiveSampleRate(
                        outputFormat.sampleRate
                    )
                    let preparation =
                        try optimizerFIR.makeRuntimePreparation(
                            programLayout: routePlan.programLayout
                        )
                    let taps = preparation.flattenedTaps
                    let configured = taps.withUnsafeBufferPointer {
                        tapBuffer in
                        guard let base = tapBuffer.baseAddress else {
                            return false
                        }
                        return N60LiveNChannelBridgeConfigureProgramFIR(
                            newBridge,
                            preparation.activeChannelMask,
                            base,
                            preparation.tapCount,
                            preparation.declaredGroupDelayFrames
                        )
                    }
                    guard configured else {
                        throw LiveNChannelTransportError
                            .speakerOptimizerFIRConfigurationFailed
                    }
                } catch {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    if let error = error as? LiveNChannelTransportError {
                        throw error
                    }
                    throw LiveNChannelTransportError
                        .speakerOptimizerFIRConfigurationFailed
                }
            }
            if let adaptiveTargetInputFrames {
                guard N60LiveNChannelBridgeConfigureAdaptiveSampleRate(
                    newBridge,
                    tapFormat.sampleRate,
                    outputFormat.sampleRate,
                    adaptiveTargetInputFrames
                ) else {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    throw CoreAudioTransportError.adaptiveSampleRateConfigurationFailed(
                        tap: tapFormat.sampleRate,
                        output: outputFormat.sampleRate
                    )
                }
            }
            if let audioUnitRack {
                guard abs(audioUnitRack.format.sampleRate - outputFormat.sampleRate) < 0.5,
                      audioUnitRack.format.channelCount
                        == Int(renderGraph.programLayout.channelCount),
                      outputBufferFrames
                        <= UInt32(audioUnitRack.format.maximumFramesPerSlice),
                      N60LiveNChannelBridgeConfigureAudioUnitRack(
                        newBridge,
                        audioUnitRack.processor
                      ) else {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    throw CoreAudioTransportError.audioUnitRackConfigurationFailed
                }
            }
            if let roomTreatment {
                try roomTreatment.validate(sampleRate: outputFormat.sampleRate)
                let physicalChannels = try roomTreatment.physicalChannels(
                    routePlan: routePlan
                )
                guard let fades = roomTreatment.transitionConfiguration.frameCounts(
                    sampleRate: outputFormat.sampleRate
                ) else {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    throw LiveNChannelTransportError.roomTreatmentPermitMismatch
                }
                let taps = roomTreatment.firProgram.taps
                let configured = taps.withUnsafeBufferPointer { tapBuffer in
                    physicalChannels.withUnsafeBufferPointer { physicalBuffer in
                        N60LiveNChannelBridgeConfigureRoomTreatment(
                            newBridge,
                            UInt32(physicalChannels.count),
                            physicalBuffer.baseAddress!,
                            tapBuffer.baseAddress!,
                            UInt32(roomTreatment.firProgram.tapCount),
                            UInt32(roomTreatment.firProgram.declaredLatencyFrames),
                            fades.armFadeFrames,
                            fades.faultFadeFrames
                        )
                    }
                }
                guard configured else {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    throw LiveNChannelTransportError.roomTreatmentConfigurationFailed
                }
                // Authorization is granted only after validating the PR76 permit
                // against this exact FIR, source list, sample rate and route.
                N60LiveNChannelBridgeSetRoomTreatmentAuthorized(
                    newBridge,
                    true
                )
            }
            // Any reason the core cannot take the session leaves the legacy render core in place,
            // and is recorded so diagnostics can say why.
            if let configuration = unifiedGraphConfiguration {
                switch Self.makeUnifiedGraph(
                    configuration: configuration,
                    bridge: newBridge,
                    sampleRate: outputFormat.sampleRate,
                    laneCount: Int(renderGraph.programLayout.channelCount),
                    outputBufferFrames: outputBufferFrames,
                    ancFeedSplitter: ancFeedSplitter
                ) {
                case .success(let host):
                    unifiedGraphHost = host
                    hostedAnc = configuration.ancActuators?.hostFed == true ? configuration.ancActuators : nil
                    hostedConfiguration = hostedAnc == nil ? nil : configuration
                    mimoStage = configuration.mimo
                    lastGraphConfiguration = configuration
                case .failure(let reason):
                    if unifiedGraphRequired {
                        N60LiveNChannelBridgeDestroy(newBridge)
                        throw LiveNChannelTransportError.unifiedGraphRejected(reason)
                    }
                    unifiedGraphFallbackReason = reason
                }
            } else {
                if unifiedGraphRequired {
                    N60LiveNChannelBridgeDestroy(newBridge)
                    throw LiveNChannelTransportError.unifiedGraphRejected(unifiedGraphIneligibility ?? .specRejected)
                }
                unifiedGraphFallbackReason = unifiedGraphIneligibility
            }
            bridge = newBridge
            installLoudnessWorker(newBridge, sampleRate: outputFormat.sampleRate)
            registerHostTimeSink(newBridge, host: unifiedGraphHost)
            if hostedAnc != nil, let feed = unifiedGraphHost?.retainedResource as? ProfileAncFeed {
                N60AncLaneFeedSetProgrammeScale(feed.pointer, max(0, outputGain))
            }
            // With a host-fed Quiet Zone the user's volume sits in the graph (OUTPUT_GAIN), so the anti-noise ignores it;
            // the bridge gain stays at unity and only carries the start and stop fades.
            N60LiveNChannelBridgeSetOutputGain(newBridge, hostedAnc == nil ? outputGain : 1)

            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]
            var aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: routePlan.usesMultiplePhysicalDevices
                    ? "Notch Sixty Semantic Multi-Output"
                    : "Notch Sixty Semantic Tap",
                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.semantic.\(UUID().uuidString)",
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            if routePlan.usesMultiplePhysicalDevices {
                let subdevices: [[String: Any]] = routePlan.orderedDeviceUIDs.map { uid in
                    [
                        kAudioSubDeviceUIDKey: uid,
                        kAudioSubDeviceDriftCompensationKey: uid != routePlan.referenceDeviceUID,
                    ]
                }
                aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = subdevices
                aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = routePlan.referenceDeviceUID
            }
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: routePlan.usesMultiplePhysicalDevices
                    ? "create semantic multi-output aggregate device"
                    : "create semantic tap aggregate device"
            )
            if routePlan.usesMultiplePhysicalDevices {
                try Self.waitForDeviceAlive(aggregateDeviceID)
            }

            try Self.writeFloat64Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                value: adaptiveSampleRateRequired ? tapFormat.sampleRate : outputFormat.sampleRate,
                operation: "set semantic aggregate sample rate"
            )
            try Self.writeUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                value: outputBufferFrames,
                operation: "set semantic aggregate buffer size"
            )
            let captureBufferFrames = try Self.readUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read semantic aggregate buffer size"
            )
            guard captureBufferFrames == outputBufferFrames else {
                throw LiveNChannelTransportError.captureBufferSizeMismatch(
                    capture: captureBufferFrames,
                    output: outputBufferFrames
                )
            }

            outputDeviceID = routePlan.usesMultiplePhysicalDevices
                ? aggregateDeviceID
                : selectedOutput.deviceID
            let clientData = UnsafeMutableRawPointer(newBridge)
            try Self.check(
                AudioDeviceCreateIOProcID(
                    aggregateDeviceID,
                    N60LiveNChannelCaptureIOProc,
                    clientData,
                    &captureIOProcID
                ),
                operation: "create semantic capture IOProc"
            )
            try Self.check(
                AudioDeviceCreateIOProcID(
                    outputDeviceID,
                    N60LiveNChannelOutputIOProc,
                    clientData,
                    &outputIOProcID
                ),
                operation: "create semantic output IOProc"
            )
            guard captureIOProcID != nil else {
                throw LiveNChannelTransportError.ioProcUnavailable(role: "capture")
            }
            guard outputIOProcID != nil else {
                throw LiveNChannelTransportError.ioProcUnavailable(role: "output")
            }

            try startIO()
        } catch {
            stop(fadeOut: false)
            throw error
        }
    }

    /// Test seam (E6 S9c2): a hardware-free session. It owns a real bridge and a real graph host built exactly as
    /// the production init builds them, but opens no tap, aggregate or IO procs, so the engine's live-edit and
    /// session-kind paths can be exercised without Core Audio. Never used by the app.
    init(
        testingSelectedOutput selectedOutput: AudioOutputDevice,
        routePlan: LiveNChannelOutputRoutePlan,
        renderGraph: N60LiveNChannelRenderGraph,
        inputMap: N60ProgramInputMap,
        sampleRate: Double,
        outputBufferFrames: UInt32 = 512,
        unifiedGraphConfiguration: UnifiedGraphConfiguration?,
        ancFeedSplitter: N60SpeakerBusSplitterSnapshot? = nil
    ) throws {
        self.selectedOutput = selectedOutput
        self.routePlan = routePlan
        let asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * renderGraph.programLayout.channelCount,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * renderGraph.programLayout.channelCount,
            mChannelsPerFrame: renderGraph.programLayout.channelCount,
            mBitsPerChannel: 32,
            mReserved: 0)
        tapFormat = AudioStreamFormatDescription(asbd)
        outputFormat = AudioStreamFormatDescription(asbd)
        guard let newBridge = N60LiveNChannelBridgeCreate(Self.bridgeCapacityFrames, inputMap, renderGraph, 0, 1) else {
            throw LiveNChannelTransportError.realtimeBridgeAllocationFailed
        }
        if let configuration = unifiedGraphConfiguration {
            switch Self.makeUnifiedGraph(
                configuration: configuration, bridge: newBridge, sampleRate: sampleRate,
                laneCount: Int(renderGraph.programLayout.channelCount), outputBufferFrames: outputBufferFrames,
                ancFeedSplitter: ancFeedSplitter
            ) {
            case .success(let host):
                unifiedGraphHost = host
                hostedAnc = configuration.ancActuators?.hostFed == true ? configuration.ancActuators : nil
                hostedConfiguration = hostedAnc == nil ? nil : configuration
                mimoStage = configuration.mimo
                lastGraphConfiguration = configuration
            case .failure(let reason): unifiedGraphFallbackReason = reason
            }
        }
        bridge = newBridge
        installLoudnessWorker(newBridge, sampleRate: sampleRate)
        registerHostTimeSink(newBridge, host: unifiedGraphHost)
        if hostedAnc != nil { N60LiveNChannelBridgeSetOutputGain(newBridge, 1) }
    }

    deinit {
        stop(fadeOut: false)
    }

    func roomTreatmentSnapshot() -> N60MIMOTreatmentLiveSnapshot? {
        guard let bridge else { return nil }
        let snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
        return snapshot.roomTreatmentConfigured
            ? snapshot.roomTreatment
            : nil
    }

    func requestRoomTreatmentArm() -> Bool {
        guard let bridge else { return false }
        return N60LiveNChannelBridgeRequestRoomTreatmentArm(bridge)
    }

    func requestRoomTreatmentBypass() {
        N60LiveNChannelBridgeRequestRoomTreatmentBypass(bridge)
    }

    func latchRoomTreatmentFault(_ fault: N60MIMOTreatmentFault) -> Bool {
        guard let bridge else { return false }
        return N60LiveNChannelBridgeLatchRoomTreatmentFault(
            bridge,
            fault
        )
    }

    func requestRoomTreatmentFaultClear() {
        N60LiveNChannelBridgeRequestRoomTreatmentFaultClear(bridge)
    }

    func revokeRoomTreatmentAuthorization() {
        N60LiveNChannelBridgeSetRoomTreatmentAuthorized(bridge, false)
    }

    /// E26 S7b2c: the output buffer's host time reaches the ANC lane feed (telemetry stamps and speaker-drive anchors).
    /// The feed is owned by the graph host, which the session keeps for as long as the bridge runs.
    private func registerHostTimeSink(_ bridge: UnsafeMutablePointer<N60LiveNChannelBridge>, host: UnifiedGraphHost?) {
        guard let feed = host?.retainedResource as? ProfileAncFeed else { return }
        N60LiveNChannelBridgeSetHostTimeSink(bridge, N60AncLaneFeedHostTimeSink, UnsafeMutableRawPointer(feed.pointer))
    }

#if DEBUG
    /// Test seam (E26 S7b2c part 2): runs one capture block and one output block through the bridge's real IO procs, as
    /// the hardware callbacks would, and returns the interleaved output (`outputChannels` per frame). The programme is a
    /// constant on every captured channel. Never used by the app.
    func testingRunBlock(frames: Int, programme: Float, outputChannels: Int, hostTime: UInt64 = 0) -> [Float] {
        guard let bridge, frames > 0 else { return [] }
        let captureChannels = Int(outputFormat.channelCount)
        var input = [Float](repeating: programme, count: frames * captureChannels)
        var output = [Float](repeating: -9, count: frames * outputChannels)
        var inputTime = AudioTimeStamp()
        var outputTime = AudioTimeStamp()
        outputTime.mHostTime = hostTime
        outputTime.mFlags = hostTime == 0 ? [] : .hostTimeValid
        input.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(captureChannels),
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)))
            var unused = AudioBufferList()
            _ = N60LiveNChannelCaptureIOProc(
                0, &inputTime, &list, &inputTime, &unused, &inputTime, UnsafeMutableRawPointer(bridge))
        }
        output.withUnsafeMutableBufferPointer { buffer in
            var list = AudioBufferList(
                mNumberBuffers: 1,
                mBuffers: AudioBuffer(
                    mNumberChannels: UInt32(outputChannels),
                    mDataByteSize: UInt32(buffer.count * MemoryLayout<Float>.size),
                    mData: UnsafeMutableRawPointer(buffer.baseAddress)))
            var unused = AudioBufferList()
            _ = N60LiveNChannelOutputIOProc(
                0, &outputTime, &unused, &outputTime, &list, &outputTime, UnsafeMutableRawPointer(bridge))
        }
        return output
    }

    /// Test seam (G29): replaces the bridge's host-time sink while no block runs; nil restores the feed's own sink.
    func testingSwapHostTimeSink(_ function: N60LiveNChannelHostTimeSinkFunction?, context: UnsafeMutableRawPointer?) {
        guard let bridge else { return }
        if let function {
            N60LiveNChannelBridgeSetHostTimeSink(bridge, function, context)
        } else {
            registerHostTimeSink(bridge, host: unifiedGraphHost)
        }
    }
#endif

    func setOutputGain(_ gain: Float) {
        ancLock.lock()
        let hosted = hostedAnc != nil
        ancLock.unlock()
        guard hosted else {
            N60LiveNChannelBridgeSetOutputGain(bridge, gain)
            return
        }
        // E26 S7b2: the volume moves into the graph's OUTPUT_GAIN stages; the anti-noise is added after them. The feed's
        // taps and echo drive scale the programme by the same volume (block-constant; the graph ramps it).
        if let feed = ancFeed { N60AncLaneFeedSetProgrammeScale(feed.pointer, max(0, gain)) }
        _ = try? updateHostedAnc { $0.userOutputGain = max(0, gain) }
    }

    func setDetailedMeteringDemand(_ enabled: Bool) {
        N60LiveNChannelBridgeSetMeteringDemand(bridge, enabled)
    }

    /// E28 S6b: BS.1770-4 loudness of the semantic program channels. Input is every program role as dequeued (LFE is
    /// metered at weight 0); Output is the same roles after the render and limiter, then one channel per driven subwoofer feed (E9 S10); on a routed lane map each role is the sum of its speaker's lanes (E28 S9), nil when no lane carries a role.
    private var wideLoudnessWorker: ProductionWideLoudnessWorker?

    private func installLoudnessWorker(_ bridge: UnsafeMutablePointer<N60LiveNChannelBridge>, sampleRate: Double) {
        let positions = LoudnessChannelPosition.positions(for: routePlan.programLayout.roles)
        let capture = bridge.pointee.loudnessCapture
        let hasOutput = (capture?.pointee.outputChannels ?? 0) > 0
        wideLoudnessWorker = ProductionWideLoudnessWorker(
            capture: capture, sampleRate: sampleRate, inputPositions: positions,
            outputPositions: hasOutput ? positions + LoudnessChannelPosition.subwooferFeeds(
                outputChannels: Int(capture?.pointee.outputChannels ?? 0), programChannels: positions.count) : nil)
    }

    func setAnalysisDemand(_ demandMask: UInt32) {
        wideLoudnessWorker?.setDemand(demandMask)
    }

    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot {
        wideLoudnessWorker?.snapshot() ?? .empty
    }

    /// Bridge counters and meters. With the graph attached, the program lane levels come from
    /// the host (under its lock, serialised with publish and release), never from the bridge.
    func bridgeSnapshot() -> N60LiveNChannelBridgeSnapshot? {
        guard let bridge else { return nil }
        var snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
        unifiedGraphHost?.overlayProgramMeters(&snapshot.meter)
        return snapshot
    }

    /// E6 S9b: moves the running graph to `configuration` (posted parameters, or a faded rebuild). The channel
    /// counts must match the running graph; a CPU-budget or core refusal throws and the running graph keeps
    /// rendering.
    @discardableResult
    func republishGraph(_ configuration: UnifiedGraphConfiguration) throws -> UnifiedGraphApplyResult {
#if DEBUG
        if let failure = testingRepublishFailure {
            testingRepublishFailure = nil
            throw failure
        }
#endif
        guard let host = unifiedGraphReadback else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        var configuration = configuration
        ancLock.lock()
        if let anc = hostedAnc { configuration.ancActuators = anc }
        if let mimo = mimoStage { configuration.mimo = mimo }
        ancLock.unlock()
        guard abs(configuration.sampleRate - outputFormat.sampleRate) < 0.5 else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.sampleRateMismatch)
        }
        configuration.maxBlockFrames = Self.graphMaxBlockFrames
        let spec: UnifiedGraphSpec
        do { spec = try configuration.makeSpec() } catch let reason as UnifiedGraphFallbackReason {
            throw LiveNChannelTransportError.unifiedGraphRejected(reason)
        } catch { throw LiveNChannelTransportError.unifiedGraphRejected(.specRejected) }
        guard spec.inputChannels == host.inputChannels, spec.outputChannels == host.outputChannels else {
            throw LiveNChannelTransportError.unifiedGraphRejected(.laneCountMismatch)
        }
        do {
            let result = try host.apply(spec, linearFade: linearFadeForEQRepublish)
            ancLock.lock()
            if hostedAnc != nil { hostedConfiguration = configuration }
            lastGraphConfiguration = configuration
            ancLock.unlock()
            return result
        } catch {
            throw LiveNChannelTransportError.graphRepublishRefused(String(describing: error))
        }
    }

    /// E19 S6: posts a new MIMO stage (the live arm and trip words change as parameters; a changed design republishes).
    /// Control plane only. Throws when the graph is not running or the session carries no MIMO stage to update.
    @discardableResult
    func applyMIMOStage(_ stage: UnifiedGraphMIMOStage) throws -> UnifiedGraphApplyResult {
        ancLock.lock()
        let configuration = lastGraphConfiguration
        let previous = mimoStage
        mimoStage = stage
        ancLock.unlock()
        guard let configuration else {
            ancLock.lock(); mimoStage = previous; ancLock.unlock()
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        do { return try republishGraph(configuration) } catch {
            ancLock.lock(); mimoStage = previous; ancLock.unlock()
            throw error
        }
    }

    /// E19 S6: the stage's telemetry (state, fault, worst bound ratios); nil without a graph or a MIMO stage. Read-and-reset.
    func mimoReadback() -> n60_mimo_readback? {
        ancLock.lock(); let attached = mimoStage != nil; ancLock.unlock()
        guard attached else { return nil }
        guard let read = unifiedGraphReadback?.mimoReadback(stageId: UnifiedGraphMIMOStage.stageId) else { return nil }
        // E19 S8 (G27): the 250 ms poll consumes the reset fields, so the screen reads this held copy instead: the worst
        // ratio and peak fields keep their maximum until the stage is off again.
        ancLock.lock()
        defer { ancLock.unlock() }
        var held = read
        if read.state != 0, let previous = mimoReadbackHold, previous.state != 0 {
            held.boundRatioMax = n60_mimo_readback.maxMerged(read.boundRatioMax, previous.boundRatioMax)
            held.deltaPeak = n60_mimo_readback.maxMerged(read.deltaPeak, previous.deltaPeak)
        }
        mimoReadbackHold = held
        return read
    }

    /// E19 S8 (G27): the last readback with max-held ratio and peak fields; reading it resets nothing.
    func peekMIMOReadback() -> n60_mimo_readback? {
        ancLock.lock(); defer { ancLock.unlock() }
        return mimoReadbackHold
    }

    /// The graph configuration last published (control plane): the headroom model and the chain digest read it.
    var publishedGraphConfiguration: UnifiedGraphConfiguration? {
        ancLock.lock(); defer { ancLock.unlock() }
        return lastGraphConfiguration
    }

    /// True when the running graph carries the MIMO stage (the arm gate "stage attached").
    var mimoStageAttached: Bool {
        ancLock.lock(); defer { ancLock.unlock() }
        return mimoStage != nil && unifiedGraphActive
    }

    /// Builds the graph for a session and attaches it to `bridge`, or says why it cannot.
    static func makeUnifiedGraph(
        configuration: UnifiedGraphConfiguration,
        bridge: UnsafeMutablePointer<N60LiveNChannelBridge>,
        sampleRate: Double,
        laneCount: Int,
        outputBufferFrames: UInt32,
        ancFeedSplitter: N60SpeakerBusSplitterSnapshot? = nil
    ) -> Result<UnifiedGraphHost, UnifiedGraphFallbackReason> {
        var configuration = configuration
        guard abs(configuration.sampleRate - sampleRate) < 0.5 else { return .failure(.sampleRateMismatch) }
        guard configuration.lanes.count == laneCount else { return .failure(.laneCountMismatch) }
        configuration.maxBlockFrames = graphMaxBlockFrames
        guard outputBufferFrames <= configuration.maxBlockFrames else { return .failure(.blockSizeTooLarge) }
        let spec: UnifiedGraphSpec
        do {
            spec = try configuration.makeSpec()
        } catch let reason as UnifiedGraphFallbackReason {
            return .failure(reason)
        } catch {
            return .failure(.specRejected)
        }
        guard let host = try? UnifiedGraphHost(spec: spec), let raw = host.rawGraph else {
            return .failure(.graphBuildFailed)
        }
        if configuration.ancActuators?.hostFed == true {
            // E26 S7b2: the anti-noise lanes are filled by the feed, registered as the graph's EXTERNAL processor
            // (control thread, IO stopped). The host keeps the feed alive until the graph is retired.
            guard let splitter = ancFeedSplitter,
                  let feed = ProfileAncFeed(sampleRate: sampleRate, splitter: splitter) else {
                host.release()
                return .failure(.specRejected)
            }
            let process = unsafeBitCast(
                N60AncLaneFeedProcess as @convention(c) (
                    UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<Float>>, UnsafePointer<UnsafeMutablePointer<Float>>,
                    UInt32, UInt32
                ) -> Int32,
                to: n60_external_process_fn.self)
            guard n60_graph_set_external_processor(
                OpaquePointer(raw), process, UnsafeMutableRawPointer(feed.pointer), ProfileAncFeed.channelCount
            ) == N60_STATUS_OK else {
                host.release()
                return .failure(.graphBuildFailed)
            }
            host.retainedResource = feed
        }
        guard N60LiveNChannelBridgeAttachGraph(
            bridge, raw, UInt32(configuration.channelCount), configuration.maxBlockFrames
        ) else { return .failure(.attachFailed) }
        return .success(host)
    }

    func counters() -> AudioTransportCounters {
        guard let bridge else { return AudioTransportCounters() }
        let snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
        let adaptive = snapshot.adaptiveSampleRate
        return AudioTransportCounters(
            captureCallbacks: snapshot.captureCallbacks,
            outputCallbacks: snapshot.outputCallbacks,
            capturedFrames: snapshot.adaptiveSampleRateEnabled
                ? adaptive.pushedInputFrames
                : snapshot.transport.capturedFrames,
            deliveredFrames: snapshot.renderedFrames,
            underrunFrames: snapshot.adaptiveSampleRateEnabled
                ? adaptive.starvedOutputFrames
                : snapshot.transport.underrunFrames,
            overrunFrames: snapshot.adaptiveSampleRateEnabled
                ? adaptive.droppedInputFrames
                : snapshot.transport.overrunFrames,
            unsupportedBufferLayouts: snapshot.transport.unsupportedBufferLayouts
                + snapshot.outputWriteFailures,
            gatedOutputCallbacks: snapshot.gatedOutputCallbacks,
            gatedOutputFrames: snapshot.gatedOutputFrames,
            bufferedFrames: snapshot.adaptiveSampleRateEnabled
                ? adaptive.bufferedFrames
                : snapshot.transport.bufferedFrames,
            adaptiveSampleRateEnabled: snapshot.adaptiveSampleRateEnabled,
            adaptiveInputSampleRate: adaptive.inputSampleRate,
            adaptiveOutputSampleRate: adaptive.outputSampleRate,
            adaptiveCorrectionPPM: adaptive.correctionPPM,
            adaptiveTargetBufferedFrames: adaptive.targetBufferedFrames,
            adaptiveDroppedInputFrames: adaptive.droppedInputFrames,
            adaptiveStarvedOutputFrames: adaptive.starvedOutputFrames,
            adaptiveControllerSaturationEvents: adaptive.controllerSaturationEvents
        )
    }

    /// E6 S9c2: ramps the output to silence in the callback (sample domain) and waits, bounded, for the ramp to end,
    /// so a session-kind change, sleep or quit never steps to zero. Control plane only; waits at most 100 ms.
    private func rampOutputToSilence() {
        guard let bridge, isOutputStarted, N60LiveNChannelBridgeGetSnapshot(bridge).outputGateOpen else { return }
        let frames = UInt32(min(max((max(outputFormat.sampleRate, 1) * 0.020).rounded(), 1), Double(UInt32.max)))
        N60LiveNChannelBridgeRequestShutdownFade(bridge, frames)
        var waited: UInt32 = 0
        while waited < 100_000, !N60LiveNChannelBridgeShutdownFadeComplete(bridge) {
            usleep(250)
            waited &+= 250
        }
    }

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true
        if fadeOut {
            rampOutputToSilence()
        }
        if fadeOut, let bridge {
            // The callback-owned ramp above has ended (or timed out); make silence permanent before teardown.
            N60LiveNChannelBridgeSetOutputGain(bridge, 0)
        }
        if isOutputStarted, let outputIOProcID {
            AudioDeviceStop(outputDeviceID, outputIOProcID)
            isOutputStarted = false
        }
        if isCaptureStarted, let captureIOProcID,
           aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, captureIOProcID)
            isCaptureStarted = false
        }
        // E20 S6: no callback renders now; the render workers leave the device workgroup and exit.
        unifiedGraphHost?.endParallelRender()
        if let outputIOProcID {
            AudioDeviceDestroyIOProcID(outputDeviceID, outputIOProcID)
            self.outputIOProcID = nil
        }
        if let captureIOProcID, aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, captureIOProcID)
            self.captureIOProcID = nil
        }
        if aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != AudioObjectID(kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        // The worker reads the bridge's loudness ring; it must be quiet before the bridge goes.
        wideLoudnessWorker?.stop()
        wideLoudnessWorker = nil
        if let bridge {
            N60LiveNChannelBridgeDestroy(bridge)
            self.bridge = nil
        }
        // The bridge (and so the callback) is gone; only now may the graph be retired.
        unifiedGraphHost?.release()
        unifiedGraphHost = nil
        audioUnitRack = nil
    }

    /// Whether the callback renders lanes, bass management and subs through libn60core.
    var unifiedGraphActive: Bool { unifiedGraphHost != nil && bridge != nil }

    /// The live graph host for metering and latency readbacks (nil while the legacy core renders).
    var unifiedGraphReadback: UnifiedGraphHost? { unifiedGraphActive ? unifiedGraphHost : nil }

    private func startIO() throws {
        guard !stopped else { throw LiveNChannelTransportError.ioProcUnavailable(role: "stopped") }
        guard let outputIOProcID else {
            throw LiveNChannelTransportError.ioProcUnavailable(role: "output")
        }
        guard let captureIOProcID else {
            throw LiveNChannelTransportError.ioProcUnavailable(role: "capture")
        }
        guard aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw LiveNChannelTransportError.ioProcUnavailable(role: "capture")
        }

        // E20 S6: the render workers join the output device's IO workgroup before its first callback.
        unifiedGraphHost?.beginParallelRender(workgroup: AudioWorkgroupWorkerPool.deviceWorkgroup(outputDeviceID))
        do {
            try Self.check(
                AudioDeviceStart(outputDeviceID, outputIOProcID),
                operation: "start semantic physical output"
            )
        } catch {
            unifiedGraphHost?.endParallelRender()
            throw error
        }
        isOutputStarted = true
        do {
            try Self.check(
                AudioDeviceStart(aggregateDeviceID, captureIOProcID),
                operation: "start semantic tap capture"
            )
            isCaptureStarted = true
        } catch {
            AudioDeviceStop(outputDeviceID, outputIOProcID)
            isOutputStarted = false
            unifiedGraphHost?.endParallelRender()
            throw error
        }
    }

    private static func resolveInputChannelDescriptions(
        deviceID: AudioDeviceID,
        channelCount: UInt32
    ) throws -> [AudioChannelDescription] {
        if let preferred = try readPreferredChannelLayout(deviceID: deviceID),
           let descriptions = try expandChannelLayout(
                preferred,
                expectedChannelCount: channelCount
           ) {
            return descriptions
        }

        // Stereo is the sole compatibility fallback. Apple defines the tap format
        // as matching the selected device stream; standard L/R is unambiguous here.
        if channelCount == 2 {
            var left = AudioChannelDescription()
            left.mChannelLabel = kAudioChannelLabel_Left
            var right = AudioChannelDescription()
            right.mChannelLabel = kAudioChannelLabel_Right
            return [left, right]
        }
        throw LiveNChannelTransportError.inputChannelLayoutUnavailable(channelCount: channelCount)
    }

    private static func readPreferredChannelLayout(
        deviceID: AudioDeviceID
    ) throws -> Data? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelLayout,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(deviceID, &address) else { return nil }
        var size: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size)
        guard sizeStatus == noErr, size >= UInt32(MemoryLayout<AudioChannelLayout>.size) else {
            return nil
        }
        var data = Data(count: Int(size))
        let status = data.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                bytes.baseAddress!
            )
        }
        guard status == noErr else { return nil }
        return data
    }

    private static func expandChannelLayout(
        _ layoutData: Data,
        expectedChannelCount: UInt32
    ) throws -> [AudioChannelDescription]? {
        layoutData.withUnsafeBytes { raw -> [AudioChannelDescription]? in
            guard let base = raw.baseAddress,
                  raw.count >= MemoryLayout<AudioChannelLayout>.size else { return nil }
            let layout = base.assumingMemoryBound(to: AudioChannelLayout.self)
            if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions {
                return copyExplicitDescriptions(layout, count: expectedChannelCount)
            }

            let property: AudioFormatPropertyID
            var specifier = UInt32(0)
            if layout.pointee.mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelBitmap {
                property = kAudioFormatProperty_ChannelLayoutForBitmap
                specifier = layout.pointee.mChannelBitmap.rawValue
            } else {
                property = kAudioFormatProperty_ChannelLayoutForTag
                specifier = layout.pointee.mChannelLayoutTag
            }

            var expandedSize: UInt32 = 0
            let infoStatus = withUnsafePointer(to: &specifier) { pointer in
                AudioFormatGetPropertyInfo(
                    property,
                    UInt32(MemoryLayout<UInt32>.size),
                    pointer,
                    &expandedSize
                )
            }
            guard infoStatus == noErr,
                  expandedSize >= UInt32(MemoryLayout<AudioChannelLayout>.size) else { return nil }
            let expanded = UnsafeMutableRawPointer.allocate(
                byteCount: Int(expandedSize),
                alignment: MemoryLayout<AudioChannelLayout>.alignment
            )
            defer { expanded.deallocate() }
            let propertyStatus = withUnsafePointer(to: &specifier) { pointer in
                AudioFormatGetProperty(
                    property,
                    UInt32(MemoryLayout<UInt32>.size),
                    pointer,
                    &expandedSize,
                    expanded
                )
            }
            guard propertyStatus == noErr else { return nil }
            return copyExplicitDescriptions(
                expanded.assumingMemoryBound(to: AudioChannelLayout.self),
                count: expectedChannelCount
            )
        }
    }

    private static func copyExplicitDescriptions(
        _ layout: UnsafePointer<AudioChannelLayout>,
        count: UInt32
    ) -> [AudioChannelDescription]? {
        var descriptions = [AudioChannelDescription](
            repeating: AudioChannelDescription(),
            count: Int(count)
        )
        let copied = descriptions.withUnsafeMutableBufferPointer { buffer in
            N60CoreAudioCopyExplicitChannelDescriptions(
                layout,
                count,
                buffer.baseAddress!
            )
        }
        return copied ? descriptions : nil
    }

    private static func waitForDeviceAlive(_ deviceID: AudioDeviceID) throws {
        for _ in 0..<300 {
            let alive = try readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read semantic aggregate readiness"
            )
            if alive != 0 { return }
            usleep(10_000)
        }
        throw LiveNChannelTransportError.aggregateDeviceNotReady
    }

    private static func currentProcessObjectID() throws -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = getpid()
        var processObject = AudioObjectID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pid) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPointer,
                &dataSize,
                &processObject
            )
        }
        try check(status, operation: "translate PID to semantic process object")
        guard processObject != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioTransportError.processObjectUnavailable
        }
        return processObject
    }

    private static func readStreamFormat(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &format),
            operation: operation
        )
        return format
    }

    private static func readUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        operation: String
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value),
            operation: operation
        )
        return value
    }

    private static func writeUInt32Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: UInt32,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        try check(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &mutableValue
            ),
            operation: operation
        )
    }

    private static func writeFloat64Property(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        value: Float64,
        operation: String
    ) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutableValue = value
        try check(
            AudioObjectSetPropertyData(
                objectID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Float64>.size),
                &mutableValue
            ),
            operation: operation
        )
    }

    private static func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioTransportError.operationFailed(operation: operation, status: status)
        }
    }
}


// MARK: - E26 S7b2: Quiet Zone host for the profile session (class A: two mains plus one sub output)

/// Realtime contract (AGENTS.md section 4): everything here is control plane. The audio thread only runs the graph,
/// which calls `N60AncLaneFeedProcess` (allocation: none; synchronisation: wait-free mailboxes and atomics; latency:
/// none added; rates: any native rate; channels: five, programme L/R and the L/R/sub anti-noise sources; reset: the
/// feed is created disarmed with the graph and recreated, disarmed, by every session rebuild). Nothing arms it but
/// `setQuietZoneInjectAuthorised`, which the engine calls only for a live `LiveTreatmentArm`.
extension CoreAudioNChannelTransportSession: QuietZoneRuntimeHost {
    private var ancFeed: ProfileAncFeed? { unifiedGraphHost?.retainedResource as? ProfileAncFeed }

    /// True while this session's graph carries the Quiet Zone feed.
    var hostsQuietZone: Bool { ancFeed != nil }

    /// Applies `mutate` to the hosted actuators and republishes the graph (posted when only live values changed).
    @discardableResult
    private func updateHostedAnc(_ mutate: (inout UnifiedGraphAncActuators) -> Void) throws -> UnifiedGraphApplyResult {
        // Serialised end to end, so an older snapshot (say authorised) cannot reach the graph after a newer revoke.
        ancPublishLock.lock(); defer { ancPublishLock.unlock() }
        ancLock.lock()
        guard var anc = hostedAnc, var configuration = hostedConfiguration else {
            ancLock.unlock()
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        let previous = anc
        mutate(&anc)
        hostedAnc = anc
        configuration.ancActuators = anc
        ancLock.unlock()
        do {
            return try republishGraph(configuration)
        } catch {
            // The graph still holds the old actuators, so the record must too (authorisation never gets ahead of it).
            ancLock.lock(); hostedAnc = previous; ancLock.unlock()
            throw error
        }
    }

    /// True when the next graph publish would let ANC_INJECT add anti-noise.
    var quietZoneInjectAuthorised: Bool {
        ancLock.lock(); defer { ancLock.unlock() }
        return hostedAnc?.authorised ?? false
    }

    /// Authorises or revokes ANC_INJECT (and ANC_CAPTURE) in the graph and arms or disarms the feed. This is the only
    /// path to authorisation and the engine calls it only while a `LiveTreatmentArm` is armed for this session. The
    /// authorisation is not a live parameter, so it is a faded graph publish. Revoking disarms the feed first (20 ms fade).
    func setQuietZoneInjectAuthorised(_ authorised: Bool) throws {
        ancAuthoriseLock.lock(); defer { ancAuthoriseLock.unlock() }
        guard let feed = ancFeed else { throw LiveNChannelTransportError.configurationChangeRequiresRestart }
        if authorised {
            // Already authorised and armed: a tonal update changes only the snapshot, never republishes the graph.
            ancLock.lock()
            let needsArm = ancFeedNeedsArm
            ancLock.unlock()
            if quietZoneInjectAuthorised, !needsArm { return }
            if !quietZoneInjectAuthorised { try updateHostedAnc { $0.authorised = true } }
            N60AncLaneFeedArm(feed.pointer)
            ancLock.lock(); ancFeedNeedsArm = false; ancLock.unlock()
        } else {
            N60AncLaneFeedDisarm(feed.pointer)
            N60AncLaneFeedReleaseLease(feed.pointer)
            do {
                try updateHostedAnc { $0.authorised = false }
            } catch {
                // The graph (and so the record) is still authorised; the feed is silent. Remember to arm it next time.
                ancLock.lock(); ancFeedNeedsArm = true; ancLock.unlock()
                throw error
            }
            ancLock.lock(); ancFeedNeedsArm = false; ancLock.unlock()
        }
    }

    /// Hands the tonal canceller's snapshot to the feed (single writer: the engine's control path).
    func setQuietZoneTonalSnapshot(_ snapshot: N60ActiveQuietZoneSnapshot) throws {
        guard let feed = ancFeed else { throw LiveNChannelTransportError.configurationChangeRequiresRestart }
        var copy = snapshot
        guard N60AncLaneFeedSetTonalSnapshot(feed.pointer, &copy) else {
            throw ActiveQuietZoneError.invalidConfiguration
        }
    }

    /// Feed counters for tests and diagnostics.
    func quietZoneFeedStatus() -> N60AncLaneFeedStatus? {
        guard let feed = ancFeed else { return nil }
        return N60AncLaneFeedGetStatus(feed.pointer)
    }

    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        guard let feed = ancFeed else { return 0 }
        var copy = record
        return N60ActiveQuietZoneGainMailboxPublish(N60AncLaneFeedMailbox(feed.pointer), &copy)
    }

    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        guard let feed = ancFeed else { return nil }
        var record = N60ActiveQuietZoneTelemetryRecord()
        return N60ActiveQuietZoneTelemetryPop(N60AncLaneFeedTelemetry(feed.pointer), &record) ? record : nil
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        guard let feed = ancFeed else { return N60ActiveQuietZoneMailboxStats() }
        return N60ActiveQuietZoneGainMailboxStats(N60AncLaneFeedMailbox(feed.pointer))
    }

    /// Latches the 20 ms fade (any thread). The graph's own guards also trip on their own; `howlGuardTripCount`
    /// counts both, so `LiveTreatmentArm` disarms on either.
    func requestHowlTrip() {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedDisarm(feed.pointer)
        ancLock.lock(); ancManualTrips &+= 1; ancLock.unlock()
    }

    /// Manual trips plus the graph guards' trips, the latter read by polling the newest snapshot (control thread, so
    /// a graph-guard trip is seen at the poll rate, not at once; the guard itself mutes within its own ramp).
    var howlGuardTripCount: UInt64 {
        let stageIds = (0..<UnifiedGraphAncActuators.hostFedActuatorCount).map {
            UnifiedGraphAncActuators.guardStageBase + UInt32($0)
        }
        let graphTrips = unifiedGraphHost?.guardTripCount(stageIds: stageIds) ?? 0
        ancLock.lock(); defer { ancLock.unlock() }
        return ancManualTrips &+ graphTrips
    }

    /// G20: a graph-guard trip newly seen since the last poll disarms the feed at once (20 ms fade), so the feed does not
    /// keep playing until the arm notices the count. Call from the lease keeper's poll (main actor).
    func pollQuietZoneGuards() {
        guard let feed = ancFeed else { return }
        let stageIds = (0..<UnifiedGraphAncActuators.hostFedActuatorCount).map {
            UnifiedGraphAncActuators.guardStageBase + UInt32($0)
        }
        let trips = unifiedGraphHost?.guardTripCount(stageIds: stageIds) ?? 0
        ancLock.lock()
        let fresh = trips > ancSeenGuardTrips
        ancSeenGuardTrips = trips
        ancLock.unlock()
        if fresh { N60AncLaneFeedDisarm(feed.pointer) }
    }

    /// Re-arms the graph guards (a live revision bump) so the anti-noise can fade back in.
    func rearmHowlGuard() {
        _ = try? updateHostedAnc { $0.rearmRevision = ($0.rearmRevision % 1_000_000) + 1 }
    }

    func renewActiveQuietZoneLease(seconds: Double) {
        guard let feed = ancFeed, seconds > 0 else { return }
        N60AncLaneFeedRenewLease(feed.pointer, UInt64((outputFormat.sampleRate * seconds).rounded(.up)))
    }

    func releaseActiveQuietZoneLease() {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedReleaseLease(feed.pointer)
    }

    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        guard let feed = ancFeed, !left.isEmpty, left.count == right.count else { return false }
        return N60AncLaneFeedSetFeedForwardWeights(feed.pointer, left, right, UInt32(left.count))
    }

    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        guard let feed = ancFeed, FeedForwardLiveArmGate.decide(gate).isAllowed else { return nil }
        return N60AncLaneFeedFeedForwardArm(feed.pointer, gate.leadSeconds, gate.requiredLeadSeconds)
    }

    func setFeedForwardLiveEcho(_ payload: FeedForwardLiveEchoPayload?, timingFrames: UInt32) -> Bool {
        guard let feed = ancFeed else { return false }
        guard let payload else { return N60AncLaneFeedSetFeedForwardEcho(feed.pointer, nil) }
        guard payload.isValid else { return false }
        let bulk = payload.bulk
        let ok = payload.left.withUnsafeBufferPointer { left in
            payload.right.withUnsafeBufferPointer { right in
                var echo = N60FeedForwardLiveEcho(
                    bulkDelay: (bulk[0], bulk[1]),
                    tapCount: (UInt32(left.count), UInt32(right.count)),
                    taps: (left.baseAddress, right.baseAddress))
                return N60AncLaneFeedSetFeedForwardEcho(feed.pointer, &echo)
            }
        }
        return ok && N60AncLaneFeedSetFeedForwardEchoTiming(feed.pointer, timingFrames)
    }

    func disarmFeedForwardLive() {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedFeedForwardDisarm(feed.pointer)
    }

    /// The feed has no separate reference-lost latch: losing the reference disarms the feed-forward filter.
    func markFeedForwardLiveReferenceLost() { disarmFeedForwardLive() }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        guard let feed = ancFeed else { return nil }
        var status = N60RenderKernelFeedForwardLiveStatus()
        status.attached = true
        status.filter = N60AncLaneFeedFeedForwardStatus(feed.pointer)
        status.outputIndex = N60AncLaneFeedReferenceOutputIndex(feed.pointer)
        status.referenceUnderruns = N60AncLaneFeedGetStatus(feed.pointer).referenceUnderruns
        return status
    }

    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard let feed = ancFeed, !samples.isEmpty else { return nil }
        return N60AncLaneFeedPushReference(feed.pointer, startIndex, samples, UInt32(samples.count))
    }

    var ambientReferenceSampleRate: Double { outputFormat.sampleRate }

    // MARK: Reference taps (E26 S7b2c, G26)

    private func tapSnapshot(_ tap: N60AncLaneFeedTap) -> N60AncLaneFeedTapSnapshot? {
        guard let feed = ancFeed else { return nil }
        return N60AncLaneFeedTapGetSnapshot(feed.pointer, tap)
    }

    private func readTap(_ tap: N60AncLaneFeedTap, maximumFrames: Int) -> [N60AncLaneFeedFramePair] {
        guard let feed = ancFeed, maximumFrames > 0,
              let snapshot = tapSnapshot(tap) else { return [] }
        let capacity = min(maximumFrames, Int(snapshot.availableFrames))
        guard capacity > 0 else { return [] }
        var result = [N60AncLaneFeedFramePair](repeating: N60AncLaneFeedFramePair(), count: capacity)
        let count = result.withUnsafeMutableBufferPointer {
            N60AncLaneFeedTapRead(feed.pointer, tap, $0.baseAddress!, UInt32($0.count))
        }
        if Int(count) < result.count { result.removeLast(result.count - Int(count)) }
        return result
    }

    func setAmbientReferenceDemand(_ enabled: Bool) {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapAmbient, enabled)
    }

    func ambientReferenceSnapshot() -> N60AmbientPlaybackReferenceSnapshot? {
        guard let s = tapSnapshot(N60AncLaneFeedTapAmbient) else { return nil }
        return N60AmbientPlaybackReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func discardAmbientReferenceFrames() {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedTapDiscard(feed.pointer, N60AncLaneFeedTapAmbient)
    }

    func readAmbientReferenceFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        readTap(N60AncLaneFeedTapAmbient, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapQuietZone, enabled)
    }

    func activeQuietZoneReferenceSnapshot() -> N60ActiveQuietZoneReferenceSnapshot? {
        guard let s = tapSnapshot(N60AncLaneFeedTapQuietZone) else { return nil }
        return N60ActiveQuietZoneReferenceSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames)
    }

    func discardActiveQuietZoneReferenceFrames() {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedTapDiscard(feed.pointer, N60AncLaneFeedTapQuietZone)
    }

    func readActiveQuietZoneReferenceFrames(maximumFrames: Int) -> [N60ActiveQuietZoneReferenceFrame] {
        readTap(N60AncLaneFeedTapQuietZone, maximumFrames: maximumFrames)
            .map { N60ActiveQuietZoneReferenceFrame(left: $0.left, right: $0.right) }
    }

    var activeQuietZoneReferenceSampleRate: Double { outputFormat.sampleRate }

    func setSpeakerDriveDemand(_ enabled: Bool) {
        guard let feed = ancFeed else { return }
        N60AncLaneFeedSetTapDemand(feed.pointer, N60AncLaneFeedTapSpeakerDrive, enabled)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        guard let s = tapSnapshot(N60AncLaneFeedTapSpeakerDrive) else { return nil }
        return N60SpeakerDriveSnapshot(
            enabled: s.enabled, availableFrames: s.availableFrames, availableAnchors: s.availableAnchors,
            capturedFrames: s.capturedFrames, droppedFrames: s.droppedFrames, droppedAnchors: s.droppedAnchors)
    }

    func readSpeakerDriveAnchors(maximum: Int) -> [N60SpeakerDriveAnchor] {
        guard let feed = ancFeed, maximum > 0 else { return [] }
        var raw = [N60AncLaneFeedAnchor](repeating: N60AncLaneFeedAnchor(), count: maximum)
        let count = raw.withUnsafeMutableBufferPointer {
            N60AncLaneFeedAnchorsRead(feed.pointer, $0.baseAddress!, UInt32($0.count))
        }
        return raw.prefix(Int(count)).map {
            N60SpeakerDriveAnchor(outputHostTime: $0.outputHostTime, firstFrameIndex: $0.firstFrameIndex,
                                  frames: $0.frames, reserved: $0.reserved)
        }
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        readTap(N60AncLaneFeedTapSpeakerDrive, maximumFrames: maximumFrames)
            .map { N60AmbientPlaybackReferenceFrame(left: $0.left, right: $0.right) }
    }
}
