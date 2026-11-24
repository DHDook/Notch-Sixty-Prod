import Foundation

// E12 S19 (flag `e12.active-acoustics-page`): the one Quiet Zone card as a pure model. Control plane only; the
// engine never sees it. It decides what the card shows (setup steps, the "where to quiet" choice, the two switches
// and their reasons, "Ready" or "Not ready"). It arms nothing: the Arm and Feed-forward switches stay the user's own
// action, through `ActiveQuietZoneController.setEnabled` and `requestFeedForwardLive`.

/// Where Quiet Zone quiets: the one choice that replaces the zone, ear and head-follow cards' separate switches.
enum QuietZoneAreaChoice: String, CaseIterable, Identifiable, Sendable {
    case oneSeat
    case followMyHead
    case twoZones
    case earPosition

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oneSeat: return "One seat"
        case .followMyHead: return "Follow my head"
        case .twoZones: return "Two zones"
        case .earPosition: return "Ear position"
        }
    }
}

/// The two switches on the page. There is no third "on" control.
enum QuietZoneSwitchID: String, CaseIterable, Identifiable, Sendable {
    case arm
    case feedForward

    var id: String { rawValue }
}

struct QuietZoneSwitchState: Equatable, Identifiable, Sendable {
    let id: QuietZoneSwitchID
    let title: String
    var isOn: Bool
    /// Why the switch cannot be turned on now; nil when it can. A disabled switch always has a reason.
    var disabledReason: String?

    var isEnabled: Bool { disabledReason == nil || isOn }
}

struct QuietZoneSetupStep: Equatable, Identifiable, Sendable {
    enum State: Equatable, Sendable { case done, todo, optional }

    let id: String
    let title: String
    var state: State
    /// What is set now, or what is missing.
    var detail: String
    /// The next action when the step is not done; nil when done.
    var nextAction: String?
}

enum QuietZoneReadiness: Equatable, Sendable {
    case ready
    case notReady(reason: String, action: String)

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .notReady: return "Not ready"
        }
    }
}

struct QuietZoneCardInputs: Equatable, Sendable {
    var microphonePermissionGranted: Bool
    var microphoneName: String?
    var engineRunning: Bool
    /// Name of the measured speaker-to-microphone model (a retained Room Correction position), if one is chosen.
    var measuredModelName: String?
    /// A subwoofer is in the anti-noise path and sub-aware Quiet Zone is on, so the sub measurement is a setup step.
    var subMeasurementApplies: Bool
    /// `SubAwareAncReadiness` message when the sub measurement is not done; nil when done.
    var subMeasurementMissing: String?
    var area: QuietZoneAreaChoice
    /// Why a choice cannot be picked now; absent when it can.
    var areaUnavailable: [QuietZoneAreaChoice: String]
    var armed: Bool
    /// Why the last disarm happened, in plain words; nil when there has been none since launch or the user disarmed.
    var lastAutoDisarmMessage: String?
    /// False when the feed-forward arming controller does not exist (its flag is off).
    var feedForwardAvailable: Bool
    var feedForwardOn: Bool
    var feedForwardFacts: FeedForwardLiveQuietZoneFacts
}

struct QuietZoneCardModel: Equatable, Sendable {
    let inputs: QuietZoneCardInputs

    init(_ inputs: QuietZoneCardInputs) { self.inputs = inputs }

    /// The text under the Arm switch: why it is off after a launch, or what tripped it.
    var armStatusLine: String {
        if inputs.armed { return "Armed. Quiet Zone is playing anti-noise." }
        if let message = inputs.lastAutoDisarmMessage { return message }
        return "Off after each launch for safety. Turn it on yourself when you are ready."
    }

