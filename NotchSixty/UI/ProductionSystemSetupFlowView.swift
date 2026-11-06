import SwiftUI
import UniformTypeIdentifiers

// E12 S3: the guided-setup window and its first steps (Output, Topology, Microphone and level,
// Room). Later steps arrive in S4 to S6.

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
         abxDirectory: URL? = nil) {
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
        topologyPreset = SystemSetupTopologyPreset.current(from: saved.snapshot ?? profiles.captureSystemState())
        if let topology = saved.choices.topology { topologyPreset.topology = topology }
        resumeArrangement(&saved)
        flow = saved
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
        let detected = Int(engine.selectedOutputDevice?.outputChannelCount ?? 0)
        let migrated = SystemArrangementMigration.derive(from: snapshot, detectedChannelCount: detected)
            ?? SystemSetupArrangementPlanner.arrangement(
                deviceUID: initial.outputUID ?? "", detectedChannelCount: detected, channelsInUse: 2,
                choices: SystemSetupSpeakerChoices())
        initial.arrangement = migrated
        speakerChoices = SystemSetupArrangementPlanner.choices(from: migrated)
        do {
            try flow.start(snapshot: snapshot, choices: initial)
            message = nil
        } catch let refusal as SystemSetupRefusal {
            message = refusal.reason
        } catch {
            message = error.localizedDescription
        }
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

    /// Auto-stop and output-change stops arrive here with the text to show.
    private func noiseEndedOnItsOwn(_ reason: String) {
        noiseIsPlaying = noise.isPlaying
        message = reason
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

    var measurePlaybackNotice: String? { calibration.playbackNotice }

    func prepareMeasure() {
        stopNoise()
        calibration.prepareForUse()
        syncMeasurementChoices()
    }

    func addSeat() {
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
        monoBass = nil
        correctionIsPrepared = false
        seatPredictions = []
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
            } else {
                let design = try roomProjects.generateDesign(
                    parameters: SystemSetupCorrectionPlan.defaultParameters, name: "Guided Setup \(correctionTarget.title)")
                let report = try roomProjects.verification(for: design)
                try roomProjects.deploySelectedDesign()
                seatPredictions = SystemSetupSeatPrediction.make(from: report)
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
            let grid = try await Task.detached(priority: .userInitiated) {
                try RoomCorrectionCore.designGrid(seats: seats, sampleRate: rate, mainSeat: 0, mode: mode)
            }.value
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
        func stage(_ lane: Int) -> RoomCorrectionLaneStage? {
            plan.stages.first { $0.laneMask & (1 << UInt64(lane)) != 0 }
        }
        // The installed alignment delay on the lane: the room's plus the bass design's.
        let laneDelays = try composeInstall(room: roomOnlyInstall, bass: bassPlan).laneDelays
        var paths: [RoomCorrectionPredictionPath] = []
        var mainIndex = 0
        for (index, source) in bass.channelSources.enumerated() {
            guard let measurement = calibration.measurements.last(where: { $0.seatID == seat.id && $0.source == source }),
                  let arrival = measurement.channel.quality.directArrivalSeconds else { continue }
            var path = RoomCorrectionPredictionPath(
                roomImpulse: measurement.channel.impulseResponse, arrivalFrames: arrival * rate)
            switch source {
            case .speaker:
                defer { mainIndex += 1 }
                guard bassPlan.mainLanes[mainIndex] == measuredLane else { continue }
                path.stage = stage(measuredLane)
                path.delaySeconds = laneDelays.first { $0.lane == measuredLane }?.seconds ?? 0
            case .subwoofer:
                let row = bass.rows[index]
                let range = PhysicalSubwooferCalibration.gainRangeDB
                path.stage = stage(bassPlan.subLanes[index - bassPlan.mainLanes.count])
                path.gainDB = min(range.upperBound, max(range.lowerBound, row.gainDB))
                path.delaySeconds = min(PhysicalSubwooferCalibration.delayRangeMilliseconds.upperBound, max(0, row.delayMilliseconds)) / 1_000
                path.polarityInverted = row.polarityInverted
            }
            paths.append(path)
        }
        return paths
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
                seatNames: listening.map(\.name), logDirectory: abxDirectory)
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
            if flow.step == .topology { try applyArrangement() }
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
        closeABX()
        stopNoise()
        calibration.cancelMeasurement()
        verificationTask?.cancel()
        sessions.delete(key: sessionKey)
        guard let snapshot = try? flow.cancel() else { return }
        do {
            try profiles.replaceSelectedSystemOutputDeviceProfile(nil)
            try profiles.replaceSelectedSystemBassManagement(snapshot.bassManagement)
            try profiles.replaceSelectedSystemOutputDeviceProfile(snapshot.outputDeviceProfile)
            try profiles.replaceSelectedSystemArrangement(snapshot.systemArrangement)
            try engine.applyStereoAlignment(snapshot.systemArrangement.flatMap { try? SystemArrangementCompiler.compile($0, preserving: snapshot.outputDeviceProfile).get().stereoAlignment })
            try profiles.replaceSelectedSystemRoomCorrection(
                snapshot.roomCorrection, calibrationSummary: snapshot.roomCorrectionCalibration)
        } catch {
            message = "Restoring the previous settings failed: \(error.localizedDescription)"
        }
    }

    struct SystemSetupApplyError: LocalizedError {
        let errorDescription: String?
        init(_ text: String) { errorDescription = text }
    }

}

