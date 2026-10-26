import Foundation

// E12 S2: guided-setup flow core. Pure Swift value types plus a small driver; no SwiftUI, no
// engine, nothing here runs on an audio thread. The UI (S3 onward) and the real controllers
// plug in through `SystemSetupServices`. Gated by the `e12.guided-setup` flag at the call sites.

// MARK: - Steps and choices

enum SystemSetupStep: String, Codable, CaseIterable, Sendable {
    case output, topology, microphone, room, measure, alignment, bass, correction, verify, save

    /// Steps whose results depend on the measurement pass (invalidated by a device or rate change).
    var dependsOnMeasurement: Bool {
        switch self {
        case .measure, .alignment, .bass, .correction, .verify: return true
        default: return false
        }
    }

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

enum SystemSetupTopology: String, Codable, CaseIterable, Sendable {
    case stereo, twoPointOne, twoPointTwo
    var hasSubwoofer: Bool { self != .stereo }
}

enum SystemSetupDesignKind: String, Codable, Sendable {
    case minimumPhase, mixedPhase
}

enum SystemSetupDesignStage: String, Codable, Sendable {
    case alignment, bass, correction
}

struct SystemSetupChoices: Codable, Equatable, Sendable {
    var outputUID: String?
    var sampleRate: Double?
    var topology: SystemSetupTopology?
    var microphoneUID: String?
    var microphoneCalibrationFile: String?
    var sweepLevelDBFS: Double?
    var seatNames: [String] = []
    var measurementIDs: [UUID] = []
    var alignmentApplied = false
    var bassApplied = false
    var correctionApplied = false
    var designKind: SystemSetupDesignKind = .minimumPhase
    var verificationPassed: Bool?
    var profileName: String = ""
}

// MARK: - Refusals

enum SystemSetupRefusal: Error, Equatable, Sendable {
    case notRunning
    case alreadyRunning
    case preconditionNotMet(SystemSetupStep, String)
    case cannotSkip(SystemSetupStep)
    case atFirstStep
    case atLastStep
    case mixedPhaseNeedsVerification
    case missingName

    var reason: String {
        switch self {
        case .notRunning: return "The setup is not running."
        case .alreadyRunning: return "The setup is already running."
        case .preconditionNotMet(_, let why): return why
        case .cannotSkip(let step): return "The \(step.rawValue) step cannot be skipped."
        case .atFirstStep: return "This is the first step."
        case .atLastStep: return "This is the last step; finish to save."
        case .mixedPhaseNeedsVerification:
            return "A mixed-phase correction cannot be saved until verification passes."
        case .missingName: return "Give the profile a name."
        }
    }
}

// MARK: - Flow reducer

struct SystemSetupFlow: Codable, Equatable, Sendable {
    enum Phase: Codable, Equatable, Sendable {
        case idle, running, failed(String), cancelled, finished
    }

    private(set) var phase: Phase = .idle
    private(set) var step: SystemSetupStep = .output
    private(set) var completed: Set<SystemSetupStep> = []
    private(set) var skipped: Set<SystemSetupStep> = []
    var choices = SystemSetupChoices()
    /// State of the selected playback system when the flow started; Cancel restores it exactly.
    private(set) var snapshot: PlaybackSystemState?
    /// Set when a device or rate change reset the measurement steps.
    private(set) var invalidationReason: String?

    init() {}

    // MARK: Preconditions

    /// Why `step` cannot be left yet, or nil when it can.
    func unmetPrecondition(for step: SystemSetupStep) -> String? {
        let c = choices
        switch step {
        case .output:
            if c.outputUID == nil { return "Choose an output device." }
            if (c.sampleRate ?? 0) <= 0 { return "The output sample rate is unknown." }
        case .topology:
            if c.topology == nil { return "Say what speakers you have." }
        case .microphone:
            if c.microphoneUID == nil { return "Choose a measurement microphone." }
            if c.sweepLevelDBFS == nil { return "Set the sweep level first." }
        case .room:
            break
        case .measure:
            if c.seatNames.isEmpty { return "Add at least one seat." }
            if c.measurementIDs.count != c.seatNames.count { return "Measure every seat." }
        case .alignment:
            if !c.alignmentApplied { return "Apply the alignment first." }
        case .bass:
            if c.topology?.hasSubwoofer == true && !c.bassApplied {
                return "Apply the bass design first."
            }
        case .correction:
            if !c.correctionApplied { return "Apply the correction first." }
        case .verify:
            if c.verificationPassed == nil { return "Run the verification first." }
        case .save:
            if c.profileName.trimmingCharacters(in: .whitespaces).isEmpty { return "Give the profile a name." }
        }
        return nil
    }

