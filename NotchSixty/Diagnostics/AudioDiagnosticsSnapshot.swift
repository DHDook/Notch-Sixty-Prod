struct RenderKernelDiagnostics: Equatable, Sendable {
    let renderedFrames: UInt64
    let sanitizedNonFiniteSamples: UInt64
    let flushedDenormalSamples: UInt64
    let snapshotReadMisses: UInt64
    let publishedGeneration: UInt64
    let latencyFrames: UInt32
    let sampleRate: Double
    let channelCount: UInt32
    let bypassed: Bool
    let eqBypassed: Bool
    let eqBandCount: UInt32

    init(_ diagnostics: N60RenderKernelDiagnostics) {
        renderedFrames = diagnostics.renderedFrames
        sanitizedNonFiniteSamples = diagnostics.sanitizedNonFiniteSamples
        flushedDenormalSamples = diagnostics.flushedDenormalSamples
        snapshotReadMisses = diagnostics.snapshotReadMisses
        publishedGeneration = diagnostics.publishedGeneration
        latencyFrames = diagnostics.latencyFrames
        sampleRate = diagnostics.sampleRate
        channelCount = diagnostics.channelCount
        bypassed = diagnostics.bypassed
        eqBypassed = diagnostics.eqBypassed
        eqBandCount = diagnostics.eqBandCount
    }
}

struct AudioDiagnosticsSnapshot: Equatable, Sendable {
    let lifecycleState: AudioLifecycleState
    let selectedOutputUID: String?
    let selectedOutputName: String?
    let selectedOutputPresent: Bool
    let selectedOutputNominalSampleRate: Double?
    let discoveredOutputCount: Int
    let tapSampleRate: Double?
    let outputSampleRate: Double?
    let sessionTransportCounters: AudioTransportCounters
    let lifetimeTransportCounters: AudioTransportCounters
    let renderKernelDiagnostics: RenderKernelDiagnostics?
    let startupGateOpened: Bool?
    let startupGateTargetFrames: UInt32?
    let startupGateActivationFrames: UInt32?
    let sampleRateChangesHandled: UInt64
    let recoveryAttempts: UInt64
    let recoverySuccesses: UInt64
    let recoveryFailures: UInt64
    let lastErrorDescription: String?
}
