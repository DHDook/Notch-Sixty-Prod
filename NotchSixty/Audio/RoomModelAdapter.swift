import Foundation

/// E29 S1: a read-only adapter that indexes the records that exist today as a `RoomModel`. Room-correction
/// positions, measurement-library records, combined ANC path records and the head survey are read as they are;
/// nothing is copied, migrated or written back. Inline captures stay where they are (owner decision 4).
struct RoomModelAdapterInput: Sendable {
    var positions: [RoomCorrectionMeasurementPosition] = []
    var library: [MeasurementRecord] = []
    var combinedAncRecords: [CombinedAncPathRecord] = []
    var surveyPoints: [QuietZoneSurveyedPosition] = []
    /// Stamps the current project knows for records that carry none of their own (the output device and arrangement
    /// revision are not stored on legacy records; they are checked only when a record has them).
    var timingTierForPositions: RoomTimingTier = .none
    /// Speaker and sub positions entered by the user, keyed by point name (case-insensitive).
    var enteredPositions: [String: RoomPosition] = [:]
}

enum RoomModelAdapter {
    static let leftFeedName = "Left speaker"
    static let rightFeedName = "Right speaker"
    static let seatMicName = "Seat microphone"
    static let referenceMicName = "Reference microphone"
    static let unassignedSeatName = "Unassigned position"

    static func build(_ input: RoomModelAdapterInput) -> RoomModel {
        var points: [UUID: RoomPoint] = [:]
        var order: [UUID] = []
        var paths: [RoomPath] = []

        func entered(_ name: String) -> RoomPosition? {
            input.enteredPositions.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func ensure(_ kind: RoomPointKind, _ name: String, id: UUID? = nil, position: RoomPosition? = nil) -> UUID {
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            let pid = id ?? RoomModelID.stable("point.\(kind.rawValue)", key)
            if points[pid] == nil {
                points[pid] = RoomPoint(id: pid, kind: kind, name: name, position: position ?? entered(name))
                order.append(pid)
            }
            return pid
        }
        func seatID(named name: String) -> UUID {
            // A seat shared by name between a room-correction position and a library record is one point.
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let existing = order.first(where: { points[$0]?.kind == .seat && points[$0]?.name.lowercased() == key }) {
                return existing
            }
            return ensure(.seat, name)
        }

        // Room-correction positions: each has a left and a right feed measured at that seat.
        for p in input.positions {
            let seat = ensure(.seat, p.name, id: p.id)
            for (channel, feedName, m) in [("left", leftFeedName, p.left), ("right", rightFeedName, p.right)] {
                let feed = ensure(.speakerFeed, feedName)
                let origin = RoomPathOrigin.roomCorrectionPosition(id: p.id, channel: channel)
                paths.append(RoomPath(
                    id: RoomModelID.stable("path", "\(origin)"), source: feed, receiver: seat, origin: origin,
                    sampleRate: p.sampleRate, timingTier: input.timingTierForPositions, sessionID: nil,
                    bandLowHz: m.quality.usableLowHz, bandHighHz: m.quality.usableHighHz, windowSeconds: nil,
                    stamps: RoomPathStamps(
                        bassFingerprint: p.ancBassFingerprint, outputGainDB: p.outputGainDBAtMeasurement),
                    date: m.capturedAt,
                    hasImpulseResponse: !m.impulseResponse.isEmpty || !m.rawCapture.isEmpty,
                    qualityOK: m.quality.sweepComplete && !m.quality.clipped))
            }
        }

        // Measurement library: channel names the source, seat (or the record name) names the receiver.
        for r in input.library {
            let isSub = r.channel.lowercased().contains("sub")
            let sourceName = r.channel.isEmpty ? "Unnamed source" : r.channel
            let source = ensure(isSub ? .subLane : .speakerFeed, sourceName)
            let receiver: UUID
            if let seat = r.seat, !seat.isEmpty { receiver = seatID(named: seat) }
            else { receiver = seatID(named: r.name.isEmpty ? Self.unassignedSeatName : r.name) }
            let origin = RoomPathOrigin.measurementRecord(id: r.id)
            paths.append(RoomPath(
                id: RoomModelID.stable("path", "\(origin)"), source: source, receiver: receiver, origin: origin,
                sampleRate: r.sampleRate, timingTier: RoomTimingTier(storedName: r.timingTier), sessionID: nil,
                bandLowHz: r.quality.usableLowHz, bandHighHz: r.quality.usableHighHz, windowSeconds: nil,
                stamps: RoomPathStamps(calibrationName: r.calibrationName), date: r.createdAt,
                hasImpulseResponse: r.hasImpulseResponse, qualityOK: r.quality.sweepComplete && !r.quality.clipped))
        }

        // Combined ANC path records: source role names the point, destination the microphone.
        for (i, rec) in input.combinedAncRecords.enumerated() {
            let source: UUID
            switch rec.source {
            case .feedLeft: source = ensure(.speakerFeed, leftFeedName)
            case .feedRight: source = ensure(.speakerFeed, rightFeedName)
            case .subLane: source = ensure(.subLane, "Sub lane")
            case .outputLeakage:
                source = ensure(rec.outputRole == .sub ? .subLane : .speakerFeed, "Output \(rec.outputChannel ?? -1)")
            }
            let receiver = rec.destination == .seatMicrophone
                ? ensure(.seat, Self.seatMicName) : ensure(.referenceMic, Self.referenceMicName)
            let origin = RoomPathOrigin.combinedAncRecord(index: i)
            paths.append(RoomPath(
                id: RoomModelID.stable("path", "\(origin)|\(rec.source.rawValue)|\(rec.destination.rawValue)|\(rec.outputChannel ?? -1)"),
                source: source, receiver: receiver, origin: origin, sampleRate: rec.sampleRate,
                // The combined record is captured with the sweep's own loopback timing (E26 S1).
                timingTier: .loopback, sessionID: nil, bandLowHz: rec.bandLowHz, bandHighHz: rec.bandHighHz,
                windowSeconds: rec.windowSeconds, stamps: RoomPathStamps(bassFingerprint: rec.fingerprint),
                date: nil, hasImpulseResponse: !rec.impulseResponse.isEmpty, qualityOK: rec.isValid))
        }

        // Head survey: points with positions; a survey point carries virtual-microphone ratios, not an IR path.
        for (i, s) in input.surveyPoints.enumerated() {
            let name = "Survey point \(i + 1)"
            let id = RoomModelID.stable("point.survey", "\(i)|\(s.x)|\(s.y)|\(s.z)")
            _ = ensure(.surveyPoint, name, id: id, position: RoomPosition(x: s.x, y: s.y, z: s.z, source: .typed, uncertaintyMetres: nil))
        }

        return RoomModel(points: order.compactMap { points[$0] }, paths: paths)
    }
}
