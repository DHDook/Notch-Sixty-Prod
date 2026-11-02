import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// E11 S5: Library tab. Saves captures, groups and annotates them, overlays up to eight curves,
/// and shows the difference of each overlay against one reference (A/B).
@MainActor
final class MeasurementLibraryModel: ObservableObject {
    @Published private(set) var records: [MeasurementRecord] = []
    @Published private(set) var loadErrors: [String] = []
    @Published var overlays = MeasurementOverlaySet()
    @Published var smoothing: MeasurementSmoothing = .octave3
    @Published var message: String?

    let library: MeasurementLibrary

    init(library: MeasurementLibrary = MeasurementLibrary(root: MeasurementLibrary.defaultRoot())) {
        self.library = library
    }

    func reload() {
        do {
            let contents = try library.load()
            records = contents.records
            loadErrors = contents.errors
        } catch {
            records = []
            loadErrors = [error.localizedDescription]
        }
    }

    func save(capture: SpeakerMeasurementLabCapture, name: String, group: String) {
        let record = MeasurementRecord(
            name: name, group: group, createdAt: capture.capturedAt, sampleRate: capture.sampleRate,
            channel: capture.source.displayName, microphone: capture.microphone.deviceUID,
            quality: capture.quality, response: capture.transferFunction)
        perform { _ = try library.save(record, impulseResponse: capture.impulseResponse) }
    }

    /// Saves an Analysis source with its raw capture and sweep settings, so distortion works on the record later.
    func save(source: MeasurementAnalysisSource, name: String, group: String) {
        var record = MeasurementRecord(
            name: name, group: group, createdAt: Date(), sampleRate: source.sampleRate, channel: source.title)
        record.sweep = source.sweep
        record.quality.directArrivalSeconds = source.arrivalSeconds
        perform {
            _ = try library.save(
                record, impulseResponse: source.impulseResponse,
                rawCapture: source.rawCapture.isEmpty ? nil : source.rawCapture)
        }
    }

    func rename(_ id: UUID, to name: String) { perform { try library.updateMetadata(id: id) { $0.name = name } } }
    func setNotes(_ id: UUID, _ notes: String) { perform { try library.updateMetadata(id: id) { $0.notes = notes } } }
    func setGroup(_ id: UUID, _ group: String) { perform { try library.updateMetadata(id: id) { $0.group = group } } }

    func delete(_ id: UUID) {
        overlays.remove(id)
        perform { try library.delete(id: id) }
    }

    func toggleOverlay(_ id: UUID) {
        if overlays.overlayIDs.contains(id) { overlays.remove(id) } else {
            do { try overlays.add(id) } catch { message = error.localizedDescription }
        }
    }

    func differenceCurves() -> [(id: UUID, curve: RoomCorrectionFrequencyResponse)] {
        guard let referenceID = overlays.referenceID,
              let reference = records.first(where: { $0.id == referenceID })?.response else { return [] }
        return overlays.overlayIDs.compactMap { id in
            guard id != referenceID, let response = records.first(where: { $0.id == id })?.response else { return nil }
            return (id, MeasurementComparison.difference(response, reference: reference, smoothing: smoothing))
        }
    }

    func useInRoomCorrection(
        left: UUID, right: UUID, projects: RoomCorrectionProjectController
    ) {
        perform {
            guard let l = records.first(where: { $0.id == left }), let r = records.first(where: { $0.id == right }) else {
                throw MeasurementLibraryError.notFound(left)
            }
            let analysis = try library.roomCorrectionAnalysis(left: l, right: r)
            try projects.retainMeasurement(
                analysis, sweep: l.sweep ?? RoomCorrectionSweepSettings(sampleRate: l.sampleRate),
                microphone: RoomCorrectionMicrophone(stableID: l.microphone, displayName: l.microphone ?? "Library measurement"),
                name: l.seat ?? l.name)
            message = "Copied \(l.name) and \(r.name) into the Room Correction project."
        }
    }