struct ProductionSystemSetupFlowView: View {
    @StateObject private var model: SystemSetupFlowModel
    @Environment(\.dismiss) private var dismiss

    init(engine: AudioIOEngine, profiles: ProductProfileController,
         microphone: RoomCorrectionCalibrationController, calibration: MultichannelCalibrationController,
         advisor: RoomTreatmentAdvisorController) {
        _model = StateObject(wrappedValue: SystemSetupFlowModel(
            engine: engine, profiles: profiles, microphone: microphone, calibration: calibration,
            services: ProductionSystemSetupServices.production(
                engine: engine, profiles: profiles, microphone: microphone, calibration: calibration)))
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
        case .topology: SystemSetupSpeakersStep(model: model)
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
                if let arrangement = model.arrangement {
                    let detected = model.detectedChannelCount
                    Picker("Output channels in use", selection: Binding(
                        get: { arrangement.outputs.channelsInUse }, set: { model.chooseChannelCount($0) }
                    )) {
                        ForEach(SystemSetupArrangementPlanner.channelChoices(detected: detected), id: \.self) {
                            Text("\($0) channels").tag($0)
                        }
                    }
                    Text(detected > 0
                         ? "This device reports \(detected) output channels. Lower the number if you wire fewer."
                         : "This device did not report its channel count, so two channels are assumed.")
                        .font(.caption).foregroundStyle(.secondary)
                    if arrangement.outputs.channelsInUse == 2 {
                        Text("Two channels can still feed a receiver or a powered subwoofer. Describe that on the next step.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// E25 S3: layout, subwoofers and "How is bass handled?", closed by the capability card.
private struct SystemSetupSpeakersStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        let inUse = model.arrangement?.outputs.channelsInUse ?? 2
        let choices = model.speakerChoices
        VStack(alignment: .leading, spacing: 10) {
            Text("What speakers do you have?").font(.headline)
            Picker("Speaker layout", selection: Binding(get: { choices.layout }, set: { model.chooseLayout($0) })) {
                ForEach(OutputProgramLayout.allCases) { Text($0.displayName).tag($0) }
            }
            Text("How is bass handled?").font(.headline)
            ForEach(SystemSetupArrangementPlanner.bassChoices(channelsInUse: inUse, layout: choices.layout), id: \.self) { bass in
                Button { model.chooseBass(bass) } label: {
                    Label(SystemSetupArrangementPlanner.title(bass),
                          systemImage: choices.bass == bass ? "largecircle.fill.circle" : "circle")
                }
                .buttonStyle(.plain)
            }
            if choices.bass == .dspToSubOutputs || choices.bass.isDownstream {
                Stepper("Subwoofers: \(choices.subwooferCount)",
                        value: Binding(get: { choices.subwooferCount }, set: { model.chooseSubwooferCount($0) }),
                        in: 1...SystemArrangement.maxSubwoofers)
            }
            if choices.bass == .dspMonoToMains || choices.bass == .dspToSubOutputs {
                Stepper(
                    "Crossover \(Int(model.topologyPreset.crossoverHz)) Hz",
                    value: $model.topologyPreset.crossoverHz,
                    in: SystemSetupTopologyPreset.crossoverRangeHz, step: 5)
            }
            if choices.bass == .downstreamReceiver {
                Text(SystemCapabilityMatrix.receiverAdvice).font(.caption).foregroundStyle(.secondary)
            }
            if choices.bass.isDownstream {
                SystemSetupReceiverBassPicker(receiverBass: choices.receiverBass) { model.chooseReceiverBass($0) }
            }
            Divider()
            Text("What this arrangement can do").font(.headline)
            ForEach(Array(model.capabilityRows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: row.availability.isUsable ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(row.availability.isUsable ? Color.green : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.feature.displayName).font(.callout)
                        Text(row.availability.text).font(.caption).foregroundStyle(.secondary)
                        if case .unavailable(_, let fix?) = row.availability {
                            Text(fix).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }
}

/// E26 S1: declares how the receiver (or powered sub) handles bass. Quiet Zone is refused through it until this is set.
/// The crossover entry appears only for calibrated LFE out.
struct SystemSetupReceiverBassPicker: View {
    let receiverBass: ReceiverBass
    let onChange: (ReceiverBass) -> Void

    private enum Kind: Hashable { case undeclared, openPreout, calibratedLFE }
    private var kind: Kind {
        switch receiverBass {
        case .undeclared: return .undeclared
        case .openPreout: return .openPreout
        case .calibratedLFE: return .calibratedLFE
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How does it handle bass?").font(.subheadline.bold())
            Picker("Receiver bass", selection: Binding(
                get: { kind },
                set: { newKind in
                    switch newKind {
                    case .undeclared: onChange(.undeclared)
                    case .openPreout: onChange(.openPreout)
                    case .calibratedLFE: onChange(.calibratedLFE(crossoverHz: ReceiverBass.defaultCrossoverHz))
                    }
                })) {
                Text("Not set").tag(Kind.undeclared)
                Text("Open sub pre-out (no receiver crossover)").tag(Kind.openPreout)
                Text("Calibrated LFE out").tag(Kind.calibratedLFE)
            }
            if case .calibratedLFE(let hz) = receiverBass {
                Stepper(
                    "Receiver crossover \(Int(hz)) Hz",
                    value: Binding(get: { hz }, set: { onChange(.calibratedLFE(crossoverHz: $0)) }),
                    in: ReceiverBass.crossoverRangeHz, step: 5)
            }
            if !receiverBass.isDeclared {
                Text(TwoChannelAncArming.undeclaredReceiverRefusal).font(.caption).foregroundStyle(.orange)
            }
            Text(ReceiverBass.setupNote).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SystemSetupMicrophoneStep: View {
    @ObservedObject var model: SystemSetupFlowModel
    @ObservedObject private var microphone: RoomCorrectionCalibrationController
    @ObservedObject private var monitor: MeasurementInputMonitor
    @State private var splText = ""

    init(model: SystemSetupFlowModel) {
        self.model = model
        _microphone = ObservedObject(wrappedValue: model.microphone)
        _monitor = ObservedObject(wrappedValue: model.levelMonitor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Measurement microphone").font(.headline)
            Text("Notch Sixty listens through this microphone to measure your speakers. Macs ask for microphone permission the first time; audio is analysed on this Mac and never leaves it.")
                .font(.callout).foregroundStyle(.secondary)
            MeasurementMicrophoneCard(
                microphone: microphone, locked: model.noiseIsPlaying,
                onSelect: { model.selectMicrophone(uid: $0) })
            if microphone.permissionStatus == .authorized, microphone.microphoneCalibration == nil {
                Text("No calibration file. Import one in the Calibrate tab for the most accurate results.")
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
                    .disabled(microphone.selectedInputDevice == nil || model.noiseIsPlaying)
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
    @ObservedObject private var microphone: RoomCorrectionCalibrationController
    @State private var importingCalibrationSeat: UUID?

    init(model: SystemSetupFlowModel) {
        self.model = model
        _calibration = ObservedObject(wrappedValue: model.calibration)
        _microphone = ObservedObject(wrappedValue: model.microphone)
    }

    var body: some View {
        let progress = model.measureProgress
        VStack(alignment: .leading, spacing: 12) {
            Text("Measure your listening seats").font(.headline)
            Text("Each speaker plays a sweep and the microphone records it at each seat. Measure the main seat first; add seats for a wider sweet spot. Playback is stopped while measuring.")
                .font(.callout).foregroundStyle(.secondary)
            if let note = model.correctionNote {
                ForEach(calibration.sources, id: \.self) { source in
                    Text(model.sourceLabel(source)).font(.caption)
                }
                Label(note, systemImage: "info.circle").font(.callout)
            }
            if calibration.sources.isEmpty {
                Label("Choose your outputs and speakers first so the setup knows which speakers to measure.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout)
            }
            Picker("Microphones", selection: Binding(
                get: { calibration.seatMicrophoneMode }, set: { model.setSeatMicrophoneMode($0) }
            )) {
                Text("One microphone, moved between seats").tag(SeatMicrophoneMode.movedMicrophone)
                Text("One microphone per seat").tag(SeatMicrophoneMode.perSeat)
            }
            .disabled(model.isMeasuring)
            HStack {
                Text("Repeats per sweep").font(.callout)
                SweepRepeatPicker(repeatCount: $microphone.sweepRepeatCount, disabled: model.isMeasuring)
            }
            if let clock = calibration.seatClockMode {
                Text(clock.label).font(.caption).foregroundStyle(clock.isLessPrecise ? .orange : .secondary)
                if clock.isLessPrecise {
                    Text("Each device has its own clock, so timing between seats comes from a chirp the front-left speaker plays before every sweep. It is less precise than channels of one interface; keep the microphones' devices running for the whole measurement.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            MeasurementSeatsCard(
                calibration: calibration, microphone: microphone, locked: model.isMeasuring,
                onAdd: { model.addSeat() },
                onRemove: { model.removeSeat($0) },
                onSetDevice: { model.setSeatDevice($0, uid: $1) },
                onSetChannel: { model.setSeatChannel($0, channel: $1) },
                onImportCalibration: { importingCalibrationSeat = $0 },
                onClearCalibration: { model.clearSeatCalibration($0) },
                accessory: { seat in
                    HStack {
                        Image(systemName: progress.isComplete(seat) ? "checkmark.circle.fill" : "circle")
                        if let latest = calibration.measurements.last(where: { $0.seatID == seat.id }) {
                            RepeatSummaryNote(quality: latest.channel.quality)
                        }
                        if progress.isComplete(seat) {
                            Button("Re-measure") { model.startRemeasure(seatID: seat.id) }.disabled(model.isMeasuring)
                        }
                    }
                })
            HStack {
                Spacer()
                if model.isMeasuring {
                    Button("Stop") { model.cancelMeasurement() }
                } else {
                    Button(progress.isComplete ? "Measure again" : "Measure") {
                        model.startMeasuring()
                    }
                    .disabled((progress.next == nil && !progress.isComplete) || !calibration.readiness.isReady)
                }
            }
            MeasurementReadinessNote(readiness: calibration.readiness, playbackNotice: model.measurePlaybackNotice)
            ProgressView(value: model.isMeasuring ? calibration.activeMeasurementProgress : progress.fraction)
            if let next = progress.next, model.isMeasuring {
                Text("Measuring \(next.seat.name), \(next.source.displayName)").font(.caption)
            }
        }
        .onAppear { model.prepareMeasure() }
        .fileImporter(
            isPresented: Binding(get: { importingCalibrationSeat != nil }, set: { if !$0 { importingCalibrationSeat = nil } }),
            allowedContentTypes: [.plainText, .commaSeparatedText, .data]
        ) { result in
            guard let seatID = importingCalibrationSeat else { return }
            importingCalibrationSeat = nil
            guard let url = try? result.get() else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
                model.message = "Microphone calibration files must be UTF-8 text with frequency and gain columns."
                return
            }
            model.importSeatCalibration(seatID, text: text, sourceName: url.lastPathComponent)
        }
    }
}

private struct SystemSetupAlignmentStep: View {
    @ObservedObject var model: SystemSetupFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Align levels, polarity and distances").font(.headline)
            Text("Notch Sixty matches the loudness and arrival time of your speakers at the seats you measured. Apply it to hear the result; you can revert at any time and Cancel restores everything.")
                .font(.callout).foregroundStyle(.secondary)
            if let note = model.alignmentSubNote {
                Label(note, systemImage: "info.circle").font(.callout)
            }
            if let alignment = model.alignment {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        Text("Speaker").bold(); Text("Level").bold(); Text("Delay").bold()
                        Text("Polarity").bold(); Text("Distance").bold()
                    }
                    ForEach(alignment.rows) { row in
                        GridRow {
                            Text(model.sourceLabel(row.source))
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
            Text(model.bassStepMode == .monoBass ? "Share the bass between the speakers" : "Blend the subwoofer").font(.headline)
            if case .skipped(let reason)? = model.bassStepMode {
                Label(reason, systemImage: "info.circle")
                if let advice = model.receiverAdvice {
                    GroupBox("Before you continue") { Text(advice).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Text("Continue to the next step.").foregroundStyle(.secondary)
            } else if model.bassStepMode == .monoBass {
                monoBassContent
            } else if !model.hasSubwoofer {
                Text("You have no subwoofer, so there is nothing to blend. Continue to the next step.")
                    .foregroundStyle(.secondary)
            } else if let bass = model.bass {
                content(bass)
            } else {
                Button("Work out the bass design") { model.computeBass() }
            }
        }
        .onAppear {
            if model.bassStepMode == .monoBass { if model.monoBass == nil { model.computeBass() } }
            else if model.hasSubwoofer && model.bass == nil { model.computeBass() }
        }
    }

    @ViewBuilder
    private var monoBassContent: some View {
        Text("Both speakers share the low frequencies. Notch Sixty picks where the sharing starts from how low your speakers play at the seats you measured. Apply it to hear the result; you can skip this to keep the standard 80 Hz setting.")
            .font(.callout).foregroundStyle(.secondary)
        if let design = model.monoBass {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow { Text("Left speaker plays down to").bold(); Text("\(design.leftExtensionHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Right speaker plays down to").bold(); Text("\(design.rightExtensionHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Shared bass below").bold(); Text("\(design.crossoverHz, specifier: "%.0f") Hz").monospacedDigit() }
                GridRow { Text("Slope").bold(); Text("\(design.filter.slopeDBPerOctave) dB per octave").monospacedDigit() }
            }
            HStack {
                Button("Apply") { Task { await model.applyBass() } }.disabled(model.choices.bassApplied)
                Button("Revert") { model.revertBass() }.disabled(!model.choices.bassApplied)
                if model.choices.bassApplied { Label("Applied", systemImage: "checkmark.circle.fill") }
            }
        } else {
            Button("Work out the bass design") { model.computeBass() }
        }
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
            Button("Apply") { Task { await model.applyBass() } }.disabled(model.choices.bassApplied)
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
            if let note = model.correctionNote { Label(note, systemImage: "info.circle").font(.callout) }
            if let advice = model.receiverAdvice { Text(advice).font(.callout).foregroundStyle(.secondary) }
            Picker("Listening", selection: $model.correctionMode) {
                ForEach(SystemSetupCorrectionMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(model.correctionMode.detail).font(.callout).foregroundStyle(.secondary)
            Picker("Sound", selection: $model.correctionTarget) {
                ForEach(model.correctionTargetChoices) { Text($0.title).tag($0) }
            }
            .onAppear { model.refreshCorrectionTargets() }
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
                Button("Apply") { Task { await model.applyCorrection() } }.disabled(model.choices.correctionApplied)
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
            RoomCorrectionABXCard(model: model)
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
