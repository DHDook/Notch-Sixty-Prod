from pathlib import Path

path = Path('NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift')
text = path.read_text()

old = '''    @State private var positionName = ""\n    @State private var importingMicrophoneCalibration = false\n'''
new = '''    @State private var positionName = ""\n    @State private var importingMicrophoneCalibration = false\n    @State private var importingTargetCurve = false\n    @State private var targetEditorText = ""\n    @State private var correctionLowHz = 30.0\n    @State private var correctionHighHz = 20_000.0\n    @State private var smoothingOctaves = 1.0 / 6.0\n    @State private var maximumBoostDB = 4.0\n    @State private var maximumCutDB = 8.0\n    @State private var requestedTapCount = 4_096\n    @State private var designName = ""\n    @State private var designPreview: RoomCorrectionCorrectionPreview?\n'''
assert old in text
text = text.replace(old, new, 1)

old = '''                if !projects.positions.isEmpty {\n                    positionsCard\n                }\n\n                if let error = actionError ?? calibration.lastErrorDescription ?? projects.lastErrorDescription {\n'''
new = '''                if !projects.positions.isEmpty {\n                    positionsCard\n                }\n\n                if projects.aggregate != nil {\n                    targetDesignCard\n                }\n\n                if let error = actionError ?? calibration.lastErrorDescription ?? projects.lastErrorDescription {\n'''
assert old in text
text = text.replace(old, new, 1)

old = '''        .fileImporter(\n            isPresented: $importingMicrophoneCalibration,\n            allowedContentTypes: [.data],\n            allowsMultipleSelection: false\n        ) { result in\n            importMicrophoneCalibrationFile(result)\n        }\n        .task(id: calibration.state) {\n'''
new = '''        .fileImporter(\n            isPresented: $importingMicrophoneCalibration,\n            allowedContentTypes: [.data],\n            allowsMultipleSelection: false\n        ) { result in\n            importMicrophoneCalibrationFile(result)\n        }\n        .fileImporter(\n            isPresented: $importingTargetCurve,\n            allowedContentTypes: [.plainText, .data],\n            allowsMultipleSelection: false\n        ) { result in\n            importTargetCurveFile(result)\n        }\n        .task(id: projects.target?.id) {\n            syncTargetEditorFromProject()\n        }\n        .task(id: projects.selectedDesign?.id) {\n            syncDesignControlsFromProject()\n        }\n        .task(id: projects.project?.modifiedAt) {\n            designPreview = nil\n        }\n        .task(id: calibration.state) {\n'''
assert old in text
text = text.replace(old, new, 1)

old = '''            Text("This review is the measured response for the current position only. Target shaping and FIR design remain separate downstream stages; none are inferred here.")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n'''
new = '''            Text("This review is the measured response for the current position only. Retain the position, then use Target & Design below to shape and generate correction explicitly.")\n                .font(.caption)\n                .foregroundStyle(.secondary)\n'''
assert old in text
text = text.replace(old, new, 1)

