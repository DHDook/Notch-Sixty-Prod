import SwiftUI

/// E24 S4b (design note 9): the Measure Analysis tab. A source picker (latest Speaker Lab, Room
/// Correction or multichannel capture, or a library record) feeds H2-H5 distortion, decay per octave
/// and third-octave, and the gated response, waterfall and spectrogram. The library lives here too.
struct MeasurementAnalysisTab: View {
    let liveSources: [MeasurementAnalysisSource]
    let latestCapture: SpeakerMeasurementLabCapture?
    var projects: RoomCorrectionProjectController?
    var equalizerBands: [EQBand] = []
    var outputSampleRate: Double = 48_000

    @StateObject private var libraryModel = MeasurementLibraryModel()
    @State private var selection: String?
    @State private var librarySource: MeasurementAnalysisSource?
    @State private var libraryError: String?
    @State private var result: MeasurementAnalysisModel.Result?
    @State private var thirdOctave = true
    @State private var saveName = ""

    private var selectedSource: MeasurementAnalysisSource? {
        guard let selection else { return liveSources.first }
        if let live = liveSources.first(where: { $0.id == selection }) { return live }
        if let librarySource, librarySource.id == selection { return librarySource }
        return liveSources.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox("Source") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Analyse", selection: Binding(get: { selectedSource?.id ?? "" }, set: { select($0) })) {
                        if liveSources.isEmpty && libraryModel.records.isEmpty { Text("Nothing measured yet").tag("") }
                        ForEach(liveSources) { Text("Latest \($0.displayTitle)").tag($0.id) }
                        if !libraryModel.records.isEmpty {
                            Divider()
                            ForEach(libraryModel.records.filter(\.hasImpulseResponse)) {
                                Text("Library: \($0.name)").tag("library-\($0.id.uuidString)")
                            }
                        }
                    }
                    if let libraryError { Text(libraryError).font(.caption).foregroundStyle(.orange) }
                    if let source = selectedSource, source.kind != .library { saveRow(source) }
                    if selectedSource == nil {
                        Text("Measure a speaker, run Room Correction or open a saved measurement to analyse it here.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            distortionCard
            decayCard
            MeasurementAnalysisCard(source: selectedSource)
            MeasurementLibraryView(
                model: libraryModel, latestCapture: latestCapture, projects: projects,
                equalizerBands: equalizerBands, outputSampleRate: outputSampleRate)
        }
        .onAppear { libraryModel.reload() }
        .task(id: selectedSource?.id) {
            guard let source = selectedSource else { result = nil; return }
            result = nil
            let computed = await Task.detached(priority: .userInitiated) { MeasurementAnalysisModel.analyze(source) }.value
            if !Task.isCancelled { result = computed }
        }
    }

    private func select(_ id: String) {
        libraryError = nil
        selection = id
        guard id.hasPrefix("library-"), let uuid = UUID(uuidString: String(id.dropFirst("library-".count))),
              let record = libraryModel.records.first(where: { $0.id == uuid }) else { return }
        let library = libraryModel.library
        Task {
            do {
                let source = try await Task.detached { try MeasurementAnalysisSource.library(record, from: library) }.value
                if selection == id { librarySource = source }
            } catch {
                libraryError = error.localizedDescription
                selection = nil
            }
        }
    }