    /// Room may be skipped; Bass only when there is no subwoofer; Measure never.
    func canSkip(_ step: SystemSetupStep) -> Bool {
        switch step {
        case .room: return true
        case .bass: return choices.topology?.hasSubwoofer == false
        default: return false
        }
    }

    // MARK: Actions

    mutating func start(snapshot: PlaybackSystemState, choices initial: SystemSetupChoices = .init()) throws {
        guard phase != .running else { throw SystemSetupRefusal.alreadyRunning }
        self = SystemSetupFlow()
        self.snapshot = snapshot
        self.choices = initial
        phase = .running
    }

    mutating func next() throws {
        try requireRunning()
        if let why = unmetPrecondition(for: step) {
            throw SystemSetupRefusal.preconditionNotMet(step, why)
        }
        guard let following = Self.after(step) else {
            throw SystemSetupRefusal.atLastStep
        }
        completed.insert(step)
        skipped.remove(step)
        step = following
    }

    mutating func back() throws {
        try requireRunning()
        guard let previous = Self.before(step) else { throw SystemSetupRefusal.atFirstStep }
        step = previous
    }

    mutating func skip() throws {
        try requireRunning()
        guard canSkip(step) else { throw SystemSetupRefusal.cannotSkip(step) }
        guard let following = Self.after(step) else { throw SystemSetupRefusal.atLastStep }
        skipped.insert(step)
        step = following
    }

    mutating func fail(_ reason: String) {
        guard phase == .running else { return }
        phase = .failed(reason)
    }

    /// Resume after a failure at the same step.
    mutating func retry() throws {
        guard case .failed = phase else { throw SystemSetupRefusal.notRunning }
        phase = .running
    }

    /// Ends the flow and returns the snapshot the caller must restore.
    mutating func cancel() throws -> PlaybackSystemState? {
        guard phase == .running || { if case .failed = phase { return true } else { return false } }() else {
            throw SystemSetupRefusal.notRunning
        }
        phase = .cancelled
        return snapshot
    }

    /// Validates the Save step. The caller saves the profile, then the flow is finished.
    mutating func finish() throws {
        try requireRunning()
        guard step == .save else { throw SystemSetupRefusal.preconditionNotMet(step, "Not at the Save step.") }
        if unmetPrecondition(for: .save) != nil { throw SystemSetupRefusal.missingName }
        if choices.designKind == .mixedPhase && choices.verificationPassed != true {
            throw SystemSetupRefusal.mixedPhaseNeedsVerification
        }
        completed.insert(.save)
        phase = .finished
    }

    /// True when the saved profile must be labelled "Not verified".
    var savesAsNotVerified: Bool { choices.verificationPassed != true }

    /// A failed verification clears the correction and returns to the Correction step.
    mutating func verificationFailed(reason: String) {
        choices.correctionApplied = false
        choices.verificationPassed = nil
        completed.subtract([.correction, .verify])
        step = .correction
        invalidationReason = reason
    }

