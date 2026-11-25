import Foundation
import Observation

// E29 S4: the seat map's view model, behind `e29.room-model`. It builds the shared `RoomModel` from the live project
// records (room-correction positions today; the other adapters join in S7), links the geometry advisor's listener and
// speaker points to model points instead of keeping a second copy, and persists entered positions through
// `RoomModelStore` in the project's folder. Control plane only: nothing here touches the engine, arms anything or
// changes a snapshot. E29 S6: a seat the user adds without measuring it gets an estimated response from the nearest
// measured seats (`n60_roommodel_interpolate`), shown with its confidence and never stored.

/// Pure layout helpers for the top-down map, kept out of the view so they can be tested.
struct RoomSeatMapLayout: Equatable, Sendable {
    /// Room extent in metres (x across, y into the room).
    var widthMetres: Double
    var lengthMetres: Double
    var viewWidth: Double
    var viewHeight: Double

    /// Metres to view points; y runs down the view (front wall at the top).
    func viewPoint(x: Double, y: Double) -> (x: Double, y: Double) {
        (x / widthMetres * viewWidth, y / lengthMetres * viewHeight)
    }

    func metres(viewX: Double, viewY: Double) -> (x: Double, y: Double) {
        let cx = min(max(viewX, 0), viewWidth), cy = min(max(viewY, 0), viewHeight)
        return (cx / viewWidth * widthMetres, cy / viewHeight * lengthMetres)
    }

    /// The room's size when geometry is known, otherwise the positions' bounding box plus a metre of margin.
    static func extent(geometry: RoomGeometryModel?, points: [RoomPoint]) -> (width: Double, length: Double) {
        if let g = geometry { return (g.dimensions.width, g.dimensions.length) }
        let ps = points.compactMap(\.position)
        return (max((ps.map(\.x).max() ?? 0) + 1, 3), max((ps.map(\.y).max() ?? 0) + 1, 3))
    }
}

enum RoomSeatMapUnit: String, CaseIterable, Identifiable, Sendable {
    case metres, feet
    var id: String { rawValue }
    var title: String { self == .metres ? "m" : "ft" }
    var perMetre: Double { self == .metres ? 1 : 3.280839895 }

    /// Feet for the US system, metres otherwise (the UK system also uses metres for room sizes).
    static func forLocale(_ locale: Locale = .current) -> RoomSeatMapUnit {
        locale.measurementSystem == .us ? .feet : .metres
    }
}

/// One estimated (derived) response into a seat nobody measured. Never persisted; confidence is shown with it.
struct RoomSeatMapDerivedRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var seatName: String
    /// "Estimated from 3 nearby seats, confidence 72%" or the reason there is no estimate.
    var text: String
    /// Nil when the position could not be estimated.
    var meanConfidence: Double?
    var usedBy: String
}

struct RoomSeatMapPathRow: Identifiable, Equatable, Sendable {
    var id: UUID
    var sourceName: String
    var receiverName: String
    var state: String
    var usedBy: String
}

@MainActor
@Observable
final class RoomSeatMapController {
    static let folderName = "room-model"
    static let moveStepMetres = 0.1

    private(set) var model = RoomModel()
    private(set) var geometry: RoomGeometryModel?
    private(set) var message: String?
    private(set) var sizeWarning: String?
    var unit: RoomSeatMapUnit
    var selectedPointID: UUID?

    private let projectStore: RoomCorrectionProjectStore
    private var projectID: UUID?
    private var context = RoomModelContext()
    /// Positions the user entered, by point ID. Linked points (see `linkedPointIDs`) live in the geometry instead.
    private var entered: [UUID: RoomPosition] = [:]
    private var project: RoomCorrectionProject?
    /// Seats the user added without measuring them (E29 S6); stored with the entered positions.
    private var extraSeats: [RoomPoint] = []
    private(set) var derivedRows: [RoomSeatMapDerivedRow] = []
    /// Estimated response into each unmeasured, positioned seat (left and right feed power-summed).
    private(set) var derivedResponses: [UUID: RoomBandResponse] = [:]

    init(projectStore: RoomCorrectionProjectStore, unit: RoomSeatMapUnit = .forLocale()) {
        self.projectStore = projectStore
        self.unit = unit
    }

