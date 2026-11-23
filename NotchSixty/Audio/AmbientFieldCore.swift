import Foundation

/// Swift face of the ambient field analysis in `libn60core` (`n60/anc_design.h` version 2, E21 S10b).
///
/// Offline only: `AmbientFieldAnalyzer` calls it on the ambient worker, never from an audio callback, and it never produces
/// audio. It is reached when `e21.core-designers` is on; off, the Swift maths in `AmbientFieldAnalyzer` runs unchanged (the
/// parity reference, deleted in S14). Value types and the controller stay in Swift. Nothing here arms or enables live ANC.
enum AmbientFieldCore {
    static func coreConfiguration(_ configuration: AmbientAnalysisConfiguration) -> n60_ambient_config {
        var core = n60_ambient_config()
        n60_ambient_config_default(&core)
        core.minimumAnalysisFrames = Int32(clamping: configuration.minimumAnalysisFrames)
        core.maximumAnalysisFrames = Int32(clamping: configuration.maximumAnalysisFrames)
        core.maximumImpulseTaps = Int32(clamping: configuration.maximumImpulseTaps)
        core.spectrumBandCount = Int32(clamping: configuration.spectrumBandCount)
        core.segmentCount = Int32(clamping: configuration.segmentCount)
        core.minimumFrequencyHz = configuration.minimumFrequencyHz
        core.maximumFrequencyHz = configuration.maximumFrequencyHz
        core.lowFrequencyUpperHz = configuration.lowFrequencyUpperHz
        core.tonalSearchUpperHz = configuration.tonalSearchUpperHz
        core.minimumTonalProminenceDB = configuration.minimumTonalProminenceDB
        core.maximumTonalComponents = Int32(clamping: configuration.maximumTonalComponents)
        core.negligiblePlaybackDBFS = configuration.negligiblePlaybackDBFS
        core.maximumPlaybackAlignmentSeconds = configuration.maximumPlaybackAlignmentSeconds
        core.alignmentSearchRateHz = configuration.alignmentSearchRateHz
        return core
    }

    static func error(_ code: Int32, sampleRate: Double, microphone: Int, minimum: Int) -> AmbientAnalysisError {
        switch code {
        case N60_AMBIENT_ERR_SAMPLE_RATE: return .invalidSampleRate(sampleRate)
        case N60_AMBIENT_ERR_INSUFFICIENT: return .insufficientSamples(minimum: minimum, actual: microphone)
        case N60_AMBIENT_ERR_NONFINITE_MICROPHONE: return .nonFiniteMicrophone
        case N60_AMBIENT_ERR_NONFINITE_PLAYBACK: return .nonFinitePlayback
        case N60_AMBIENT_ERR_ACOUSTIC_MODEL: return .invalidAcousticModel
        case N60_AMBIENT_ERR_TRANSFORM_TOO_LARGE: return .transformTooLarge(microphone)
        case N60_AMBIENT_ERR_CONFIGURATION: return .invalidConfiguration
        default: return .invalidConfiguration
        }
    }

    private static func bands(_ rows: [n60_ambient_band], count: Int) -> [AmbientSpectrumBand] {
        rows.prefix(count).map {
            AmbientSpectrumBand(
                lowerFrequencyHz: $0.lowerFrequencyHz, centerFrequencyHz: $0.centerFrequencyHz,
                upperFrequencyHz: $0.upperFrequencyHz, levelDBFS: $0.levelDBFS)
        }
    }

