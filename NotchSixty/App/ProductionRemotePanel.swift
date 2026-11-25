import AppKit
import SwiftUI

/// E12 S13 (behind `e12.dashboard-remote`): the remote-control panel. One component, hosted by the menu bar item or, when
/// that is off in Settings, by a toolbar popover. Everything the user changes while listening lives here and not on the
/// Dashboard. Slots for later controls are listed in `RemoteSlot`; an unfilled slot draws nothing.
struct ProductionRemotePanel: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    private var engine: AudioIOEngine
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PreferenceKeys.Application.volumeStepResolution)
    private var storedVolumeStepResolution = ApplicationVolumeStepResolution.standard.rawValue
    @State private var commandError: String?
    @State private var switchingOutput = false
    @StateObject private var beforeAfter: BeforeAfterModel
    private let flags: FeatureFlags
    private let control: ControlService

    @MainActor init(product: ProductController, flags: FeatureFlags? = nil) {
        let flags = flags ?? FeatureFlags()
        self.product = product
        self.flags = flags
        control = product.makeControlService(flags: { flags })
        _beforeAfter = StateObject(wrappedValue: BeforeAfterModel(
            player: ProfileContentAuditionPlayer(profiles: product.profiles),
            headphone: ProfileHeadphoneCompare(profiles: product.profiles)))
        _profiles = ObservedObject(wrappedValue: product.profiles)
        engine = product.audioEngine
    }

    /// E12 S14 (G10): fade out, stop, select and start again; a failed switch returns to the previous device.
    private func switchOutput(to uid: String?) {
        guard !switchingOutput else { return }
        switchingOutput = true
        let switcher = LiveOutputSwitch(transport: OutputSwitchEngineTransport(
            engine: engine, start: { try await product.startProcessing() }))
        Task { @MainActor in
            let outcome = await switcher.switchOutput(to: uid)
            commandError = outcome.errorMessage
            switchingOutput = false
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            commandError = nil
        } catch {
            commandError = error.localizedDescription
        }
    }

    private var processingActive: Bool {
        switch engine.lifecycleState {
        case .starting, .running, .reconfiguring, .recoveringOutput: return true
        default: return false
        }
    }

    private var canToggleProcessing: Bool {
        guard !product.recovery.safeLaunchActive else { return false }
        switch engine.lifecycleState {
        case .idle, .running, .reconfiguring, .recoveringOutput, .failed: return true
        default: return false
        }
    }

    private var processingBinding: Binding<Bool> {
        Binding(
            get: { processingActive },
            set: { enabled in
                Task { @MainActor in
                    await Task.yield()
                    if enabled {
                        if engine.lifecycleState == .failed { engine.stop() }
                        guard engine.lifecycleState == .idle else { return }
                        do {
                            try await product.startProcessing()
                            commandError = nil
                        } catch {
                            commandError = error.localizedDescription
                        }
                    } else {
                        engine.stop()
                        commandError = nil
                    }
                }
            }
        )
    }

    private var presetSelection: Binding<UUID?> {
        Binding(
            get: { profiles.selectedContentPresetID },
            set: { id in
                guard let id else { return }
                Task { @MainActor in
                    do {
                        try await product.selectContentPreset(id)
                        commandError = nil
                    } catch {
                        commandError = error.localizedDescription
                    }
                }
            }
        )
    }

    private var statusLabel: String {
        if product.recovery.safeLaunchActive { return "Safe Launch" }
        switch engine.lifecycleState {
        case .idle: return "Stopped"
        case .running: return "Processing"
        case .failed: return "Failed"
        case .requestingPermission: return "Requesting Permission"
        case .creatingTap, .creatingAggregate, .openingOutput, .starting: return "Starting"
        case .reconfiguring: return "Reconfiguring"
        case .switchingInput: return "Switching Input"
        case .waitingForInputDevice: return "Waiting for Input"
        case .recoveringOutput: return "Recovering Output"
        case .stopping: return "Stopping"
        }
    }

    private var usesDecibelScale: Bool {
        engine.masterVolumeCapabilities.controlMode == .softwareDSP
            && ApplicationVolumeStepResolution(storedValue: storedVolumeStepResolution)?.usesDecibels == true
    }

    private var volumePosition: Binding<Double> {
        let decibelLinear = usesDecibelScale
        return Binding(
            get: {
                let level = engine.masterVolumeConfiguration.level
                return decibelLinear ? MasterVolumeConfiguration.decibelFaderPosition(forLevel: level) : level
            },
            set: { position in
                let level = decibelLinear
                    ? MasterVolumeConfiguration.level(forDecibelFaderPosition: position) : position
                perform { try engine.setMasterVolumeLevel(level) }
            }
        )
    }

    private var volumeReadout: String {
        let level = engine.masterVolumeConfiguration.level
        if usesDecibelScale {
            return VolumeFeedbackPresentation.decibelReadout(
                MasterVolumeConfiguration.softwareTaperDB(forLevel: level), alwaysTenths: true)
        }
        return String(format: "%.0f%%", level * 100)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("NOTCH SIXTY").font(.headline)
                Label(statusLabel, systemImage: processingActive ? "waveform.circle.fill" : "stop.circle")
                    .font(.caption)
                    .foregroundStyle(engine.lifecycleState == .failed ? .red : .secondary)
            }

            Divider()

            Toggle("Processing", isOn: processingBinding)
                .toggleStyle(.switch)
                .disabled(!canToggleProcessing)

            volumeRow
            balanceRow
            outputRow
            presetRow
            if !MenuBarRemoteModel.automationControls(automationOn: flags.isEnabled(.automation)).isEmpty {
                automationRows
            }
            if RemoteSlot.beforeAfter.isFilled, FeatureFlags().isEnabled(.blindListening) {
                BeforeAfterRow(model: beforeAfter, openBlind: openBlindListening)
            }

            Divider()

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("Open Notch Sixty", systemImage: "macwindow").frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Open Notch Sixty")
        }
        .padding(14)
        .frame(width: 300)
        .designMessage("Processing Error", message: $commandError)
    }

    private var volumeRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Volume").font(.subheadline.weight(.semibold))
                Spacer()
                Text(volumeReadout).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button {
                    perform { try engine.setMasterMuted(!engine.masterVolumeConfiguration.muted) }
                } label: {
                    Image(systemName: engine.masterVolumeConfiguration.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.glass)
                .accessibilityLabel(engine.masterVolumeConfiguration.muted ? "Unmute" : "Mute")
                Slider(value: volumePosition, in: MasterVolumeConfiguration.levelRange)
                    .accessibilityLabel("Master volume")
                    .accessibilityValue(volumeReadout)
            }
        }
    }

    private var balanceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Balance").font(.subheadline.weight(.semibold))
                Spacer()
                Text(MenuBarRemoteModel.balanceReadout(engine.playbackControlConfiguration.balance))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            ProductionBalanceBar(
                balance: Binding(
                    get: { engine.playbackControlConfiguration.balance },
                    set: { value in perform { try engine.setChannelBalance(value) } }
                )
            )
            .accessibilityLabel("Left right balance")
            .accessibilityValue(MenuBarRemoteModel.balanceReadout(engine.playbackControlConfiguration.balance))
        }
    }

    private var outputRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Output").font(.subheadline.weight(.semibold))
            Picker("Output device", selection: Binding(
                get: { engine.routeConfiguration.selectedOutputUID },
                set: { uid in switchOutput(to: uid) }
            )) {
                Text("No Output").tag(String?.none)
                ForEach(engine.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(!MenuBarRemoteModel.outputPickerEnabled(lifecycle: engine.lifecycleState, switching: switchingOutput))
            .accessibilityLabel("Output device")
            if switchingOutput {
                Text("Switching output…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// E16 S1: Playback System, Bypass and room correction, all through `ControlService` so the same rules apply as for
    /// an intent. A refusal shows in the panel's message.
    private func runControl(_ command: ControlCommand) {
        Task { @MainActor in
            commandError = await control.perform(command).refusalReason
        }
    }

    private var automationRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Playback System").font(.subheadline.weight(.semibold))
                Picker("Playback System", selection: Binding(
                    get: { profiles.selectedSystemProfileID },
                    set: { id in if let id { runControl(.selectSystem(id)) } }
                )) {
                    ForEach(profiles.systemProfiles) { system in
                        Text(system.name).tag(Optional(system.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Playback System")
            }
            Toggle("Bypass", isOn: Binding(
                get: { engine.playbackControlConfiguration.globalBypassed },
                set: { runControl(.setBypass($0)) }))
                .toggleStyle(.switch)
            Toggle("Room correction", isOn: Binding(
                get: { engine.roomCorrectionConfiguration.enabled },
                set: { runControl(.setRoomCorrection($0)) }))
                .toggleStyle(.switch)
        }
    }

    private func openBlindListening() {
        beforeAfter.done()
        BlindListeningRequest.shared.request()
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preset").font(.subheadline.weight(.semibold))
            Picker("Preset", selection: presetSelection) {
                ForEach(profiles.contentPresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Preset")
            if profiles.selectedContentPresetIsDirty {
                Text("Current preset has unsaved changes.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Toolbar button that opens the same panel in a popover when the menu bar item is off.
struct ProductionRemoteToolbarButton: View {
    let product: ProductController
    @State private var shown = false

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Label("Remote", systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.glass)
        .help("Volume, output and preset")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            ProductionRemotePanel(product: product).productionToggleStyle()
        }
    }
}

/// E12 S27 (G9): level-matched before/after. "Before" is processing off, "After" is the current settings.
private struct BeforeAfterRow: View {
    @ObservedObject var model: BeforeAfterModel
    let openBlind: () -> Void
    private let tick = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()

    @ViewBuilder private func sideButton(_ title: String, _ side: BeforeAfterModel.Side, key: KeyEquivalent) -> some View {
        if model.side == side {
            Button(title) { model.show(side) }.buttonStyle(.glassProminent).keyboardShortcut(key, modifiers: [.command, .option])
        } else {
            Button(title) { model.show(side) }.buttonStyle(.glass).keyboardShortcut(key, modifiers: [.command, .option])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Before and after").font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                sideButton("Before", .before, key: "b")
                sideButton("After", .after, key: "a")
                if model.isComparing { Button("Done") { model.done() }.buttonStyle(.glass) }
            }
            .disabled(model.isSwitching)
            if let summary = model.levelSummary { Text(summary).font(.caption).foregroundStyle(.secondary) }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.orange) }
            Button("Compare blind…", action: openBlind).buttonStyle(.link).font(.caption)
        }
        .onReceive(tick) { _ in model.refresh() }
        .onDisappear { model.done() }
    }
}