    // MARK: Loading

    func load(project: RoomCorrectionProject, geometry: RoomGeometryModel?, context: RoomModelContext = RoomModelContext()) {
        self.project = project
        self.projectID = project.id
        self.geometry = geometry
        self.context = context
        entered = [:]
        extraSeats = []
        message = nil
        if let doc = try? RoomModelStore.load(from: directory(for: project.id)) {
            for p in doc.model.points { if let pos = p.position { entered[p.id] = pos } }
            extraSeats = doc.model.points.filter { $0.kind == .seat }
        }
        rebuild()
    }

    private func directory(for projectID: UUID) -> URL {
        projectStore.projectDirectory(for: projectID).appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Left feed, right feed and the first seat take their position from the geometry when there is one.
    var linkedPointIDs: Set<UUID> {
        guard geometry != nil else { return [] }
        var ids: Set<UUID> = [RoomModelAdapter.leftFeedID, RoomModelAdapter.rightFeedID]
        ids.insert(listenerID)
        return ids
    }

    /// The first room-correction position is the main seat; with none, the geometry's listener gets its own seat.
    private var listenerID: UUID { project?.measurements.first?.id ?? Self.geometryListenerID }
    static let geometryListenerID = RoomModelID.stable("point.seat", "listening position")

    private func rebuild() {
        guard let project else { model = RoomModel(); return }
        let built = RoomModelAdapter.build(RoomModelAdapterInput(positions: project.measurements))
        let linked = linkedPointIDs
        let main = listenerID
        var base = built.points
        for seat in extraSeats where !base.contains(where: { $0.id == seat.id }) { base.append(seat) }
        if geometry != nil {
            // The advisor's geometry always has a listener and two speakers; make sure they are points.
            func add(_ id: UUID, _ kind: RoomPointKind, _ name: String) {
                if !base.contains(where: { $0.id == id }) { base.append(RoomPoint(id: id, kind: kind, name: name, position: nil)) }
            }
            add(RoomModelAdapter.leftFeedID, .speakerFeed, RoomModelAdapter.leftFeedName)
            add(RoomModelAdapter.rightFeedID, .speakerFeed, RoomModelAdapter.rightFeedName)
            add(main, .seat, "Listening position")
        }
        let points = base.map { p -> RoomPoint in
            var q = p
            if linked.contains(p.id), let g = geometry {
                let src: RoomGeometryPoint3D? =
                    p.id == RoomModelAdapter.leftFeedID ? g.leftSpeaker
                    : p.id == RoomModelAdapter.rightFeedID ? g.rightSpeaker
                    : (p.id == main ? g.listener : nil)
                if let s = src { q.position = RoomPosition(x: s.x, y: s.y, z: s.z, source: .typed, uncertaintyMetres: nil) }
            } else if let pos = entered[p.id] {
                q.position = pos
            }
            return q
        }
        model = RoomModel(points: points, paths: built.paths)
        updateSizeWarning()
        refreshDerived()
    }

    private func updateSizeWarning() {
        // Design note 9: warn above the store's cap. Estimate from rate and window (1 s when unknown), 32-bit samples.
        let bytes = model.paths.filter(\.hasImpulseResponse).reduce(0.0) { $0 + $1.sampleRate * ($1.windowSeconds ?? 1) * 4 }
        sizeWarning = bytes > Double(RoomModelStore.sizeWarningBytes)
            ? "This room model's impulse responses are large (over 200 MB). Remove old measurements to save space." : nil
    }

    // MARK: Reading

    var points: [RoomPoint] { model.points }
    var positionedPoints: [RoomPoint] { model.points.filter { $0.position != nil } }
    /// Points without coordinates stay listed beside the map.
    var unpositionedPoints: [RoomPoint] { model.points.filter { $0.position == nil } }
    var selectedPoint: RoomPoint? { selectedPointID.flatMap { model.point($0) } }

    func name(of id: UUID) -> String { model.point(id)?.name ?? "Unknown point" }

    var pathRows: [RoomSeatMapPathRow] {
        model.paths.map { path in
            let state = RoomModelRule.state(of: path, in: context)
            let stateText: String
            let usedBy: String
            switch state {
            case .measured:
                stateText = path.qualityOK ? "Measured" : "Measured, poor quality"
                usedBy = Self.usage(for: path)
            case .stale:
                stateText = "Stale: " + RoomModelRule.staleMessage
                usedBy = "Not used until measured again"
            }
            return RoomSeatMapPathRow(
                id: path.id, sourceName: name(of: path.source), receiverName: name(of: path.receiver),
                state: stateText, usedBy: usedBy)
        }
    }

    /// Design note 5: which features read a measured path.
    static func usage(for path: RoomPath) -> String {
        guard path.qualityOK else { return "Not used (measurement flagged)" }
        return path.timingTier.carriesPhase
            ? "Room correction, Quiet Zone, MIMO design"
            : "Room correction (magnitude only for cross-source use)"
    }

    var summaryText: String {
        let c = model.completeness(in: context)
        return "\(c.pointCount) points, \(c.pathCount) measured paths, \(c.unpositionedPointIDs.count) without a position, \(c.stalePathIDs.count) stale."
    }

    // MARK: Unmeasured seats and derived paths (E29 S6)

    /// Seats the user added to ask "what would it be like here?"; they have no measured path.
    var unmeasuredSeatIDs: [UUID] { extraSeats.map(\.id).filter { model.point($0) != nil } }

    @discardableResult
    func addUnmeasuredSeat(name: String, x: Double, y: Double, z: Double = 1.1) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, x.isFinite, y.isFinite, z.isFinite else { return nil }
        let id = UUID()
        extraSeats.append(RoomPoint(id: id, kind: .seat, name: trimmed, position: nil))
        entered[id] = RoomPosition(x: max(0, x), y: max(0, y), z: max(0, z), source: .typed, uncertaintyMetres: nil)
        persist()
        rebuild()
        return id
    }

