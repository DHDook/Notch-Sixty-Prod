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

    init(product: ProductController) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        engine = product.audioEngine
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
        case .switchingInput: return "Switching Input"
        case .waitingForInputDevice: return "Waiting for Input"
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
                set: { uid in perform { try engine.selectOutput(uid: uid) } }
            )) {
                Text("No Output").tag(String?.none)
                ForEach(engine.outputDevices) { device in
                    Text(device.name).tag(Optional(device.uid))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .disabled(!MenuBarRemoteModel.outputPickerEnabled(idle: engine.lifecycleState == .idle))
            .accessibilityLabel("Output device")
            if engine.lifecycleState != .idle {
                Text("Switch processing off to change the output.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
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
