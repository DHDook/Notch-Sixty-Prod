import Foundation

/// Assemble a complete A/B/A controlled-source survey from one movable mic.
/// All three captures must come from an instrumented launch and a clock
/// verified outside this coordinator. No audio is persisted in the resulting
/// calibration, only synchronized arrival evidence and provenance.
struct QuietZoneFeedForwardSurveySession: Sendable {
    enum Stage: Int, CaseIterable, Sendable {
        case listener = 0
        case upstream = 1
        case listenerReturn = 2

        var position: QuietZoneFeedForwardPosition {
            switch self {
            case .listener: return .listenerFirst
            case .upstream: return .upstream
            case .listenerReturn: return .listenerReturn
            }
        }
    }

    private(set) var arrivals: [QuietZoneFeedForwardArrival] = []
    private(set) var firstCaptureTimestamp: Date?
    private(set) var lastCaptureTimestamp: Date?
    let createdAt: Date
    let expectedProjectID: UUID
    let expectedMicrophoneStableID: String
    let expectedMicrophoneChannel: Int
    let expectedRouteFingerprint: String
    let expectedClockID: String
    let expectedStimulusID: String

    /// Limit total time so user motion and room changes are not hidden.
    static let maximumSurveyDuration: TimeInterval = 360
    static let minimumInterCaptureInterval: TimeInterval = 0.25

    init(
        projectID: UUID,
        microphoneStableID: String,
        microphoneChannel: Int,
        routeFingerprint: String,
        clockID: String,
        stimulusID: String,
        now: Date = Date()
    ) throws {
        guard !microphoneStableID.isEmpty, microphoneChannel >= 0,
              !routeFingerprint.isEmpty, !clockID.isEmpty,
              !stimulusID.isEmpty else {
            throw QuietZoneFeedForwardError.incompatibleClock
        }
        self.expectedProjectID = projectID
        self.expectedMicrophoneStableID = microphoneStableID
        self.expectedMicrophoneChannel = microphoneChannel
        self.expectedRouteFingerprint = routeFingerprint
        self.expectedClockID = clockID
        self.expectedStimulusID = stimulusID
        self.createdAt = now
    }

    var nextStage: Stage? {
        guard arrivals.count < Stage.allCases.count else { return nil }
        return Stage(rawValue: arrivals.count)
    }

    var isComplete: Bool { arrivals.count == Stage.allCases.count }

    /// The caller must supply a calibrated controlled-source capture.
    /// No way to advance a stage with just an unclocked room sweep.
    mutating func add(
        _ capture: QuietZoneFeedForwardProbeCapture,
        projectID: UUID,
        capturedAt: Date = Date(),
        detector: QuietZoneFeedForwardProbeDetector = .init()
    ) throws -> QuietZoneFeedForwardArrival {
        guard let stage = nextStage else {
            throw QuietZoneFeedForwardError.incompleteCapture
        }
        guard projectID == expectedProjectID,
              capture.position == stage.position,
              capture.microphoneDeviceID == expectedMicrophoneStableID,
              capture.microphoneChannel == expectedMicrophoneChannel,
              capture.routeFingerprint == expectedRouteFingerprint,
              capture.synchronizedClockID == expectedClockID,
              capture.sourceTriggerID == expectedStimulusID else {
            throw QuietZoneFeedForwardError.incompatibleProject
        }
        let elapsed = capturedAt.timeIntervalSince(createdAt)
        guard elapsed.isFinite, elapsed >= 0,
              elapsed <= Self.maximumSurveyDuration,
              lastCaptureTimestamp.map({
                  capturedAt.timeIntervalSince($0)
                    >= Self.minimumInterCaptureInterval
              }) ?? true
        else { throw QuietZoneFeedForwardError.staleData }

        // Detector validates waveform quality, clipping and trigger precision.
        let arrival = try detector.detect(capture)
        // We also prevent a silent change in input sample rate mid-survey.
        if let first = arrivals.first,
           abs(first.sampleRate - arrival.sampleRate) >= 0.5 {
            throw QuietZoneFeedForwardError.incompatibleClock
        }

        // Do not mutate until every guard has passed. If the listener return
        // disagrees with the initial measurement, invalidate the entire survey.
        if stage == .listenerReturn, let first = arrivals.first,
           abs(first.arrivalAfterTriggerSeconds
               - arrival.arrivalAfterTriggerSeconds)
               > QuietZoneFeedForwardBudgetAnalyzer
                   .maximumListenerRepeatDifferenceSeconds {
            arrivals.removeAll()
            firstCaptureTimestamp = nil
            lastCaptureTimestamp = nil
            throw QuietZoneFeedForwardError.sourceDrift
        }

        arrivals.append(arrival)
        if firstCaptureTimestamp == nil { firstCaptureTimestamp = capturedAt }
        lastCaptureTimestamp = capturedAt
        return arrival
    }

    func committed(
        to plan: QuietZoneFeedForwardCalibration,
        project: RoomCorrectionProject,
        now: Date = Date()
    ) throws -> (QuietZoneFeedForwardCalibration, QuietZoneFeedForwardBudget) {
        guard isComplete, plan.projectID == expectedProjectID,
              project.id == expectedProjectID,
              plan.microphoneStableID == expectedMicrophoneStableID
        else { throw QuietZoneFeedForwardError.incompleteCapture }
        var copy = plan
        copy.arrivals = arrivals
        copy.capturedAt = now
        // Keep existing separately obtained output-to-seat timing only if its
        // timebase/route identity still matches. The analyzer enforces that.
        let budget = try QuietZoneFeedForwardBudgetAnalyzer()
            .analyze(copy, project: project, now: now)
        return (copy, budget)
    }
}
