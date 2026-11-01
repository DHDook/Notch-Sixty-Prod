import Combine
import Foundation

// E24 S1: what the Level step and the Measure-tab Generator card play through. With no playback running there is
// no graph to put the generator in, so the noise runs in a measurement-owned level session
// (`MeasurementLevelSession`); with playback on the graph renderer the generator joins the live graph as before.

/// Builds the level-session request from the engine, profile and microphone state, and says why it cannot.
@MainActor
protocol LevelSessionEnvironment: AnyObject {
    /// Lanes the noise can play on, in program-role order.
    var laneChoices: [(index: Int, name: String, isLFE: Bool)] { get }
    func makeRequest() throws -> LevelSessionRequest
}

@MainActor
final class EngineLevelSessionEnvironment: LevelSessionEnvironment {
    private let engine: AudioIOEngine
    private let profiles: ProductProfileController
    private let microphone: RoomCorrectionCalibrationController

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
    }

    var laneChoices: [(index: Int, name: String, isLFE: Bool)] {
        if engine.liveGraphEditsAvailable { return engine.generatorLaneChoices }
        if let plan = try? routePlan(), !plan.isRouted {
            return plan.programLayout.roles.enumerated().map {
                ($0.offset, $0.element.displayName, $0.element == .lowFrequencyEffects)
            }
        }
        return engine.generatorLaneChoices
    }

    private func routePlan() throws -> LiveNChannelOutputRoutePlan {
        guard let output = engine.selectedOutputDevice, let uid = engine.routeConfiguration.selectedOutputUID else {
            throw MeasurementLevelSessionError.outputRequired
        }
        if let profile = profiles.selectedSystemOutputDeviceProfile, profile.enabled {
            let bassEnabled = profiles.selectedSystemProfile?.state.bassManagement.enabled
                ?? engine.bassManagementConfiguration.enabled
            do {
                return try profile.makeLivePlan(
                    availableDevices: engine.outputDevices, sampleRate: output.nominalSampleRate,
                    selectedOutputUID: uid, bassManagementEnabled: bassEnabled)
            } catch {
                throw MeasurementLevelSessionError.routeUnavailable(error.localizedDescription)
            }
        }
        guard output.outputChannelCount >= 2 else {
            throw MeasurementLevelSessionError.routeUnavailable("this output has fewer than two channels.")
        }
        return LiveNChannelOutputRoutePlan(
            programLayout: .stereo, orderedDeviceUIDs: [uid], referenceDeviceUID: uid,
            physicalChannelCount: UInt32(output.outputChannelCount), programPhysicalChannels: [0, 1],
            subwooferPhysicalChannels: [], subwooferCount: 0, bassManagementEnabled: false,
            speakerCalibrations: [:], subwooferCalibrations: [])
    }

    func makeRequest() throws -> LevelSessionRequest {
        guard let output = engine.selectedOutputDevice else { throw MeasurementLevelSessionError.outputRequired }
        guard let input = microphone.selectedInputDevice else { throw MeasurementLevelSessionError.microphoneRequired }
        guard microphone.permissionStatus == .authorized else { throw MeasurementLevelSessionError.microphonePermissionRequired }
        let plan = try routePlan()
        guard !plan.isRouted else {
            throw MeasurementLevelSessionError.routeUnavailable("routed layouts are not supported by the level noise yet.")
        }
        let roles = plan.programLayout.roles
        var lanes: [LevelSessionLane] = []
        for (index, role) in roles.enumerated() where index < plan.programPhysicalChannels.count {
            lanes.append(LevelSessionLane(
                roleIndex: index, name: role.displayName, physicalChannel: plan.programPhysicalChannels[index],
                isLFE: role == .lowFrequencyEffects))
        }
        return LevelSessionRequest(
            routePlan: plan, outputs: engine.outputDevices, input: input,
            inputChannel: microphone.selectedInputChannelIndex, sampleRate: output.nominalSampleRate, lanes: lanes)
    }
}

/// The Level step's noise player: the level session when playback is idle, the live graph when it runs there.
@MainActor
final class LevelSessionNoisePlayer: SystemSetupNoisePlaying {
    private let engine: AudioIOEngine
    private let environment: LevelSessionEnvironment
    private let monitor: MeasurementInputMonitor
    private let session: MeasurementLevelSession
    private var usesLiveGraph = false
    private(set) var isPlaying = false
    private var outputObserver: AnyCancellable?
    private var stopHandler: ((String) -> Void)?

    init(engine: AudioIOEngine, environment: LevelSessionEnvironment, monitor: MeasurementInputMonitor,
         transport: @escaping LevelSessionTransportFactory = LevelSessionHardware.transportFactory) {
        self.engine = engine
        self.environment = environment
        self.monitor = monitor
        session = MeasurementLevelSession(transport: transport)
        session.onEnded = { [weak self] _ in
            guard let self else { return }
            self.monitor.stop()
            self.isPlaying = false
            self.stopHandler?("The noise stopped by itself after the generator's time limit.")
        }
    }

    func setStopHandler(_ handler: @escaping (String) -> Void) { stopHandler = handler }

    func start(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection) throws {
        guard settings.kind == .bandLimitedPink || settings.kind == .pink,
              settings.levelDB <= SystemSetupLevelPlan.ceilingDB,
              settings.ceilingDB <= SignalGeneratorSettings.hardCeilingDB else {
            throw SystemSetupNoiseError.aboveCeiling
        }
        if isPlaying {
            if usesLiveGraph { try engine.setLiveGenerator(settings, selection: selection) }
            else { try session.update(settings, selection: selection) }
            return
        }
        if engine.liveGraphEditsAvailable {
            try engine.setLiveGenerator(settings, selection: selection)
            usesLiveGraph = true
            isPlaying = true
            return
        }
        if engine.lifecycleState != .idle {
            throw SystemSetupNoiseError.engineRefused(
                "Playback is running on a renderer that cannot add the setup noise. Stop playback in the main window, then play the noise.")
        }
        let request = try environment.makeRequest()
        monitor.stop()
        try session.start(request, settings: settings, selection: selection)
        guard let ring = session.ring else { session.stop(); throw MeasurementLevelSessionError.deviceFailure("no meter ring") }
        monitor.weighting = .c
        monitor.attach(ring: ring, sampleRate: session.sampleRate)
        usesLiveGraph = false
        isPlaying = true
        observeOutputChange()
    }

    func stop() {
        outputObserver = nil
        if usesLiveGraph {
            for _ in 0..<2 {
                if (try? engine.setLiveGenerator(nil, selection: .allProgram(includeLFE: false))) != nil {
                    isPlaying = false
                    usesLiveGraph = false
                    return
                }
            }
            return
        }
        guard isPlaying else { return }
        session.stop()
        monitor.stop()
        isPlaying = session.isRunning
    }

    /// The noise belongs to the output it started on: any change of the selected output stops it.
    private func observeOutputChange() {
        let started = engine.routeConfiguration.selectedOutputUID
        outputObserver = engine.$routeConfiguration
            .map(\.selectedOutputUID).removeDuplicates().dropFirst()
            .sink { [weak self] uid in
                guard let self, self.isPlaying, uid != started else { return }
                self.stop()
                self.stopHandler?("The noise stopped because the output device changed.")
            }
    }
}
