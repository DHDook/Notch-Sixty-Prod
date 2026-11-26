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
    /// E12 S28b2: the test is being prepared (both sides built and measured) before the first trial.
    @Published private(set) var isPreparing = false
    /// Q1: the user confirms, once per test, that the mains can take full-range bass for "Everything off".
    @Published var confirmFullRangeBass = false
    private var preparation: Task<Void, Never>?
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
        let current = player.currentContentState()
        var list = ComparisonCandidates.list(current: current, presets: profiles.contentPresets)
        if let system = player as? SystemAuditionPlaying {
            let context = system.systemContext
            list.insert(ComparisonCandidates.everythingOff(current: current, context: context, bassOff: bassMayGoOff(context)), at: 2)
            list += ComparisonCandidates.systemProfiles(profiles.systemProfiles, current: current, context: context)
        }
        candidates = list
    }

    private func bassMayGoOff(_ context: SystemAuditionContext?) -> Bool {
        guard let context else { return false }
        return context.subwoofers == 0 || confirmFullRangeBass
    }

    /// True when "Everything off" is chosen, a subwoofer is configured and bass management is on: the question of Q1.
    var needsFullRangeBassConfirmation: Bool {
        guard candidates.contains(where: { $0.kind == .everythingOff && ($0.id == sideAID || $0.id == sideBID) }),
              let context = (player as? SystemAuditionPlaying)?.systemContext else { return false }
        return context.subwoofers > 0 && context.running.bassManagement.enabled
    }

    /// The picker label for a side: a greyed one says why.
    func label(_ candidate: ComparisonCandidate) -> String {
        candidate.unavailableReason.map { "\(candidate.name) (\($0))" } ?? candidate.name
    }

    func prefillFromRemote() {
        sideAID = "current"
        sideBID = "off"
    }

    var guidance: String { BlindComparisonStatistics.guidance(kind: mode.kind, trials: trialCount) }

    var canStart: Bool { service == nil && !isPreparing && sideAID != sideBID }

    /// Content-only pairs start at once. A pair with a system side builds and measures both graphs first (off the main
    /// actor), so `start` returns before the test is ready; `awaitPreparation` waits for it.
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
        if a.isSystemSide || b.isSystemSide {
            guard let system = player as? SystemAuditionPlaying else {
                error = "Comparing system settings is not available here."
                return
            }
            isPreparing = true
            error = nil
            preparation = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let made = try await BlindLiveComparison.makeSystemService(
                        player: system, a: a, b: b, kind: self.mode.kind, trialCount: self.trialCount, switchHold: self.switchHold)
                    self.adopt(made, a: a, b: b)
                } catch {
                    self.error = error.localizedDescription
                }
                self.isPreparing = false
            }
            return
        }
        do {
            adopt(try BlindLiveComparison.makeService(player: player, a: a, b: b, kind: mode.kind, trialCount: trialCount, switchHold: switchHold), a: a, b: b)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func awaitPreparation() async { await preparation?.value }

    private func adopt(_ made: BlindComparisonService, a: ComparisonCandidate, b: ComparisonCandidate) {
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
        preparation?.cancel()
        service?.close()
        service = nil
        forwarding = nil
        confirmFullRangeBass = false
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
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("Play your own music through the app, then try to tell two settings apart, or say which you prefer. Level is matched first: the louder side is turned down, never the quieter one turned up. Sides can be content settings (equaliser, preamp, dynamics), a saved system profile, or everything off. \"Everything off\" never turns off output protection, speaker-driver processing, a bi-amp or tri-amp splitter, routing or master volume. Output protection stays on for every side.")
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
                Label(error, systemImage: "exclamationmark.triangle").font(DesignType.caption.font).foregroundStyle(StatusLevel.attention.color)
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
        VStack(alignment: .leading, spacing: DesignSpacing.l.pt) {
            Text("1. Choose what to compare").font(DesignType.sectionTitle.font)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.l.pt) { pickers }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) { pickers }
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
            Text(model.guidance).font(DesignType.caption.font).foregroundStyle(.secondary)
            if model.needsFullRangeBassConfirmation {
                Toggle("My main speakers can take full-range bass (room correction and bass management go off, so the bass reaches them whole)", isOn: $model.confirmFullRangeBass)
                    .onChange(of: model.confirmFullRangeBass) { _, _ in model.reload() }
                if !model.confirmFullRangeBass {
                    Text("Without this, \"Everything off\" keeps bass management on and turns off everything else.")
                        .font(DesignType.caption.font).foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Start blind test") { model.start() }
                    .buttonStyle(.glassProminent)
                    .disabled(!model.canStart)
                if model.isPreparing { ProgressView().controlSize(.small); Text("Preparing both sides…").font(DesignType.caption.font) }
            }
            Text("Playback must be running. The test never starts playback, and it puts your settings back when it ends.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
        }
        .padding(DesignSpacing.xl.pt)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    @ViewBuilder private var pickers: some View {
        Picker("A", selection: $model.sideAID) {
            ForEach(model.candidates) { Text(model.label($0)).tag($0.id).selectionDisabled($0.unavailableReason != nil) }
        }
        .frame(maxWidth: 320)
        Picker("B", selection: $model.sideBID) {
            ForEach(model.candidates) { Text(model.label($0)).tag($0.id).selectionDisabled($0.unavailableReason != nil) }
        }
        .frame(maxWidth: 320)
    }
}

struct BlindLiveRunView: View {
    @ObservedObject var service: BlindComparisonService
    let kind: BlindComparisonService.Kind
    var record: BlindTestRecord?
    var onExport: () -> Void = {}
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text(service.match.summary).font(DesignType.caption.font).foregroundStyle(.secondary)
            switch service.phase {
            case .trials: trials
            case .askingPreference, .finished: results
            case .ended(let reason):
                Label("\(reason) Your settings are back.", systemImage: "info.circle")
                Button("Close", action: onClose)
            }
            if let message = service.message { Text(message).font(DesignType.caption.font).foregroundStyle(StatusLevel.attention.color) }
        }
        .padding(DesignSpacing.xl.pt)
        .background(.regularMaterial, in: .rect(cornerRadius: DesignRadius.large.pt))
    }

    private var trials: some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("Trial \(service.currentTrialNumber) of \(service.totalTrials)").font(DesignType.sectionTitle.font)
            ViewThatFits(in: .horizontal) {
                HStack { listenButtons }
                VStack(alignment: .leading) { listenButtons }
            }
            Text(kind == .abx
                 ? "Play A, B and X as often as you like, but hear X at least once before you answer. Keys: A, B, X, then 1 for \"X is A\" or 2 for \"X is B\"."
                 : "Play A and B as often as you like, but hear both before you answer. Which side is which candidate changes every trial. Keys: A, B, then 1 or 2 for the one you prefer.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
            ViewThatFits(in: .horizontal) {
                HStack { answerButtons }
                VStack(alignment: .leading) { answerButtons }
            }
            Button("Stop and restore my settings", action: onClose).buttonStyle(.glass)
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
            .buttonStyle(.glassProminent)
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
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Text("All \(service.totalTrials) trials are in.").font(DesignType.sectionTitle.font)
            if let result = service.abxResult {
                Text("\(result.correct) of \(result.trials) correct (p = \(String(format: "%.4f", result.pValue)))")
                    .font(DesignType.sectionTitle.font.monospacedDigit())
                Text(result.pValue < BlindComparisonStatistics.alpha
                     ? "That is more than guessing would give. You can hear a difference between these two."
                     : "That is within what guessing gives. This run does not show you can hear a difference; it does not prove there is none.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            if let result = service.preferenceResult {
                Text("Preferred A \(result.preferredA) times, B \(result.preferredB) times (p = \(String(format: "%.4f", result.pValue)))")
                    .font(DesignType.sectionTitle.font.monospacedDigit())
                Text(result.pValue < BlindComparisonStatistics.alpha
                     ? "That split is unlikely to be chance."
                     : "That split could be chance; no clear preference.")
                    .font(DesignType.caption.font).foregroundStyle(.secondary)
            }
            if service.phase == .askingPreference {
                Button("Show which was which") { service.finish() }.buttonStyle(.glassProminent)
            }
            if let names = service.revealedNames {
                Text("A was \(names.a). B was \(names.b).")
            }
            Text("Running the test again until it passes does not count; judge each run on its own. The result is kept in the list of finished tests.")
                .font(DesignType.caption.font).foregroundStyle(.secondary)
            HStack {
                if record != nil { Button("Save a copy of the result…", action: onExport).buttonStyle(.glass) }
                Button("Close and restore my settings", action: onClose).buttonStyle(.glass)
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
