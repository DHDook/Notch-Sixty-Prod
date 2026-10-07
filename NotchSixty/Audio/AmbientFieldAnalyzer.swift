import Accelerate
import Foundation

enum AmbientSeparationMode: String, Codable, Equatable, Sendable {
    case microphoneOnly
    case modeledPlaybackSubtraction
    case playbackModelUnavailable
}

enum AmbientNoiseCharacter: String, Codable, Equatable, Sendable {
    case quiet
    case broadband
    case tonal
    case tonalPeriodic
    case nonstationary
    case mixed
}

struct AmbientPlaybackSourceReference: Equatable, Sendable {
    let id: String
    let samples: [Float]
    let acousticImpulseResponse: [Float]?

    init(
        id: String,
        samples: [Float],
        acousticImpulseResponse: [Float]? = nil
    ) {
        self.id = id
        self.samples = samples
        self.acousticImpulseResponse = acousticImpulseResponse
    }
}

struct AmbientSpectrumBand: Identifiable, Equatable, Sendable {
    let lowerFrequencyHz: Double
    let centerFrequencyHz: Double
    let upperFrequencyHz: Double
    let levelDBFS: Double

    var id: Double { centerFrequencyHz }
}

struct AmbientTonalComponent: Identifiable, Equatable, Sendable {
    let frequencyHz: Double
    let levelDBFS: Double
    let prominenceDB: Double

    var id: Double { frequencyHz }
}

struct AmbientAnalysisSnapshot: Equatable, Sendable {
    let sampleRate: Double
    let analyzedFrames: Int
    let separationMode: AmbientSeparationMode
    let separationConfidence: Double
    let predictionGain: Double?
    let microphoneLevelDBFS: Double
    let predictedPlaybackLevelDBFS: Double?
    let ambientLevelDBFS: Double
    let ambientLevelDBSPL: Double?
    let stationarityScore: Double
    let periodicityScore: Double
    let periodicFrequencyHz: Double?
    let lowFrequencyEnergyFraction: Double
    let cancellationCandidateScore: Double
    let character: AmbientNoiseCharacter
    let spectrum: [AmbientSpectrumBand]
    let tonalComponents: [AmbientTonalComponent]
}

struct AmbientAnalysisConfiguration: Equatable, Sendable {
    var minimumAnalysisFrames = 4_096
    var maximumAnalysisFrames = 65_536
    var maximumImpulseTaps = 8_192
    var spectrumBandCount = 64
    var segmentCount = 8
    var minimumFrequencyHz = 20.0
    var maximumFrequencyHz = 20_000.0
    var lowFrequencyUpperHz = 250.0
    var tonalSearchUpperHz = 1_000.0
    var minimumTonalProminenceDB = 8.0
    var maximumTonalComponents = 8
    var negligiblePlaybackDBFS = -70.0
    var maximumPlaybackAlignmentSeconds = 0.35
    var alignmentSearchRateHz = 2_000.0
    var optionalDBSPLAt0DBFS: Double?

    static let production = AmbientAnalysisConfiguration()
}

enum AmbientAnalysisError: Error, Equatable, LocalizedError {
    case invalidSampleRate(Double)
    case insufficientSamples(minimum: Int, actual: Int)
    case playbackLengthMismatch(microphone: Int, playback: Int)
    case nonFiniteMicrophone
    case nonFinitePlayback
    case invalidAcousticModel
    case invalidConfiguration
    case transformTooLarge(Int)
    case transformSetupFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSampleRate(let rate):
            return "Ambient analysis sample rate \(rate) Hz is invalid."
        case .insufficientSamples(let minimum, let actual):
            return "Ambient analysis requires at least \(minimum) samples; \(actual) were provided."
        case .playbackLengthMismatch(let microphone, let playback):
            return "Ambient analysis microphone/playback lengths differ (\(microphone) vs \(playback))."
        case .nonFiniteMicrophone:
            return "Ambient analysis microphone samples contain non-finite values."
        case .nonFinitePlayback:
            return "Ambient analysis playback samples contain non-finite values."
        case .invalidAcousticModel:
            return "Ambient analysis acoustic-model impulse response is invalid."
        case .invalidConfiguration:
            return "Ambient analysis configuration is invalid."
        case .transformTooLarge(let size):
            return "Ambient analysis requires an unsupported transform size of \(size) samples."
        case .transformSetupFailed(let size):
            return "Ambient analysis could not create an Accelerate transform of \(size) samples."
        }
    }
}

