import Foundation

// E24 S0: one place that builds the services the guided-setup window runs on. The app and the
// end-to-end harness both call `ProductionSystemSetupServices.production`, so the harness exercises the
// wiring the user gets, not a test-only copy of it.

/// The services behind the Level and Verify steps.
@MainActor
struct ProductionSystemSetupServices {
    let noise: SystemSetupNoisePlaying
    let verifier: SystemSetupPostApplyMeasuring

    /// Production wiring for `engine`.
    static func production(engine: AudioIOEngine) -> ProductionSystemSetupServices {
        ProductionSystemSetupServices(
            noise: EngineSystemSetupNoisePlayer(host: engine),
            verifier: UnconnectedSystemSetupPostApplyMeasurer())
    }
}
