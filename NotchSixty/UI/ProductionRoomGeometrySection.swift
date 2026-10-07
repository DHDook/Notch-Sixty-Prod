import SwiftUI

private enum RoomGeometryDisplayUnit:
    String, CaseIterable, Identifiable
{
    case meters
    case feet

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meters: return "m"
        case .feet: return "ft"
        }
    }

    var fromMeters: Double {
        switch self {
        case .meters: return 1
        case .feet: return 3.280839895
        }
    }
}

struct ProductionRoomGeometrySection: View {
    @ObservedObject var advisor: RoomTreatmentAdvisorController
    @State private var unit: RoomGeometryDisplayUnit = .meters
    @State private var showsAdvancedPredictions = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Geometry & Placement")
                        .font(.headline)
                    Text(
                        "Optional room model. Geometry predicts; measurements decide whether the prediction is actually present."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()

                Picker("Units", selection: $unit) {
                    ForEach(RoomGeometryDisplayUnit.allCases) {
                        value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 104)
            }

            if advisor.geometryDraft == nil {
                emptyGeometryState
            } else {
                geometryEditor

                if let message =
                    advisor.geometryValidationMessage {
                    Label(
                        message,
                        systemImage:
                            "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if let analysis = advisor.geometryAnalysis,
                   let model = advisor.geometryDraft {
                    GeometryRoomPlanView(
                        model: model,
                        analysis: analysis
                    )
                    .frame(height: 300)

                    evidenceCard(analysis)
                    placementCard(analysis)

                    DisclosureGroup(
                        "Detailed Geometry Predictions",
                        isExpanded:
                            $showsAdvancedPredictions
                    ) {
                        detailedPredictions(analysis)
                            .padding(.top, 10)
                    }
                }

                geometryActions
            }
        }
        .padding(18)
        .glassEffect(
            .regular,
            in: .rect(cornerRadius: 18)
        )
    }

    private var emptyGeometryState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "No room geometry saved for this measurement project",
                systemImage: "square.resize"
            )
            .font(.subheadline.bold())

