import Combine
import CoreAudio
import Foundation

@MainActor
final class AudioIOEngine: ObservableObject {
    private let deviceCatalog: any OutputDeviceCataloging
    private let eventMonitor: AudioHardwareEventMonitor
    private var lifecycle: AudioLifecycleStateMachine
    private var transportSession: CoreAudioTransportSession?
    private var lifetimeArchivedCounters = AudioTransportCounters()
    private var processingSessionArchivedCounters = AudioTransportCounters()
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
        try start(resetProcessingSessionCounters: true)
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
        let processingSessionCounters = processingSessionArchivedCounters + currentCounters
        let lifetimeCounters = lifetimeArchivedCounters + currentCounters
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate,
            discoveredOutputCount: outputDevices.count,
            tapSampleRate: transportSession?.tapFormat.sampleRate,
            outputSampleRate: transportSession?.outputFormat.sampleRate,
            sessionTransportCounters: processingSessionCounters,
            lifetimeTransportCounters: lifetimeCounters,
            startupGateOpened: transportSession?.startupGateOpened,
            startupGateTargetFrames: transportSession?.startupGateTargetFrames,
            startupGateActivationFrames: transportSession?.startupGateActivationFrames,
            sampleRateChangesHandled: sampleRateChangesHandled,
            recoveryAttempts: recoveryAttempts,
            recoverySuccesses: recoverySuccesses,
            recoveryFailures: recoveryFailures,
            lastErrorDescription: lastErrorDescription
        )
    }

    private func start(resetProcessingSessionCounters: Bool) throws {
        guard lifecycle.state == .idle else { return }
        try refreshOutputDevices()
        guard let output = selectedOutputDevice else {
            let error = AudioRouteSelectionError.outputDeviceUnavailable(uid: routeConfiguration.selectedOutputUID ?? "No output selected")
            lastErrorDescription = error.localizedDescription
            throw error
        }

        if resetProcessingSessionCounters {
            processingSessionArchivedCounters = AudioTransportCounters()
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

    private func setLifecycle(_ nextState: AudioLifecycleState) throws {
        try lifecycle.transition(to: nextState)
        lifecycleState = lifecycle.state
    }

    private func buildTransport(output: AudioOutputDevice) throws {
        transportSession = try CoreAudioTransportSession(selectedOutput: output)
    }

    private func tearDownTransport(fadeOut: Bool) {
        if let session = transportSession {
            let counters = session.counters()
            lifetimeArchivedCounters = lifetimeArchivedCounters + counters
            lifetimeArchivedCounters.bufferedFrames = 0
            processingSessionArchivedCounters = processingSessionArchivedCounters + counters
            processingSessionArchivedCounters.bufferedFrames = 0
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
            return
        }

        if selectedIsPresent && lifecycle.state == .recoveringOutput {
            scheduleRecoveryAttempt(generation: recoveryGeneration, delay: 0)
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
        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
    }

    private func scheduleRecoveryAttempt(generation: UInt64, delay: TimeInterval) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.performRecoveryAttempt(generation: generation)
        }
        recoveryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func performRecoveryAttempt(generation: UInt64) {
        guard generation == recoveryGeneration, lifecycle.state == .recoveringOutput else { return }
        recoveryAttempts &+= 1

        do {
            try refreshOutputDevices()
            guard let output = selectedOutputDevice else {
                lastErrorDescription = "Waiting for selected output to return."
                scheduleRecoveryAttempt(generation: generation, delay: 0.5)
                return
            }

            do {
                try buildTransport(output: output)
                try eventMonitor.monitorSampleRate(of: output.deviceID)
                recoverySuccesses &+= 1
                try setLifecycle(.running)
                lastErrorDescription = nil
                recoveryWorkItem = nil
                return
            } catch {
                recoveryFailures &+= 1
                lastErrorDescription = "Selected output is present but not ready yet: \(error.localizedDescription)"
                tearDownTransport(fadeOut: false)
            }
        } catch {
            lastErrorDescription = error.localizedDescription
        }

        scheduleRecoveryAttempt(generation: generation, delay: 0.5)
    }

    private func handleWillSleep() {
        guard lifecycle.state == .running else {
            resumeAfterWake = false
            return
        }
        resumeAfterWake = true
        eventMonitor.removeSelectedOutputSampleRateMonitor()
        try? setLifecycle(.stopping)
        tearDownTransport(fadeOut: true)
        try? setLifecycle(.idle)
    }

    private func handleDidWake() {
        guard resumeAfterWake else { return }
        resumeAfterWake = false
        do {
            try start(resetProcessingSessionCounters: false)
        } catch {
            lastErrorDescription = error.localizedDescription
        }
    }
}
