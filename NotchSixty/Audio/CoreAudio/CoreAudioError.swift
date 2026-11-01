import AppKit
import CoreAudio
import Darwin
import Foundation

enum CoreAudioOperation: String, Equatable, Sendable {
    case enumerateDevices
    case readOutputStreams
    case readOutputChannelCount
    case readDeviceUID
    case readDeviceName
    case readNominalSampleRate
    case readAvailableSampleRates
}

struct CoreAudioError: Error, Equatable, Sendable, LocalizedError {
    let operation: CoreAudioOperation
    let status: OSStatus
    let objectID: AudioObjectID

    var errorDescription: String? {
        "Core Audio \(operation.rawValue) failed for object \(objectID) with status \(status)."
    }
}

struct AudioStreamFormatDescription: Equatable, Sendable {
    let sampleRate: Double
    let formatID: AudioFormatID
    let formatFlags: AudioFormatFlags
    let bytesPerFrame: UInt32
    let channelCount: UInt32
    let bitsPerChannel: UInt32

    init(_ format: AudioStreamBasicDescription) {
        sampleRate = format.mSampleRate
        formatID = format.mFormatID
        formatFlags = format.mFormatFlags
        bytesPerFrame = format.mBytesPerFrame
        channelCount = format.mChannelsPerFrame
        bitsPerChannel = format.mBitsPerChannel
    }

    var isFloatPCM: Bool {
        formatID == kAudioFormatLinearPCM && (formatFlags & kAudioFormatFlagIsFloat) != 0
    }

    var isSupportedFloat32TransportFormat: Bool {
        isFloatPCM && bitsPerChannel == 32 && channelCount > 0
    }

    var isSupportedStereoTransportFormat: Bool {
        isSupportedFloat32TransportFormat && channelCount == 2
    }
}

struct AudioTransportCounters: Equatable, Sendable {
    var captureCallbacks: UInt64 = 0
    var outputCallbacks: UInt64 = 0
    var capturedFrames: UInt64 = 0
    var deliveredFrames: UInt64 = 0
    var underrunFrames: UInt64 = 0
    var overrunFrames: UInt64 = 0
    var unsupportedBufferLayouts: UInt64 = 0
    var gatedOutputCallbacks: UInt64 = 0
    var gatedOutputFrames: UInt64 = 0
    var bufferedFrames: UInt32 = 0
    var graphPublications: UInt64 = 0
    var graphPublicationFailures: UInt64 = 0
    var graphPublicationCoalescedUpdates: UInt64 = 0
    var graphTransitionsScheduled: UInt64 = 0
    var adaptiveSampleRateEnabled = false
    var adaptiveInputSampleRate = 0.0
    var adaptiveOutputSampleRate = 0.0
    var adaptiveCorrectionPPM = 0.0
    var adaptiveTargetBufferedFrames: UInt32 = 0
    var adaptiveDroppedInputFrames: UInt64 = 0
    var adaptiveStarvedOutputFrames: UInt64 = 0
    var adaptiveControllerSaturationEvents: UInt64 = 0

    init(snapshot: N60RealtimeAudioBridgeSnapshot) {
        captureCallbacks = snapshot.captureCallbacks
        outputCallbacks = snapshot.outputCallbacks
        capturedFrames = snapshot.capturedFrames
        deliveredFrames = snapshot.deliveredFrames
        underrunFrames = snapshot.underrunFrames
        overrunFrames = snapshot.overrunFrames
        unsupportedBufferLayouts = snapshot.unsupportedBufferLayouts
        gatedOutputCallbacks = snapshot.gatedOutputCallbacks
        gatedOutputFrames = snapshot.gatedOutputFrames
        bufferedFrames = snapshot.bufferedFrames
        adaptiveSampleRateEnabled = snapshot.adaptiveSampleRateEnabled
        adaptiveInputSampleRate = snapshot.adaptiveSampleRate.inputSampleRate
        adaptiveOutputSampleRate = snapshot.adaptiveSampleRate.outputSampleRate
        adaptiveCorrectionPPM = snapshot.adaptiveSampleRate.correctionPPM
        adaptiveTargetBufferedFrames = snapshot.adaptiveSampleRate.targetBufferedFrames
        adaptiveDroppedInputFrames = snapshot.adaptiveSampleRate.droppedInputFrames
        adaptiveStarvedOutputFrames = snapshot.adaptiveSampleRate.starvedOutputFrames
        adaptiveControllerSaturationEvents = snapshot.adaptiveSampleRate.controllerSaturationEvents
    }

    init(
        captureCallbacks: UInt64 = 0,
        outputCallbacks: UInt64 = 0,
        capturedFrames: UInt64 = 0,
        deliveredFrames: UInt64 = 0,
        underrunFrames: UInt64 = 0,
        overrunFrames: UInt64 = 0,
        unsupportedBufferLayouts: UInt64 = 0,
        gatedOutputCallbacks: UInt64 = 0,
        gatedOutputFrames: UInt64 = 0,
        bufferedFrames: UInt32 = 0,
        graphPublications: UInt64 = 0,
        graphPublicationFailures: UInt64 = 0,
        graphPublicationCoalescedUpdates: UInt64 = 0,
        graphTransitionsScheduled: UInt64 = 0,
        adaptiveSampleRateEnabled: Bool = false,
        adaptiveInputSampleRate: Double = 0,
        adaptiveOutputSampleRate: Double = 0,
        adaptiveCorrectionPPM: Double = 0,
        adaptiveTargetBufferedFrames: UInt32 = 0,
        adaptiveDroppedInputFrames: UInt64 = 0,
        adaptiveStarvedOutputFrames: UInt64 = 0,
        adaptiveControllerSaturationEvents: UInt64 = 0
    ) {
        self.captureCallbacks = captureCallbacks
        self.outputCallbacks = outputCallbacks
        self.capturedFrames = capturedFrames
        self.deliveredFrames = deliveredFrames
        self.underrunFrames = underrunFrames
        self.overrunFrames = overrunFrames
        self.unsupportedBufferLayouts = unsupportedBufferLayouts
        self.gatedOutputCallbacks = gatedOutputCallbacks
        self.gatedOutputFrames = gatedOutputFrames
        self.bufferedFrames = bufferedFrames
        self.graphPublications = graphPublications
        self.graphPublicationFailures = graphPublicationFailures
        self.graphPublicationCoalescedUpdates = graphPublicationCoalescedUpdates
        self.graphTransitionsScheduled = graphTransitionsScheduled
        self.adaptiveSampleRateEnabled = adaptiveSampleRateEnabled
        self.adaptiveInputSampleRate = adaptiveInputSampleRate
        self.adaptiveOutputSampleRate = adaptiveOutputSampleRate
        self.adaptiveCorrectionPPM = adaptiveCorrectionPPM
        self.adaptiveTargetBufferedFrames = adaptiveTargetBufferedFrames
        self.adaptiveDroppedInputFrames = adaptiveDroppedInputFrames
        self.adaptiveStarvedOutputFrames = adaptiveStarvedOutputFrames
        self.adaptiveControllerSaturationEvents = adaptiveControllerSaturationEvents
    }

    static func + (lhs: Self, rhs: Self) -> Self {
        Self(
            captureCallbacks: lhs.captureCallbacks + rhs.captureCallbacks,
            outputCallbacks: lhs.outputCallbacks + rhs.outputCallbacks,
            capturedFrames: lhs.capturedFrames + rhs.capturedFrames,
            deliveredFrames: lhs.deliveredFrames + rhs.deliveredFrames,
            underrunFrames: lhs.underrunFrames + rhs.underrunFrames,
            overrunFrames: lhs.overrunFrames + rhs.overrunFrames,
            unsupportedBufferLayouts: lhs.unsupportedBufferLayouts + rhs.unsupportedBufferLayouts,
            gatedOutputCallbacks: lhs.gatedOutputCallbacks + rhs.gatedOutputCallbacks,
            gatedOutputFrames: lhs.gatedOutputFrames + rhs.gatedOutputFrames,
            bufferedFrames: rhs.bufferedFrames,
            graphPublications: lhs.graphPublications + rhs.graphPublications,
            graphPublicationFailures: lhs.graphPublicationFailures + rhs.graphPublicationFailures,
            graphPublicationCoalescedUpdates: lhs.graphPublicationCoalescedUpdates + rhs.graphPublicationCoalescedUpdates,
            graphTransitionsScheduled: lhs.graphTransitionsScheduled + rhs.graphTransitionsScheduled,
            adaptiveSampleRateEnabled: rhs.adaptiveSampleRateEnabled,
            adaptiveInputSampleRate: rhs.adaptiveInputSampleRate,
            adaptiveOutputSampleRate: rhs.adaptiveOutputSampleRate,
            adaptiveCorrectionPPM: rhs.adaptiveCorrectionPPM,
            adaptiveTargetBufferedFrames: rhs.adaptiveTargetBufferedFrames,
            adaptiveDroppedInputFrames: lhs.adaptiveDroppedInputFrames + rhs.adaptiveDroppedInputFrames,
            adaptiveStarvedOutputFrames: lhs.adaptiveStarvedOutputFrames + rhs.adaptiveStarvedOutputFrames,
            adaptiveControllerSaturationEvents: lhs.adaptiveControllerSaturationEvents + rhs.adaptiveControllerSaturationEvents
        )
    }
}

