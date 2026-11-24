import SwiftUI
import UniformTypeIdentifiers

// E12 S29: split out of ProductionSystemSetupFlowView.swift with no change in behaviour.

/// Drives the reducer from the UI. Topology is written through the profile API when the user
/// leaves that step; Cancel restores the bass-management snapshot exactly.
@MainActor
final class SystemSetupFlowModel: ObservableObject {
    @Published private(set) var flow = SystemSetupFlow()
    @Published var topologyPreset = SystemSetupTopologyPreset(topology: .stereo)
    /// E25 S3: the Speakers step's choices (layout, subs, bass handling); the arrangement is rebuilt from them.
    @Published private(set) var speakerChoices = SystemSetupSpeakerChoices()
    @Published private(set) var level = SystemSetupLevelPlan()
    @Published var message: String?
    @Published private(set) var alignment: SystemSetupAlignment?
    @Published private(set) var noiseIsPlaying = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var bass: SystemSetupBassDesign?
    /// E25 S4: class C's mono-bass crossover designed from the feeds, and the bass settings it replaced.
    @Published private(set) var monoBass: SystemSetupMonoBassDesign?
    private var bassManagementBeforeMono: BassManagementConfiguration?
    @Published var correctionMode = SystemSetupCorrectionMode.default
    @Published var correctionTarget = SystemSetupCorrectionTarget.default
    /// Built-in sounds plus the target library's saved and imported room targets (E13 S1).
    @Published private(set) var correctionTargetChoices = SystemSetupCorrectionTarget.all
    @Published private(set) var seatPredictions: [SystemSetupSeatPrediction] = []
    /// E12 S30: what Apply predicted, for the Correction graph, and the graphs' detail (simple: one curve per line of the story).
    @Published private(set) var correctionPrediction: SystemSetupGraphBuilder.CorrectionPrediction?
    @Published var graphDetail = SystemSetupGraphDetail.simple
    @Published private(set) var correctionIsPrepared = false
    @Published private(set) var verificationReport: SystemSetupVerificationReport?
    @Published private(set) var verificationSummary: SystemSetupVerificationSummary?
    @Published private(set) var isVerifying = false
    @Published private(set) var roomInsights: [SystemSetupRoomInsight] = []
    @Published private(set) var savedProfileName: String?
    /// E24 S9: the open blind ABX (Save step), its preparation state and why it cannot open.
    @Published private(set) var abx: RoomCorrectionABXController?
    @Published private(set) var abxPreparing = false
    @Published var abxMixedFitsEveryRate = true
    /// E12 S29: shown in a dialog that stays until dismissed when Cancel or Close could not put the old settings back.
    @Published var restoreFailure: String?
    /// E12 S29: the page after Save, and the before/after state of its "Compare before and after" button.
    @Published private(set) var summary: SystemSetupSummary?
    @Published private(set) var comparingBefore = false
    /// E12 S29: true while a resumed session applies its trial settings again; Next waits for it.
    @Published private(set) var isReapplying = false
    private(set) var reapplyTask: Task<Void, Never>?

    let engine: AudioIOEngine
    let profiles: ProductProfileController
    let microphone: RoomCorrectionCalibrationController
    let calibration: MultichannelCalibrationController
    private let noise: SystemSetupNoisePlaying
    /// The Level step's meter; the level session feeds it while noise plays.
    let levelMonitor: MeasurementInputMonitor
    private let laneChoices: @MainActor () -> [(index: Int, name: String, isLFE: Bool)]
    /// The flow's own Room Correction project (its own folder), so it never overwrites the project
    /// the user keeps in the Room Correction workspace.
    let roomProjects: RoomCorrectionProjectController
    private var profileBeforeBass: OutputDeviceProfileConfiguration?
    /// E24 S3c: what Bass Apply replaced (the room configuration and its summary), the room-only lane design that
    /// Correction produced, and the bass design's grids; the installed `lanes` is always their composition.
    private var roomBeforeBass: (configuration: RoomCorrectionConfiguration, summary: RoomCorrectionCalibrationSummary?)?
    private var roomOnlyInstall: RoomCorrectionLaneInstall?
    private var bassLanePlan: RoomCorrectionBassApplyPlan?
    private let verifier: SystemSetupPostApplyMeasuring
    private let seats: SystemSetupSeatMeasuring
    private let sessions: SystemSetupSessionStore
    private var verificationTask: Task<Void, Never>?
    private let abxPlayer: RoomCorrectionABXPlaying
    private let abxDirectory: URL
    private let abxSwitchHold: TimeInterval
    /// The two room-only designs the open ABX compares (minimum and mixed phase); Keep applies one of them.
    private var abxRooms: (minimum: RoomCorrectionLaneInstall, mixed: RoomCorrectionLaneInstall)?
    /// The running measure task, so Stop can cancel the seat measurer's pass.
    private var measureTask: Task<Void, Never>?
    static let verificationTimeoutSeconds = 60.0

    init(engine: AudioIOEngine, profiles: ProductProfileController, microphone: RoomCorrectionCalibrationController,
         calibration: MultichannelCalibrationController,
         services: ProductionSystemSetupServices? = nil,
         sessions: SystemSetupSessionStore = SystemSetupSessionStore(directory: SystemSetupSessionStore.defaultDirectory()),
         roomProjectsDirectory: URL = SystemSetupSessionStore.defaultDirectory()
             .appendingPathComponent("RoomCorrection", isDirectory: true),
         abxDirectory: URL? = nil, abxSwitchHold: TimeInterval = ComparisonSwitchTiming.fixedSeconds) {
        self.abxSwitchHold = abxSwitchHold
        let services = services ?? ProductionSystemSetupServices.production(
            engine: engine, profiles: profiles, microphone: microphone, calibration: calibration)
        self.seats = services.seats
        self.verifier = services.verifier
        self.sessions = sessions
        self.engine = engine
        self.profiles = profiles
        self.microphone = microphone
        self.calibration = calibration
        self.noise = services.noise
        self.levelMonitor = services.monitor
        self.abxPlayer = services.abx
        self.abxDirectory = abxDirectory ?? RoomCorrectionABXLog.defaultDirectory()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("NotchSixty-ABX", isDirectory: true)
        self.laneChoices = services.laneChoices
        self.roomProjects = RoomCorrectionProjectController(
            profiles: profiles,
            store: RoomCorrectionProjectStore(rootDirectory: roomProjectsDirectory))
        noise.setStopHandler { [weak self] reason in self?.noiseEndedOnItsOwn(reason) }
        services.measurer.candidateProvider = { [weak self] rate in
            guard let self else { throw SystemSetupVerificationError.couldNotMeasure("The setup window closed.") }
            return try self.verificationCandidate(sampleRate: rate)
        }
    }

    var choices: SystemSetupChoices { flow.choices }
    var step: SystemSetupStep { flow.step }
    var preset: SystemSetupPreset { flow.preset }
    /// E12 S10: the steps this run shows (the quick preset leaves out Speakers and Room).
    var visibleSteps: [SystemSetupStep] { flow.preset.steps }
    /// Set when a quick run has saved: the window offers the full setup instead of closing.
    @Published private(set) var quickFinished = false
    var isRunning: Bool { flow.phase == .running }

    // MARK: Shell (E12 S29)

    /// Bass is listed when there is a subwoofer to blend or a mono bass to design; otherwise it is left out.
    var bassIsListed: Bool { flow.choices.hasDspSubwoofer || bassStepMode == .monoBass }
    var listedSteps: [SystemSetupStep] {
        SystemSetupShell.listedSteps(presetSteps: visibleSteps, bassIsListed: bassIsListed)
    }
    var stepRows: [SystemSetupStepRow] {
        SystemSetupShell.rows(
            listed: listedSteps, current: step, completed: flow.completed, skipped: flow.skipped)
    }
    var stepPosition: (position: Int, total: Int) { SystemSetupShell.position(listed: listedSteps, current: step) }
    var timeRemainingText: String {
        SystemSetupTimeEstimate.label(minutes: SystemSetupTimeEstimate.minutesRemaining(
            listed: listedSteps, from: step, seats: max(flow.choices.seatNames.count, calibration.seats.count)))
    }

    /// Opens a finished step from the list.
    func open(_ target: SystemSetupStep) {
        guard !isReapplying, !isVerifying else { return }
        do { try flow.reopen(target); message = nil; persistSession() } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch { message = error.localizedDescription }
    }

