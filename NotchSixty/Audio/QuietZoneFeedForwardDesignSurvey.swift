import Foundation

/// E4 S9b2: the in-app measurement behind the feed-forward design.
///
/// - Reference to seat: the H1 transfer and coherence from the noise itself,
///   with the reference and error microphones on two channels of the project
///   microphone's device (one clock), by `N60FeedForwardSurvey`.
/// - Speaker leakage into the reference: one room-correction sweep per
///   speaker, captured on the reference channel.
/// - Secondary paths at the seat: the Room Correction position model the
///   tonal canceller already uses.
///
/// Nothing here can authorize live output: the design it feeds is a preview
/// until the live-ANC authorisation path says otherwise.
struct QuietZoneFeedForwardSurveyBand: Codable, Equatable, Sendable {
    var frequencyHz: Double
    /// H1 transfer, reference microphone to error (seat) microphone.
    var referenceToSeat: ActiveQuietZoneComplex
    var coherence: Double
}

struct QuietZoneFeedForwardLeakage: Codable, Equatable, Sendable {
    var sampleRate: Double
    /// Each speaker's impulse response at the reference microphone, from the
    /// start of playback (so it keeps the output-to-input latency).
    var leftImpulseResponse: [Float]
    var rightImpulseResponse: [Float]
    var capturedAt: Date
}

struct QuietZoneFeedForwardDesignSurvey: Codable, Equatable, Sendable {
    static let schemaVersion = 2
    var version: Int = schemaVersion
    var projectID: UUID
    /// The input device both microphones share.
    var microphoneStableID: String
    var errorChannel: Int
    var referenceChannel: Int
    var sampleRate: Double
    var capturedAt: Date
    var segments: Int
    var bands: [QuietZoneFeedForwardSurveyBand]
    /// v1: the native-rate response of one sweep. v2: the mean echo model at fd, with its delay
    /// as leading zeros, so the designer's band assembly reads it unchanged.
    var leakage: QuietZoneFeedForwardLeakage?
    /// E4 S22b2: the three-sweep echo model (v2). A v1 file has none; see `echoModelOrLegacy`.
    var echoModel: FeedForwardEchoModel?

    /// The model that drives echo removal. A v1 leakage becomes a one-repeat model without a
    /// bound, which the stability check reports as "not checked".
    var echoModelOrLegacy: FeedForwardEchoModel? {
        if let echoModel { return echoModel }
        guard let leakage else { return nil }
        return try? FeedForwardEchoModelBuilder.build(
            left: [leakage.leftImpulseResponse], right: [leakage.rightImpulseResponse],
            nativeSampleRate: leakage.sampleRate, capturedAt: leakage.capturedAt
        )
    }

    /// The same device and channels: a new noise survey may keep the leakage.
    func sameInputs(as other: QuietZoneFeedForwardDesignSurvey) -> Bool {
        projectID == other.projectID && microphoneStableID == other.microphoneStableID
            && errorChannel == other.errorChannel && referenceChannel == other.referenceChannel
    }
}

extension FeedForwardEchoModel {
    /// The mean path at fd with its delay as leading zeros.
    func asLeakage() -> QuietZoneFeedForwardLeakage {
        QuietZoneFeedForwardLeakage(
            sampleRate: sampleRate,
            leftImpulseResponse: [Float](repeating: 0, count: left.bulkDelay) + left.taps,
            rightImpulseResponse: [Float](repeating: 0, count: right.bulkDelay) + right.taps,
            capturedAt: capturedAt
        )
    }
}

enum QuietZoneFeedForwardSurveyGrid {
    /// 1/6-octave grid from 25 Hz: 16 bands to 141 Hz, inside the designer's
    /// 25–150 Hz.
    static let frequenciesHz: [Double] = (0..<16).map { 25 * pow(2, Double($0) / 6) }
    static let minimumCoherence = QuietZoneVirtualSeatDesigner.minimumCoherence
    /// Coherence is biased high over the first few Welch segments.
    static let minimumSegments = 8
    static let defaultDurationSeconds = 60.0
}

enum QuietZoneFeedForwardSurveyError: Error, Equatable, LocalizedError {
    case incompatibleProject
    case referenceChannelMissing
    case referenceChannelUnavailable(Int)
    case noiseSurveyMissing
    case referenceIsErrorChannel
    case microphonePermissionRequired
    case playbackMustBeIdle
    case noOutputSelected
    case alreadyRunning
    case captureFault
    case notEnoughSegments(Int)
    case noCoherentBands
    case leakageMissing
    case positionModelMissing
    case corruptSidecar

    var errorDescription: String? {
        switch self {
        case .incompatibleProject:
            return "Choose a Room Correction project whose microphone is the selected input."
        case .referenceChannelMissing:
            return "Choose the reference microphone's channel on the same interface."
        case .referenceChannelUnavailable(let channel):
            return "Reference channel \(channel + 1) is not an input channel of the seat microphone's interface."
        case .noiseSurveyMissing:
            return "Measure the reference to seat transfer first, with the same channels."
        case .referenceIsErrorChannel:
            return "The reference microphone must be on a different channel from the seat microphone."
        case .microphonePermissionRequired:
            return "Microphone access is required."
        case .playbackMustBeIdle:
            return "Stop playback before measuring speaker leakage."
        case .noOutputSelected:
            return "Choose a playback output first."
        case .alreadyRunning:
            return "A feed-forward measurement is already running."
        case .captureFault:
            return "The two-channel capture dropped or lost samples; measure again."
        case .notEnoughSegments(let segments):
            return "Only \(segments) analysis segments were captured; at least \(QuietZoneFeedForwardSurveyGrid.minimumSegments) are needed."
        case .noCoherentBands:
            return "No band reached coherence \(QuietZoneFeedForwardSurveyGrid.minimumCoherence) between the microphones. Measure while the noise to cancel is present and playback is paused."
        case .leakageMissing:
            return "Measure speaker leakage into the reference microphone."
        case .positionModelMissing:
            return "Select a Room Correction position with left and right impulse responses."
        case .corruptSidecar:
            return "The saved feed-forward survey could not be read."
        }
    }
}