    /// E11 S6: imports REW text, FRD, ZMA or WAV impulse responses chosen by the user.
    func importFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.plainText, .wav, UTType(filenameExtension: "frd"), UTType(filenameExtension: "zma")].compactMap { $0 }
        guard panel.runModal() == .OK else { return }
        perform {
            var notes: [String] = []
            for url in panel.urls {
                let data = try Data(contentsOf: url)
                let name = url.deletingPathExtension().lastPathComponent
                switch url.pathExtension.lowercased() {
                case "wav": _ = try library.importImpulseWAV(data, name: name)
                case "frd", "zma":
                    let result = try library.importCurve(data, format: url.pathExtension.lowercased() == "zma" ? .zma : .frd, name: name)
                    notes += result.issues.map { "\(name) \($0.description)" }
                default:
                    let result = try library.importCurve(data, format: .rew, name: name)
                    notes += result.issues.map { "\(name) \($0.description)" }
                }
            }
            message = notes.isEmpty ? "Imported \(panel.urls.count) file(s)." : notes.prefix(5).joined(separator: "\n")
        }
    }

    func export(_ id: UUID, kind: String) {
        let panel = NSSavePanel()
        let base = records.first(where: { $0.id == id })?.name ?? "measurement"
        let data: () throws -> Data
        switch kind {
        case "frd": panel.nameFieldStringValue = base + ".frd"; data = { try self.library.exportCurve(id: id, format: .frd) }
        case "zma": panel.nameFieldStringValue = base + ".zma"; data = { try self.library.exportCurve(id: id, format: .zma) }
        case "wav": panel.nameFieldStringValue = base + ".wav"; data = { try self.library.exportImpulseWAV(id: id) }
        case "raw": panel.nameFieldStringValue = base + "-raw.wav"; data = { try self.library.exportRawWAV(id: id) }
        default: panel.nameFieldStringValue = base + ".txt"; data = { try self.library.exportCurve(id: id, format: .rew) }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try data().write(to: url, options: .atomic); message = "Exported \(url.lastPathComponent)." }
    }

    private func perform(_ work: () throws -> Void) {
        do { try work() }
        catch { message = error.localizedDescription }
        reload()
    }
}

enum MeasurementPlotLayout {
    /// Log-frequency x (20 Hz to 20 kHz) and dB y across `size`, auto-ranged to `rangeDB`.
    static func points(_ curve: RoomCorrectionFrequencyResponse, size: CGSize, minDB: Double, maxDB: Double) -> [CGPoint] {
        let lo = log10(20.0), hi = log10(20_000.0)
        return zip(curve.frequenciesHz, curve.magnitudeDB).compactMap { f, db in
            guard f >= 20, f <= 20_000, db.isFinite, maxDB > minDB else { return nil }
            let x = size.width * CGFloat((log10(f) - lo) / (hi - lo))
            let y = size.height * CGFloat(1 - (min(maxDB, max(minDB, db)) - minDB) / (maxDB - minDB))
            return CGPoint(x: x, y: y)
        }
    }
}

struct MeasurementLibraryView: View {
    @ObservedObject var model: MeasurementLibraryModel
    let latestCapture: SpeakerMeasurementLabCapture?
    var projects: RoomCorrectionProjectController?
    /// E11 S10: current EQ bands and output rate, for the "predicted with current EQ" overlay.
    var equalizerBands: [EQBand] = []
    var outputSampleRate: Double = 48_000
    @State private var showsPredicted = false

    @State private var newName = ""
    @State private var newGroup = ""
    @State private var leftID: UUID?
    @State private var rightID: UUID?

    private static let palette: [Color] = [.blue, .orange, .green, .pink, .purple, .teal, .yellow, .red]

