import Combine
import SwiftUI
import UniformTypeIdentifiers

// E12 S27 (behind `e12.blind-listening`): "Test what Notch Sixty does". Pick two sides, pick a test, listen to your own
// music on the selected output. Control plane only; every switch goes through `BlindComparisonService`.

@MainActor
final class BlindLiveModel: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case abx = "Can I hear a difference?"
        case preference = "Which do I prefer?"
        var id: String { rawValue }
        var kind: BlindComparisonService.Kind { self == .abx ? .abx : .preference }
    }

    private let profiles: ProductProfileController
    private let player: ContentAuditionPlaying
    private let history: BlindTestHistoryStore
    private var forwarding: AnyCancellable?
    private var names: (a: String, b: String) = ("", "")
    private var recorded = false

    @Published private(set) var candidates: [ComparisonCandidate] = []
    @Published var sideAID = "current"
    @Published var sideBID = "off"
    @Published var mode = Mode.abx
    @Published var trialCount = 16
    @Published private(set) var service: BlindComparisonService?
    @Published private(set) var error: String?
    /// The record of the test that just finished; nil until the trials are in.
    @Published private(set) var finishedRecord: BlindTestRecord?
    /// The fixed switch time; tests shorten it.
    var switchHold = ComparisonSwitchTiming.fixedSeconds

    init(profiles: ProductProfileController, history: BlindTestHistoryStore, player: ContentAuditionPlaying? = nil) {
        self.profiles = profiles
        self.history = history
        self.player = player ?? ProfileContentAuditionPlayer(profiles: profiles)
        reload()
    }

    func reload() {
        candidates = ComparisonCandidates.list(current: player.currentContentState(), presets: profiles.contentPresets)
    }

    func prefillFromRemote() {
        sideAID = "current"
        sideBID = "off"
    }

    var guidance: String { BlindComparisonStatistics.guidance(kind: mode.kind, trials: trialCount) }

    var canStart: Bool { service == nil && sideAID != sideBID }

    func start() {
        reload()
        guard let a = candidates.first(where: { $0.id == sideAID }), let b = candidates.first(where: { $0.id == sideBID }) else {
            error = "Choose two sides first."
            return
        }
        if let reason = player.unavailableReason {
            error = reason
            return
        }
        do {
            let made = try BlindLiveComparison.makeService(player: player, a: a, b: b, kind: mode.kind, trialCount: trialCount, switchHold: switchHold)
            names = (a.name, b.name)
            recorded = false
            finishedRecord = nil
            forwarding = made.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
                // The published change fires before the new value lands, so read it on the next turn.
                Task { @MainActor [weak self] in self?.recordIfFinished() }
            }
            service = made
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Keeps the result in History once, as soon as the trials are in (can-I-hear-it: at the reveal question).
    func recordIfFinished() {
        guard !recorded, let service else { return }
        let record: BlindTestRecord?
        if let result = service.preferenceResult {
            record = BlindTestRecords.preference(sideA: names.a, sideB: names.b, result: result)
        } else if service.abxResult != nil {
            record = BlindTestRecords.abx(sideA: names.a, sideB: names.b, session: service.session)
        } else {
            record = nil
        }
        guard let record else { return }
        recorded = true
        finishedRecord = record
        history.append(record)
    }

    /// Ends the test and puts the applied settings back.
    func stop() {
        service?.close()
        service = nil
        forwarding = nil
    }
}

struct ProductionBlindLiveView: View {
    @StateObject private var model: BlindLiveModel
    @ObservedObject private var request = BlindListeningRequest.shared
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    @State private var exportDocument: BlindTestExportFile?
    @State private var exporting = false

