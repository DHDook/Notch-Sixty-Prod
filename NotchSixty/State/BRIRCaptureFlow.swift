import Foundation

// E13 S7 (design note 11): the guided personal-BRIR capture flow, behind `e13.headphones`.
//
// A main-actor state machine over an injectable environment. The environment owns the hardware
// (microphone input, sweep output, the saved-asset store); the flow owns the order of the steps,
// the quality gate with retry, and the rule that nothing is stored until every pass is in. Cancel at
// any step ends the measurement session (which cancels the transport and restores the device rate)
// and drops every result, so a cancelled flow leaves no partial asset.
//
// Realtime impact: none. All of this runs on the main actor and tasks.

/// One finished pass, with the quality verdict.
struct BRIRPassOutcome: Sendable {
    var left: [Float]
    var right: [Float]
    var quality: BRIRPassQuality
}

@MainActor
protocol BRIRCaptureEnvironment: AnyObject {
    /// Claims the measurement path (stops playback). Called once before the first pass.
    func beginSession() throws
    /// Releases it and restores any device state a pass changed. Idempotent.
    func finishSession()
    func speakerPass(plan: BRIRCapturePlan, step: BRIRCaptureStep) async throws -> BRIRPassOutcome
    /// Sweeps one headphone earcup (`channel` 0 left, 1 right) while the ear microphones record.
    func headphonePass(plan: BRIRCapturePlan, channel: Int) async throws -> BRIRPassOutcome
    func save(_ asset: BinauralProfileAsset) throws -> BinauralProfileReference
}

enum BRIRFlowStep: Int, CaseIterable, Comparable {
    case microphones, speakers, positions, compensation, capture, review, saved

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .microphones: "Microphones"
        case .speakers: "Speakers"
        case .positions: "Head positions"
        case .compensation: "Headphone compensation"
        case .capture: "Capture"
        case .review: "Review"
        case .saved: "Saved"
        }
    }
}

/// One thing the user is asked to capture.
enum BRIRFlowPass: Equatable {
    case speaker(BRIRCaptureStep)
    case reseat(Int)
}

@MainActor
final class BRIRCaptureFlow: ObservableObject {
    @Published private(set) var step: BRIRFlowStep = .microphones
    @Published var leftEar: MeasurementSeat?
    @Published var rightEar: MeasurementSeat?
    @Published var speakers: [OutputProgramRole]
    @Published var headPositions: BRIRHeadPositions = .three
    @Published var headTilt: BRIRHeadTilt = .level
    @Published var includeCompensation = false
    /// The user confirms the headphones are the selected output and are on, over the ear microphones.
    @Published var headphonesConfirmed = false
    @Published var displayName = "My BRIR"
    @Published private(set) var results: [BRIRCaptureResult] = []
    @Published private(set) var passIndex = 0
    @Published private(set) var isCapturing = false
    @Published private(set) var problem: String?
    @Published private(set) var lastQuality: BRIRPassQuality?
    @Published private(set) var savedReference: BinauralProfileReference?

    let sampleRate: Double
    let tapCount: Int
    /// The speakers the arrangement can play, in layout order; `speakers` is the chosen subset.
    let availableSpeakerRoles: [OutputProgramRole]
    private let environment: BRIRCaptureEnvironment
    private var reseats: [(left: [Float], right: [Float])] = []
    private var sessionOpen = false
    private var captureTask: Task<Void, Never>?

    init(environment: BRIRCaptureEnvironment, sampleRate: Double, availableSpeakers: [OutputProgramRole]) {
        self.environment = environment
        self.sampleRate = sampleRate
        // The BRIR can be as long as the binaural stage allows, and no longer than a quarter second.
        self.tapCount = max(1, min(Int(N60_BINAURAL_MAX_TAPS), Int(0.25 * sampleRate)))
        self.availableSpeakerRoles = availableSpeakers.filter { $0 != .lowFrequencyEffects }
        self.speakers = availableSpeakerRoles
    }

    // MARK: Plan and prompts

    var plan: BRIRCapturePlan? {
        guard let leftEar, let rightEar else { return nil }
        return BRIRCapturePlan(
            speakers: speakers, headPositions: headPositions, headTilt: headTilt, sampleRate: sampleRate, tapCount: tapCount,
            leftEar: leftEar, rightEar: rightEar)
    }

    var passes: [BRIRFlowPass] {
        guard let plan else { return [] }
        let speakerPasses = plan.steps.map { BRIRFlowPass.speaker($0) }
        let reseatPasses = includeCompensation
            ? (0..<BRIRCapturePlan.compensationReseatCount).map { BRIRFlowPass.reseat($0) } : []
        return speakerPasses + reseatPasses
    }

    var currentPass: BRIRFlowPass? { passes.indices.contains(passIndex) ? passes[passIndex] : nil }

    /// The prompt for the pass about to be captured.
    var prompt: String {
        switch currentPass {
        case .speaker(let captureStep):
            let yaw = captureStep.headYawDegrees
            let head = yaw == 0
                ? "Face straight ahead."
                : "Turn your head \(Int(abs(yaw))) degrees to the \(yaw < 0 ? "left" : "right")."
            let pitch = captureStep.headPitchDegrees
            let tilt = pitch == 0
                ? ""
                : " Tilt your head \(Int(abs(pitch))) degrees \(pitch > 0 ? "up" : "down")."
            return "\(head)\(tilt) Keep still, then capture \(captureStep.role.displayName)."
        case .reseat(let index):
            return "Put the headphones on over the microphones, then capture. Take them off and put them back on for each of the \(BRIRCapturePlan.compensationReseatCount) reseats (\(index + 1) of \(BRIRCapturePlan.compensationReseatCount))."
        case nil:
            return ""
        }
    }

