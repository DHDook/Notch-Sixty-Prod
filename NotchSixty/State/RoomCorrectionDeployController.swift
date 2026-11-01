import Foundation

// E10 S8 (design note 9): trial apply, post-apply verification and the `canDeploy` gate.

/// What the trial host is asked to apply and what the verifier compares the capture with.
struct RoomCorrectionDeployCandidate: Sendable {
    enum Kind: String, Codable, Sendable { case minimumPhase, mixedPhase, jointBass }

    var designID: String
    var kind: Kind
    var sampleRate: Double
    var lanePlan: RoomCorrectionLanePlan
    var latencyMode: RoomCorrectionLatencyMode
    /// The lane whose output is measured at the main seat.
    var measuredLane: Int
    /// Part (a): the prediction check of the published filter.
    var predictionCheck: RoomCorrectionPredictionCheck
    /// The prediction at the main seat on the verifier's centres.
    var predicted: RoomCorrectionBandedResponse
    /// Starts well below the analysed range: the generator's 100 ms start ramp attenuates the first octave of a sweep.
    var sweepStartHz = 10.0
    var sweepEndHz = 18_000.0
    var sweepFrames: Int

    /// Minimum-phase designs keep today's prediction-only path.
    var needsPostApply: Bool { kind != .minimumPhase }
}

/// The live graph side of the trial, injected so the controller is testable without hardware. The engine adapter applies
/// the candidate through the normal snapshot path, keeps the previous configuration ready, plays the generator sweep and
/// returns the monitor capture aligned to the sweep start (chirp timing is the host's job, E11).
protocol RoomCorrectionTrialHost: AnyObject, Sendable {
    func applyTrial(_ candidate: RoomCorrectionDeployCandidate) async throws
    func captureSweep(for candidate: RoomCorrectionDeployCandidate) async throws -> [Float]
    /// Restores the previous configuration. Must be safe to call when nothing was applied.
    func revertTrial() async
}

@MainActor
final class RoomCorrectionDeployController: ObservableObject {
    enum State: Equatable { case idle, applying, capturing, analysing }

    @Published private(set) var state: State = .idle
    @Published private(set) var storedReport: RoomCorrectionPostApplyReport?
    private var currentTask: Task<RoomCorrectionPostApplyReport, Never>?
    private let storeURL: URL?
    private let criteria: RoomCorrectionPostApplyCriteria

    init(criteria: RoomCorrectionPostApplyCriteria = RoomCorrectionPostApplyCriteria(), storeURL: URL? = nil) {
        self.criteria = criteria
        self.storeURL = storeURL
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            storedReport = try? decoder.decode(RoomCorrectionPostApplyReport.self, from: data)
        }
    }

    /// True only for a candidate whose prediction check passed and, for mixed-phase and joint-bass designs, whose stored
    /// post-apply report passed for this design at this rate.
    func canDeploy(_ candidate: RoomCorrectionDeployCandidate) -> Bool {
        guard candidate.predictionCheck.passed else { return false }
        guard candidate.needsPostApply else { return true }
        guard let report = storedReport else { return false }
        return report.passed && report.designID == candidate.designID && report.sampleRate == candidate.sampleRate
    }

    /// Drops a stored report when the design it covers changes.
    func invalidate() {
        storedReport = nil
        if let storeURL { try? FileManager.default.removeItem(at: storeURL) }
    }

    func cancel() { currentTask?.cancel() }

    /// Trial-applies the candidate, plays the sweep, verifies, and either keeps it (a passing report is stored) or
    /// reverts. Never throws: every failure is a report with its outcome.
    @discardableResult
    func verify(
        _ candidate: RoomCorrectionDeployCandidate, host: RoomCorrectionTrialHost, timeoutSeconds: Double
    ) async -> RoomCorrectionPostApplyReport {
        guard currentTask == nil else {
            return RoomCorrectionPostApplyVerifier.failure(
                candidate.designID, candidate.sampleRate, .captureFailed, "A verification is already running.", criteria)
        }
        guard candidate.predictionCheck.passed else {
            return RoomCorrectionPostApplyVerifier.failure(
                candidate.designID, candidate.sampleRate, .analysisFailed,
                candidate.predictionCheck.reasons.joined(separator: " "), criteria)
        }
        storedReport = nil
        let criteria = self.criteria
        let task = Task { [weak self] () -> RoomCorrectionPostApplyReport in
            func fail(_ outcome: RoomCorrectionPostApplyOutcome, _ detail: String) async -> RoomCorrectionPostApplyReport {
                await host.revertTrial()
                return RoomCorrectionPostApplyVerifier.failure(
                    candidate.designID, candidate.sampleRate, outcome, detail, criteria)
            }
            await self?.set(.applying)
            do { try await host.applyTrial(candidate) } catch is CancellationError {
                return await fail(.cancelled, "Cancelled while applying.")
            } catch { return await fail(.captureFailed, "The trial apply failed: \(error)") }
            await self?.set(.capturing)
            let capture: [Float]
            do {
                capture = try await Self.withTimeout(seconds: timeoutSeconds) {
                    try await host.captureSweep(for: candidate)
                }
            } catch is CancellationError {
                return await fail(.cancelled, "Cancelled during the capture.")
            } catch is TimeoutError {
                return await fail(.timedOut, "The capture did not finish in \(timeoutSeconds) s.")
            } catch { return await fail(.captureFailed, "\(error)") }
            if Task.isCancelled { return await fail(.cancelled, "Cancelled before analysis.") }
            await self?.set(.analysing)
            do {
                let response = try RoomCorrectionPostApplyVerifier.impulseResponse(
                    capture: capture, sweepStartHz: candidate.sweepStartHz, sweepEndHz: candidate.sweepEndHz,
                    sweepFrames: candidate.sweepFrames, sampleRate: candidate.sampleRate)
                let measured = try RoomCorrectionPostApplyVerifier.bandedResponse(
                    impulse: response.impulse, originFrame: response.arrivalFrames,
                    // The deconvolved peak sits after the start of a minimum-phase filter's response; keep that early energy in the window.
                    preFrames: Int(candidate.lanePlan.declaredLatencyFrames) + Int(0.005 * candidate.sampleRate),
                    sampleRate: candidate.sampleRate, criteria: criteria)
                let report = RoomCorrectionPostApplyVerifier.evaluate(
                    designID: candidate.designID, sampleRate: candidate.sampleRate, predicted: candidate.predicted,
                    measured: measured, criteria: criteria)
                if !report.passed { await host.revertTrial() }
                return report
            } catch { return await fail(.analysisFailed, "\(error)") }
        }
        currentTask = task
        let report = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        currentTask = nil
        state = .idle
        if report.passed { store(report) }
        return report
    }

    private func set(_ newState: State) { state = newState }

    private func store(_ report: RoomCorrectionPostApplyReport) {
        storedReport = report
        guard let storeURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(report) { try? data.write(to: storeURL, options: .atomic) }
    }

    struct TimeoutError: Error {}

    nonisolated private static func withTimeout<T: Sendable>(
        seconds: Double, _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw TimeoutError()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimeoutError() }
            return first
        }
    }
}
