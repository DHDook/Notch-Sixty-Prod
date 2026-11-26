import Foundation

// E29 S7 part 2 (G18): the one gate every design consumer passes its measured inputs through. A consumer asks the
// model for the records it needs; the gate checks each one is a measured path (never a derived estimate) and not stale
// under the one staleness rule, then hands back the original records untouched. Handing back the same values (not
// copies rebuilt from the model) is what keeps every design bit-identical to the direct inputs. Control plane only.

/// Who is asking, for the design note 5 table. Derived paths are refused for every consumer here; the music-at-seat
/// predictor (which may use them) reads `RoomSeatMapController.derivedResponses` directly and is not a design.
enum RoomModelConsumer: String, CaseIterable, Sendable {
    case roomCorrectionDesign, subPathDesign, quietZoneDesign, virtualSeat, mimoPlant
}

enum RoomModelAccessError: Error, Equatable, CustomStringConvertible {
    /// The input is an estimate for a seat nobody measured. Designers never use estimates.
    case derivedPathRefused(consumer: RoomModelConsumer, pointID: UUID)
    /// The input is not in the model at all.
    case notMeasured(consumer: RoomModelConsumer, id: UUID)
    case stale(consumer: RoomModelConsumer, reasons: [RoomPathStaleReason])

    var description: String {
        switch self {
        case .derivedPathRefused: return "This seat is estimated, not measured. Measure it before designing from it."
        case .notMeasured: return "That seat has no measurement."
        case .stale: return RoomModelRule.staleMessage
        }
    }
}

enum RoomModelConsumerAccess {
    /// Room-correction positions for a design. `derivedPointIDs` are seats the caller was asked to use that exist only
    /// as estimates. Staleness is judged only when `context` is given (nil fields in it are not checked).
    static func positions(
        _ positions: [RoomCorrectionMeasurementPosition], model: RoomModel, context: RoomModelContext?,
        consumer: RoomModelConsumer, derivedPointIDs: Set<UUID> = []
    ) throws -> [RoomCorrectionMeasurementPosition] {
        if let d = positions.first(where: { derivedPointIDs.contains($0.id) }) {
            throw RoomModelAccessError.derivedPathRefused(consumer: consumer, pointID: d.id)
        }
        for p in positions where p.included {
            let paths = model.paths(to: p.id)
            guard !paths.isEmpty else { throw RoomModelAccessError.notMeasured(consumer: consumer, id: p.id) }
            try checkFresh(paths, context: context, consumer: consumer)
        }
        return positions
    }

    /// Combined ANC path records (E26 sub paths, E4 Quiet Zone plant) for a design.
    static func ancRecords(
        _ records: [CombinedAncPathRecord], model: RoomModel, context: RoomModelContext?, consumer: RoomModelConsumer
    ) throws -> [CombinedAncPathRecord] {
        let paths = model.paths.filter {
            if case .combinedAncRecord = $0.origin { return true } else { return false }
        }
        if !records.isEmpty, paths.isEmpty {
            throw RoomModelAccessError.notMeasured(consumer: consumer, id: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        }
        try checkFresh(paths, context: context, consumer: consumer)
        return records
    }

    /// Seats a MIMO plant reads (E19). The plant's own baseline captures live in the MIMO controller, so the model
    /// only refuses estimates here, and judges staleness for seats that do have model paths.
    static func seats(
        _ seatIDs: [UUID], model: RoomModel, context: RoomModelContext?, consumer: RoomModelConsumer,
        derivedPointIDs: Set<UUID> = []
    ) throws {
        if let d = seatIDs.first(where: { derivedPointIDs.contains($0) }) {
            throw RoomModelAccessError.derivedPathRefused(consumer: consumer, pointID: d)
        }
        for id in seatIDs { try checkFresh(model.paths(to: id), context: context, consumer: consumer) }
    }

    private static func checkFresh(_ paths: [RoomPath], context: RoomModelContext?, consumer: RoomModelConsumer) throws {
        guard let context else { return }
        var reasons: [RoomPathStaleReason] = []
        for path in paths {
            for r in RoomModelRule.staleReasons(of: path, in: context) where !reasons.contains(r) { reasons.append(r) }
        }
        if !reasons.isEmpty { throw RoomModelAccessError.stale(consumer: consumer, reasons: reasons) }
    }
}
