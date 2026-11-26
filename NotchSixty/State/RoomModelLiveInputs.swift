import Foundation

/// E29 S7 (behind `e29.room-model`): what the room model needs from the live app that room-correction positions do
/// not store themselves. Stamped on a position when it is retained, and read again for the seat map's staleness
/// context, so one rule (`RoomModelRule`) judges both. Only Swift reads the flag; nothing here is realtime.
struct RoomCaptureStamp: Codable, Equatable, Sendable {
    /// "loopback", "reference" or nil. Room-correction sweeps are aligned by their direct arrival, so they carry no
    /// absolute timing and stay nil (magnitude-only across sources) until a capture path that records timing exists.
    var timingTier: String?
    /// One capture session; relative phase across sources needs the same non-nil session.
    var sessionID: String?
    var outputDeviceUID: String?
    var arrangementRevision: String?
}

struct RoomSurveyCoordinate: Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
}

/// The live facts behind the map's staleness context and the points it shows.
struct RoomModelLiveInputs: Sendable {
    var outputDeviceUID: String?
    var arrangementRevision: String?
    var outputGainDB: Double?
    var ancPathRecords: [CombinedAncPathRecord] = []
    var headSurvey: [RoomSurveyCoordinate] = []
}

enum RoomModelArrangementRevision {
    /// A stable digest of the speaker arrangement; it changes whenever the arrangement (outputs, bass handling, feed
    /// calibration) changes, which is when stored paths no longer describe the system.
    static func revision(of arrangement: SystemArrangement?) -> String? {
        guard let arrangement else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(arrangement) else { return nil }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3 }
        return String(hash, radix: 16)
    }
}

@MainActor
enum RoomModelLiveWiring {
    /// Connects the live sources to the retain-time stamp and to the seat map. Called once at app construction under
    /// `e29.room-model`; with the flag off nothing is stamped and no feed is attached.
    static func attach(
        projects: RoomCorrectionProjectController, advisor: RoomTreatmentAdvisorController,
        ambient: AmbientCompensationController, profiles: ProductProfileController, engine: AudioIOEngine,
        quietZone: ActiveQuietZoneController, survey: QuietZoneFeedForwardSurveyController,
        mimo: MIMOTreatmentController? = nil
    ) {
        func live() -> RoomModelLiveInputs {
            RoomModelLiveInputs(
                outputDeviceUID: engine.selectedOutputDevice?.uid,
                arrangementRevision: RoomModelArrangementRevision.revision(
                    of: profiles.selectedSystemProfile?.state.systemArrangement),
                outputGainDB: quietZone.currentOutputGainDB,
                ancPathRecords: survey.leakageRecords,
                headSurvey: (quietZone.virtualMic?.headFollow?.positions ?? []).map {
                    RoomSurveyCoordinate(x: $0.x, y: $0.y, z: $0.z)
                })
        }
        projects.captureStamp = {
            let inputs = live()
            return RoomCaptureStamp(
                timingTier: nil, sessionID: nil, outputDeviceUID: inputs.outputDeviceUID,
                arrangementRevision: inputs.arrangementRevision)
        }
        // The staleness rule's view of "now" for the designers (output gain is judged by the E26 stamp itself).
        func context() -> RoomModelContext {
            let inputs = live()
            return RoomModelContext(
                arrangementRevision: inputs.arrangementRevision, outputDeviceUID: inputs.outputDeviceUID)
        }
        // G5: every retained position is captured into the room model and the profile keeps the model ID.
        projects.roomModelRecorder = { [weak projects, weak profiles] position, projectID, _ in
            guard let projects, let profiles else { return }
            let id = try RoomModelCapture.record(
                position, projectID: projectID, store: projects.store, context: context())
            profiles.setSelectedRoomModelID(id)
        }
        // G18: room-correction designs read their positions through the model (measured, current, never estimated).
        projects.roomModelGate = { [weak projects] consumer, positions in
            guard let projects else { return positions }
            let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: positions))
            let derived = projects.project.map {
                RoomModelCapture.derivedSeatIDs(
                    store: projects.store, projectID: $0.id, measuredIDs: Set($0.measurements.map(\.id)))
            } ?? []
            return try RoomModelConsumerAccess.positions(
                positions, model: model, context: context(), consumer: consumer, derivedPointIDs: derived)
        }
        // G18: the MIMO plant is designed from measured seats only.
        mimo?.roomModelGate = { [weak projects] seatIDs in
            guard let projects else { return }
            let model = RoomModelAdapter.build(RoomModelAdapterInput(positions: projects.positions))
            let derived = projects.project.map {
                RoomModelCapture.derivedSeatIDs(
                    store: projects.store, projectID: $0.id, measuredIDs: Set($0.measurements.map(\.id)))
            } ?? []
            try RoomModelConsumerAccess.seats(
                seatIDs, model: model, context: context(), consumer: .mimoPlant, derivedPointIDs: derived)
        }
        // G20: the E26 sub path and E4 Quiet Zone designs read their combined path records through the model.
        func ancGate(_ records: [CombinedAncPathRecord], _ consumer: RoomModelConsumer) throws -> [CombinedAncPathRecord] {
            let model = RoomModelAdapter.build(RoomModelAdapterInput(combinedAncRecords: records))
            return try RoomModelConsumerAccess.ancRecords(records, model: model, context: context(), consumer: consumer)
        }
        survey.roomModelGate = ancGate
        // G20: the head-follow blend is allowed only while those paths are current. The verdict is cached on the
        // inputs that can change it, because the blend asks on every update.
        final class Verdict { var key: String?; var allowed = true }
        let verdict = Verdict()
        quietZone.virtualMic?.headFollow?.roomModelGate = { [weak survey] in
            guard let survey else { return true }
            let inputs = live()
            let key = "\(inputs.outputDeviceUID ?? "-")|\(inputs.arrangementRevision ?? "-")|\(survey.leakageRecords.count)"
            if verdict.key != key {
                verdict.key = key
                verdict.allowed = (try? ancGate(survey.leakageRecords, .virtualSeat)) != nil
            }
            return verdict.allowed
        }
        advisor.roomModelLive = live
        ambient.seatMusicFeed = advisor.seatMusicFeed
    }
}
