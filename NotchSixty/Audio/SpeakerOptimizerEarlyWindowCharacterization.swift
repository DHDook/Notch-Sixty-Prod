import Foundation

struct SpeakerOptimizerEarlyWindowSettings: Codable, Equatable, Sendable {
    /// Keep a short amount of the response before the direct-arrival peak so
    /// the onset is not hard-truncated.
    var preArrivalMilliseconds: Double = 0.75
    /// Conservative default: long enough to retain whole-speaker integration,
    /// short enough to reduce later room energy at a ~1 m measurement.
    var postArrivalMilliseconds: Double = 6.0
    /// Raised-cosine fade at the end of the retained impulse segment.
    var fadeOutMilliseconds: Double = 1.5
    /// A gated response is not trusted until at least this many periods fit in
    /// the post-arrival window. With 6 ms and two cycles this is ~333 Hz.
    var minimumCyclesForReliableMagnitude: Double = 2.0

    func validate() -> Bool {
        preArrivalMilliseconds.isFinite
            && (0...2.0).contains(preArrivalMilliseconds)
            && postArrivalMilliseconds.isFinite
            && (3.0...12.0).contains(postArrivalMilliseconds)
            && fadeOutMilliseconds.isFinite
            && fadeOutMilliseconds >= 0.25
            && fadeOutMilliseconds <= postArrivalMilliseconds * 0.5
            && minimumCyclesForReliableMagnitude.isFinite
            && (1.0...4.0).contains(minimumCyclesForReliableMagnitude)
    }
}

struct SpeakerOptimizerEarlyWindowEvidence: Codable, Equatable, Sendable {
    var captureID: UUID
    var targetID: UUID
    var source: MultichannelCalibrationSource
    var sampleRate: Double
    var response: RoomCorrectionFrequencyResponse
    var directArrivalSeconds: Double
    var retainedPreArrivalMilliseconds: Double
    var retainedPostArrivalMilliseconds: Double
    var fadeOutMilliseconds: Double
    var minimumReliableFrequencyHz: Double
    var maximumReliableFrequencyHz: Double
    var microphoneCalibrationFingerprint: String?
    var microphoneCalibrationApplied: Bool
    /// This product is intentionally unavailable to coherent-sum / alignment
    /// code. Windowing changes phase; only the magnitude is retained.
    var magnitudeOnly: Bool = true
    /// A bounded installed-room gate is useful evidence, not an anechoic claim.
    var isAnechoic: Bool = false
    var warnings: [String]

    func validate() -> Bool {
        sampleRate.isFinite
            && sampleRate > 0
            && directArrivalSeconds.isFinite
            && directArrivalSeconds >= 0
            && retainedPreArrivalMilliseconds.isFinite
            && retainedPreArrivalMilliseconds >= 0
            && retainedPostArrivalMilliseconds.isFinite
            && retainedPostArrivalMilliseconds > 0
            && fadeOutMilliseconds.isFinite
            && fadeOutMilliseconds >= 0
            && minimumReliableFrequencyHz.isFinite
            && maximumReliableFrequencyHz.isFinite
            && minimumReliableFrequencyHz > 0
            && maximumReliableFrequencyHz > minimumReliableFrequencyHz
            && magnitudeOnly
            && !isAnechoic
            && response.phaseRadians == nil
            && !response.frequenciesHz.isEmpty
            && response.frequenciesHz.count == response.magnitudeDB.count
            && response.frequenciesHz.allSatisfy(\.isFinite)
            && response.magnitudeDB.allSatisfy(\.isFinite)
            && zip(response.frequenciesHz, response.frequenciesHz.dropFirst())
                .allSatisfy { $0 < $1 }
            && (response.frequenciesHz.first ?? 0) >= minimumReliableFrequencyHz - 1.0e-6
            && (response.frequenciesHz.last ?? .infinity) <= maximumReliableFrequencyHz + 1.0e-6
    }
}

