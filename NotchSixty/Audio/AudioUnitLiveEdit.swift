import AudioToolbox
import AVFAudio
import Foundation

/// E33 S23 (`e33.page-enhancements`): edit a plug-in by ear, its own presets, copy and paste of its settings.
///
/// Control plane only (main actor). Nothing here runs on the render path. The editor attaches to the unit the rack is
/// already rendering, so a parameter change is heard at once and no new generation is built. The one realtime-adjacent
/// change is that the stage's control-plane health check does not call a latency or tail change a fault while its unit is
/// being edited (`AudioUnitLiveProcessStage.setLiveEditing`); the controlled restart then runs when the editor closes.

/// One entry in a plug-in's own preset list (factory presets of the unit, or presets the user saved in the unit).
struct AudioUnitPresetEntry: Equatable, Identifiable, Sendable {
    let number: Int
    let name: String
    let isFactory: Bool
    var id: String { "\(isFactory ? "f" : "u")\(number):\(name)" }
}

/// The unit being edited. The system implementation wraps an `AUAudioUnit`; tests use a fake.
@MainActor
protocol AudioUnitLiveEditTarget: AnyObject {
    func captureState() throws -> Data
    func restoreState(_ data: Data) throws
    /// Reported latency now, in frames at the rack rate; nil when the unit reports a value outside the accepted range.
    var reportedLatencyFrames: Int? { get }
    func presets() -> [AudioUnitPresetEntry]
    func applyPreset(_ entry: AudioUnitPresetEntry) throws
    /// True while the editor is open, so the live stage does not treat a latency change as a fault.
    func setEditing(_ editing: Bool)
}

enum AudioUnitLiveEditError: Error, Equatable, LocalizedError {
    case stateUnavailable
    case invalidState
    case stateTooLarge(Int)
    case presetUnavailable(String)
    case differentPlugIn

    var errorDescription: String? {
        switch self {
        case .stateUnavailable:
            return "The plug-in did not expose settings that can be saved."
        case .invalidState:
            return "The saved plug-in settings could not be restored."
        case .stateTooLarge(let bytes):
            return "The plug-in settings are too large (\(bytes) bytes)."
        case .presetUnavailable(let name):
            return "The preset \"\(name)\" is no longer available in the plug-in."
        case .differentPlugIn:
            return "Those settings were copied from a different plug-in. Paste works only onto the same plug-in."
        }
    }
}

/// What closing the editor does.
enum AudioUnitLiveEditOutcome: Equatable, Sendable {
    /// Settings equal those captured when the window opened: nothing to save.
    case unchanged
    /// Save through the existing rack transaction. `latencyChanged` means the rack restarts (existing controlled restart).
    case commit(state: Data, latencyChanged: Bool)
}

@MainActor
final class AudioUnitLiveEditSession {
    /// A latency that differs from what the rack was built with by more than this is a change (the runtime's rule).
    static let latencyToleranceFrames = 1

    private let target: any AudioUnitLiveEditTarget
    /// Settings as they were when the window opened. Revert restores exactly these bytes.
    let capturedState: Data
    let renderedLatencyFrames: Int
    private(set) var isEnded = false

    init(target: any AudioUnitLiveEditTarget, renderedLatencyFrames: Int) throws {
        self.target = target
        self.renderedLatencyFrames = renderedLatencyFrames
        capturedState = try target.captureState()
        target.setEditing(true)
    }

    var presets: [AudioUnitPresetEntry] { target.presets() }

    var reportedLatencyFrames: Int? { target.reportedLatencyFrames }

    /// True when the unit now reports a latency that differs from the one the rack was built with.
    var latencyChanged: Bool {
        guard let now = target.reportedLatencyFrames else { return true }
        return abs(now - renderedLatencyFrames) > Self.latencyToleranceFrames
    }

    var hasEdits: Bool {
        guard let now = try? target.captureState() else { return false }
        return !Self.sameSettings(now, capturedState)
    }

    func applyPreset(_ entry: AudioUnitPresetEntry) throws {
        try target.applyPreset(entry)
    }

    func revert() throws {
        try target.restoreState(capturedState)
    }

    /// Decides what closing does. Does not end the session: the caller ends it after the rack transaction.
    func finish() throws -> AudioUnitLiveEditOutcome {
        let now = try target.captureState()
        let changed = latencyChanged
        if Self.sameSettings(now, capturedState), !changed { return .unchanged }
        return .commit(state: now, latencyChanged: changed)
    }

