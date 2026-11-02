import Foundation

/// E24 S2: the one answer to "can this surface measure now, and if not, why". Pure; the four
/// measure surfaces (setup wizard, Room Correction, multichannel calibration, Speaker Lab)
/// gather their inputs and show `reason` under every disabled measure button.
///
/// Playback is never a blocker. Every measure path stops normal playback first and shows
/// `MeasurementPlaybackPolicy.stoppedNotice` (owner decision, 1 Nov 2026).
enum MeasurementReadiness: Equatable {
    /// What the user can do about a block, where there is something to do.
    enum Fix: Equatable {
        case grantMicrophoneAccess
        case openSystemSettings
        case selectMicrophone
        case selectOutput
        case describeSpeakers
        case startSession
    }

    struct Blocker: Equatable {
        let reason: String
        let fix: Fix?
    }

    struct Inputs: Equatable {
        var permission: MicrophonePermissionStatus
        var hasInputDevice: Bool
        var hasOutputDevice: Bool
        /// The surface needs an enabled output device profile (multichannel, Speaker Lab).
        var requiresProfile: Bool = false
        var hasProfile: Bool = true
        /// The surface needs a session or campaign that has a next step (lab session, campaign).
        var requiresWork: Bool = false
        var hasWork: Bool = true
        var transportActive: Bool = false
        /// A short name for a busy state such as "measuring" or "analysing", else nil.
        var busyDescription: String?
        /// The surface is not in a state that can start (for example it is failed and needs reset).
        var stateAllowsStart: Bool = true
        /// Bytes the sweep timeline would hold (playback plus capture buffers); nil when not known.
        var timelineBytes: Int?
    }

    /// The most memory a measurement timeline may use (design note 9).
    static let timelineBudgetBytes = 512_000_000

    /// Playback plus capture buffers for one pass of `settings` (float32 each).
    static func timelineBytes(for settings: RoomCorrectionSweepSettings) -> Int {
        let rate = settings.sampleRate
        let sweep = settings.durationSeconds * rate
        let tail = settings.tailSeconds * rate
        let frames = settings.leadInSeconds * rate + Double(max(1, settings.repeatCount)) * (sweep + tail)
        let bytes = frames * 8
        return bytes.isFinite && bytes < Double(Int.max) ? Int(bytes) : Int.max
    }

    case ready
    case blocked(Blocker)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var reason: String? {
        if case .blocked(let blocker) = self { return blocker.reason }
        return nil
    }

    var fix: Fix? {
        if case .blocked(let blocker) = self { return blocker.fix }
        return nil
    }

    static func evaluate(_ inputs: Inputs) -> MeasurementReadiness {
        if inputs.transportActive || inputs.busyDescription != nil {
            return .blocked(Blocker(
                reason: "A measurement is already \(inputs.busyDescription ?? "running"). Wait for it to finish or cancel it.",
                fix: nil))
        }
        switch inputs.permission {
        case .authorized:
            break
        case .notDetermined:
            return .blocked(Blocker(
                reason: "Microphone access has not been granted yet. Allow it to measure the room.",
                fix: .grantMicrophoneAccess))
        case .denied:
            return .blocked(Blocker(
                reason: "Microphone access is denied. Enable it for Notch Sixty in System Settings.",
                fix: .openSystemSettings))
        case .restricted:
            return .blocked(Blocker(
                reason: "Microphone access is restricted for this account or Mac, so measuring is not possible.",
                fix: nil))
        }
        if !inputs.hasInputDevice {
            return .blocked(Blocker(reason: "Choose a measurement microphone.", fix: .selectMicrophone))
        }
        if !inputs.hasOutputDevice {
            return .blocked(Blocker(reason: "Choose the Playback System output device.", fix: .selectOutput))
        }
        if inputs.requiresProfile && !inputs.hasProfile {
            return .blocked(Blocker(
                reason: "Enable and configure an output device profile for this output first.",
                fix: .describeSpeakers))
        }
        if inputs.requiresWork && !inputs.hasWork {
            return .blocked(Blocker(
                reason: "Everything planned has already been measured. Review the results, or reset to measure again.",
                fix: .startSession))
        }
        if !inputs.stateAllowsStart {
            return .blocked(Blocker(reason: "The last measurement did not complete. Reset or review it before measuring again.", fix: nil))
        }
        if let bytes = inputs.timelineBytes, bytes > timelineBudgetBytes {
            return .blocked(Blocker(
                reason: "This sweep needs about \(bytes / 1_000_000) MB of buffer at this sample rate, over the \(timelineBudgetBytes / 1_000_000) MB limit. Use a shorter sweep or fewer repeats.",
                fix: nil))
        }
        return .ready
    }
}

/// The seam a controller uses to see and stop normal playback; tests inject a fake because the
/// real engine cannot start without hardware.
struct MeasurementPlaybackControl {
    var isRunning: () -> Bool
    var stop: () -> Void

    @MainActor
    static func engine(_ engine: AudioIOEngine) -> MeasurementPlaybackControl {
        MeasurementPlaybackControl(
            isRunning: { engine.lifecycleState != .idle },
            stop: { engine.stop() })
    }
}

/// E24 S2: one playback policy for every measure path.
enum MeasurementPlaybackPolicy {
    @MainActor
    static func stopPlaybackIfRunning(_ control: MeasurementPlaybackControl) -> String? {
        stopPlaybackIfRunning(isRunning: control.isRunning(), stop: control.stop)
    }

    static let stoppedNotice = "Playback was stopped so the speakers can be measured. Start it again when you finish."

    /// Stops normal playback if it is running and returns the notice to show, else nil.
    /// `AudioIOEngine.stop()` tears the transport down through the normal fade, which also ends
    /// any armed Quiet Zone feed-forward session via the transport's own disarm path.
    @MainActor
    static func stopPlaybackIfRunning(_ engine: AudioIOEngine) -> String? {
        stopPlaybackIfRunning(isRunning: engine.lifecycleState != .idle) { engine.stop() }
    }

    /// The policy itself, separated from the engine so it can be tested without hardware.
    static func stopPlaybackIfRunning(isRunning: Bool, stop: () -> Void) -> String? {
        guard isRunning else { return nil }
        stop()
        return stoppedNotice
    }
}
