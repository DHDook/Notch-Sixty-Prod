import AppKit
import Combine
import CoreAudio
import Darwin
import Foundation

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

    var isNonInterleaved: Bool {
        (formatFlags & kAudioFormatFlagIsNonInterleaved) != 0
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
    var bufferedFrames: UInt32 = 0

    init(snapshot: N60RealtimeAudioBridgeSnapshot) {
        captureCallbacks = snapshot.captureCallbacks
        outputCallbacks = snapshot.outputCallbacks
        capturedFrames = snapshot.capturedFrames
        deliveredFrames = snapshot.deliveredFrames
        underrunFrames = snapshot.underrunFrames
        overrunFrames = snapshot.overrunFrames
        unsupportedBufferLayouts = snapshot.unsupportedBufferLayouts
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
        bufferedFrames: UInt32 = 0
    ) {
        self.captureCallbacks = captureCallbacks
        self.outputCallbacks = outputCallbacks
        self.capturedFrames = capturedFrames
        self.deliveredFrames = deliveredFrames
        self.underrunFrames = underrunFrames
        self.overrunFrames = overrunFrames
        self.unsupportedBufferLayouts = unsupportedBufferLayouts
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
            bufferedFrames: rhs.bufferedFrames
        )
    }
}

struct CoreAudioTransportError: Error, LocalizedError, Equatable {
    case processObjectUnavailable
    case operationFailed(operation: String, status: OSStatus)
    case unsupportedFormat(role: String, format: AudioStreamFormatDescription)
    case sampleRateMismatch(tap: Double, output: Double)
    case realtimeBridgeAllocationFailed

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
        }
    }
}

final class CoreAudioTransportSession {
    private static let bridgeCapacityFrames: UInt32 = 65_536