    /// Why Next (or Save) is disabled, shown beside the button; nil when it can be pressed.
    var nextBlockedReason: String? {
        if isReapplying { return "Putting your trial settings back." }
        if isVerifying { return "Checking the result." }
        if isMeasuring { return "Measuring." }
        if let why = flow.unmetPrecondition(for: step) { return why }
        if step == .save, flow.choices.designKind == .mixedPhase, flow.choices.verificationPassed != true {
            return SystemSetupRefusal.mixedPhaseNeedsVerification.reason
        }
        return nil
    }
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
        topologyPreset = SystemSetupTopologyPreset.current(from: saved.snapshot ?? profiles.captureSystemState())
        if let topology = saved.choices.topology { topologyPreset.topology = topology }
        if let hz = saved.choices.crossoverHz { topologyPreset.crossoverHz = hz }
        if let slope = saved.choices.crossoverSlope { topologyPreset.slope = slope }
        resumeArrangement(&saved)
        flow = saved
        restoreKeptMeasurements()
        calibration.prepareForUse()
        flow.resumed(measurementsAvailable: !calibration.measurements.isEmpty)
        if flow.choices.measurementIDs.isEmpty { flow.choices.trialToReapply = nil }
        if flow.choices.trialToReapply != nil { flow.trialSuspended() }
        restoreCorrectionChoices(flow.choices)
        syncMeasurementChoices()
        message = flow.invalidationReason ?? message ?? "Resumed where you left off."
        if flow.choices.trialToReapply != nil {
            message = "Resumed where you left off. Putting your trial settings back."
            reapplyTask = Task { await reapplyTrial() }
        }
        return true
    }

    private var keptCampaigns: MultichannelCalibrationCampaignStore {
        MultichannelCalibrationCampaignStore(rootDirectory: sessions.directory.appendingPathComponent("KeptCampaigns", isDirectory: true))
    }

    private func discardKeptMeasurements() {
        guard let systemID = profiles.selectedSystemProfileID else { return }
        try? FileManager.default.removeItem(at: keptCampaigns.url(for: systemID))
    }

    /// A session closed to continue later left its settings restored, which dropped the routing the measurements were
    /// taken with. Put that routing back, then the measurements that were kept aside.
    private func restoreKeptMeasurements() {
        guard flow.choices.keptMeasurements == true else { return }
        flow.choices.keptMeasurements = nil
        guard let systemID = profiles.selectedSystemProfileID,
              let archive = try? keptCampaigns.load(systemID) else {
            flow.choices.trialToReapply = nil
            return
        }
        do {
            if flow.step.index > SystemSetupStep.topology.index || flow.preset == .quick { try applyArrangement() }
            try calibration.restoreKeptCampaign(archive)
        } catch {
            flow.choices.trialToReapply = nil
            message = "Your measurements could not be put back: \(error.localizedDescription)"
        }
    }

    private func restoreCorrectionChoices(_ choices: SystemSetupChoices) {
        if let id = choices.correctionModeID, let mode = SystemSetupCorrectionMode(rawValue: id) { correctionMode = mode }
        refreshCorrectionTargets()
        if let id = choices.correctionTargetID, let target = correctionTargetChoices.first(where: { $0.id == id }) {
            correctionTarget = target
        }
    }

    /// E12 S29: applies the trial stages that were taken off when the setup was closed, in order, from the measurements
    /// that were kept. A stage that fails sends the flow back to its step with the reason.
    func reapplyTrial() async {
        let stages = flow.choices.trialToReapply ?? []
        flow.choices.trialToReapply = nil
        guard !stages.isEmpty, !flow.choices.measurementIDs.isEmpty else { persistSession(); return }
        isReapplying = true
        defer { isReapplying = false }
        for stage in [SystemSetupDesignStage.alignment, .bass, .correction] where stages.contains(stage) {
            switch stage {
            case .alignment:
                await computeAlignment()
                applyAlignment()
            case .bass:
                computeBass()
                await applyBass()
            case .correction:
                prepareCorrection()
                await applyCorrection()
            }
            let applied: Bool
            switch stage {
            case .alignment: applied = flow.choices.alignmentApplied
            case .bass: applied = flow.choices.bassApplied
            case .correction: applied = flow.choices.correctionApplied
            }
            if !applied {
                let reason = "Your \(stage.rawValue) settings could not be put back: \(message ?? "try applying them again.")"
                flow.trialReapplyFailed(stage, reason: reason)
                message = reason
                persistSession()
                return
            }
        }
        message = "Your trial settings are back."
        persistSession()
    }

    func begin(preset: SystemSetupPreset = .full, entry: SystemSetupEntry = .fresh) {
        quickFinished = false
        savedProfileName = nil
        summary = nil
        comparingBefore = false
        restoreFailure = nil
        if resumeSession() { return }
        let snapshot = profiles.captureSystemState()
        var initial = SystemSetupChoices()
        initial.outputUID = engine.selectedOutputDevice?.uid
        initial.sampleRate = engine.selectedOutputDevice?.nominalSampleRate
        initial.microphoneUID = microphone.selectedInputUID
        initial.microphoneCalibrationFile = microphone.microphoneCalibration?.sourceName
        topologyPreset = SystemSetupTopologyPreset.current(from: snapshot)
        initial.topology = topologyPreset.topology
        let detected = Int(engine.selectedOutputDevice?.outputChannelCount ?? 0)
        let migrated = SystemArrangementMigration.derive(from: snapshot, detectedChannelCount: detected)
            ?? SystemSetupArrangementPlanner.arrangement(
                deviceUID: initial.outputUID ?? "", detectedChannelCount: detected, channelsInUse: 2,
                choices: SystemSetupSpeakerChoices())
        initial.arrangement = migrated
        speakerChoices = SystemSetupArrangementPlanner.choices(from: migrated)
        do {
            try flow.start(snapshot: snapshot, choices: initial, preset: entry == .fresh ? preset : .full)
            message = nil
            if entry != .fresh { try openAtShortcut(entry) }
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Second runs (E12 S31, decision 36)

    /// Opens the run at a shortcut's step with the rest kept: the output, the speakers and the microphone come from
    /// the system as it is now. "Change the sound" measures nothing: it needs the measurements already taken and says
    /// so, and stays at the start, when they are no longer there.
    private func openAtShortcut(_ entry: SystemSetupEntry) throws {
        calibration.prepareForUse()
        if entry.dropsMeasurements {
            try calibration.resetMeasurements()
        }
        if entry == .changeSound {
            guard !calibration.measurements.isEmpty else {
                message = "The measurements from the last run are not kept. Use Measure again instead."
                return
            }
            // The arrangement the measurements were taken with is the one the system has now.
            try applyArrangement()
        }
        syncMeasurementChoices()
        if entry == .changeSound {
            let wanted = flow.choices.seatNames.count
            guard wanted > 0, flow.choices.measurementIDs.count == wanted else {
                message = "The measurements from the last run are incomplete. Use Measure again instead."
                return
            }
            // The sweep level is not needed again: no sweep runs.
            if flow.choices.sweepLevelDBFS == nil { flow.choices.sweepLevelDBFS = level.levelDB }
        }
        try flow.startAt(entry.startStep)
        persistSession()
    }

    // MARK: Outputs and Speakers (E25 S3)

    var detectedChannelCount: Int { Int(engine.selectedOutputDevice?.outputChannelCount ?? 0) }
    var arrangement: SystemArrangement? { flow.choices.arrangement }

    /// A schema-1 session has no arrangement: derive it from the topology.
    private func resumeArrangement(_ saved: inout SystemSetupFlow) {
        guard saved.choices.arrangement == nil else {
            if let a = saved.choices.arrangement { speakerChoices = SystemSetupArrangementPlanner.choices(from: a) }
            return
        }
        let topology = saved.choices.topology ?? .stereo
        let migrated = SystemSetupArrangementPlanner.migrate(
            topology: topology, deviceUID: engine.selectedOutputDevice?.uid ?? saved.choices.outputUID ?? "",
            detectedChannelCount: detectedChannelCount)
        saved.choices.arrangement = migrated.arrangement
        speakerChoices = SystemSetupArrangementPlanner.choices(from: migrated.arrangement)
        if migrated.resumeAtSpeakers, let note = migrated.note { saved.resumeAtSpeakers(note: note) }
    }

    /// Rebuilds the arrangement after the device, channel count or a Speakers choice changed.
    private func rebuildArrangement(channelsInUse: Int? = nil) {
        let previous = flow.choices.arrangement
        let uid = engine.selectedOutputDevice?.uid ?? flow.choices.outputUID ?? ""
        flow.choices.arrangement = SystemSetupArrangementPlanner.arrangement(
            deviceUID: uid, detectedChannelCount: detectedChannelCount,
            channelsInUse: channelsInUse ?? previous?.outputs.channelsInUse ?? 2,
            choices: speakerChoices, keeping: previous)
        if let a = flow.choices.arrangement {
            // The chosen layout is kept even when this arrangement stores stereo (a wider layout needs a downstream
            // bass handling): picking the layout first and the receiver second must still give a 5.1 arrangement.
            let layout = speakerChoices.layout
            speakerChoices = SystemSetupArrangementPlanner.choices(from: a)
            speakerChoices.layout = layout
        }
        persistSession()
    }

    func chooseChannelCount(_ count: Int) {
        let capped = detectedChannelCount > 0 ? min(count, detectedChannelCount) : count
        if capped == 2 {
            if speakerChoices.bass == .dspToSubOutputs { speakerChoices.bass = .fullRange }
        } else if speakerChoices.bass.isDownstream || speakerChoices.bass == .dspMonoToMains {
            speakerChoices.bass = .fullRange
        }
        rebuildArrangement(channelsInUse: capped)
    }

    func chooseLayout(_ layout: OutputProgramLayout) { speakerChoices.layout = layout; rebuildArrangement() }
    func chooseBass(_ bass: BassHandling) {
        speakerChoices.bass = bass
        if bass == .dspToSubOutputs || bass.isDownstream, speakerChoices.subwooferCount == 0 { speakerChoices.subwooferCount = 1 }
        rebuildArrangement()
    }
    /// E26 S1: how the receiver or powered sub handles bass. Quiet Zone through it needs a declaration.
    func chooseReceiverBass(_ receiverBass: ReceiverBass) {
        speakerChoices.receiverBass = receiverBass
        rebuildArrangement()
    }
    func chooseSubwooferCount(_ count: Int) {
        speakerChoices.subwooferCount = min(max(count, 0), SystemArrangement.maxSubwoofers)
        rebuildArrangement()
    }

    /// The capability card for the arrangement as it stands.
    var capabilityRows: [(feature: SystemFeature, availability: CapabilityAvailability)] {
        guard let a = flow.choices.arrangement else { return [] }
        return SystemSetupArrangementPlanner.capabilityRows(a, deviceChannelCount: detectedChannelCount)
    }

    /// Compiles the arrangement and writes it: the profile, bass management, the stored arrangement and the stereo
    /// session's mono-bass and feed calibration. Throws a user-readable reason when the arrangement cannot be used.
    private func applyArrangement() throws {
        guard let arrangement = flow.choices.arrangement, let base = flow.snapshot else { return }
        let compiled: CompiledArrangement
        switch SystemArrangementCompiler.compile(arrangement, preserving: base.outputDeviceProfile) {
        case .success(let value): compiled = value
        case .failure(let issue): throw SystemSetupApplyError(issue.errorDescription ?? "This arrangement cannot be used.")
        }
        var target = base
        if compiled.bassManagementEnabled {
            target.bassManagement.frequencyHz = min(
                max(topologyPreset.crossoverHz, SystemSetupTopologyPreset.crossoverRangeHz.lowerBound),
                SystemSetupTopologyPreset.crossoverRangeHz.upperBound)
            target.bassManagement.topology = topologyPreset.slope
        }
        target = compiled.apply(to: target)
        // Clearing the profile first keeps each validation true whichever way the bass switch moves.
        try profiles.replaceSelectedSystemOutputDeviceProfile(nil)
        try profiles.replaceSelectedSystemBassManagement(target.bassManagement)
        if let profile = compiled.outputDeviceProfile {
            try profiles.replaceSelectedSystemOutputDeviceProfile(profile)
        }
        try profiles.replaceSelectedSystemArrangement(arrangement)
        try engine.applyStereoAlignment(compiled.stereoAlignment)
    }

    func chooseOutput(uid: String) {
        do {
            try engine.selectOutput(uid: uid)
            let device = engine.selectedOutputDevice
            flow.outputConfigurationChanged(outputUID: device?.uid, sampleRate: device?.nominalSampleRate)
            if speakerChoices.bass == .dspToSubOutputs, Int(device?.outputChannelCount ?? 0) < 3 { speakerChoices.bass = .fullRange }
            rebuildArrangement(channelsInUse: min(flow.choices.arrangement?.outputs.channelsInUse ?? 2,
                                                  max(Int(device?.outputChannelCount ?? 2), 2)))
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func selectMicrophone(uid: String?) {
        microphone.selectInput(uid: uid)
        flow.choices.microphoneUID = microphone.selectedInputUID
        flow.choices.microphoneCalibrationFile = microphone.microphoneCalibration?.sourceName
    }

    /// Reloads the saved targets; keeps the current choice when it still exists, else the default.
    func refreshCorrectionTargets(library: TargetLibrary = TargetLibrary()) {
        correctionTargetChoices = SystemSetupCorrectionTarget.choices(library: library.loadAll().records)
        if !correctionTargetChoices.contains(correctionTarget) { correctionTarget = .default }
    }

    /// Channels the noise can play on right now, in lane order.
    var noiseChannels: [(index: Int, name: String, isLFE: Bool)] { laneChoices() }

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

    // MARK: Automatic level (E12 S31, decision 33)

    @Published private(set) var autoLevelRunning = false
    /// Why the automatic level stopped, or that it finished.
    @Published private(set) var autoLevelStatus: String?
    private var autoLevelTask: Task<Void, Never>?
    /// Pause between a step and the next look at the meter (the slow reading needs about a second to settle).
    var autoLevelSettle: Duration = .milliseconds(1_500)
    /// Test seam: the C-weighted reading; nil reads the Level step's meter.
    var autoLevelReading: (@MainActor () -> Double?)?

    /// Starts the meter with the noise, so nobody has to press them in a particular order.
    func startLevelMeter() {
        guard !levelMonitor.isRunning, let device = microphone.selectedInputDevice else { return }
        levelMonitor.weighting = .c
        levelMonitor.start(microphone: device, channel: microphone.selectedInputChannelIndex)
    }

    func stopLevelMeter() { levelMonitor.stop() }

    /// Plays the noise and raises it in small steps until the meter reads the target. It never passes the plan's
    /// ceiling, stops when the reading does not rise, and stops on `stopAutoLevel`.
    func startAutoLevel() {
        guard !autoLevelRunning else { return }
        autoLevelStatus = nil
        if !noiseIsPlaying { toggleNoise() }
        guard noiseIsPlaying else { return }
        startLevelMeter()
        autoLevelRunning = true
        autoLevelTask = Task { [weak self] in
            var auto = SystemSetupAutoLevel()
            while !Task.isCancelled {
                guard let settle = self?.autoLevelSettle else { return }
                try? await Task.sleep(for: settle)
                guard let self, !Task.isCancelled, self.autoLevelRunning else { return }
                guard self.noiseIsPlaying else { self.endAutoLevel("The noise stopped, so the automatic level stopped."); return }
                let reading = self.autoLevelReading?() ?? self.levelMonitor.reading?.slowDB
                switch auto.decide(reading: reading, atCeiling: self.level.atCeiling) {
                case .wait: continue
                case .raise(let step):
                    self.level.raise(byDB: step)
                    self.republishNoise()
                case .finished(let text), .stopped(let text):
                    self.endAutoLevel(text)
                    return
                }
            }
        }
    }

    func stopAutoLevel() {
        guard autoLevelRunning else { return }
        autoLevelTask?.cancel()
        endAutoLevel("Stopped. The noise is still playing at the level it reached.")
    }

    private func endAutoLevel(_ text: String) {
        autoLevelTask = nil
        autoLevelRunning = false
        autoLevelStatus = text
    }
    func lowerLevel() { level.lower(); republishNoise() }

    /// Plays the Level step's noise through the E11 generator, or says why it cannot.
    func toggleNoise() {
        if noiseIsPlaying { stopNoise(); return }
        do {
            try noise.start(level.validatedGeneratorSettings(sampleRate: engine.selectedOutputDevice?.nominalSampleRate ?? 48_000), selection: level.target)
            noiseIsPlaying = noise.isPlaying
            message = nil
            if noiseIsPlaying { startLevelMeter() }
        } catch {
            noiseIsPlaying = false
            message = error.localizedDescription
        }
    }

    /// Auto-stop and output-change stops arrive here with the text to show.
    private func noiseEndedOnItsOwn(_ reason: String) {
        noiseIsPlaying = noise.isPlaying
        message = reason
    }

    func stopNoise() {
        if autoLevelRunning {
            autoLevelTask?.cancel()
            endAutoLevel("The noise was stopped, so the automatic level stopped.")
        }
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

    var measurePlaybackNotice: String? { calibration.playbackNotice }

    func prepareMeasure() {
        stopNoise()
        calibration.prepareForUse()
        syncMeasurementChoices()
    }

    func addSeat() {
        if let limit = flow.preset.seatLimit, flow.choices.seatNames.count >= limit {
            message = "The quick setup measures one seat. Open the full setup for more."
            return
        }
        do { try calibration.addSeat(); syncMeasurementChoices() } catch { message = error.localizedDescription }
    }

    // E24 S5b1: one microphone per seat. The default is the single moved microphone.
    func setSeatMicrophoneMode(_ mode: SeatMicrophoneMode) {
        do {
            try calibration.setSeatMicrophoneMode(mode)
            if mode == .perSeat { assignDefaultSeatChannels() }
            syncMeasurementChoices()
        } catch { message = error.localizedDescription }
    }

    /// Gives every seat without a microphone the next free channel of the selected input interface.
    private func assignDefaultSeatChannels() {
        guard let device = microphone.selectedInputDevice else { return }
        var used = Set(calibration.seats.compactMap { $0.microphone.map { "\($0.deviceUID)#\($0.channelIndex)" } })
        for seat in calibration.seats where seat.microphone == nil {
            var channel = 0
            while used.contains("\(device.uid)#\(channel)") { channel += 1 }
            used.insert("\(device.uid)#\(channel)")
            try? calibration.setSeatMicrophone(seat.id, MultichannelSeatMicrophone(
                deviceUID: device.uid, channelIndex: channel, calibration: nil))
        }
    }

    /// The input device of one seat's microphone (E24 S5b2). Devices other than the first make the pass use timing chirps.
    func setSeatDevice(_ seatID: UUID, uid: String) {
        guard let seat = calibration.seats.first(where: { $0.id == seatID }) else { return }
        let current = seat.microphone
        do {
            try calibration.setSeatMicrophone(seatID, MultichannelSeatMicrophone(
                deviceUID: uid, channelIndex: current?.channelIndex ?? 0, calibration: current?.calibration))
        } catch { message = error.localizedDescription }
    }

    func setSeatChannel(_ seatID: UUID, channel: Int) {
        guard let seat = calibration.seats.first(where: { $0.id == seatID }),
              let device = microphone.selectedInputDevice else { return }
        let current = seat.microphone
        do {
            try calibration.setSeatMicrophone(seatID, MultichannelSeatMicrophone(
                deviceUID: current?.deviceUID ?? device.uid, channelIndex: max(0, channel), calibration: current?.calibration))
        } catch { message = error.localizedDescription }
    }

    /// A separate calibration file per seat; the seat is measured again to use it.
    func importSeatCalibration(_ seatID: UUID, text: String, sourceName: String?) {
        guard let seat = calibration.seats.first(where: { $0.id == seatID }), let current = seat.microphone else { return }
        do {
            let parsed = try RoomCorrectionMicrophoneCalibrationParser().parse(text, sourceName: sourceName)
            try calibration.setSeatMicrophone(seatID, MultichannelSeatMicrophone(
                deviceUID: current.deviceUID, channelIndex: current.channelIndex, calibration: parsed))
        } catch { message = error.localizedDescription }
    }

    func clearSeatCalibration(_ seatID: UUID) {
        guard let seat = calibration.seats.first(where: { $0.id == seatID }), let current = seat.microphone else { return }
        try? calibration.setSeatMicrophone(seatID, MultichannelSeatMicrophone(
            deviceUID: current.deviceUID, channelIndex: current.channelIndex, calibration: nil))
    }

    func removeSeat(_ id: UUID) {
        do { try calibration.removeSeat(id); invalidateDesign(); syncMeasurementChoices() }
        catch { message = error.localizedDescription }
    }

    /// Measures every missing seat and source. The seat measurer owns the loop and, with one microphone per seat,
    /// captures all pending seats in a single pass per source. Playback is stopped first (measurement needs the
    /// output to itself) and the reason is shown.
    func measureAll() async {
        guard !isMeasuring else { return }
        isMeasuring = true
        defer { isMeasuring = false; syncMeasurementChoices() }
        // The controller stops playback itself (E24 S2); its notice is shown under the button.
        message = nil
        let pending = calibration.seatsWithPendingWork().compactMap { seat in
            calibration.seats.firstIndex { $0.id == seat.id }
        }
        guard !pending.isEmpty else { return }
        await measureThroughServices(pending)
    }

    /// The Measure button: runs `measureAll` as a task Stop can cancel.
    func startMeasuring() {
        guard !isMeasuring else { return }
        measureTask = Task { await measureAll() }
    }

    func startRemeasure(seatID: UUID) {
        guard !isMeasuring else { return }
        measureTask = Task { await remeasure(seatID: seatID) }
    }

    /// Re-measure one seat: its records are dropped and the seat measurer measures them again (K = 1 with that seat's
    /// own microphone in per-seat mode).
    func remeasure(seatID: UUID) async {
        guard !isMeasuring, let index = calibration.seats.firstIndex(where: { $0.id == seatID }) else { return }
        isMeasuring = true
        defer { isMeasuring = false; syncMeasurementChoices() }
        message = nil
        do {
            for source in calibration.sources { try calibration.remeasure(seatID: seatID, source: source) }
            invalidateDesign()
        } catch { message = error.localizedDescription; return }
        await measureThroughServices([index])
    }

    private func measureThroughServices(_ indices: [Int]) async {
        let rate = engine.selectedOutputDevice?.nominalSampleRate ?? flow.choices.sampleRate ?? 48_000
        do {
            _ = try await seats.measureSeats(indices, sampleRate: rate)
        } catch is CancellationError {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    func cancelMeasurement() {
        measureTask?.cancel()
        calibration.cancelMeasurement()
        syncMeasurementChoices()
    }

    /// E12 S11: set from `e12.setup-flow`; tests switch it on directly. Off leaves verdicts and the limit out.
    var verdictsEnabled = FeatureFlags().isEnabled(.setupFlow)

    /// One verdict per included seat that has any measurement, worst source wins.
    var seatVerdicts: [SeatMeasurementVerdict] {
        guard verdictsEnabled else { return [] }
        return calibration.seats.filter { $0.included && $0.weight > 0 }.compactMap { seat in
            let entries = calibration.sources.compactMap { source in
                calibration.measurements.last { $0.seatID == seat.id && $0.source == source }
                    .map { (source: source.displayName, quality: $0.channel.quality) }
            }
            return MeasurementVerdictRules.verdict(forSeat: entries).map { SeatMeasurementVerdict(seatName: seat.name, verdict: $0) }
        }
    }

    /// The correction's upper edge while the microphone has no calibration file; nil when a file lifts it or the flag is off.
    var correctionLimitHz: Double? {
        guard verdictsEnabled else { return nil }
        return SystemSetupCorrectionLimit.limitHz(
            calibrationFile: microphone.microphoneCalibration?.sourceName,
            overrideHz: flow.choices.correctionLimitOverrideHz)
    }

    private func syncMeasurementChoices() {
        var choices = flow.choices
        measureProgress.apply(to: &choices)
        choices.seatVerdicts = verdictsEnabled ? seatVerdicts : nil
        flow.choices = choices
    }

    /// New or removed measurements make the alignment stale: revert the trial and ask again.
    private func invalidateDesign() {
        if flow.choices.correctionApplied { revertCorrection() }
        if flow.choices.bassApplied { revertBass() }
        if flow.choices.alignmentApplied { revertAlignment() }
        alignment = nil
        bass = nil
        monoBass = nil
        correctionIsPrepared = false
        seatPredictions = []
        correctionPrediction = nil
    }

    // MARK: Alignment

    /// E25 S4: two channels in use, so the feeds are what is aligned and calibration lands in the stereo session.
    private var usesFeedSession: Bool { SystemSetupAdaptiveSteps.isFeedSession(arrangement) }

    /// Class-aware text for the Alignment step: the receiver reason in place of subwoofer controls, or the feed note.
    var alignmentSubNote: String? { SystemSetupAdaptiveSteps.alignmentSubNote(arrangement) }
    var bassStepMode: SystemSetupBassStepMode? { SystemSetupAdaptiveSteps.bassMode(arrangement) }
    var receiverAdvice: String? { SystemSetupAdaptiveSteps.receiverAdvice(arrangement) }
    /// The measurement suite's name for a source: a downstream sub is "not separable" from its feed.
    func sourceLabel(_ source: MultichannelCalibrationSource) -> String {
        SystemSetupAdaptiveSteps.measuredSourceLabel(source, arrangement: arrangement)
    }
    var correctionNote: String? { SystemSetupAdaptiveSteps.correctionNote(arrangement) }

    /// The arrangement with `edit` applied to its stereo alignment, validated by the compiler, stored and sent to the
    /// engine. Rolls the stored arrangement back when the compiler or the engine refuses.
    private func editStereoAlignment(_ edit: (inout StereoBassAlignment) -> Void) throws {
        guard var updated = flow.choices.arrangement else { return }
        let previous = updated
        var alignment = updated.stereoAlignment ?? StereoBassAlignment()
        edit(&alignment)
        updated.stereoAlignment = alignment
        let compiled: CompiledArrangement
        switch SystemArrangementCompiler.compile(updated, preserving: nil) {
        case .success(let value): compiled = value
        case .failure(let issue): throw SystemSetupApplyError(issue.errorDescription ?? "This arrangement cannot be used.")
        }
        try profiles.replaceSelectedSystemArrangement(updated)
        do { try engine.applyStereoAlignment(compiled.stereoAlignment) } catch {
            try? profiles.replaceSelectedSystemArrangement(previous)
            throw error
        }
        flow.choices.arrangement = updated
    }

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
        if usesFeedSession {
            guard let alignment, let feeds = SystemSetupAdaptiveSteps.feedCalibration(from: alignment) else {
                message = "Work out the alignment first."
                return
            }
            do {
                try editStereoAlignment { $0.left = feeds.left; $0.right = feeds.right }
                flow.choices.alignmentApplied = true
                message = nil
            } catch { message = error.localizedDescription }
            return
        }
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
        if usesFeedSession {
            let before = snapshot.systemArrangement?.stereoAlignment
            do {
                try editStereoAlignment { $0.left = before?.left ?? SpeakerFeedCalibration(); $0.right = before?.right ?? SpeakerFeedCalibration() }
                flow.choices.alignmentApplied = false
            } catch { message = "Restoring the previous alignment failed: \(error.localizedDescription)" }
            return
        }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            flow.choices.alignmentApplied = false
        } catch {
            message = "Restoring the previous alignment failed: \(error.localizedDescription)"
        }
    }

    // MARK: Bass

    var hasSubwoofer: Bool { flow.choices.hasDspSubwoofer }

    /// Joint bass design (E10) for the measured seats. E10's mixed-phase flag has been removed, so
    /// the joint optimiser is always allowed here; without a subwoofer the step is skipped.
    func computeBass() {
        guard let rate = flow.choices.sampleRate else { return }
        if bassStepMode == .monoBass {
            do {
                monoBass = try SystemSetupMonoBassDesign.make(
                    seats: calibration.seats, measurements: calibration.measurements, sampleRate: rate)
                message = nil
            } catch {
                monoBass = nil
                message = error.localizedDescription
            }
            return
        }
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

    /// Installs the bass step. The sub gain, delay and polarity go to the profile as before; with the unified graph and an
    /// enabled profile the optimiser's low-frequency grids also install on the main and sub lanes through the lane plan
    /// (composed with the room design when Correction already ran), so the step is audible.
    /// Class C trial: the designed crossover frequency goes to bass management and the slope to the stereo session.
    func applyMonoBass() {
        guard let design = monoBass else {
            message = "Work out the bass design first."
            return
        }
        let before = profiles.selectedSystemProfile?.state.bassManagement ?? engine.bassManagementConfiguration
        var target = before
        target.frequencyHz = min(max(design.crossoverHz, SystemSetupTopologyPreset.crossoverRangeHz.lowerBound),
                                 SystemSetupTopologyPreset.crossoverRangeHz.upperBound)
        do {
            try profiles.replaceSelectedSystemBassManagement(target)
            do { try editStereoAlignment { $0.monoBassFilter = design.filter } } catch {
                try? profiles.replaceSelectedSystemBassManagement(before)
                throw error
            }
            bassManagementBeforeMono = before
            flow.choices.bassApplied = true
            message = nil
        } catch { message = error.localizedDescription }
    }

    func revertMonoBass() {
        let snapshot = flow.snapshot
        do {
            if let before = bassManagementBeforeMono ?? snapshot?.bassManagement {
                var restored = before
                restored.enabled = profiles.selectedSystemProfile?.state.bassManagement.enabled ?? before.enabled
                try profiles.replaceSelectedSystemBassManagement(restored)
            }
            let original = snapshot?.systemArrangement?.stereoAlignment?.monoBassFilter
            try editStereoAlignment { $0.monoBassFilter = original }
            bassManagementBeforeMono = nil
            flow.choices.bassApplied = false
        } catch { message = "Restoring the previous bass settings failed: \(error.localizedDescription)" }
    }

    func applyBass() async {
        if bassStepMode == .monoBass { applyMonoBass(); return }
        guard let bass, let profile = profiles.selectedSystemOutputDeviceProfile else {
            message = "Work out the bass design first."
            return
        }
        do {
            let before = profile
            let roomBefore = (engine.roomCorrectionConfiguration, selectedRoomCorrectionSummary)
            let plan = try await makeBassLanePlan(bass, profile: profile)
            let composed = try plan.map { try composeInstall(room: roomOnlyInstall, bass: $0) }
            if let composed { try await engine.precomputeRoomCorrectionPlans(for: composed) }
            try profiles.replaceSelectedSystemOutputDeviceProfile(try bass.applying(to: profile))
            if let composed {
                do {
                    try profiles.replaceSelectedSystemRoomCorrection(
                        RoomCorrectionConfiguration(enabled: true, lanes: composed), calibrationSummary: nil)
                } catch {
                    try? profiles.replaceSelectedSystemOutputDeviceProfile(before)
                    throw error
                }
            }
            profileBeforeBass = before
            roomBeforeBass = roomBefore
            bassLanePlan = plan
            flow.choices.bassApplied = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    func revertBass() {
        if bassStepMode == .monoBass { revertMonoBass(); return }
        do {
            if let previous = profileBeforeBass {
                try profiles.replaceSelectedSystemOutputDeviceProfile(previous)
            }
            // The room design alone when Correction ran after the bass step; otherwise what was there before.
            if bassLanePlan != nil {
                if let room = roomOnlyInstall {
                    try profiles.replaceSelectedSystemRoomCorrection(
                        RoomCorrectionConfiguration(enabled: true, lanes: room), calibrationSummary: nil)
                } else if let before = roomBeforeBass {
                    try profiles.replaceSelectedSystemRoomCorrection(before.configuration, calibrationSummary: before.summary)
                }
            }
            bassLanePlan = nil
            roomBeforeBass = nil
            profileBeforeBass = nil
            flow.choices.bassApplied = false
        } catch {
            message = "Restoring the previous bass settings failed: \(error.localizedDescription)"
        }
    }

    private var selectedRoomCorrectionSummary: RoomCorrectionCalibrationSummary? {
        profiles.systemProfiles.first { $0.id == profiles.selectedSystemProfileID }?.state.roomCorrectionCalibration
    }

    /// The lane layout of the enabled profile on the selected output, or nil on the filter path (legacy kernel, no profile).
    private func laneLayout(profile: OutputDeviceProfileConfiguration) throws
        -> (shape: UnifiedGraphLayoutShape, subs: Int)? {
        guard engine.unifiedGraphEnabled, profile.enabled, let output = engine.selectedOutputDevice else { return nil }
        let routePlan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices, sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid, bassManagementEnabled: engine.bassManagementConfiguration.enabled)
        guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else { return nil }
        return (shape, Int(routePlan.subwooferCount))
    }

    private func makeBassLanePlan(
        _ bass: SystemSetupBassDesign, profile: OutputDeviceProfileConfiguration
    ) async throws -> RoomCorrectionBassApplyPlan? {
        guard bass.mode == .jointOptimised, let layout = try laneLayout(profile: profile) else { return nil }
        return try bass.lanePlan(
            frontLeft: layout.shape.frontLeft, frontRight: layout.shape.frontRight,
            programLaneCount: layout.shape.laneCount, subwooferCount: layout.subs,
            latencyMode: roomOnlyInstall?.design.latencyMode ?? correctionMode.latencyMode)
    }

    /// The lanes to install: the room design and the bass grids composed (either may be absent).
    private func composeInstall(room: RoomCorrectionLaneInstall?, bass: RoomCorrectionBassApplyPlan?) throws -> RoomCorrectionLaneInstall {
        let layoutSource = room.map { ($0.programLaneCount, $0.subwooferCount) }
            ?? bass.map { ($0.design.laneCount - $0.subLanes.count, $0.subLanes.count) }
        guard let (program, subs) = layoutSource else { throw RoomCorrectionLaneComposerError.nothingToCompose }
        return try RoomCorrectionLaneComposer.compose(
            room: room, bass: bass, name: room?.name ?? "Guided Setup Bass", programLaneCount: program, subwooferCount: subs)
    }

    // MARK: Correction

    /// Builds the flow's Room Correction project from the seat records (no second measurement),
    /// then designs with the Room Correction workspace's own path.
    func prepareCorrection() {
        guard let rate = flow.choices.sampleRate, let systemID = profiles.selectedSystemProfileID else { return }
        do {
            let input = microphone.selectedInputDevice
            let sweep = microphone.sweepSettings(sampleRate: rate, levelDBFS: flow.choices.sweepLevelDBFS)
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

    /// Trial apply. With the unified graph and an enabled speaker profile the wizard designs one grid per front lane over
    /// the seat impulse responses, precomputes the plan at every rate the output exposes, and deploys the lanes (mixed phase
    /// in music mode when the plan's latency fits the budget at every rate; verification still gates saving). Otherwise
    /// (legacy kernel, no profile) it falls back to the stereo minimum-phase filter through the project controller.
    func applyCorrection() async {
        if let reason = MeasurementVerdictRules.blockingReason(flow.choices.seatVerdicts) {
            message = reason
            return
        }
        do {
            if !correctionIsPrepared { prepareCorrection() }
            guard correctionIsPrepared else { return }
            try roomProjects.setTarget(correctionTarget.curve)
            if let roomInstall = try await makeLaneInstall() {
                let install = try composeInstall(room: roomInstall, bass: bassLanePlan)
                try await engine.precomputeRoomCorrectionPlans(for: install)
                let rates = engine.selectedOutputDevice?.correctionSampleRates ?? [flow.choices.sampleRate ?? 48_000]
                var mixed = false
                var finalInstall = install
                if correctionMode == .music {
                    mixed = try rates.allSatisfy { rate in
                        RoomCorrectionLaneInstall.latencyFits(
                            try engine.roomCorrectionRateCache.plan(for: install.design, sampleRate: rate), mode: install.design.latencyMode)
                    }
                }
                var finalRoom = roomInstall
                if !mixed, install.design.latencyMode.isMixedPhase {
                    finalRoom = try await makeLaneInstall(forceMode: .video) ?? roomInstall
                    finalInstall = try composeInstall(room: finalRoom, bass: bassLanePlan)
                    try await engine.precomputeRoomCorrectionPlans(for: finalInstall)
                }
                roomOnlyInstall = finalRoom
                abxRooms = nil
                try profiles.replaceSelectedSystemRoomCorrection(
                    RoomCorrectionConfiguration(enabled: true, lanes: finalInstall), calibrationSummary: nil)
                flow.choices.designKind = mixed ? .mixedPhase : .minimumPhase
                seatPredictions = []
                if let frequencies = try? RoomCorrectionCore.gridFrequencies() {
                    correctionPrediction = .grids(frequenciesHz: frequencies, correctionDB: finalRoom.design.lanes.map(\.grid.correctionDB))
                }
            } else {
                let design = try roomProjects.generateDesign(
                    parameters: SystemSetupCorrectionPlan.parameters(limitHz: correctionLimitHz), name: "Guided Setup \(correctionTarget.title)")
                let report = try roomProjects.verification(for: design)
                try roomProjects.deploySelectedDesign()
                seatPredictions = SystemSetupSeatPrediction.make(from: report)
                if let predicted = design.predictedLeftResponse, let measured = roomProjects.project?.aggregate?.leftResponse {
                    correctionPrediction = .responses(predicted: predicted, measured: measured)
                } else {
                    correctionPrediction = nil
                }
                flow.choices.designKind = correctionMode.designKind(mixedPhaseAllowed: false)
            }
            flow.choices.correctionApplied = true
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// The lane-plan form of the correction, or nil when the filter path applies (legacy kernel, no enabled profile).
    private func makeLaneInstall(forceMode: RoomCorrectionLatencyMode? = nil) async throws -> RoomCorrectionLaneInstall? {
        guard engine.unifiedGraphEnabled, let rate = flow.choices.sampleRate,
              let profile = profiles.selectedSystemOutputDeviceProfile, profile.enabled,
              let output = engine.selectedOutputDevice else { return nil }
        let routePlan = try profile.makeLivePlan(
            availableDevices: engine.outputDevices, sampleRate: output.nominalSampleRate,
            selectedOutputUID: output.uid, bassManagementEnabled: engine.bassManagementConfiguration.enabled)
        guard let shape = UnifiedGraphLayoutShape(roles: routePlan.programLayout.roles) else { return nil }
        let included = calibration.seats.filter { $0.included && $0.weight > 0 }
        guard !included.isEmpty else { return nil }
        let mode = forceMode ?? correctionMode.latencyMode
        let limitHz = correctionLimitHz
        let gridFrequencies = limitHz == nil ? [] : try RoomCorrectionCore.gridFrequencies()
        var lanes: [RoomCorrectionLaneDesign] = []
        for (source, lane) in [(MultichannelCalibrationSource.speaker(.frontLeft), shape.frontLeft),
                               (.speaker(.frontRight), shape.frontRight)] {
            guard calibration.sources.contains(source), let lane else { continue }
            let seats = try included.map { seat -> RoomCorrectionCore.SeatImpulseResponse in
                guard let measurement = calibration.measurements.last(where: { $0.seatID == seat.id && $0.source == source }) else {
                    throw SystemSetupBassError.missingMeasurement(seat: seat.name, source: source.displayName)
                }
                guard let arrival = measurement.channel.quality.directArrivalSeconds, arrival.isFinite, arrival >= 0 else {
                    throw SystemSetupBassError.missingArrival(source: source.displayName)
                }
                return .init(samples: measurement.channel.impulseResponse, arrivalFrames: arrival * rate, weight: seat.weight)
            }
            var grid = try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionCore.designGrid(seats: seats, sampleRate: rate, mainSeat: 0, mode: mode)
            }.value
            if let limitHz { SystemSetupCorrectionLimit.apply(to: &grid, frequenciesHz: gridFrequencies, limitHz: limitHz) }
            lanes.append(RoomCorrectionLaneDesign(lane: lane, grid: grid))
        }
        guard !lanes.isEmpty else { return nil }
        let design = RoomCorrectionMultiLaneDesign(
            latencyMode: mode, laneCount: shape.laneCount + Int(routePlan.subwooferCount), lanes: lanes)
        return RoomCorrectionLaneInstall(
            name: "Guided Setup \(correctionTarget.title)", design: design, programLaneCount: shape.laneCount,
            subwooferCount: Int(routePlan.subwooferCount))
    }

    func revertCorrection() {
        guard let snapshot = flow.snapshot else { return }
        do {
            try profiles.replaceSelectedSystemRoomCorrection(
                snapshot.roomCorrection, calibrationSummary: snapshot.roomCorrectionCalibration)
            // Bass Apply stays in force: put its grids back on their own.
            if let bassPlan = bassLanePlan {
                try profiles.replaceSelectedSystemRoomCorrection(
                    RoomCorrectionConfiguration(enabled: true, lanes: try composeInstall(room: nil, bass: bassPlan)),
                    calibrationSummary: nil)
            }
            roomOnlyInstall = nil
            abxRooms = nil
            flow.choices.correctionApplied = false
            seatPredictions = []
            correctionPrediction = nil
        } catch {
            message = "Restoring the previous correction failed: \(error.localizedDescription)"
        }
    }

    // MARK: Verify (design note 7)

    /// The main seat's predicted error after correction, from the Correction step.
    var predictedMainSeatErrorDB: Double { seatPredictions.first?.rmsErrorAfterDB ?? 0 }

    /// What the live check compares: the installed plan's lane-0 stage and latency (what the graph actually runs) at the
    /// main seat's measured room, against a sweep played through the running graph. Falls back to the published filter on
    /// the stereo path.
    func verificationCandidate(sampleRate rate: Double) throws -> RoomCorrectionDeployCandidate {
        guard let mainSeat = roomProjects.positions.first else {
            throw SystemSetupVerificationError.couldNotMeasure("No measured main seat is available.")
        }
        let criteria = RoomCorrectionPostApplyCriteria()
        let impulse = mainSeat.left.impulseResponse
        var peak = 0
        for index in impulse.indices where abs(impulse[index]) > abs(impulse[peak]) { peak = index }
        let plan: RoomCorrectionLanePlan
        let stage: RoomCorrectionLaneStage
        var measuredLane = 0
        var kind: RoomCorrectionDeployCandidate.Kind = .minimumPhase
        if let installed = engine.installedRoomCorrectionPlan(sampleRate: rate), let first = installed.stages.first {
            plan = installed
            measuredLane = first.laneMask.trailingZeroBitCount
            stage = installed.stages.first { $0.laneMask & (1 << UInt64(measuredLane)) != 0 } ?? first
            kind = flow.choices.designKind == .mixedPhase ? .mixedPhase : .minimumPhase
        } else {
            guard let design = roomProjects.selectedDesign else {
                throw SystemSetupVerificationError.couldNotMeasure("No correction design is selected.")
            }
            let filter = try design.deploymentFilter()
            stage = RoomCorrectionLaneStage(laneMask: 1, taps: filter.leftTaps)
            plan = RoomCorrectionLanePlan(
                designID: design.id, sampleRate: rate, stages: [stage],
                declaredLatencyFrames: filter.declaredLatencyFrames, laneCount: 2)
        }
        let predicted: RoomCorrectionBandedResponse
        if let paths = try bassPredictionPaths(plan: plan, measuredLane: measuredLane, sampleRate: rate), paths.count > 1 {
            predicted = try RoomCorrectionPostApplyVerifier.prediction(
                paths: paths, declaredLatencyFrames: plan.declaredLatencyFrames, sampleRate: rate, criteria: criteria)
        } else {
            predicted = try RoomCorrectionPostApplyVerifier.prediction(
                roomImpulse: impulse, roomArrivalFrames: Double(peak), stage: stage,
                declaredLatencyFrames: plan.declaredLatencyFrames, sampleRate: rate, criteria: criteria)
        }
        return RoomCorrectionDeployCandidate(
            designID: plan.designID.uuidString, kind: kind, sampleRate: rate, lanePlan: plan,
            latencyMode: correctionMode.latencyMode, measuredLane: measuredLane,
            predictionCheck: RoomCorrectionPredictionCheck(passed: true, rmsErrorDB: predictedMainSeatErrorDB, reasons: []),
            predicted: predicted, sweepFrames: Int(2 * rate))
    }

    /// With the joint bass installed, a sweep on the measured lane reaches the main seat through that lane's main and through
    /// every subwoofer (the generator sits ahead of bass management): one path each, from the seat's own measurements.
    /// Nil when no bass design is installed. The bass-management crossover is not modelled (an E22 bench item).
    private func bassPredictionPaths(
        plan: RoomCorrectionLanePlan, measuredLane: Int, sampleRate rate: Double
    ) throws -> [RoomCorrectionPredictionPath]? {
        guard let bassPlan = bassLanePlan, let bass, let seat = calibration.seats.first(where: { $0.included && $0.weight > 0 })
        else { return nil }
        // The installed alignment delay on the lane: the room's plus the bass design's.
        let laneDelays = try composeInstall(room: roomOnlyInstall, bass: bassPlan).laneDelays
        let sources = bass.channelSources.enumerated().map { index, source -> RoomCorrectionJointBassSource in
            let measurement = calibration.measurements.last { $0.seatID == seat.id && $0.source == source }
            var item = RoomCorrectionJointBassSource(
                isSubwoofer: { if case .subwoofer = source { return true } else { return false } }(),
                impulse: measurement?.channel.impulseResponse,
                directArrivalSeconds: measurement?.channel.quality.directArrivalSeconds)
            if item.isSubwoofer {
                let row = bass.rows[index]
                item.gainDB = row.gainDB
                item.delayMilliseconds = row.delayMilliseconds
                item.polarityInverted = row.polarityInverted
            }
            return item
        }
        return RoomCorrectionPostApplyVerifier.jointBassPaths(
            sources: sources, mainLanes: bassPlan.mainLanes, subLanes: bassPlan.subLanes, plan: plan,
            measuredLane: measuredLane, laneDelays: laneDelays, sampleRate: rate)
    }

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
            var unavailable = error is SystemSetupVerificationError
            if case .timedOut? = error as? SystemSetupVerificationError { unavailable = false }
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

    // MARK: Compare by ear (E24 S9, blind ABX)

    /// Why the ABX cannot open right now, or nil.
    var abxUnavailableReason: String? {
        guard flow.choices.correctionApplied, roomOnlyInstall != nil else { return "Apply the correction first." }
        if abxPreparing { return "Preparing the two designs." }
        return abxPlayer.unavailableReason
    }

    /// Opens the blind ABX of minimum against mixed phase: the applied design is kept, the other is designed from the
    /// same seats, both are composed with the bass design and cached at every output rate, then matched on level and
    /// latency at the session rate. The profile is not changed; the engine plays the candidates as an override.
    func openABX() async {
        guard abx == nil, let applied = roomOnlyInstall else { return }
        if let reason = abxUnavailableReason { message = reason; return }
        abxPreparing = true
        defer { abxPreparing = false }
        do {
            let appliedIsMixed = flow.choices.designKind == .mixedPhase
            let minimum: RoomCorrectionLaneInstall
            let mixed: RoomCorrectionLaneInstall
            if let cached = abxRooms {
                (minimum, mixed) = cached
            } else if appliedIsMixed {
                mixed = applied
                guard let other = try await makeLaneInstall(forceMode: .video) else { throw RoomCorrectionABXError.noProgramLanes }
                minimum = other
            } else {
                minimum = applied
                guard let other = try await makeLaneInstall(
                    forceMode: correctionMode == .music ? .defaultMusic : .music50ms) else { throw RoomCorrectionABXError.noProgramLanes }
                mixed = other
            }
            let installA = try composeInstall(room: minimum, bass: bassLanePlan)
            let installB = try composeInstall(room: mixed, bass: bassLanePlan)
            try await engine.precomputeRoomCorrectionPlans(for: installA)
            try await engine.precomputeRoomCorrectionPlans(for: installB)
            let rates = engine.selectedOutputDevice?.correctionSampleRates ?? [flow.choices.sampleRate ?? 48_000]
            let rate = engine.selectedOutputDevice?.nominalSampleRate ?? flow.choices.sampleRate ?? 48_000
            abxMixedFitsEveryRate = try rates.allSatisfy {
                RoomCorrectionLaneInstall.latencyFits(
                    try engine.roomCorrectionRateCache.plan(for: installB.design, sampleRate: $0), mode: installB.design.latencyMode)
            }
            let planA = try engine.roomCorrectionRateCache.plan(for: installA.design, sampleRate: rate)
            let planB = try engine.roomCorrectionRateCache.plan(for: installB.design, sampleRate: rate)
            let common = Set(installA.design.lanes.map(\.lane)).intersection(installB.design.lanes.map(\.lane))
                .filter { $0 < installA.programLaneCount }.sorted()
            let match = try RoomCorrectionABXMatch.make(a: planA, b: planB, programLanes: common)
            let listening = calibration.seats.filter { $0.included && $0.weight > 0 }
            abxRooms = (minimum, mixed)
            abx = try RoomCorrectionABXController(
                player: abxPlayer, a: installA, b: installB, match: match, seatCount: listening.count,
                seatNames: listening.map(\.name), logDirectory: abxDirectory, switchHold: abxSwitchHold)
            message = nil
        } catch {
            message = error.localizedDescription
        }
    }

    /// Closing without Keep returns to the applied design.
    func closeABX() {
        abx?.close()
        abx = nil
    }

    /// Why "Keep B" (mixed phase) is not offered, or nil.
    var keepMixedPhaseUnavailableReason: String? {
        abxMixedFitsEveryRate ? nil : "Mixed phase does not fit the latency budget at every rate this output supports."
    }

    /// Keep A (minimum phase) or Keep B (mixed phase) after a finished run (Q15). The kept design is what Save stores.
    /// Keeping the applied design changes nothing. Keeping the other one writes its install as Apply does, clears the
    /// verification and returns to Verify, because that design has not been verified.
    func keepABXCandidate(_ kind: SystemSetupDesignKind) {
        guard let controller = abx, controller.phase == .finished, let rooms = abxRooms else { return }
        if kind == .mixedPhase, let reason = keepMixedPhaseUnavailableReason { message = reason; return }
        controller.close()
        abx = nil
        guard kind != flow.choices.designKind else { return }
        do {
            let install = try composeInstall(room: kind == .mixedPhase ? rooms.mixed : rooms.minimum, bass: bassLanePlan)
            try profiles.replaceSelectedSystemRoomCorrection(
                RoomCorrectionConfiguration(enabled: true, lanes: install), calibrationSummary: nil)
            roomOnlyInstall = kind == .mixedPhase ? rooms.mixed : rooms.minimum
            abxRooms = (rooms.minimum, rooms.mixed)
            flow.keptDifferentDesign(kind)
            verificationReport = nil
            verificationSummary = nil
            message = "Verify the kept design before saving."
            persistSession()
        } catch {
            message = "Keeping that design failed: \(error.localizedDescription)"
        }
    }

    // MARK: Save (design notes 7 and 9)

    var savesAsNotVerified: Bool { flow.savesAsNotVerified }

    /// Saves the verified (or, for minimum phase, "Not verified") system as a profile and ends the flow.
    func save() {
        do {
            try flow.finish()
            let name = SystemSetupSaveNaming.profileName(flow.choices.profileName, notVerified: flow.savesAsNotVerified)
            let id = profiles.saveCurrentSystemProfile(named: name)
            // E12 S15 (G14): a passing verification is stored with the saved profile, so the Overview reads "verified".
            if flow.choices.verificationPassed == true,
               let design = profiles.selectedSystemProfile?.state.roomCorrectionCalibration?.activeDesignID {
                profiles.recordSystemVerification(designID: design)
            }
            savedProfileName = profiles.systemProfiles.first(where: { $0.id == id })?.name ?? name
            quickFinished = flow.preset == .quick
            summary = makeSummary()
            sessions.delete(key: sessionKey)
            discardKeptMeasurements()
            message = nil
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
    }

    private func makeSummary() -> SystemSetupSummary {
        var arrangementText: String?
        if let arrangement {
            let speakers = arrangement.speakers.count
            let subs = arrangement.subwooferCount
            arrangementText = "\(speakers) \(speakers == 1 ? "speaker" : "speakers")"
                + (subs > 0 ? " and \(subs) \(subs == 1 ? "subwoofer" : "subwoofers")" : "")
        }
        return SystemSetupSummary.make(
            profileName: savedProfileName ?? flow.choices.profileName, outputName: engine.selectedOutputDevice?.name,
            sampleRate: flow.choices.sampleRate, arrangementText: arrangementText,
            alignmentApplied: flow.choices.alignmentApplied, bassApplied: flow.choices.bassApplied,
            correctionApplied: flow.choices.correctionApplied, designKind: flow.choices.designKind,
            seatCount: flow.choices.seatNames.count, notVerified: flow.savesAsNotVerified,
            verificationHeadline: verificationSummary?.headline)
    }

    /// The summary's "Compare before and after": the same audition switch as the toolbar and the Playback menu.
    func toggleBeforeAfter() {
        do {
            try engine.setAuditionMode(comparingBefore ? .processed : .reference)
            comparingBefore.toggle()
            message = nil
        } catch { message = error.localizedDescription }
    }

    /// Leaves the audition on the processed sound when the summary closes.
    func endComparison() {
        guard comparingBefore else { return }
        try? engine.setAuditionMode(.processed)
        comparingBefore = false
    }

    /// Imports the microphone's calibration file inside the Microphone step.
    func importMicrophoneCalibration(text: String, sourceName: String?) {
        do {
            let imported = try microphone.importMicrophoneCalibration(text: text, sourceName: sourceName)
            flow.choices.microphoneCalibrationFile = imported.sourceName ?? sourceName
            message = nil
            persistSession()
        } catch { message = error.localizedDescription }
    }

    func clearMicrophoneCalibration() {
        microphone.clearMicrophoneCalibration()
        flow.choices.microphoneCalibrationFile = nil
        persistSession()
    }

    func setProfileName(_ name: String) { flow.choices.profileName = name; persistSession() }

    func acceptSweepLevel(measuredSPLdBC: Double) {
        flow.choices.sweepLevelDBFS = level.sweepLevel(measuredSPLdBC: measuredSPLdBC)
    }

    func next() {
        do {
            // The quick preset has no Speakers step: the arrangement derived at the start is applied when Output is left.
            if flow.step == .topology || (flow.step == .output && flow.preset == .quick) { try applyArrangement() }
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

    /// E12 S10: turns a quick run into the full flow in place (same choices, same measurements).
    func openFullSetup() {
        do { try flow.openFullSetup(); message = nil; persistSession() } catch { message = error.localizedDescription }
    }

    /// E12 S10: after a quick run saved, starts the full flow over the state the quick run left.
    func beginFullAfterQuick() {
        quickFinished = false
        savedProfileName = nil
        begin(preset: .full)
    }

    func skip() {
        do { try flow.skip(); persistSession() } catch let refusal as SystemSetupRefusal { message = refusal.reason } catch {}
    }

    /// True once anything has been measured: Cancel then asks first, because it discards the measurements.
    var cancelNeedsConfirmation: Bool { !flow.choices.measurementIDs.isEmpty }

    private func stopEverythingRunning() {
        closeABX()
        stopNoise()
        calibration.cancelMeasurement()
        verificationTask?.cancel()
    }

    /// Test seam: replaces the restore step so a failed restore can be exercised.
    var restoreOverride: ((PlaybackSystemState) -> String?)?

    /// Puts the settings from before the flow back. Returns why that failed, or nil.
    private func restore(_ snapshot: PlaybackSystemState) -> String? {
        if let restoreOverride { return restoreOverride(snapshot) }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(nil)
            try profiles.replaceSelectedSystemBassManagement(snapshot.bassManagement)
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            try profiles.replaceSelectedSystemArrangement(snapshot.systemArrangement)
            try engine.applyStereoAlignment(snapshot.systemArrangement.flatMap { try? SystemArrangementCompiler.compile($0, preserving: snapshot.outputDeviceProfile).get().stereoAlignment })
            try profiles.replaceSelectedSystemRoomCorrection(
                snapshot.roomCorrection, calibrationSummary: snapshot.roomCorrectionCalibration)
            return nil
        } catch {
            return "Restoring the previous settings failed: \(error.localizedDescription)"
        }
    }

    /// Cancel: restores the settings from before the flow and discards the session and its measurements.
    func cancel() {
        stopEverythingRunning()
        sessions.delete(key: sessionKey)
        discardKeptMeasurements()
        endComparison()
        guard let snapshot = try? flow.cancel() else { return }
        restoreFailure = restore(snapshot)
    }

    /// E12 S29, "Close and continue later" (decision 32): restores the settings from before the flow and keeps the
    /// session and the measurements. The trial stages are noted so resuming applies them again.
    func closeForLater() {
        guard flow.phase == .running, let snapshot = flow.snapshot else { cancel(); return }
        stopEverythingRunning()
        endComparison()
        var stages: [SystemSetupDesignStage] = []
        if flow.choices.alignmentApplied { stages.append(.alignment) }
        if flow.choices.bassApplied { stages.append(.bass) }
        if flow.choices.correctionApplied { stages.append(.correction) }
        flow.choices.trialToReapply = stages.isEmpty ? nil : stages
        flow.choices.correctionModeID = correctionMode.rawValue
        flow.choices.correctionTargetID = correctionTarget.id
        flow.choices.crossoverHz = topologyPreset.crossoverHz
        flow.choices.crossoverSlope = topologyPreset.slope
        if let archive = calibration.campaignArchiveForKeeping() {
            do { try keptCampaigns.save(archive); flow.choices.keptMeasurements = true } catch {
                flow.choices.keptMeasurements = nil
            }
        }
        persistSession()
        restoreFailure = restore(snapshot)
    }

    struct SystemSetupApplyError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

}
