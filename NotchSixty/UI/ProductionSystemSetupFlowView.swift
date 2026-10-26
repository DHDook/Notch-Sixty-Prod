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
    @Published private(set) var bass: SystemSetupBassDesign?
    @Published var correctionMode = SystemSetupCorrectionMode.default
    @Published var correctionTarget = SystemSetupCorrectionTarget.default
    @Published private(set) var seatPredictions: [SystemSetupSeatPrediction] = []
    @Published private(set) var correctionIsPrepared = false
    @Published private(set) var verificationReport: SystemSetupVerificationReport?
    @Published private(set) var verificationSummary: SystemSetupVerificationSummary?
    @Published private(set) var isVerifying = false
    @Published private(set) var roomInsights: [SystemSetupRoomInsight] = []
    @Published private(set) var savedProfileName: String?

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let calibration: MultichannelCalibrationController
    private let noise: SystemSetupNoisePlaying
    /// The flow's own Room Correction project (its own folder), so it never overwrites the project
    /// the user keeps in the Room Correction workspace.
    let roomProjects: RoomCorrectionProjectController
    private var profileBeforeBass: OutputDeviceProfileConfiguration?
    private let verifier: SystemSetupPostApplyMeasuring
    private let sessions: SystemSetupSessionStore
    private var verificationTask: Task<Void, Never>?
    static let verificationTimeoutSeconds = 60.0

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController,
         calibration: MultichannelCalibrationController,
         noise: SystemSetupNoisePlaying? = nil,
         verifier: SystemSetupPostApplyMeasuring? = nil,
         sessions: SystemSetupSessionStore = SystemSetupSessionStore(directory: SystemSetupSessionStore.defaultDirectory())) {
        self.verifier = verifier ?? UnconnectedSystemSetupPostApplyMeasurer()
        self.sessions = sessions
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.calibration = calibration
        self.noise = noise ?? EngineSystemSetupNoisePlayer(host: engine)
        self.roomProjects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(
                rootDirectory: SystemSetupSessionStore.defaultDirectory()
                    .appendingPathComponent("RoomCorrection", isDirectory: true)))
    }

    var choices: SystemSetupChoices { flow.choices }
    var step: SystemSetupStep { flow.step }
    var isRunning: Bool { flow.phase == .running }
    /// Steps built so far; later ones show a placeholder.
    static let builtSteps: Set<SystemSetupStep> = Set(SystemSetupStep.allCases)

    private var sessionKey: String { profiles.selectedSystemProfileID?.uuidString ?? "default" }

    private func persistSession() {
        guard flow.phase == .running else { return }
        try? sessions.save(SystemSetupSession(playbackSystemKey: sessionKey, updatedAt: Date(), flow: flow))
    }

    /// Resumes the saved session for this playback system at its last completed step. A different output
    /// device or rate drops the measurement steps; measurements the controller no longer holds do the same.
    private func resumeSession() -> Bool {
        guard var saved = sessions.load(key: sessionKey)?.flow, saved.phase == .running else { return false }
        let device = engine.selectedOutputDevice
        saved.outputConfigurationChanged(outputUID: device?.uid, sampleRate: device?.nominalSampleRate)
        calibration.prepareForUse()
        saved.resumed(measurementsAvailable: !calibration.measurements.isEmpty)
        flow = saved
        topologyPreset = SystemSetupTopologyPreset.current(from: saved.snapshot ?? profiles.captureSystemState())
        if let topology = saved.choices.topology { topologyPreset.topology = topology }
        syncMeasurementChoices()
        message = saved.invalidationReason ?? "Resumed where you left off."
        return true
    }

    func begin() {
        if resumeSession() { return }
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
    func selectNoiseTarget(lane: Int?, includeLFE: Bool = false) {
        let wasPlaying = noiseIsPlaying
        if wasPlaying { stopNoise(); if noiseIsPlaying { return } }
        level.recordLevel()
        if let lane, let channel = noiseChannels.first(where: { $0.index == lane }) {
            level.selectTarget(.lane(lane), isLFE: channel.isLFE)
        } else {
            level.selectTarget(.allProgram(includeLFE: includeLFE), isLFE: false)
        }
        if wasPlaying, !noiseIsPlaying { toggleNoise() }
    }

    /// "All channels" has two modes: without the LFE (default) and with it (full-band noise reaches the sub).
    func selectCombinedMode(includeLFE: Bool) {
        selectNoiseTarget(lane: nil, includeLFE: includeLFE)
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
        if flow.choices.correctionApplied { revertCorrection() }
        if flow.choices.bassApplied { revertBass() }
        if flow.choices.alignmentApplied { revertAlignment() }
        alignment = nil
        bass = nil
        correctionIsPrepared = false
        seatPredictions = []
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

    // MARK: Bass

    var hasSubwoofer: Bool { flow.choices.topology?.hasSubwoofer == true }

    /// Joint bass design (E10) for the measured seats. E10's mixed-phase flag has been removed, so
    /// the joint optimiser is always allowed here; without a subwoofer the step is skipped.
    func computeBass() {
        guard let rate = flow.choices.sampleRate else { return }
        do {
            bass = try SystemSetupBassDesign.make(
                sources: calibration.sources, seats: calibration.seats, measurements: calibration.measurements,
                sampleRate: rate, crossoverHz: engine.bassManagementConfiguration.frequencyHz,
                jointBassAllowed: true)
            message = nil
        } catch {
            bass = nil
            message = error.localizedDescription
        }
    }

    func applyBass() {
        guard let bass, let profile = profiles.selectedSystemOutputDeviceProfile else {
            message = "Work out the bass design first."
            return
        }
        do {
            let before = profile
            try profiles.replaceSelectedSystemOutputDeviceProfile(try bass.applying(to: profile))
            profileBeforeBass = before
            flow.choices.bassApplied = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func revertBass() {
        do {
            if let previous = profileBeforeBass {
                try profiles.replaceSelectedSystemOutputDeviceProfile(previous)
            }
            profileBeforeBass = nil
            flow.choices.bassApplied = false
        } catch {
            message = "Restoring the previous bass settings failed: \(error.localizedDescription)"
        }
    }

    // MARK: Correction

    /// Builds the flow's Room Correction project from the seat records (no second measurement),
    /// then designs with the Room Correction workspace's own path.
    func prepareCorrection() {
        guard let rate = flow.choices.sampleRate, let systemID = profiles.selectedSystemProfileID else { return }
        do {
            let input = microphone.selectedInputDevice
            let sweep = RoomCorrectionSweepSettings(
                sampleRate: rate, startFrequencyHz: microphone.sweepStartFrequencyHz,
                endFrequencyHz: microphone.sweepEndFrequencyHz, durationSeconds: microphone.sweepDurationSeconds,
                levelDBFS: flow.choices.sweepLevelDBFS ?? microphone.sweepLevelDBFS,
                leadInSeconds: microphone.sweepLeadInSeconds, tailSeconds: microphone.sweepTailSeconds,
                fadeSeconds: microphone.sweepFadeSeconds)
            let mic = RoomCorrectionMicrophone(
                stableID: input?.uid, displayName: input?.name ?? "Measurement Microphone", manufacturer: nil,
                inputChannelIndex: microphone.selectedInputChannelIndex, calibration: microphone.microphoneCalibration)
            let project = try SystemSetupRoomProjectAdapter.project(
                playbackSystemID: systemID, name: "\(profiles.selectedSystemProfileName) Guided Setup",
                seats: calibration.seats, measurements: calibration.measurements, sampleRate: rate,
                sweep: sweep, microphone: mic)
            try roomProjects.adoptProject(project)
            correctionIsPrepared = true
            message = nil
        } catch {
            correctionIsPrepared = false
            message = error.localizedDescription
        }
    }

    /// Trial apply: designs against the chosen target and deploys through the controller's gated
    /// path (verification recomputed before commit). Mixed phase is not produced here; the Verify
    /// step's verifier gates it (S6), so the design kind stays minimum phase.
    func applyCorrection() {
        do {
            if !correctionIsPrepared { prepareCorrection() }
            guard correctionIsPrepared else { return }
            try roomProjects.setTarget(correctionTarget.curve)
            let design = try roomProjects.generateDesign(
                parameters: SystemSetupCorrectionPlan.defaultParameters, name: "Guided Setup \(correctionTarget.title)")
            let report = try roomProjects.verification(for: design)
            try roomProjects.deploySelectedDesign()
            seatPredictions = SystemSetupSeatPrediction.make(from: report)
            flow.choices.designKind = correctionMode.designKind(mixedPhaseAllowed: false)
            flow.choices.correctionApplied = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func revertCorrection() {
        guard let snapshot = flow.snapshot else { return }
        do {
            try profiles.replaceSelectedSystemRoomCorrection(
                snapshot.roomCorrection, calibrationSummary: snapshot.roomCorrectionCalibration)
            flow.choices.correctionApplied = false
            seatPredictions = []
        } catch {
            message = "Restoring the previous correction failed: \(error.localizedDescription)"
        }
    }

    // MARK: Verify (design note 7)

    /// The main seat's predicted error after correction, from the Correction step.
    var predictedMainSeatErrorDB: Double { seatPredictions.first?.rmsErrorAfterDB ?? 0 }

    /// Room insights come from the advisor's analyser over the flow's own Room Correction project.
    func prepareVerify() {
        roomInsights = SystemSetupRoomInsights.make(
            report: roomProjects.project.map { RoomTreatmentAdvisorAnalyzer().analyze(project: $0) })
    }

    /// Measures the main seat again through the live graph. Minimum phase keeps a failed or unavailable
    /// check as "Not verified"; a mixed-phase mismatch, a timeout or a cancel reverts the correction and
    /// returns to Correction.
    func runVerification() {
        guard verificationTask == nil, let rate = flow.choices.sampleRate else { return }
        isVerifying = true
        let predicted = predictedMainSeatErrorDB
        let timeout = Self.verificationTimeoutSeconds
        let verifier = self.verifier
        verificationTask = Task { [weak self] in
            var outcome: Result<SystemSetupVerificationReport, Error>
            do {
                let report = try await withThrowingTaskGroup(of: SystemSetupVerificationReport.self) { group in
                    group.addTask { @MainActor in
                        try await verifier.measureMainSeat(predictedErrorDB: predicted, sampleRate: rate)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                        throw SystemSetupVerificationError.timedOut(seconds: timeout)
                    }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw SystemSetupVerificationError.timedOut(seconds: timeout) }
                    return first
                }
                outcome = .success(report)
            } catch { outcome = .failure(error) }
            self?.finishVerification(outcome)
        }
    }

    func cancelVerification() { verificationTask?.cancel() }

    private func finishVerification(_ outcome: Result<SystemSetupVerificationReport, Error>) {
        verificationTask = nil
        isVerifying = false
        let kind = flow.choices.designKind
        switch outcome {
        case .success(let report):
            verificationReport = report
            if report.passed || kind == .minimumPhase {
                flow.choices.verificationPassed = report.passed
                verificationSummary = .make(report: report, designKind: kind)
            } else {
                failVerification(reason: "Verification did not match the design; the correction was reverted.")
            }
        case .failure(let error):
            let unavailable = (error as? SystemSetupVerificationError) == .measurementUnavailable
            if unavailable && kind == .minimumPhase {
                verificationReport = nil
                flow.choices.verificationPassed = false
                verificationSummary = .make(report: nil, designKind: kind, failure: error.localizedDescription)
            } else {
                let reason = error is CancellationError
                    ? "Verification was cancelled; the correction was reverted." : error.localizedDescription
                failVerification(reason: reason)
            }
        }
        persistSession()
    }

    private func failVerification(reason: String) {
        revertCorrection()
        verificationReport = nil
        verificationSummary = SystemSetupVerificationSummary(verdict: .failed, headline: "Verification failed", detail: reason)
        flow.verificationFailed(reason: reason)
        message = reason
    }

    // MARK: Save (design notes 7 and 9)

    var savesAsNotVerified: Bool { flow.savesAsNotVerified }

    /// Saves the verified (or, for minimum phase, "Not verified") system as a profile and ends the flow.
    func save() {
        do {
            try flow.finish()
            let name = SystemSetupSaveNaming.profileName(flow.choices.profileName, notVerified: flow.savesAsNotVerified)
            let id = profiles.saveCurrentSystemProfile(named: name)
            savedProfileName = profiles.systemProfiles.first(where: { $0.id == id })?.name ?? name
            sessions.delete(key: sessionKey)
            message = nil
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    func setProfileName(_ name: String) { flow.choices.profileName = name; persistSession() }

    func acceptSweepLevel(measuredSPLdBC: Double) {
        flow.choices.sweepLevelDBFS = level.sweepLevel(measuredSPLdBC: measuredSPLdBC)
    }

    func next() {
        do {
            if flow.step == .topology { try applyTopology() }
            try flow.next()
            message = nil
            if flow.step == .verify { prepareVerify() }
            if flow.step == .save, flow.choices.profileName.isEmpty {
                flow.choices.profileName = SystemSetupSaveNaming.defaultName(outputName: engine.selectedOutputDevice?.name)
            }
            persistSession()
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    func back() { try? flow.back(); persistSession() }

    func skip() {
        do { try flow.skip(); persistSession() } catch let refusal as SystemSetupRefusal { message = refusal.reason } catch {}
    }

    func cancel() {
        stopNoise()
        calibration.cancelMeasurement()
        verificationTask?.cancel()
        sessions.delete(key: sessionKey)
        guard let snapshot = try? flow.cancel() else { return }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            try profiles.replaceSelectedSystemBassManagement(snapshot.bassManagement)
            try profiles.replaceSelectedSystemRoomCorrection(
                snapshot.roomCorrection, calibrationSummary: snapshot.roomCorrectionCalibration)
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
            if model.step == .save {
                Button("Save") { model.save(); if model.savedProfileName != nil { dismiss() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isVerifying)
            } else {
                Button("Next") { model.next() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!SystemSetupFlowModel.builtSteps.contains(model.step) || model.isVerifying)
            }
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
        case .bass: SystemSetupBassStep(model: model)
        case .correction: SystemSetupCorrectionStep(model: model)
        case .verify: SystemSetupVerifyStep(model: model)
        case .save: SystemSetupSaveStep(model: model)
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
            Text("Set each channel on its own, then use All channels as a combined check (the LFE is left out unless you choose the including-LFE mode). Pink noise starts very quietly at \(Int(SystemSetupLevelPlan.startLevelDB)) dBFS. Raise it a step at a time until the meter reads about \(Int(SystemSetupLevelPlan.targetSPLdBC)) dB(C) at your main seat. It never goes above \(Int(SystemSetupLevelPlan.ceilingDB)) dBFS.")
                .font(.callout).foregroundStyle(.secondary)
            let channels = model.noiseChannels
            Picker("Channel", selection: Binding<Int>(
                get: {
                    switch model.level.target {
                    case .lane(let lane): return lane
                    case .allProgram(let includeLFE): return includeLFE ? -2 : -1
                    }
                },
                set: { model.selectNoiseTarget(lane: $0 < 0 ? nil : $0, includeLFE: $0 == -2) }
            )) {
                Text("All channels except the LFE (combined check)").tag(-1)
                if channels.contains(where: \.isLFE) { Text("All channels including the LFE").tag(-2) }
                ForEach(channels, id: \.index) { Text($0.name + ($0.isLFE ? " (starts at \(Int(SystemSetupLevelPlan.lfeStartLevelDB)) dBFS, bass only)" : "")).tag($0.index) }
            }
            if model.level.showsFullBandLFEWarning {
                Text("Warning: this mode sends full-band noise to the subwoofer as well. It starts at \(Int(SystemSetupLevelPlan.lfeStartLevelDB)) dBFS. Raise the level slowly and stop if the sub strains.")
                    .font(.callout).foregroundStyle(.orange)
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

private struct SystemSetupBassStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Blend the subwoofer").font(.headline)
            if !model.hasSubwoofer {
                Text("You have no subwoofer, so there is nothing to blend. Continue to the next step.")
                    .foregroundStyle(.secondary)
            } else if let bass = model.bass {
                content(bass)
            } else {
                Button("Work out the bass design") { model.computeBass() }
            }
        }
        .onAppear { if model.hasSubwoofer && model.bass == nil { model.computeBass() } }
    }

    @ViewBuilder
    private func content(_ bass: SystemSetupBassDesign) -> some View {
        Text("Notch Sixty sets the subwoofer's level, delay and polarity so bass is as even as possible across every seat you measured. Apply it to hear the result; Revert or Cancel restores your earlier settings.")
            .font(.callout).foregroundStyle(.secondary)
        if bass.mode == .subAlignmentOnly {
            Label("The subwoofer keeps the alignment you applied in the previous step.", systemImage: "checkmark.circle")
        } else {
            if let before = bass.seatSpreadBeforeDB, let after = bass.seatSpreadAfterDB {
                Text("Seat-to-seat bass difference (20 to 120 Hz): \(before, specifier: "%.1f") dB now, \(after, specifier: "%.1f") dB predicted.")
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Seat").bold(); Text("Average level now").bold(); Text("Predicted").bold() }
                ForEach(Array(bass.seatNames.enumerated()), id: \.offset) { index, name in
                    GridRow {
                        Text(name)
                        Text("\(bass.seatMeanBeforeDB[safe: index] ?? 0, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(bass.seatMeanAfterDB[safe: index] ?? 0, specifier: "%.1f") dB").monospacedDigit()
                    }
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Speaker").bold(); Text("Level").bold(); Text("Delay").bold(); Text("Polarity").bold() }
                ForEach(bass.rows) { row in
                    GridRow {
                        Text(row.title)
                        Text("\(row.gainDB, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(row.delayMilliseconds, specifier: "%.2f") ms").monospacedDigit()
                        Text(row.polarityInverted ? "Inverted" : "Normal")
                    }
                }
            }
        }
        HStack {
            Button("Apply") { model.applyBass() }.disabled(model.choices.bassApplied)
            Button("Revert") { model.revertBass() }.disabled(!model.choices.bassApplied)
            if model.choices.bassApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

private struct SystemSetupCorrectionStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Correct the room").font(.headline)
            Text("Notch Sixty flattens the bumps and dips your seats share, using the measurements you already made. Nothing is measured again.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Listening", selection: $model.correctionMode) {
                ForEach(SystemSetupCorrectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.correctionMode.detail).font(.callout).foregroundStyle(.secondary)
            Picker("Sound", selection: $model.correctionTarget) {
                ForEach(SystemSetupCorrectionTarget.all) { Text($0.title).tag($0) }
            }
            Text(model.correctionTarget.detail).font(.callout).foregroundStyle(.secondary)
            if !model.seatPredictions.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Seat").bold(); Text("Error now").bold(); Text("Predicted").bold() }
                    ForEach(model.seatPredictions) { seat in
                        GridRow {
                            Text(seat.name)
                            Text("\(seat.rmsErrorBeforeDB, specifier: "%.1f") dB").monospacedDigit()
                            Text("\(seat.rmsErrorAfterDB, specifier: "%.1f") dB").monospacedDigit()
                        }
                    }
                }
            }
            HStack {
                Button("Apply") { model.applyCorrection() }.disabled(model.choices.correctionApplied)
                Button("Revert") { model.revertCorrection() }.disabled(!model.choices.correctionApplied)
                if model.choices.correctionApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
            }
        }
    }
}

private struct SystemSetupVerifyStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Check the result").font(.headline)
            Text("Notch Sixty measures your main seat once more with the correction on and compares it with what was predicted.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Verify") { model.runVerification() }.disabled(model.isVerifying)
                if model.isVerifying {
                    ProgressView().controlSize(.small)
                    Button("Cancel check") { model.cancelVerification() }
                }
            }
            if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: summary.verdict == .verified ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.headline)
                Text(summary.detail).font(.callout).foregroundStyle(.secondary)
            }
            if let report = model.verificationReport {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow { Text("Predicted error").bold(); Text("Measured error").bold() }
                    GridRow {
                        Text("\(report.predictedErrorDB, specifier: "%.1f") dB").monospacedDigit()
                        Text("\(report.measuredErrorDB, specifier: "%.1f") dB").monospacedDigit()
                    }
                }
            }
            roomInsightsCard
        }
    }

    private var roomInsightsCard: some View {
        GroupBox("Room insights") {
            VStack(alignment: .leading, spacing: 8) {
                if model.roomInsights.isEmpty {
                    Text("Nothing here that EQ cannot handle.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.roomInsights) { insight in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(insight.title).font(.callout.weight(insight.isImportant ? .semibold : .regular))
                        Text(insight.detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("The Room tab in System shows the full advisor.").font(.caption).foregroundStyle(.secondary)
            }
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SystemSetupSaveStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save your system").font(.headline)
            TextField("Profile name", text: Binding(
                get: { model.choices.profileName }, set: { model.setProfileName($0) }))
            if model.savesAsNotVerified {
                Label("This profile will be labelled Not verified.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            } else if let summary = model.verificationSummary {
                Label(summary.headline, systemImage: "checkmark.seal.fill").font(.callout)
            }
        }
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
