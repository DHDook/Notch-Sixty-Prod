import Carbon.HIToolbox
import Combine
import Foundation

// E16 S2 (behind `e16.automation`): user-assigned global hotkeys. Carbon `RegisterEventHotKey` works in the App Sandbox
// and needs no permission. None are assigned by default (owner Q5). A hotkey builds a `ControlCommand` and hands it to
// `ControlService`, so every rule that applies to the UI applies here. No action arms Quiet Zone or MIMO.

enum HotkeyAction: String, CaseIterable, Codable, Identifiable, Sendable {
    case processing, bypass, roomCorrection, nextPreset, previousPreset, volumeUp, volumeDown, mute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .processing: return "Processing on or off"
        case .bypass: return "Bypass on or off"
        case .roomCorrection: return "Room correction on or off"
        case .nextPreset: return "Next preset"
        case .previousPreset: return "Previous preset"
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .mute: return "Mute on or off"
        }
    }
}

/// A key code plus Carbon modifier bits (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
struct HotkeyBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let commandBit = UInt32(cmdKey)
    static let shiftBit = UInt32(shiftKey)
    static let optionBit = UInt32(optionKey)
    static let controlBit = UInt32(controlKey)

    /// A bare key (or Shift alone) would swallow ordinary typing, so one of these is required.
    var hasRequiredModifier: Bool { modifiers & (Self.commandBit | Self.optionBit | Self.controlBit) != 0 }

    var display: String {
        var text = ""
        if modifiers & Self.controlBit != 0 { text += "⌃" }
        if modifiers & Self.optionBit != 0 { text += "⌥" }
        if modifiers & Self.shiftBit != 0 { text += "⇧" }
        if modifiers & Self.commandBit != 0 { text += "⌘" }
        return text + Self.keyName(keyCode)
    }

    private static let names: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W",
        14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9",
        103: "F11", 105: "F13", 109: "F10", 111: "F12", 118: "F4", 120: "F2", 122: "F1", 123: "←", 124: "→",
        125: "↓", 126: "↑"
    ]

    static func keyName(_ code: UInt32) -> String { names[code] ?? "Key \(code)" }
}

enum HotkeyRegistrationResult: Equatable {
    case registered
    case failed(String)
}

protocol GlobalHotkeyRegistering: AnyObject {
    /// Called on the main thread with the id passed to `register`.
    var onPress: ((UInt32) -> Void)? { get set }
    func register(id: UInt32, binding: HotkeyBinding) -> HotkeyRegistrationResult
    func unregisterAll()
}

/// The production backend: Carbon hot keys on the application event target.
final class CarbonHotkeyRegistrar: GlobalHotkeyRegistering {
    var onPress: ((UInt32) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private static let signature: OSType = 0x4E36_4B59  // "N6KY"

    func register(id: UInt32, binding: HotkeyBinding) -> HotkeyRegistrationResult {
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            binding.keyCode, binding.modifiers, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs.append(ref)
            return .registered
        }
        return .failed(status == OSStatus(eventHotKeyExistsErr)
            ? "That shortcut is already used by another app or by macOS."
            : "macOS would not register that shortcut.")
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                    MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
                let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
                registrar.onPress?(hotKeyID.id)
                return noErr
            },
            1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        unregisterAll()
        if let handler { RemoveEventHandler(handler) }
    }
}

@MainActor
final class HotkeyController: ObservableObject {
    static let defaultsKey = "automation.hotkeys"

    @Published private(set) var bindings: [HotkeyAction: HotkeyBinding] = [:]
    /// Why an assigned shortcut is not active (another app owns it), by action.
    @Published private(set) var problems: [HotkeyAction: String] = [:]

    private let registrar: GlobalHotkeyRegistering
    private let defaults: UserDefaults
    private let service: @MainActor () -> ControlService?
    private let volumeStep: @MainActor () -> MasterVolumeKeyStep
    private let isEnabled: @MainActor () -> Bool