enum SpeakerOptimizerEarlyWindowError: Error, Equatable, LocalizedError {
    case invalidSettings
    case invalidSampleRate(Double)
    case missingImpulseResponse
    case missingDirectArrival
    case invalidDirectArrival
    case insufficientPostArrivalImpulse
    case missingTransferFunction
    case invalidTransferFunction
    case microphoneCalibrationIdentityMismatch
    case invalidMicrophoneCalibration
    case noReliableFrequencyBand
    case characterizationIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .invalidSettings:
            return "Speaker characterization early-window settings are invalid."
        case .invalidSampleRate(let value):
            return "Speaker characterization sample rate \(value) Hz is invalid."
        case .missingImpulseResponse:
            return "Speaker characterization requires the in-memory deconvolved impulse response before compact persistence."
        case .missingDirectArrival:
            return "Speaker characterization requires a valid direct-arrival estimate."
        case .invalidDirectArrival:
            return "The recorded direct arrival falls outside the analyzed impulse response."
        case .insufficientPostArrivalImpulse:
            return "The analyzed impulse response is too short for the requested early window."
        case .missingTransferFunction:
            return "Speaker characterization requires the full analyzed transfer frequency grid."
        case .invalidTransferFunction:
            return "The full analyzed transfer response is invalid."
        case .microphoneCalibrationIdentityMismatch:
            return "The microphone calibration used for early-window analysis does not match the characterization microphone identity."
        case .invalidMicrophoneCalibration:
            return "The microphone calibration curve is invalid for early-window analysis."
        case .noReliableFrequencyBand:
            return "The requested early window leaves no conservatively reliable frequency band."
        case .characterizationIdentityMismatch:
            return "The analyzed measurement does not match the requested characterization target."
        }
    }
}

/// Derives a bounded, magnitude-only response from the deconvolved impulse
/// BEFORE Speaker Optimizer discards raw capture / impulse buffers.
///
/// This deliberately does not detect or claim the first room reflection. The
/// gate is an explicit analysis assumption. Its lower trust boundary follows
/// directly from gate duration, and the result remains tagged non-anechoic.
struct SpeakerOptimizerEarlyWindowAnalyzer: Sendable {
    func derive(
        channel: RoomCorrectionChannelMeasurement,
        captureID: UUID,
        target: SpeakerOptimizerCharacterizationTarget,
        sampleRate: Double,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        microphoneCalibration: RoomCorrectionMicrophoneCalibration?,
        settings: SpeakerOptimizerEarlyWindowSettings = .init()
    ) throws -> SpeakerOptimizerEarlyWindowEvidence {
        guard settings.validate() else {
            throw SpeakerOptimizerEarlyWindowError.invalidSettings
        }
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw SpeakerOptimizerEarlyWindowError.invalidSampleRate(sampleRate)
        }
        guard !channel.impulseResponse.isEmpty,
              channel.impulseResponse.allSatisfy(\.isFinite) else {
            throw SpeakerOptimizerEarlyWindowError.missingImpulseResponse
        }
        guard let arrivalSeconds = channel.quality.directArrivalSeconds else {
            throw SpeakerOptimizerEarlyWindowError.missingDirectArrival
        }
        let arrivalDouble = arrivalSeconds * sampleRate
        guard arrivalSeconds.isFinite, arrivalSeconds >= 0,
              arrivalDouble.isFinite else {
            throw SpeakerOptimizerEarlyWindowError.invalidDirectArrival
        }
        let arrivalFrame = Int(arrivalDouble.rounded())
        guard channel.impulseResponse.indices.contains(arrivalFrame) else {
            throw SpeakerOptimizerEarlyWindowError.invalidDirectArrival
        }
        guard let full = channel.transferFunction else {
            throw SpeakerOptimizerEarlyWindowError.missingTransferFunction
        }
        try validateTransferFunction(full)
        try validateCalibrationIdentity(
            microphone: microphone,
            calibration: microphoneCalibration
        )

        let preFrames = Int(
            (settings.preArrivalMilliseconds * sampleRate / 1_000).rounded()
        )
        let requestedPostFrames = Int(
            (settings.postArrivalMilliseconds * sampleRate / 1_000).rounded()
        )
        let fadeFrames = max(
            1,
            Int((settings.fadeOutMilliseconds * sampleRate / 1_000).rounded())
        )
        guard requestedPostFrames >= 2 else {
            throw SpeakerOptimizerEarlyWindowError.invalidSettings
        }