    func removeUnmeasuredSeat(_ id: UUID) {
        guard extraSeats.contains(where: { $0.id == id }) else { return }
        extraSeats.removeAll { $0.id == id }
        entered[id] = nil
        if selectedPointID == id { selectedPointID = nil }
        persist()
        rebuild()
    }

    /// Estimates each positioned, unmeasured seat from the nearest measured seats (measured, in date and with an
    /// impulse response; stale and flagged paths are left out). Synchronous: a few short FFTs. Nothing is stored.
    private func refreshDerived() {
        derivedRows = []
        derivedResponses = [:]
        guard let project else { return }
        let feeds = model.points.filter { $0.kind == .speakerFeed }
        for seat in model.points where seat.kind == .seat && model.paths(to: seat.id).isEmpty {
            guard let seatPosition = seat.position else { continue }
            var perFeed: [RoomBandResponse] = []
            var refusal: String?
            let usable = feeds.filter { !model.paths(from: $0.id).isEmpty }
            for feed in usable {
                guard let feedPosition = feed.position else {
                    refusal = "Place the speakers on the map to estimate this seat."
                    break
                }
                let neighbours = neighbourPaths(from: feed.id, project: project)
                guard let rate = Self.dominantRate(neighbours.map(\.rate)) else { continue }
                let same = neighbours.filter { $0.rate == rate }.map(\.path)
                switch RoomModelInterpolator.derive(
                    source: feedPosition, query: seatPosition, sampleRate: rate, neighbours: same) {
                case .success(let r): perFeed.append(r)
                case .failure(let why): refusal = why.message
                }
            }
            if refusal == nil, perFeed.isEmpty { refusal = RoomDerivedRefusal.noNeighbours.message }
            if let refusal {
                derivedRows.append(RoomSeatMapDerivedRow(
                    id: seat.id, seatName: seat.name, text: "No estimate. \(refusal)", meanConfidence: nil,
                    usedBy: "Nothing"))
            } else if let both = RoomBandResponse.powerSum(perFeed) {
                derivedResponses[seat.id] = both
                var count = 0
                if case .derived(let k) = both.origin { count = k / max(perFeed.count, 1) }
                let pct = Int((both.meanConfidence * 100).rounded())
                derivedRows.append(RoomSeatMapDerivedRow(
                    id: seat.id, seatName: seat.name,
                    text: "Estimated from \(count) nearby \(count == 1 ? "seat" : "seats"), confidence \(pct)%. "
                        + "Shown only; not used for room correction.",
                    meanConfidence: both.meanConfidence,
                    usedBy: "Conversation Focus music estimate (with a fallback when confidence is low)"))
            }
        }
    }

