import AppKit
import CoreAudio
import Darwin
import Foundation

enum CoreAudioOperation: String, Equatable, Sendable {
    case enumerateDevices
    case readOutputStreams
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

    var isSupportedStereoTransportFormat: Bool {
        isFloatPCM && channelCount == 2 && bitsPerChannel == 32
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
        bufferedFrames: UInt32 = 0
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
            bufferedFrames: rhs.bufferedFrames
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
    case realtimeBridgeAllocationFailed
    case dspGraphPublicationFailed
    case convolutionProgramPreparationFailed
    case roomCorrectionProgramPreparationFailed
    case ioProcUnavailable(role: String)
    case outputBufferExceedsBridgeCapacity(bufferFrames: UInt32, capacityFrames: UInt32)

    var errorDescription: String? {
        switch self {
        case .processObjectUnavailable:
            return "Unable to resolve Notch Sixty's Core Audio process object for tap self-exclusion."
        case .operationFailed(let operation, let status):
            return "Core Audio \(operation) failed with status \(status)."
        case .unsupportedFormat(let role, let format):
            return "Unsupported \(role) format: \(format.sampleRate) Hz, \(format.channelCount) channels, \(format.bitsPerChannel)-bit."
        case .sampleRateMismatch(let tap, let output):
            return "Native sample-rate mismatch: tap \(tap) Hz, output \(output) Hz. Transport SRC is intentionally disabled."
        case .realtimeBridgeAllocationFailed:
            return "Unable to allocate the preallocated realtime audio bridge."
        case .dspGraphPublicationFailed:
            return "Unable to publish the render-ready DSP graph."
        case .convolutionProgramPreparationFailed:
            return "Unable to prepare an inactive convolution program slot."
        case .roomCorrectionProgramPreparationFailed:
            return "Unable to prepare an inactive room-correction FIR program slot."
        case .ioProcUnavailable(let role):
            return "Core Audio created the \(role) IOProc without returning a usable callback identifier."
        case .outputBufferExceedsBridgeCapacity(let bufferFrames, let capacityFrames):
            return "Startup gate requires \(bufferFrames) buffered frames but realtime bridge capacity is \(capacityFrames) frames."
        }
    }
}

final class CoreAudioTransportSession {
    private static let bridgeCapacityFrames: UInt32 = 65_536
    private static let fadeStepMicroseconds: UInt32 = 1_500
    private static let fadeStepCount: UInt32 = 8
    private static let graphTransitionFadeMilliseconds = 8.0

    let selectedOutput: AudioOutputDevice
    private(set) var tapFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var outputFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var startupGateTargetFrames: UInt32 = 0
    private(set) var startupGateActivationFrames: UInt32 = 0

    var startupGateOpened: Bool {
        guard let bridge else { return false }
        return N60RealtimeAudioBridgeGetSnapshot(bridge).outputGateOpen
    }

    private var bridge: OpaquePointer?
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioDeviceID(kAudioObjectUnknown)
    private var captureIOProcID: AudioDeviceIOProcID?
    private var outputIOProcID: AudioDeviceIOProcID?
    private var isCaptureStarted = false
    private var isOutputStarted = false
    private var stopped = false

    init(selectedOutput: AudioOutputDevice) throws {
        self.selectedOutput = selectedOutput
        guard let newBridge = N60RealtimeAudioBridgeCreate(Self.bridgeCapacityFrames) else {
            throw CoreAudioTransportError.realtimeBridgeAllocationFailed
        }
        bridge = newBridge

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
            guard outputFormat.isSupportedStereoTransportFormat else {
                throw CoreAudioTransportError.unsupportedFormat(role: "output", format: outputFormat)
            }
            guard abs(tapFormat.sampleRate - outputFormat.sampleRate) < 0.5 else {
                throw CoreAudioTransportError.sampleRateMismatch(tap: tapFormat.sampleRate, output: outputFormat.sampleRate)
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
            let gatePolicy = AudioStartupGatePolicy(
                outputBufferFrames: outputBufferFrames,
                sampleRate: outputFormat.sampleRate
            )
            guard gatePolicy.activationBufferedFrames <= Self.bridgeCapacityFrames else {
                throw CoreAudioTransportError.outputBufferExceedsBridgeCapacity(
                    bufferFrames: gatePolicy.activationBufferedFrames,
                    capacityFrames: Self.bridgeCapacityFrames
                )
            }
            startupGateTargetFrames = gatePolicy.steadyStateTargetFrames
            startupGateActivationFrames = gatePolicy.activationBufferedFrames

            let tapEntry: [String: Any] = [
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: false,
            ]
            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Notch Sixty Private Tap",
                kAudioAggregateDeviceUIDKey: "com.dhdook.NotchSixty.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceTapListKey: [tapEntry],
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceIsPrivateKey: true,
            ]
            try Self.check(
                AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID),
                operation: "create private aggregate device"
            )