struct AudioStartupGatePolicy: Equatable, Sendable {
    let steadyStateTargetFrames: UInt32
    let activationBufferedFrames: UInt32
    let fadeInFrames: UInt32

    init(outputBufferFrames: UInt32, sampleRate: Double, fadeInMilliseconds: Double = 12.0) {
        let bufferFrames = max(outputBufferFrames, 1)
        steadyStateTargetFrames = bufferFrames
        if bufferFrames > UInt32.max / 2 {
            activationBufferedFrames = UInt32.max
        } else {
            activationBufferedFrames = bufferFrames * 2
        }

        let requestedFadeFrames = max(sampleRate, 1) * max(fadeInMilliseconds, 0) / 1_000.0
        fadeInFrames = UInt32(min(max(requestedFadeFrames.rounded(), 1), Double(UInt32.max)))
    }
}

enum CoreAudioTransportError: Error, LocalizedError, Equatable {
    case processObjectUnavailable
    case operationFailed(operation: String, status: OSStatus)
    case unsupportedFormat(role: String, format: AudioStreamFormatDescription)
    case sampleRateMismatch(tap: Double, output: Double)
    case adaptiveSampleRateConfigurationFailed(tap: Double, output: Double)
    case realtimeBridgeAllocationFailed
    case dspGraphPublicationFailed
    case convolutionProgramPreparationFailed
    case roomCorrectionProgramPreparationFailed
    case speakerIRProgramPreparationFailed
    case ioProcUnavailable(role: String)
    case outputBufferExceedsBridgeCapacity(bufferFrames: UInt32, capacityFrames: UInt32)
    case captureBufferSizeMismatch(capture: UInt32, output: UInt32)
    case sameDeviceOutputMapCompilationFailed
    case aggregateDeviceNotReady
    case speakerBusSplitterConfigurationFailed
    case speakerDriverProcessingConfigurationFailed
    case headphoneDSPConfigurationFailed
    case audioUnitRackConfigurationFailed

    var errorDescription: String? {
        switch self {
        case .processObjectUnavailable:
            return "Unable to resolve Notch Sixty's Core Audio process object for tap self-exclusion."
        case .operationFailed(let operation, let status):
            return "Core Audio \(operation) failed with status \(status)."
        case .unsupportedFormat(let role, let format):
            return "Unsupported \(role) format: \(format.sampleRate) Hz, \(format.channelCount) channels, \(format.bitsPerChannel)-bit."
        case .sampleRateMismatch(let tap, let output):
            return "Native sample-rate mismatch: tap \(tap) Hz, output \(output) Hz is not supported by this aggregate-clock transport."
        case .adaptiveSampleRateConfigurationFailed(let tap, let output):
            return "Unable to prepare adaptive sample-rate conversion from \(tap) Hz to \(output) Hz."
        case .realtimeBridgeAllocationFailed:
            return "Unable to allocate the preallocated realtime audio bridge."
        case .dspGraphPublicationFailed:
            return "Unable to publish the render-ready DSP graph."
        case .convolutionProgramPreparationFailed:
            return "Unable to prepare an inactive convolution program slot."
        case .roomCorrectionProgramPreparationFailed:
            return "Unable to prepare an inactive room-correction FIR program slot."
        case .speakerIRProgramPreparationFailed:
            return "Unable to prepare an inactive Speaker IR FIR program slot."
        case .ioProcUnavailable(let role):
            return "Core Audio created the \(role) IOProc without returning a usable callback identifier."
        case .outputBufferExceedsBridgeCapacity(let bufferFrames, let capacityFrames):
            return "Startup gate requires \(bufferFrames) buffered frames but realtime bridge capacity is \(capacityFrames) frames."
        case .captureBufferSizeMismatch(let capture, let output):
            return "Tap aggregate callback quantum is \(capture) frames; expected \(output) frames to match the physical output."
        case .sameDeviceOutputMapCompilationFailed:
            return "Unable to compile the validated physical output map."
        case .aggregateDeviceNotReady:
            return "Core Audio created the private multi-output aggregate device but it did not become ready for IO."
        case .speakerBusSplitterConfigurationFailed:
            return "Unable to configure the immutable physical speaker crossover before audio callbacks start."
        case .speakerDriverProcessingConfigurationFailed:
            return "Unable to configure immutable per-driver speaker processing before audio callbacks start."
        case .headphoneDSPConfigurationFailed:
            return "Unable to configure the immutable headphone correction stage before audio callbacks start."
        case .audioUnitRackConfigurationFailed:
            return "Unable to configure the immutable live Audio Unit rack before audio callbacks start."
        }
    }
}

private final class DSPGraphSnapshotBox: @unchecked Sendable {
    let snapshot: N60DSPGraphSnapshot

    init(_ snapshot: N60DSPGraphSnapshot) {
        self.snapshot = snapshot
    }
}

private struct DSPGraphPublicationMetrics: Sendable {
    var publications: UInt64 = 0
    var failures: UInt64 = 0
    var coalescedUpdates: UInt64 = 0
    var transitionsScheduled: UInt64 = 0
}

/// Serial control-plane publisher for an already-running transport.
///
/// The realtime reader remains lock-free. Graph writes that can wait for an
/// inactive render slot happen on this worker instead of the MainActor, and
/// rapid control updates collapse to the newest complete graph. Structural
/// transitions use the bridge's sample-domain ramp, wait off the caller thread
/// for the audio callback to acknowledge rendered zero gain, publish the latest
/// graph at that silent boundary, then fade back up.
///
/// Prepared FIR programs have a stricter ownership rule: their three program
/// slots are sized for the two immutable render-graph generations plus one
/// preparation target. A structural transition is therefore registered
/// synchronously (without sleeping) so the single MainActor control writer can
/// refuse another FIR preparation until the queued generation is published.
private final class DSPGraphPublicationCoordinator: @unchecked Sendable {
    private static let transitionPollIntervalMilliseconds = 1

    private let queue = DispatchQueue(
        label: "com.dhdook.NotchSixty.dsp-graph-publication",
        qos: .userInteractive
    )
    private let bridge: OpaquePointer
    private var stopped = false
    private var transitionActive = false
    private var flushScheduled = false
    private var pendingSnapshot: DSPGraphSnapshotBox?
    private var metrics = DSPGraphPublicationMetrics()

    init(bridge: OpaquePointer) {
        self.bridge = bridge
    }

    func enqueuePublish(_ snapshot: N60DSPGraphSnapshot) {
        let box = DSPGraphSnapshotBox(snapshot)
        queue.async { [self, box] in
            guard !stopped else { return }
            replacePending(with: box)
            guard !transitionActive, !flushScheduled else { return }
            flushScheduled = true
            queue.async { [self] in flushLatestPublish() }
        }
    }

    func enqueueTransition(
        _ snapshot: N60DSPGraphSnapshot,
        fadeFrames: UInt32
    ) {
        let box = DSPGraphSnapshotBox(snapshot)
        queue.sync { [self, box] in
            guard !stopped else { return }
            replacePending(with: box)
            guard !transitionActive else { return }

            transitionActive = true
            metrics.transitionsScheduled &+= 1
            N60RealtimeAudioBridgeRampTransitionGain(bridge, 0.0, fadeFrames)
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.transitionPollIntervalMilliseconds)) { [self] in
                waitForFadeDownCompletion(fadeFrames: fadeFrames)
            }
        }
    }

    func canPrepareProgram() -> Bool {
        queue.sync { !stopped && !transitionActive }
    }

    func snapshotMetrics() -> DSPGraphPublicationMetrics {
        queue.sync { metrics }
    }

    func stop() {
        queue.sync {
            stopped = true
            pendingSnapshot = nil
            flushScheduled = false
        }
    }

    private func replacePending(with box: DSPGraphSnapshotBox) {
        if pendingSnapshot != nil {
            metrics.coalescedUpdates &+= 1
        }
        pendingSnapshot = box
    }

    private func flushLatestPublish() {
        flushScheduled = false
        guard !stopped, !transitionActive, let box = pendingSnapshot else { return }
        pendingSnapshot = nil
        publish(box.snapshot)
    }

    private func waitForFadeDownCompletion(fadeFrames: UInt32) {
        guard !stopped else {
            transitionActive = false
            pendingSnapshot = nil
            return
        }

        let state = N60RealtimeAudioBridgeGetSnapshot(bridge)
        guard state.transitionFramesRemaining == 0, state.transitionGain <= 0.000_001 else {
            queue.asyncAfter(deadline: .now() + .milliseconds(Self.transitionPollIntervalMilliseconds)) { [self] in
                waitForFadeDownCompletion(fadeFrames: fadeFrames)
            }
            return
        }
        finishTransition(fadeFrames: fadeFrames)
    }

    private func finishTransition(fadeFrames: UInt32) {
        guard !stopped else {
            transitionActive = false
            pendingSnapshot = nil
            return
        }

        let snapshot = pendingSnapshot?.snapshot
        pendingSnapshot = nil
        if let snapshot {
            _ = publish(snapshot)
        }
        N60RealtimeAudioBridgeRampTransitionGain(bridge, 1.0, fadeFrames)
        transitionActive = false
    }

    @discardableResult
    private func publish(_ snapshot: N60DSPGraphSnapshot) -> Bool {
        if N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot) {
            metrics.publications &+= 1
            return true
        }
        metrics.failures &+= 1
        return false
    }
}

