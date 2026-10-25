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

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController) {
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
    }

    var choices: SystemSetupChoices { flow.choices }
    var step: SystemSetupStep { flow.step }
    var isRunning: Bool { flow.phase == .running }
    /// Steps built so far; later ones show a placeholder.
    static let builtSteps: Set<SystemSetupStep> = [.output, .topology, .microphone, .room]

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

    func raiseLevel() { level.raise() }
    func lowerLevel() { level.lower() }

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
        guard let snapshot = try? flow.cancel() else { return }
        do {
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
         microphone: RoomCorrectionCalibrationController, advisor: RoomTreatmentAdvisorController) {
        _model = StateObject(wrappedValue: SystemSetupFlowModel(
            engine: engine, profiles: profiles, microphone: microphone))
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
            Text("Pink noise starts very quietly at \(Int(SystemSetupLevelPlan.startLevelDB)) dBFS. Raise it a step at a time until the meter reads about \(Int(SystemSetupLevelPlan.targetSPLdBC)) dB(C) at your main seat. It never goes above \(Int(SystemSetupLevelPlan.ceilingDB)) dBFS.")
                .font(.callout).foregroundStyle(.secondary)
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
        .onDisappear { monitor.stop() }
    }

    private func toggleMeter() {
        if monitor.isRunning { monitor.stop(); return }
        guard let device = microphone.selectedInputDevice else { return }
        monitor.weighting = .c
        monitor.start(microphone: device, channel: microphone.selectedInputChannelIndex)
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
