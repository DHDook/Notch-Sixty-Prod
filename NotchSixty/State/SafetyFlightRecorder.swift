import Foundation

/// What kind of safety event the flight recorder holds (E4 S17).
enum SafetyEventKind: String, Equatable, Sendable {
    case arm
    case disarm
    case verifier
    case guardTrip
    case environment
    /// E4 S20: a step, reset or resume of the earned anti-noise cap.
    case cap
}

/// One entry: when it happened, what kind, and a short plain-language line. No audio and no
/// sample data is ever stored, only text.
struct SafetyEvent: Equatable, Sendable {
    var time: Date
    var kind: SafetyEventKind
    var message: String
}

/// Ring buffer of the last 60 seconds of arm, verifier, howl-guard and environment events
/// (E4 S17). It records why anti-noise stopped, in plain language, for the user and for the
/// diagnostics export.
///
/// Control plane only (main actor): the render path never sees it. Capacity is bounded by both
/// age (`retentionSeconds`) and count (`maximumEvents`), so a noisy fault cannot grow it.
struct SafetyFlightRecorder: Sendable {
    static let retentionSeconds = 60.0
    static let maximumEvents = 200

    private(set) var events: [SafetyEvent] = []
    /// The explanation of the most recent automatic or user disarm; survives pruning so the
    /// reason is still shown after 60 s. Cleared by the next arm.
    private(set) var lastDisarmExplanation: String?

    mutating func record(_ kind: SafetyEventKind, _ message: String, at time: Date = Date()) {
        // Repeated identical environment/verifier lines (a poll loop) add nothing.
        if let last = events.last, last.kind == kind, last.message == message { return }
        events.append(SafetyEvent(time: time, kind: kind, message: message))
        prune(now: time)
    }

    mutating func recordArm(at time: Date = Date()) {
        lastDisarmExplanation = nil
        record(.arm, "Armed.", at: time)
    }

    mutating func recordDisarm(_ reason: LiveTreatmentDisarmReason, at time: Date = Date()) {
        let kind: SafetyEventKind = reason == .instabilityTrip ? .guardTrip
            : (reason == .seatRegression ? .verifier : .disarm)
        let text = Self.explanation(for: reason)
        lastDisarmExplanation = text
        record(kind, text, at: time)
        record(.disarm, "Disarmed (\(reason.rawValue)).", at: time)
    }

    mutating func reset() {
        events.removeAll()
        lastDisarmExplanation = nil
    }

    /// Events from the last 60 s before `now`, oldest first.
    func recent(now: Date = Date()) -> [SafetyEvent] {
        events.filter { now.timeIntervalSince($0.time) <= Self.retentionSeconds }
    }

    /// Lines for the diagnostics export, oldest first, with the age of each event.
    func diagnosticsLines(now: Date = Date()) -> [String] {
        var lines = ["Safety Events (last 60 s):"]
        let recent = recent(now: now)
        if recent.isEmpty {
            lines.append("  none")
        } else {
            for event in recent {
                let age = max(0, now.timeIntervalSince(event.time))
                lines.append(String(format: "  -%.1f s  %@  %@", age, event.kind.rawValue, event.message))
            }
        }
        if let why = lastDisarmExplanation { lines.append("Last disarm: \(why)") }
        return lines
    }

    private mutating func prune(now: Date) {
        events.removeAll { now.timeIntervalSince($0.time) > Self.retentionSeconds }
        if events.count > Self.maximumEvents {
            events.removeFirst(events.count - Self.maximumEvents)
        }
    }

    /// Plain-language reason a disarm happened.
    static func explanation(for reason: LiveTreatmentDisarmReason) -> String {
        switch reason {
        case .user: return "You turned Quiet Zone off."
        case .outputDeviceChanged: return "The output device changed, so the cancellation no longer matched your speakers."
        case .outputDeviceLost: return "The output device disappeared."
        case .sleep: return "The Mac went to sleep."
        case .sampleRateChanged: return "The audio sample rate changed, so the cancellation had to be rebuilt."
        case .inputLost: return "A measurement microphone was lost."
        case .microphoneInvalid: return "The microphone signal was silent, frozen, clipped or otherwise invalid."
        case .engineStopped: return "Audio processing stopped."
        case .quit: return "Notch Sixty was quitting."
        case .transportReconfigured: return "The audio path was rebuilt."
        case .instabilityTrip: return "The howl guard heard a runaway tone and muted the anti-noise."
        case .microphoneStalled: return "The microphone analysis stopped updating."
        case .inputDeviceChanged: return "The measurement microphone changed."
        case .outputGainChanged: return "The output volume changed enough to throw off the cancellation."
        case .seatRegression: return "The seat microphone heard a tone or band louder than before arming, so the anti-noise was backed out."
        case .microphoneMoved: return "The measurement microphone moved and the supervised re-tune did not recover, so the anti-noise was stopped."
        case .adaptiveFault: return "The adaptive tuning faulted, so the anti-noise was stopped."
        }
    }
}
