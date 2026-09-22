struct StereoMeterReading: Equatable, Sendable {
    let peakLeft: Float
    let peakRight: Float
    let rmsLeft: Float
    let rmsRight: Float
    let overRangeSamples: UInt64

    init(_ reading: N60StereoMeterReading) {
        peakLeft = reading.peakLeft
        peakRight = reading.peakRight
        rmsLeft = reading.rmsLeft
        rmsRight = reading.rmsRight
        overRangeSamples = reading.overRangeSamples
    }
}

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
    let inputGainLinear: Float
    let headroomGainLinear: Float
    let outputGainLinear: Float
    let eqBypassed: Bool
    let eqBandCount: UInt32
    let crossoverEnabled: Bool
    let crossoverFrequencyHz: Double
    let crossoverTopology: N60CrossoverTopology
    let crossoverMonitorMode: N60CrossoverMonitorMode
    let crossoverSubGainLinear: Float
    let crossoverSubPolarityInverted: Bool
    let crossoverSectionCount: UInt32
    let inputMeter: StereoMeterReading
    let postEQMeter: StereoMeterReading
    let outputMeter: StereoMeterReading

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
        inputGainLinear = diagnostics.inputGainLinear
        headroomGainLinear = diagnostics.headroomGainLinear
        outputGainLinear = diagnostics.outputGainLinear
        eqBypassed = diagnostics.eqBypassed
        eqBandCount = diagnostics.eqBandCount
        crossoverEnabled = diagnostics.crossoverEnabled
        crossoverFrequencyHz = diagnostics.crossoverFrequencyHz
        crossoverTopology = diagnostics.crossoverTopology
        crossoverMonitorMode = diagnostics.crossoverMonitorMode
        crossoverSubGainLinear = diagnostics.crossoverSubGainLinear
        crossoverSubPolarityInverted = diagnostics.crossoverSubPolarityInverted
        crossoverSectionCount = diagnostics.crossoverSectionCount
        inputMeter = StereoMeterReading(diagnostics.inputMeter)
        postEQMeter = StereoMeterReading(diagnostics.postEQMeter)
        outputMeter = StereoMeterReading(diagnostics.outputMeter)
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
