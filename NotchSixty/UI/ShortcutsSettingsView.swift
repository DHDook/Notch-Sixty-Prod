import AppKit
import SwiftUI

/// E16 S2 (behind `e16.automation`): Settings > Shortcuts. One recorder row per hotkey action, the media-key options and
/// the Input Monitoring status. Rows reflow instead of scrolling sideways (AGENTS.md section 13).
enum ShortcutsSettingsContent {
    static let cardTitles = ["Keyboard Shortcuts", "Media Keys"]
    static let inputMonitoringURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")

    static func statusText(_ state: GlobalVolumeKeyMonitoringState) -> String {
        switch state {
        case .active: return "Media keys are on. They change Notch Sixty's volume while this output has no volume control of its own."
        case .permissionRequired: return "Input Monitoring is off for Notch Sixty. Turn it on in System Settings > Privacy & Security > Input Monitoring."
        case .stopped: return "Media keys are used only when the selected output has no volume control of its own."
        }
    }

    /// The Carbon modifier bits for the keys held in an AppKit event.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var bits: UInt32 = 0
        if flags.contains(.command) { bits |= HotkeyBinding.commandBit }
        if flags.contains(.shift) { bits |= HotkeyBinding.shiftBit }
        if flags.contains(.option) { bits |= HotkeyBinding.optionBit }
        if flags.contains(.control) { bits |= HotkeyBinding.controlBit }
        return bits
    }
}

@MainActor
final class HotkeyRecorder: ObservableObject {
    @Published private(set) var recording: HotkeyAction?
    @Published private(set) var messages: [HotkeyAction: String] = [:]
    private var monitor: Any?

    func start(_ action: HotkeyAction, controller: HotkeyController) {
        stop()
        recording = action
        messages[action] = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak controller] event in
            guard let self, let controller, self.recording == action else { return event }
            if event.keyCode == 53 {  // Escape cancels
                self.stop()
                return nil
            }
            let binding = HotkeyBinding(
                keyCode: UInt32(event.keyCode),
                modifiers: ShortcutsSettingsContent.carbonModifiers(event.modifierFlags))
            self.messages[action] = controller.assign(binding, to: action)
            self.stop()
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var hotkeys: HotkeyController
    @ObservedObject var volumeKeys: VolumeKeyController
    @ObservedObject var preferences: ApplicationPreferences
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        card("Keyboard Shortcuts", "keyboard") {
            Text("Record a shortcut for any action. None are set until you record them. Include Command, Control or Option.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
            ForEach(HotkeyAction.allCases) { action in
                row(action)
            }
        }
        card("Media Keys", "speaker.wave.2") {
            Text(ShortcutsSettingsContent.statusText(volumeKeys.monitoringState))
                .fixedSize(horizontal: false, vertical: true)
            if volumeKeys.monitoringState == .permissionRequired, let url = ShortcutsSettingsContent.inputMonitoringURL {
                Link("Open Input Monitoring Settings", destination: url)
            }
            Toggle("Show a level indicator when a media key changes the volume", isOn: $preferences.showMediaKeyIndicator)
            Text("Hold Option and Shift with a volume key for a quarter-size step. The mute key mutes and unmutes.")
                .font(DesignType.caption.font)
                .foregroundStyle(.secondary)
        }
        .onAppear { hotkeys.refreshRegistrations() }
        .onDisappear { recorder.stop() }
    }

    private func row(_ action: HotkeyAction) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.xs.pt) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSpacing.m.pt) {
                    Text(action.title)
                    Spacer(minLength: DesignSpacing.m.pt)
                    controls(action)
                }
                VStack(alignment: .leading, spacing: DesignSpacing.s.pt) {
                    Text(action.title)
                    HStack(spacing: DesignSpacing.m.pt) { controls(action) }
                }
            }
            if let text = recorder.messages[action] ?? hotkeys.problems[action] {
                Text(text).font(DesignType.caption.font).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func controls(_ action: HotkeyAction) -> some View {
        let isRecording = recorder.recording == action
        Button(isRecording ? "Press keys…" : (hotkeys.bindings[action]?.display ?? "Record")) {
            if isRecording { recorder.stop() } else { recorder.start(action, controller: hotkeys) }
        }
        .buttonStyle(.glass)
        Button("Clear") { hotkeys.clear(action) }
            .buttonStyle(.glass)
            .disabled(hotkeys.bindings[action] == nil)
    }

    private func card<Content: View>(
        _ title: String, _ systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSpacing.m.pt) {
            Label(title, systemImage: systemImage).font(DesignType.sectionTitle.font)
            content()
        }
        .padding(DesignSpacing.l.pt)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: DesignRadius.large.pt))
    }
}