    static func analyze(
        configuration: AmbientAnalysisConfiguration,
        microphone: [Float],
        playbackSources: [AmbientPlaybackSourceReference],
        sampleRate: Double
    ) throws -> AmbientAnalysisDetailedResult {
        var core = coreConfiguration(configuration)
        for source in playbackSources where source.samples.count != microphone.count {
            throw AmbientAnalysisError.playbackLengthMismatch(microphone: microphone.count, playback: source.samples.count)
        }
        let frames = Int(n60_ambient_window_frames(&core, UInt32(clamping: microphone.count)))
        var result = n60_ambient_result()
        var spectrum = [n60_ambient_band](repeating: n60_ambient_band(), count: Int(N60_AMBIENT_MAX_BANDS))
        var modeled = spectrum
        let toneCapacity = max(1, min(configuration.maximumTonalComponents, 64))
        var tones = [n60_ambient_tone](repeating: n60_ambient_tone(), count: toneCapacity)
        var residual = [Float](repeating: 0, count: max(frames, 1))

        // Sources are flattened into two contiguous arrays (analysis worker, off the audio thread) so the pointers stay valid
        // for the whole call without nested pinning.
        let frameCount = microphone.count
        var flatSamples = [Float]()
        flatSamples.reserveCapacity(frameCount * playbackSources.count)
        var flatImpulses = [Float]()
        var impulseRanges: [(offset: Int, count: Int)?] = []
        for source in playbackSources {
            flatSamples.append(contentsOf: source.samples)
            if let impulse = source.acousticImpulseResponse {
                impulseRanges.append((flatImpulses.count, impulse.count))
                flatImpulses.append(contentsOf: impulse)
            } else {
                impulseRanges.append(nil)
            }
        }
        let code: Int32 = microphone.withUnsafeBufferPointer { mic in
            flatSamples.withUnsafeBufferPointer { samples in
                flatImpulses.withUnsafeBufferPointer { impulses in
                    var coreSources = [n60_ambient_source]()
                    for (index, range) in impulseRanges.enumerated() {
                        coreSources.append(
                            n60_ambient_source(
                                samples: samples.baseAddress.map { $0 + index * frameCount },
                                impulse: range.flatMap { _ in impulses.baseAddress.map { $0 + range!.offset } },
                                impulseCount: UInt32(range?.count ?? 0)))
                    }
                    return n60_ambient_analyze(
                        &core, mic.baseAddress, UInt32(clamping: mic.count), coreSources, UInt32(coreSources.count),
                        sampleRate, &result, &spectrum, &modeled, &tones, UInt32(tones.count), &residual)
                }
            }
        }
        guard code == 0 else {
            throw error(
                code, sampleRate: sampleRate, microphone: microphone.count, minimum: configuration.minimumAnalysisFrames)
        }

        var mode: AmbientSeparationMode = .microphoneOnly
        switch result.separationMode {
        case Int32(N60_AMBIENT_MODE_MODELED_SUBTRACTION): mode = .modeledPlaybackSubtraction
        case Int32(N60_AMBIENT_MODE_MODEL_UNAVAILABLE): mode = .playbackModelUnavailable
        default: break
        }
        let character: AmbientNoiseCharacter
        switch result.character {
        case Int32(N60_AMBIENT_CHARACTER_QUIET): character = .quiet
        case Int32(N60_AMBIENT_CHARACTER_TONAL): character = .tonal
        case Int32(N60_AMBIENT_CHARACTER_TONAL_PERIODIC): character = .tonalPeriodic
        case Int32(N60_AMBIENT_CHARACTER_NONSTATIONARY): character = .nonstationary
        case Int32(N60_AMBIENT_CHARACTER_MIXED): character = .mixed
        default: character = .broadband
        }
        let snapshot = AmbientAnalysisSnapshot(
            sampleRate: sampleRate,
            analyzedFrames: Int(result.analyzedFrames),
            separationMode: mode,
            separationConfidence: result.separationConfidence,
            predictionGain: result.hasPredictionGain != 0 ? result.predictionGain : nil,
            microphoneLevelDBFS: result.microphoneLevelDBFS,
            predictedPlaybackLevelDBFS: result.hasPredictedLevel != 0 ? result.predictedPlaybackLevelDBFS : nil,
            ambientLevelDBFS: result.ambientLevelDBFS,
            ambientLevelDBSPL: configuration.optionalDBSPLAt0DBFS.map { result.ambientLevelDBFS + $0 },
            stationarityScore: result.stationarityScore,
            periodicityScore: result.periodicityScore,
            periodicFrequencyHz: result.hasPeriodicFrequency != 0 ? result.periodicFrequencyHz : nil,
            lowFrequencyEnergyFraction: result.lowFrequencyEnergyFraction,
            cancellationCandidateScore: result.cancellationCandidateScore,
            character: character,
            spectrum: bands(spectrum, count: Int(result.spectrumCount)),
            tonalComponents: tones.prefix(Int(result.tonalCount)).map {
                AmbientTonalComponent(
                    frequencyHz: $0.frequencyHz, levelDBFS: $0.levelDBFS, prominenceDB: $0.prominenceDB,
                    phaseRadians: $0.phaseRadians)
            })
        return AmbientAnalysisDetailedResult(
            snapshot: snapshot,
            separatedResidualSamples: Array(residual.prefix(frames)),
            playbackAlignmentLagFrames: result.hasAlignment != 0 ? Int(result.alignmentLagFrames) : nil,
            playbackAlignmentConfidence: result.hasAlignment != 0 ? result.alignmentConfidence : nil,
            modeledPlaybackSpectrum: result.hasModeledSpectrum != 0 ? bands(modeled, count: Int(result.spectrumCount)) : nil)
    }
}