    /// Output device or rate changed: drop everything that came from measuring.
    mutating func outputConfigurationChanged(outputUID: String?, sampleRate: Double?) {
        let changed = outputUID != choices.outputUID || sampleRate != choices.sampleRate
        guard changed else { return }
        let hadMeasurement = !choices.measurementIDs.isEmpty || step.dependsOnMeasurement
        choices.outputUID = outputUID
        choices.sampleRate = sampleRate
        guard hadMeasurement else { return }
        choices.measurementIDs = []
        choices.alignmentApplied = false
        choices.bassApplied = false
        choices.correctionApplied = false
        choices.verificationPassed = nil
        completed.subtract(SystemSetupStep.allCases.filter(\.dependsOnMeasurement))
        skipped.subtract(SystemSetupStep.allCases.filter(\.dependsOnMeasurement))
        if step.index > SystemSetupStep.measure.index { step = .measure }
        invalidationReason = "The output device or sample rate changed, so the measurements were discarded. Measure again."
    }

    /// A resumed session whose measurements are no longer held (the session stores only their IDs) goes
    /// back to the Measure step, and says why.
    mutating func resumed(measurementsAvailable: Bool) {
        guard phase == .running, step.index > SystemSetupStep.measure.index, !measurementsAvailable else { return }
        choices.measurementIDs = []
        choices.alignmentApplied = false
        choices.bassApplied = false
        choices.correctionApplied = false
        choices.verificationPassed = nil
        completed.subtract(SystemSetupStep.allCases.filter(\.dependsOnMeasurement))
        skipped.subtract(SystemSetupStep.allCases.filter(\.dependsOnMeasurement))
        step = .measure
        invalidationReason = "The measurements were not kept, so the setup resumed at Measure seats."
    }

    // MARK: Helpers

    private func requireRunning() throws {
        guard phase == .running else { throw SystemSetupRefusal.notRunning }
    }

    static func after(_ step: SystemSetupStep) -> SystemSetupStep? {
        let all = SystemSetupStep.allCases
        let i = step.index + 1
        return i < all.count ? all[i] : nil
    }