            let clientData = UnsafeMutableRawPointer(newBridge)
            try Self.check(
                AudioDeviceCreateIOProcID(aggregateDeviceID, N60CaptureIOProc, clientData, &captureIOProcID),
                operation: "create capture IOProc"
            )
            try Self.check(
                AudioDeviceCreateIOProcID(selectedOutput.deviceID, N60OutputIOProc, clientData, &outputIOProcID),
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
                gatePolicy.activationBufferedFrames,
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

    func counters() -> AudioTransportCounters {
        guard let bridge else { return AudioTransportCounters() }
        return AudioTransportCounters(snapshot: N60RealtimeAudioBridgeGetSnapshot(bridge))
    }

    func renderDiagnostics() -> RenderKernelDiagnostics? {
        guard let bridge else { return nil }
        return RenderKernelDiagnostics(N60RealtimeAudioBridgeGetRenderDiagnostics(bridge))
    }

    func prepareConvolutionProgram(
        slot: UInt32,
        taps: [Float],
        declaredLatencyFrames: UInt32
    ) throws -> N60ConvolutionProgramInfo {
        guard let bridge, !taps.isEmpty else {
            throw CoreAudioTransportError.convolutionProgramPreparationFailed
        }
        var info = N60ConvolutionProgramInfo()
        let prepared = taps.withUnsafeBufferPointer { buffer in
            N60RealtimeAudioBridgePrepareConvolutionProgram(
                bridge,
                slot,
                buffer.baseAddress!,
                nil,
                UInt32(buffer.count),
                declaredLatencyFrames,
                &info
            )
        }
        guard prepared else { throw CoreAudioTransportError.convolutionProgramPreparationFailed }
        return info
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
        return info
    }

    func publishDSPGraph(_ snapshot: N60DSPGraphSnapshot) throws {
        guard let bridge, N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot) else {
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }
        if !isOutputStarted || !isCaptureStarted {
            try startIO()
        }
    }

    func transitionDSPGraph(_ snapshot: N60DSPGraphSnapshot) throws {
        guard let bridge else { throw CoreAudioTransportError.dspGraphPublicationFailed }

        if !isOutputStarted || !isCaptureStarted {
            try publishDSPGraph(snapshot)
            return
        }

        for step in stride(from: Int(Self.fadeStepCount) - 1, through: 0, by: -1) {
            N60RealtimeAudioBridgeSetTransitionGainImmediate(
                bridge,
                Float(step) / Float(Self.fadeStepCount)
            )
            usleep(Self.fadeStepMicroseconds)
        }

        guard N60RealtimeAudioBridgePublishDSPGraph(bridge, snapshot) else {
            N60RealtimeAudioBridgeSetTransitionGainImmediate(bridge, 1.0)
            throw CoreAudioTransportError.dspGraphPublicationFailed
        }

        let fadeFramesDouble = max(outputFormat.sampleRate, 1) * Self.graphTransitionFadeMilliseconds / 1_000.0
        let fadeFrames = UInt32(min(max(fadeFramesDouble.rounded(), 1), Double(UInt32.max)))
        N60RealtimeAudioBridgeSetTransitionGainImmediate(bridge, 0.0)
        N60RealtimeAudioBridgeRampTransitionGain(bridge, 1.0, fadeFrames)
    }

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true

        if fadeOut, let bridge, isOutputStarted {
            for step in stride(from: Int(Self.fadeStepCount) - 1, through: 0, by: -1) {
                N60RealtimeAudioBridgeSetOutputGain(bridge, Float(step) / Float(Self.fadeStepCount))
                usleep(Self.fadeStepMicroseconds)
            }
        }

        if isOutputStarted, let outputIOProcID {
            AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)
            isOutputStarted = false
        }
        if isCaptureStarted, let captureIOProcID, aggregateDeviceID != AudioDeviceID(kAudioObjectUnknown) {
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
            N60RealtimeAudioBridgeDestroy(bridge)
            self.bridge = nil
        }
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
            AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)
            isOutputStarted = false
        }

        try Self.check(
            AudioDeviceStart(selectedOutput.deviceID, outputIOProcID),
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
            AudioDeviceStop(selectedOutput.deviceID, outputIOProcID)
            isOutputStarted = false
            throw error
        }
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
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var dataSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &format), operation: operation)
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
        try check(AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value), operation: operation)
        return value
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
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, listener)
        guard status == noErr else {
            throw CoreAudioTransportError.operationFailed(operation: "install sample-rate listener", status: status)
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
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, DispatchQueue.main, sampleRateListener)
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
            throw CoreAudioTransportError.operationFailed(operation: "install device-list listener", status: status)
        }
        deviceListListener = listener
    }

    private func installPowerNotifications() {
        guard notificationTokens.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                self?.onWillSleep?()
            }
        )
        notificationTokens.append(
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.onDidWake?()
            }
        )
    }
}