    let selectedOutput: AudioOutputDevice
    private(set) var tapFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())
    private(set) var outputFormat = AudioStreamFormatDescription(AudioStreamBasicDescription())

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

            try Self.check(
                AudioHardwareCreateProcessTap(description, &tapID),
                operation: "create process tap"
            )

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
                throw CoreAudioTransportError.sampleRateMismatch(
                    tap: tapFormat.sampleRate,
                    output: outputFormat.sampleRate
                )
            }

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

            try Self.check(
                AudioDeviceCreateIOProcID(aggregateDeviceID, N60CaptureIOProc, newBridge, &captureIOProcID),
                operation: "create capture IOProc"
            )
            try Self.check(
                AudioDeviceCreateIOProcID(selectedOutput.deviceID, N60OutputIOProc, newBridge, &outputIOProcID),
                operation: "create output IOProc"
            )

            if let outputIOProcID {
                try Self.check(
                    AudioDeviceStart(selectedOutput.deviceID, outputIOProcID),
                    operation: "start physical output"
                )
                isOutputStarted = true
            }
            if let captureIOProcID {
                try Self.check(
                    AudioDeviceStart(aggregateDeviceID, captureIOProcID),
                    operation: "start tap capture"
                )
                isCaptureStarted = true
            }
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

    func stop(fadeOut: Bool) {
        guard !stopped else { return }
        stopped = true

        if fadeOut, let bridge, isOutputStarted {
            for step in stride(from: 7, through: 0, by: -1) {
                N60RealtimeAudioBridgeSetOutputGain(bridge, Float(step) / 8.0)
                usleep(1_500)
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
        try check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &format),
            operation: operation
        )
        return format
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

@MainActor
final class AudioIOEngine: ObservableObject {
    private let deviceCatalog: any OutputDeviceCataloging
    private let eventMonitor: AudioHardwareEventMonitor
    private var lifecycle: AudioLifecycleStateMachine
    private var transportSession: CoreAudioTransportSession?
    private var archivedCounters = AudioTransportCounters()
    private var reconfigurationWorkItem: DispatchWorkItem?
    private var recoveryWorkItem: DispatchWorkItem?
    private var recoveryGeneration: UInt64 = 0
    private var resumeAfterWake = false
    private var prepared = false

    private(set) var sampleRateChangesHandled: UInt64 = 0
    private(set) var recoveryAttempts: UInt64 = 0
    private(set) var recoverySuccesses: UInt64 = 0
    private(set) var recoveryFailures: UInt64 = 0

    @Published private(set) var outputDevices: [AudioOutputDevice] = []
    @Published private(set) var routeConfiguration: AudioRouteConfiguration
    @Published private(set) var lastErrorDescription: String?
    @Published private(set) var lifecycleState: AudioLifecycleState

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration(),
        eventMonitor: AudioHardwareEventMonitor = AudioHardwareEventMonitor()
    ) {
        self.deviceCatalog = deviceCatalog
        self.routeConfiguration = initialRouteConfiguration
        self.eventMonitor = eventMonitor
        let lifecycle = AudioLifecycleStateMachine()
        self.lifecycle = lifecycle
        self.lifecycleState = lifecycle.state

        eventMonitor.onDeviceListChanged = { [weak self] in self?.handleDeviceListChanged() }
        eventMonitor.onSelectedOutputSampleRateChanged = { [weak self] in self?.scheduleSampleRateReconfiguration() }
        eventMonitor.onWillSleep = { [weak self] in self?.handleWillSleep() }
        eventMonitor.onDidWake = { [weak self] in self?.handleDidWake() }
    }

    var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputUID = routeConfiguration.selectedOutputUID else { return nil }
        return outputDevices.first { $0.uid == selectedOutputUID }
    }

    func prepareForUse() {
        guard !prepared else { return }
        prepared = true
        do {
            try refreshOutputDevices()
            try eventMonitor.start()
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }

    @discardableResult
    func refreshOutputDevices() throws -> [AudioOutputDevice] {
        do {
            let discoveredDevices = try deviceCatalog.outputDevices()
            outputDevices = discoveredDevices
            lastErrorDescription = nil
            return discoveredDevices
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func selectOutput(uid: String?) throws {
        guard lifecycle.state == .idle else { return }
        guard let uid else {
            routeConfiguration.selectedOutputUID = nil
            return
        }
        guard outputDevices.contains(where: { $0.uid == uid }) else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: uid)
            lastErrorDescription = error.localizedDescription
            throw error
        }
        routeConfiguration.selectedOutputUID = uid
        lastErrorDescription = nil
    }

    func start() throws {
        guard lifecycle.state == .idle else { return }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "No output selected")
            lastErrorDescription = error.localizedDescription
            throw error
        }

        do {
            try setLifecycle(.requestingPermission)
            try setLifecycle(.creatingTap)
            try buildTransport(output: output)
            try setLifecycle(.creatingAggregate)
            try setLifecycle(.openingOutput)
            try setLifecycle(.starting)
            try setLifecycle(.running)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
            throw error
        }
    }

    func stop() {
        guard lifecycle.state != .idle else { return }
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        reconfigurationWorkItem = nil
        recoveryWorkItem = nil
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
    }

    func shutdownForTermination() {
        recoveryGeneration &+= 1
        reconfigurationWorkItem?.cancel()
        recoveryWorkItem?.cancel()
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        if lifecycle.state != .idle {
            if lifecycle.state != .stopping { try? setLifecycle(.stopping) }
            tearDownTransport(fadeOut: true)
            try? setLifecycle(.idle)
        }
        eventMonitor.stop()
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        let currentCounters = transportSession?.counters() ?? AudioTransportCounters()
        let totalCounters = archivedCounters + currentCounters
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: transportSession?.tapFormat.sampleRate,
            outputSampleRate: transportSession?.outputFormat.sampleRate,
            transportCounters: totalCounters,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func setLifecycle(_ nextState: AudioLifecycleState) throws {
        try lifecycle.transition(to: nextState)
        lifecycleState = lifecycle.state
    }

    private func buildTransport(output: AudioOutputDevice) throws {
        transportSession = try CoreAudioTransportSession(selectedOutput: output)
    }

    private func tearDownTransport(fadeOut: Bool) {
        if let session = transportSession {
            archivedCounters = archivedCounters + session.counters()
            archivedCounters.bufferedFrames = 0
            session.stop(fadeOut: fadeOut)
            transportSession = nil
        }
    }

    private func forceFailedState(_ error: Error) {
        lastErrorDescription = error.localizedDescription
        if AudioLifecycleStateMachine.canTransition(from: lifecycle.state, to: .failed) {
            try? lifecycle.transition(to: .failed)
            lifecycleState = lifecycle.state
        }
    }

    private func handleDeviceListChanged() {
        do { try refreshOutputDevices() } catch { return }
        guard let selectedUID = routeConfiguration.selectedOutputUID else { return }
        let selectedIsPresent = outputDevices.contains { $0.uid == selectedUID }
        if !selectedIsPresent && (lifecycle.state == .running || lifecycle.state == .reconfiguring) {
            beginOutputRecovery()
        }
    }

    private func scheduleSampleRateReconfiguration() {
        guard lifecycle.state == .running else { return }
        reconfigurationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.performSampleRateReconfiguration() }
        reconfigurationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func performSampleRateReconfiguration() {
        guard lifecycle.state == .running else { return }
        do {
            try setLifecycle(.reconfiguring)
            eventMonitor.removeSelectedOutputSampleRateMonitor()
            tearDownTransport(fadeOut: false)
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                beginOutputRecovery()
                return
            }
            try buildTransport(output: output)
            try eventMonitor.monitorSampleRate(of: output.deviceID)
            sampleRateChangesHandled &+= 1
            try setLifecycle(.running)
            lastErrorDescription = nil
        } catch {
            tearDownTransport(fadeOut: false)
            forceFailedState(error)
        }
    }

    private func beginOutputRecovery() {
        guard lifecycle.state == .running || lifecycle.state == .reconfiguring else { return }
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        try? setLifecycle(.recoveringOutput)
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        tearDownTransport(fadeOut: false)
        scheduleRecoveryAttempt(generation: generation, attempt: 1)
    }

    private func scheduleRecoveryAttempt(generation: UInt64, attempt: Int) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRecoveryAttempt(generation: generation, attempt: attempt)
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func performRecoveryAttempt(generation: UInt64, attempt: Int) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryAttempts &+= 1
        do {
            try refreshOutputDevices()
            if let output = selectedOutputDevice {
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                recoverySuccesses &+= 1
                try setLifecycle(.running)
                lastErrorDescription = nil
                return
            }
        } catch {
            lastErrorDescription = error.localizedDescription
            tearDownTransport(fadeOut: false)
        }

        if attempt < 10 {
            scheduleRecoveryAttempt(generation: generation, attempt: attempt + 1)
        } else {
            recoveryFailures &+= 1
            forceFailedState(AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "unknown"))
        }
    }

    private func handleWillSleep() {
        guard lifecycle.state == .running else {
            resumeAfterWake = false
            return
        }
        resumeAfterWake = true
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        try? setLifecycle(.stopping)
        tearDownTransport(fadeOut: false)
        try? setLifecycle(.idle)
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        do { try start() } catch { lastErrorDescription = error.localizedDescription }
    }
}