    static func before(_ step: SystemSetupStep) -> SystemSetupStep? {
        let i = step.index - 1
        return i >= 0 ? SystemSetupStep.allCases[i] : nil
    }
}

// MARK: - Services

struct SystemSetupMeasurementRecord: Equatable, Sendable {
    var id: UUID
    var seatIndex: Int
    var sampleRate: Double
}

struct SystemSetupVerificationReport: Codable, Equatable, Sendable {
    var passed: Bool
    var predictedErrorDB: Double
    var measuredErrorDB: Double
    var sampleRate: Double
}

/// The work behind each step. The real implementation wraps the calibration and room-correction
/// controllers (S3 onward); tests use `SimulatedSystemSetupServices`.
protocol SystemSetupServices: Sendable {
    func measureSeat(index: Int, sampleRate: Double) async throws -> SystemSetupMeasurementRecord
    /// Returns the trial state for the stage, built from `state` and the measurement records.
    func design(
        stage: SystemSetupDesignStage,
        records: [SystemSetupMeasurementRecord],
        state: PlaybackSystemState
    ) async throws -> PlaybackSystemState
    func apply(_ state: PlaybackSystemState) async throws
    func revert(to snapshot: PlaybackSystemState) async throws
    func verify(
        state: PlaybackSystemState,
        records: [SystemSetupMeasurementRecord]
    ) async throws -> SystemSetupVerificationReport
    func save(
        name: String,
        state: PlaybackSystemState,
        report: SystemSetupVerificationReport?
    ) async throws -> PlaybackSystemProfile
}

/// Deterministic stand-in used by tests: a synthetic room with a fixed per-seat result, no audio.
/// (The C++ reference room is not bridged to Swift; E12 S4 tests the numerics through the real path.)
actor SimulatedSystemSetupServices: SystemSetupServices {
    private(set) var live: PlaybackSystemState
    private(set) var appliedStages: [SystemSetupDesignStage] = []
    private(set) var reverted = false
    private(set) var saved: [PlaybackSystemProfile] = []
    var verificationPasses = true
    var failMeasureAtSeat: Int?
    var verifyDelaySeconds = 0.0

    init(initial: PlaybackSystemState) { live = initial }

    func setVerificationPasses(_ value: Bool) { verificationPasses = value }
    func setFailMeasureAtSeat(_ value: Int?) { failMeasureAtSeat = value }
    func setVerifyDelaySeconds(_ value: Double) { verifyDelaySeconds = value }

    func measureSeat(index: Int, sampleRate: Double) async throws -> SystemSetupMeasurementRecord {
        if failMeasureAtSeat == index { throw SimulatedFailure.measurement }
        let id = UUID(uuid: (UInt8(truncatingIfNeeded: index), 0xE1, 0x12, 0, 0, 0, 0, 0,
                             0, 0, 0, 0, 0, 0, 0, UInt8(truncatingIfNeeded: Int(sampleRate / 100))))
        return SystemSetupMeasurementRecord(id: id, seatIndex: index, sampleRate: sampleRate)
    }

    func design(
        stage: SystemSetupDesignStage,
        records: [SystemSetupMeasurementRecord],
        state: PlaybackSystemState
    ) async throws -> PlaybackSystemState {
        var next = state
        switch stage {
        case .alignment: next.outputGainDB = state.outputGainDB - 1
        case .bass: next.bassManagement.subGainDB = state.bassManagement.subGainDB + 0.5
        case .correction: next.roomCorrection.enabled = true
        }
        appliedStages.append(stage)
        return next
    }

    func apply(_ state: PlaybackSystemState) async throws { live = state }

    func revert(to snapshot: PlaybackSystemState) async throws {
        live = snapshot
        reverted = true
    }

    func verify(
        state: PlaybackSystemState,
        records: [SystemSetupMeasurementRecord]
    ) async throws -> SystemSetupVerificationReport {
        if verifyDelaySeconds > 0 { try await Task.sleep(nanoseconds: UInt64(verifyDelaySeconds * 1_000_000_000)) }
        return SystemSetupVerificationReport(
            passed: verificationPasses,
            predictedErrorDB: 1.0,
            measuredErrorDB: verificationPasses ? 1.2 : 6.0,
            sampleRate: records.first?.sampleRate ?? 0
        )
    }

    func save(
        name: String,
        state: PlaybackSystemState,
        report: SystemSetupVerificationReport?
    ) async throws -> PlaybackSystemProfile {
        let profile = PlaybackSystemProfile(name: name, state: state)
        saved.append(profile)
        return profile
    }

    enum SimulatedFailure: Error { case measurement }
}

// MARK: - Driver

/// Runs the work of the current step through the services and feeds the result into the reducer.
@MainActor
final class SystemSetupDriver {
    private(set) var flow = SystemSetupFlow()
    private(set) var working: PlaybackSystemState
    private(set) var records: [SystemSetupMeasurementRecord] = []
    private(set) var report: SystemSetupVerificationReport?
    private(set) var savedProfile: PlaybackSystemProfile?
    private var beforeCorrection: PlaybackSystemState?
    private var verificationTask: Task<SystemSetupVerificationReport, Error>?
    private let services: SystemSetupServices

    init(services: SystemSetupServices, current: PlaybackSystemState) {
        self.services = services
        self.working = current
    }

    func start(choices: SystemSetupChoices = .init()) throws {
        try flow.start(snapshot: working, choices: choices)
    }

    func update(_ edit: (inout SystemSetupChoices) -> Void) { edit(&flow.choices) }
    func next() throws { try flow.next() }
    func back() throws { try flow.back() }
    func skip() throws { try flow.skip() }

    /// Measures every seat that has no record yet. A failure stops the flow at this step.
    func measureSeats() async {
        guard let rate = flow.choices.sampleRate else { return }
        do {
            for index in flow.choices.seatNames.indices where index >= records.count {
                let record = try await services.measureSeat(index: index, sampleRate: rate)
                records.append(record)
                flow.choices.measurementIDs.append(record.id)
            }
        } catch {
            flow.fail("Measurement failed: \(error)")
        }
    }

    func applyAlignment() async { await applyStage(.alignment) { $0.alignmentApplied = true } }
    func applyBass() async { await applyStage(.bass) { $0.bassApplied = true } }

    func applyCorrection() async {
        beforeCorrection = working
        await applyStage(.correction) { $0.correctionApplied = true }
    }

