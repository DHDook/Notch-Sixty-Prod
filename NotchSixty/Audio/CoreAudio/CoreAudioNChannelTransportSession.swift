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
    case configurationChangeRequiresRestart

    var errorDescription: String? {
        switch self {
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
        case .configurationChangeRequiresRestart:
            return "Stop N-channel processing before changing DSP or Output Device Profile configuration."
        }
    }
}

/// Control-plane compiler for PR61's immutable live render graph. The first
/// production activation intentionally supports only processing that already has
/// a semantic N-channel implementation: global gain, PR54 lanes, and PR55 bass
/// management. Stereo-only stages fail closed in AudioIOEngine before this graph
/// is created rather than being silently omitted.
enum LiveNChannelRenderGraphCompiler {
    static func makeGraph(
        routePlan: LiveNChannelOutputRoutePlan,
        sampleRate: Double,
        gainConfiguration: DSPGainConfiguration,
        bassManagementConfiguration: BassManagementConfiguration
    ) throws -> N60LiveNChannelRenderGraph {
        let layout = routePlan.programLayout.realtimeLayout
        var lanes = N60ProgramLaneGraphSnapshotMakeUnity(sampleRate, layout)

        let combinedGainDB = gainConfiguration.inputPreampDB
            + gainConfiguration.headroomAttenuationDB
            + gainConfiguration.outputGainDB
        let combinedGain = DSPGainConfiguration.linearGain(forDB: combinedGainDB)
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

        let outputMap = try routePlan.makeRealtimeOutputMap()
        var bass = N60MultichannelBassManagementSnapshot()
        if bassManagementConfiguration.enabled {
            bass = N60MultichannelBassManagementSnapshotMake(
                sampleRate,
                layout,
                routePlan.subwooferCount
            )
            let routeGain = 1.0 / Float(max(routePlan.subwooferCount, 1))
            for channel in 0..<layout.channelCount {
                if layout.channels[Int(channel)] == N60ProgramChannelRoleLowFrequencyEffects {
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
    private static let bridgeCapacityFrames: UInt32 = 65_536

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
        routePlan: LiveNChannelOutputRoutePlan,
        renderGraph: N60LiveNChannelRenderGraph,
        outputGain: Float
    ) throws {
        self.selectedOutput = selectedOutput
        self.routePlan = routePlan

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
            guard abs(tapFormat.sampleRate - outputFormat.sampleRate) < 0.5 else {
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
            guard gatePolicy.activationBufferedFrames <= Self.bridgeCapacityFrames else {
                throw LiveNChannelTransportError.outputBufferExceedsBridgeCapacity(
                    bufferFrames: gatePolicy.activationBufferedFrames,
                    capacityFrames: Self.bridgeCapacityFrames
                )
            }
            startupGateTargetFrames = gatePolicy.steadyStateTargetFrames
            startupGateActivationFrames = gatePolicy.activationBufferedFrames

            guard let newBridge = N60LiveNChannelBridgeCreate(
                Self.bridgeCapacityFrames,
                inputMap,
                renderGraph,
                gatePolicy.activationBufferedFrames,
                gatePolicy.fadeInFrames
            ) else {
                throw LiveNChannelTransportError.realtimeBridgeAllocationFailed
            }
            bridge = newBridge
            N60LiveNChannelBridgeSetOutputGain(newBridge, outputGain)

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
                value: outputFormat.sampleRate,
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

    deinit {
        stop(fadeOut: false)
    }

    func setOutputGain(_ gain: Float) {
        N60LiveNChannelBridgeSetOutputGain(bridge, gain)
    }

    func counters() -> AudioTransportCounters {
        guard let bridge else { return AudioTransportCounters() }
        let snapshot = N60LiveNChannelBridgeGetSnapshot(bridge)
        return AudioTransportCounters(
            captureCallbacks: snapshot.captureCallbacks,
            outputCallbacks: snapshot.outputCallbacks,
            capturedFrames: snapshot.transport.capturedFrames,
            deliveredFrames: snapshot.renderedFrames,
            underrunFrames: snapshot.transport.underrunFrames,
            overrunFrames: snapshot.transport.overrunFrames,
            unsupportedBufferLayouts: snapshot.transport.unsupportedBufferLayouts
                + snapshot.outputWriteFailures,
            gatedOutputCallbacks: snapshot.gatedOutputCallbacks,
            gatedOutputFrames: snapshot.gatedOutputFrames,
            bufferedFrames: snapshot.transport.bufferedFrames
        )
    }

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true
        if fadeOut, let bridge {
            // PR61 has an atomic master-gain control but no callback-owned shutdown
            // ramp yet. Fail silent immediately rather than sleeping on the audio
            // thread or freeing a bridge that may still be referenced by Core Audio.
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
            N60LiveNChannelBridgeDestroy(bridge)
            self.bridge = nil
        }
    }

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

        try Self.check(
            AudioDeviceStart(outputDeviceID, outputIOProcID),
            operation: "start semantic physical output"
        )
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
        try layoutData.withUnsafeBytes { raw -> [AudioChannelDescription]? in
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
                specifier = layout.pointee.mChannelBitmap
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
