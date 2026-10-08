import Foundation

/// PR96 offline model of a single movable microphone:
/// listener A -> upstream doorway -> listener B.
/// These records require source-trigger timestamps from a genuinely shared
/// or cross-calibrated hardware clock. A phone replay started by hand or
/// unsynchronized Core Audio sweeps are not valid timing evidence.
enum QuietZoneFeedForwardPosition: String, Codable, Equatable, Sendable {
    case listenerFirst
    case upstream
    case listenerReturn
}

struct QuietZoneFeedForwardArrival: Codable, Equatable, Sendable {
    var position: QuietZoneFeedForwardPosition
    var sourceTriggerID: String
    var synchronizedClockID: String
    var microphoneDeviceID: String
    var microphoneChannel: Int
    var routeFingerprint: String
    var sampleRate: Double
    /// Arrival relative to the trigger, in a timebase calibrated against
    /// both the playback command and the input clock.
    var arrivalAfterTriggerSeconds: Double
    var oneSigmaTimingUncertaintySeconds: Double
    var snrDB: Double
    var clipped: Bool = false
}

struct QuietZoneFeedForwardTimingPath: Codable, Equatable, Sendable {
    var synchronizedClockID: String
    var microphoneDeviceID: String
    var microphoneChannel: Int
    var routeFingerprint: String
    var sampleRate: Double

    /// Measured ADC/input and reference acquisition latency, including its
    /// physical buffer/scheduling delay. This is NOT inferred from hop count.
    var referenceAcquisitionSeconds: Double
    /// Measured maximum reference sample -> anti-noise command scheduling
    /// latency, including all DSP and any plugin/buffer delay.
    var referenceProcessingSeconds: Double
    /// Measured anti-noise output command -> listener physical sound delay:
    /// output buffer, DAC, speaker electroacoustics and sound flight.
    var commandToSeatSeconds: Double
    var totalWorstCaseJitterSeconds: Double
    var timingUncertaintySeconds: Double
    /// True only if the controller's real-time monitoring path was actually
    /// characterized, rather than assumed from existing 250ms PR90 polling.
    var lowLatencyTransportVerified: Bool
}

struct QuietZoneFeedForwardCalibration: Codable, Equatable, Sendable {
    static let schemaVersion = 1
    var version: Int = schemaVersion
    var projectID: UUID
    var playbackSystemID: UUID
    var listenerPositionID: UUID
    var upstreamLabel: String
    var microphoneStableID: String
    var capturedAt: Date = Date()
    var arrivals: [QuietZoneFeedForwardArrival] = []
    var timingPath: QuietZoneFeedForwardTimingPath?

    /// Raw noisy measurement data are not persisted; only bounded timing
    /// evidence and provenance are kept.
}

enum QuietZoneFeedForwardReadiness: String, Equatable, Sendable {
    case missingMeasurements
    case invalidTimebase
    case unreliableMeasurements
    case nonCausal
    case limitedMargin
    case physicallyPlausible
}

struct QuietZoneFeedForwardBudget: Equatable, Sendable {
    var readiness: QuietZoneFeedForwardReadiness
    var acousticPreviewSeconds: Double?
    var conservativePreviewSeconds: Double?
    var antiNoisePathSeconds: Double?
    var conservativeReserveSeconds: Double?
    var geometryOnly: Bool
    var runtimeAvailable: Bool
    var explanation: String

    static let missing = QuietZoneFeedForwardBudget(
        readiness: .missingMeasurements,
        acousticPreviewSeconds: nil,
        conservativePreviewSeconds: nil,
        antiNoisePathSeconds: nil,
        conservativeReserveSeconds: nil,
        geometryOnly: false,
        runtimeAvailable: false,
        explanation: "Capture repeatable source-triggered measurements at the listener, upstream, then listener again. A separate calibrated anti-noise path is also required."
    )
}

enum QuietZoneFeedForwardError: Error, LocalizedError, Equatable {
    case incompatibleProject
    case incompleteCapture
    case incompatibleClock
    case poorQuality
    case sourceDrift
    case invalidPath
    case staleData
    case noLiveTransport
    case corruptSidecar

    var errorDescription: String? {
        switch self {
        case .incompatibleProject: return "Feed-forward calibration belongs to a different Room Correction project, playback route or microphone."
        case .incompleteCapture: return "The listener → upstream → listener timing survey is incomplete."
        case .incompatibleClock: return "Source/ADC/DAC trigger clocks are not synchronized or calibrated."
        case .poorQuality: return "One or more captures has low SNR, clipping or unbounded timing uncertainty."
        case .sourceDrift: return "Returning to the listener did not reproduce the controlled source arrival; timing is unreliable."
        case .invalidPath: return "An actual measured low-latency anti-noise path and jitter bound are required."
        case .staleData: return "The microphone, clock, route or acoustic environment may have changed. Recalibrate."
        case .noLiveTransport: return "The causal reference-to-speaker transport has not been hardware-verified. Feed-forward ANC cannot arm."
        case .corruptSidecar: return "Saved feed-forward calibration is corrupt or incompatible."
        }
    }
}

