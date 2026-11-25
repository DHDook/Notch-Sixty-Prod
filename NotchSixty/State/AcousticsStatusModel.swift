import Combine
import Foundation

// E12 S22: plain status for Active Acoustics as a pure model. Control plane only; the engine never sees it and it
// arms nothing. It decides three things: the microphone line on the page, the one status line per feature on the
// Dashboard, and the plain words on the Room Treatment tab. Words follow `docs/PLAIN_WORDING.md`.

enum AcousticsMicrophoneState: Equatable, Sendable {
    case permissionNeeded
    case notChosen
    /// The chosen microphone is not connected. It is kept, so the same one resumes when it returns.
    case lost(name: String)
    /// Chosen and connected, but nothing is listening to it right now.
    case ready(name: String)
    case live(name: String)
    case problem(name: String)

    var isLive: Bool { if case .live = self { return true } else { return false } }

    var isLost: Bool { if case .lost = self { return true } else { return false } }

    var title: String {
        switch self {
        case .live: return "Microphone live"
        case .lost: return "Microphone lost"
        case .problem: return "Microphone problem"
        case .ready: return "Microphone ready"
        case .notChosen: return "No microphone chosen"
        case .permissionNeeded: return "Microphone access needed"
        }
    }

    var detail: String {
        switch self {
        case .permissionNeeded: return "Allow microphone access, then choose your measurement microphone."
        case .notChosen: return "Choose your measurement microphone below."
        case .lost(let name):
            return "\(name) is not connected. Playback Adaptation has faded out and resumes when it is back. Quiet Zone is off and stays off until you turn it on again."
        case .ready(let name): return "\(name) is connected. It listens when Playback Adaptation is on or Quiet Zone is armed."
        case .live(let name): return "Listening through \(name)."
        case .problem(let name): return "\(name) is connected but not giving a usable signal."
        }
    }

    static let sharedNote = "One microphone serves both Playback Adaptation and Quiet Zone."
}

struct AcousticsStatusLine: Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var text: String
    var isOn: Bool
}

struct AcousticsStatusInputs: Equatable, Sendable {
    var microphoneLost = false
    var playbackAdaptationOn = false
    var quietZoneArmed = false
    var quietZoneFault = false
    /// Why Quiet Zone went off by itself, in plain words; nil when it did not.
    var quietZoneOffReason: String?
    /// False when Room Treatment is not available in this build.
    var roomTreatmentAvailable = true
    var roomTreatment: DashboardAcoustics = .notSetUp
}

enum AcousticsStatusModel {
    static func microphoneState(
        permissionGranted: Bool, selectedName: String?, lostName: String?, monitorStatus: AmbientCompensationMonitorStatus
    ) -> AcousticsMicrophoneState {
        guard permissionGranted else { return .permissionNeeded }
        if let lostName { return .lost(name: lostName) }
        guard let name = selectedName else { return .notChosen }
        switch monitorStatus {
        case .observing, .compensating, .held: return .live(name: name)
        case .failed: return .problem(name: name)
        case .stopped: return .ready(name: name)
        }
    }

    /// One read-only line per feature. No control: the menu bar remote carries none of these (owner decision 12).
    static func lines(_ i: AcousticsStatusInputs) -> [AcousticsStatusLine] {
        var lines: [AcousticsStatusLine] = []
        let adaptation: String
        if i.playbackAdaptationOn && i.microphoneLost { adaptation = "Paused, microphone lost" }
        else if i.playbackAdaptationOn { adaptation = "On, adapting your music to the room" }
        else { adaptation = "Off" }
        lines.append(.init(id: "playbackAdaptation", title: "Playback Adaptation", text: adaptation,
                           isOn: i.playbackAdaptationOn && !i.microphoneLost))
        let quiet: String
        if i.quietZoneFault { quiet = "Stopped safely after a problem" }
        else if i.quietZoneArmed { quiet = "On, reducing noise at your seat" }
        else if let reason = i.quietZoneOffReason { quiet = reason }
        else { quiet = "Off. It starts only when you turn it on" }
        lines.append(.init(id: "quietZone", title: "Quiet Zone", text: quiet, isOn: i.quietZoneArmed && !i.quietZoneFault))
        if i.roomTreatmentAvailable {
            let on: Bool
            if case .active = i.roomTreatment { on = true } else { on = false }
            lines.append(.init(id: "roomTreatment", title: "Room Treatment",
                               text: DashboardModel.acousticsLine(i.roomTreatment), isOn: on))
        }
        return lines
    }

