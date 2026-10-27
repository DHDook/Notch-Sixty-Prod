import SwiftUI

// E8 S6: the routing and crossover editor, shown on the Speakers tab. It edits a
// `SpeakerRoutingConfiguration` through `SpeakerRoutingEditorModel` and hands each edit to the engine, which republishes
// live where it can and reconfigures with the shutdown fade where it must.

struct ProductionRoutingEditorView: View {
    @ObservedObject var engine: AudioIOEngine
    @StateObject private var model: SpeakerRoutingEditorModel
    @State private var actionError: String?
    @State private var interchangeNotes: [String] = []

    init(engine: AudioIOEngine) {
        self.engine = engine
        let device = engine.selectedOutputDevice
        let profile = engine.outputDeviceProfileConfiguration
        let program = (profile?.enabled == true) ? profile?.programLayout.roles.count ?? 2 : 2
        let subs = (profile?.enabled == true) ? profile?.subwooferAssignments.count ?? 0 : 0
        let configuration = engine.speakerRoutingConfiguration ?? SpeakerRoutingConfiguration(enabled: false)
        _model = StateObject(wrappedValue: SpeakerRoutingEditorModel(
            configuration: configuration,
            context: SpeakerRoutingContext(
                programLanes: program,
                subwoofers: max(subs, configuration.subwooferSourceCount),
                sampleRate: device?.nominalSampleRate ?? 48_000)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            templateCard
            ForEach(model.configuration.speakers) { speaker in
                speakerCard(speaker)
            }
            matrixCard
            pipelineCard
            camillaCard
            if !model.messages.isEmpty { messagesCard }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .onAppear { model.onCommit = commit }
    }

    private func commit(_ configuration: SpeakerRoutingConfiguration) {
        do {
            try engine.replaceSpeakerRoutingConfiguration(configuration)
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
    }

    // MARK: Cards

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Routing and crossovers").font(.title2.weight(.semibold))
            Toggle("Use the routing matrix", isOn: Binding(
                get: { model.configuration.enabled }, set: { model.setEnabled($0) }))
            Text("Each speaker has a source and one to eight ways. Every way has its own output, filters, EQ, trim, polarity and delay.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var templateCard: some View {
        GroupBox("System template") {
            HStack {
                Picker("System template", selection: Binding(
                    get: { model.currentTemplate },
                    set: { choice in
                        guard let choice else { return }
                        guard let device = engine.selectedOutputDevice else {
                            actionError = "Select an output device first."
                            return
                        }
                        if !model.applyTemplate(choice, deviceUID: device.uid) {
                            actionError = "That template does not fit this layout."
                        }
                    }
                )) {
                    if model.currentTemplate == nil {
                        Text("Custom").tag(SpeakerRoutingTemplate?.none)
                    }
                    ForEach(SpeakerRoutingTemplate.allCases) { template in
                        Text(template.displayName).tag(Optional(template))
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
                Text("Choosing a template rebuilds the speakers; outputs are assigned in channel order on the selected device.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }

    private func speakerCard(_ speaker: RoutedSpeaker) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(speaker.name.isEmpty ? "Speaker" : speaker.name).font(.headline)
                    Text(SpeakerRoutingEditorModel.sourceName(speaker.source)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add way") {
                        let used = Set(model.configuration.outputEndpoints.map(\.channelIndex))
                        let channel = (0..<UInt32(64)).first { !used.contains($0) } ?? 0
                        let uid = speaker.ways.first?.endpoint.deviceUID ?? engine.selectedOutputDevice?.uid ?? ""
                        if !model.addWay(speaker: speaker.id,
                                         endpoint: PhysicalOutputEndpoint(deviceUID: uid, channelIndex: channel)) {
                            actionError = "A speaker can have at most \(RoutedSpeaker.maxWays) ways."
                        }
                    }
                    Button("Remove speaker", role: .destructive) { model.removeSpeaker(speaker.id) }
                }
                RoutingResponsePlot(model: model, speaker: speaker)
                    .frame(height: 140)
                ForEach(speaker.ways) { way in
                    wayRow(speaker: speaker, way: way)
                    Divider()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func wayRow(speaker: RoutedSpeaker, way: RoutedWay) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(way.name.isEmpty ? "Way" : way.name).font(.subheadline.weight(.semibold))
                Text("Output \(way.endpoint.channelIndex + 1)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Remove") { _ = model.removeWay(way.id, speaker: speaker.id) }
                    .disabled(speaker.ways.count < 2)
            }
            HStack(spacing: 16) {
                filterEditor("High-pass", spec: way.highPass, edge: .highPass, speaker: speaker, way: way)
                filterEditor("Low-pass", spec: way.lowPass, edge: .lowPass, speaker: speaker, way: way)
            }
            HStack(spacing: 16) {
                numberField("Trim dB", value: way.trimDB) { v in
                    model.editWay(way.id, speaker: speaker.id) { $0.trimDB = v }
                }
                numberField("Delay ms", value: way.delayMilliseconds) { v in
                    model.editWay(way.id, speaker: speaker.id) { $0.delayMilliseconds = v }
                }
                Toggle("Invert polarity", isOn: Binding(
                    get: { way.polarityInverted },
                    set: { v in model.editWay(way.id, speaker: speaker.id) { $0.polarityInverted = v } }))
                Spacer()
                Text("EQ sections: \(way.eq.count)").font(.caption).foregroundStyle(.secondary)
                Button("Add EQ") {
                    model.addEQ(RoutingEQSection(type: 0, frequencyHz: 1_000, gainDB: 0, q: 1),
                                way: way.id, speaker: speaker.id)
                }
                .disabled(way.eq.count >= Int(N60_PEQ_MAX_SECTIONS))
            }
            linearisationRow(way: way)
            ForEach(Array(way.eq.enumerated()), id: \.offset) { index, section in
                HStack(spacing: 12) {
                    Text("EQ \(index + 1)").font(.caption).frame(width: 40, alignment: .leading)
                    numberField("Hz", value: section.frequencyHz) { v in
                        model.editWay(way.id, speaker: speaker.id) { $0.eq[index].frequencyHz = v }
                    }
                    numberField("Gain dB", value: section.gainDB) { v in
                        model.editWay(way.id, speaker: speaker.id) { $0.eq[index].gainDB = v }
                    }
                    numberField("Q", value: section.q) { v in
                        model.editWay(way.id, speaker: speaker.id) { $0.eq[index].q = v }
                    }
                    Button("Remove") { model.removeEQ(at: index, way: way.id, speaker: speaker.id) }
                }
            }
        }
    }

    /// E8 B3: apply, remove and A/B for the way's driver linearisation.
    private func linearisationRow(way: RoutedWay) -> some View {
        let state = model.linearisationState(way.id)
        return HStack(spacing: 12) {
            Text("Driver linearisation").font(.caption)
            Text(state == .active ? "On" : state == .bypassed ? "Bypassed (A)" : "Off")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if state != .none {
                Picker("A/B", selection: Binding(
                    get: { state == .bypassed },
                    set: { model.setLinearisationBypassed($0, way: way.id) })) {
                    Text("A: off").tag(true)
                    Text("B: on").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 150)
                Button("Remove") { model.removeLinearisation(way: way.id) }
            }
            Button(state == .none ? "Apply from Lab" : "Re-apply from Lab") {
                let store = SpeakerMeasurementLabSessionStore()
                do {
                    let sessions = try store.listRecentSessions(limit: 25)
                    let result = try model.applyLabCapture(wayID: way.id, sessions: sessions)
                    interchangeNotes = result.warnings
                    actionError = nil
                } catch {
                    actionError = error.localizedDescription
                }
            }
        }
    }

    private func filterEditor(
        _ title: String, spec: CrossoverCore.FilterSpec?, edge: SpeakerRoutingEditorModel.Edge,
        speaker: RoutedSpeaker, way: RoutedWay
    ) -> some View {
        let fallback = CrossoverCore.FilterSpec(family: .linkwitzRiley, order: 4, cornerHz: 1_000)
        return HStack(spacing: 8) {
            Toggle(title, isOn: Binding(
                get: { spec != nil },
                set: { on in model.setFilter(on ? fallback : nil, edge: edge, way: way.id, speaker: speaker.id) }))
            if let spec {
                Picker("Family", selection: Binding(
                    get: { spec.family },
                    set: { f in var s = spec; s.family = f
                        model.setFilter(s, edge: edge, way: way.id, speaker: speaker.id) })) {
                    Text("Butterworth").tag(CrossoverCore.Family.butterworth)
                    Text("Bessel").tag(CrossoverCore.Family.bessel)
                    Text("Linkwitz-Riley").tag(CrossoverCore.Family.linkwitzRiley)
                }
                .labelsHidden().frame(width: 130)
                Picker("Slope", selection: Binding(
                    get: { spec.order },
                    set: { o in var s = spec; s.order = o
                        model.setFilter(s, edge: edge, way: way.id, speaker: speaker.id) })) {
                    ForEach(spec.family.orders, id: \.self) { Text("\($0 * 6) dB/oct").tag($0) }
                }
                .labelsHidden().frame(width: 100)
                numberField("Hz", value: spec.cornerHz) { v in
                    var s = spec; s.cornerHz = v
                    model.setFilter(s, edge: edge, way: way.id, speaker: speaker.id)
                }
            }
        }
    }

    private func numberField(_ title: String, value: Double, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value }, set: set), format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder).frame(width: 72)
        }
    }

    private var matrixCard: some View {
        GroupBox("Matrix") {
            let outputs = model.configuration.outputEndpoints
            if outputs.isEmpty {
                Text("No outputs yet.").foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 6) {
                        GridRow {
                            Text("")
                            ForEach(Array(outputs.enumerated()), id: \.offset) { _, output in
                                Text("Out \(output.channelIndex + 1)").font(.caption)
                            }
                        }
                        ForEach(Array(model.matrixCells.enumerated()), id: \.offset) { _, row in
                            GridRow {
                                Text(row.first.map { SpeakerRoutingEditorModel.sourceName($0.source) } ?? "")
                                    .font(.caption).frame(width: 110, alignment: .leading)
                                ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                    matrixCell(cell)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                Text("A dot is a feed from a speaker's way. Type a gain in dB to add a raw feed; clear it to remove.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func matrixCell(_ cell: SpeakerRoutingEditorModel.MatrixCell) -> some View {
        HStack(spacing: 4) {
            if cell.fedByWay { Image(systemName: "circle.fill").font(.caption2) }
            TextField("", text: Binding(
                get: { cell.rawGain.map { String(format: "%.1f", 20 * log10(max(1e-6, abs($0)))) } ?? "" },
                set: { text in
                    if let db = Double(text) {
                        model.setMatrixGain(source: cell.source, output: cell.output, gain: pow(10, db / 20))
                    } else if text.isEmpty {
                        model.removeMatrixEntry(source: cell.source, output: cell.output)
                    }
                }))
                .textFieldStyle(.roundedBorder).frame(width: 56)
        }
    }

    private var pipelineCard: some View {
        let rows = SpeakerRoutingPipeline.rows(model.configuration, context: model.context)
        return DisclosureGroup("Pipeline") {
            VStack(alignment: .leading, spacing: 10) {
                if rows.isEmpty { Text("Nothing is routed yet.").foregroundStyle(.secondary) }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(row.title) (output \(row.output.channelIndex + 1))").font(.headline)
                        ForEach(Array(row.steps.enumerated()), id: \.offset) { _, step in
                            HStack(alignment: .firstTextBaseline) {
                                Text(step.title).frame(width: 90, alignment: .leading)
                                Text(step.detail).foregroundStyle(.secondary)
                                Spacer()
                                if step.latencyFrames > 0 {
                                    Text(String(format: "%.2f ms", step.latencyFrames / model.context.sampleRate * 1000))
                                        .monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            .font(.callout)
                        }
                        Text(String(format: "Total latency %.2f ms", row.totalLatencyMilliseconds(sampleRate: model.context.sampleRate)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
        }
    }

    private var camillaCard: some View {
        GroupBox("CamillaDSP") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Import YAML…") { importCamilla() }
                    Button("Export YAML…") { exportCamilla() }
                        .disabled(model.configuration.speakers.isEmpty && model.configuration.matrix.isEmpty)
                }
                ForEach(Array(interchangeNotes.enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func importCamilla() {
        let panel = NSOpenPanel()
        panel.title = "Import CamillaDSP YAML"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedFileTypes = ["yml", "yaml"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let uid = engine.selectedOutputDevice?.uid ?? ""
            let imported = try CamillaDSPRouting.importRouting(text, context: model.context, deviceUID: uid)
            interchangeNotes = imported.warnings
            if let routing = imported.routing {
                var next = routing
                next.enabled = model.configuration.enabled
                model.replace(next)
            } else {
                interchangeNotes.append("The file has no routing to import.")
            }
            if !imported.programEQ.isEmpty {
                interchangeNotes.append("Program EQ in the file was not applied; import it from the Equalizer tab.")
            }
        } catch {
            interchangeNotes = ["Import failed: \(error.localizedDescription)"]
        }
    }

    private func exportCamilla() {
        let exported = CamillaDSPRouting.exportRouting(
            model.configuration, context: model.context, playbackDeviceName: engine.selectedOutputDevice?.name)
        let panel = NSSavePanel()
        panel.title = "Export CamillaDSP YAML"
        panel.nameFieldStringValue = "NotchSixty-routing.yml"
        panel.allowedFileTypes = ["yml", "yaml"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            try Data(exported.yaml.utf8).write(to: url, options: .atomic)
            interchangeNotes = exported.warnings
        } catch {
            interchangeNotes = ["Export failed: \(error.localizedDescription)"]
        }
    }

    private var messagesCard: some View {
        GroupBox("Checks") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(model.messages.enumerated()), id: \.offset) { _, line in
                    Label(line, systemImage: "exclamationmark.circle").font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Per-way curves (thin) and the summed response (bold) of one speaker, 20 Hz to 20 kHz, 24 dB span.
private struct RoutingResponsePlot: View {
    @ObservedObject var model: SpeakerRoutingEditorModel
    let speaker: RoutedSpeaker

    var body: some View {
        let freqs = model.plotFrequencies()
        let ways = speaker.ways.map { way in freqs.map { model.wayMagnitudeDB(way, atHz: $0) ?? -60 } }
        let sum = freqs.map { model.summedMagnitudeDB(speaker, atHz: $0) ?? -60 }
        Canvas { context, size in
            func path(_ values: [Double]) -> Path {
                var p = Path()
                for (i, v) in values.enumerated() {
                    let x = size.width * CGFloat(i) / CGFloat(max(1, values.count - 1))
                    let y = size.height * CGFloat((12 - min(12, max(-36, v))) / 48)
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
                return p
            }
            var zero = Path()
            let y0 = size.height * 12 / 48
            zero.move(to: CGPoint(x: 0, y: y0)); zero.addLine(to: CGPoint(x: size.width, y: y0))
            context.stroke(zero, with: .color(.secondary.opacity(0.4)), lineWidth: 0.5)
            for values in ways { context.stroke(path(values), with: .color(.secondary), lineWidth: 1) }
            context.stroke(path(sum), with: .color(.accentColor), lineWidth: 2)
        }
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel("Crossover response for \(speaker.name)")
    }
}