/// Passive, offline/control-plane ambient-field estimator.
///
/// This analyzer never generates cancellation audio. It accepts a microphone
/// observation plus an optional copy of the known playback signal and a measured
/// speaker-to-microphone impulse response. When both references are usable, the
/// known playback contribution is predicted and removed before environmental
/// statistics are computed.
///
/// A future live worker can feed this type from bounded copied microphone and
/// playback-history rings. No Core Audio callback calls this analyzer.
struct AmbientFieldAnalyzer: Sendable {
    let configuration: AmbientAnalysisConfiguration

    init(configuration: AmbientAnalysisConfiguration = .production) {
        self.configuration = configuration
    }

    func analyze(
        microphone: [Float],
        playbackReference: [Float]? = nil,
        acousticImpulseResponse: [Float]? = nil,
        sampleRate: Double
    ) throws -> AmbientAnalysisSnapshot {
        let sources: [AmbientPlaybackSourceReference]
        if let playbackReference {
            sources = [
                AmbientPlaybackSourceReference(
                    id: "playback",
                    samples: playbackReference,
                    acousticImpulseResponse: acousticImpulseResponse
                )
            ]
        } else {
            sources = []
        }
        return try analyze(
            microphone: microphone,
            playbackSources: sources,
            sampleRate: sampleRate
        )
    }

    /// Multichannel-ready control-plane entry point. Each semantic speaker/source
    /// contributes its known playback history and measured source-to-microphone
    /// impulse response. Predictions are summed in the acoustic domain before one
    /// bounded microphone/reference gain fit is estimated.
    func analyze(
        microphone: [Float],
        playbackSources: [AmbientPlaybackSourceReference],
        sampleRate: Double
    ) throws -> AmbientAnalysisSnapshot {
        try validateConfiguration()
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AmbientAnalysisError.invalidSampleRate(sampleRate)
        }
        guard microphone.count >= configuration.minimumAnalysisFrames else {
            throw AmbientAnalysisError.insufficientSamples(
                minimum: configuration.minimumAnalysisFrames,
                actual: microphone.count
            )
        }
        guard microphone.allSatisfy(\.isFinite) else {
            throw AmbientAnalysisError.nonFiniteMicrophone
        }
        for source in playbackSources {
            guard source.samples.count == microphone.count else {
                throw AmbientAnalysisError.playbackLengthMismatch(
                    microphone: microphone.count,
                    playback: source.samples.count
                )
            }
            guard source.samples.allSatisfy(\.isFinite) else {
                throw AmbientAnalysisError.nonFinitePlayback
            }
            if let impulse = source.acousticImpulseResponse {
                guard !impulse.isEmpty,
                      impulse.allSatisfy(\.isFinite),
                      impulse.contains(where: { abs($0) > 1.0e-12 }) else {
                    throw AmbientAnalysisError.invalidAcousticModel
                }
            }
        }

        let frameCount = min(microphone.count, configuration.maximumAnalysisFrames)
        let microphoneWindow = Array(microphone.suffix(frameCount))
        let sourceWindows = playbackSources.map { source in
            AmbientPlaybackSourceReference(
                id: source.id,
                samples: Array(source.samples.suffix(frameCount)),
                acousticImpulseResponse: source.acousticImpulseResponse
            )
        }

        let microphoneRMS = Self.rms(microphoneWindow)
        let microphoneLevel = Self.dbfs(amplitude: microphoneRMS)

        var separationMode: AmbientSeparationMode = .microphoneOnly
        var confidence = 1.0
        var predictionGain: Double?
        var predictedLevel: Double?
        var residual = microphoneWindow

        let audibleSources = sourceWindows.filter {
            Self.dbfs(amplitude: Self.rms($0.samples))
                > configuration.negligiblePlaybackDBFS
        }
        if !audibleSources.isEmpty {
            if audibleSources.contains(where: { $0.acousticImpulseResponse == nil }) {
                // Never reinterpret known-but-unmodeled program audio as ambient
                // noise. A later live controller must acquire/resolve the missing
                // acoustic path before it can trust the residual field.
                separationMode = .playbackModelUnavailable
                confidence = 0.15
            } else {
                var predicted = [Float](repeating: 0, count: frameCount)
                for source in audibleSources {
                    guard let sourceImpulse = source.acousticImpulseResponse else { continue }
                    let impulse = Array(
                        sourceImpulse.prefix(configuration.maximumImpulseTaps)
                    )
                    let contribution = try predictPlayback(
                        playback: source.samples,
                        impulseResponse: impulse
                    )
                    for index in predicted.indices {
                        predicted[index] += contribution[index]
                    }
                }

                let alignment = estimatePlaybackAlignment(
                    microphone: microphoneWindow,
                    predictedPlayback: predicted,
                    sampleRate: sampleRate
                )
                let alignedPrediction = alignment.alignedPlayback
                let estimate = estimatePlaybackScale(
                    microphone: microphoneWindow,
                    predictedPlayback: alignedPrediction
                )
                predictionGain = estimate.gain
                predictedLevel = Self.dbfs(
                    amplitude: Self.rms(alignedPrediction)
                        * estimate.gain
                )
                residual = zip(
                    microphoneWindow,
                    alignedPrediction
                ).map {
                    Float(
                        Double($0.0)
                            - estimate.gain * Double($0.1)
                    )
                }
                separationMode = .modeledPlaybackSubtraction
                confidence = estimate.confidence
                    * alignment.confidence
            }
        }

