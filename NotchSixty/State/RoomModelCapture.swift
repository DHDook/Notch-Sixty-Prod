import Foundation

/// E29 S7 part 2 (G5): production capture into `RoomModelStore`. When a room-correction position is retained (under
/// `e29.room-model`), its left and right paths and impulse responses are written into the project's room-model folder
/// next to the seat map's entered positions, stamped with the output device and arrangement revision (G2). The model is
/// an index; the position stays in the project as it is. Control plane only; never arms or changes an engine snapshot.
enum RoomModelCapture {
    static func directory(store: RoomCorrectionProjectStore, projectID: UUID) -> URL {
        store.projectDirectory(for: projectID).appendingPathComponent(RoomSeatMapController.folderName, isDirectory: true)
    }

    static func modelID(for projectID: UUID) -> UUID { RoomModelID.stable("model", projectID.uuidString) }

    /// Adds the position's two paths (with impulse responses) and its points to the stored model. Returns the model ID.
    @discardableResult
    static func record(
        _ position: RoomCorrectionMeasurementPosition, projectID: UUID, store: RoomCorrectionProjectStore,
        context: RoomModelContext
    ) throws -> UUID {
        let dir = directory(store: store, projectID: projectID)
        var doc = (try? RoomModelStore.load(from: dir)) ?? RoomModelDocument(modelID: modelID(for: projectID))
        let built = RoomModelAdapter.build(RoomModelAdapterInput(positions: [position]))
        for point in built.points where !doc.model.points.contains(where: { $0.id == point.id }) { doc.addPoint(point) }
        for path in built.paths {
            guard case .roomCorrectionPosition(_, let channel) = path.origin else { continue }
            let ir = channel == "left" ? position.left.impulseResponse : position.right.impulseResponse
            try doc.addPath(path, impulseResponse: ir.isEmpty ? nil : ir, context: context)
        }
        try RoomModelStore.save(doc, to: dir)
        return doc.modelID
    }

    /// Seats stored in the model that nobody measured (estimates): designers refuse them.
    static func derivedSeatIDs(store: RoomCorrectionProjectStore, projectID: UUID, measuredIDs: Set<UUID>) -> Set<UUID> {
        guard let doc = try? RoomModelStore.load(from: directory(store: store, projectID: projectID)) else { return [] }
        return Set(doc.model.points.filter {
            $0.kind == .seat && !measuredIDs.contains($0.id) && doc.model.paths(to: $0.id).isEmpty
        }.map(\.id))
    }
}
