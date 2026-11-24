import SwiftUI

struct ProductionRoomTreatmentDesignSection: View {
    @Bindable var advisor: RoomTreatmentAdvisorController
    @State private var manualKind: RoomPassiveTreatmentKind = .broadbandAbsorber
    @State private var manualSurface: RoomGeometrySurface = .frontWall

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                Text("Treatment Design & Verification")
                    .font(DesignType.sectionTitle.font)
                Text("Design occasional physical improvements; nothing here changes live playback or any preset.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            if advisor.savedGeometry == nil || advisor.geometryHasUnsavedChanges {
                Label(
                    "Save a valid, accurate room model above before designing treatments. Unsaved placement experiments cannot become treatment plans.",
                    systemImage: "ruler"
                )
                .font(DesignType.label.font)
                .foregroundStyle(.secondary)
            } else {
                designContent
            }
            verificationCard
        }
        .padding(DesignSpacing.l.pt)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder
    private var designContent: some View {
        if advisor.treatmentDraft == nil {
            VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                Text("No physical treatment plan for this room")
                    .font(DesignType.label.font.bold())
                Text("Create an optional Advisor-only treatment plan based on the measured room and its modeled surfaces.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                Button("Create Treatment Plan") { advisor.createTreatmentPlan() }
                    .buttonStyle(.glassProminent)
            }
        } else if let plan = advisor.treatmentDraft {
            if let analysis = advisor.treatmentAnalysis {
                recommendedZones(analysis)
                TreatmentPlanRoomSketch(
                    geometry: advisor.savedGeometry!,
                    placements: plan.placements
                )
                .frame(height: 230)
                HStack {
                    Text("Plan · \(plan.placements.count) placements")
                        .font(DesignType.label.font.bold())
                    Spacer()
                    Text(String(format: "%.2f m² covered", analysis.treatmentAreaSquareMeters))
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
                ForEach(plan.placements) { placement in
                    placementEditor(placement)
                }
                if !analysis.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                        ForEach(analysis.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                                .font(DesignType.caption.font)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(DesignSpacing.m.pt)
                    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
                }
            } else {
                Text("Treatment geometry is invalid. Adjust or revert its placement coordinates.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
                ForEach(plan.placements) { placement in
                    placementEditor(placement)
                }
            }
            HStack(spacing: DesignSpacing.s.pt) {
                Picker("Type", selection: $manualKind) {
                    ForEach(RoomPassiveTreatmentKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .frame(maxWidth: 220)
                Picker("Surface", selection: $manualSurface) {
                    ForEach(RoomGeometrySurface.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
                .frame(maxWidth: 190)
                Button {
                    advisor.addManualTreatment(kind: manualKind, surface: manualSurface)
                } label: {
                    Label("Add Placement", systemImage: "plus")
                }
                .buttonStyle(.glass)
            }

            HStack {
                Button {
                    advisor.saveTreatmentPlan()
                } label: {
                    Label("Save Treatment Plan", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.glassProminent)
                .disabled(advisor.treatmentAnalysis == nil || !advisor.canEditTreatment)
                Button("Revert") { advisor.revertTreatmentPlan() }
                    .disabled(!advisor.treatmentHasUnsavedChanges)
                Spacer()
                if advisor.treatmentHasUnsavedChanges {
                    Text("UNSAVED DRAFT")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)
                } else {
                    Text("SAVED")
                        .font(DesignType.caption.font.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let message = advisor.treatmentMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(DesignType.caption.font)
                .foregroundStyle(StatusLevel.attention.color)
        }
    }

    private func recommendedZones(
        _ analysis: RoomPassiveTreatmentDesignSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Evidence-Based Placement Candidates")
                .font(DesignType.label.font.bold())
            if analysis.suggestions.isEmpty {
                Text("No sufficiently supported treatment zone is identified. Avoid blanket absorption; improve measurements or placement first.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
            ForEach(analysis.suggestions) { suggestion in
                HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                    VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                        Text(suggestion.title).font(DesignType.label.font.bold())
                        Text(suggestion.evidence)
                            .font(DesignType.caption.font)
                        Text(suggestion.rationale)
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                        Text("\(Int(suggestion.confidence * 100))% advisory confidence · \(suggestion.placement.surface.displayName)")
                            .font(DesignType.caption.font)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Add to Plan") {
                        advisor.addTreatmentSuggestion(suggestion)
                    }
                    .buttonStyle(.glass)
                }
                Divider()
            }
        }
        .padding(DesignSpacing.m.pt)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
    }

    private func placementEditor(
        _ item: RoomPassiveTreatmentPlacement
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            HStack {
                Picker("Treatment", selection: treatmentKind(item)) {
                    ForEach(RoomPassiveTreatmentKind.allCases) { kind in
                        Text(kind.label).tag(kind)
                    }
                }
                .frame(maxWidth: 240)
                Picker("Surface", selection: treatmentSurface(item)) {
                    ForEach(RoomGeometrySurface.allCases) { surface in
                        Text(surface.displayName).tag(surface)
                    }
                }
                .frame(maxWidth: 180)
                Spacer()
                Button(role: .destructive) {
                    advisor.removeTreatmentPlacement(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.glass)
                .help("Remove this treatment from the draft")
            }
            HStack(spacing: DesignSpacing.m.pt) {
                numericField("U (0–1)", item: item, keyPath: \.u)
                numericField("V (0–1)", item: item, keyPath: \.v)
                numericField("Width m", item: item, keyPath: \.widthMeters)
                numericField("Height m", item: item, keyPath: \.heightMeters)
                numericField("Depth m", item: item, keyPath: \.thicknessMeters)
                numericField("Gap m", item: item, keyPath: \.airGapMeters)
            }
            Text(String(format:
                "Total depth %.0f cm · quarter-wave context %.0f Hz (not an absorption prediction). Validate manufacturer data and real measurements.",
                item.totalDepthMeters * 100, item.quarterWavelengthContextHz))
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.m.pt)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
    }

    private func numericField(
        _ name: String,
        item: RoomPassiveTreatmentPlacement,
        keyPath: WritableKeyPath<RoomPassiveTreatmentPlacement, Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text(name).font(DesignType.caption.font).foregroundStyle(.secondary)
            TextField(
                name,
                value: numberBinding(item, keyPath),
                format: .number.precision(.fractionLength(2))
            )
            .textFieldStyle(.roundedBorder)
        }
        .frame(maxWidth: 100)
    }

    private func numberBinding(
        _ item: RoomPassiveTreatmentPlacement,
        _ keyPath: WritableKeyPath<RoomPassiveTreatmentPlacement, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                advisor.treatmentDraft?.placements.first(where: { $0.id == item.id })?[keyPath: keyPath]
                    ?? item[keyPath: keyPath]
            },
            set: { newValue in
                var changed = advisor.treatmentDraft?.placements.first(where: { $0.id == item.id }) ?? item
                changed[keyPath: keyPath] = newValue
                advisor.updateTreatmentPlacement(changed)
            }
        )
    }

    private func treatmentKind(_ item: RoomPassiveTreatmentPlacement) -> Binding<RoomPassiveTreatmentKind> {
        Binding(get: {
            advisor.treatmentDraft?.placements.first(where: { $0.id == item.id })?.kind ?? item.kind
        }, set: { kind in
            var changed = item
            changed.kind = kind
            advisor.updateTreatmentPlacement(changed)
        })
    }

    private func treatmentSurface(_ item: RoomPassiveTreatmentPlacement) -> Binding<RoomGeometrySurface> {
        Binding(get: {
            advisor.treatmentDraft?.placements.first(where: { $0.id == item.id })?.surface ?? item.surface
        }, set: { surface in
            var changed = item
            changed.surface = surface
            advisor.updateTreatmentPlacement(changed)
        })
    }

    private var verificationCard: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Before / After Measurements")
                .font(DesignType.label.font.bold())
            Text("The selected Room Advisor project is the baseline. Measure after installing treatment using the same microphone, sweep, speaker routing, level and named positions; save as a separate Room Correction project.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            Picker(
                "Follow-up project",
                selection: Binding(
                    get: { advisor.verificationFollowUpID },
                    set: { advisor.verifyTreatmentFollowUp($0) }
                )
            ) {
                Text("Select follow-up…").tag(UUID?.none)
                ForEach(advisor.treatmentFollowUpProjects) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }
            .frame(maxWidth: 480)

            if let result = advisor.verificationReport {
                if result.comparable {
                    HStack(spacing: DesignSpacing.m.pt) {
                        Text("\(result.matchedPositionCount) matched positions")
                        Text("\(result.improvements) improvements")
                        Text("\(result.regressions) regressions")
                    }
                    .font(DesignType.caption.font.bold())
                    ForEach(result.metrics) { metric in
                        HStack(alignment: .top, spacing: DesignSpacing.m.pt) {
                            VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
                                Text(metric.title).font(DesignType.label.font.bold())
                                Text(metric.explanation)
                                    .font(DesignType.caption.font)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: DesignSpacing.xs.pt) {
                                Text(String(format: "%.2f → %.2f %@", metric.baseline, metric.followUp, metric.unit))
                                    .font(DesignType.label.font.monospacedDigit())
                                Text(metric.change.title)
                                    .font(DesignType.caption.font.bold())
                            }
                        }
                        Divider()
                    }
                } else {
                    Label("Measurements not comparable", systemImage: "xmark.shield")
                        .font(DesignType.label.font.bold())
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(DesignType.caption.font)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No verification run selected. A treatment plan alone cannot demonstrate acoustic improvement.")
                    .font(DesignType.caption.font)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignSpacing.m.pt)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
    }
}

private struct TreatmentPlanRoomSketch: View {
    let geometry: RoomGeometryModel
    let placements: [RoomPassiveTreatmentPlacement]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            Text("Top-Down Treatment Layout · schematic")
                .font(DesignType.label.font.bold())
            GeometryReader { proxy in
                let space = CGSize(
                    width: max(1, proxy.size.width - 30),
                    height: max(1, proxy.size.height - 25)
                )
                let aspect = geometry.dimensions.width / geometry.dimensions.length
                let roomWidth: CGFloat = min(space.width, space.height * CGFloat(aspect))
                let roomHeight: CGFloat = roomWidth / CGFloat(aspect)
                let offset = CGPoint(x: (proxy.size.width - roomWidth) / 2, y: (proxy.size.height - roomHeight) / 2)
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .stroke(.secondary.opacity(0.65), lineWidth: 2)
                        .frame(width: roomWidth, height: roomHeight)
                        .position(x: offset.x + roomWidth / 2, y: offset.y + roomHeight / 2)
                    ForEach(placements) { item in
                        Text(item.kind == .bassTrap ? "B" : item.kind == .broadbandAbsorber ? "A" : "D")
                            .font(DesignType.caption.font.bold())
                            .frame(width: 23, height: 23)
                            .background(.regularMaterial, in: Circle())
                            .position(markerPosition(item, origin: offset, width: roomWidth, height: roomHeight))
                    }
                }
            }
            HStack(spacing: DesignSpacing.m.pt) {
                Text("B Bass trap")
                Text("A Absorber")
                Text("D Diffuser candidate")
            }
            .font(DesignType.caption.font)
            .foregroundStyle(.secondary)
            Text("Wall markers are projected onto the floor plan; the editor controls actual mounting height and area.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.m.pt)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: DesignRadius.medium.pt))
    }

    private func markerPosition(
        _ item: RoomPassiveTreatmentPlacement,
        origin: CGPoint,
        width: CGFloat,
        height: CGFloat
    ) -> CGPoint {
        let x: Double
        let y: Double
        switch item.surface {
        case .frontWall:
            x = item.u; y = 0
        case .rearWall:
            x = item.u; y = 1
        case .leftWall:
            x = 0; y = item.u
        case .rightWall:
            x = 1; y = item.u
        case .floor, .ceiling:
            x = item.u; y = item.v
        }
        return CGPoint(x: origin.x + width * CGFloat(x), y: origin.y + height * CGFloat(y))
    }
}