final class CoreAudioTransportSession {
    private static let bridgeCapacityFrames: UInt32 = 65_536
    private static let graphTransitionFadeMilliseconds = 8.0
    private static let shutdownFadePollMicroseconds: UInt32 = 250
    private static let shutdownFadeTimeoutMicroseconds: UInt32 = 100_000

    let selectedOutput: AudioOutputDevice
    /// Random lifecycle token. Evidence from a stopped or reconstructed output
    /// route is never compatible, even when its device UID is unchanged.
    let calibrationTimingRouteLeaseID = UUID().uuidString
    let sameDeviceOutputPlan: SameDeviceOutputRoutePlan?
    let aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan?
    private(set) var tapFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var outputFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var startupGateTargetFrames: UInt32 = 0
    private(set) var startupGateActivationFrames: UInt32 = 0

    var startupGateOpened: Bool {
        guard let bridge else { return false }
        return N60RealtimeAudioBridgeGetSnapshot(bridge).outputGateOpen
    }

    private var bridge: OpaquePointer?
    /// E6 S8: when true, each published stereo snapshot the core can reproduce is also
    /// rendered through a libn60core graph; anything else keeps the kernel path.
    var unifiedGraphEnabled = false
    private var unifiedGraphHost: UnifiedGraphHost?
    /// Integer inter-channel taps of the attached stereo graph, excluded from its reported latency.
    private var unifiedGraphLaneTapFrames: UInt32 = 0
    /// E6 S8d: the taps of recently prepared kernel convolver programs, by generation, so a snapshot that references
    /// one can be rebuilt on the graph. The kernel snapshot carries only the generation. Only programs the core can
    /// hold (up to 32768 taps) are kept, newest few per convolver (the kernel has three slots).
    private var retainedPrograms: [UnifiedGraphProgramKind: [UInt64: UnifiedGraphFIRProgram]] = [:]
    private let retainedProgramsLock = NSLock()
    /// Why the kernel renders although the graph is enabled; nil while the graph renders or is off.
    private(set) var unifiedGraphFallbackReason: UnifiedGraphFallbackReason?
    private var headphoneDSPConfigured = false
    /// E6 S9d: the profile the HEADPHONE stage renders (nil without a stereo headphone profile) and the one the
    /// kernel was configured with. They differ after a live edit; the kernel cannot be reconfigured while IO runs.
    private var headphoneProfile: HeadphoneDeviceProfileConfiguration?
    private var kernelHeadphoneProfile: HeadphoneDeviceProfileConfiguration?
    private var lastGraphSnapshot: N60DSPGraphSnapshot?
    private var graphPublicationCoordinator: DSPGraphPublicationCoordinator?
    private var analysisWorker: ProductionAnalysisWorker?
    private var audioUnitRack: AudioUnitLiveRackSwitchboard?
    /// The graph whose EXTERNAL stage this transport's rack was bound to (E6 S8e).
    private var rackBoundGraph: UnsafeMutableRawPointer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var captureIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var outputDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var isCaptureStarted = false
    private var isOutputStarted = false
    private var stopped = false

    init(
        selectedOutput: AudioOutputDevice,
        sameDeviceOutputPlan: SameDeviceOutputRoutePlan? = nil,
        aggregateDeviceOutputPlan: AggregateDeviceOutputRoutePlan? = nil,
        speakerCrossoverMode: SpeakerCrossoverMode? = nil,
        speakerBusSplitterSnapshot: N60SpeakerBusSplitterSnapshot? = nil,
        speakerDriverProcessingSnapshot: N60SpeakerDriverProcessingSnapshot? = nil,
        audioUnitRack: AudioUnitLiveRackSwitchboard? = nil
    ) throws {
        precondition(sameDeviceOutputPlan == nil || aggregateDeviceOutputPlan == nil)
        self.selectedOutput = selectedOutput
        self.sameDeviceOutputPlan = sameDeviceOutputPlan
        self.aggregateDeviceOutputPlan = aggregateDeviceOutputPlan
        self.audioUnitRack = audioUnitRack
        guard let newBridge = N60RealtimeAudioBridgeCreate(Self.bridgeCapacityFrames) else {
            throw CoreAudioTransportError.realtimeBridgeAllocationFailed
        }
        bridge = newBridge
        graphPublicationCoordinator = DSPGraphPublicationCoordinator(bridge: newBridge)
        analysisWorker = ProductionAnalysisWorker(bridge: newBridge)

        do {
            let processObject = try Self.currentProcessObjectID()
            let description = CATapDescription(
                excludingProcesses: [processObject],
                deviceUID: selectedOutput.uid,
                stream: 0
            )
            description.name = "Notch Sixty System Audio"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped

            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), operation: "create process tap")

            tapFormat = AudioStreamFormatDescription(
                try Self.readStreamFormat(
                    objectID: tapID,
                    selector: kAudioTapPropertyFormat,
                    scope: kAudioObjectPropertyScopeGlobal,
                    operation: "read tap format"
                )
            )
            outputFormat = AudioStreamFormatDescription(
                try Self.readStreamFormat(
                    objectID: selectedOutput.deviceID,
                    selector: kAudioDevicePropertyStreamFormat,
                    scope: kAudioDevicePropertyScopeOutput,
                    operation: "read output stream format"
                )
            )

