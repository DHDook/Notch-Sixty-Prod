import AppIntents
import Foundation

// E16 S1 (behind `e16.automation`): App Intents for Shortcuts. Compiled into every build (App Intents metadata is static)
// and each one refuses with "Not available in this build." while the flag is off. There is no `AppShortcutsProvider`
// until S6, so no Spotlight or Siri phrase shows before graduation. Every intent goes through `ControlService`; none
// arms live treatment or selects an output.

struct ControlIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func runControl(_ command: ControlCommand) async throws {
    if let reason = await AutomationRuntime.shared.run(command).refusalReason {
        throw ControlIntentError(message: reason)
    }
}

// MARK: Entities

struct PlaybackSystemEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Playback System"
    static let defaultQuery = PlaybackSystemQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaybackSystemQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [PlaybackSystemEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [PlaybackSystemEntity] {
        (AutomationRuntime.shared.service?.systems ?? []).map { PlaybackSystemEntity(id: $0.id, name: $0.name) }
    }
}

struct ContentPresetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Preset"
    static let defaultQuery = ContentPresetQuery()

    var id: UUID
    var name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ContentPresetQuery: EntityQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ContentPresetEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }

    @MainActor
    func suggestedEntities() async throws -> [ContentPresetEntity] {
        (AutomationRuntime.shared.service?.presets ?? []).map { ContentPresetEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: Intents

struct SelectPlaybackSystemIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Playback System"
    static let description = IntentDescription("Switches Notch Sixty to a Playback System for the current output.")

    @Parameter(title: "Playback System") var system: PlaybackSystemEntity

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.selectSystem(system.id))
        return .result()
    }
}

struct SelectPresetIntent: AppIntent {
    static let title: LocalizedStringResource = "Select Preset"
    static let description = IntentDescription("Switches Notch Sixty to a content preset.")

    @Parameter(title: "Preset") var preset: ContentPresetEntity

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.selectPreset(preset.id))
        return .result()
    }
}

struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Volume"
    static let description = IntentDescription("Sets the Notch Sixty volume, 0 to 100 percent of the volume slider.")

    @Parameter(title: "Percent", default: 50) var percent: Int

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.setVolume(Double(percent) / 100))
        return .result()
    }
}

struct ChangeVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Change Volume"
    static let description = IntentDescription("Raises or lowers the Notch Sixty volume by a number of percent.")

    @Parameter(title: "Change in percent", default: 5) var percent: Int

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.stepVolume(Double(percent) / 100))
        return .result()
    }
}

struct SetMuteIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Mute"

    @Parameter(title: "Muted", default: true) var muted: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.setMuted(muted))
        return .result()
    }
}

struct SetBypassIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Bypass"
    static let description = IntentDescription("Turns the global DSP bypass on or off.")

    @Parameter(title: "Bypassed", default: true) var bypassed: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.setBypass(bypassed))
        return .result()
    }
}

struct SetProcessingIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Processing"
    static let description = IntentDescription("Starts or stops Notch Sixty processing.")

    @Parameter(title: "Processing", default: true) var on: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.setProcessing(on))
        return .result()
    }
}

struct SetRoomCorrectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Room Correction"

    @Parameter(title: "Room correction on", default: true) var on: Bool

    @MainActor func perform() async throws -> some IntentResult {
        try await runControl(.setRoomCorrection(on))
        return .result()
    }
}

struct GetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Notch Sixty Status"
    static let description = IntentDescription("Reports processing, volume, output, Playback System and preset.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let result = await AutomationRuntime.shared.run(.readStatus)
        if let reason = result.refusalReason { throw ControlIntentError(message: reason) }
        guard case .status(let snapshot) = result else { throw ControlIntentError(message: AutomationRuntime.notReady) }
        return .result(value: ControlStatusText.describe(snapshot))
    }
}

/// Brings the app forward on Active Acoustics. Turn On stays the user's click in the app (owner Q2, 25 Nov 2026).
struct OpenQuietZoneIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Quiet Zone"
    static let description = IntentDescription("Opens Notch Sixty on Active Acoustics. It never turns Quiet Zone on.")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        if let reason = AutomationRuntime.shared.openQuietZone().refusalReason {
            throw ControlIntentError(message: reason)
        }
        return .result()
    }
}

/// One sentence for the status intent and the API.
enum ControlStatusText {
    static func describe(_ s: ControlStateSnapshot) -> String {
        var parts = [s.processing ? "Processing" : "Stopped"]
        if s.bypassed { parts.append("bypassed") }
        parts.append(s.muted ? "muted" : "volume \(Int((s.volumeLevel * 100).rounded())) percent")
        if let output = s.outputName { parts.append("output \(output)") }
        if let system = s.system { parts.append("system \(system.name)") }
        if let preset = s.preset { parts.append("preset \(preset.name)") }
        parts.append("room correction \(s.roomCorrection ? "on" : "off")")
        parts.append("Quiet Zone \(s.quietZoneStatus.lowercased())")
        return parts.joined(separator: ", ") + "."
    }
}
