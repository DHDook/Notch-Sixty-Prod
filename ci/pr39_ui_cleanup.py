from pathlib import Path

ROOT = Path("NotchSixty/UI/ProductionRootView.swift")
PROFILES = Path("NotchSixty/State/ProductProfiles.swift")
TOOLBAR = Path("NotchSixty/UI/ProductionProfileToolbar.swift")

root = ROOT.read_text()
old_tint = '        .tint(Color(red: 0.91, green: 0.58, blue: 0.24))\n'
assert old_tint in root, "expected root amber tint not found"
root = root.replace(old_tint, "")

old_device = '''            if let output = engine.selectedOutputDevice {
                Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
'''
new_device = '''            if let output = engine.selectedOutputDevice {
                Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
'''
assert old_device in root, "expected device toolbar readout not found"
root = root.replace(old_device, new_device)
ROOT.write_text(root)

profiles = PROFILES.read_text()
old_content_update = '''    func overwriteSelectedContentPreset() {
        guard let selectedContentPresetID,
              let index = userContentPresets.firstIndex(where: { $0.id == selectedContentPresetID }) else { return }
        userContentPresets[index].state = captureContentState()
        lastErrorDescription = nil
        persist()
    }
'''
new_content_update = old_content_update + '''
    func renameSelectedContentPreset(to proposedName: String) {
        guard let selectedContentPresetID,
              let index = userContentPresets.firstIndex(where: { $0.id == selectedContentPresetID }) else { return }
        let existing = Set(
            contentPresets
                .filter { $0.id != selectedContentPresetID }
                .map { $0.name.lowercased() }
        )
        userContentPresets[index].name = uniqueName(
            proposedName,
            existing: existing,
            fallback: "My Preset"
        )
        lastErrorDescription = nil
        persist()
    }
'''
assert old_content_update in profiles, "content update method not found"
profiles = profiles.replace(old_content_update, new_content_update, 1)

old_system_update = '''    func overwriteSelectedSystemProfile() {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        let association = systemProfiles[index].state.associatedOutputUID
        var state = captureSystemState()
        state.associatedOutputUID = association
        systemProfiles[index].state = state
        lastErrorDescription = nil
        persist()
    }
'''
new_system_update = old_system_update + '''
    func renameSelectedSystemProfile(to proposedName: String) {
        guard let selectedSystemProfileID,
              let index = systemProfiles.firstIndex(where: { $0.id == selectedSystemProfileID }) else { return }
        let existing = Set(
            systemProfiles
                .filter { $0.id != selectedSystemProfileID }
                .map { $0.name.lowercased() }
        )
        systemProfiles[index].name = uniqueName(
            proposedName,
            existing: existing,
            fallback: "My System"
        )
        lastErrorDescription = nil
        persist()
    }
'''
assert old_system_update in profiles, "system update method not found"
profiles = profiles.replace(old_system_update, new_system_update, 1)
PROFILES.write_text(profiles)

TOOLBAR.write_text(r'''import SwiftUI

struct ProductionProfileToolbar: View {
    @ObservedObject var profiles: ProductProfileController
    @ObservedObject var engine: AudioIOEngine

    @State private var editorPrompt: EditorPrompt?
    @State private var draftName = ""

    private enum EditorPrompt {
        case newContent
        case renameContent
        case newSystem
        case renameSystem

        var title: String {
            switch self {
            case .newContent: return "New Content Preset"
            case .renameContent: return "Rename Content Preset"
            case .newSystem: return "New Playback System"
            case .renameSystem: return "Rename Playback System"
            }
        }

        var actionTitle: String {
            switch self {
            case .newContent, .newSystem: return "Create"
            case .renameContent, .renameSystem: return "Rename"
            }
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            contentPresetMenu
                .controlSize(.small)
            systemMenu
                .controlSize(.small)

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
            editorPrompt?.title ?? "Edit",
            isPresented: Binding(
                get: { editorPrompt != nil },
                set: { if !$0 { editorPrompt = nil } }
            )
        ) {
            TextField("Name", text: $draftName)
            Button("Cancel", role: .cancel) { editorPrompt = nil }
            Button(editorPrompt?.actionTitle ?? "Save") {
                let prompt = editorPrompt
                editorPrompt = nil
                switch prompt {
                case .newContent:
                    profiles.saveCurrentContentPreset(named: draftName)
                case .renameContent:
                    profiles.renameSelectedContentPreset(to: draftName)
                case .newSystem:
                    profiles.saveCurrentSystemProfile(named: draftName)
                case .renameSystem:
                    profiles.renameSelectedSystemProfile(to: draftName)
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
            Button("New Preset…") {
                begin(.newContent, defaultName: "My Preset")
            }
            if profiles.canOverwriteSelectedContentPreset {
                Button("Save Changes") {
                    profiles.overwriteSelectedContentPreset()
                }
                .disabled(!profiles.selectedContentPresetIsDirty)

                Button("Rename…") {
                    begin(.renameContent, defaultName: profiles.selectedContentPresetName)
                }

                Button("Delete", role: .destructive) {
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
        .help(
            profiles.selectedContentPresetIsDirty
                ? "Content Preset — unsaved changes"
                : "Content Preset: EQ/voicing, phase mode, dynamics, and input/headroom gain"
        )
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
            Button("New Playback System…") {
                begin(.newSystem, defaultName: "My System")
            }
            if profiles.selectedSystemProfile != nil {
                Button("Save Changes") {
                    profiles.overwriteSelectedSystemProfile()
                }
                .disabled(!profiles.selectedSystemProfileIsDirty)

                Button("Rename…") {
                    begin(.renameSystem, defaultName: profiles.selectedSystemProfileName)
                }

                Button("Delete", role: .destructive) {
                    profiles.deleteSelectedSystemProfile()
                }

                Divider()
                Button("Associate with Current Output") {
                    profiles.associateSelectedSystemWithCurrentOutput()
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
            profiles.selectedSystemProfileIsDirty
                ? "Playback System — unsaved changes"
                : "Playback System: output association, crossover, alignment, output trim, room correction, and speaker correction"
        )
    }

    private func begin(_ prompt: EditorPrompt, defaultName: String) {
        draftName = defaultName
        editorPrompt = prompt
    }
}
''')

print("Applied PR39 preset/profile CRUD, tint, and device-readout cleanup")
