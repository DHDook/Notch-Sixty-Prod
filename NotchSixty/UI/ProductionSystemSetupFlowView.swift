import SwiftUI

// E12 S3: the guided-setup window and its first steps (Output, Topology, Microphone and level,
// Room). Later steps arrive in S4 to S6. Reachable only with `e12.guided-setup` on.

/// Drives the reducer from the UI. Topology is written through the profile API when the user
/// leaves that step; Cancel restores the bass-management snapshot exactly.
@MainActor
final class SystemSetupFlowModel: ObservableObject {
    @Published private(set) var flow = SystemSetupFlow()
    @Published var topologyPreset = SystemSetupTopologyPreset(topology: .stereo)
    @Published private(set) var level = SystemSetupLevelPlan()
    @Published var message: String?
    @Published private(set) var alignment: SystemSetupAlignment?
    @Published private(set) var noiseIsPlaying = false
    @Published private(set) var isMeasuring = false

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let calibration: MultichannelCalibrationController
    private let noise: SystemSetupNoisePlaying

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController,
         calibration: MultichannelCalibrationController,
         noise: SystemSetupNoisePlaying? = nil) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.calibration = calibration
        self.noise = noise ?? EngineSystemSetupNoisePlayer(host: engine)
    }

    var choices: SystemSetupChoices { flow.choices }
    var step: SystemSetupStep { flow.step }
    var isRunning: Bool { flow.phase == .running }
    /// Steps built so far; later ones show a placeholder.
    static let builtSteps: Set<SystemSetupStep> = [.output, .topology, .microphone, .room, .measure, .alignment]

    func begin() {
        let snapshot = profiles.captureSystemState()
        var initial = SystemSetupChoices()
        initial.outputUID = engine.selectedOutputDevice?.uid
        initial.sampleRate = engine.selectedOutputDevice?.nominalSampleRate
        initial.microphoneUID = microphone.selectedInputUID
        initial.microphoneCalibrationFile = microphone.microphoneCalibration?.sourceName
        topologyPreset = SystemSetupTopologyPreset.current(from: snapshot)
        initial.topology = topologyPreset.topology
        do {
            try flow.start(snapshot: snapshot, choices: initial)
            message = nil
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseOutput(uid: String) {
        do {
            try engine.selectOutput(uid: uid)
            let device = engine.selectedOutputDevice
            flow.outputConfigurationChanged(outputUID: device?.uid, sampleRate: device?.nominalSampleRate)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func chooseTopology(_ topology: SystemSetupTopology) {
        topologyPreset.topology = topology
        flow.choices.topology = topology
    }

    func selectMicrophone(uid: String?) {
        microphone.selectInput(uid: uid)
        flow.choices.microphoneUID = microphone.selectedInputUID
        flow.choices.microphoneCalibrationFile = microphone.microphoneCalibration?.sourceName
    }

    /// Channels the noise can play on right now, in lane order.
    var noiseChannels: [(index: Int, name: String, isLFE: Bool)] { engine.generatorLaneChoices }

    /// Plays one channel at a time (or all channels) for the Level step. Switching channel stops the current noise,
    /// returns to that channel's starting level and starts it again if noise was playing.
    func selectNoiseTarget(lane: Int?) {
        let wasPlaying = noiseIsPlaying
        if wasPlaying { stopNoise(); if noiseIsPlaying { return } }
        level.recordLevel()
        if let lane, let channel = noiseChannels.first(where: { $0.index == lane }) {
            level.selectTarget(.lane(lane), isLFE: channel.isLFE)
        } else {
            level.selectTarget(.allProgram(includeLFE: false), isLFE: false)
        }
        if wasPlaying, !noiseIsPlaying { toggleNoise() }
    }

    func raiseLevel() { level.raise(); republishNoise() }
    func lowerLevel() { level.lower(); republishNoise() }

    /// Plays the Level step's noise through the E11 generator, or says why it cannot.
    func toggleNoise() {
        if noiseIsPlaying { stopNoise(); return }
        do {
            try noise.start(level.validatedGeneratorSettings(sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000), selection: level.target)
            noiseIsPlaying = noise.isPlaying
            message = nil
        } catch {
            noiseIsPlaying = false
            message = error.localizedDescription
        }
    }

    func stopNoise() {
        noise.stop()
        noiseIsPlaying = noise.isPlaying
        if noiseIsPlaying { message = "The noise could not be stopped. Stop playback from the main window." }
    }

    private func republishNoise() {
        guard noiseIsPlaying else { return }
        do { try noise.start(level.validatedGeneratorSettings(sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000), selection: level.target) } catch { stopNoise(); message = error.localizedDescription }
    }

    // MARK: Measure (design note 3)

    var measureProgress: SystemSetupMeasureProgress {
        SystemSetupMeasureProgress(
            seats: calibration.seats, sources: calibration.sources, measurements: calibration.measurements)
    }

    func prepareMeasure() {
        stopNoise()
        calibration.prepareForUse()
        syncMeasurementChoices()
    }

    func addSeat() {
        do { try calibration.addSeat(); syncMeasurementChoices() } catch { message = error.localizedDescription }
    }

    func removeSeat(_ id: UUID) {
        do { try calibration.removeSeat(id); invalidateDesign(); syncMeasurementChoices() }
        catch { message = error.localizedDescription }
    }

    /// Measures every missing seat and source in turn. Playback is stopped first (measurement needs
    /// the output to itself) and the reason is shown.
    func measureAll() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false; syncMeasurementChoices() }
        if engine.lifecycleState != .idle {
            engine.stop()
            message = "Playback was stopped so the speakers can be measured. Start it again when setup finishes."
        } else {
            message = nil
        }
        while measureProgress.next != nil {
            do {
                try calibration.beginNextMeasurement()
                while calibration.state == .measuring {
                    try? await Task.sleep(for: .milliseconds(100))
                    if try await calibration.finishMeasurementIfComplete() { break }
                    if Task.isCancelled { calibration.cancelMeasurement(); return }
                }
                syncMeasurementChoices()
            } catch {
                message = error.localizedDescription
                return
            }
        }
    }

    /// Re-measure one seat: its records are dropped and the next pass measures them again.
    func remeasure(seatID: UUID) {
        do {
            for source in calibration.sources { try calibration.remeasure(seatID: seatID, source: source) }
            invalidateDesign()
            syncMeasurementChoices()
        } catch { message = error.localizedDescription }
    }

    func cancelMeasurement() {
        calibration.cancelMeasurement()
        syncMeasurementChoices()
    }

    private func syncMeasurementChoices() {
        var choices = flow.choices
        measureProgress.apply(to: &choices)
        flow.choices = choices
    }

    /// New or removed measurements make the alignment stale: revert the trial and ask again.
    private func invalidateDesign() {
        if flow.choices.alignmentApplied { revertAlignment() }
        alignment = nil
    }

    // MARK: Alignment

    func computeAlignment() async {
        do {
            let design = try await calibration.designCalibration()
            alignment = SystemSetupAlignment.make(
                design: design, seats: calibration.seats, measurements: calibration.measurements)
            message = nil
        } catch {
            alignment = nil
            message = error.localizedDescription
        }
    }

    /// Trial apply: only trim, delay and polarity change; Cancel or Revert restores the snapshot.
    func applyAlignment() {
        guard let alignment, let profile = profiles.selectedSystemOutputDeviceProfile else {
            message = "Work out the alignment first."
            return
        }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(try alignment.applying(to: profile))
            flow.choices.alignmentApplied = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func revertAlignment() {
        guard let snapshot = flow.snapshot else { return }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            flow.choices.alignmentApplied = false
        } catch {
            message = "Restoring the previous alignment failed: \(error.localizedDescription)"
        }
    }

    func acceptSweepLevel(measuredSPLdBC: Double) {
        flow.choices.sweepLevelDBFS = level.sweepLevel(measuredSPLdBC: measuredSPLdBC)
    }

    func next() {
        do {
            if flow.step == .topology { try applyTopology() }
            try flow.next()
            message = nil
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    func back() { try? flow.back() }

    func skip() {
        do { try flow.skip() } catch let refusal as SystemSetupRefusal { message = refusal.reason } catch {}
    }

    func cancel() {
        stopNoise()
        calibration.cancelMeasurement()
        guard let snapshot = try? flow.cancel() else { return }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            try profiles.replaceSelectedSystemBassManagement(snapshot.bassManagement)
        } catch {
            message = "Restoring the previous settings failed: \(error.localizedDescription)"
        }
    }

    private func applyTopology() throws {
        guard let base = flow.snapshot else { return }
        let target = topologyPreset.applying(to: base).bassManagement
        try profiles.replaceSelectedSystemBassManagement(target)
    }
}

struct ProductionSystemSetupFlowView: View {
    @StateObject private var model: SystemSetupFlowModel
    @Environment(\.dismiss) private var dismiss

    init(engine: AudioIOEngine, profiles: ProductProfileController,
         microphone: RoomCorrectionCalibrationController, calibration: MultichannelCalibrationController,
         advisor: RoomTreatmentAdvisorController) {
        _model = StateObject(wrappedValue: SystemSetupFlowModel(
            engine: engine, profiles: profiles, microphone: microphone, calibration: calibration))
        self.advisor = advisor
    }

    private let advisor: RoomTreatmentAdvisorController
    private let visibleSteps: [SystemSetupStep] = SystemSetupStep.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepContent
                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(.orange)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(minWidth: 640, minHeight: 520)
        .onAppear { if !model.isRunning { model.begin() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up my system").font(.title3.weight(.semibold))
            ProgressView(value: Double(model.step.index + 1), total: Double(visibleSteps.count))
            Text("Step \(model.step.index + 1) of \(visibleSteps.count): \(Self.title(model.step))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { model.cancel(); dismiss() }
            Spacer()
            Button("Back") { model.back() }.disabled(model.step == .output)
            if model.flow.canSkip(model.step) {
                Button("Skip") { model.skip() }
            }
            Button("Next") { model.next() }
                .keyboardShortcut(.defaultAction)
                .disabled(!SystemSetupFlowModel.builtSteps.contains(model.step))
        }
        .padding(16)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch model.step {
        case .output: SystemSetupOutputStep(model: model)
        case .topology: SystemSetupTopologyStep(model: model)
        case .microphone: SystemSetupMicrophoneStep(model: model)
        case .measure: SystemSetupMeasureStep(model: model)
        case .alignment: SystemSetupAlignmentStep(model: model)
        case .room:
            Text("Optional. Describe the room so seat and speaker suggestions can pre-fill the next steps, or skip.")
                .foregroundStyle(.secondary)
            ProductionRoomGeometrySection(advisor: advisor)
        default:
            Text("This step arrives in a later update of the guided setup. Your choices so far are kept.")
                .foregroundStyle(.secondary)
        }
    }

    static func title(_ step: SystemSetupStep) -> String {
        switch step {
        case .output: return "Output"
        case .topology: return "Speakers"
        case .microphone: return "Microphone and level"
        case .room: return "Room"
        case .measure: return "Measure seats"
        case .alignment: return "Alignment"
        case .bass: return "Bass"
        case .correction: return "Correction"
        case .verify: return "Verify"
        case .save: return "Save"
        }
    }
}

private struct SystemSetupOutputStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var engine: AudioIOEngine

    init(model: SystemSetupFlowModel) {
        self.model = model
        _engine = ObservedObject(wrappedValue: model.engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which output plays your speakers?").font(.headline)
            Picker("Output", selection: Binding(
                get: { engine.selectedOutputDevice?.uid ?? "" },
                set: { if !$0.isEmpty { model.chooseOutput(uid: $0) } }
            )) {
                Text("Choose an output").tag("")
                ForEach(engine.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
            }
            if let device = engine.selectedOutputDevice {
                Text("Runs at \(device.nominalSampleRate, specifier: "%g") Hz, the device's own rate.")
                    .font(.caption).foregroundStyle(.secondary)
                if SystemSetupEntryPolicy.isHeadphoneOutput(
                    name: device.name, uid: device.uid, state: model.profiles.selectedSystemProfile?.state) {
                    Label("This looks like headphones. Use the Headphones workspace for headphone correction.",
                          systemImage: "headphones")
                        .font(.callout)
                }
            }
        }
    }
}

private struct SystemSetupTopologyStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What speakers do you have?").font(.headline)
            ForEach(SystemSetupTopology.allCases, id: \.self) { topology in
                Button {
                    model.chooseTopology(topology)
                } label: {
                    Label(SystemSetupTopologyPreset(topology: topology).title,
                          systemImage: model.topologyPreset.topology == topology ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
            }
            if model.topologyPreset.topology.hasSubwoofer {
                Stepper(
                    "Crossover \(Int(model.topologyPreset.crossoverHz)) Hz",
                    value: $model.topologyPreset.crossoverHz,
                    in: SystemSetupTopologyPreset.crossoverRangeHz, step: 5)
                Picker("Slope", selection: $model.topologyPreset.slope) {
                    ForEach(CrossoverTopology.allCases) { Text($0.displayName).tag($0) }
                }
                Text("Two subwoofers share the same bass path for now; separate subwoofer routing arrives with the routing matrix.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct SystemSetupMicrophoneStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var microphone: RoomCorrectionCalibrationController
    @StateObject private var monitor = MeasurementInputMonitor()
    @State private var splText = ""

    init(model: SystemSetupFlowModel) {
        self.model = model
        _microphone = ObservedObject(wrappedValue: model.microphone)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurement microphone").font(.headline)
            Text("Notch Sixty listens through this microphone to measure your speakers. Macs ask for microphone permission the first time; audio is analysed on this Mac and never leaves it.")
                .font(.callout).foregroundStyle(.secondary)
            if microphone.permissionStatus != .authorized {
                Button("Allow microphone access") {
                    Task { await microphone.requestMicrophonePermission(); try? microphone.refreshInputDevices() }
                }
            } else {
                Picker("Microphone", selection: Binding(
                    get: { microphone.selectedInputUID ?? "" },
                    set: { model.selectMicrophone(uid: $0.isEmpty ? nil : $0) }
                )) {
                    Text("Choose a microphone").tag("")
                    ForEach(microphone.inputDevices) { Text($0.name).tag($0.uid) }
                }
                Text(microphone.microphoneCalibration.map { "Calibration file: \($0.sourceName ?? "loaded")" }
                     ?? "No calibration file. Import one in the Calibrate tab for the most accurate results.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text("Set the level").font(.headline)
            Text("Set each channel on its own, then use All channels as a combined check (the LFE is never in it). Pink noise starts very quietly at \(Int(SystemSetupLevelPlan.startLevelDB)) dBFS. Raise it a step at a time until the meter reads about \(Int(SystemSetupLevelPlan.targetSPLdBC)) dB(C) at your main seat. It never goes above \(Int(SystemSetupLevelPlan.ceilingDB)) dBFS.")
                .font(.callout).foregroundStyle(.secondary)
            let channels = model.noiseChannels
            Picker("Channel", selection: Binding<Int>(
                get: { if case .lane(let lane) = model.level.target { return lane } else { return -1 } },
                set: { model.selectNoiseTarget(lane: $0 < 0 ? nil : $0) }
            )) {
                Text("All channels (combined check)").tag(-1)
                ForEach(channels, id: \.index) { Text($0.name + ($0.isLFE ? " (starts at \(Int(SystemSetupLevelPlan.lfeStartLevelDB)) dBFS, bass only)" : "")).tag($0.index) }
            }
            HStack {
                Button("Lower") { model.lowerLevel() }
                Text("\(Int(model.level.levelDB)) dBFS").monospacedDigit()
                Button("Raise") { model.raiseLevel() }.disabled(model.level.atCeiling)
                Spacer()
                if let reading = monitor.reading {
                    Text("\(reading.slowDB, specifier: "%.1f") dB(C)").monospacedDigit()
                }
            }
            HStack {
                Button(model.noiseIsPlaying ? "Stop noise" : "Play noise") { model.toggleNoise() }
                Button(monitor.isRunning ? "Stop meter" : "Start meter") { toggleMeter() }
                    .disabled(microphone.selectedInputDevice == nil)
                Button("Use this level for the sweep") {
                    if let reading = monitor.reading { model.acceptSweepLevel(measuredSPLdBC: reading.slowDB) }
                }
                .disabled(monitor.reading == nil)
                if let sweep = model.choices.sweepLevelDBFS {
                    Text("Sweep level \(sweep, specifier: "%.0f") dBFS").font(.caption)
                }
            }
        }
        .onDisappear { monitor.stop(); model.stopNoise() }
    }

    private func toggleMeter() {
        if monitor.isRunning { monitor.stop(); return }
        guard let device = microphone.selectedInputDevice else { return }
        monitor.weighting = .c
        monitor.start(microphone: device, channel: microphone.selectedInputChannelIndex)
    }
}

private struct SystemSetupMeasureStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var calibration: MultichannelCalibrationController

    init(model: SystemSetupFlowModel) {
        self.model = model
        _calibration = ObservedObject(wrappedValue: model.calibration)
    }

    var body: some View {
        let progress = model.measureProgress
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure your listening seats").font(.headline)
            Text("Each speaker plays a sweep and the microphone records it at each seat. Measure the main seat first; add seats for a wider sweet spot. Playback is stopped while measuring.")
                .font(.callout).foregroundStyle(.secondary)
            if calibration.sources.isEmpty {
                Label("Describe your speakers and outputs in Speakers first; measuring needs an enabled output device profile.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            ForEach(calibration.seats) { seat in
                HStack {
                    Image(systemName: progress.isComplete(seat) ? "checkmark.circle.fill" : "circle")
                    Text(seat.name)
                    Spacer()
                    if progress.isComplete(seat) {
                        Button("Re-measure") { model.remeasure(seatID: seat.id) }.disabled(model.isMeasuring)
                    }
                    if calibration.seats.count > 1 {
                        Button("Remove") { model.removeSeat(seat.id) }.disabled(model.isMeasuring)
                    }
                }
            }
            HStack {
                Button("Add seat") { model.addSeat() }
                    .disabled(model.isMeasuring || calibration.seats.count >= Int(N60_CALIBRATION_MAX_SEATS))
                Spacer()
                if model.isMeasuring {
                    Button("Stop") { model.cancelMeasurement() }
                } else {
                    Button(progress.isComplete ? "Measure again" : "Measure") {
                        Task { await model.measureAll() }
                    }
                    .disabled(progress.next == nil && !progress.isComplete)
                }
            }
            ProgressView(value: model.isMeasuring ? calibration.activeMeasurementProgress : progress.fraction)
            if let next = progress.next, model.isMeasuring {
                Text("Measuring \(next.seat.name), \(next.source.displayName)").font(.caption)
            }
        }
        .onAppear { model.prepareMeasure() }
    }
}

private struct SystemSetupAlignmentStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Align levels, polarity and distances").font(.headline)
            Text("Notch Sixty matches the loudness and arrival time of your speakers at the seats you measured. Apply it to hear the result; you can revert at any time and Cancel restores everything.")
                .font(.callout).foregroundStyle(.secondary)
            if let alignment = model.alignment {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Speaker").bold(); Text("Level").bold(); Text("Delay").bold()
                        Text("Polarity").bold(); Text("Distance").bold()
                    }
                    ForEach(alignment.rows) { row in
                        GridRow {
                            Text(row.title)
                            Text("\(row.levelDB, specifier: "%.1f") dB").monospacedDigit()
                            Text("\(row.delayMilliseconds, specifier: "%.2f") ms").monospacedDigit()
                            Text(row.polarityInverted ? "Inverted" : "Normal")
                            Text(row.distanceText).monospacedDigit()
                        }
                    }
                }
                if !alignment.invertedSources.isEmpty {
                    Label("A speaker looks wired out of polarity. Alignment flips it for you; check the wiring too.",
                          systemImage: "exclamationmark.triangle").font(.callout)
                }
                HStack {
                    Button("Apply") { model.applyAlignment() }.disabled(model.choices.alignmentApplied)
                    Button("Revert") { model.revertAlignment() }.disabled(!model.choices.alignmentApplied)
                    if model.choices.alignmentApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
                }
            } else {
                Button("Work out the alignment") { Task { await model.computeAlignment() } }
            }
        }
        .onAppear { if model.alignment == nil { Task { await model.computeAlignment() } } }
    }
}

// MARK: - Entry cards (design note 10)

/// The "Set up my system" card shown on the Dashboard and System Overview. Hidden with the flag
/// off; shows a pointer to Headphones for headphone outputs.
struct SystemSetupEntryCard: View {
    let availability: SystemSetupEntryPolicy.Availability
    let start: () -> Void
    let openHeadphones: () -> Void

    var body: some View {
        switch availability {
        case .hidden:
            EmptyView()
        case .headphonesPointer:
            GroupBox {
                HStack {
                    Label("This output looks like headphones. Headphone correction lives in Headphones.",
                          systemImage: "headphones")
                    Spacer()
                    Button("Open Headphones", action: openHeadphones)
                }.padding(4)
            }
        case .offer:
            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Set up my system", systemImage: "wand.and.stars").font(.headline)
                        Text("Choose your speakers, set levels and measure your room in one guided flow.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Start", action: start)
                }.padding(4)
            }
        }
    }
}