    var progress: Double { passes.isEmpty ? 0 : Double(passIndex) / Double(passes.count) }

    // MARK: Navigation

    /// Why the flow cannot leave the current step, or nil.
    var blocker: String? {
        switch step {
        case .microphones:
            guard let leftEar, let rightEar else { return "Choose a microphone channel for each ear." }
            return leftEar.id == rightEar.id ? "The left and right ear need different channels." : nil
        case .speakers:
            return speakers.isEmpty ? "Choose at least one speaker." : nil
        case .positions:
            return nil
        case .compensation:
            return includeCompensation && !headphonesConfirmed ? "Confirm the headphones are on and selected as the output." : nil
        case .capture:
            return currentPass == nil ? nil : "Capture every pass first."
        case .review:
            return displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Give the profile a name." : nil
        case .saved:
            return nil
        }
    }

    func advance() {
        guard !isCapturing, blocker == nil, step < .saved else { return }
        if step == .compensation {
            do { try plan?.validate() } catch { problem = error.localizedDescription; return }
            results = []
            reseats = []
            passIndex = 0
        }
        problem = nil
        step = BRIRFlowStep(rawValue: step.rawValue + 1) ?? .saved
    }

    func back() {
        // From the review on, every pass is in; capturing again means starting over (Cancel).
        guard !isCapturing, step > .microphones, step < .review else { return }
        if step == .capture {
            releaseSession()
            results = []
            reseats = []
            passIndex = 0
        }
        problem = nil
        step = BRIRFlowStep(rawValue: step.rawValue - 1) ?? .microphones
    }

    // MARK: Capture

    /// Starts the current pass on a task the flow can cancel.
    func startCapture() {
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await self?.capture()
            self?.captureTask = nil
        }
    }

    /// Captures the current pass. A pass that clips or is too noisy is dropped and the same pass is
    /// offered again; any other failure leaves the pass where it was. When the last pass is in the
    /// session is released and the flow moves to the review.
    func capture() async {
        guard step == .capture, !isCapturing, let plan, let pass = currentPass else { return }
        isCapturing = true
        problem = nil
        defer { isCapturing = false }
        do {
            if !sessionOpen {
                try environment.beginSession()
                sessionOpen = true
            }
            switch pass {
            case .speaker(let captureStep):
                let outcome = try await environment.speakerPass(plan: plan, step: captureStep)
                try Task.checkCancellation()
                lastQuality = outcome.quality
                if let message = outcome.quality.problem { problem = message; return }
                results.append(BRIRCaptureResult(
                    role: captureStep.role, headYawDegrees: captureStep.headYawDegrees,
                    headPitchDegrees: captureStep.headPitchDegrees, leftIR: outcome.left, rightIR: outcome.right))
            case .reseat:
                let leftCup = try await environment.headphonePass(plan: plan, channel: 0)
                try Task.checkCancellation()
                let rightCup = try await environment.headphonePass(plan: plan, channel: 1)
                try Task.checkCancellation()
                lastQuality = BRIRPassQuality(
                    snrDB: min(leftCup.quality.snrDB, rightCup.quality.snrDB),
                    clippedSamples: leftCup.quality.clippedSamples + rightCup.quality.clippedSamples)
                if let message = leftCup.quality.problem ?? rightCup.quality.problem { problem = message; return }
                // Each ear is measured through its own earcup.
                reseats.append((left: leftCup.left, right: rightCup.right))
            }
            passIndex += 1
            if currentPass == nil {
                releaseSession()
                step = .review
            }
        } catch is CancellationError {
            // `cancel()` already released the session and dropped the results.
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Ends the flow from any step: stops a pass in flight, releases the device and drops every result.
    func cancel() {
        captureTask?.cancel()
        captureTask = nil
        releaseSession()
        results = []
        reseats = []
        passIndex = 0
        lastQuality = nil
        problem = nil
        isCapturing = false
        step = .microphones
    }

    private func releaseSession() {
        guard sessionOpen else { return }
        sessionOpen = false
        environment.finishSession()
    }

    // MARK: Review and save

    /// The asset the review shows and saves: every pass, with the headphone compensation convolved in.
    func makeAsset() throws -> BinauralProfileAsset {
        guard let plan else { throw BRIRCaptureError.invalidPlan }
        let compensation: BRIRHeadphoneCompensation? = includeCompensation
            ? try BRIRHeadphoneCompensation.design(
                leftReseats: reseats.map(\.left), rightReseats: reseats.map(\.right), sampleRate: sampleRate)
            : nil
        return try BRIRCaptureAssembler.makeAsset(
            displayName: displayName.trimmingCharacters(in: .whitespaces),
            plan: plan, results: results, compensation: compensation)
    }

    /// Builds, stores and returns the reference the caller assigns to the headphone profile.
    @discardableResult
    func save() -> BinauralProfileReference? {
        guard step == .review, blocker == nil else { return nil }
        do {
            let reference = try environment.save(try makeAsset())
            savedReference = reference
            problem = nil
            step = .saved
            return reference
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }
}
