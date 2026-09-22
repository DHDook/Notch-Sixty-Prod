import Combine
import CoreAudio
import Foundation

enum EQFilterType: String, CaseIterable, Identifiable, Sendable {
    case peaking
    case lowShelf
    case highShelf
    case lowPass
    case highPass
    case notch

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking: return "Peak"
        case .lowShelf: return "Low Shelf"
        case .highShelf: return "High Shelf"
        case .lowPass: return "Low Pass"
        case .highPass: return "High Pass"
        case .notch: return "Notch"
        }
    }

    var cType: N60BiquadFilterType {
        switch self {
        case .peaking: return N60BiquadFilterTypePeaking
        case .lowShelf: return N60BiquadFilterTypeLowShelf
        case .highShelf: return N60BiquadFilterTypeHighShelf
        case .lowPass: return N60BiquadFilterTypeLowPass
        case .highPass: return N60BiquadFilterTypeHighPass
        case .notch: return N60BiquadFilterTypeNotch
        }
    }
}

struct EQBand: Identifiable, Equatable, Sendable {
    let id: UUID
    var enabled: Bool
    var type: EQFilterType
    var frequencyHz: Double
    var gainDB: Double
    var q: Double

    init(
        id: UUID = UUID(),
        enabled: Bool = true,
        type: EQFilterType = .peaking,
        frequencyHz: Double = 1_000,
        gainDB: Double = 0,
        q: Double = 0.707
    ) {
        self.id = id
        self.enabled = enabled
        self.type = type
        self.frequencyHz = frequencyHz
        self.gainDB = gainDB
        self.q = q
    }
}

enum EQConfigurationError: Error, LocalizedError, Equatable {
    case tooManyBands(Int)
    case invalidBand(index: Int)

    var errorDescription: String? {
        switch self {
        case .tooManyBands(let count):
            return "Parametric EQ supports at most \(Int(N60_MAX_EQ_BANDS)) bands; configuration contains \(count)."
        case .invalidBand(let index):
            return "EQ band \(index + 1) is invalid for the current output sample rate."
        }
    }
}

struct EQConfiguration: Equatable, Sendable {
    static let maximumBandCount = Int(N60_MAX_EQ_BANDS)

    var bypassed = false
    var bands: [EQBand] = []

    var enabledBandCount: Int {
        bands.reduce(into: 0) { count, band in
            if band.enabled { count += 1 }
        }
    }

    func makeGraphSnapshot(sampleRate: Double) throws -> N60DSPGraphSnapshot {
        guard bands.count <= Self.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(bands.count)
        }

        var graph = N60DSPGraphSnapshotMakeUnity(sampleRate)
        graph.eqBypassed = bypassed
        N60DSPGraphSnapshotClearEQ(&graph)

        var renderIndex: UInt32 = 0
        for (modelIndex, band) in bands.enumerated() where band.enabled {
            guard N60DSPGraphSnapshotSetEQBand(
                &graph,
                renderIndex,
                band.type.cType,
                band.frequencyHz,
                band.gainDB,
                band.q,
                true
            ) else {
                throw EQConfigurationError.invalidBand(index: modelIndex)
            }
            renderIndex += 1
        }
        return graph
    }
}

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
    @Published private(set) var eqConfiguration = EQConfiguration()
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

    func addEQBand(_ band: EQBand = EQBand()) throws {
        guard eqConfiguration.bands.count < EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(eqConfiguration.bands.count + 1)
        }
        var updated = eqConfiguration
        updated.bands.append(band)
        try applyEQConfiguration(updated)
    }

    func updateEQBand(_ band: EQBand) throws {
        guard let index = eqConfiguration.bands.firstIndex(where: { $0.id == band.id }) else { return }
        var updated = eqConfiguration
        updated.bands[index] = band
        try applyEQConfiguration(updated)
    }

    func removeEQBand(id: UUID) throws {
        var updated = eqConfiguration
        updated.bands.removeAll { $0.id == id }
        try applyEQConfiguration(updated)
    }

    func setEQBypassed(_ bypassed: Bool) throws {
        var updated = eqConfiguration
        updated.bypassed = bypassed
        try applyEQConfiguration(updated)
    }

    func replaceEQConfiguration(_ configuration: EQConfiguration) throws {
        try applyEQConfiguration(configuration)
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
            renderKernelDiagnostics: transportSession?.renderDiagnostics(),
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

    private func applyEQConfiguration(_ configuration: EQConfiguration) throws {
        guard configuration.bands.count <= EQConfiguration.maximumBandCount else {
            throw EQConfigurationError.tooManyBands(configuration.bands.count)
        }

        if let session = transportSession {
            let graph = try configuration.makeGraphSnapshot(sampleRate: session.outputFormat.sampleRate)
            try session.publishDSPGraph(graph)
        }
        eqConfiguration = configuration
        lastErrorDescription = nil
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
        let session = try CoreAudioTransportSession(selectedOutput: output)
        let graph = try eqConfiguration.makeGraphSnapshot(sampleRate: session.outputFormat.sampleRate)
        try session.publishDSPGraph(graph)
        transportSession = session
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