    var body: some View {
        GroupBox("Measurement library") {
            VStack(alignment: .leading, spacing: 12) {
                saveRow
                Button("Import REW, FRD, ZMA or WAV...") { model.importFiles() }
                Toggle("Show predicted response with current EQ", isOn: $showsPredicted)
                plot(title: showsPredicted ? "Overlays (predicted with current EQ)" : "Overlays",
                     curves: showsPredicted ? predictedCurves : overlayCurves, minDB: -30, maxDB: 30, relative: true)
                if model.overlays.referenceID != nil {
                    Picker("Smoothing", selection: $model.smoothing) {
                        ForEach(MeasurementSmoothing.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    plot(title: "Difference from reference (dB)", curves: differenceCurves, minDB: -12, maxDB: 12, relative: false)
                }
                ForEach(model.records) { record in row(record) }
                if model.records.isEmpty { Text("No saved measurements yet.").foregroundStyle(.secondary) }
                if projects != nil { roomCorrectionRow }
                ForEach(model.loadErrors, id: \.self) { Text("Skipped: \($0)").font(.caption).foregroundStyle(.orange) }
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .onAppear { model.reload() }
    }

    private var saveRow: some View {
        HStack {
            TextField("Name", text: $newName).textFieldStyle(.roundedBorder)
            TextField("Group", text: $newGroup).textFieldStyle(.roundedBorder)
            Button("Save latest capture") {
                if let latestCapture {
                    model.save(capture: latestCapture, name: newName, group: newGroup)
                    newName = ""
                }
            }
            .disabled(latestCapture == nil || newName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var overlayCurves: [(id: UUID, curve: RoomCorrectionFrequencyResponse)] {
        model.overlays.overlayIDs.compactMap { id in
            model.records.first(where: { $0.id == id })?.response.map { (id, $0) }
        }
    }

    private var predictedCurves: [(id: UUID, curve: RoomCorrectionFrequencyResponse)] {
        let program = ProductionEQResponseMath.compile(bands: equalizerBands, sampleRate: outputSampleRate)
        return overlayCurves.map {
            ($0.id, MeasurementOverlays.predicted(measurement: $0.curve, program: program, sampleRate: outputSampleRate))
        }
    }

    private var differenceCurves: [(id: UUID, curve: RoomCorrectionFrequencyResponse)] { model.differenceCurves() }

    private func colour(_ id: UUID) -> Color {
        Self.palette[(model.overlays.overlayIDs.firstIndex(of: id) ?? 0) % Self.palette.count]
    }

    private func plot(title: String, curves: [(id: UUID, curve: RoomCorrectionFrequencyResponse)], minDB: Double, maxDB: Double, relative: Bool) -> some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            Canvas { context, size in
                var shift = 0.0
                for entry in curves {
                    if relative, let mid = entry.curve.magnitudeDB.sorted().dropFirst(entry.curve.magnitudeDB.count / 2).first {
                        shift = mid
                    }
                    let shifted = RoomCorrectionFrequencyResponse(
                        frequenciesHz: entry.curve.frequenciesHz, magnitudeDB: entry.curve.magnitudeDB.map { $0 - shift }, phaseRadians: nil)
                    let pts = MeasurementPlotLayout.points(shifted, size: size, minDB: minDB, maxDB: maxDB)
                    guard let first = pts.first else { continue }
                    var path = Path()
                    path.move(to: first)
                    pts.dropFirst().forEach { path.addLine(to: $0) }
                    context.stroke(path, with: .color(colour(entry.id)), lineWidth: 1.5)
                }
            }
            .frame(height: 160)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("\(title), \(curves.count) curves")
        }
    }

    private func row(_ record: MeasurementRecord) -> some View {
        let isOverlay = model.overlays.overlayIDs.contains(record.id)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { isOverlay }, set: { _ in model.toggleOverlay(record.id) })) {
                    Text(record.name).bold()
                }
                .disabled(record.response == nil)
                if isOverlay { Circle().fill(colour(record.id)).frame(width: 10, height: 10) }
                Spacer()
                Text(record.group.isEmpty ? "Ungrouped" : record.group).font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f kHz", record.sampleRate / 1000)).font(.caption).foregroundStyle(.secondary)
                Button(model.overlays.referenceID == record.id ? "Clear reference" : "Use as reference") {
                    model.overlays.setReference(model.overlays.referenceID == record.id ? nil : record.id)
                    if model.overlays.referenceID == record.id { try? model.overlays.add(record.id) }
                }
                .disabled(record.response == nil)
                Menu("Export") {
                    Button("REW text") { model.export(record.id, kind: "rew") }.disabled(record.response == nil)
                    Button("FRD") { model.export(record.id, kind: "frd") }.disabled(record.response == nil)
                    Button("ZMA") { model.export(record.id, kind: "zma") }.disabled(record.response == nil)
                    Button("Impulse response WAV") { model.export(record.id, kind: "wav") }.disabled(!record.hasImpulseResponse)
                    Button("Raw capture WAV") { model.export(record.id, kind: "raw") }.disabled(!record.hasRawCapture)
                }
                Button("Delete", role: .destructive) { model.delete(record.id) }
            }
            TextField("Notes", text: Binding(get: { record.notes }, set: { model.setNotes(record.id, $0) }))
                .textFieldStyle(.roundedBorder).font(.caption)
        }
    }

    private var roomCorrectionRow: some View {
        HStack {
            Picker("Left", selection: $leftID) { Text("None").tag(UUID?.none); ForEach(model.records) { Text($0.name).tag(UUID?.some($0.id)) } }
            Picker("Right", selection: $rightID) { Text("None").tag(UUID?.none); ForEach(model.records) { Text($0.name).tag(UUID?.some($0.id)) } }
            Button("Use in Room Correction") {
                if let leftID, let rightID, let projects { model.useInRoomCorrection(left: leftID, right: rightID, projects: projects) }
            }
            .disabled(leftID == nil || rightID == nil || projects == nil)
        }
    }
}