        let start = max(0, arrivalFrame - preFrames)
        let requestedEnd = arrivalFrame + requestedPostFrames + 1
        guard requestedEnd <= channel.impulseResponse.count else {
            throw SpeakerOptimizerEarlyWindowError.insufficientPostArrivalImpulse
        }
        let end = requestedEnd
        let actualPostSeconds = Double(end - arrivalFrame - 1) / sampleRate
        let actualPreSeconds = Double(arrivalFrame - start) / sampleRate
        guard actualPostSeconds > 0 else {
            throw SpeakerOptimizerEarlyWindowError.insufficientPostArrivalImpulse
        }

        let gateLimitedLow = settings.minimumCyclesForReliableMagnitude
            / actualPostSeconds
        let sourceLow = max(
            channel.quality.usableLowHz ?? (full.frequenciesHz.first ?? 0),
            gateLimitedLow
        )
        let sourceHigh = min(
            channel.quality.usableHighHz ?? (full.frequenciesHz.last ?? 0),
            sampleRate * 0.49
        )
        guard sourceLow.isFinite, sourceHigh.isFinite,
              sourceLow > 0, sourceHigh > sourceLow else {
            throw SpeakerOptimizerEarlyWindowError.noReliableFrequencyBand
        }

        let frequencies = full.frequenciesHz.filter {
            $0 >= sourceLow && $0 <= sourceHigh
        }
        guard frequencies.count >= 8,
              let first = frequencies.first,
              let last = frequencies.last,
              last > first else {
            throw SpeakerOptimizerEarlyWindowError.noReliableFrequencyBand
        }

        let taperStart = max(arrivalFrame, end - 1 - fadeFrames)
        var magnitudes: [Double] = []
        magnitudes.reserveCapacity(frequencies.count)

        for frequency in frequencies {
            var real = 0.0
            var imaginary = 0.0
            for frame in start..<end {
                let weight: Double
                if frame < arrivalFrame, arrivalFrame > start {
                    let x = Double(frame - start) / Double(arrivalFrame - start)
                    weight = 0.5 - 0.5 * cos(Double.pi * x)
                } else if frame > taperStart, end - 1 > taperStart {
                    let x = Double(frame - taperStart)
                        / Double(end - 1 - taperStart)
                    weight = 0.5 + 0.5 * cos(Double.pi * x)
                } else {
                    weight = 1.0
                }
                let value = Double(channel.impulseResponse[frame]) * weight
                let phase = -2.0 * Double.pi * frequency
                    * Double(frame) / sampleRate
                real += value * cos(phase)
                imaginary += value * sin(phase)
            }
            var magnitudeDB = 20.0 * log10(max(hypot(real, imaginary), 1.0e-12))
            if let microphoneCalibration {
                do {
                    magnitudeDB += try microphoneCalibration.gainDB(at: frequency)
                } catch {
                    throw SpeakerOptimizerEarlyWindowError.invalidMicrophoneCalibration
                }
            }
            guard magnitudeDB.isFinite else {
                throw SpeakerOptimizerEarlyWindowError.invalidTransferFunction
            }
            magnitudes.append(magnitudeDB)
        }

