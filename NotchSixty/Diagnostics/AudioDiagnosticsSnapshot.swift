struct AudioDiagnosticsSnapshot: Equatable, Sendable {
    let lifecycleState: AudioLifecycleState
    let selectedOutputUID: String?
    let selectedOutputName: String?
    let selectedOutputPresent: Bool
    let selectedOutputNominalSampleRate: Double?
    let discoveredOutputCount: Int
    let lastErrorDescription: String?
}