struct QuietZoneFeedForwardBudgetAnalyzer: Sendable {
    static let maximumSurveyAge: TimeInterval = 86_400
    static let maximumArrivalUncertaintySeconds = 0.001
    static let maximumListenerRepeatDifferenceSeconds = 0.0015
    static let minimumSNRDB = 24.0
    static let requiredReserveSeconds = 0.002

    func analyze(
        _ calibration: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        now: Date = Date()
    ) throws -> QuietZoneFeedForwardBudget {
        guard calibration.version == QuietZoneFeedForwardCalibration.schemaVersion,
              calibration.projectID == project.id,
              calibration.playbackSystemID == project.playbackSystemID,
              let projectMicrophone = project.microphone,
              projectMicrophone.stableID == calibration.microphoneStableID,
              project.measurements.contains(where: {
                  $0.id == calibration.listenerPositionID && $0.included
              }),
              !calibration.upstreamLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw QuietZoneFeedForwardError.incompatibleProject }
        guard now.timeIntervalSince(calibration.capturedAt) >= -120,
              now.timeIntervalSince(calibration.capturedAt) < Self.maximumSurveyAge
        else { throw QuietZoneFeedForwardError.staleData }

        guard calibration.arrivals.count == 3,
              calibration.arrivals.map(\.position) == [
                  .listenerFirst, .upstream, .listenerReturn
              ]
        else { return .missing }
        let a = calibration.arrivals[0]
        let b = calibration.arrivals[1]
        let c = calibration.arrivals[2]

        guard !a.sourceTriggerID.isEmpty,
              a.sourceTriggerID == b.sourceTriggerID,
              b.sourceTriggerID == c.sourceTriggerID,
              !a.synchronizedClockID.isEmpty,
              a.synchronizedClockID == b.synchronizedClockID,
              b.synchronizedClockID == c.synchronizedClockID
        else { throw QuietZoneFeedForwardError.incompatibleClock }

        for record in calibration.arrivals {
            guard record.microphoneDeviceID == calibration.microphoneStableID,
                  record.microphoneDeviceID == a.microphoneDeviceID,
                  record.microphoneChannel == projectMicrophone.inputChannelIndex,
                  record.routeFingerprint == a.routeFingerprint,
                  !record.routeFingerprint.isEmpty,
                  record.sampleRate.isFinite,
                  record.sampleRate >= 8_000,
                  abs(record.sampleRate - a.sampleRate) < 0.5
            else { throw QuietZoneFeedForwardError.incompatibleProject }

            guard record.arrivalAfterTriggerSeconds.isFinite,
                  record.arrivalAfterTriggerSeconds >= 0,
                  record.arrivalAfterTriggerSeconds <= 2,
                  record.oneSigmaTimingUncertaintySeconds.isFinite,
                  record.oneSigmaTimingUncertaintySeconds >= 0,
                  record.oneSigmaTimingUncertaintySeconds <= Self.maximumArrivalUncertaintySeconds,
                  record.snrDB.isFinite,
                  record.snrDB >= Self.minimumSNRDB,
                  !record.clipped
            else { throw QuietZoneFeedForwardError.poorQuality }
        }

        let listenerDrift = abs(a.arrivalAfterTriggerSeconds - c.arrivalAfterTriggerSeconds)
        guard listenerDrift <= Self.maximumListenerRepeatDifferenceSeconds
        else { throw QuietZoneFeedForwardError.sourceDrift }

        let meanListener = 0.5 * (a.arrivalAfterTriggerSeconds + c.arrivalAfterTriggerSeconds)
        let preview = meanListener - b.arrivalAfterTriggerSeconds
        let uncertainty = 3 * (
            max(a.oneSigmaTimingUncertaintySeconds, c.oneSigmaTimingUncertaintySeconds)
            + b.oneSigmaTimingUncertaintySeconds
        ) + listenerDrift / 2
        let conservativePreview = preview - uncertainty