        let ambientRMS = Self.rms(residual)
        let ambientLevel = Self.dbfs(amplitude: ambientRMS)
        let spectralFrame = try makeSpectralFrame(
            samples: residual,
            sampleRate: sampleRate
        )
        let spectrum = makeSpectrumBands(
            spectralFrame: spectralFrame,
            sampleRate: sampleRate
        )
        let tones = makeTonalComponents(
            spectralFrame: spectralFrame,
            sampleRate: sampleRate
        )
        let stationarity = stationarityScore(samples: residual)
        let periodicity = try periodicity(
            samples: residual,
            sampleRate: sampleRate
        )
        let lowFrequencyFraction = Self.lowFrequencyFraction(
            spectrum: spectrum,
            upperHz: min(configuration.lowFrequencyUpperHz, sampleRate * 0.49)
        )
        let cancellationCandidate = Self.clamp01(
            confidence
                * stationarity
                * min(1.0, lowFrequencyFraction * 1.25 + periodicity.score * 0.15)
        )
        let character = Self.classify(
            ambientLevelDBFS: ambientLevel,
            stationarity: stationarity,
            periodicity: periodicity.score,
            strongestToneProminenceDB: tones.first?.prominenceDB
        )
        let spl = configuration.optionalDBSPLAt0DBFS.map { ambientLevel + $0 }

