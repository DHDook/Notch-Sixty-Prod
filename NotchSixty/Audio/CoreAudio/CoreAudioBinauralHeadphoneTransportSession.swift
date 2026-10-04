import CoreAudio
import Foundation

enum BinauralHeadphoneTransportError: Error, Equatable, LocalizedError {
    case programChannelCountMismatch(tap: UInt32, expected: UInt32)
    case programLayoutMismatch
    case outputMustBeStereo(UInt32)
    case sampleRateMismatch(source: Double, output: Double)
    case bridgeAllocationFailed
    case protectionConfigurationFailed
    case ioProcUnavailable(role: String)
    case outputBufferExceedsBridgeCapacity(bufferFrames: UInt32, capacityFrames: UInt32)
    case captureBufferSizeMismatch(capture: UInt32, output: UInt32)
    case headTrackingGenerationFailed

    var errorDescription: String? {
        switch self {
        case .programChannelCountMismatch(let tap, let expected):
            return "Virtual Speakers captured \(tap) program channels but the selected layout expects \(expected)."
        case .programLayoutMismatch:
            return "The Virtual Speakers program source does not expose the semantic channel roles required by the selected layout."
        case .outputMustBeStereo(let channels):
            return "Virtual Speakers requires a two-channel headphone output; the selected output exposes \(channels) channels."
        case .sampleRateMismatch(let source, let output):
            return "Virtual Speakers requires native-rate program and headphone endpoints; source is \(source) Hz and output is \(output) Hz."
        case .bridgeAllocationFailed:
            return "Unable to prepare the realtime binaural/headphone renderer."
        case .protectionConfigurationFailed:
            return "Unable to configure the downstream headphone true-peak limiter."
        case .ioProcUnavailable(let role):
            return "Core Audio did not return a usable Virtual Speakers \(role) callback."
        case .outputBufferExceedsBridgeCapacity(let frames, let capacity):
            return "Virtual Speakers startup requires \(frames) buffered frames but bridge capacity is \(capacity)."
        case .captureBufferSizeMismatch(let capture, let output):
            return "Virtual Speakers capture quantum is \(capture) frames; headphone output quantum is \(output) frames."
        case .headTrackingGenerationFailed:
            return "Unable to prepare the next head-tracked binaural renderer generation."
        }
    }
}

/// Full-duplex owner for semantic decoded PCM -> PR57 binaural -> PR56 headphone
/// correction -> dedicated protection -> physical stereo headphones.
///
/// The program source may differ from the headphone output. That distinction is
/// required for true 5.1/7.1.4 virtualization because channels already discarded
/// by an upstream stereo mix cannot be reconstructed at the headphone endpoint.
final class CoreAudioBinauralHeadphoneTransportSession {
    private static let bridgeCapacityFrames: UInt32 = 65_536

    let selectedOutput: AudioOutputDevice
    let programSource: AudioOutputDevice
    let programLayout: OutputProgramLayout
    private(set) var tapFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var outputFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var startupGateTargetFrames: UInt32 = 0
    private(set) var startupGateActivationFrames: UInt32 = 0

    var startupGateOpened: Bool {
        guard let bridge else { return false }
        return N60BinauralHeadphoneBridgeGetSnapshot(bridge).outputGateOpen
    }

    var algorithmicLatencyFrames: UInt64 {
        guard let bridge else { return 0 }
        return N60BinauralHeadphoneBridgeGetSnapshot(bridge).algorithmicLatencyFrames
    }

    private var bridge: UnsafeMutablePointer<N60BinauralHeadphoneBridge>?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var captureIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var isCaptureStarted = false
    private var isOutputStarted = false
    private var stopped = false

