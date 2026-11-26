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
    nonisolated static let folderName = "room-model"
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
    private var libraryRecords: [MeasurementRecord] = []
    /// E29 S7: live ANC path records and head-survey seats for the map (G11).
    private var live = RoomModelLiveInputs()
    /// E29 S7: the seat whose music Conversation Focus uses, and where it is published (nil: no feed in this host).
    private(set) var focusSeatID: UUID?
    private(set) var focusMessage: String?
    private let seatMusicFeed: SeatMusicFeed?
    private let defaults: UserDefaults
    /// Loads a measurement record's impulse response (the library in production; a fake in tests). E29 S5.
    private let impulseResponseLoader: (UUID) -> [Float]?
    /// The stereo feed calibration, for the locate delay cross-check. Display only.
    var stereoAlignment: StereoBassAlignment?
    /// What the last locate said (fix, uncertainty and cross-checks, or why it was refused).
    private(set) var locateMessage: String?

    init(
        projectStore: RoomCorrectionProjectStore, unit: RoomSeatMapUnit = .forLocale(),
        impulseResponseLoader: @escaping (UUID) -> [Float]? = RoomSeatMapController.libraryLoader,
        seatMusicFeed: SeatMusicFeed? = nil, defaults: UserDefaults = .standard
    ) {
        self.seatMusicFeed = seatMusicFeed
        self.defaults = defaults
        self.projectStore = projectStore
        self.unit = unit
        self.impulseResponseLoader = impulseResponseLoader
    }

    /// The measurement library's impulse response for a record, or nil when it cannot be read.
    nonisolated static func libraryLoader(_ id: UUID) -> [Float]? {
        try? MeasurementLibrary(root: MeasurementLibrary.defaultRoot()).loadImpulseResponse(id: id)
    }

    // MARK: Loading

    func load(
        project: RoomCorrectionProject, geometry: RoomGeometryModel?, context: RoomModelContext = RoomModelContext(),
        library: [MeasurementRecord] = [], live: RoomModelLiveInputs? = nil
    ) {
        self.project = project
        self.libraryRecords = library
        self.live = live ?? RoomModelLiveInputs()
        var context = context
        // The staleness context (G10): everything the live app knows, so one rule judges every path.
        context.outputDeviceUID = self.live.outputDeviceUID ?? context.outputDeviceUID
        context.arrangementRevision = self.live.arrangementRevision ?? context.arrangementRevision
        context.outputGainDB = self.live.outputGainDB ?? context.outputGainDB
        locateMessage = nil
        self.projectID = project.id
        focusSeatID = defaults.string(forKey: Self.focusKey(project.id)).flatMap(UUID.init(uuidString:))
        self.geometry = geometry
        self.context = context
        entered = [:]
        extraSeats = []
        message = nil
        if let doc = try? RoomModelStore.load(from: directory(for: project.id)) {
            for p in doc.model.points { if let pos = p.position { entered[p.id] = pos } }
            // Seats with captured paths are measured (E29 S7 part 2); only the rest are the user's unmeasured seats.
            extraSeats = doc.model.points.filter { $0.kind == .seat && doc.model.paths(to: $0.id).isEmpty }
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
        let built = RoomModelAdapter.build(RoomModelAdapterInput(
            positions: project.measurements, library: libraryRecords, combinedAncRecords: live.ancPathRecords,
            surveyCoordinates: live.headSurvey))
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
                if let s = src {
                    // A located seat keeps its source and uncertainty while the geometry still holds its coordinates (G13).
                    let kept = entered[p.id].flatMap {
                        abs($0.x - s.x) < 1e-6 && abs($0.y - s.y) < 1e-6 && abs($0.z - s.z) < 1e-6 ? $0 : nil
                    }
                    q.position = RoomPosition(
                        x: s.x, y: s.y, z: s.z, source: kept?.source ?? .typed, uncertaintyMetres: kept?.uncertaintyMetres)
                }
            } else if let pos = entered[p.id] {
                q.position = pos
            }
            return q
        }
        model = RoomModel(points: points, paths: built.paths)
        updateSizeWarning()
        refreshDerived()
        publishSeatMusic()
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
    func setPosition(
        _ id: UUID, x: Double, y: Double, z: Double?, source: RoomPositionSource = .typed, uncertainty: Double? = nil
    ) -> RoomGeometryModel? {
        guard x.isFinite, y.isFinite, z?.isFinite ?? true, model.point(id) != nil else { return nil }
        let height = z ?? model.point(id)?.position?.z ?? defaultHeight(for: id)
        let pos = RoomPosition(x: max(0, x), y: max(0, y), z: max(0, height), source: source, uncertaintyMetres: uncertainty)
        var updated: RoomGeometryModel?
        if linkedPointIDs.contains(id), var g = geometry {
            let p = RoomGeometryPoint3D(x: pos.x, y: pos.y, z: pos.z)
            if id == RoomModelAdapter.leftFeedID { g.leftSpeaker = p }
            else if id == RoomModelAdapter.rightFeedID { g.rightSpeaker = p }
            else { g.listener = p }
            g.modifiedAt = Date()
            geometry = g
            updated = g
            // Only a located fix keeps its own record (source and uncertainty, G13); a typed move lives in the geometry.
            if source == .typed { entered[id] = nil } else { entered[id] = pos }
            if source != .typed || !entered.isEmpty { persist() }
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

    // MARK: Music at the seat for Conversation Focus (E29 S7)

    private static func focusKey(_ project: UUID) -> String { "e29.focusSeat.\(project.uuidString)" }

    /// Chooses (or clears, with nil) the seat whose music Conversation Focus uses. Stored per project.
    func setFocusSeat(_ id: UUID?) {
        focusSeatID = id
        if let projectID {
            if let id { defaults.set(id.uuidString, forKey: Self.focusKey(projectID)) }
            else { defaults.removeObject(forKey: Self.focusKey(projectID)) }
        }
        publishSeatMusic()
    }

    /// The response into a seat from both feeds, from its newest usable measured paths; derived seats use the
    /// estimate. `stale` is true when the newest path reads stale for the music estimate; `gainDB` is the output
    /// gain stamped on it. The output-gain staleness check is left out of the music context on purpose: the
    /// programme levels are live, so a volume change since the measurement needs no correction, only a difference
    /// between the seat's and the reference's own stamps.
    private func seatResponse(_ seat: UUID) -> (response: RoomBandResponse, stale: Bool, gainDB: Double?)? {
        if let derived = derivedResponses[seat] { return (derived, false, nil) }
        var musicContext = context
        musicContext.outputGainDB = nil
        var perFeed: [RoomBandResponse] = []
        var stale = false
        var gain: Double?
        for feed in model.points where feed.kind == .speakerFeed {
            let candidates = model.paths(from: feed.id, to: seat).filter { $0.hasImpulseResponse && $0.qualityOK }
            guard let path = candidates.max(by: { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }),
                  let ir = impulseResponse(of: path),
                  let response = RoomModelInterpolator.measured(impulseResponse: ir, sampleRate: path.sampleRate)
            else { continue }
            if RoomModelRule.state(of: path, in: musicContext) != .measured { stale = true }
            gain = gain ?? path.stamps.outputGainDB
            perFeed.append(response)
        }
        guard !perFeed.isEmpty, let both = RoomBandResponse.powerSum(perFeed) else { return nil }
        return (both, stale, gain)
    }

    private func impulseResponse(of path: RoomPath) -> [Float]? {
        switch path.origin {
        case .measurementRecord(let id): return impulseResponseLoader(id)
        case .roomCorrectionPosition(let id, let channel):
            guard let m = project?.measurements.first(where: { $0.id == id }) else { return nil }
            let ir = channel == "left" ? m.left.impulseResponse : m.right.impulseResponse
            return ir.isEmpty ? nil : ir
        default: return nil
        }
    }

    /// Publishes the chosen seat to the Conversation Focus feed, or withdraws it (today's analysis-microphone
    /// prediction) when none is chosen or the reference seat cannot be read.
    private func publishSeatMusic() {
        focusMessage = nil
        guard let feed = seatMusicFeed else { return }
        guard let id = focusSeatID, let seat = model.point(id), seat.kind == .seat else {
            feed.publish(nil)
            return
        }
        guard let reference = seatResponse(listenerID), !reference.response.isDerived,
              let target = seatResponse(id) else {
            feed.publish(nil)
            focusMessage = "Conversation Focus keeps its microphone estimate: the seat or the main seat has no measurement."
            return
        }
        feed.publish(SeatMusicFeed.Source(
            seatName: seat.name, seat: target.response, reference: reference.response,
            seatPathStale: target.stale, referencePathStale: reference.stale,
            seatMeasuredGainDB: target.gainDB, referenceMeasuredGainDB: reference.gainDB))
        if target.stale || reference.stale { focusMessage = RoomModelRule.staleMessage }
    }

    // MARK: Acoustic locate (E29 S5)

    /// Gathers the seat's measured speaker paths with their impulse responses. Library records and room-correction
    /// positions both count; the timing tier each path carries decides whether it is trusted (design note 3). Older
    /// room-correction positions carry none, so they read as untrusted (E29 S7, G12).
    private func locateSources(for seat: UUID, loadImpulseResponses: Bool) -> (sources: [RoomLocateSource], problem: String?) {
        func feedPosition(_ id: UUID) -> RoomPosition? { model.point(id)?.position }
        var newest: [UUID: RoomPath] = [:]
        for path in model.paths where path.receiver == seat && path.hasImpulseResponse {
            guard RoomModelRule.state(of: path, in: context) == .measured else { continue }
            switch path.origin {
            case .measurementRecord, .roomCorrectionPosition: break
            default: continue
            }
            if let existing = newest[path.source], (existing.date ?? .distantPast) >= (path.date ?? .distantPast) { continue }
            newest[path.source] = path
        }
        guard !newest.isEmpty else {
            return ([], "Locate needs measurements of this seat from each speaker, made with loopback timing.")
        }
        var sources: [RoomLocateSource] = []
        for (sourceID, path) in newest.sorted(by: { name(of: $0.key) < name(of: $1.key) }) {
            guard let point = model.point(sourceID) else { continue }
            if point.kind == .subLane {
                sources.append(RoomLocateSource(
                    speakerName: point.name, speakerPosition: RoomPosition(x: 0, y: 0, z: 0, source: .unknown, uncertaintyMetres: nil),
                    impulseResponse: [Float](repeating: 0, count: 16), sampleRate: path.sampleRate,
                    timingTrusted: path.timingTier.carriesPhase, isSub: true))
                continue
            }
            // A library channel named "Left" or "Right" uses the stereo feed's position (the advisor's geometry).
            let lower = point.name.lowercased()
            let feed: UUID? = lower.contains("left") ? RoomModelAdapter.leftFeedID : lower.contains("right") ? RoomModelAdapter.rightFeedID : nil
            guard let position = feedPosition(feed ?? sourceID) ?? point.position else {
                return ([], "Enter the position of \(feed.map { name(of: $0) } ?? point.name) first.")
            }
            // The availability check runs while drawing, so it does not read the files.
            guard let ir = loadImpulseResponses ? impulseResponse(of: path) : [Float](repeating: 0, count: 16), ir.count >= 16 else {
                return ([], "The impulse response of \(point.name) could not be read.")
            }
            sources.append(RoomLocateSource(
                speakerName: point.name, speakerPosition: position, impulseResponse: ir, sampleRate: path.sampleRate,
                timingTrusted: path.timingTier.carriesPhase))
        }
        return (sources, nil)
    }

    private func isLocatable(_ id: UUID) -> Bool {
        guard let kind = model.point(id)?.kind else { return false }
        return kind == .seat || kind == .ear
    }

    /// Why "Locate from measurement" is not offered for this point, or nil when it is.
    func locateUnavailableReason(for id: UUID) -> String? {
        guard isLocatable(id) else { return "Only seats and ears can be located." }
        let gathered = locateSources(for: id, loadImpulseResponses: false)
        if let problem = gathered.problem { return problem }
        let fullRange = gathered.sources.filter { !$0.isSub }
        if fullRange.count < 2 { return RoomLocateRefusal.tooFewSpeakers.message }
        if fullRange.contains(where: { !$0.timingTrusted }) { return RoomLocateRefusal.noLoopbackTiming.message }
        return nil
    }

    /// Fills the seat's position from the time of flight. Returns the geometry to save when the seat is linked to it.
    @discardableResult
    func locate(_ id: UUID) -> RoomGeometryModel? {
        locateMessage = nil
        if let reason = locateUnavailableReason(for: id) { locateMessage = reason; return nil }
        let gathered = locateSources(for: id, loadImpulseResponses: true)
        if let problem = gathered.problem { locateMessage = problem; return nil }
        let height = model.point(id)?.position?.z ?? defaultHeight(for: id)
        switch RoomAcousticLocator.locate(gathered.sources, seatHeight: height) {
        case .refused(let why):
            locateMessage = why.message
            return nil
        case .located(let fix):
            let updated = setPosition(
                id, x: fix.position.x, y: fix.position.y, z: fix.position.z, source: .acousticLocate,
                uncertainty: fix.position.uncertaintyMetres)
            var text = String(
                format: "Located at %.2f m across, %.2f m into the room (about %.0f cm, %d speakers, assumed height %.2f m).",
                fix.position.x, fix.position.y, (fix.position.uncertaintyMetres ?? 0) * 100, fix.speakersUsed, fix.position.z)
            let off = fix.checks.filter { abs($0.differenceMetres) > 0.1 }
            for c in off {
                text += String(
                    format: " %@: measured %.2f m, entered position gives %.2f m; check its position.",
                    c.speakerName, c.measuredMetres, c.geometricMetres)
            }
            let left = fix.checks.first { $0.speakerName.lowercased().contains("left") }
            let right = fix.checks.first { $0.speakerName.lowercased().contains("right") }
            if let l = left, let r = right,
               let note = RoomAcousticLocator.delayCrossCheck(
                   left: l.measuredMetres, right: r.measuredMetres, calibration: stereoAlignment) {
                text += " " + note
            }
            locateMessage = text
            return updated
        }
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
        // Keep what capture stored (E29 S7 part 2): measured paths and their IRs, and the points they join.
        var doc = (try? RoomModelStore.load(from: directory(for: projectID)))
            ?? RoomModelDocument(modelID: RoomModelCapture.modelID(for: projectID))
        let referenced = Set(doc.model.paths.flatMap { [$0.source, $0.receiver] })
        let enteredIDs = Set(pts.map(\.id))
        let kept = doc.model.points.filter { referenced.contains($0.id) && !enteredIDs.contains($0.id) }
        doc.model = RoomModel(points: pts + kept, paths: doc.model.paths)
        do {
            try RoomModelStore.save(doc, to: directory(for: projectID))
            message = nil
        } catch {
            message = "Could not save positions: \(error.localizedDescription)"
        }
    }
}