        return AmbientAnalysisSnapshot(
            sampleRate: sampleRate,
            analyzedFrames: frameCount,
            separationMode: separationMode,
            separationConfidence: Self.clamp01(confidence),
            predictionGain: predictionGain,
            microphoneLevelDBFS: microphoneLevel,
            predictedPlaybackLevelDBFS: predictedLevel,
            ambientLevelDBFS: ambientLevel,
            ambientLevelDBSPL: spl,
            stationarityScore: stationarity,
            periodicityScore: periodicity.score,
            periodicFrequencyHz: periodicity.frequencyHz,
            lowFrequencyEnergyFraction: lowFrequencyFraction,
            cancellationCandidateScore: cancellationCandidate,
            character: character,
            spectrum: spectrum,
            tonalComponents: tones
        )
    }

    private func validateConfiguration() throws {
        guard configuration.minimumAnalysisFrames >= 256,
              configuration.maximumAnalysisFrames >= configuration.minimumAnalysisFrames,
              configuration.maximumAnalysisFrames <= 131_072,
              configuration.maximumImpulseTaps > 0,
              configuration.maximumImpulseTaps <= 32_768,
              configuration.spectrumBandCount >= 8,
              configuration.spectrumBandCount <= 256,
              configuration.segmentCount >= 2,
              configuration.segmentCount <= 32,
              configuration.minimumFrequencyHz.isFinite,
              configuration.minimumFrequencyHz > 0,
              configuration.maximumFrequencyHz.isFinite,
              configuration.maximumFrequencyHz > configuration.minimumFrequencyHz,
              configuration.lowFrequencyUpperHz.isFinite,
              configuration.lowFrequencyUpperHz > configuration.minimumFrequencyHz,
              configuration.tonalSearchUpperHz.isFinite,
              configuration.tonalSearchUpperHz > configuration.minimumFrequencyHz,
              configuration.minimumTonalProminenceDB.isFinite,
              configuration.maximumTonalComponents > 0,
              configuration.maximumPlaybackAlignmentSeconds.isFinite,
              configuration.maximumPlaybackAlignmentSeconds >= 0,
              configuration.maximumPlaybackAlignmentSeconds <= 1.0,
              configuration.alignmentSearchRateHz.isFinite,
              configuration.alignmentSearchRateHz >= 500,
              configuration.alignmentSearchRateHz <= 8_000 else {
            throw AmbientAnalysisError.invalidConfiguration
        }
    }

    private func predictPlayback(
        playback: [Float],
        impulseResponse: [Float]
    ) throws -> [Float] {
        let convolutionCount = playback.count + impulseResponse.count - 1
        let transformSize = try Self.transformSize(required: convolutionCount)
        let dft = try AmbientDFT(size: transformSize)
        let playbackSpectrum = dft.forward(playback)
        let impulseSpectrum = dft.forward(impulseResponse)

        var productReal = [Float](repeating: 0, count: transformSize)
        var productImaginary = [Float](repeating: 0, count: transformSize)
        for index in 0..<transformSize {
            let ar = playbackSpectrum.real[index]
            let ai = playbackSpectrum.imaginary[index]
            let br = impulseSpectrum.real[index]
            let bi = impulseSpectrum.imaginary[index]
            productReal[index] = ar * br - ai * bi
            productImaginary[index] = ar * bi + ai * br
        }
        let convolved = dft.inverse(real: productReal, imaginary: productImaginary)
        return Array(convolved.prefix(playback.count))
    }

    private struct PlaybackAlignmentEstimate {
        var alignedPlayback: [Float]
        var lagFrames: Int
        var confidence: Double
    }

    /// Estimate the bounded timing offset between the independently clocked
    /// microphone capture and the rendered-playback history. The retained room
    /// impulse already contains acoustic propagation delay; this search only
    /// compensates transport/history offset and slow clock drift.
    ///
    /// A coarse decimated normalized correlation keeps the search bounded, then
    /// a one-stride full-rate refinement provides sample-level alignment. The
    /// analyzer remains entirely off the realtime thread.
    private func estimatePlaybackAlignment(
        microphone: [Float],
        predictedPlayback: [Float],
        sampleRate: Double
    ) -> PlaybackAlignmentEstimate {
        guard microphone.count == predictedPlayback.count,
              !microphone.isEmpty,
              configuration.maximumPlaybackAlignmentSeconds > 0 else {
            return PlaybackAlignmentEstimate(
                alignedPlayback: predictedPlayback,
                lagFrames: 0,
                confidence: 1
            )
        }

        let maximumLag = min(
            Int(
                (
                    sampleRate
                        * configuration
                            .maximumPlaybackAlignmentSeconds
                ).rounded()
            ),
            max(microphone.count / 3, 0)
        )
        guard maximumLag > 0 else {
            return PlaybackAlignmentEstimate(
                alignedPlayback: predictedPlayback,
                lagFrames: 0,
                confidence: 1
            )
        }

        let stride = max(
            Int(
                (
                    sampleRate
                        / configuration.alignmentSearchRateHz
                ).rounded()
            ),
            1
        )
        let coarseMaximum =
            max(maximumLag / stride, 1)

        var bestLag = 0
        var bestCorrelation = -Double.infinity

        for coarse in (-coarseMaximum)...coarseMaximum {
            let lag = coarse * stride
            let correlation = normalizedCorrelation(
                microphone: microphone,
                reference: predictedPlayback,
                lagFrames: lag,
                sampleStride: stride
            )
            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestLag = lag
            }
        }

        let refineLow = max(
            -maximumLag,
            bestLag - stride
        )
        let refineHigh = min(
            maximumLag,
            bestLag + stride
        )
        if refineLow <= refineHigh {
            for lag in refineLow...refineHigh {
                let correlation = normalizedCorrelation(
                    microphone: microphone,
                    reference: predictedPlayback,
                    lagFrames: lag,
                    sampleStride: 1
                )
                if correlation > bestCorrelation {
                    bestCorrelation = correlation
                    bestLag = lag
                }
            }
        }

        var aligned = [Float](
            repeating: 0,
            count: predictedPlayback.count
        )
        var overlap = 0
        for index in aligned.indices {
            let sourceIndex = index - bestLag
            guard sourceIndex >= 0,
                  sourceIndex < predictedPlayback.count else {
                continue
            }
            aligned[index] = predictedPlayback[sourceIndex]
            overlap += 1
        }

        let overlapFraction =
            Double(overlap) / Double(max(aligned.count, 1))
        let correlationConfidence = Self.clamp01(
            (max(bestCorrelation, 0) - 0.05) / 0.55
        )
        let boundaryFraction =
            maximumLag > 0
                ? Double(abs(bestLag)) / Double(maximumLag)
                : 0
        let boundaryConfidence = Self.clamp01(
            (1.0 - boundaryFraction) / 0.15
        )
        let confidence = Self.clamp01(
            correlationConfidence
                * overlapFraction
                * max(boundaryConfidence, 0.15)
        )

        return PlaybackAlignmentEstimate(
            alignedPlayback: aligned,
            lagFrames: bestLag,
            confidence: confidence
        )
    }

    /// Correlates microphone[index] with reference[index - lag].
    private func normalizedCorrelation(
        microphone: [Float],
        reference: [Float],
        lagFrames: Int,
        sampleStride: Int
    ) -> Double {
        var dot = 0.0
        var microphoneEnergy = 0.0
        var referenceEnergy = 0.0
        var count = 0

        var index = 0
        while index < microphone.count {
            let referenceIndex = index - lagFrames
            if referenceIndex >= 0,
               referenceIndex < reference.count {
                let observed = Double(microphone[index])
                let modeled = Double(reference[referenceIndex])
                dot += observed * modeled
                microphoneEnergy += observed * observed
                referenceEnergy += modeled * modeled
                count += 1
            }
            index += max(sampleStride, 1)
        }

        guard count >= 64,
              microphoneEnergy > 1.0e-18,
              referenceEnergy > 1.0e-18 else {
            return -1
        }
        return dot / sqrt(
            microphoneEnergy * referenceEnergy
        )
    }

    private func estimatePlaybackScale(
        microphone: [Float],
        predictedPlayback: [Float]
    ) -> (gain: Double, confidence: Double) {
        let global = Self.leastSquaresGain(
            observed: microphone,
            reference: predictedPlayback
        )
        let gain = min(max(global ?? 1.0, 0.0), 4.0)
        guard let global, global > 0.025 else {
            return (gain, 0.20)
        }

        let segmentCount = min(configuration.segmentCount, microphone.count / 256)
        guard segmentCount >= 2 else { return (gain, 0.35) }
        let segmentLength = microphone.count / segmentCount
        var gains: [Double] = []
        var residualCorrelations: [Double] = []
        gains.reserveCapacity(segmentCount)
        residualCorrelations.reserveCapacity(segmentCount)

        for segment in 0..<segmentCount {
            let start = segment * segmentLength
            let end = segment == segmentCount - 1
                ? microphone.count
                : start + segmentLength
            guard end > start else { continue }

            var observed: [Float] = []
            var reference: [Float] = []
            observed.reserveCapacity(end - start)
            reference.reserveCapacity(end - start)
            for index in start..<end {
                observed.append(microphone[index])
                reference.append(predictedPlayback[index])
            }

            let referenceLevel = Self.dbfs(amplitude: Self.rms(reference))
            guard referenceLevel > configuration.negligiblePlaybackDBFS else { continue }
            if let localGain = Self.leastSquaresGain(
                observed: observed,
                reference: reference
            ) {
                gains.append(min(max(localGain, 0.0), 4.0))
                let residual = zip(observed, reference).map {
                    Float(Double($0.0) - gain * Double($0.1))
                }
                residualCorrelations.append(abs(Self.correlation(
                    residual,
                    reference
                ) ?? 0))
            }
        }

        guard gains.count >= 2 else { return (gain, 0.45) }
        let mean = gains.reduce(0, +) / Double(gains.count)
        let variance = gains.reduce(0.0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        } / Double(gains.count)
        let normalizedSpread = sqrt(variance) / max(abs(mean), 0.10)
        let gainStability = exp(-normalizedSpread / 0.35)
        let residualCorrelation = residualCorrelations.isEmpty
            ? 0.5
            : residualCorrelations.reduce(0, +) / Double(residualCorrelations.count)
        let decorrelation = 1.0 - min(max(residualCorrelation, 0), 1)
        let confidence = 0.15 + 0.55 * gainStability + 0.30 * decorrelation
        return (gain, Self.clamp01(confidence))
    }

    private func makeSpectralFrame(
        samples: [Float],
        sampleRate: Double
    ) throws -> AmbientSpectralFrame {
        let size = try Self.transformSize(required: samples.count)
        let dft = try AmbientDFT(size: size)
        var windowed = [Float](repeating: 0, count: samples.count)
        var windowEnergy = 0.0
        if samples.count == 1 {
            windowed[0] = samples[0]
            windowEnergy = 1
        } else {
            let denominator = Double(samples.count - 1)
            for index in samples.indices {
                let window = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(index) / denominator)
                windowed[index] = samples[index] * Float(window)
                windowEnergy += window * window
            }
        }
        let spectrum = dft.forward(windowed)
        return AmbientSpectralFrame(
            size: size,
            real: spectrum.real,
            imaginary: spectrum.imaginary,
            windowEnergy: max(windowEnergy, Double.leastNonzeroMagnitude)
        )
    }

    private func makeSpectrumBands(
        spectralFrame: AmbientSpectralFrame,
        sampleRate: Double
    ) -> [AmbientSpectrumBand] {
        let nyquist = sampleRate * 0.5
        let minimum = max(
            configuration.minimumFrequencyHz,
            sampleRate / Double(spectralFrame.size)
        )
        let maximum = min(configuration.maximumFrequencyHz, nyquist * 0.98)
        guard maximum > minimum else { return [] }
        let ratio = maximum / minimum
        var bands: [AmbientSpectrumBand] = []
        bands.reserveCapacity(configuration.spectrumBandCount)

        for band in 0..<configuration.spectrumBandCount {
            let lowerFraction = Double(band) / Double(configuration.spectrumBandCount)
            let upperFraction = Double(band + 1) / Double(configuration.spectrumBandCount)
            let lower = minimum * pow(ratio, lowerFraction)
            let upper = minimum * pow(ratio, upperFraction)
            let center = sqrt(lower * upper)
            let firstBin = max(
                1,
                Int(floor(lower * Double(spectralFrame.size) / sampleRate))
            )
            let lastBin = min(
                spectralFrame.size / 2 - 1,
                max(firstBin, Int(ceil(upper * Double(spectralFrame.size) / sampleRate)))
            )
            var magnitudeSquared = 0.0
            if firstBin <= lastBin {
                for bin in firstBin...lastBin {
                    let real = Double(spectralFrame.real[bin])
                    let imaginary = Double(spectralFrame.imaginary[bin])
                    magnitudeSquared += real * real + imaginary * imaginary
                }
            }
            let power = 2.0 * magnitudeSquared
                / (Double(spectralFrame.size) * spectralFrame.windowEnergy)
            bands.append(AmbientSpectrumBand(
                lowerFrequencyHz: lower,
                centerFrequencyHz: center,
                upperFrequencyHz: upper,
                levelDBFS: Self.dbfs(power: power)
            ))
        }
        return bands
    }

    private func makeTonalComponents(
        spectralFrame: AmbientSpectralFrame,
        sampleRate: Double
    ) -> [AmbientTonalComponent] {
        let maximum = min(configuration.tonalSearchUpperHz, sampleRate * 0.49)
        let firstBin = max(
            2,
            Int(ceil(configuration.minimumFrequencyHz * Double(spectralFrame.size) / sampleRate))
        )
        let lastBin = min(
            spectralFrame.size / 2 - 2,
            Int(floor(maximum * Double(spectralFrame.size) / sampleRate))
        )
        guard lastBin > firstBin else { return [] }

        var candidates: [AmbientTonalComponent] = []
        for bin in firstBin...lastBin {
            let power = Self.binPower(
                real: spectralFrame.real[bin],
                imaginary: spectralFrame.imaginary[bin],
                transformSize: spectralFrame.size,
                windowEnergy: spectralFrame.windowEnergy
            )
            let previous = Self.binPower(
                real: spectralFrame.real[bin - 1],
                imaginary: spectralFrame.imaginary[bin - 1],
                transformSize: spectralFrame.size,
                windowEnergy: spectralFrame.windowEnergy
            )
            let next = Self.binPower(
                real: spectralFrame.real[bin + 1],
                imaginary: spectralFrame.imaginary[bin + 1],
                transformSize: spectralFrame.size,
                windowEnergy: spectralFrame.windowEnergy
            )
            guard power > previous, power >= next else { continue }

            var neighborhood: [Double] = []
            let lower = max(firstBin, bin - 12)
            let upper = min(lastBin, bin + 12)
            for neighbor in lower...upper where abs(neighbor - bin) > 2 {
                neighborhood.append(Self.binPower(
                    real: spectralFrame.real[neighbor],
                    imaginary: spectralFrame.imaginary[neighbor],
                    transformSize: spectralFrame.size,
                    windowEnergy: spectralFrame.windowEnergy
                ))
            }
            guard !neighborhood.isEmpty else { continue }
            neighborhood.sort()
            let noisePower = neighborhood[neighborhood.count / 2]
            let prominence = 10.0 * log10(
                max(power, 1.0e-30) / max(noisePower, 1.0e-30)
            )
            guard prominence >= configuration.minimumTonalProminenceDB else { continue }

            candidates.append(AmbientTonalComponent(
                frequencyHz: Double(bin) * sampleRate / Double(spectralFrame.size),
                levelDBFS: Self.dbfs(power: power),
                prominenceDB: prominence
            ))
        }

        // Prominence is the admission criterion; level is the ranking
        // criterion. Otherwise a vanishingly small model/subtraction residue can
        // outrank a materially louder ambient tone merely because the bins
        // around the residue are even quieter.
        candidates.sort {
            if $0.levelDBFS == $1.levelDBFS {
                return $0.prominenceDB > $1.prominenceDB
            }
            return $0.levelDBFS > $1.levelDBFS
        }

        var accepted: [AmbientTonalComponent] = []
        for candidate in candidates {
            let duplicate = accepted.contains {
                abs($0.frequencyHz - candidate.frequencyHz)
                    < max(sampleRate / Double(spectralFrame.size) * 3.0, candidate.frequencyHz * 0.025)
            }
            if !duplicate {
                accepted.append(candidate)
                if accepted.count == configuration.maximumTonalComponents { break }
            }
        }
        return accepted
    }

    private func stationarityScore(samples: [Float]) -> Double {
        let segmentCount = min(configuration.segmentCount, samples.count / 256)
        guard segmentCount >= 2 else { return 0 }
        let length = samples.count / segmentCount
        var levels: [Double] = []
        levels.reserveCapacity(segmentCount)
        for segment in 0..<segmentCount {
            let start = segment * length
            let end = segment == segmentCount - 1 ? samples.count : start + length
            guard end > start else { continue }
            var sum = 0.0
            for index in start..<end {
                let value = Double(samples[index])
                sum += value * value
            }
            let rms = sqrt(sum / Double(end - start))
            levels.append(Self.dbfs(amplitude: rms))
        }
        guard levels.count >= 2 else { return 0 }
        let mean = levels.reduce(0, +) / Double(levels.count)
        let variance = levels.reduce(0.0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        } / Double(levels.count)
        return Self.clamp01(exp(-sqrt(variance) / 6.0))
    }

    private func periodicity(
        samples: [Float],
        sampleRate: Double
    ) throws -> (score: Double, frequencyHz: Double?) {
        let mean = samples.reduce(0.0) { $0 + Double($1) } / Double(samples.count)
        let centered = samples.map { Float(Double($0) - mean) }
        let transformSize = try Self.transformSize(required: centered.count * 2)
        let dft = try AmbientDFT(size: transformSize)
        let spectrum = dft.forward(centered)
        var powerReal = [Float](repeating: 0, count: transformSize)
        let powerImaginary = [Float](repeating: 0, count: transformSize)
        for index in 0..<transformSize {
            let real = spectrum.real[index]
            let imaginary = spectrum.imaginary[index]
            powerReal[index] = real * real + imaginary * imaginary
        }
        let autocorrelation = dft.inverse(
            real: powerReal,
            imaginary: powerImaginary
        )
        let zero = Double(autocorrelation[0])
        guard zero.isFinite, zero > 1.0e-20 else { return (0, nil) }

        let minimumLag = max(1, Int(floor(sampleRate / configuration.tonalSearchUpperHz)))
        let maximumLag = min(
            centered.count / 2,
            Int(ceil(sampleRate / configuration.minimumFrequencyHz))
        )
        guard maximumLag > minimumLag else { return (0, nil) }

        var bestScore = 0.0
        var bestLag = 0
        for lag in minimumLag...maximumLag {
            let normalized = Double(autocorrelation[lag]) / zero
            if normalized > bestScore {
                bestScore = normalized
                bestLag = lag
            }
        }
        let score = Self.clamp01(bestScore)
        return (
            score,
            bestLag > 0 ? sampleRate / Double(bestLag) : nil
        )
    }

    private static func leastSquaresGain(
        observed: [Float],
        reference: [Float]
    ) -> Double? {
        guard observed.count == reference.count, !observed.isEmpty else { return nil }
        var cross = 0.0
        var referenceEnergy = 0.0
        for index in observed.indices {
            let observedValue = Double(observed[index])
            let referenceValue = Double(reference[index])
            cross += observedValue * referenceValue
            referenceEnergy += referenceValue * referenceValue
        }
        guard referenceEnergy > 1.0e-20 else { return nil }
        let gain = cross / referenceEnergy
        return gain.isFinite ? gain : nil
    }

    private static func correlation(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        var cross = 0.0
        var lhsEnergy = 0.0
        var rhsEnergy = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index])
            let right = Double(rhs[index])
            cross += left * right
            lhsEnergy += left * left
            rhsEnergy += right * right
        }
        let denominator = sqrt(lhsEnergy * rhsEnergy)
        guard denominator > 1.0e-20 else { return nil }
        return min(max(cross / denominator, -1), 1)
    }

    private static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0
        for sample in samples {
            let value = Double(sample)
            sum += value * value
        }
        return sqrt(sum / Double(samples.count))
    }

    private static func dbfs(amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 1.0e-15 else { return -300 }
        return 20.0 * log10(amplitude)
    }

    private static func dbfs(power: Double) -> Double {
        guard power.isFinite, power > 1.0e-30 else { return -300 }
        return 10.0 * log10(power)
    }

    private static func binPower(
        real: Float,
        imaginary: Float,
        transformSize: Int,
        windowEnergy: Double
    ) -> Double {
        let r = Double(real)
        let i = Double(imaginary)
        return 2.0 * (r * r + i * i)
            / (Double(transformSize) * windowEnergy)
    }

    private static func lowFrequencyFraction(
        spectrum: [AmbientSpectrumBand],
        upperHz: Double
    ) -> Double {
        var lowPower = 0.0
        var totalPower = 0.0
        for band in spectrum {
            let power = pow(10.0, band.levelDBFS / 10.0)
            totalPower += power
            if band.centerFrequencyHz <= upperHz {
                lowPower += power
            }
        }
        guard totalPower > 0 else { return 0 }
        return clamp01(lowPower / totalPower)
    }

    private static func classify(
        ambientLevelDBFS: Double,
        stationarity: Double,
        periodicity: Double,
        strongestToneProminenceDB: Double?
    ) -> AmbientNoiseCharacter {
        if ambientLevelDBFS < -100 { return .quiet }
        if stationarity < 0.45 { return .nonstationary }
        let prominence = strongestToneProminenceDB ?? 0
        if prominence >= 12, periodicity >= 0.45 { return .tonalPeriodic }
        if prominence >= 8 { return .tonal }
        if periodicity >= 0.45 { return .mixed }
        return .broadband
    }

    private static func transformSize(required: Int) throws -> Int {
        guard required > 0 else { return 1 }
        var size = 1
        while size < required {
            guard size <= 262_144 else {
                throw AmbientAnalysisError.transformTooLarge(required)
            }
            size <<= 1
        }
        guard size <= 524_288 else {
            throw AmbientAnalysisError.transformTooLarge(size)
        }
        return size
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private struct AmbientSpectrum {
    let real: [Float]
    let imaginary: [Float]
}

private struct AmbientSpectralFrame {
    let size: Int
    let real: [Float]
    let imaginary: [Float]
    let windowEnergy: Double
}

private final class AmbientDFT {
    private let size: Int
    private let forwardSetup: vDSP_DFT_Setup
    private let inverseSetup: vDSP_DFT_Setup
    private let zeroImaginary: [Float]

    init(size: Int) throws {
        guard let forwardSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(size),
            .FORWARD
        ) else {
            throw AmbientAnalysisError.transformSetupFailed(size)
        }
        guard let inverseSetup = vDSP_DFT_zop_CreateSetup(
            nil,
            vDSP_Length(size),
            .INVERSE
        ) else {
            vDSP_DFT_DestroySetup(forwardSetup)
            throw AmbientAnalysisError.transformSetupFailed(size)
        }
        self.size = size
        self.forwardSetup = forwardSetup
        self.inverseSetup = inverseSetup
        zeroImaginary = [Float](repeating: 0, count: size)
    }

    deinit {
        vDSP_DFT_DestroySetup(forwardSetup)
        vDSP_DFT_DestroySetup(inverseSetup)
    }

    func forward(_ source: [Float]) -> AmbientSpectrum {
        precondition(source.count <= size)
        var padded = [Float](repeating: 0, count: size)
        if !source.isEmpty {
            padded.replaceSubrange(0..<source.count, with: source)
        }
        var real = [Float](repeating: 0, count: size)
        var imaginary = [Float](repeating: 0, count: size)
        padded.withUnsafeBufferPointer { inputReal in
            zeroImaginary.withUnsafeBufferPointer { inputImaginary in
                real.withUnsafeMutableBufferPointer { outputReal in
                    imaginary.withUnsafeMutableBufferPointer { outputImaginary in
                        vDSP_DFT_Execute(
                            forwardSetup,
                            inputReal.baseAddress!,
                            inputImaginary.baseAddress!,
                            outputReal.baseAddress!,
                            outputImaginary.baseAddress!
                        )
                    }
                }
            }
        }
        return AmbientSpectrum(real: real, imaginary: imaginary)
    }

    func inverse(real: [Float], imaginary: [Float]) -> [Float] {
        precondition(real.count == size && imaginary.count == size)
        var outputReal = [Float](repeating: 0, count: size)
        var outputImaginary = [Float](repeating: 0, count: size)
        real.withUnsafeBufferPointer { inputReal in
            imaginary.withUnsafeBufferPointer { inputImaginary in
                outputReal.withUnsafeMutableBufferPointer { realResult in
                    outputImaginary.withUnsafeMutableBufferPointer { imaginaryResult in
                        vDSP_DFT_Execute(
                            inverseSetup,
                            inputReal.baseAddress!,
                            inputImaginary.baseAddress!,
                            realResult.baseAddress!,
                            imaginaryResult.baseAddress!
                        )
                    }
                }
            }
        }
        let scale = 1.0 / Float(size)
        for index in outputReal.indices {
            outputReal[index] *= scale
        }
        return outputReal
    }
}
