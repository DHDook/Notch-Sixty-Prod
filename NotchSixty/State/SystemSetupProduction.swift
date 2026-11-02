import Foundation

// E24 S0: one place that builds the services the guided-setup window runs on. The app and the
// end-to-end harness both call `ProductionSystemSetupServices.production`, so the harness exercises the
// wiring the user gets, not a test-only copy of it.

/// The services behind the Level and Verify steps.
@MainActor
struct ProductionSystemSetupServices {
    let noise: SystemSetupNoisePlaying
    /// The measure step's seat measurer (E24 S5b1). The flow's `measureAll` and `remeasure` own no measure loop.
    let seats: SystemSetupSeatMeasuring
    let verifier: SystemSetupPostApplyMeasuring
    /// The verifier, with the hook the flow uses to say what to check.
    let measurer: SystemSetupPostApplyMeasurer
    /// The meter the Level step reads: fed by the level session while noise plays, by the microphone otherwise.
    let monitor: MeasurementInputMonitor
    /// Lanes the noise can play on right now.
    let laneChoices: @MainActor () -> [(index: Int, name: String, isLFE: Bool)]

    /// Production wiring for `engine`. E24 S1: the noise runs in a measurement-owned level session when
    /// playback is idle (`levelTransport` is the Core Audio boundary tests replace).
    static func production(
        engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController,
        calibration: MultichannelCalibrationController,
        monitor: MeasurementInputMonitor? = nil,
        seats: SystemSetupSeatMeasuring? = nil,
        levelTransport: @escaping LevelSessionTransportFactory = LevelSessionHardware.transportFactory,
        trialPlayback: TrialSweepPlaying? = nil
    ) -> ProductionSystemSetupServices {
        let monitor = monitor ?? MeasurementInputMonitor()
        let environment = EngineLevelSessionEnvironment(engine: engine, profiles: profiles, microphone: microphone)
        let host = EngineRoomCorrectionTrialHost(
            playback: trialPlayback ?? EngineTrialSweepPlayer(engine: engine, microphone: microphone))
        let measurer = SystemSetupPostApplyMeasurer(host: host)
        return ProductionSystemSetupServices(
            noise: LevelSessionNoisePlayer(engine: engine, environment: environment, monitor: monitor, transport: levelTransport),
            seats: seats ?? CalibrationSeatMeasurer(calibration: calibration),
            verifier: measurer, measurer: measurer,
            monitor: monitor,
            laneChoices: { environment.laneChoices })
    }
}
