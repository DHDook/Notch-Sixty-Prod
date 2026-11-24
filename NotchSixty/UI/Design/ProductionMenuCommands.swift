import AppKit
import SwiftUI

/// E34 S5 (behind `e34.design-language`): the View and Playback menus.
///
/// Every Playback command calls the same engine method as the on-screen control it mirrors (the toolbar Bypass
/// button, the Processing switch, the menu-bar volume and audition controls). The commands are plain data so a test
/// can drive them against a fake engine. E16 keeps the global hotkeys; nothing here registers one.

/// The engine surface the Playback menu needs. `AudioIOEngine` conforms with no extra code.
@MainActor
protocol PlaybackMenuEngine: AnyObject {
    var lifecycleState: AudioLifecycleState { get }
    var playbackControlConfiguration: PlaybackControlConfiguration { get }
    var masterVolumeConfiguration: MasterVolumeConfiguration { get }
    var softwareVolumeKeyStep: MasterVolumeKeyStep { get }
    func stop()
    func setGlobalDSPBypassed(_ bypassed: Bool) throws
    func setAuditionMode(_ mode: AuditionMode) throws
    func setMasterVolumeLevel(_ level: Double) throws
    func setMasterMuted(_ muted: Bool) throws
}

extension AudioIOEngine: PlaybackMenuEngine {}

enum PlaybackMenuCommand: String, CaseIterable, Identifiable {
    case start, stop, toggleBypass, toggleBeforeAfter, volumeUp, volumeDown, toggleMute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: return "Start Processing"
        case .stop: return "Stop Processing"
        case .toggleBypass: return "Bypass"
        case .toggleBeforeAfter: return "Before / After"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .toggleMute: return "Mute"
        }
    }

    /// Shortcuts avoid every existing one (the EQ page owns ⌘[ ⌘] ⇧⌘N ⌥⌘B ⌘⌫, Help owns ⌘?).
    var shortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
        switch self {
        case .start: return ("r", [.command, .control])
        case .stop: return (".", [.command])
        case .toggleBypass: return ("b", [.command, .control])
        case .toggleBeforeAfter: return ("a", [.command, .control])
        case .volumeUp: return (.upArrow, [.command, .control])
        case .volumeDown: return (.downArrow, [.command, .control])
        case .toggleMute: return ("m", [.command, .control])
        }
    }
}

@MainActor
struct PlaybackMenuActions {
    let engine: any PlaybackMenuEngine
    /// The same start path as the Processing switch (`ProductController.startProcessing`).
    let startProcessing: () async throws -> Void
    var safeLaunchActive: () -> Bool = { false }

    private var isActive: Bool {
        switch engine.lifecycleState {
        case .starting, .running, .reconfiguring, .recoveringOutput, .switchingInput, .waitingForInputDevice: return true
        default: return false
        }
    }

    func isEnabled(_ command: PlaybackMenuCommand) -> Bool {
        switch command {
        case .start:
            return !safeLaunchActive() && (engine.lifecycleState == .idle || engine.lifecycleState == .failed)
        case .stop:
            return isActive || engine.lifecycleState == .failed
        case .toggleBypass, .toggleBeforeAfter:
            return engine.lifecycleState == .running
        case .volumeUp, .volumeDown, .toggleMute:
            return true
        }
    }

    /// Runs the command. Returns without doing anything when it is not enabled, like a disabled control.
    func perform(_ command: PlaybackMenuCommand) async throws {
        guard isEnabled(command) else { return }
        switch command {
        case .start:
            if engine.lifecycleState == .failed { engine.stop() }
            guard engine.lifecycleState == .idle else { return }
            try await startProcessing()
        case .stop:
            engine.stop()
        case .toggleBypass:
            try engine.setGlobalDSPBypassed(!engine.playbackControlConfiguration.globalBypassed)
        case .toggleBeforeAfter:
            let now = engine.playbackControlConfiguration.auditionMode
            try engine.setAuditionMode(now == .reference ? .processed : .reference)
        case .volumeUp, .volumeDown:
            let direction: Double = command == .volumeUp ? 1 : -1
            let level = engine.softwareVolumeKeyStep.level(
                afterPress: direction, from: engine.masterVolumeConfiguration.level)
            try engine.setMasterVolumeLevel(level)
        case .toggleMute:
            try engine.setMasterMuted(!engine.masterVolumeConfiguration.muted)
        }
    }
}

/// View menu: one shortcut (⌘1 to ⌘7) for each sidebar page.
enum ViewMenuPages {
    static let pages: [ProductionSection] = [
        .dashboard, .equalizer, .dynamics, .meters, .system, .headphones, .plugins,
    ]

    static func shortcut(forPageAt index: Int) -> KeyEquivalent? {
        guard pages.indices.contains(index) else { return nil }
        return KeyEquivalent(Character(String(index + 1)))
    }

    static func page(forShortcut key: Character) -> ProductionSection? {
        guard let digit = key.wholeNumberValue, digit >= 1 else { return nil }
        return pages.indices.contains(digit - 1) ? pages[digit - 1] : nil
    }
}

struct ProductionMenuCommands: Commands {
    @ObservedObject var navigation: ProductionNavigation
    let product: ProductController

    var body: some Commands {
        if FeatureFlags.isEnabledProcessWide(.setupFlow) {
            CommandGroup(after: .newItem) {
                SetupMenuItem(navigation: navigation)
            }
        }
        if FeatureFlags.isEnabledProcessWide(.designLanguage) {
            CommandMenu("Playback") {
                PlaybackMenuItems(product: product)
            }
            CommandGroup(after: .sidebar) {
                ViewMenuItems(navigation: navigation)
            }
        }
    }
}

/// E12 S29 (decision 34): "Set Up My System…" opens the guided setup from the File menu (flag `e12.setup-flow`).
enum SystemSetupMenuCommand {
    static let title = "Set Up My System…"

    @MainActor
    static func perform(navigation: ProductionNavigation) {
        navigation.navigate(to: .system)
        navigation.requestedGuidedSetup = .full
    }
}

private struct SetupMenuItem: View {
    @ObservedObject var navigation: ProductionNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(SystemSetupMenuCommand.title) {
            openWindow(id: "main")
            SystemSetupMenuCommand.perform(navigation: navigation)
        }
    }
}

private struct ViewMenuItems: View {
    @ObservedObject var navigation: ProductionNavigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ForEach(Array(ViewMenuPages.pages.enumerated()), id: \.element) { index, section in
            if let key = ViewMenuPages.shortcut(forPageAt: index) {
                Button(section.title) {
                    openWindow(id: "main")
                    navigation.navigate(to: section)
                }
                .keyboardShortcut(key, modifiers: .command)
            }
        }
    }
}

private struct PlaybackMenuItems: View {
    let product: ProductController

    private var actions: PlaybackMenuActions {
        PlaybackMenuActions(
            engine: product.audioEngine,
            startProcessing: { try await product.startProcessing() },
            safeLaunchActive: { product.recovery.safeLaunchActive })
    }

    var body: some View {
        let actions = actions
        ForEach(PlaybackMenuCommand.allCases) { command in
            Button(command.title) {
                Task { @MainActor in
                    do { try await actions.perform(command) } catch { NSSound.beep() }
                }
            }
            .keyboardShortcut(command.shortcut.key, modifiers: command.shortcut.modifiers)
            .disabled(!actions.isEnabled(command))
        }
    }
}
