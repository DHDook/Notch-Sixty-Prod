#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/NotchSixtyApp.swift")
source = path.read_text(encoding="utf-8")


def replace_once(old: str, new: str, label: str) -> None:
    global source
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    source = source.replace(old, new, 1)

replace_once(
'''            Picker("Content Preset", selection: presetSelection) {
                ForEach(profiles.contentPresets) { preset in
                    Text(preset.name).tag(Optional(preset.id))
                }
            }
            .productionGlassPickerChrome()
            .pickerStyle(.menu)
''',
'''            HStack(spacing: 8) {
                Label("Preset", systemImage: "music.note.list")
                    .fixedSize()

                Picker("", selection: presetSelection) {
                    ForEach(profiles.contentPresets) { preset in
                        Text(preset.name).tag(Optional(preset.id))
                    }
                }
                .labelsHidden()
                .productionGlassPickerChrome()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity)
            }
''',
"tray preset row",
)

replace_once(
'''                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        Picker("Appearance", selection: $preferences.appearance) {
                            ForEach(ApplicationAppearanceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .productionGlassPickerChrome()
                        .pickerStyle(.segmented)
                    }
''',
'''                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        HStack(spacing: 10) {
                            Text("Appearance")
                            Picker("", selection: $preferences.appearance) {
                                ForEach(ApplicationAppearanceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .productionGlassPickerChrome()
                            .pickerStyle(.segmented)
                            .frame(width: 220)
                        }
                    }
''',
"appearance picker row",
)

replace_once(
'''                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        Picker("Show Notch Sixty in", selection: $preferences.presence) {
                            ForEach(ApplicationPresenceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .productionGlassPickerChrome()
                        .pickerStyle(.segmented)

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
''',
'''                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        HStack(spacing: 10) {
                            Text("Show Notch Sixty in")
                            Picker("", selection: $preferences.presence) {
                                ForEach(ApplicationPresenceMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .productionGlassPickerChrome()
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
''',
"app presence picker row",
)

replace_once(
'''}

@main
struct NotchSixtyApp: App {
    @StateObject private var product: ProductController
''',
'''}

private final class NotchSixtyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct NotchSixtyApp: App {
    @NSApplicationDelegateAdaptor(NotchSixtyAppDelegate.self) private var appDelegate
    @StateObject private var product: ProductController
''',
"app delegate insertion",
)

required = [
    'Label("Preset", systemImage: "music.note.list")',
    '.labelsHidden()',
    'applicationShouldTerminateAfterLastWindowClosed',
    '@NSApplicationDelegateAdaptor(NotchSixtyAppDelegate.self)',
]
for token in required:
    if token not in source:
        raise SystemExit(f"missing expected hardened token: {token}")

if 'Picker("Content Preset", selection: presetSelection)' in source:
    raise SystemExit("tray still exposes the verbose Content Preset picker label")
if 'Picker("Appearance", selection: $preferences.appearance)' in source:
    raise SystemExit("Appearance label is still embedded inside the segmented picker")
if 'Picker("Show Notch Sixty in", selection: $preferences.presence)' in source:
    raise SystemExit("App Presence label is still embedded inside the segmented picker")

path.write_text(source, encoding="utf-8")
print("Post-v1.0.0 shell hardening patch applied.")