    var steps: [QuietZoneSetupStep] {
        var steps: [QuietZoneSetupStep] = []
        let micReady = inputs.microphonePermissionGranted && inputs.microphoneName != nil
        steps.append(QuietZoneSetupStep(
            id: "microphone",
            title: "Choose a microphone",
            state: micReady ? .done : .todo,
            detail: micReady
                ? "Using \(inputs.microphoneName ?? "your microphone")."
                : (inputs.microphonePermissionGranted
                    ? "No microphone is chosen."
                    : "Microphone access is not allowed yet."),
            nextAction: micReady ? nil
                : (inputs.microphonePermissionGranted
                    ? "Choose your measurement microphone in Room Correction."
                    : "Allow microphone access in Settings, then choose your measurement microphone.")))
        steps.append(QuietZoneSetupStep(
            id: "measure",
            title: "Measure",
            state: inputs.measuredModelName != nil ? .done : .todo,
            detail: inputs.measuredModelName.map { "Measured at \($0)." }
                ?? "Quiet Zone needs a measurement of your speakers at the microphone.",
            nextAction: inputs.measuredModelName != nil ? nil
                : "Measure your speakers in Room Correction, then pick that position below."))
        if inputs.subMeasurementApplies {
            let missing = inputs.subMeasurementMissing
            steps.append(QuietZoneSetupStep(
                id: "subwoofer",
                title: "Measure your subwoofer",
                state: missing == nil ? .done : .todo,
                detail: missing ?? "Your subwoofer setup is measured.",
                nextAction: missing == nil ? nil : "Use Measure with your subwoofer below."))
        }
        steps.append(QuietZoneSetupStep(
            id: "area",
            title: "Choose where to quiet",
            state: .done,
            detail: "Quieting: \(inputs.area.title.lowercased()).",
            nextAction: nil))
        steps.append(QuietZoneSetupStep(
            id: "turnOn",
            title: "Turn on",
            state: inputs.armed ? .done : .todo,
            detail: inputs.armed ? "Quiet Zone is armed." : armTurnOnReason ?? "Ready to arm.",
            nextAction: inputs.armed ? nil : (armTurnOnReason == nil ? "Turn on Arm." : "Finish the steps above.")))
        return steps
    }

    /// Why Arm cannot be turned on now; nil when it can.
    var armTurnOnReason: String? {
        if !inputs.microphonePermissionGranted { return "Microphone access is not allowed yet." }
        if inputs.microphoneName == nil { return "Choose a microphone first." }
        if inputs.measuredModelName == nil { return "Measure your speakers first." }
        if !inputs.engineRunning { return "Start audio processing first." }
        if inputs.subMeasurementApplies, let missing = inputs.subMeasurementMissing { return missing }
        return nil
    }

    var readiness: QuietZoneReadiness {
        let facts = inputs.feedForwardFacts
        if !inputs.feedForwardAvailable {
            return .notReady(reason: "Feed-forward is not available in this build.", action: "Nothing to do.")
        }
        if facts.receiverBassUndeclared {
            return .notReady(
                reason: "Your receiver's bass handling is not declared.",
                action: "Say how your receiver handles bass in the setup above.")
        }
        if facts.subwooferActive {
            return .notReady(reason: "Feed-forward is not available with a subwoofer yet.", action: "Use Quiet Zone without feed-forward.")
        }
        if let why = facts.arrangementRefusal {
            return .notReady(reason: why, action: "Fix your speaker setup in System, then come back.")
        }
        if let why = facts.subAwareRefusal {
            return .notReady(reason: why, action: "Measure your subwoofer in the setup above.")
        }
        switch facts.budget.readiness {
        case .physicallyPlausible:
            return .ready
        case .missingMeasurements:
            return .notReady(
                reason: "The timing measurements are missing.",
                action: "Measure the listener, the upstream microphone and the listener again (see Hardware Acceptance).")
        case .invalidTimebase:
            return .notReady(
                reason: "The input and output clocks cannot be trusted.",
                action: "Use a device whose input and output share a clock, then measure again.")
        case .unreliableMeasurements:
            return .notReady(
                reason: "The timing measurements were too noisy or did not repeat.",
                action: "Measure again in a quiet room.")
        case .nonCausal:
            return .notReady(
                reason: "Anti-noise cannot arrive before the noise does at this setup.",
                action: "Move the upstream microphone closer to the noise source and measure again.")
        case .limitedMargin:
            return .notReady(
                reason: "The timing margin is too small to be safe.",
                action: "Move the upstream microphone closer to the noise source and measure again.")
        }
    }

    var switches: [QuietZoneSwitchState] {
        [armSwitch, feedForwardSwitch]
    }

    var armSwitch: QuietZoneSwitchState {
        QuietZoneSwitchState(
            id: .arm,
            title: "Arm",
            isOn: inputs.armed,
            disabledReason: inputs.armed ? nil : armTurnOnReason)
    }

    var feedForwardSwitch: QuietZoneSwitchState {
        var reason: String?
        if !inputs.armed {
            reason = "Turn on Arm first."
        } else if case .notReady(let why, _) = readiness {
            reason = why
        }
        return QuietZoneSwitchState(
            id: .feedForward,
            title: "Feed-forward",
            isOn: inputs.feedForwardOn,
            disabledReason: inputs.feedForwardOn ? nil : reason)
    }

    /// True when `choice` can be picked; `reason(for:)` says why not.
    func reason(for choice: QuietZoneAreaChoice) -> String? { inputs.areaUnavailable[choice] }
}
