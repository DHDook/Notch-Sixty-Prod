import SwiftUI

/// E29 S4: the seat map on the Rooms page (behind `e29.room-model`). A top-down view of the room's points with drag
/// and typed position entry, a list of points that have no position yet, and the state of every measured path with
/// the features that use it. Speakers and the main seat follow the advisor's geometry, so there is one room store.
struct ProductionSeatMapSection: View {
    @Bindable var advisor: RoomTreatmentAdvisorController
    @State private var map: RoomSeatMapController

    init(advisor: RoomTreatmentAdvisorController) {
        self.advisor = advisor
        _map = State(initialValue: RoomSeatMapController(projectStore: advisor.store))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            header
            if map.points.isEmpty {
                Text("No seats or speakers yet. Measure a seat, or describe the room above, and they appear here.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: DesignSpacing.l.pt) {
                        mapCanvas.frame(minWidth: 320, idealWidth: 460, maxWidth: 560)
                        sidePanel
                    }
                    VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
                        mapCanvas
                        sidePanel
                    }
                }
                pathList
                derivedList
            }
            if let warning = map.sizeWarning {
                Label(warning, systemImage: "externaldrive.badge.exclamationmark")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            if let message = map.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .task(id: reloadKey) { reload() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seat map")
    }

    private var reloadKey: String {
        "\(advisor.selectedProjectID?.uuidString ?? "none")|\(advisor.selectedProject?.modifiedAt.timeIntervalSince1970 ?? 0)"
    }

    private func reload() {
        guard let project = advisor.selectedProject else { return }
        var context = RoomModelContext()
        context.calibrationName = project.microphone?.calibration?.sourceName
        map.load(project: project, geometry: advisor.geometryDraft, context: context)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text("Seat map").font(DesignType.sectionTitle.font)
                Text("Positions are optional. Measurements stay authoritative; the map only adds coordinates. \(map.summaryText)")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Picker("Units", selection: $map.unit) {
                ForEach(RoomSeatMapUnit.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
    }

    // MARK: Map

    private var mapCanvas: some View {
        GeometryReader { proxy in
            let extent = RoomSeatMapLayout.extent(geometry: map.geometry, points: map.points)
            let layout = RoomSeatMapLayout(
                widthMetres: extent.width, lengthMetres: extent.length,
                viewWidth: Double(proxy.size.width), viewHeight: Double(proxy.size.height))
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).stroke(.secondary, lineWidth: 1)
                Text("Front wall").font(DesignType.caption.font).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.top, 2)
                ForEach(map.positionedPoints) { point in
                    if let pos = point.position {
                        let v = layout.viewPoint(x: pos.x, y: pos.y)
                        marker(point)
                            .position(x: v.x, y: v.y)
                            .gesture(
                                DragGesture(minimumDistance: 2, coordinateSpace: .named("seatmap"))
                                    .onChanged { g in
                                        let m = layout.metres(viewX: Double(g.location.x), viewY: Double(g.location.y))
                                        map.selectedPointID = point.id
                                        apply(map.setPosition(point.id, x: m.x, y: m.y, z: nil))
                                    })
                            .onTapGesture { map.selectedPointID = point.id }
                    }
                }
            }
            .coordinateSpace(name: "seatmap")
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minHeight: 200)
    }

    private var aspect: CGFloat {
        let e = RoomSeatMapLayout.extent(geometry: map.geometry, points: map.points)
        return CGFloat(max(e.width, 1) / max(e.length, 1))
    }

    private func marker(_ point: RoomPoint) -> some View {
        let selected = map.selectedPointID == point.id
        return VStack(spacing: 0) {
            Image(systemName: Self.symbol(point.kind))
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
            Text(point.name).font(.caption2).lineLimit(1).fixedSize()
        }
        .padding(2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(point.name), \(Self.kindName(point.kind)), \(describe(point.position))")
        .accessibilityHint("Use the position fields to move it.")
        .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
    }

    static func symbol(_ kind: RoomPointKind) -> String {
        switch kind {
        case .speakerFeed: return "hifispeaker.fill"
        case .subLane: return "speaker.wave.3.fill"
        case .seat, .ear: return "person.fill"
        case .referenceMic: return "mic.fill"
        case .surveyPoint: return "scope"
        }
    }

    static func kindName(_ kind: RoomPointKind) -> String {
        switch kind {
        case .speakerFeed: return "speaker"
        case .subLane: return "subwoofer"
        case .seat: return "seat"
        case .ear: return "ear"
        case .referenceMic: return "reference microphone"
        case .surveyPoint: return "survey point"
        }
    }

    private func describe(_ pos: RoomPosition?) -> String {
        guard let p = pos else { return "no position" }
        let k = map.unit.perMetre, u = map.unit.title
        return String(format: "across %.2f %@, into the room %.2f %@, height %.2f %@", p.x * k, u, p.y * k, u, p.z * k, u)
    }

    /// A linked point's edit goes back to the advisor's geometry draft; saving stays in the geometry section.
    private func apply(_ geometry: RoomGeometryModel?) {
        if let geometry { advisor.replaceGeometryDraft(geometry) }
    }

    // MARK: Side panel

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            if let point = map.selectedPoint { editor(point) } else {
                Text("Select a point on the map or in a list to enter its position.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            if !map.unpositionedPoints.isEmpty {
                VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                    Text("Not placed yet").font(DesignType.label.font)
                    ForEach(map.unpositionedPoints) { point in
                        Button {
                            map.selectedPointID = point.id
                        } label: {
                            Label("\(point.name) (\(Self.kindName(point.kind)))", systemImage: Self.symbol(point.kind))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(point.name), \(Self.kindName(point.kind)), no position")
                        .accessibilityHint("Select to enter a position.")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editor(_ point: RoomPoint) -> some View {
        let k = map.unit.perMetre
        let pos = point.position
        return VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
            Text("\(point.name) (\(Self.kindName(point.kind)))").font(DesignType.label.font)
            HStack {
                coordinateField("Across", value: (pos?.x ?? 0) * k) { commit(point, x: $0 / k, y: nil, z: nil) }
                coordinateField("Into room", value: (pos?.y ?? 0) * k) { commit(point, x: nil, y: $0 / k, z: nil) }
                coordinateField("Height", value: (pos?.z ?? 0) * k) { commit(point, x: nil, y: nil, z: $0 / k) }
            }
            HStack {
                Button("Remove position") { map.clearPosition(point.id) }
                    .disabled(pos == nil || map.linkedPointIDs.contains(point.id))
                if map.linkedPointIDs.contains(point.id) {
                    Text("Follows the room geometry.").font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func coordinateField(_ title: String, value: Double, onCommit: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title) (\(map.unit.title))").font(DesignType.caption.font).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: { onCommit($0) }), format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
                .accessibilityLabel("\(title) in \(map.unit == .metres ? "metres" : "feet")")
        }
    }

    private func commit(_ point: RoomPoint, x: Double?, y: Double?, z: Double?) {
        let p = point.position
        apply(map.setPosition(point.id, x: x ?? p?.x ?? 0, y: y ?? p?.y ?? 0, z: z ?? p?.z))
    }

    // MARK: Estimated seats (E29 S6)

    @State private var newSeatName = ""

    private var derivedList: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text("Seats you have not measured").font(DesignType.label.font)
            Text("Add a seat to see an estimate from the nearest measured seats. Estimates are shown with their confidence, never saved, and never used to design room correction or noise cancelling.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { seatEntry }
                VStack(alignment: .leading) { seatEntry }
            }
            ForEach(map.derivedRows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(row.seatName): \(row.text)").font(DesignType.caption.font)
                    Text("Used by: \(row.usedBy)").font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var seatEntry: some View {
        TextField("Seat name", text: $newSeatName)
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 220)
            .accessibilityLabel("Name of an unmeasured seat")
        Button("Add seat next to the main seat") {
            let base = map.positionedPoints.first { $0.kind == .seat }?.position
            _ = map.addUnmeasuredSeat(
                name: newSeatName, x: (base?.x ?? 1) + 0.5, y: base?.y ?? 2, z: base?.z ?? 1.1)
            newSeatName = ""
        }
        .disabled(newSeatName.trimmingCharacters(in: .whitespaces).isEmpty)
        ForEach(map.unmeasuredSeatIDs, id: \.self) { id in
            Button("Remove \(map.name(of: id))") { map.removeUnmeasuredSeat(id) }
        }
    }

    // MARK: Paths

    private var pathList: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text("Measured paths").font(DesignType.label.font)
            if map.pathRows.isEmpty {
                Text("No measured paths yet.").font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            ForEach(map.pathRows) { row in
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(row.sourceName) to \(row.receiverName): \(row.state)").font(DesignType.caption.font)
                    Text("Used by: \(row.usedBy)").font(DesignType.caption.font).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