    private func saveRow(_ source: MeasurementAnalysisSource) -> some View {
        HStack {
            TextField("Name to save this capture under", text: $saveName).textFieldStyle(.roundedBorder)
            Button("Save to library") {
                libraryModel.save(source: source, name: saveName, group: "")
                saveName = ""
            }
            .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: Distortion

    private var distortionCard: some View {
        GroupBox("Harmonic distortion (H2 to H5)") {
            VStack(alignment: .leading, spacing: 8) {
                switch result?.distortion {
                case nil:
                    Text(selectedSource == nil ? "No source selected." : "Analysing...").foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                case .result(let distortion):
                    DistortionPlot(result: distortion)
                    if let thd = distortion.thdDB.filter({ $0 > MeasurementCore.DistortionResult.noDataDB }).sorted().last {
                        Text(String(format: "Worst total harmonic distortion %.1f dB re the fundamental.", thd))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !distortion.cleanSeparation {
                        Text(String(
                            format: "The sweep is too short to separate the harmonics from the room response; use a sweep of at least %.1f s.",
                            distortion.minSweepSeconds))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    // MARK: Decay

    private var decayCard: some View {
        GroupBox("Decay: EDT, T20, T30 and RT60") {
            VStack(alignment: .leading, spacing: 8) {
                switch result?.decay {
                case nil:
                    Text(selectedSource == nil ? "No source selected." : "Analysing...").foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).font(.callout).foregroundStyle(.secondary)
                case .result(let octave, let third):
                    Picker("Bands", selection: $thirdOctave) {
                        Text("Third-octave").tag(true)
                        Text("Octave").tag(false)
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 260)
                    Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 4) {
                        GridRow {
                            Text("Band").bold(); Text("EDT").bold(); Text("T20").bold(); Text("T30").bold(); Text("RT60").bold()
                            Text("Range").bold()
                        }
                        ForEach(thirdOctave ? third : octave, id: \.centreHz) { band in
                            GridRow {
                                Text(Self.bandName(band.centreHz))
                                Text(Self.seconds(band.edtSeconds)); Text(Self.seconds(band.t20Seconds))
                                Text(Self.seconds(band.t30Seconds)); Text(Self.seconds(band.rt60Seconds))
                                Text(String(format: "%.0f dB", band.decayRangeDB)).foregroundStyle(band.flags == 0 ? Color.secondary : Color.orange)
                            }
                            .font(.callout.monospacedDigit())
                        }
                    }
                    Text("A band in orange had too little decay range above the noise for a full T30; read it as indicative.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    static func bandName(_ hz: Double) -> String {
        hz >= 1000 ? String(format: "%.3g kHz", hz / 1000) : String(format: "%.0f Hz", hz)
    }

    static func seconds(_ value: Double) -> String { value > 0 ? String(format: "%.2f s", value) : "n/a" }
}

/// Fundamental and H2 to H5 in dB on a log frequency axis.
private struct DistortionPlot: View {
    let result: MeasurementCore.DistortionResult
    private static let colours: [Color] = [.orange, .green, .pink, .purple]

    var body: some View {
        let floorDB = -120.0, topDB = 0.0
        VStack(alignment: .leading, spacing: 4) {
            Canvas { context, size in
                func path(_ values: [Double]) -> Path {
                    var path = Path()
                    var open = false
                    for (index, f) in result.frequencyHz.enumerated() where f > 0 {
                        let raw = values[index]
                        guard raw > MeasurementCore.DistortionResult.noDataDB else { open = false; continue }
                        let db = raw
                        let x = size.width * log10(f / 20) / 3
                        let y = size.height * (topDB - min(max(db, floorDB), topDB)) / (topDB - floorDB)
                        if open { path.addLine(to: CGPoint(x: x, y: y)) } else { path.move(to: CGPoint(x: x, y: y)); open = true }
                    }
                    return path
                }
                for k in 0..<4 {
                    context.stroke(path(result.harmonicDB[k]), with: .color(Self.colours[k]), lineWidth: 1.5)
                }
                context.stroke(path(result.thdDB), with: .color(.primary.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityLabel("Harmonic distortion H2 to H5 in dB relative to the fundamental, 20 Hz to 20 kHz")
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { k in
                    Label("H\(k + 2)", systemImage: "circle.fill").foregroundStyle(Self.colours[k]).font(.caption)
                }
                Label("THD", systemImage: "circle.dashed").font(.caption)
                Spacer()
                Text("0 dB top, -120 dB bottom, relative to the fundamental").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