    // MARK: Room Treatment honesty (G32)

    static let roomTreatmentHeadline = "You can design and preview. Turning it on needs a qualified setup."
    static let roomTreatmentDifference =
        "Room Correction reshapes the sound for your listening position. Room Treatment uses your speakers together to shorten how long bass rings at several seats."

    /// What this setup is missing before Room Treatment can be turned on, in plain words. Empty when nothing is.
    static func roomTreatmentMissing(
        measuredSpeakers: Bool, designed: Bool, qualified: Bool, refusals: [String]
    ) -> [String] {
        var missing: [String] = []
        if !measuredSpeakers { missing.append("Measure your speakers at each seat.") }
        if !designed { missing.append("Design a treatment and check the preview.") }
        if !qualified { missing.append("Qualify this setup. Room Treatment can only be turned on for a qualified setup.") }
        for reason in refusals where !missing.contains(reason) { missing.append(reason) }
        return missing
    }
}

/// E12 S22: reads the three controllers for the model above and republishes their changes, so the Dashboard and the
/// page redraw when the microphone or a feature changes. Read-only: it holds no switch and never arms anything.
@MainActor
final class AcousticsStatusSource: ObservableObject {
    private weak var ambient: AmbientCompensationController?
    private weak var quietZone: ActiveQuietZoneController?
    private weak var microphone: RoomCorrectionCalibrationController?
    private weak var mimoTreatment: MIMOTreatmentController?
    private var changes: [AnyCancellable] = []

    init(
        ambient: AmbientCompensationController? = nil, quietZone: ActiveQuietZoneController? = nil,
        microphone: RoomCorrectionCalibrationController? = nil, mimoTreatment: MIMOTreatmentController? = nil
    ) {
        self.ambient = ambient
        self.quietZone = quietZone
        self.microphone = microphone
        self.mimoTreatment = mimoTreatment
        let send: () -> Void = { [weak self] in self?.objectWillChange.send() }
        if let ambient { changes.append(ambient.objectWillChange.sink { _ in send() }) }
        if let quietZone { changes.append(quietZone.objectWillChange.sink { _ in send() }) }
        if let microphone { changes.append(microphone.objectWillChange.sink { _ in send() }) }
    }

    var microphoneState: AcousticsMicrophoneState {
        guard let microphone, let ambient else { return .notChosen }
        return AcousticsStatusModel.microphoneState(
            permissionGranted: microphone.permissionStatus == .authorized,
            selectedName: microphone.selectedInputDevice?.name,
            lostName: microphone.lostInput?.name,
            monitorStatus: ambient.monitorStatus)
    }

    func lines(roomTreatment: DashboardAcoustics) -> [AcousticsStatusLine] {
        guard let ambient, let quietZone else { return [] }
        var inputs = AcousticsStatusInputs()
        inputs.microphoneLost = microphone?.lostInput != nil
        inputs.playbackAdaptationOn = ambient.playbackAdaptationActive
        inputs.quietZoneArmed = quietZone.arm.isArmed
        inputs.quietZoneFault = quietZone.status == .fault && quietZone.arm.isArmed
        inputs.quietZoneOffReason = quietZone.arm.latchedByEvent ? quietZone.arm.statusMessage : nil
        inputs.roomTreatmentAvailable = mimoTreatment?.isAvailable ?? true
        inputs.roomTreatment = roomTreatment
        return AcousticsStatusModel.lines(inputs)
    }
}