    private func neighbourPaths(from feed: UUID, project: RoomCorrectionProject) -> [(rate: Double, path: RoomNeighbourPath)] {
        var out: [(Double, RoomNeighbourPath)] = []
        for path in model.paths(from: feed) {
            guard path.qualityOK, RoomModelRule.state(of: path, in: context) == .measured,
                  case .roomCorrectionPosition(let id, let channel) = path.origin,
                  let position = model.point(path.receiver)?.position,
                  let measured = project.measurements.first(where: { $0.id == id }) else { continue }
            let ir = channel == "left" ? measured.left.impulseResponse : measured.right.impulseResponse
            guard !ir.isEmpty else { continue }
            out.append((path.sampleRate, RoomNeighbourPath(
                position: position, impulseResponse: ir, phaseTrusted: path.timingTier.carriesPhase)))
        }
        return out
    }

    /// The rate most neighbours share (ties go to the higher rate), so one query never mixes rates.
    static func dominantRate(_ rates: [Double]) -> Double? {
        let counts = Dictionary(grouping: rates, by: { $0 }).mapValues(\.count)
        return counts.max { a, b in a.value != b.value ? a.value < b.value : a.key < b.key }?.key
    }

    // MARK: Editing

    /// Moves a point. Returns the geometry to hand to the advisor when the point is linked to it, so there is still
    /// one store for the room; the caller saves it through the geometry section.
    @discardableResult
    func setPosition(_ id: UUID, x: Double, y: Double, z: Double?, source: RoomPositionSource = .typed) -> RoomGeometryModel? {
        guard x.isFinite, y.isFinite, z?.isFinite ?? true, model.point(id) != nil else { return nil }
        let height = z ?? model.point(id)?.position?.z ?? defaultHeight(for: id)
        let pos = RoomPosition(x: max(0, x), y: max(0, y), z: max(0, height), source: source, uncertaintyMetres: nil)
        var updated: RoomGeometryModel?
        if linkedPointIDs.contains(id), var g = geometry {
            let p = RoomGeometryPoint3D(x: pos.x, y: pos.y, z: pos.z)
            if id == RoomModelAdapter.leftFeedID { g.leftSpeaker = p }
            else if id == RoomModelAdapter.rightFeedID { g.rightSpeaker = p }
            else { g.listener = p }
            g.modifiedAt = Date()
            geometry = g
            updated = g
        } else {
            entered[id] = pos
            persist()
        }
        rebuild()
        return updated
    }

    func clearPosition(_ id: UUID) {
        guard !linkedPointIDs.contains(id) else {
            message = "This point follows the room geometry. Edit it there or move it on the map."
            return
        }
        entered[id] = nil
        persist()
        rebuild()
    }

    /// The advisor's geometry changed elsewhere (sections, undo): re-read it.
    func geometryChanged(_ g: RoomGeometryModel?) {
        geometry = g
        rebuild()
    }

    @discardableResult
    func nudge(_ id: UUID, dx: Double, dy: Double) -> RoomGeometryModel? {
        guard let p = model.point(id)?.position else { return nil }
        return setPosition(id, x: p.x + dx, y: p.y + dy, z: nil)
    }

    private func defaultHeight(for id: UUID) -> Double {
        switch model.point(id)?.kind {
        case .seat, .ear: return 1.1
        default: return 0.9
        }
    }

    private func persist() {
        guard let projectID else { return }
        // Only entered points are stored (positions are an index; measured data stays where it is).
        // Extra seats may not be in `model` yet (persist runs before rebuild).
        let all = model.points + extraSeats.filter { seat in !model.points.contains { $0.id == seat.id } }
        let pts = all.filter { entered[$0.id] != nil }.map { p -> RoomPoint in
            var q = p
            q.position = entered[p.id]
            return q
        }
        let doc = RoomModelDocument(modelID: RoomModelID.stable("model", projectID.uuidString), model: RoomModel(points: pts))
        do {
            try RoomModelStore.save(doc, to: directory(for: projectID))
            message = nil
        } catch {
            message = "Could not save positions: \(error.localizedDescription)"
        }
    }
}
