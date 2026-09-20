import Foundation

@MainActor
final class AudioIOEngine {
    private let deviceCatalog: any OutputDeviceCataloging
    private var lifecycle: AudioLifecycleStateMachine

    private(set) var outputDevices: [AudioOutputDevice] = []
    private(set) var routeConfiguration: AudioRouteConfiguration
    private(set) var lastErrorDescription: String?

    init(
        deviceCatalog: any OutputDeviceCataloging = CoreAudioOutputDeviceCatalog(),
        initialRouteConfiguration: AudioRouteConfiguration = AudioRouteConfiguration()
    ) {
        self.deviceCatalog = deviceCatalog
        self.routeConfiguration = initialRouteConfiguration
        self.lifecycle = AudioLifecycleStateMachine()
    }

    var lifecycleState: AudioLifecycleState {
        lifecycle.state
    }

    var selectedOutputDevice: AudioOutputDevice? {
        guard let selectedOutputUID = routeConfiguration.selectedOutputUID else {
            return nil
        }
        return outputDevices.first { $0.uid == selectedOutputUID }
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

    func transition(to nextState: AudioLifecycleState) throws {
        do {
            try lifecycle.transition(to: nextState)
            lastErrorDescription = nil
        } catch {
            lastErrorDescription = error.localizedDescription
            throw error
        }
    }

    func clearLastError() {
        lastErrorDescription = nil
    }

    func diagnosticsSnapshot() -> AudioDiagnosticsSnapshot {
        let selectedDevice = selectedOutputDevice
        return AudioDiagnosticsSnapshot(
            lifecycleState: lifecycle.state,
            selectedOutputUID: routeConfiguration.selectedOutputUID,
            selectedOutputName: selectedDevice?.name,
            selectedOutputPresent: selectedDevice != nil,
            selectedOutputNominalSampleRate: selectedDevice?.nominalSampleRate,
            discoveredOutputCount: outputDevices.count,
            lastErrorDescription: lastErrorDescription
        )
    }
}