            guard tapFormat.isSupportedStereoTransportFormat else {
                throw CoreAudioTransportError.unsupportedFormat(role: "tap", format: tapFormat)
            }
            if sameDeviceOutputPlan == nil && aggregateDeviceOutputPlan == nil {
                guard outputFormat.isSupportedStereoTransportFormat else {
                    throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)
                }
            } else {
                guard outputFormat.isSupportedFloat32TransportFormat else {
                    throw CoreAudioTransportError.unsupportedFormat(role: "multichannel output reference", format: outputFormat)
                }
            }
            let adaptiveSampleRateRequired = abs(tapFormat.sampleRate - outputFormat.sampleRate) >= 0.5
            if adaptiveSampleRateRequired, aggregateDeviceOutputPlan != nil {
                // The legacy multi-device speaker path already runs capture and
                // output inside one HAL Aggregate Device clock domain. PR70
                // intentionally activates ASRC only for the independent stereo
                // capture/output clocks; semantic N-channel activation is PR71.
                throw CoreAudioTransportError.sampleRateMismatch(
                    tap: tapFormat.sampleRate,
                    output: outputFormat.sampleRate
                )
            }

            if let sameDeviceOutputPlan {
                try sameDeviceOutputPlan.validateForC4LiveTransport(selectedOutputUID: selectedOutput.uid, crossoverMode: speakerCrossoverMode)
                let descriptors = sameDeviceOutputPlan.routes.map { route -> N60SpeakerOutputRouteDescriptor in
                    var descriptor = N60SpeakerOutputRouteDescriptor()
                    descriptor.bus = route.bus.realtimeCType
                    descriptor.physicalChannelIndex = route.destination.channelIndex
                    return descriptor
                }
                try Self.configureOutputMap(
                    bridge: newBridge,
                    physicalChannelCount: sameDeviceOutputPlan.physicalChannelCount,
                    descriptors: descriptors
                )
            } else if let aggregateDeviceOutputPlan {
                try aggregateDeviceOutputPlan.validateForC4LiveTransport(selectedOutputUID: selectedOutput.uid, crossoverMode: speakerCrossoverMode)
                let descriptors = aggregateDeviceOutputPlan.mappedRoutes.map { mapped -> N60SpeakerOutputRouteDescriptor in
                    var descriptor = N60SpeakerOutputRouteDescriptor()
                    descriptor.bus = mapped.route.bus.realtimeCType
                    descriptor.physicalChannelIndex = mapped.aggregateChannelIndex
                    return descriptor
                }
                try Self.configureOutputMap(
                    bridge: newBridge,
                    physicalChannelCount: aggregateDeviceOutputPlan.physicalChannelCount,
                    descriptors: descriptors
                )
            }

            if let speakerBusSplitterSnapshot {
                guard N60RealtimeAudioBridgeConfigureSpeakerBusSplitter(
                    newBridge, speakerBusSplitterSnapshot
                ) else {
                    throw CoreAudioTransportError.speakerBusSplitterConfigurationFailed
                }
            }
            if let speakerDriverProcessingSnapshot {
                guard N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing(
                    newBridge, speakerDriverProcessingSnapshot
                ) else {
                    throw CoreAudioTransportError.speakerDriverProcessingConfigurationFailed
                }
            }

            let unityGraph = N60DSPGraphSnapshotMakeUnity(outputFormat.sampleRate)
            guard N60RealtimeAudioBridgePublishDSPGraph(newBridge, unityGraph) else {
                throw CoreAudioTransportError.dspGraphPublicationFailed
            }

            let outputBufferFrames = try Self.readUInt32Property(
                objectID: selectedOutput.deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read physical output buffer size"
            )
            if let audioUnitRack {
                guard abs(audioUnitRack.format.sampleRate - outputFormat.sampleRate) < 0.5,
                      audioUnitRack.format.channelCount == 2,
                      outputBufferFrames <= UInt32(audioUnitRack.format.maximumFramesPerSlice),
                      N60RealtimeAudioBridgeConfigureAudioUnitRack(
                        newBridge,
                        audioUnitRack.processor
                      ) else {
                    throw CoreAudioTransportError.audioUnitRackConfigurationFailed
                }
            }
            let gatePolicy = AudioStartupGatePolicy(
                outputBufferFrames: outputBufferFrames,
                sampleRate: outputFormat.sampleRate
            )
            var gateMinimumFrames = gatePolicy.activationBufferedFrames
            if adaptiveSampleRateRequired {
                let ratio = tapFormat.sampleRate / outputFormat.sampleRate
                let inputFramesPerOutputBuffer = UInt32(
                    min(
                        ceil(Double(outputBufferFrames) * ratio),
                        Double(UInt32.max)
                    )
                )
                let lookahead = UInt32(N60_ADAPTIVE_SRC_DEFAULT_TAPS / 2)
                // Keep three output quanta of input-domain headroom
                // around the PI target. Two quanta proved too shallow under
                // independently scheduled HAL callbacks because controller
                // settling could consume the FIR look-ahead margin.
                let target64 = max(
                    UInt64(256),
                    UInt64(inputFramesPerOutputBuffer) * 3 + UInt64(lookahead) * 2
                )
                let activation64 = target64
                    + UInt64(inputFramesPerOutputBuffer)
                    + UInt64(lookahead)
                guard target64 < UInt64(Self.bridgeCapacityFrames),
                      activation64 <= UInt64(Self.bridgeCapacityFrames) else {
                    throw CoreAudioTransportError.outputBufferExceedsBridgeCapacity(
                        bufferFrames: UInt32(min(activation64, UInt64(UInt32.max))),
                        capacityFrames: Self.bridgeCapacityFrames
                    )
                }
                let targetInputFrames = UInt32(target64)
                gateMinimumFrames = UInt32(activation64)
                guard N60RealtimeAudioBridgeConfigureAdaptiveSampleRate(
                    newBridge,
                    tapFormat.sampleRate,
                    outputFormat.sampleRate,
                    targetInputFrames
                ) else {
                    throw CoreAudioTransportError.adaptiveSampleRateConfigurationFailed(
                        tap: tapFormat.sampleRate,
                        output: outputFormat.sampleRate
                    )
                }
                startupGateTargetFrames = targetInputFrames
                startupGateActivationFrames = gateMinimumFrames
            } else {
                guard gatePolicy.activationBufferedFrames <= Self.bridgeCapacityFrames else {
                    throw CoreAudioTransportError.outputBufferExceedsBridgeCapacity(
                        bufferFrames: gatePolicy.activationBufferedFrames,
                        capacityFrames: Self.bridgeCapacityFrames
                    )
                }
                startupGateTargetFrames = gatePolicy.steadyStateTargetFrames
                startupGateActivationFrames = gatePolicy.activationBufferedFrames
            }

            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]
            var aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: aggregateDeviceOutputPlan == nil
                    ? "Notch Sixty Private Tap"
                    : "Notch Sixty Private Multi-Output",
                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceTapListKey: [tapEntry],
                // The session owns capture lifecycle explicitly through its IOProc.
                // Do not let the aggregate run the tap independently.
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            if let aggregateDeviceOutputPlan {
                let subdevices: [[String: Any]] = aggregateDeviceOutputPlan.orderedDeviceUIDs.map { uid in
                    [
                        kAudioSubDeviceUIDKey: uid,
                        kAudioSubDeviceDriftCompensationKey: uid != aggregateDeviceOutputPlan.referenceDeviceUID,
                    ]
                }
                aggregateDescription[kAudioAggregateDeviceSubDeviceListKey] = subdevices
                aggregateDescription[kAudioAggregateDeviceMainSubDeviceKey] = aggregateDeviceOutputPlan.referenceDeviceUID
            }
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: aggregateDeviceOutputPlan == nil
                    ? "create private tap aggregate device"
                    : "create private multi-output aggregate device"
            )
            if aggregateDeviceOutputPlan != nil {
                try Self.waitForDeviceAlive(aggregateDeviceID)
            }

            // Matched-rate sessions retain the original output-rate pinning.
            // For PR70 ASRC sessions the tap aggregate remains in the tap's native
            // clock domain so capture/output clocks are genuinely independent;
            // the adaptive bridge owns rate conversion and drift correction.
            try Self.writeFloat64Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                value: adaptiveSampleRateRequired ? tapFormat.sampleRate : outputFormat.sampleRate,
                operation: "set tap aggregate sample rate"
            )
            try Self.writeUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                value: outputBufferFrames,
                operation: "set tap aggregate buffer size"
            )
            let captureBufferFrames = try Self.readUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read tap aggregate buffer size"
            )
            guard captureBufferFrames == outputBufferFrames else {
                throw CoreAudioTransportError.captureBufferSizeMismatch(
                    capture: captureBufferFrames,
                    output: outputBufferFrames
                )
            }

            outputDeviceID = aggregateDeviceOutputPlan == nil ? selectedOutput.deviceID : aggregateDeviceID
            let clientData = UnsafeMutableRawPointer(newBridge)
            try Self.check(
                AudioDeviceCreateIOProcID(aggregateDeviceID, N60CaptureIOProc, clientData, &captureIOProcID),
                operation: "create capture IOProc"
            )
            try Self.check(
                AudioDeviceCreateIOProcID(outputDeviceID, N60OutputIOProc, clientData, &outputIOProcID),
                operation: "create output IOProc"
            )

            guard captureIOProcID != nil else {
                throw CoreAudioTransportError.ioProcUnavailable(role: "capture")
            }
            guard outputIOProcID != nil else {
                throw CoreAudioTransportError.ioProcUnavailable(role: "output")
            }

            N60RealtimeAudioBridgeSetOutputGain(newBridge, 1.0)
            N60RealtimeAudioBridgeSetTransitionGainImmediate(newBridge, 1.0)
            N60RealtimeAudioBridgeConfigureOutputGate(
                newBridge,
                gateMinimumFrames,
                gatePolicy.fadeInFrames
            )
        } catch {
            stop(fadeOut: false)
            throw error
        }
    }

    deinit {
        stop(fadeOut: false)
    }

    /// Returns a PASSIVE witness only for this exact running physical output.
    /// An aggregate/multi-device route or stopped session cannot produce
    /// trusted PR97 clock acquisition evidence through the stereo path.
    func passiveFeedForwardOutputTimingSnapshot()
        -> N60FeedForwardOutputTimingSnapshot? {
        guard !stopped, isOutputStarted,
              aggregateDeviceOutputPlan == nil,
              outputDeviceID == selectedOutput.deviceID,
              let bridge else { return nil }
        let witness = N60RealtimeAudioBridgeGetFeedForwardOutputTimingSnapshot(bridge)
        guard witness.valid, witness.callbackCount > 0,
              witness.invalidCount == 0 else { return nil }
        return witness
    }

    func counters() -> AudioTransportCounters {
        guard let bridge else { return AudioTransportCounters() }
        var counters = AudioTransportCounters(snapshot: N60RealtimeAudioBridgeGetSnapshot(bridge))
        if let metrics = graphPublicationCoordinator?.snapshotMetrics() {
            counters.graphPublications = metrics.publications
            counters.graphPublicationFailures = metrics.failures
            counters.graphPublicationCoalescedUpdates = metrics.coalescedUpdates
            counters.graphTransitionsScheduled = metrics.transitionsScheduled
        }
        return counters
    }

    func setAnalysisDemand(_ demandMask: UInt32) {
        guard let bridge else { return }
        N60RealtimeAudioBridgeSetAnalysisDemand(bridge, demandMask)
        analysisWorker?.setDemand(demandMask, sampleRate: outputFormat.sampleRate)
    }

    func productionAnalysisSnapshot() -> ProductionAnalysisSnapshot {
        analysisWorker?.snapshot() ?? .empty
    }

    func resetSpectrumPeakHold() {
        analysisWorker?.resetSpectrumPeakHold()
    }

    func analysisCaptureSnapshot() -> N60AnalysisCaptureSnapshot? {
        guard let bridge else { return nil }
        return N60RealtimeAudioBridgeGetAnalysisCaptureSnapshot(bridge)
    }

    func setAmbientReferenceDemand(_ enabled: Bool) {
        guard let bridge else { return }
        N60RealtimeAudioBridgeSetAmbientReferenceDemand(
            bridge,
            enabled
        )
    }

    func ambientReferenceSnapshot()
        -> N60AmbientPlaybackReferenceSnapshot? {
        guard let bridge else { return nil }
        return N60RealtimeAudioBridgeGetAmbientReferenceSnapshot(
            bridge
        )
    }

    func discardAmbientReferenceFrames() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeDiscardAmbientReferenceFrames(
            bridge
        )
    }

    func readAmbientReferenceFrames(
        maximumFrames: Int =
            Int(N60_AMBIENT_REFERENCE_CAPACITY_FRAMES)
    ) -> [N60AmbientPlaybackReferenceFrame] {
        guard let bridge, maximumFrames > 0 else { return [] }
        let snapshot =
            N60RealtimeAudioBridgeGetAmbientReferenceSnapshot(
                bridge
            )
        let capacity = min(
            maximumFrames,
            Int(snapshot.availableFrames)
        )
        guard capacity > 0 else { return [] }

        var result = [N60AmbientPlaybackReferenceFrame](
            repeating: N60AmbientPlaybackReferenceFrame(),
            count: capacity
        )
        let count = result.withUnsafeMutableBufferPointer {
            N60RealtimeAudioBridgeReadAmbientReferenceFrames(
                bridge,
                $0.baseAddress!,
                UInt32($0.count)
            )
        }
        if Int(count) < result.count {
            result.removeLast(result.count - Int(count))
        }
        return result
    }

    /// E4 S22b1: speaker-drive recording for the feed-forward echo model.
    func setSpeakerDriveDemand(_ enabled: Bool) {
        guard let bridge else { return }
        N60RealtimeAudioBridgeSetSpeakerDriveDemand(bridge, enabled)
    }

    func speakerDriveSnapshot() -> N60SpeakerDriveSnapshot? {
        guard let bridge else { return nil }
        return N60RealtimeAudioBridgeGetSpeakerDriveSnapshot(bridge)
    }

    func readSpeakerDriveAnchors(maximum: Int = Int(N60_SPEAKER_DRIVE_ANCHOR_CAPACITY)) -> [N60SpeakerDriveAnchor] {
        guard let bridge, maximum > 0 else { return [] }
        var result = [N60SpeakerDriveAnchor](repeating: N60SpeakerDriveAnchor(), count: maximum)
        let count = result.withUnsafeMutableBufferPointer {
            N60RealtimeAudioBridgeReadSpeakerDriveAnchors(bridge, $0.baseAddress!, UInt32($0.count))
        }
        result.removeLast(result.count - Int(count))
        return result
    }

    func readSpeakerDriveFrames(maximumFrames: Int) -> [N60AmbientPlaybackReferenceFrame] {
        guard let bridge, maximumFrames > 0 else { return [] }
        var result = [N60AmbientPlaybackReferenceFrame](
            repeating: N60AmbientPlaybackReferenceFrame(), count: maximumFrames
        )
        let count = result.withUnsafeMutableBufferPointer {
            N60RealtimeAudioBridgeReadSpeakerDriveFrames(bridge, $0.baseAddress!, UInt32($0.count))
        }
        result.removeLast(result.count - Int(count))
        return result
    }

    var ambientReferenceSampleRate: Double {
        outputFormat.sampleRate
    }

    /// E4 S14: renews the anti-noise dead-man lease for `seconds` of output.
    func renewActiveQuietZoneLease(seconds: Double) {
        guard let bridge, seconds > 0 else { return }
        let frames = UInt64((outputFormat.sampleRate * seconds).rounded(.up))
        N60RealtimeAudioBridgeRenewActiveQuietZoneLease(bridge, frames)
    }

    /// E4 S15: number of live howl-guard trips on this session (0 when none).
    var howlGuardTripCount: UInt64 {
        guard let bridge else { return 0 }
        return N60RealtimeAudioBridgeHowlGuardTripCount(bridge)
    }

    /// E4 S25b: live feed-forward. Dark unless `feedForwardLiveFeatureEnabled`, which Swift sets from
    /// `e4.feedforward-live`. Nothing here arms: arming goes through FeedForwardLiveArmGate.
    var feedForwardLiveFeatureEnabled = false

    /// Control plane, IO stopped. No-op (false) while the feature is off.
    @discardableResult
    func attachFeedForwardLive(peakLimit: Double = 0.5) -> Bool {
        guard feedForwardLiveFeatureEnabled, let bridge, !isOutputStarted, !isCaptureStarted else { return false }
        return N60RealtimeAudioBridgeAttachFeedForwardLive(bridge, outputFormat.sampleRate, peakLimit)
    }

    func detachFeedForwardLive() {
        guard let bridge, !isOutputStarted, !isCaptureStarted else { return }
        N60RealtimeAudioBridgeDetachFeedForwardLive(bridge)
    }

    func setFeedForwardLiveWeights(left: [Float], right: [Float]) -> Bool {
        guard let bridge, !left.isEmpty, left.count == right.count else { return false }
        return N60RealtimeAudioBridgeSetFeedForwardLiveWeights(bridge, left, right, UInt32(left.count))
    }

    /// Returns the N60FeedForwardLiveArm* code; nil when the gate refuses or the feature is off.
    func armFeedForwardLive(gate: FeedForwardLiveArmGate.Inputs) -> UInt32? {
        guard feedForwardLiveFeatureEnabled, let bridge, FeedForwardLiveArmGate.decide(gate).isAllowed
        else { return nil }
        return N60RealtimeAudioBridgeArmFeedForwardLive(bridge, gate.leadSeconds, gate.requiredLeadSeconds)
    }

    func disarmFeedForwardLive() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeDisarmFeedForwardLive(bridge)
    }

    func markFeedForwardLiveReferenceLost() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeMarkFeedForwardLiveReferenceLost(bridge)
    }

    func feedForwardLiveStatus() -> N60RenderKernelFeedForwardLiveStatus? {
        guard let bridge else { return nil }
        return N60RealtimeAudioBridgeGetFeedForwardLiveStatus(bridge)
    }

    /// Returns the next output index expected; the caller (the reference pump) places samples by it.
    func pushFeedForwardLiveReference(startIndex: UInt64, samples: [Float]) -> UInt64? {
        guard let bridge, !samples.isEmpty else { return nil }
        return N60RealtimeAudioBridgePushFeedForwardLiveReference(
            bridge, startIndex, samples, UInt32(samples.count)
        )
    }

    /// E4 S15: clears a latched trip so the anti-noise can fade back in. Called when arming.
    func rearmHowlGuard() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeRearmHowlGuard(bridge)
    }

    /// E4 S18b: publishes one adaptive gain record to the render thread's mailbox (single writer:
    /// the adaptive worker). Returns the assigned sequence, 0 when rejected outright.
    @discardableResult
    func publishActiveQuietZoneGainRecord(_ record: N60ActiveQuietZoneGainRecord) -> UInt64 {
        guard let bridge else { return 0 }
        var copy = record
        return N60RealtimeAudioBridgePublishActiveQuietZoneGainRecord(bridge, &copy)
    }

    /// E4 S18b: pops the oldest phase-anchor telemetry record (single consumer: the worker).
    func popActiveQuietZoneTelemetry() -> N60ActiveQuietZoneTelemetryRecord? {
        guard let bridge else { return nil }
        var record = N60ActiveQuietZoneTelemetryRecord()
        return N60RealtimeAudioBridgePopActiveQuietZoneTelemetry(bridge, &record) ? record : nil
    }

    var activeQuietZoneMailboxStats: N60ActiveQuietZoneMailboxStats {
        guard let bridge else { return N60ActiveQuietZoneMailboxStats() }
        return N60RealtimeAudioBridgeActiveQuietZoneMailboxStats(bridge)
    }

    /// E4 S18b: latches the 20 ms anti-noise fade as a howl trip (any thread).
    func requestHowlTrip() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeRequestHowlTrip(bridge)
    }

    func releaseActiveQuietZoneLease() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeReleaseActiveQuietZoneLease(bridge)
    }

    func setActiveQuietZoneReferenceDemand(_ enabled: Bool) {
        guard let bridge else { return }
        N60RealtimeAudioBridgeSetActiveQuietZoneReferenceDemand(
            bridge,
            enabled
        )
    }

    func activeQuietZoneReferenceSnapshot()
        -> N60ActiveQuietZoneReferenceSnapshot? {
        guard let bridge else { return nil }
        return N60RealtimeAudioBridgeGetActiveQuietZoneReferenceSnapshot(
            bridge
        )
    }

    func discardActiveQuietZoneReferenceFrames() {
        guard let bridge else { return }
        N60RealtimeAudioBridgeDiscardActiveQuietZoneReferenceFrames(
            bridge
        )
    }

    func readActiveQuietZoneReferenceFrames(
        maximumFrames: Int =
            Int(N60_ACTIVE_QUIET_ZONE_REFERENCE_CAPACITY_FRAMES)
    ) -> [N60ActiveQuietZoneReferenceFrame] {
        guard let bridge, maximumFrames > 0 else { return [] }
        let snapshot =
            N60RealtimeAudioBridgeGetActiveQuietZoneReferenceSnapshot(
                bridge
            )
        let capacity = min(
            maximumFrames,
            Int(snapshot.availableFrames)
        )
        guard capacity > 0 else { return [] }

        var result = [N60ActiveQuietZoneReferenceFrame](
            repeating: N60ActiveQuietZoneReferenceFrame(),
            count: capacity
        )
        let count = result.withUnsafeMutableBufferPointer {
            N60RealtimeAudioBridgeReadActiveQuietZoneReferenceFrames(
                bridge,
                $0.baseAddress!,
                UInt32($0.count)
            )
        }
        if Int(count) < result.count {
            result.removeLast(result.count - Int(count))
        }
        return result
    }

    var activeQuietZoneReferenceSampleRate: Double {
        outputFormat.sampleRate
    }

    func renderDiagnostics() -> RenderKernelDiagnostics? {
        guard let bridge else { return nil }
        var raw = N60RealtimeAudioBridgeGetRenderDiagnostics(bridge)
        // E6 S8: while libn60core renders, meters and latency come from the graph.
        if let host = unifiedGraphReadback {
            host.overlayStereoReadbacks(
                &raw,
                latencyFrames: host.latencyFrames &- min(host.latencyFrames, unifiedGraphLaneTapFrames),
                includeOutput: !N60RealtimeAudioBridgeOutputVUMeterDemand()
            )
        }
        return RenderKernelDiagnostics(raw)
    }

    private func retainProgram(
        _ kind: UnifiedGraphProgramKind, info: N60ConvolutionProgramInfo,
        left: [Float], right: [Float]?, declaredLatencyFrames: UInt32
    ) {
        retainedProgramsLock.lock(); defer { retainedProgramsLock.unlock() }
        guard info.tapCount <= 32_768 else { return }
        var forKind = retainedPrograms[kind] ?? [:]
        forKind[info.generation] = UnifiedGraphFIRProgram(
            generation: info.generation, left: left, right: right, declaredLatencyFrames: declaredLatencyFrames
        )
        while forKind.count > 4, let oldest = forKind.keys.min() { forKind[oldest] = nil }
        retainedPrograms[kind] = forKind
    }

    private func retainedProgram(_ kind: UnifiedGraphProgramKind, generation: UInt64) -> UnifiedGraphFIRProgram? {
        retainedProgramsLock.lock(); defer { retainedProgramsLock.unlock() }
        return retainedPrograms[kind]?[generation]
    }

    func prepareConvolutionProgram(
        slot: UInt32,
        leftTaps: [Float],
        rightTaps: [Float]? = nil,
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        guard let bridge, !leftTaps.isEmpty else {
            throw CoreAudioTransportError.convolutionProgramPreparationFailed
        }
        guard graphPublicationCoordinator?.canPrepareProgram() ?? true else {
            throw CoreAudioTransportError.convolutionProgramPreparationFailed
        }
        guard rightTaps == nil || rightTaps?.count == leftTaps.count else {
            throw CoreAudioTransportError.convolutionProgramPreparationFailed
        }

        var info = N60ConvolutionProgramInfo()
        let prepared = leftTaps.withUnsafeBufferPointer { leftBuffer in
            if let rightTaps {
                return rightTaps.withUnsafeBufferPointer { rightBuffer in
                    N60RealtimeAudioBridgePrepareConvolutionProgram(
                        bridge,
                        slot,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        UInt32(leftBuffer.count),
                        declaredLatencyFrames,
                        &info
                    )
                }
            }
            return N60RealtimeAudioBridgePrepareConvolutionProgram(
                bridge,
                slot,
                leftBuffer.baseAddress!,
                nil,
                UInt32(leftBuffer.count),
                declaredLatencyFrames,
                &info
            )
        }
        guard prepared else { throw CoreAudioTransportError.convolutionProgramPreparationFailed }
        retainProgram(.convolution, info: info, left: leftTaps, right: rightTaps, declaredLatencyFrames: declaredLatencyFrames)
        return info
    }

    func prepareConvolutionProgram(
        slot: UInt32,
        taps: [Float],
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        try prepareConvolutionProgram(
            slot: slot,
            leftTaps: taps,
            rightTaps: nil,
            declaredLatencyFrames: declaredLatencyFrames
        )
    }

    func prepareRoomCorrectionProgram(
        slot: UInt32,
        leftTaps: [Float],
        rightTaps: [Float]? = nil,
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        guard let bridge, !leftTaps.isEmpty else {
            throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed
        }
        guard graphPublicationCoordinator?.canPrepareProgram() ?? true else {
            throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed
        }
        guard rightTaps == nil || rightTaps?.count == leftTaps.count else {
            throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed
        }

        var info = N60ConvolutionProgramInfo()
        let prepared = leftTaps.withUnsafeBufferPointer { leftBuffer in
            if let rightTaps {
                return rightTaps.withUnsafeBufferPointer { rightBuffer in
                    N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
                        bridge,
                        slot,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        UInt32(leftBuffer.count),
                        declaredLatencyFrames,
                        &info
                    )
                }
            }
            return N60RealtimeAudioBridgePrepareRoomCorrectionProgram(
                bridge,
                slot,
                leftBuffer.baseAddress!,
                nil,
                UInt32(leftBuffer.count),
                declaredLatencyFrames,
                &info
            )
        }
        guard prepared else { throw CoreAudioTransportError.roomCorrectionProgramPreparationFailed }
        retainProgram(.roomCorrection, info: info, left: leftTaps, right: rightTaps, declaredLatencyFrames: declaredLatencyFrames)
        return info
    }

    func prepareSpeakerIRProgram(
        slot: UInt32,
        leftTaps: [Float],
        rightTaps: [Float]? = nil,
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        guard let bridge, !leftTaps.isEmpty else {
            throw CoreAudioTransportError.speakerIRProgramPreparationFailed
        }
        guard graphPublicationCoordinator?.canPrepareProgram() ?? true else {
            throw CoreAudioTransportError.speakerIRProgramPreparationFailed
        }
        guard rightTaps == nil || rightTaps?.count == leftTaps.count else {
            throw CoreAudioTransportError.speakerIRProgramPreparationFailed
        }

        var info = N60ConvolutionProgramInfo()
        let prepared = leftTaps.withUnsafeBufferPointer { leftBuffer in
            if let rightTaps {
                return rightTaps.withUnsafeBufferPointer { rightBuffer in
                    N60RealtimeAudioBridgePrepareSpeakerIRProgram(
                        bridge,
                        slot,
                        leftBuffer.baseAddress!,
                        rightBuffer.baseAddress!,
                        UInt32(leftBuffer.count),
                        declaredLatencyFrames,
                        &info
                    )
                }
            }
            return N60RealtimeAudioBridgePrepareSpeakerIRProgram(
                bridge,
                slot,
                leftBuffer.baseAddress!,
                nil,
                UInt32(leftBuffer.count),
                declaredLatencyFrames,
                &info
            )
        }
        guard prepared else { throw CoreAudioTransportError.speakerIRProgramPreparationFailed }
        retainProgram(.speakerIR, info: info, left: leftTaps, right: rightTaps, declaredLatencyFrames: declaredLatencyFrames)
        return info
    }

    func configureHeadphoneDSP(
        _ snapshot: N60HeadphoneDSPSnapshot?, profile: HeadphoneDeviceProfileConfiguration? = nil
    ) throws {
        guard let bridge, !isOutputStarted, !isCaptureStarted else {
            throw CoreAudioTransportError.headphoneDSPConfigurationFailed
        }
        if let snapshot {
            guard N60RealtimeAudioBridgeConfigureHeadphoneDSP(bridge, snapshot) else {
                throw CoreAudioTransportError.headphoneDSPConfigurationFailed
            }
        } else {
            N60RealtimeAudioBridgeClearHeadphoneDSP(bridge)
        }
        headphoneDSPConfigured = snapshot != nil
        headphoneProfile = snapshot != nil ? profile : nil
        kernelHeadphoneProfile = headphoneProfile
        // IO is stopped here, so the callback cannot be mid-hand-over; the next publish
        // re-evaluates eligibility, and until then the kernel (which has the headphone DSP) renders.
        if headphoneDSPConfigured { detachUnifiedGraph() }
    }

    /// E12 S4a: the generator stage the next graph build includes (nil for normal playback). Session-scoped, so a
    /// restart or an output change starts without it.
    private var liveGenerator: (params: [Float], laneMask: UInt64?)?

    /// E12 S4a. Control thread. Adds (or with nil, removes) the generator stage on the running stereo graph and
    /// republishes it as posted parameters or a faded rebuild. Throws, leaving the stage state as it was, when the
    /// session renders on the kernel or the graph refuses; the kernel never plays the generator.
    func setLiveGenerator(_ settings: SignalGeneratorSettings?, laneMask: UInt64?) throws {
        guard let settings else {
            guard liveGenerator != nil else { return }
            liveGenerator = nil
            // A refusal here hands rendering to the kernel, which has no generator, so the noise stops either way.
            if let snapshot = lastGraphSnapshot { refreshUnifiedGraph(for: snapshot) }
            return
        }
        guard unifiedGraphEnabled, unifiedGraphActive, let snapshot = lastGraphSnapshot,
              let params = settings.stageParams(active: true, sampleRate: outputFormat.sampleRate) else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        liveGenerator = (params, laneMask)
        guard refreshUnifiedGraph(for: snapshot), unifiedGraphActive else {
            // The refusal already cleared the stage; rebuild the graph without it so rendering returns to the graph.
            liveGenerator = nil
            if let snapshot = lastGraphSnapshot { refreshUnifiedGraph(for: snapshot) }
            throw LiveNChannelTransportError.unifiedGraphRejected(unifiedGraphFallbackReason ?? .specRejected)
        }
    }

    /// Whether the plain-stereo callback is currently rendering through libn60core.
    var unifiedGraphActive: Bool {
        guard let bridge else { return false }
        return N60RealtimeAudioBridgeUnifiedGraphActive(bridge)
    }

    /// True while the graph renders a stereo session whose headphone profile it applies (E6 S9d).
    var headphoneGraphActive: Bool { headphoneProfile != nil && unifiedGraphActive }

    /// True when the kernel's headphone stage holds an older profile than the graph (after a live edit), so a
    /// fall-back to the kernel would render the wrong correction.
    private var kernelHeadphoneStale: Bool { headphoneProfile != kernelHeadphoneProfile }

    /// E6 S9d. Control thread. A live headphone profile edit on a graph-rendered stereo session: the HEADPHONE and
    /// ear delay stages are rebuilt from `profile` and applied as posted parameters (or a faded rebuild). Any
    /// refusal leaves the running graph and the stored profile as they were.
    func applyLiveHeadphoneProfile(_ profile: HeadphoneDeviceProfileConfiguration) throws {
        guard headphoneGraphActive, let snapshot = lastGraphSnapshot else {
            throw LiveNChannelTransportError.configurationChangeRequiresRestart
        }
        // Stored state changes only once the graph accepted the profile.
        if !refreshUnifiedGraph(for: snapshot, headphone: profile) {
            throw LiveNChannelTransportError.unifiedGraphRejected(unifiedGraphFallbackReason ?? .specRejected)
        }
    }

    /// The live graph host, for metering and latency readbacks (nil while the kernel renders).
    var unifiedGraphReadback: UnifiedGraphHost? { unifiedGraphActive ? unifiedGraphHost : nil }

    /// Control thread. Builds or updates the core graph for `snapshot` and attaches it, or
    /// detaches it so the kernel renders. Any failure falls back to the kernel.
    @discardableResult
    private func refreshUnifiedGraph(
        for snapshot: N60DSPGraphSnapshot, headphone candidate: HeadphoneDeviceProfileConfiguration? = nil
    ) -> Bool {
        guard let bridge else { return false }
        lastGraphSnapshot = snapshot
        unifiedGraphFallbackReason = nil
        // A refusal normally hands rendering to the kernel. After a live headphone edit the kernel holds the older
        // correction, so the running graph stays instead and the caller sees the refusal (E6 S9d).
        let profile = candidate ?? headphoneProfile
        let kernelWouldBeWrong = kernelHeadphoneStale || (headphoneDSPConfigured && profile != kernelHeadphoneProfile)
        func refuse(_ reason: UnifiedGraphFallbackReason) -> Bool {
            unifiedGraphFallbackReason = reason
            // The kernel never plays the generator, so a refusal ends the noise instead of leaving stale state.
            liveGenerator = nil
            if !(kernelWouldBeWrong && N60RealtimeAudioBridgeUnifiedGraphActive(bridge)) { detachUnifiedGraph() }
            return false
        }
        guard unifiedGraphEnabled else {
            if kernelWouldBeWrong { return false }
            detachUnifiedGraph()
            return true
        }
        // E6 S8e: same-device, aggregate and AU rack routes render through the graph too (the rack as its
        // EXTERNAL stage, the speaker-bus split in the bridge). A stereo headphone profile is the HEADPHONE stage
        // and ear delays (E6 S9d); one the stage cannot reproduce, or a kernel-only headphone setup, keeps the kernel.
        if headphoneDSPConfigured, headphoneProfile == nil { return refuse(.headphoneDSP) }
        var mutable = snapshot
        var configuration: UnifiedGraphConfiguration
        switch UnifiedGraphTranslator.stereoEligibility(
            snapshot: &mutable, sampleRate: outputFormat.sampleRate,
            programs: { [self] kind, generation in retainedProgram(kind, generation: generation) }
        ) {
        case .success(let accepted): configuration = accepted
        case .failure(let reason):
            return refuse(reason)
        }
        if let liveGenerator {
            configuration.generatorParams = liveGenerator.params
            configuration.generatorLaneMask = liveGenerator.laneMask
        }
        guard var spec = try? configuration.makeSpec() else { return refuse(.specRejected) }
        var earDelayFrames: [UInt32] = [0, 0]
        if headphoneDSPConfigured, let profile {
            switch UnifiedGraphTranslator.stereoApplyHeadphone(spec: spec, profile: profile) {
            case .failure(let reason): return refuse(reason)
            case .success(let applied):
                spec = applied.spec
                earDelayFrames = applied.earDelayFrames
            }
        }
        if let audioUnitRack {
            spec = spec.insertingExternalRackStage(latencyFrames: UInt32(clamping: max(audioUnitRack.latencyFrames, 0)))
        }
        do {
            if let host = unifiedGraphHost {
                try host.apply(spec)
            } else {
                unifiedGraphHost = try UnifiedGraphHost(spec: spec)
            }
            guard let host = unifiedGraphHost, let raw = host.rawGraph else { return true }
            // E6 S8e: the graph's EXTERNAL stage calls this transport's AU rack (once per graph; the graph
            // is attached only after this succeeds).
            if audioUnitRack != nil, rackBoundGraph != raw {
                guard N60RealtimeAudioBridgeBindRackToGraph(bridge, raw) else {
                    return refuse(.attachFailed)
                }
                rackBoundGraph = raw
            }
            // E6 S8b2c: the bridge aligns the kernel and graph paths across the hand-over fade
            // by the difference between this and the kernel snapshot's latency.
            // The integer inter-channel taps are applied per lane by both paths and are not part
            // of the kernel's reported latency, so they are removed from the graph's readback (the
            // eligible stereo setup has one tap pair, so the larger of the two is the lane offset).
            // Published before the attach so the callback never fades with a stale value.
            // The ear delays are likewise applied by the kernel's headphone stage and left out of its latency.
            let taps = configuration.lanes.enumerated().map { index, lane in
                lane.interChannelTapFrames &+ (index < earDelayFrames.count ? earDelayFrames[index] : 0)
            }.max() ?? 0
            unifiedGraphLaneTapFrames = taps
            N60RealtimeAudioBridgeSetUnifiedGraphLatency(bridge, host.latencyFrames &- min(host.latencyFrames, taps))
            if !N60RealtimeAudioBridgeUnifiedGraphActive(bridge) {
                guard N60RealtimeAudioBridgeSetUnifiedGraph(bridge, raw, spec.maxBlockFrames, spec.sampleRate) else {
                    return refuse(.attachFailed)
                }
            }
            unifiedGraphHost?.collect()
            if let candidate { headphoneProfile = candidate }
            return true
        } catch {
            return refuse(unifiedGraphHost == nil ? .graphBuildFailed : .specRejected)
        }
    }

    private func detachUnifiedGraph() {
        unifiedGraphLaneTapFrames = 0
        if let bridge, N60RealtimeAudioBridgeUnifiedGraphActive(bridge) {
            _ = N60RealtimeAudioBridgeSetUnifiedGraph(bridge, nil, 0, 0)
        }
    }


    func publishDSPGraph(_ snapshot: N60DSPGraphSnapshot) throws {
        guard let bridge else { throw CoreAudioTransportError.dspGraphPublicationFailed }
        if !refreshUnifiedGraph(for: snapshot), kernelHeadphoneStale {
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }
        if !isOutputStarted || !isCaptureStarted {
            // E4 S15: IO is stopped, so the howl guard can be created here. Always on; the guard
            // does nothing while no anti-noise plays.
            // Only when neither side runs: Attach swaps the guards, and a started output IOProc
            // may be rendering. The first publish of a session always happens fully stopped.
            if !isOutputStarted && !isCaptureStarted,
               !N60RealtimeAudioBridgeAttachHowlGuard(bridge, outputFormat.sampleRate) {
                throw CoreAudioTransportError.dspGraphPublicationFailed
            }
            // E4 S25b: the live feed-forward filter, only behind its flag. Attached idle: it plays
            // nothing until the gated Arm.
            if !isOutputStarted && !isCaptureStarted, feedForwardLiveFeatureEnabled,
               !N60RealtimeAudioBridgeAttachFeedForwardLive(bridge, outputFormat.sampleRate, 0.5) {
                throw CoreAudioTransportError.dspGraphPublicationFailed
            }
            guard N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot) else {
                throw CoreAudioTransportError.dspGraphPublicationFailed
            }
            try startIO()
            return
        }
        guard let graphPublicationCoordinator else {
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }
        graphPublicationCoordinator.enqueuePublish(snapshot)
    }

    func transitionDSPGraph(_ snapshot: N60DSPGraphSnapshot) throws {
        guard bridge != nil else { throw CoreAudioTransportError.dspGraphPublicationFailed }
        if !refreshUnifiedGraph(for: snapshot), kernelHeadphoneStale {
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }

        if !isOutputStarted || !isCaptureStarted {
            try publishDSPGraph(snapshot)
            return
        }

        guard let graphPublicationCoordinator else {
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }
        graphPublicationCoordinator.enqueueTransition(
            snapshot,
            fadeFrames: graphTransitionFadeFrames()
        )
    }

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true
        graphPublicationCoordinator?.stop()
        analysisWorker?.stop()
        analysisWorker = nil

        // Teardown remains synchronous so Core Audio cannot call through a freed
        // bridge. If output has opened, wait for the audio callback to report that
        // the sample-domain fade actually reached zero rather than sleeping for
        // its nominal duration. The bounded timeout prevents teardown deadlock if
        // the device stops delivering callbacks unexpectedly.
        if fadeOut, let bridge, isOutputStarted {
            let initialState = N60RealtimeAudioBridgeGetSnapshot(bridge)
            if initialState.outputGateOpen {
                N60RealtimeAudioBridgeRampTransitionGain(
                    bridge,
                    0.0,
                    graphTransitionFadeFrames()
                )
                var waitedMicroseconds: UInt32 = 0
                while waitedMicroseconds < Self.shutdownFadeTimeoutMicroseconds {
                    let state = N60RealtimeAudioBridgeGetSnapshot(bridge)
                    if state.transitionFramesRemaining == 0, state.transitionGain <= 0.000_001 {
                        break
                    }
                    usleep(Self.shutdownFadePollMicroseconds)
                    waitedMicroseconds &+= Self.shutdownFadePollMicroseconds
                }
            }
        }

        if isOutputStarted, let outputIOProcID {
            AudioDeviceStop(outputDeviceID, outputIOProcID)
            isOutputStarted = false
        }
        if isCaptureStarted, let captureIOProcID, aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, captureIOProcID)
            isCaptureStarted = false
        }
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
        if let bridge {
            N60RealtimeAudioBridgeDestroy(bridge)
            self.bridge = nil
        }
        // The host outlives the bridge that rendered it; release it only after destroy.
        unifiedGraphHost?.release()
        unifiedGraphHost = nil
        rackBoundGraph = nil
        audioUnitRack = nil
        graphPublicationCoordinator = nil
    }

    private func graphTransitionFadeFrames() -> UInt32 {
        let fadeFramesDouble = max(outputFormat.sampleRate, 1)
            * Self.graphTransitionFadeMilliseconds / 1_000.0
        return UInt32(min(max(fadeFramesDouble.rounded(), 1), Double(UInt32.max)))
    }

    private func startIO() throws {
        guard !stopped else { throw CoreAudioTransportError.dspGraphPublicationFailed }
        if isOutputStarted && isCaptureStarted { return }

        guard let outputIOProcID else {
            throw CoreAudioTransportError.ioProcUnavailable(role: "output")
        }
        guard let captureIOProcID else {
            throw CoreAudioTransportError.ioProcUnavailable(role: "capture")
        }
        guard aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw CoreAudioTransportError.ioProcUnavailable(role: "capture")
        }

        if isCaptureStarted {
            AudioDeviceStop(aggregateDeviceID, captureIOProcID)
            isCaptureStarted = false
        }
        if isOutputStarted {
            AudioDeviceStop(outputDeviceID, outputIOProcID)
            isOutputStarted = false
        }

        try Self.check(
            AudioDeviceStart(outputDeviceID, outputIOProcID),
            operation: "start physical output"
        )
        isOutputStarted = true

        do {
            try Self.check(
                AudioDeviceStart(aggregateDeviceID, captureIOProcID),
                operation: "start tap capture"
            )
            isCaptureStarted = true
        } catch {
            AudioDeviceStop(outputDeviceID, outputIOProcID)
            isOutputStarted = false
            throw error
        }
    }

    private static func configureOutputMap(
        bridge: OpaquePointer,
        physicalChannelCount: UInt32,
        descriptors: [N60SpeakerOutputRouteDescriptor]
    ) throws {
        var outputMap = N60SameDeviceOutputMap()
        let compiled = descriptors.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return false }
            return N60SameDeviceOutputMapCompile(
                physicalChannelCount,
                baseAddress,
                UInt32(buffer.count),
                &outputMap
            )
        }
        guard compiled,
              N60RealtimeAudioBridgeConfigureSameDeviceOutputMap(bridge, outputMap) else {
            throw CoreAudioTransportError.sameDeviceOutputMapCompilationFailed
        }
    }

    private static func waitForDeviceAlive(_ deviceID: AudioDeviceID) throws {
        for _ in 0..<300 {
            let alive = try readUInt32Property(
                objectID: deviceID,
                selector: kAudioDevicePropertyDeviceIsAlive,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read aggregate device readiness"
            )
            if alive != 0 { return }
            usleep(10_000)
        }
        throw CoreAudioTransportError.aggregateDeviceNotReady
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
        try check(status, operation: "translate PID to process object")
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
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        address.mScope = scope
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

final class AudioHardwareEventMonitor {
    var onDeviceListChanged: (() -> Void)?
    var onSelectedOutputSampleRateChanged: (() -> Void)?
    var onWillSleep: (() -> Void)?
    var onDidWake: (() -> Void)?

    private var deviceListListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var monitoredOutputDeviceID: AudioDeviceID?
    private var notificationTokens: [NSObjectProtocol] = []

    func start() throws {
        try installDeviceListListener()
        installPowerNotifications()
    }

    func monitorSampleRate(of deviceID: AudioDeviceID?) throws {
        removeSelectedOutputSampleRateMonitor()
        guard let deviceID else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onSelectedOutputSampleRateChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            listener
        )
        guard status == noErr else {
            throw CoreAudioTransportError.operationFailed(
                operation: "install sample-rate listener",
                status: status
            )
        }
        monitoredOutputDeviceID = deviceID
        sampleRateListener = listener
    }

    func removeSelectedOutputSampleRateMonitor() {
        guard let deviceID = monitoredOutputDeviceID, let sampleRateListener else {
            monitoredOutputDeviceID = nil
            self.sampleRateListener = nil
            return
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            deviceID,
            &address,
            DispatchQueue.main,
            sampleRateListener
        )
        monitoredOutputDeviceID = nil
        self.sampleRateListener = nil
    }

    func stop() {
        removeSelectedOutputSampleRateMonitor()
        if let deviceListListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                deviceListListener
            )
            self.deviceListListener = nil
        }
        for token in notificationTokens {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
        }
        notificationTokens.removeAll()
    }

    deinit {
        stop()
    }

    private func installDeviceListListener() throws {
        guard deviceListListener == nil else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.onDeviceListChanged?()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            listener
        )
        guard status == noErr else {
            throw CoreAudioTransportError.operationFailed(
                operation: "install device-list listener",
                status: status
            )
        }
        deviceListListener = listener
    }

    private func installPowerNotifications() {
        guard notificationTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onWillSleep?()
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.onDidWake?()
            }
        )
    }
}