struct QuietZoneFeedForwardDesignSurveyStore: Sendable {
    var roomStore: RoomCorrectionProjectStore

    func url(for projectID: UUID) -> URL {
        roomStore.projectDirectory(for: projectID)
            .appendingPathComponent("quiet-zone-feed-forward-survey-v1.json")
    }

    /// nil if none is saved. A survey from another project or microphone
    /// device is refused.
    func load(for project: RoomCorrectionProject) throws -> QuietZoneFeedForwardDesignSurvey? {
        let location = url(for: project.id)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        let survey: QuietZoneFeedForwardDesignSurvey
        do {
            survey = try JSONDecoder().decode(
                QuietZoneFeedForwardDesignSurvey.self, from: Data(contentsOf: location)
            )
        } catch {
            throw QuietZoneFeedForwardSurveyError.corruptSidecar
        }
        guard survey.projectID == project.id,
              survey.microphoneStableID == project.microphone?.stableID,
              survey.errorChannel == project.microphone?.inputChannelIndex
        else { throw QuietZoneFeedForwardSurveyError.incompatibleProject }
        return survey
    }

    func save(_ survey: QuietZoneFeedForwardDesignSurvey, project: RoomCorrectionProject) throws {
        guard survey.projectID == project.id,
              survey.microphoneStableID == project.microphone?.stableID,
              survey.errorChannel == project.microphone?.inputChannelIndex
        else { throw QuietZoneFeedForwardSurveyError.incompatibleProject }
        let directory = roomStore.projectDirectory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(survey).write(to: url(for: project.id), options: .atomic)
    }
}

/// Turns a survey and the seat's position model into the designer's bands.
struct QuietZoneFeedForwardBandAssembler: Sendable {
    struct Result: Equatable, Sendable {
        var bands: [QuietZoneVirtualSeatBand]
        /// Bands left out for coherence below the designer's minimum.
        var rejectedFrequenciesHz: [Double]
    }

    func assemble(
        survey: QuietZoneFeedForwardDesignSurvey,
        position: RoomCorrectionMeasurementPosition
    ) throws -> Result {
        guard let leakage = survey.leakage else { throw QuietZoneFeedForwardSurveyError.leakageMissing }
        guard !position.left.impulseResponse.isEmpty, !position.right.impulseResponse.isEmpty else {
            throw QuietZoneFeedForwardSurveyError.positionModelMissing
        }
        var bands: [QuietZoneVirtualSeatBand] = []
        var rejected: [Double] = []
        for band in survey.bands {
            guard band.coherence >= QuietZoneFeedForwardSurveyGrid.minimumCoherence else {
                rejected.append(band.frequencyHz)
                continue
            }
            let f = band.frequencyHz
            bands.append(QuietZoneVirtualSeatBand(
                frequencyHz: f,
                // The designer uses only sourceToListener / sourceToReference.
                sourceToReference: ActiveQuietZoneComplex(real: 1, imaginary: 0),
                sourceToListener: band.referenceToSeat,
                leftSecondaryAtListener: Self.response(position.left.impulseResponse, f, position.sampleRate),
                rightSecondaryAtListener: Self.response(position.right.impulseResponse, f, position.sampleRate),
                leftLeakageAtReference: Self.response(leakage.leftImpulseResponse, f, leakage.sampleRate),
                rightLeakageAtReference: Self.response(leakage.rightImpulseResponse, f, leakage.sampleRate),
                measuredCoherence: band.coherence
            ))
        }
        guard !bands.isEmpty else { throw QuietZoneFeedForwardSurveyError.noCoherentBands }
        return Result(bands: bands, rejectedFrequenciesHz: rejected)
    }

    /// H(f) = sum h[n] exp(-j 2 pi f n / fs), any length (the planner's
    /// helper caps at 32,768 samples, under 0.1 s at 384 kHz).
    static func response(_ impulse: [Float], _ hz: Double, _ sampleRate: Double) -> ActiveQuietZoneComplex {
        let step = -2 * Double.pi * hz / sampleRate
        var re = 0.0, im = 0.0
        var pr = 1.0, pi = 0.0
        let (sr, si) = (cos(step), sin(step))
        for (n, value) in impulse.enumerated() {
            re += Double(value) * pr
            im += Double(value) * pi
            if n % 4_096 == 4_095 {  // re-anchor the phasor
                let angle = step * Double(n + 1)
                (pr, pi) = (cos(angle), sin(angle))
            } else {
                (pr, pi) = (pr * sr - pi * si, pr * si + pi * sr)
            }
        }
        return ActiveQuietZoneComplex(real: re, imaginary: im)
    }
}