            Text(
                "Add dimensions and speaker/listener positions to test room-mode, first-reflection and boundary-interference hypotheses. The template is only a starting point—replace every value with the real room."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                advisor.startGeometryTemplate()
            } label: {
                Label(
                    "Add Room Geometry",
                    systemImage: "plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(advisor.selectedProjectID == nil)
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            alignment: .leading
        )
        .background(
            .secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private var geometryEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Room Model")
                    .font(.subheadline.bold())
                Spacer()
                if advisor.geometryHasUnsavedChanges {
                    Text("UNSAVED")
                        .font(.caption.bold())
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                } else if advisor.savedGeometry != nil {
                    Text("SAVED")
                        .font(.caption.bold())
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                }
            }

            geometryFieldGroup(
                title: "Room dimensions",
                fields: [
                    ("Width", \.dimensions.width),
                    ("Length", \.dimensions.length),
                    ("Height", \.dimensions.height),
                ]
            )

            geometryFieldGroup(
                title: "Listener position",
                fields: [
                    ("X · left/right", \.listener.x),
                    ("Y · front/rear", \.listener.y),
                    ("Z · height", \.listener.z),
                ]
            )

            geometryFieldGroup(
                title: "Left speaker",
                fields: [
                    ("X", \.leftSpeaker.x),
                    ("Y", \.leftSpeaker.y),
                    ("Z", \.leftSpeaker.z),
                ]
            )

            geometryFieldGroup(
                title: "Right speaker",
                fields: [
                    ("X", \.rightSpeaker.x),
                    ("Y", \.rightSpeaker.y),
                    ("Z", \.rightSpeaker.z),
                ]
            )

            Text(
                "Coordinates: X runs left wall → right wall, Y front wall → rear wall, Z floor → ceiling."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func geometryFieldGroup(
        title: String,
        fields: [
            (
                String,
                WritableKeyPath<RoomGeometryModel, Double>
            )
        ]
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                ForEach(
                    Array(fields.enumerated()),
                    id: \.offset
                ) { item in
                    let field = item.element
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.0)
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        TextField(
                            field.0,
                            value:
                                geometryBinding(field.1),
                            format:
                                .number
                                .precision(
                                    .fractionLength(2)
                                )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                    }
                }

                Text(unit.title)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)

                Spacer()
            }
        }
    }

    private func geometryBinding(
        _ keyPath:
            WritableKeyPath<RoomGeometryModel, Double>
    ) -> Binding<Double> {
        Binding(
            get: {
                guard let model =
                        advisor.geometryDraft else {
                    return 0
                }
                return model[keyPath: keyPath]
                    * unit.fromMeters
            },
            set: { newValue in
                advisor.setGeometryValue(
                    keyPath,
                    newValue / unit.fromMeters
                )
            }
        )
    }

    private var geometryActions: some View {
        HStack(spacing: 10) {
            Button {
                advisor.saveGeometry()
            } label: {
                Label(
                    "Save Geometry",
                    systemImage: "square.and.arrow.down"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                advisor.geometryDraft == nil
                    || advisor.geometryAnalysis == nil
            )

            if advisor.savedGeometry != nil {
                Button {
                    advisor.revertGeometry()
                } label: {
                    Label(
                        "Revert",
                        systemImage: "arrow.uturn.backward"
                    )
                }
                .buttonStyle(.bordered)
                .disabled(
                    !advisor.geometryHasUnsavedChanges
                )

                Button(role: .destructive) {
                    advisor.clearGeometry()
                } label: {
                    Label(
                        "Clear",
                        systemImage: "trash"
                    )
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Label(
                "Prediction only · verify by re-measuring",
                systemImage: "ruler"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func evidenceCard(
        _ analysis: RoomGeometryAnalysis
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Geometry × Measurement")
                .font(.subheadline.bold())

            ForEach(analysis.evidence.prefix(8)) {
                evidence in
                HStack(alignment: .top, spacing: 10) {
                    Text(evidence.status.displayName.uppercased())
                        .font(.caption2.bold())
                        .tracking(0.6)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            .secondary.opacity(0.09),
                            in: Capsule()
                        )
                        .frame(width: 88)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(evidence.title)
                            .font(.callout.bold())
                        Text(evidence.prediction)
                            .font(.caption)
                        if let measurement =
                            evidence.measurement {
                            Text(measurement)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(evidence.rationale)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(
                                horizontal: false,
                                vertical: true
                            )
                    }
                    Spacer()
                }
            }
        }
        .padding(14)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private func placementCard(
        _ analysis: RoomGeometryAnalysis
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Placement Experiments")
                .font(.subheadline.bold())

            if analysis.placementCandidates.isEmpty {
                Text(
                    "No nearby candidate materially improves the current geometry-risk score. This does not prove the current placement is optimal; it only means the bounded PR93 search did not find a useful simple move."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(
                    analysis
                        .placementCandidates.indices,
                    id: \.self
                ) { index in
                    let candidate =
                        analysis.placementCandidates[index]
                    HStack(alignment: .top, spacing: 11) {
                        Text("\(index + 1)")
                            .font(
                                .headline
                                .monospacedDigit()
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                Color.accentColor
                                    .opacity(0.12),
                                in: Circle()
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(candidate.title)
                                    .font(.callout.bold())
                                Text(
                                    String(
                                        format:
                                            "geometry risk −%.0f%%",
                                        candidate
                                            .expectedImprovementPercent
                                    )
                                )
                                .font(.caption.bold())
                                .foregroundStyle(.secondary)
                            }

                            Text(candidate.detail)
                                .font(.caption)

                            Text(candidate.rationale)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(
                                    horizontal: false,
                                    vertical: true
                                )
                        }
                        Spacer()
                    }

                    if index
                        < analysis
                            .placementCandidates
                            .count - 1 {
                        Divider()
                    }
                }

                Label(
                    "These percentages describe the relative geometry-risk score—not predicted SPL or guaranteed audible improvement. Move one thing, re-measure, and keep the change only if the measurement improves.",
                    systemImage:
                        "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private func detailedPredictions(
        _ analysis: RoomGeometryAnalysis
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            predictionGroup(
                title: "Lowest Room Modes",
                rows:
                    analysis.modes
                    .prefix(10)
                    .map {
                        String(
                            format:
                                "%@ · %.1f Hz",
                            $0.label,
                            $0.frequencyHz
                        )
                    }
            )

            predictionGroup(
                title: "Earliest First Reflections",
                rows:
                    analysis.reflections
                    .prefix(8)
                    .map {
                        String(
                            format:
                                "%@ / %@ · %.1f ms · +%.2f m path",
                            $0.speaker.displayName,
                            $0.surface.displayName,
                            $0.delayMilliseconds,
                            $0.excessPathMeters
                        )
                    }
            )

            predictionGroup(
                title: "Boundary Cancellation Candidates",
                rows:
                    analysis.boundaryInterference
                    .prefix(8)
                    .map {
                        String(
                            format:
                                "%@ / %@ · %.1f Hz",
                            $0.speaker.displayName,
                            $0.surface.displayName,
                            $0.firstCancellationHz
                        )
                    }
            )
        }
    }

    private func predictionGroup(
        title: String,
        rows: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            ForEach(rows, id: \.self) { row in
                Text(row)
                    .font(
                        .system(
                            .caption,
                            design: .monospaced
                        )
                    )
            }
        }
    }
}

private struct GeometryRoomPlanView: View {
    var model: RoomGeometryModel
    var analysis: RoomGeometryAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Top-Down Room Plan")
                    .font(.subheadline.bold())
                Spacer()
                Text("FRONT WALL")
                    .font(.caption2.bold())
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { proxy in
                let inset: CGFloat = 22
                let width =
                    max(1, proxy.size.width - inset * 2)
                let height =
                    max(1, proxy.size.height - inset * 2)
                let roomAspect =
                    model.dimensions.width
                    / model.dimensions.length
                let canvasAspect =
                    Double(width / height)

                let roomWidth: CGFloat =
                    roomAspect > canvasAspect
                    ? width
                    : height * CGFloat(roomAspect)
                let roomHeight: CGFloat =
                    roomAspect > canvasAspect
                    ? width / CGFloat(roomAspect)
                    : height

                let origin = CGPoint(
                    x:
                        (proxy.size.width - roomWidth)
                        / 2,
                    y:
                        (proxy.size.height - roomHeight)
                        / 2
                )

                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            .secondary.opacity(0.55),
                            lineWidth: 1.5
                        )
                        .frame(
                            width: roomWidth,
                            height: roomHeight
                        )
                        .position(
                            x: origin.x + roomWidth / 2,
                            y: origin.y + roomHeight / 2
                        )

                    ForEach(
                        analysis.reflections
                            .filter {
                                $0.surface != .floor
                                    && $0.surface != .ceiling
                            }
                            .prefix(8)
                    ) { reflection in
                        Circle()
                            .fill(
                                .secondary.opacity(0.35)
                            )
                            .frame(width: 6, height: 6)
                            .position(
                                roomPoint(
                                    reflection
                                        .reflectionPoint,
                                    origin: origin,
                                    roomWidth: roomWidth,
                                    roomHeight: roomHeight
                                )
                            )
                    }

                    speakerMarker(
                        "L",
                        at: model.leftSpeaker,
                        origin: origin,
                        roomWidth: roomWidth,
                        roomHeight: roomHeight
                    )

                    speakerMarker(
                        "R",
                        at: model.rightSpeaker,
                        origin: origin,
                        roomWidth: roomWidth,
                        roomHeight: roomHeight
                    )

                    listenerMarker(
                        at: model.listener,
                        origin: origin,
                        roomWidth: roomWidth,
                        roomHeight: roomHeight
                    )
                }
            }

            HStack(spacing: 14) {
                Label(
                    "L/R speakers",
                    systemImage: "hifispeaker.fill"
                )
                Label(
                    "Listener",
                    systemImage: "person.fill"
                )
                Label(
                    "Predicted reflection point",
                    systemImage: "circle.fill"
                )
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(
            .secondary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 13)
        )
    }

    private func roomPoint(
        _ point: RoomGeometryPoint3D,
        origin: CGPoint,
        roomWidth: CGFloat,
        roomHeight: CGFloat
    ) -> CGPoint {
        CGPoint(
            x:
                origin.x
                + CGFloat(
                    point.x / model.dimensions.width
                ) * roomWidth,
            y:
                origin.y
                + CGFloat(
                    point.y / model.dimensions.length
                ) * roomHeight
        )
    }

    private func speakerMarker(
        _ label: String,
        at point: RoomGeometryPoint3D,
        origin: CGPoint,
        roomWidth: CGFloat,
        roomHeight: CGFloat
    ) -> some View {
        Text(label)
            .font(.caption2.bold())
            .frame(width: 26, height: 26)
            .background(
                .regularMaterial,
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(
                        Color.accentColor.opacity(0.65),
                        lineWidth: 1
                    )
            }
            .position(
                roomPoint(
                    point,
                    origin: origin,
                    roomWidth: roomWidth,
                    roomHeight: roomHeight
                )
            )
    }

    private func listenerMarker(
        at point: RoomGeometryPoint3D,
        origin: CGPoint,
        roomWidth: CGFloat,
        roomHeight: CGFloat
    ) -> some View {
        Image(systemName: "person.fill")
            .font(.caption)
            .frame(width: 28, height: 28)
            .background(
                .regularMaterial,
                in: Circle()
            )
            .position(
                roomPoint(
                    point,
                    origin: origin,
                    roomWidth: roomWidth,
                    roomHeight: roomHeight
                )
            )
    }
}
