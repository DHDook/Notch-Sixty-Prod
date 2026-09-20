struct AudioDiagnosticsSnapshot: Equatable, Sendable {
    let lifecycleState: AudioLifecycleState
    let selectedOutputUID: String?
    let selectedOutputName: String?
    let selectedOutputPresent: Bool
    let selectedOutputNominalSampleRate: Double?
    let discoveredOutputCount: Int
    let tapSampleRate: Double?
    let outputSampleRate: Double?
    let transportCounters: AudioTransportCounters
    let sampleRateChangesHandled: UInt64
    let recoveryAttempts: UInt64
    let recoverySuccesses: UInt64
    let recoveryFailures: UInt64
    let lastErrorDescription: String?
}