    /// Same bytes, or the same property list (a unit may re-serialise identical settings in another byte order).
    static func sameSettings(_ a: Data, _ b: Data) -> Bool {
        if a == b { return true }
        guard let x = try? PropertyListSerialization.propertyList(from: a, options: [], format: nil),
              let y = try? PropertyListSerialization.propertyList(from: b, options: [], format: nil) else { return false }
        return (x as AnyObject).isEqual(y)
    }

    func end() {
        guard !isEnded else { return }
        isEnded = true
        target.setEditing(false)
    }

    /// Plain sentence for the editor while an edit has moved the plug-in's delay.
    static func latencyNotice(rendered: Int, now: Int?, sampleRate: Double) -> String {
        guard let now, sampleRate > 0 else {
            return "This plug-in now reports a delay outside the accepted range."
        }
        let ms = { (frames: Int) in String(format: "%.1f", Double(frames) / sampleRate * 1_000) }
        return "This change moves the plug-in's delay from \(ms(rendered)) ms to \(ms(now)) ms. Closing the editor restarts audio briefly to keep the rack in time."
    }
}

/// Settings copied from one slot, kept for pasting onto another slot holding the same plug-in (this or another Content
/// Preset). No preset library of our own (owner decision 28): this is one in-memory value.
struct AudioUnitSettingsClipboard: Equatable, Sendable {
    let component: AudioUnitComponentIdentity
    let displayName: String?
    let state: Data?

    init?(copying slot: AudioUnitRackSlotState) {
        guard let component = slot.component else { return nil }
        self.component = component
        displayName = slot.displayName
        state = slot.opaqueFullState
    }

    func canPaste(onto slot: AudioUnitRackSlotState) -> Bool {
        slot.component == component
    }

    /// The mutation that pastes onto `index`; refused for a different plug-in.
    func pasteMutation(onto slot: AudioUnitRackSlotState, index: Int) throws -> AudioUnitRackMutation {
        guard canPaste(onto: slot) else { throw AudioUnitLiveEditError.differentPlugIn }
        return .setOpaqueFullState(slot: index, state: state)
    }
}

/// The system target: an `AUAudioUnit`, either the one the rack renders (`stage` set) or a detached copy.
@MainActor
final class AUAudioUnitEditTarget: AudioUnitLiveEditTarget {
    let audioUnit: AUAudioUnit
    private let sampleRate: Double
    private let stage: AudioUnitLiveProcessStage?

    init(audioUnit: AUAudioUnit, sampleRate: Double, stage: AudioUnitLiveProcessStage? = nil) {
        self.audioUnit = audioUnit
        self.sampleRate = sampleRate
        self.stage = stage
    }

    func captureState() throws -> Data {
        try Self.encodeState(of: audioUnit)
    }

    func restoreState(_ data: Data) throws {
        try Self.decodeState(data, into: audioUnit)
    }

    var reportedLatencyFrames: Int? {
        AudioUnitLiveTimingValidator.frameCount(
            seconds: audioUnit.latency,
            sampleRate: sampleRate,
            maximumSeconds: AudioUnitProbeResult.maximumLatencySeconds
        )
    }

    func presets() -> [AudioUnitPresetEntry] {
        let factory = (audioUnit.factoryPresets ?? []).map {
            AudioUnitPresetEntry(number: $0.number, name: $0.name, isFactory: true)
        }
        let user = audioUnit.userPresets.map {
            AudioUnitPresetEntry(number: $0.number, name: $0.name, isFactory: false)
        }
        return factory + user
    }

    func applyPreset(_ entry: AudioUnitPresetEntry) throws {
        guard presets().contains(entry) else {
            throw AudioUnitLiveEditError.presetUnavailable(entry.name)
        }
        let preset = AUAudioUnitPreset()
        preset.number = entry.number
        preset.name = entry.name
        audioUnit.currentPreset = preset
    }

    func setEditing(_ editing: Bool) {
        stage?.setLiveEditing(editing)
    }

    static func encodeState(of audioUnit: AUAudioUnit) throws -> Data {
        guard let state = audioUnit.fullState ?? audioUnit.fullStateForDocument,
              PropertyListSerialization.propertyList(state, isValidFor: .binary) else {
            throw AudioUnitLiveEditError.stateUnavailable
        }
        let data = try PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
        guard data.count <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitLiveEditError.stateTooLarge(data.count)
        }
        return data
    }

    static func decodeState(_ data: Data, into audioUnit: AUAudioUnit) throws {
        guard data.count <= AudioUnitRackSlotState.maximumOpaqueStateBytes else {
            throw AudioUnitLiveEditError.stateTooLarge(data.count)
        }
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let state = object as? [String: Any] else { throw AudioUnitLiveEditError.invalidState }
        audioUnit.fullState = state
    }
}
