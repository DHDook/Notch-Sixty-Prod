import AppKit
import Combine
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct ProductionMenuBarView: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    private var engine: AudioIOEngine
    @Environment(\.openWindow) private var openWindow
    @State private var commandError: String?

    init(product: ProductController) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        engine = product.audioEngine
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

    private var processingActive: Bool {
        switch engine.lifecycleState {
        case .starting, .running, .reconfiguring, .recoveringOutput, .switchingInput, .waitingForInputDevice:
            return true
        default:
            return false
        }
    }

    private var canToggleProcessing: Bool {
        guard !product.recovery.safeLaunchActive else {
            return false
        }
        switch engine.lifecycleState {
        case .idle, .running, .reconfiguring, .recoveringOutput, .failed:
            return true
        default:
            return false
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

    private var statusLabel: String {
        if product.recovery.safeLaunchActive {
            return "Safe Launch"
        }
        switch engine.lifecycleState {
        case .idle: return "Stopped"
        case .running: return "Processing"
        case .failed: return "Failed"
        case .requestingPermission: return "Requesting Permission"
        case .creatingTap, .creatingAggregate, .openingOutput, .starting: return "Starting"
        case .reconfiguring: return "Reconfiguring"
        case .recoveringOutput: return "Recovering Output"
        case .switchingInput: return "Switching Input"
        case .waitingForInputDevice: return "Waiting for Input"
        case .stopping: return "Stopping"
        }
    }

    private var statusSymbol: String {
        if product.recovery.safeLaunchActive {
            return "lifepreserver.fill"
        }
        switch engine.lifecycleState {
        case .running: return "waveform.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .idle: return "stop.circle"
        default: return "arrow.triangle.2.circlepath.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("NOTCH SIXTY")
                        .font(.headline)
                    Label(statusLabel, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(
                            product.recovery.safeLaunchActive
                                ? .orange
                                : engine.lifecycleState == .failed
                                    ? .red
                                    : .secondary
                        )
                }
                Spacer(minLength: 16)
            }

            Divider()

            Toggle("Processing", isOn: processingBinding)
                .toggleStyle(.switch)
                .disabled(!canToggleProcessing)

            HStack(spacing: 8) {
                Label("Preset", systemImage: "music.note.list")
                    .fixedSize()

                Picker("", selection: presetSelection) {
                    ForEach(profiles.contentPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }

            if profiles.selectedContentPresetIsDirty {
                Text("Current preset has unsaved changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                } label: {
                    Label("Open Notch Sixty", systemImage: "macwindow")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button(role: .destructive) {
                    product.shutdownForTermination()
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.glass)
                .foregroundStyle(.red)
                .help("Quit Notch Sixty")
            }
        }
        .padding(14)
        .frame(width: 300)
        .designMessage("Processing Error", message: $commandError)
    }
}
