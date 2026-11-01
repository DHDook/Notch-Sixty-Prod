import Combine
import Foundation

// E24 S1: Play/Stop for the Measure-tab Generator card. With playback on the graph renderer the generator joins the
// live graph (`AudioIOEngine.setLiveGenerator`); otherwise it runs in the measurement-owned level session. The core
// clamps the level to the ceiling, ramps over 100 ms and auto-stops (at most 10 minutes); this controller adds the
// stop on output change and the real error texts.
@MainActor
final class MeasurementGeneratorController: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var secondsRemaining: Int?
    @Published private(set) var message: String?

    private let engine: AudioIOEngine
    private let environment: LevelSessionEnvironment
    private let session: MeasurementLevelSession
    private var usesLiveGraph = false
    private var startedUID: String?
    private var outputObserver: AnyCancellable?
    private var countdown: Task<Void, Never>?

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController,
         transport: @escaping LevelSessionTransportFactory = LevelSessionHardware.transportFactory) {
        self.engine = engine
        environment = EngineLevelSessionEnvironment(engine: engine, profiles: profiles, microphone: microphone)
        session = MeasurementLevelSession(transport: transport)
        session.onEnded = { [weak self] _ in self?.ended("Stopped: the generator reached its time limit.") }
    }

    deinit { MainActor.assumeIsolated { countdown?.cancel() } }

    func toggle(_ settings: SignalGeneratorSettings) {
        if isPlaying { stop(); return }
        play(settings)
    }

    func play(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection = .allProgram(includeLFE: false)) {
        guard !isPlaying else { return update(settings) }
        do {
            guard settings.stageParams(active: true, sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000) != nil else {
                throw MeasurementLevelSessionError.invalidSettings
            }
            if engine.liveGraphEditsAvailable {
                try engine.setLiveGenerator(settings, selection: selection)
                usesLiveGraph = true
            } else if engine.lifecycleState != .idle {
                throw SystemSetupNoiseError.engineRefused(
                    "Playback is running on a renderer that cannot add the generator. Stop playback in the main window, then press Play.")
            } else {
                // The card has no microphone of its own: a mic is only needed for the meter, so use the selected one.
                try session.start(try environment.makeRequest(), settings: settings, selection: selection)
                usesLiveGraph = false
            }
        } catch {
            message = error.localizedDescription
            return
        }
        message = nil
        isPlaying = true
        startedUID = engine.routeConfiguration.selectedOutputUID
        outputObserver = engine.$routeConfiguration.map(\.selectedOutputUID).removeDuplicates().dropFirst()
            .sink { [weak self] uid in
                guard let self, self.isPlaying, uid != self.startedUID else { return }
                self.stop()
                self.message = "Stopped because the output device changed."
            }
        secondsRemaining = Int(settings.autoStopSeconds.rounded(.up))
        countdown?.cancel()
        countdown = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isPlaying, let left = self.secondsRemaining else { return }
                self.secondsRemaining = max(0, left - 1)
            }
        }
    }

    /// Live level or signal change while playing.
    func update(_ settings: SignalGeneratorSettings, selection: SignalGeneratorLaneSelection = .allProgram(includeLFE: false)) {
        guard isPlaying else { return }
        do {
            if usesLiveGraph { try engine.setLiveGenerator(settings, selection: selection) }
            else { try session.update(settings, selection: selection) }
        } catch {
            message = error.localizedDescription
        }
    }

    func stop() {
        if usesLiveGraph {
            for _ in 0..<2 where (try? engine.setLiveGenerator(nil, selection: .allProgram(includeLFE: false))) != nil {
                ended(nil)
                return
            }
            message = "The generator could not be stopped. Stop playback from the main window."
            return
        }
        session.stop()
        if !session.isRunning { ended(nil) }
    }

    private func ended(_ reason: String?) {
        isPlaying = false
        secondsRemaining = nil
        countdown?.cancel()
        outputObserver = nil
        usesLiveGraph = false
        if let reason { message = reason }
    }
}