    init(
        registrar: GlobalHotkeyRegistering,
        defaults: UserDefaults = .standard,
        service: @escaping @MainActor () -> ControlService?,
        volumeStep: @escaping @MainActor () -> MasterVolumeKeyStep,
        isEnabled: @escaping @MainActor () -> Bool
    ) {
        self.registrar = registrar
        self.defaults = defaults
        self.service = service
        self.volumeStep = volumeStep
        self.isEnabled = isEnabled
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: HotkeyBinding].self, from: data) {
            for (key, binding) in stored {
                if let action = HotkeyAction(rawValue: key) { bindings[action] = binding }
            }
        }
        registrar.onPress = { [weak self] id in
            MainActor.assumeIsolated {
                guard let self, let action = HotkeyAction.allCases.first(where: { Self.hotkeyID($0) == id }) else { return }
                Task { await self.dispatch(action) }
            }
        }
        refreshRegistrations()
    }

    static func hotkeyID(_ action: HotkeyAction) -> UInt32 {
        UInt32((HotkeyAction.allCases.firstIndex(of: action) ?? 0) + 1)
    }

    /// Registers every stored shortcut while `e16.automation` is on, and none while it is off.
    func refreshRegistrations() {
        registrar.unregisterAll()
        problems = [:]
        guard isEnabled() else { return }
        for action in HotkeyAction.allCases {
            guard let binding = bindings[action] else { continue }
            if case .failed(let reason) = registrar.register(id: Self.hotkeyID(action), binding: binding) {
                problems[action] = reason
            }
        }
    }

    /// Returns nil when assigned, or the plain reason it was refused.
    @discardableResult
    func assign(_ binding: HotkeyBinding, to action: HotkeyAction) -> String? {
        guard binding.hasRequiredModifier else { return "Include Command, Control or Option so typing is not affected." }
        if let other = bindings.first(where: { $0.key != action && $0.value == binding })?.key {
            return "Already used for \"\(other.title)\"."
        }
        let previous = bindings[action]
        bindings[action] = binding
        refreshRegistrations()
        if let reason = problems[action] {
            bindings[action] = previous
            refreshRegistrations()
            return reason
        }
        persist()
        return nil
    }

    func clear(_ action: HotkeyAction) {
        bindings[action] = nil
        refreshRegistrations()
        persist()
    }

    private func persist() {
        let stored = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        defaults.set(try? JSONEncoder().encode(stored), forKey: Self.defaultsKey)
    }

    /// The command a hotkey issues, or nil when it has nothing to do (no presets).
    func command(for action: HotkeyAction, snapshot: ControlStateSnapshot, presets: [ControlPresetInfo]) -> ControlCommand? {
        switch action {
        case .processing: return .setProcessing(!snapshot.processing)
        case .bypass: return .setBypass(!snapshot.bypassed)
        case .roomCorrection: return .setRoomCorrection(!snapshot.roomCorrection)
        case .mute: return .toggleMute
        case .volumeUp, .volumeDown:
            let level = volumeStep().level(afterPress: action == .volumeUp ? 1 : -1, from: snapshot.volumeLevel)
            return .setVolume(level)
        case .nextPreset, .previousPreset:
            guard let first = presets.first, let last = presets.last else { return nil }
            let forward = action == .nextPreset
            guard let current = snapshot.preset.flatMap({ named in presets.firstIndex { $0.id == named.id } }) else {
                return .selectPreset((forward ? first : last).id)
            }
            let next = (current + (forward ? 1 : presets.count - 1)) % presets.count
            return .selectPreset(presets[next].id)
        }
    }

    @discardableResult
    func dispatch(_ action: HotkeyAction) async -> ControlResult {
        guard isEnabled(), let service = service() else { return .refused(ControlRefusal.notAvailable) }
        guard let command = command(for: action, snapshot: service.snapshot, presets: service.presets) else {
            return .refused("There are no presets to switch between.")
        }
        return await service.perform(command)
    }
}