        guard let timing = calibration.timingPath else {
            return QuietZoneFeedForwardBudget(
                readiness: .missingMeasurements,
                acousticPreviewSeconds: preview,
                conservativePreviewSeconds: conservativePreview,
                antiNoisePathSeconds: nil,
                conservativeReserveSeconds: nil,
                geometryOnly: false,
                runtimeAvailable: false,
                explanation: "Acoustic preview is calibrated, but the actual ADC → DSP → output command → listening-seat delay has not been measured."
            )
        }
        guard timing.synchronizedClockID == a.synchronizedClockID,
              timing.microphoneDeviceID == a.microphoneDeviceID,
              timing.microphoneChannel == a.microphoneChannel,
              timing.routeFingerprint == a.routeFingerprint,
              abs(timing.sampleRate - a.sampleRate) < 0.5
        else { throw QuietZoneFeedForwardError.incompatibleClock }
        let values = [
            timing.referenceAcquisitionSeconds,
            timing.referenceProcessingSeconds,
            timing.commandToSeatSeconds,
            timing.totalWorstCaseJitterSeconds,
            timing.timingUncertaintySeconds
        ]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              timing.commandToSeatSeconds > 0,
              timing.referenceProcessingSeconds > 0,
              timing.timingUncertaintySeconds <= 0.005
        else { throw QuietZoneFeedForwardError.invalidPath }

        let path = timing.referenceAcquisitionSeconds
            + timing.referenceProcessingSeconds
            + timing.commandToSeatSeconds
        let upperPath = path + timing.totalWorstCaseJitterSeconds
            + 3 * timing.timingUncertaintySeconds
        let reserve = conservativePreview - upperPath
        let readiness: QuietZoneFeedForwardReadiness
        let explanation: String
        if reserve <= 0 {
            readiness = .nonCausal
            explanation = "Anti-noise cannot reliably arrive before an unpredictable disturbance reaches the calibrated listener. Move the reference upstream or shorten the measured processing path."
        } else if reserve < Self.requiredReserveSeconds {
            readiness = .limitedMargin
            explanation = "Only a narrow positive timing margin remains. Do not activate cancellation without stronger clock/jitter evidence and physical verification."
        } else {
            readiness = .physicallyPlausible
            explanation = "The measured timing budget is positive. This establishes timing plausibility, NOT broadband control bandwidth, disturbance-to-listener coherence, stability or actual reduction."
        }
        return QuietZoneFeedForwardBudget(
            readiness: readiness,
            acousticPreviewSeconds: preview,
            conservativePreviewSeconds: conservativePreview,
            antiNoisePathSeconds: path,
            conservativeReserveSeconds: reserve,
            geometryOnly: false,
            // Deliberate lock: PR96 has no proven low-latency live feed-forward
            // transport. Ordinary PR90 250ms polling cannot be reused.
            runtimeAvailable: false,
            explanation: explanation + (timing.lowLatencyTransportVerified
                ? " Real-time control still requires validated disturbance modeling and listener verification."
                : " The reference-to-output transport is not yet hardware-verified.")
        )
    }
}

struct QuietZoneFeedForwardStore: Sendable {
    var roomStore: RoomCorrectionProjectStore

    func url(for projectID: UUID) -> URL {
        roomStore.projectDirectory(for: projectID)
            .appendingPathComponent("quiet-zone-feed-forward-v1.json")
    }

    func load(for project: RoomCorrectionProject) throws -> QuietZoneFeedForwardCalibration? {
        let location = url(for: project.id)
        guard FileManager.default.fileExists(atPath: location.path) else { return nil }
        do {
            let data = try Data(contentsOf: location)
            let calibration = try JSONDecoder().decode(QuietZoneFeedForwardCalibration.self, from: data)
            guard calibration.projectID == project.id,
                  calibration.playbackSystemID == project.playbackSystemID,
                  calibration.microphoneStableID == project.microphone?.stableID
            else { throw QuietZoneFeedForwardError.incompatibleProject }
            return calibration
        } catch let error as QuietZoneFeedForwardError {
            throw error
        } catch { throw QuietZoneFeedForwardError.corruptSidecar }
    }

    func save(_ calibration: QuietZoneFeedForwardCalibration, project: RoomCorrectionProject) throws {
        guard calibration.projectID == project.id,
              calibration.playbackSystemID == project.playbackSystemID,
              calibration.microphoneStableID == project.microphone?.stableID,
              project.measurements.contains(where: { $0.id == calibration.listenerPositionID })
        else { throw QuietZoneFeedForwardError.incompatibleProject }
        if !calibration.arrivals.isEmpty {
            _ = try QuietZoneFeedForwardBudgetAnalyzer().analyze(calibration, project: project)
        }
        let directory = roomStore.projectDirectory(for: project.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(calibration).write(to: url(for: project.id), options: .atomic)
    }

    func delete(for projectID: UUID) throws {
        let location = url(for: projectID)
        if FileManager.default.fileExists(atPath: location.path) {
            try FileManager.default.removeItem(at: location)
        }
    }
}