    init(
        selectedOutput: AudioOutputDevice,
        programSource: AudioOutputDevice,
        programLayout: OutputProgramLayout,
        preparedProfile: PreparedBinauralProfile,
        headphoneSnapshot: N60HeadphoneDSPSnapshot,
        programGain: Float,
        outputGain: Float
    ) throws {
        self.selectedOutput = selectedOutput
        self.programSource = programSource
        self.programLayout = programLayout

        do {
            let processObject = try CoreAudioSemanticTransportSupport.currentProcessObjectID(
                operationPrefix: "Virtual Speakers"
            )
            let description = CATapDescription(
                excludingProcesses: [processObject],
                deviceUID: programSource.uid,
                stream: 0
            )
            description.name = "Notch Sixty Virtual Speakers Program"
            description.isPrivate = true
            description.muteBehavior = .mutedWhenTapped
            description.isMixdown = false
            description.isMono = false

            try CoreAudioSemanticTransportSupport.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "create Virtual Speakers program tap"
            )

            let tapASBD = try CoreAudioSemanticTransportSupport.readStreamFormat(
                objectID: tapID,
                selector: kAudioTapPropertyFormat,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read Virtual Speakers tap format"
            )
            let outputASBD = try CoreAudioSemanticTransportSupport.readStreamFormat(
                objectID: selectedOutput.deviceID,
                selector: kAudioDevicePropertyStreamFormat,
                scope: kAudioDevicePropertyScopeOutput,
                operation: "read headphone output format"
            )
            tapFormat = AudioStreamFormatDescription(tapASBD)
            outputFormat = AudioStreamFormatDescription(outputASBD)

            guard tapFormat.isSupportedFloat32TransportFormat else {
                throw CoreAudioTransportError.unsupportedFormat(
                    role: "Virtual Speakers program tap",
                    format: tapFormat
                )
            }
            guard outputFormat.isSupportedStereoTransportFormat else {
                throw BinauralHeadphoneTransportError.outputMustBeStereo(
                    outputFormat.channelCount
                )
            }
            let expectedChannels = UInt32(programLayout.roles.count)
            guard tapFormat.channelCount == expectedChannels else {
                throw BinauralHeadphoneTransportError.programChannelCountMismatch(
                    tap: tapFormat.channelCount,
                    expected: expectedChannels
                )
            }
            guard abs(tapFormat.sampleRate - outputFormat.sampleRate) < 0.5 else {
                throw BinauralHeadphoneTransportError.sampleRateMismatch(
                    source: tapFormat.sampleRate,
                    output: outputFormat.sampleRate
                )
            }
            guard abs(preparedProfile.descriptor.sampleRate - outputFormat.sampleRate) < 0.5,
                  preparedProfile.descriptor.programLayout.channelCount == expectedChannels else {
                throw BinauralHeadphoneTransportError.programLayoutMismatch
            }

            let descriptions = try CoreAudioSemanticTransportSupport.resolveInputChannelDescriptions(
                deviceID: programSource.deviceID,
                channelCount: tapFormat.channelCount
            )
            var inputMap = N60ProgramInputMap()
            let mapped = descriptions.withUnsafeBufferPointer { buffer in
                N60ProgramInputMapCompile(
                    buffer.baseAddress!,
                    UInt32(buffer.count),
                    preparedProfile.descriptor.programLayout,
                    &inputMap
                )
            }
            guard mapped else {
                throw BinauralHeadphoneTransportError.programLayoutMismatch
            }

            let outputBufferFrames = try CoreAudioSemanticTransportSupport.readUInt32Property(
                objectID: selectedOutput.deviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read Virtual Speakers headphone buffer size"
            )
            let gatePolicy = AudioStartupGatePolicy(
                outputBufferFrames: outputBufferFrames,
                sampleRate: outputFormat.sampleRate
            )
            guard gatePolicy.activationBufferedFrames <= Self.bridgeCapacityFrames else {
                throw BinauralHeadphoneTransportError.outputBufferExceedsBridgeCapacity(
                    bufferFrames: gatePolicy.activationBufferedFrames,
                    capacityFrames: Self.bridgeCapacityFrames
                )
            }
            startupGateTargetFrames = gatePolicy.steadyStateTargetFrames
            startupGateActivationFrames = gatePolicy.activationBufferedFrames

            var protection = N60ProtectionSnapshotMakeBypassed(outputFormat.sampleRate)
            guard N60ProtectionSnapshotSetOversamplingFactor(
                    &protection,
                    N60OversamplingFactor4x
                  ),
                  N60ProtectionSnapshotSetLimiterAdvanced(
                    &protection,
                    true,
                    -1.0,
                    0.5,
                    90.0,
                    2.0,
                    true
                  ),
                  N60ProtectionSnapshotIsValid(&protection) else {
                throw BinauralHeadphoneTransportError.protectionConfigurationFailed
            }

            let newBridge: UnsafeMutablePointer<N60BinauralHeadphoneBridge>? =
                preparedProfile.leftIRs.withUnsafeBufferPointer { left in
                    preparedProfile.rightIRs.withUnsafeBufferPointer { right in
                        N60BinauralHeadphoneBridgeCreate(
                            Self.bridgeCapacityFrames,
                            inputMap,
                            preparedProfile.descriptor,
                            left.baseAddress!,
                            right.baseAddress!,
                            headphoneSnapshot,
                            protection,
                            programGain,
                            gatePolicy.activationBufferedFrames,
                            gatePolicy.fadeInFrames
                        )
                    }
                }
            guard let newBridge else {
                throw BinauralHeadphoneTransportError.bridgeAllocationFailed
            }
            bridge = newBridge
            N60BinauralHeadphoneBridgeSetOutputGain(newBridge, outputGain)

            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Notch Sixty Virtual Speakers Tap",
                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.binaural.\(UUID().uuidString)",
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            try CoreAudioSemanticTransportSupport.check(
                AudioHardwareCreateAggregateDevice(
                    aggregateDescription as CFDictionary,
                    &aggregateDeviceID
                ),
                operation: "create Virtual Speakers tap aggregate"
            )
            try CoreAudioSemanticTransportSupport.waitForDeviceAlive(
                aggregateDeviceID,
                operationPrefix: "Virtual Speakers"
            )
            try CoreAudioSemanticTransportSupport.writeFloat64Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyNominalSampleRate,
                scope: kAudioObjectPropertyScopeGlobal,
                value: outputFormat.sampleRate,
                operation: "set Virtual Speakers aggregate sample rate"
            )
            try CoreAudioSemanticTransportSupport.writeUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                value: outputBufferFrames,
                operation: "set Virtual Speakers aggregate buffer size"
            )
            let captureBufferFrames = try CoreAudioSemanticTransportSupport.readUInt32Property(
                objectID: aggregateDeviceID,
                selector: kAudioDevicePropertyBufferFrameSize,
                scope: kAudioObjectPropertyScopeGlobal,
                operation: "read Virtual Speakers aggregate buffer size"
            )
            guard captureBufferFrames == outputBufferFrames else {
                throw BinauralHeadphoneTransportError.captureBufferSizeMismatch(
                    capture: captureBufferFrames,
                    output: outputBufferFrames
                )
            }

            let clientData = UnsafeMutableRawPointer(newBridge)
            try CoreAudioSemanticTransportSupport.check(
                AudioDeviceCreateIOProcID(
                    aggregateDeviceID,
                    N60BinauralHeadphoneCaptureIOProc,
                    clientData,
                    &captureIOProcID
                ),
                operation: "create Virtual Speakers capture IOProc"
            )
            try CoreAudioSemanticTransportSupport.check(
                AudioDeviceCreateIOProcID(
                    selectedOutput.deviceID,
                    N60BinauralHeadphoneOutputIOProc,
                    clientData,
                    &outputIOProcID
                ),
                operation: "create Virtual Speakers headphone IOProc"
            )
            guard captureIOProcID != nil else {
                throw BinauralHeadphoneTransportError.ioProcUnavailable(role: "capture")
            }
            guard outputIOProcID != nil else {
                throw BinauralHeadphoneTransportError.ioProcUnavailable(role: "output")
            }
            try startIO()
        } catch {
            stop(fadeOut: false)
            throw error
        }
    }

    deinit { stop(fadeOut: false) }

    func setOutputGain(_ gain: Float) {
        N60BinauralHeadphoneBridgeSetOutputGain(bridge, gain)
    }

    func setDetailedMeteringDemand(_ enabled: Bool) {
        N60BinauralHeadphoneBridgeSetMeteringDemand(bridge, enabled)
    }

    func bridgeSnapshot() -> N60BinauralHeadphoneBridgeSnapshot? {
        guard let bridge else { return nil }
        return N60BinauralHeadphoneBridgeGetSnapshot(bridge)
    }

    func headTrackingSnapshot() -> N60HeadTrackedBinauralSnapshot? {
        guard let bridge else { return nil }
        return N60BinauralHeadphoneBridgeGetSnapshot(bridge).headTracking
    }

    func prepareHeadTrackedGeneration(
        preparedProfile: PreparedBinauralProfile,
        pose: N60HeadPose,
        warmupFrames: UInt32,
        crossfadeFrames: UInt32
    ) throws -> Bool {
        guard let bridge else {
            throw BinauralHeadphoneTransportError.bridgeAllocationFailed
        }
        guard N60BinauralHeadphoneBridgeCanPrepareTrackedGeneration(bridge) else {
            return false
        }
        let accepted = preparedProfile.leftIRs.withUnsafeBufferPointer { left in
            preparedProfile.rightIRs.withUnsafeBufferPointer { right in
                N60BinauralHeadphoneBridgePrepareTrackedGeneration(
                    bridge,
                    preparedProfile.descriptor,
                    left.baseAddress!,
                    right.baseAddress!,
                    pose,
                    warmupFrames,
                    crossfadeFrames
                )
            }
        }
        guard accepted else {
            throw BinauralHeadphoneTransportError.headTrackingGenerationFailed
        }
        return true
    }

    func counters() -> AudioTransportCounters {
        guard let bridge else { return AudioTransportCounters() }
        let snapshot = N60BinauralHeadphoneBridgeGetSnapshot(bridge)
        return AudioTransportCounters(
            captureCallbacks: snapshot.captureCallbacks,
            outputCallbacks: snapshot.outputCallbacks,
            capturedFrames: snapshot.transport.capturedFrames,
            deliveredFrames: snapshot.renderedFrames,
            underrunFrames: snapshot.transport.underrunFrames,
            overrunFrames: snapshot.transport.overrunFrames,
            unsupportedBufferLayouts: snapshot.transport.unsupportedBufferLayouts
                + snapshot.outputWriteFailures + snapshot.renderFailures,
            gatedOutputCallbacks: snapshot.gatedOutputCallbacks,
            gatedOutputFrames: snapshot.gatedOutputFrames,
            bufferedFrames: snapshot.transport.bufferedFrames
        )
    }

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true
        if fadeOut, let bridge {
            N60BinauralHeadphoneBridgeSetOutputGain(bridge, 0)
        }
        if isOutputStarted, let outputIOProcID {
            AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)
            isOutputStarted = false
        }
        if isCaptureStarted, let captureIOProcID,
           aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
            AudioDeviceStop(aggregateDeviceID, captureIOProcID)
            isCaptureStarted = false
        }
        if let outputIOProcID {
            AudioDeviceDestroyIOProcID(selectedOutput.deviceID, outputIOProcID)
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
            N60BinauralHeadphoneBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

    private func startIO() throws {
        guard !stopped,
              let outputIOProcID,
              let captureIOProcID,
              aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw BinauralHeadphoneTransportError.ioProcUnavailable(role: "startup")
        }
        try CoreAudioSemanticTransportSupport.check(
            AudioDeviceStart(selectedOutput.deviceID, outputIOProcID),
            operation: "start Virtual Speakers headphone output"
        )
        isOutputStarted = true
        do {
            try CoreAudioSemanticTransportSupport.check(
                AudioDeviceStart(aggregateDeviceID, captureIOProcID),
                operation: "start Virtual Speakers program capture"
            )
            isCaptureStarted = true
        } catch {
            AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)
            isOutputStarted = false
            throw error
        }
    }
}