anchor = '''    private func importMicrophoneCalibrationFile(_ result: Result<[URL], Error>) {\n'''
assert anchor in text
card = r'''    private var targetDesignCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("5. Target & Design").font(.headline)
                    Text("Shape the retained aggregate, preview safety limits, then generate a bounded minimum-phase FIR candidate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(RoomCorrectionBuiltInTarget.allCases) { builtIn in
                        Button(builtIn.curve.name) {
                            applyTarget(builtIn.curve)
                        }
                    }
                    Divider()
                    Button("Import Target…") {
                        actionError = nil
                        importingTargetCurve = true
                    }
                } label: {
                    Label(projects.target?.name ?? "Choose Target", systemImage: "scope")
                }
                .buttonStyle(.bordered)
            }

            if let target = projects.target {
                HStack(spacing: 20) {
                    statusValue("Target", target.name)
                    statusValue("Points", String(target.points.count))
                    if let aggregate = projects.aggregate {
                        statusValue(
                            "Aggregate",
                            "\(aggregate.includedPositionIDs.count) position\(aggregate.includedPositionIDs.count == 1 ? "" : "s")"
                        )
                    }
                }

                DisclosureGroup("Edit target points") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("One frequency/gain pair per line. Frequencies are interpolated in log space; duplicate frequencies are averaged when applied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $targetEditorText)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 110, maxHeight: 170)
                            .padding(6)
                            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
                        HStack {
                            Button("Apply Edited Points") { applyEditedTarget() }
                                .disabled(targetEditorText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            Button("Revert Editor") { syncTargetEditorFromProject() }
                        }
                    }
                    .padding(.top, 8)
                }
            } else {
                Text("Choose a built-in target or import a UTF-8 two-column frequency/gain target before previewing correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 12) {
                GridRow {
                    Text("Correction range").foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        TextField("Low", value: $correctionLowHz, format: .number)
                            .frame(width: 90)
                        Text("Hz –")
                        TextField("High", value: $correctionHighHz, format: .number)
                            .frame(width: 100)
                        Text("Hz")
                    }
                }
                GridRow {
                    Text("Smoothing").foregroundStyle(.secondary)
                    Picker("Smoothing", selection: $smoothingOctaves) {
                        Text("Off").tag(0.0)
                        Text("1/12 oct").tag(1.0 / 12.0)
                        Text("1/6 oct").tag(1.0 / 6.0)
                        Text("1/3 oct").tag(1.0 / 3.0)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 360)
                }
                GridRow {
                    Text("Maximum boost").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Slider(value: $maximumBoostDB, in: 0...12, step: 0.5)
                            .frame(width: 260)
                        Text("\(maximumBoostDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 62, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("Maximum cut").foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Slider(value: $maximumCutDB, in: 0...24, step: 0.5)
                            .frame(width: 260)
                        Text("\(maximumCutDB, specifier: "%.1f") dB")
                            .monospacedDigit()
                            .frame(width: 62, alignment: .trailing)
                    }
                }
                GridRow {
                    Text("FIR length").foregroundStyle(.secondary)
                    Picker("FIR length", selection: $requestedTapCount) {
                        ForEach([1_024, 2_048, 4_096, 8_192, 16_384, 32_768], id: \.self) { taps in
                            Text("\(taps.formatted()) taps").tag(taps)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180)
                }
            }

            HStack(spacing: 12) {
                Button {
                    previewCurrentDesign()
                } label: {
                    Label("Preview Correction", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
                .disabled(projects.target == nil || projects.aggregate == nil)

                TextField("Design name", text: $designName)
                    .frame(maxWidth: 260)

                Button {
                    generateCurrentDesign()
                } label: {
                    Label("Generate FIR", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .disabled(projects.target == nil || projects.aggregate == nil)
            }

            if let preview = designPreview {
                Divider()
                HStack(spacing: 24) {
                    statusValue(
                        "Effective Range",
                        "\(formattedFrequency(preview.effectiveCorrectionLowHz)) – \(formattedFrequency(preview.effectiveCorrectionHighHz))"
                    )
                    statusValue(
                        "Preview Max Boost",
                        String(format: "%.2f dB", preview.maximumPositiveCorrectionDB)
                    )
                    statusValue(
                        "Preview Headroom",
                        String(format: "%.1f dB", preview.estimatedHeadroomDB)
                    )
                }
                Text("Preview headroom is advisory only. Content Preset headroom is not changed by Room Correction.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !projects.designs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    Text("Generated Designs").font(.callout.weight(.semibold))
                    ForEach(Array(projects.designs.reversed())) { design in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(design.name).font(.callout.weight(.medium))
                                Text("\(design.parameters.requestedTapCount.formatted()) taps · \(formattedRate(design.sampleRate)) · headroom \(design.recommendedHeadroomDB, specifier: "%.1f") dB")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if projects.selectedDesign?.id == design.id {
                                Label("Selected", systemImage: "checkmark.circle.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                            } else {
                                Button("Select") {
                                    actionError = nil
                                    do { try projects.selectDesign(id: design.id) }
                                    catch { actionError = error.localizedDescription }
                                }
                            }
                            Button(role: .destructive) {
                                actionError = nil
                                do { try projects.deleteDesign(id: design.id) }
                                catch { actionError = error.localizedDescription }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if let selected = projects.selectedDesign {
                Divider()
                Label("Selected candidate: \(selected.name). Deployment remains a separate explicit step and daily playback is unchanged.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var currentDesignParameters: RoomCorrectionDesignParameters {
        RoomCorrectionDesignParameters(
            correctionLowHz: correctionLowHz,
            correctionHighHz: correctionHighHz,
            smoothingOctaves: smoothingOctaves,
            maximumBoostDB: maximumBoostDB,
            maximumCutDB: maximumCutDB,
            requestedTapCount: requestedTapCount
        )
    }

    private func applyTarget(_ target: RoomCorrectionTargetCurve) {
        actionError = nil
        do {
            try projects.setTarget(target)
            targetEditorText = serializedTarget(target)
            designPreview = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func applyEditedTarget() {
        actionError = nil
        guard let current = projects.target else {
            actionError = "Choose a target before editing target points."
            return
        }
        do {
            let edited = try RoomCorrectionTargetCurveParser().parse(
                targetEditorText,
                name: current.name,
                id: current.id
            )
            try projects.setTarget(edited)
            targetEditorText = serializedTarget(edited)
            designPreview = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func previewCurrentDesign() {
        actionError = nil
        do {
            designPreview = try projects.previewDesign(parameters: currentDesignParameters)
        } catch {
            designPreview = nil
            actionError = error.localizedDescription
        }
    }

    private func generateCurrentDesign() {
        actionError = nil
        let trimmed = designName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = projects.target.map { "\($0.name) Correction" } ?? "Room Correction"
        do {
            _ = try projects.generateDesign(
                parameters: currentDesignParameters,
                name: trimmed.isEmpty ? fallback : trimmed
            )
            designName = ""
            designPreview = try? projects.previewDesign(parameters: currentDesignParameters)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func syncTargetEditorFromProject() {
        targetEditorText = projects.target.map(serializedTarget) ?? ""
    }

    private func syncDesignControlsFromProject() {
        if let selected = projects.selectedDesign {
            let parameters = selected.parameters
            correctionLowHz = parameters.correctionLowHz
            correctionHighHz = parameters.correctionHighHz
            smoothingOctaves = parameters.smoothingOctaves
            maximumBoostDB = parameters.maximumBoostDB
            maximumCutDB = parameters.maximumCutDB
            requestedTapCount = parameters.requestedTapCount
            return
        }
        if let sampleRate = projects.project?.sweep?.sampleRate {
            correctionHighHz = min(correctionHighHz, sampleRate * 0.45)
        }
    }

    private func serializedTarget(_ target: RoomCorrectionTargetCurve) -> String {
        target.points.map {
            String(format: "%.3f %.3f", $0.frequencyHz, $0.gainDB)
        }.joined(separator: "\n")
    }

    private func importTargetCurveFile(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                actionError = "Choose a target curve file."
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            guard let targetText = String(data: data, encoding: .utf8) else {
                actionError = "Target files must be UTF-8 text with frequency and gain columns."
                return
            }
            let sourceName = url.deletingPathExtension().lastPathComponent
            let target = try RoomCorrectionTargetCurveParser().parse(
                targetText,
                name: sourceName.isEmpty ? "Imported Target" : sourceName
            )
            try projects.setTarget(target)
            targetEditorText = serializedTarget(target)
            designPreview = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

'''
text = text.replace(anchor, card + anchor, 1)
path.write_text(text)
