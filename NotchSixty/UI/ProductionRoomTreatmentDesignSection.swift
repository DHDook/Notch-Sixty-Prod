import SwiftUI

struct ProductionRoomTreatmentDesignSection: View {
    @ObservedObject var advisor: RoomTreatmentAdvisorController
    @State private var manualKind: RoomPassiveTreatmentKind = .broadbandAbsorber
    @State private var manualSurface: RoomGeometrySurface = .frontWall

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Treatment Design & Verification")
                    .font(.headline)
                Text("Design occasional physical improvements; nothing here changes live playback or any preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if advisor.savedGeometry == nil || advisor.geometryHasUnsavedChanges {
                Label(
                    "Save a valid, accurate room model above before designing treatments. Unsaved placement experiments cannot become treatment plans.",
                    systemImage: "ruler"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else {
                designContent
            }
            verificationCard
        }
        .padding(18)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private var designContent: some View {
        if advisor.treatmentDraft == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("No physical treatment plan for this room")
                    .font(.subheadline.bold())
                Text("Create an optional Advisor-only treatment plan based on the measured room and its modeled surfaces.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Create Treatment Plan") { advisor.createTreatmentPlan() }
                    .buttonStyle(.borderedProminent)
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
                        .font(.subheadline.bold())
                    Spacer()
                    Text(String(format: "%.2f m² covered", analysis.treatmentAreaSquareMeters))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(plan.placements) { placement in
                    placementEditor(placement)
                }
                if !analysis.warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(analysis.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "info.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(12)
                    .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text("Treatment geometry is invalid. Adjust or revert its placement coordinates.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(plan.placements) { placement in
                    placementEditor(placement)
                }
            }
            HStack(spacing: 8) {
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
                .buttonStyle(.bordered)
            }

            HStack {
                Button {
                    advisor.saveTreatmentPlan()
                } label: {
                    Label("Save Treatment Plan", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .disabled(advisor.treatmentAnalysis == nil || !advisor.canEditTreatment)
                Button("Revert") { advisor.revertTreatmentPlan() }
                    .disabled(!advisor.treatmentHasUnsavedChanges)
                Spacer()
                if advisor.treatmentHasUnsavedChanges {
                    Text("UNSAVED DRAFT")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                } else {
                    Text("SAVED")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                }
            }
        }
        if let message = advisor.treatmentMessage {
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func recommendedZones(
        _ analysis: RoomPassiveTreatmentDesignSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Evidence-Based Placement Candidates")
                .font(.subheadline.bold())
            if analysis.suggestions.isEmpty {
                Text("No sufficiently supported treatment zone is identified. Avoid blanket absorption; improve measurements or placement first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(analysis.suggestions) { suggestion in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(suggestion.title).font(.callout.bold())
                        Text(suggestion.evidence)
                            .font(.caption)
                        Text(suggestion.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(Int(suggestion.confidence * 100))% advisory confidence · \(suggestion.placement.surface.displayName)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button("Add to Plan") {
                        advisor.addTreatmentSuggestion(suggestion)
                    }
                    .buttonStyle(.bordered)
                }
                Divider()
            }
        }
        .padding(12)
        .background(.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func placementEditor(
        _ item: RoomPassiveTreatmentPlacement
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
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
                .buttonStyle(.bordered)
                .help("Remove this treatment from the draft")
            }
            HStack(spacing: 12) {
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
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }

    private func numericField(
        _ name: String,
        item: RoomPassiveTreatmentPlacement,
        keyPath: WritableKeyPath<RoomPassiveTreatmentPlacement, Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 11) {
            Text("Before / After Measurements")
                .font(.subheadline.bold())
            Text("The selected Room Advisor project is the baseline. Measure after installing treatment using the same microphone, sweep, speaker routing, level and named positions; save as a separate Room Correction project.")
                .font(.caption)
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
                    HStack(spacing: 12) {
                        Text("\(result.matchedPositionCount) matched positions")
                        Text("\(result.improvements) improvements")
                        Text("\(result.regressions) regressions")
                    }
                    .font(.caption.bold())
                    ForEach(result.metrics) { metric in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.title).font(.callout.bold())
                                Text(metric.explanation)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 3) {
                                Text(String(format: "%.2f → %.2f %@", metric.baseline, metric.followUp, metric.unit))
                                    .font(.callout.monospacedDigit())
                                Text(metric.change.title)
                                    .font(.caption.bold())
                            }
                        }
                        Divider()
                    }
                } else {
                    Label("Measurements not comparable", systemImage: "xmark.shield")
                        .font(.callout.bold())
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Label(warning, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No verification run selected. A treatment plan alone cannot demonstrate acoustic improvement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct TreatmentPlanRoomSketch: View {
    let geometry: RoomGeometryModel
    let placements: [RoomPassiveTreatmentPlacement]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Top-Down Treatment Layout · schematic")
                .font(.subheadline.bold())
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
                            .font(.caption2.bold())
                            .frame(width: 23, height: 23)
                            .background(.regularMaterial, in: Circle())
                            .position(markerPosition(item, origin: offset, width: roomWidth, height: roomHeight))
                    }
                }
            }
            HStack(spacing: 12) {
                Text("B Bass trap")
                Text("A Absorber")
                Text("D Diffuser candidate")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            Text("Wall markers are projected onto the floor plan; the editor controls actual mounting height and area.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
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