    init(profiles: ProductProfileController, history: BlindTestHistoryStore) {
        _model = StateObject(wrappedValue: BlindLiveModel(profiles: profiles, history: history))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Play your own music through the app, then try to tell two settings apart, or say which you prefer. Level is matched first: the louder side is turned down, never the quieter one turned up. The equaliser, preamp and dynamics are what change between sides; room correction, bass management and output protection stay on for both.")
                .foregroundStyle(.secondary)
            if let service = model.service {
                BlindLiveRunView(service: service, kind: model.mode.kind, record: model.finishedRecord, onExport: {
                    guard let record = model.finishedRecord, let data = try? BlindTestRecords.exportData(record) else { return }
                    exportDocument = BlindTestExportFile(data: data)
                    exporting = true
                }) { model.stop() }
            } else {
                setup
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        }
        .onReceive(tick) { _ in model.service?.refreshReadiness() }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: "notch-sixty-blind-test") { _ in }
        .onAppear { consumeRequest() }
        .onChange(of: request.pending) { _, _ in consumeRequest() }
        .onDisappear { model.stop() }
    }

    private func consumeRequest() {
        guard request.pending else { return }
        model.reload()
        model.prefillFromRemote()
        request.take()
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("1. Choose what to compare").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { pickers }
                VStack(alignment: .leading, spacing: 8) { pickers }
            }
            Picker("Test", selection: $model.mode) {
                ForEach(BlindLiveModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
            Picker("Trials", selection: $model.trialCount) {
                Text("12 trials").tag(12)
                Text("16 trials").tag(16)
                Text("24 trials").tag(24)
            }
            .frame(maxWidth: 230)
            Text(model.guidance).font(.caption).foregroundStyle(.secondary)
            Button("Start blind test") { model.start() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
            Text("Playback must be running. The test never starts playback, and it puts your settings back when it ends.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    @ViewBuilder private var pickers: some View {
        Picker("A", selection: $model.sideAID) {
            ForEach(model.candidates) { Text($0.name).tag($0.id) }
        }
        .frame(maxWidth: 280)
        Picker("B", selection: $model.sideBID) {
            ForEach(model.candidates) { Text($0.name).tag($0.id) }
        }
        .frame(maxWidth: 280)
    }
}

struct BlindLiveRunView: View {
    @ObservedObject var service: BlindComparisonService
    let kind: BlindComparisonService.Kind
    var record: BlindTestRecord?
    var onExport: () -> Void = {}
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(service.match.summary).font(.caption).foregroundStyle(.secondary)
            switch service.phase {
            case .trials: trials
            case .askingPreference, .finished: results
            case .ended(let reason):
                Label("\(reason) Your settings are back.", systemImage: "info.circle")
                Button("Close", action: onClose)
            }
            if let message = service.message { Text(message).font(.caption).foregroundStyle(.orange) }
        }
        .padding(20)
        .background(.regularMaterial, in: .rect(cornerRadius: 18))
    }

    private var trials: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Trial \(service.currentTrialNumber) of \(service.totalTrials)").font(.headline)
            ViewThatFits(in: .horizontal) {
                HStack { listenButtons }
                VStack(alignment: .leading) { listenButtons }
            }
            Text(kind == .abx
                 ? "Play A, B and X as often as you like, but hear X at least once before you answer. Keys: A, B, X, then 1 for \"X is A\" or 2 for \"X is B\"."
                 : "Play A and B as often as you like, but hear both before you answer. Which side is which candidate changes every trial. Keys: A, B, then 1 or 2 for the one you prefer.")
                .font(.caption).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { answerButtons }
                VStack(alignment: .leading) { answerButtons }
            }
            Button("Stop and restore my settings", action: onClose).buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var listenButtons: some View {
        selectButton("A", .a, key: "a")
        selectButton("B", .b, key: "b")
        if kind == .abx { selectButton("X", .x, key: "x") }
        if service.isSwitching { ProgressView().controlSize(.small) }
    }

    private func selectButton(_ title: String, _ choice: BlindComparisonService.Selection, key: KeyEquivalent) -> some View {
        Button(title) { service.select(choice) }
            .buttonStyle(.borderedProminent)
            .tint(service.selection == choice ? .accentColor : .gray)
            .keyboardShortcut(key, modifiers: [])
            .disabled(!service.canSwitch)
    }

    @ViewBuilder private var answerButtons: some View {
        Button(kind == .abx ? "X is A" : "Prefer A") { service.answer(xIsB: false) }
            .keyboardShortcut("1", modifiers: [])
            .disabled(!service.canAnswer)
        Button(kind == .abx ? "X is B" : "Prefer B") { service.answer(xIsB: true) }
            .keyboardShortcut("2", modifiers: [])
            .disabled(!service.canAnswer)
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All \(service.totalTrials) trials are in.").font(.headline)
            if let result = service.abxResult {
                Text("\(result.correct) of \(result.trials) correct (p = \(String(format: "%.4f", result.pValue)))")
                    .font(.headline.monospacedDigit())
                Text(result.pValue < BlindComparisonStatistics.alpha
                     ? "That is more than guessing would give. You can hear a difference between these two."
                     : "That is within what guessing gives. This run does not show you can hear a difference; it does not prove there is none.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let result = service.preferenceResult {
                Text("Preferred A \(result.preferredA) times, B \(result.preferredB) times (p = \(String(format: "%.4f", result.pValue)))")
                    .font(.headline.monospacedDigit())
                Text(result.pValue < BlindComparisonStatistics.alpha
                     ? "That split is unlikely to be chance."
                     : "That split could be chance; no clear preference.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if service.phase == .askingPreference {
                Button("Show which was which") { service.finish() }.buttonStyle(.borderedProminent)
            }
            if let names = service.revealedNames {
                Text("A was \(names.a). B was \(names.b).")
            }
            Text("Running the test again until it passes does not count; judge each run on its own. The result is kept in the list of finished tests.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if record != nil { Button("Save a copy of the result…", action: onExport).buttonStyle(.bordered) }
                Button("Close and restore my settings", action: onClose).buttonStyle(.bordered)
            }
        }
    }
}

/// A finished test saved as a JSON copy.
struct BlindTestExportFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
