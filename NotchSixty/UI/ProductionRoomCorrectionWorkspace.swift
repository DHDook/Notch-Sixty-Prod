import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ProductionRoomCorrectionWorkspace: View {
    @ObservedObject var engine: AudioIOEngine
    @ObservedObject var calibration: RoomCorrectionCalibrationController
    @ObservedObject var projects: RoomCorrectionProjectController
    @ObservedObject var profiles: ProductProfileController

    @State private var actionError: String?
    @State private var positionName = ""
    @State private var importingMicrophoneCalibration = false
    @State private var importingTargetCurve = false
    @State private var targetEditorText = ""
    @State private var correctionLowHz = 30.0
    @State private var correctionHighHz = 20_000.0
    @State private var smoothingOctaves = 1.0 / 6.0
    @State private var maximumBoostDB = 4.0
    @State private var maximumCutDB = 8.0
    @State private var requestedTapCount = 4_096
    @State private var designName = ""
    @State private var designPreview: RoomCorrectionCorrectionPreview?

    private var selectedInputBinding: Binding<String?> {
        Binding(
            get: { calibration.selectedInputUID },
            set: { calibration.selectInput(uid: $0) }
        )
    }

    private var inputChannelBinding: Binding<Int> {
        Binding(
            get: { calibration.selectedInputChannelIndex + 1 },
            set: { value in try? calibration.selectInputChannel(index: value - 1) }
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                dailyPlaybackCard
                setupCard
                measurementCard

                if calibration.state == .reviewing, let analysis = calibration.latestAnalysis {
                    reviewCard(analysis)
                }

                if !projects.positions.isEmpty {
                    positionsCard
                }

                if projects.aggregate != nil {
                    targetDesignCard
                }

                if let error = actionError ?? calibration.lastErrorDescription ?? projects.lastErrorDescription {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(28)
            .frame(maxWidth: 940, alignment: .topLeading)
        }
        .navigationTitle("Room Correction")
        .task { calibration.prepareForUse() }
        .task(id: profiles.selectedSystemProfileID) {
            projects.prepareForUse()
            do {
                try calibration.setMicrophoneCalibration(projects.project?.microphone?.calibration)
            } catch {
                actionError = error.localizedDescription
            }
        }
        .fileImporter(
            isPresented: $importingMicrophoneCalibration,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            importMicrophoneCalibrationFile(result)
        }
        .fileImporter(
            isPresented: $importingTargetCurve,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            importTargetCurveFile(result)
        }
        .task(id: projects.target?.id) {
            syncTargetEditorFromProject()
        }
        .task(id: projects.selectedDesign?.id) {
            syncDesignControlsFromProject()
        }
        .task(id: projects.project?.modifiedAt) {
            designPreview = nil
        }
        .task(id: calibration.state) {
            switch calibration.state {
            case .measuring:
                while !Task.isCancelled && calibration.state == .measuring {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard !Task.isCancelled else { break }
                    do {
                        if try calibration.finishMeasurementIfComplete() { break }
                    } catch {
                        actionError = error.localizedDescription
                        break
                    }
                }

            case .analyzing:
                _ = await calibration.analyzeLatestCapture()

            default:
                break
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Room Correction")
                .font(.largeTitle.bold())
            Text("Measure the physical stereo playback system independently from daily content DSP, then analyze and design a reproducible correction filter.")
                .foregroundStyle(.secondary)
        }
    }

    private var dailyPlaybackCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Daily Playback").font(.headline)
                    Text(engine.roomCorrectionConfiguration.filter?.name ?? "No correction filter deployed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle(
                    "Correction Enabled",
                    isOn: Binding(
                        get: { engine.roomCorrectionConfiguration.enabled },
                        set: { try? engine.setRoomCorrectionEnabled($0) }
                    )
                )
                .toggleStyle(.switch)
                .disabled(engine.roomCorrectionConfiguration.filter == nil)
            }

            HStack(spacing: 22) {
                statusValue(
                    "Playback System Output",
                    calibration.selectedOutputDevice?.name ?? "Not selected"
                )
                statusValue(
                    "Native Rate",
                    calibration.selectedOutputDevice.map { formattedRate($0.nominalSampleRate) } ?? "—"
                )
                statusValue(
                    "DSP State",
                    engine.lifecycleState.rawValue.capitalized
                )
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("1. Setup").font(.headline)
                Spacer()
                calibrationStateBadge
            }

            LabeledContent("Microphone Permission") {
                HStack(spacing: 10) {
                    Text(permissionLabel)
                        .foregroundStyle(calibration.permissionStatus == .authorized ? .primary : .secondary)
                    if calibration.permissionStatus != .authorized {
                        Button("Request Access") {
                            actionError = nil
                            Task { await calibration.requestMicrophonePermission() }
                        }
                        .disabled(calibration.state == .requestingPermission)
                    }
                }
            }

            if calibration.permissionStatus == .authorized {
                LabeledContent("Measurement Input") {
                    HStack(spacing: 10) {
                        Picker("Measurement Input", selection: selectedInputBinding) {
                            Text("Choose a microphone…").tag(Optional<String>.none)
                            ForEach(calibration.inputDevices) { device in
                                Text("\(device.name) · \(formattedRate(device.nominalSampleRate))")
                                    .tag(Optional(device.uid))
                            }
                        }
                        .labelsHidden()
                        .frame(minWidth: 320)
                        .disabled(calibration.state == .measuring || calibration.state == .arming)

                        Button("Refresh") {
                            actionError = nil
                            do { _ = try calibration.refreshInputDevices() }
                            catch { actionError = error.localizedDescription }
                        }
                        .disabled(calibration.state == .measuring || calibration.state == .arming)
                    }
                }

                LabeledContent("Microphone Channel") {
                    Stepper(
                        "Input \(calibration.selectedInputChannelIndex + 1)",
                        value: inputChannelBinding,
                        in: 1...32
                    )
                    .disabled(
                        calibration.selectedInputDevice == nil
                            || calibration.state == .measuring
                            || calibration.state == .arming
                    )
                }


                LabeledContent("Microphone Calibration") {
                    HStack(spacing: 10) {
                        Text(calibration.microphoneCalibration?.sourceName ?? "No calibration curve")
                            .foregroundStyle(calibration.microphoneCalibration == nil ? .secondary : .primary)
                            .lineLimit(1)

                        Button("Import…") {
                            actionError = nil
                            importingMicrophoneCalibration = true
                        }
                        .disabled(calibration.state == .measuring || calibration.state == .arming)

                        Button("Clear") {
                            actionError = nil
                            calibration.clearMicrophoneCalibration()
                        }
                        .disabled(
                            calibration.microphoneCalibration == nil
                                || calibration.state == .measuring
                                || calibration.state == .arming
                        )
                    }
                }

                if let microphoneCalibration = calibration.microphoneCalibration {
                    Text("\(microphoneCalibration.points.count) calibration points. The curve is applied to offline measurement analysis only; it is never inserted into daily playback DSP.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            LabeledContent("Sweep Duration") {
                Picker("Sweep Duration", selection: $calibration.sweepDurationSeconds) {
                    Text("5 s").tag(5.0)
                    Text("10 s").tag(10.0)
                    Text("15 s").tag(15.0)
                    Text("20 s").tag(20.0)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 320)
                .disabled(calibration.state == .measuring || calibration.state == .arming)
            }

            LabeledContent("Sweep Level") {
                HStack(spacing: 12) {
                    Slider(value: $calibration.sweepLevelDBFS, in: -36 ... -6, step: 1)
                        .frame(width: 280)
                    Text("\(calibration.sweepLevelDBFS, specifier: "%.0f") dBFS")
                        .monospacedDigit()
                        .frame(width: 72, alignment: .trailing)
                }
            }

            Text("Measurement uses two sequential sweeps at the current native output rate: Left speaker first, then Right. Captured microphone audio is never routed into playback. Start conservatively and raise the level only if measurement quality requires it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var measurementCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. Measure").font(.headline)

            if engine.lifecycleState != .idle {
                Label(
                    "Stop normal DSP playback before calibration can take exclusive ownership of the physical output.",
                    systemImage: "stop.circle"
                )
                .foregroundStyle(.orange)
            } else {
                Label(
                    "Normal DSP is idle. Calibration may claim the selected output without changing your Playback System settings.",
                    systemImage: "checkmark.circle"
                )
                .foregroundStyle(.secondary)
            }

            switch calibration.state {
            case .arming:
                ProgressView("Preparing dedicated calibration transport…")

            case .measuring:
                ProgressView(value: calibration.measurementProgress) {
                    Text("Capturing sequential Left / Right sweeps")
                } currentValueLabel: {
                    Text("\(calibration.measurementProgress * 100, specifier: "%.0f")%")
                        .monospacedDigit()
                }
                Text("Keep the microphone stationary until both sweeps and the decay tail finish.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Cancel Measurement", role: .cancel) {
                    calibration.cancelMeasurement()
                }

            case .analyzing:
                ProgressView("Extracting impulse responses and transfer functions…")
                if let capture = calibration.latestCapture {
                    Text("Left: \(capture.left.count) samples · Right: \(capture.right.count) samples")
                        .font(.system(.body, design: .monospaced))
                }
                Text("Analysis runs off the realtime audio path. The captured sweeps are being deconvolved and checked for clipping, noise, usable bandwidth, and direct-arrival timing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .reviewing:
                Label("Measurement and analysis complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Review the measured Left / Right quality below before keeping this position or measuring again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    actionError = nil
                    do { try calibration.beginMeasurement() }
                    catch { actionError = error.localizedDescription }
                } label: {
                    Label("Measure Current Position Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(!calibration.canBeginMeasurement)

            case .failed:
                Button("Reset Calibration") {
                    actionError = nil
                    calibration.resetAfterFailure()
                    calibration.prepareForUse()
                }

            default:
                Button {
                    actionError = nil
                    do { try calibration.beginMeasurement() }
                    catch { actionError = error.localizedDescription }
                } label: {
                    Label("Measure Current Position", systemImage: "waveform.badge.magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!calibration.canBeginMeasurement)

                Text("This capture measures one listening position. After analysis, keep it as a named position below, then repeat for additional seats.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private func reviewCard(_ analysis: RoomCorrectionMeasurementAnalysis) -> some View {
        let warnings = analysisWarnings(analysis)
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("3. Review").font(.headline)
                Spacer()
                Text(formattedRate(analysis.sampleRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            channelReview("Left", measurement: analysis.left)
            Divider()
            channelReview("Right", measurement: analysis.right)

            if !warnings.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Measurement notes", systemImage: "exclamationmark.triangle")
                        .font(.callout.weight(.semibold))
                    ForEach(warnings, id: \.self) { warning in
                        Text("• \(warning)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            if projects.contains(analysis) {
                Label("Current measurement retained in the Playback System project", systemImage: "tray.and.arrow.down.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    TextField(projects.suggestedPositionName, text: $positionName)
                        .frame(maxWidth: 280)
                    Button {
                        retainReviewedMeasurement(analysis)
                    } label: {
                        Label("Keep Position", systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Text("Leave the name blank to use \(projects.suggestedPositionName). Raw capture, impulse response, transfer function, and quality metadata are retained together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("This review is the measured response for the current position only. Retain the position, then use Target & Design below to shape and generate correction explicitly.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder
    private func channelReview(
        _ name: String,
        measurement: RoomCorrectionChannelMeasurement
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(name).font(.callout.weight(.semibold))
                Spacer()
                if measurement.quality.clipped {
                    Label("Clipped", systemImage: "waveform.path.badge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                } else {
                    Label("No clipping", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                statusValue("SNR", formattedDB(measurement.quality.estimatedSNRDB))
                statusValue("Capture Peak", formattedDB(measurement.quality.capturePeakDBFS))
                statusValue(
                    "Direct Arrival",
                    formattedMilliseconds(measurement.quality.directArrivalSeconds)
                )
                statusValue(
                    "Usable Band",
                    formattedBand(
                        low: measurement.quality.usableLowHz,
                        high: measurement.quality.usableHighHz
                    )
                )
                statusValue(
                    "Response Points",
                    String(measurement.transferFunction?.frequenciesHz.count ?? 0)
                )
            }
        }
    }

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("4. Positions").font(.headline)
                    Text(projects.project?.name ?? "No room-correction project")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Start New Project") {
                    actionError = nil
                    do {
                        try projects.startNewProject()
                        positionName = ""
                    } catch {
                        actionError = error.localizedDescription
                    }
                }
                .buttonStyle(.bordered)
            }

            ForEach(projects.positions) { position in
                RoomCorrectionPositionRow(
                    position: position,
                    projects: projects,
                    onError: { actionError = $0 }
                )
            }

            Divider()
            if let aggregate = projects.aggregate {
                Label(
                    "Weighted magnitude aggregate ready from \(aggregate.includedPositionIDs.count) included position\(aggregate.includedPositionIDs.count == 1 ? "" : "s")",
                    systemImage: "sum"
                )
                .font(.callout.weight(.semibold))
                Text("Weights are normalized before averaging magnitude in dB. Seat phase and timing remain attached to each individual measurement.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No aggregate is active. Include at least one retained position with weight greater than zero.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }

    private var targetDesignCard: some View {
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

    private func importMicrophoneCalibrationFile(_ result: Result<[URL], Error>) {
        actionError = nil
        do {
            let urls = try result.get()
            guard let url = urls.first else {
                actionError = "Choose a microphone calibration file."
                return
            }
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                actionError = "Microphone calibration files must be UTF-8 text with frequency and gain columns."
                return
            }
            _ = try calibration.importMicrophoneCalibration(
                text: text,
                sourceName: url.lastPathComponent
            )
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func retainReviewedMeasurement(_ analysis: RoomCorrectionMeasurementAnalysis) {
        actionError = nil
        guard let input = calibration.selectedInputDevice,
              let sweep = calibration.activePlan?.program.settings else {
            actionError = "The reviewed measurement no longer has its originating microphone or sweep metadata. Measure the position again before retaining it."
            return
        }

        let microphone = RoomCorrectionMicrophone(
            stableID: input.uid,
            displayName: input.name,
            manufacturer: nil,
            inputChannelIndex: calibration.selectedInputChannelIndex,
            calibration: calibration.microphoneCalibration
        )
        let proposed = positionName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try projects.retainMeasurement(
                analysis,
                sweep: sweep,
                microphone: microphone,
                name: proposed.isEmpty ? nil : proposed
            )
            positionName = ""
        } catch {
            actionError = error.localizedDescription
        }
    }

    private var calibrationStateBadge: some View {
        Text(calibration.state.rawValue.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.quaternary, in: Capsule())
    }

    private var permissionLabel: String {
        switch calibration.permissionStatus {
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted"
        case .denied: return "Denied"
        case .authorized: return "Authorized"
        }
    }

    @ViewBuilder
    private func statusValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
        }
    }

    private func analysisWarnings(_ analysis: RoomCorrectionMeasurementAnalysis) -> [String] {
        Array(Set(analysis.left.quality.warnings + analysis.right.quality.warnings)).sorted()
    }

    private func formattedDB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }

    private func formattedMilliseconds(_ seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return String(format: "%.2f ms", seconds * 1_000)
    }

    private func formattedBand(low: Double?, high: Double?) -> String {
        guard let low, let high else { return "—" }
        return "\(formattedFrequency(low)) – \(formattedFrequency(high))"
    }

    private func formattedFrequency(_ frequency: Double) -> String {
        if frequency >= 1_000 {
            return String(format: "%.1f kHz", frequency / 1_000)
        }
        return String(format: "%.0f Hz", frequency)
    }

    private func formattedRate(_ rate: Double) -> String {
        if rate >= 1_000 {
            return String(format: "%.1f kHz", rate / 1_000)
        }
        return String(format: "%.0f Hz", rate)
    }
}


private struct RoomCorrectionPositionRow: View {
    let positionID: UUID
    @ObservedObject var projects: RoomCorrectionProjectController
    let onError: (String) -> Void
    @State private var nameDraft: String

    init(
        position: RoomCorrectionMeasurementPosition,
        projects: RoomCorrectionProjectController,
        onError: @escaping (String) -> Void
    ) {
        positionID = position.id
        self.projects = projects
        self.onError = onError
        _nameDraft = State(initialValue: position.name)
    }

    private var position: RoomCorrectionMeasurementPosition? {
        projects.positions.first { $0.id == positionID }
    }

    var body: some View {
        if let position {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Toggle("Included", isOn: includedBinding)
                        .toggleStyle(.switch)
                        .controlSize(.small)

                    TextField("Position name", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .onSubmit { commitName() }

                    Button("Rename") { commitName() }
                        .buttonStyle(.bordered)
                        .disabled(nameDraft.trimmingCharacters(in: .whitespacesAndNewlines) == position.name)

                    Spacer()

                    Stepper(value: weightBinding, in: 0...10, step: 0.25) {
                        Text("Weight \(position.weight, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    .frame(width: 170)
                }

                HStack(spacing: 18) {
                    Text("L SNR \(formattedDB(position.left.quality.estimatedSNRDB))")
                    Text("R SNR \(formattedDB(position.right.quality.estimatedSNRDB))")
                    Text("\(position.sampleRate / 1_000, specifier: "%.1f") kHz")
                    Text(position.included ? "Included in aggregate" : "Retained · excluded")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: position.name) { _, newName in
                if nameDraft != newName { nameDraft = newName }
            }
        }
    }

    private var includedBinding: Binding<Bool> {
        Binding(
            get: { position?.included ?? false },
            set: { included in
                do { try projects.setMeasurementIncluded(id: positionID, included: included) }
                catch { onError(error.localizedDescription) }
            }
        )
    }

    private var weightBinding: Binding<Double> {
        Binding(
            get: { position?.weight ?? 0 },
            set: { weight in
                do { try projects.setMeasurementWeight(id: positionID, weight: weight) }
                catch { onError(error.localizedDescription) }
            }
        )
    }

    private func commitName() {
        do {
            try projects.renameMeasurement(id: positionID, to: nameDraft)
        } catch {
            onError(error.localizedDescription)
            if let position { nameDraft = position.name }
        }
    }

    private func formattedDB(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f dB", value)
    }
}
