import Foundation

// E16 S1 (behind `e16.automation`): the one command vocabulary every automation surface speaks. Intents, hotkeys, media
// keys, the widget, the local API and the remote panel all build a `ControlCommand` and hand it to `ControlService`.

/// A user-level action. None of them arms live Quiet Zone or MIMO treatment, and none selects an output device.
enum ControlCommand: Equatable, Sendable {
    case selectSystem(UUID)
    case selectPreset(UUID)
    /// An absolute level in `MasterVolumeConfiguration.levelRange`.
    case setVolume(Double)
    /// A relative level change; the result is clamped to the range.
    case stepVolume(Double)
    case setMuted(Bool)
    case toggleMute
    case setBypass(Bool)
    case setProcessing(Bool)
    case setRoomCorrection(Bool)
    case readStatus
}

enum ControlResult: Equatable, Sendable {
    case done
    case status(ControlStateSnapshot)
    /// Nothing changed; `reason` is plain text fit to show the user.
    case refused(String)

    var refusalReason: String? {
        if case .refused(let reason) = self { return reason }
        return nil
    }
}

/// Plain reasons, shared by every surface.
enum ControlRefusal {
    static let notAvailable = "Not available in this build."
    static let safeLaunch = "Choose how to open Notch Sixty first (Safe Launch)."
    static let engineFailed = "Audio failed; turn Processing off and on again first."
    static let busy = "Notch Sixty is starting or stopping; try again in a moment."
    static let invalidLevel = "That volume level is out of range."
    static let unknownSystem = "That Playback System no longer exists."
    static let unknownPreset = "That preset no longer exists."
    static func otherOutput(_ device: String) -> String {
        "This system is for \(device); choose it in Notch Sixty."
    }
}

/// The state every surface reads. Versioned so the widget file and the API can evolve additively.
struct ControlStateSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1

    struct Named: Codable, Equatable, Sendable {
        var id: UUID
        var name: String
    }

    var version = ControlStateSnapshot.currentVersion
    var processing: Bool
    var bypassed: Bool
    var roomCorrection: Bool
    /// 0...1 on the same scale as the volume slider.
    var volumeLevel: Double
    var muted: Bool
    /// How volume reaches the output: "softwareDSP" or "device".
    var controlMode: String
    var outputName: String?
    var outputUID: String?
    var system: Named?
    var preset: Named?
    /// Read-only text. No command arms either feature.
    var quietZoneStatus: String
    var roomTreatmentStatus: String
}