        let response = RoomCorrectionFrequencyResponse(
            frequenciesHz: frequencies,
            magnitudeDB: magnitudes,
            phaseRadians: nil
        )
        let result = SpeakerOptimizerEarlyWindowEvidence(
            captureID: captureID,
            targetID: target.id,
            source: target.source,
            sampleRate: sampleRate,
            response: response,
            directArrivalSeconds: arrivalSeconds,
            retainedPreArrivalMilliseconds: actualPreSeconds * 1_000,
            retainedPostArrivalMilliseconds: actualPostSeconds * 1_000,
            fadeOutMilliseconds: settings.fadeOutMilliseconds,
            minimumReliableFrequencyHz: first,
            maximumReliableFrequencyHz: last,
            microphoneCalibrationFingerprint: microphone.calibrationFingerprint,
            microphoneCalibrationApplied: microphoneCalibration != nil,
            warnings: [
                "Early-window characterization is magnitude-only and must not be used as synchronized crossover/timing phase evidence.",
                "The installed-room gate reduces later room energy but is not an anechoic or free-field measurement.",
                "Frequencies below the gate-derived reliability boundary remain governed by the listening-position campaign."
            ]
        )
        guard result.validate() else {
            throw SpeakerOptimizerEarlyWindowError.invalidTransferFunction
        }
        return result
    }

    private func validateTransferFunction(
        _ response: RoomCorrectionFrequencyResponse
    ) throws {
        guard !response.frequenciesHz.isEmpty,
              response.frequenciesHz.count == response.magnitudeDB.count,
              response.frequenciesHz.allSatisfy({ $0.isFinite && $0 > 0 }),
              response.magnitudeDB.allSatisfy(\.isFinite),
              zip(response.frequenciesHz, response.frequenciesHz.dropFirst())
                .allSatisfy({ $0 < $1 }) else {
            throw SpeakerOptimizerEarlyWindowError.invalidTransferFunction
        }
    }

    private func validateCalibrationIdentity(
        microphone: SpeakerOptimizerMicrophoneIdentity,
        calibration: RoomCorrectionMicrophoneCalibration?
    ) throws {
        guard microphone.validate() else {
            throw SpeakerOptimizerEarlyWindowError.microphoneCalibrationIdentityMismatch
        }
        if let fingerprint = microphone.calibrationFingerprint {
            guard let calibration,
                  calibration.sourceName == fingerprint else {
                throw SpeakerOptimizerEarlyWindowError
                    .microphoneCalibrationIdentityMismatch
            }
        }
        guard let calibration else { return }
        guard calibration.schemaVersion
                == RoomCorrectionMicrophoneCalibration.currentSchemaVersion,
              calibration.points.count >= 2 else {
            throw SpeakerOptimizerEarlyWindowError.invalidMicrophoneCalibration
        }
        var previous = 0.0
        for point in calibration.points {
            guard point.frequencyHz.isFinite,
                  point.frequencyHz > previous,
                  point.gainDB.isFinite else {
                throw SpeakerOptimizerEarlyWindowError.invalidMicrophoneCalibration
            }
            previous = point.frequencyHz
        }
    }
}

/// Single point where the ordinary in-memory calibration measurement becomes
/// compact characterization evidence. The early response is derived before the
/// impulse/raw capture is discarded.
struct SpeakerOptimizerCharacterizationCaptureBuilder: Sendable {
    private let earlyWindowAnalyzer = SpeakerOptimizerEarlyWindowAnalyzer()

    func build(
        measurement: MultichannelCalibrationMeasurement,
        playbackSystemID: UUID,
        routingSignature: String,
        microphone: SpeakerOptimizerMicrophoneIdentity,
        target: SpeakerOptimizerCharacterizationTarget,
        microphoneCalibration: RoomCorrectionMicrophoneCalibration?,
        settings: SpeakerOptimizerEarlyWindowSettings = .init()
    ) throws -> (
        capture: SpeakerOptimizerMeasurementCapture,
        earlyWindow: SpeakerOptimizerEarlyWindowEvidence
    ) {
        guard measurement.seatID == target.id,
              measurement.source == target.source,
              abs(measurement.sampleRate - measurement.sampleRate) < 0.5 else {
            throw SpeakerOptimizerEarlyWindowError.characterizationIdentityMismatch
        }
        let compact = try SpeakerOptimizerMeasurementCapture(
            compacting: measurement,
            playbackSystemID: playbackSystemID,
            routingSignature: routingSignature,
            microphone: microphone
        )
        let early = try earlyWindowAnalyzer.derive(
            channel: measurement.channel,
            captureID: measurement.id,
            target: target,
            sampleRate: measurement.sampleRate,
            microphone: microphone,
            microphoneCalibration: microphoneCalibration,
            settings: settings
        )
        return (compact, early)
    }
}