    /// Verifies through the services. A timeout or a cancel (see `cancelVerification`) reverts the
    /// correction and returns to the Correction step; so does a mixed-phase mismatch.
    func runVerification(timeoutSeconds: Double = 60) async {
        guard verificationTask == nil else { return }
        let services = self.services, state = working, records = self.records
        let task = Task { () -> SystemSetupVerificationReport in
            try await withThrowingTaskGroup(of: SystemSetupVerificationReport.self) { group in
                group.addTask { try await services.verify(state: state, records: records) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                    throw SystemSetupVerificationError.timedOut(seconds: timeoutSeconds)
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw SystemSetupVerificationError.timedOut(seconds: timeoutSeconds)
                }
                return first
            }
        }
        verificationTask = task
        defer { verificationTask = nil }
        do {
            let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            report = result
            if result.passed || flow.choices.designKind == .minimumPhase {
                flow.choices.verificationPassed = result.passed
            } else {
                await revertCorrectionTrial(reason: "Verification did not match the design; the correction was reverted.")
            }
        } catch is CancellationError {
            await revertCorrectionTrial(reason: "Verification was cancelled; the correction was reverted.")
        } catch let error as SystemSetupVerificationError {
            await revertCorrectionTrial(reason: error.errorDescription ?? "Verification failed; the correction was reverted.")
        } catch {
            flow.fail("Verification failed: \(error)")
        }
    }

    func cancelVerification() { verificationTask?.cancel() }

    private func revertCorrectionTrial(reason: String) async {
        do {
            if let base = beforeCorrection {
                try await services.revert(to: base)
                working = base
            }
            flow.verificationFailed(reason: reason)
        } catch {
            flow.fail("Restoring the previous correction failed: \(error)")
        }
    }

    func finish() async {
        do {
            try flow.finish()
            savedProfile = try await services.save(
                name: flow.choices.profileName, state: working, report: report
            )
        } catch let refusal as SystemSetupRefusal {
            flow.fail(refusal.reason)
        } catch {
            flow.fail("Saving failed: \(error)")
        }
    }

    func cancel() async {
        guard let snapshot = try? flow.cancel() else { return }
        do {
            try await services.revert(to: snapshot)
            working = snapshot
        } catch {
            flow.fail("Restoring the previous settings failed: \(error)")
        }
    }

    private func applyStage(
        _ stage: SystemSetupDesignStage, mark: (inout SystemSetupChoices) -> Void
    ) async {
        do {
            let trial = try await services.design(stage: stage, records: records, state: working)
            try await services.apply(trial)
            working = trial
            mark(&flow.choices)
        } catch {
            flow.fail("\(stage.rawValue) failed: \(error)")
        }
    }
}

// MARK: - Session persistence

/// Schema 1 session: step and choices and measurement IDs, never audio buffers.
struct SystemSetupSession: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion = SystemSetupSession.currentSchemaVersion
    var playbackSystemKey: String
    var updatedAt: Date
    var flow: SystemSetupFlow

    init(playbackSystemKey: String, updatedAt: Date, flow: SystemSetupFlow) {
        self.playbackSystemKey = playbackSystemKey
        self.updatedAt = updatedAt
        self.flow = flow
    }
}

struct SystemSetupSessionStore: Sendable {
    let directory: URL

    /// Default location: Application Support/NotchSixty/SystemSetup.
    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("NotchSixty/SystemSetup", isDirectory: true)
    }

    private func url(for key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? String($0) : "_" }.joined()
        return directory.appendingPathComponent("session-\(safe).json")
    }

    func save(_ session: SystemSetupSession) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(session).write(to: url(for: session.playbackSystemKey), options: .atomic)
    }

    /// Nil when there is no session or it is unreadable or from a newer schema.
    func load(key: String) -> SystemSetupSession? {
        guard let data = try? Data(contentsOf: url(for: key)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let session = try? decoder.decode(SystemSetupSession.self, from: data),
              session.schemaVersion <= SystemSetupSession.currentSchemaVersion else { return nil }
        return session
    }

    func delete(key: String) {
        try? FileManager.default.removeItem(at: url(for: key))
    }
}
