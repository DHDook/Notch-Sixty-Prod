import SwiftUI

struct ProductionProfileToolbar: View {
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var engine: AudioIOEngine

    @State private var savePrompt: SavePrompt?
    @State private var draftName = ""

    private enum SavePrompt {
        case content
        case system

        var title: String {
            switch self {
            case .content: return "Save Content Preset"
            case .system: return "Save Playback System"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            contentPresetMenu

            Button {
                if profiles.canOverwriteSelectedContentPreset {
                    profiles.overwriteSelectedContentPreset()
                } else {
                    beginSave(
                        .content,
                        defaultName: profiles.selectedContentPresetName == "Custom"
                            ? "My Preset"
                            : profiles.selectedContentPresetName
                    )
                }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.glass)
            .help(
                profiles.canOverwriteSelectedContentPreset
                    ? "Update selected Content Preset"
                    : "Save current Content Preset"
            )

            systemMenu.controlSize(.small)

            if let error = profiles.lastErrorDescription {
                Button {
                    profiles.clearError()
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help(error)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .alert(
            savePrompt?.title ?? "Save",
            isPresented: Binding(
                get: { savePrompt != nil },
                set: { if !$0 { savePrompt = nil } }
            )
        ) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { savePrompt = nil }
            Button("Save") {
                let prompt = savePrompt
                savePrompt = nil
                switch prompt {
                case .content:
                    profiles.saveCurrentContentPreset(named: draftName)
                case .system:
                    profiles.saveCurrentSystemProfile(named: draftName)
                case .none:
                    break
                }
            }
        }
    }

    private var contentPresetMenu: some View {
        Menu {
            Section("Content Presets") {
                ForEach(profiles.contentPresets) { preset in
                    Button {
                        profiles.selectContentPreset(preset.id)
                    } label: {
                        HStack {
                            if profiles.selectedContentPresetID == preset.id {
                                Image(systemName: "checkmark")
                            }
                            Text(preset.name)
                            if preset.origin == .factory {
                                Text("Factory")
                            }
                        }
                    }
                }
            }

            Divider()
            Button("Save Current as New Preset…") {
                beginSave(.content, defaultName: "My Preset")
            }
            if profiles.canOverwriteSelectedContentPreset {
                Button("Update \(profiles.selectedContentPresetName)") {
                    profiles.overwriteSelectedContentPreset()
                }
                Button("Delete \(profiles.selectedContentPresetName)", role: .destructive) {
                    profiles.deleteSelectedContentPreset()
                }
            }
        } label: {
            Label(
                "\(profiles.selectedContentPresetName)\(profiles.selectedContentPresetIsDirty ? " •" : "")",
                systemImage: "music.note.list"
            )
        }
        .buttonStyle(.glass)
        .help("Content Preset: EQ/voicing, phase mode, dynamics, and input/headroom gain")
    }

    private var systemMenu: some View {
        Menu {
            Section("Playback Systems") {
                ForEach(profiles.systemProfiles) { system in
                    Button {
                        profiles.selectSystemProfile(system.id)
                    } label: {
                        HStack {
                            if profiles.selectedSystemProfileID == system.id {
                                Image(systemName: "checkmark")
                            }
                            Text(system.name)
                        }
                    }
                }
            }

            Divider()
            Button("New System from Current…") {
                beginSave(.system, defaultName: "My System")
            }
            if profiles.selectedSystemProfile != nil {
                Button("Update \(profiles.selectedSystemProfileName)") {
                    profiles.overwriteSelectedSystemProfile()
                }
                Button("Associate with Current Output") {
                    profiles.associateSelectedSystemWithCurrentOutput()
                }
                Button("Delete \(profiles.selectedSystemProfileName)", role: .destructive) {
                    profiles.deleteSelectedSystemProfile()
                }
            }
        } label: {
            Label(
                "\(profiles.selectedSystemProfileName)\(profiles.selectedSystemProfileIsDirty ? " •" : "")",
                systemImage: profiles.selectedSystemOutputMatches
                    ? "hifispeaker.2"
                    : "hifispeaker.2.fill"
            )
        }
        .buttonStyle(.glass)
        .help(
            "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"
        )
    }

    private func beginSave(_ prompt: SavePrompt, defaultName: String) {
        draftName = defaultName
        savePrompt = prompt
    }
}
