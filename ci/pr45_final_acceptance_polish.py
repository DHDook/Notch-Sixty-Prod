#!/usr/bin/env python3
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{path}: expected one match, found {count}: {old[:100]!r}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


app = ROOT / "NotchSixty" / "NotchSixtyApp.swift"
root_view = ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift"
profile_toolbar = ROOT / "NotchSixty" / "UI" / "ProductionProfileToolbar.swift"
dynamics = ROOT / "NotchSixty" / "UI" / "ProductionDynamicsView.swift"
validator = ROOT / "ci" / "validate_pr45_release_hardening.py"

# Do not repeatedly mutate NSApplication appearance/activation policy when the
# menu-bar extra is opened. Preferences are applied once from the main scene;
# subsequent user changes are handled by the preference didSet observers.
replace_once(
    app,
    "    @Published private(set) var launchAtLoginError: String?\n    private var appearanceObservation: NSKeyValueObservation?\n",
    "    @Published private(set) var launchAtLoginError: String?\n    private var appearanceObservation: NSKeyValueObservation?\n    private var didApplyInitialPreferences = false\n",
)
replace_once(
    app,
    "    func apply() {\n        applyAppearance()\n        applyActivationPolicy()\n    }\n",
    "    func apply() {\n        guard !didApplyInitialPreferences else { return }\n        didApplyInitialPreferences = true\n        applyAppearance()\n        applyActivationPolicy()\n    }\n",
)
replace_once(
    app,
    "            ProductionMenuBarView(product: product)\n                .task {\n                    product.prepareForUse()\n                    preferences.apply()\n                }\n",
    "            ProductionMenuBarView(product: product)\n                .task { product.prepareForUse() }\n",
)

# Break the synchronous SwiftUI Toggle transaction before running the CoreAudio
# lifecycle. This avoids re-entrant view invalidation while start() publishes its
# lifecycle transitions and keeps the menu-bar extra responsive.
replace_once(
    app,
    "    private var processingBinding: Binding<Bool> {\n        Binding(\n            get: { processingActive },\n            set: { enabled in\n                if enabled {\n                    if engine.lifecycleState == .failed { engine.stop() }\n                    guard engine.lifecycleState == .idle else { return }\n                    do {\n                        try engine.start()\n                        commandError = nil\n                    } catch {\n                        commandError = error.localizedDescription\n                    }\n                } else {\n                    engine.stop()\n                    commandError = nil\n                }\n            }\n        )\n    }\n",
    "    private var processingBinding: Binding<Bool> {\n        Binding(\n            get: { processingActive },\n            set: { enabled in\n                Task { @MainActor in\n                    await Task.yield()\n                    if enabled {\n                        if engine.lifecycleState == .failed { engine.stop() }\n                        guard engine.lifecycleState == .idle else { return }\n                        do {\n                            try engine.start()\n                            commandError = nil\n                        } catch {\n                            commandError = error.localizedDescription\n                        }\n                    } else {\n                        engine.stop()\n                        commandError = nil\n                    }\n                }\n            }\n        )\n    }\n",
)

# Use native Liquid Glass button styles. Avoid hard-filled blue/red backgrounds,
# which become fluorescent/candy-colored in dark appearance.
replace_once(
    app,
    "                .buttonStyle(.borderedProminent)\n                .tint(.blue)\n",
    "                .buttonStyle(.glassProminent)\n",
)
replace_once(
    app,
    "                .buttonStyle(.borderedProminent)\n                .tint(.red)\n                .help(\"Quit Notch Sixty\")\n",
    "                .buttonStyle(.glass)\n                .foregroundStyle(.red)\n                .help(\"Quit Notch Sixty\")\n",
)

# Replace the classic grouped Form with glass cards that match the macOS 27
# production surfaces used elsewhere in the app.
text = app.read_text(encoding="utf-8")
settings_start = text.index("private struct ProductionSettingsView")
body_start = text.index("    var body: some View {", settings_start)
struct_end = text.index("\n}\n\n@main\nstruct NotchSixtyApp", body_start)
new_body = '''    var body: some View {
        ScrollView {
            GlassEffectContainer(spacing: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    settingsCard(title: "About", systemImage: "info.circle") {
                        LabeledContent("Version") {
                            Text(version).monospacedDigit()
                        }
                        LabeledContent("Build") {
                            Text(build).monospacedDigit()
                        }
                    }

                    settingsCard(title: "Appearance", systemImage: "circle.lefthalf.filled") {
                        Picker("Appearance", selection: $preferences.appearance) {
                            ForEach(ApplicationAppearanceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    settingsCard(title: "App Presence", systemImage: "macwindow.on.rectangle") {
                        Picker("Show Notch Sixty in", selection: $preferences.presence) {
                            ForEach(ApplicationPresenceMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)

                        Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Startup", systemImage: "power") {
                        Toggle(
                            "Launch at Login",
                            isOn: Binding(
                                get: { preferences.launchAtLoginEnabled },
                                set: { preferences.setLaunchAtLogin($0) }
                            )
                        )

                        LabeledContent("Status") {
                            Text(preferences.launchAtLoginStatusDescription)
                                .foregroundStyle(.secondary)
                        }

                        if let error = preferences.launchAtLoginError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }

                        Text("Launch at Login is optional and does not automatically start audio processing. Processing remains an explicit user action in v1.0.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Permissions", systemImage: "lock.shield") {
                        LabeledContent("System Audio") {
                            Text("Requested by macOS when processing needs system-audio capture.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        LabeledContent("Measurement Microphone") {
                            Text("Requested only from Room Correction when you choose Request Access.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }
                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    settingsCard(title: "Support", systemImage: "wrench.and.screwdriver") {
                        Button {
                            copyDiagnostics()
                        } label: {
                            Label("Copy Diagnostics", systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.glass)

                        Text("Copies app/build, macOS, audio device/rate, active preset/system, bypass state, and DSP latency. It does not include captured audio or room-measurement samples.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
        }
        .task { preferences.refreshLaunchAtLoginStatus() }
        .frame(width: 540)
        .frame(minHeight: 580)
    }

    private func settingsCard<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
'''
text = text[:body_start] + new_body + text[struct_end:]
app.write_text(text, encoding="utf-8")

# Force toolbar menus to render their selected names instead of inheriting the
# toolbar's icon-only Label style.
replace_once(
    profile_toolbar,
    '''        } label: {
            Label(
                "Content: \\(profiles.selectedContentPresetName)\\(profiles.selectedContentPresetIsDirty ? " •" : "")",
                systemImage: "music.note.list"
            )
        }
''',
    '''        } label: {
            HStack(spacing: 6) {
                Image(systemName: "music.note.list")
                Text("Content: \\(profiles.selectedContentPresetName)\\(profiles.selectedContentPresetIsDirty ? " •" : "")")
            }
        }
''',
)
replace_once(
    profile_toolbar,
    '''        } label: {
            Label(
                "System: \\(profiles.selectedSystemProfileName)\\(profiles.selectedSystemProfileIsDirty ? " •" : "")",
                systemImage: profiles.selectedSystemOutputMatches
                    ? "hifispeaker.2"
                    : "hifispeaker.2.fill"
            )
        }
''',
    '''        } label: {
            HStack(spacing: 6) {
                Image(systemName: profiles.selectedSystemOutputMatches
                    ? "hifispeaker.2"
                    : "hifispeaker.2.fill")
                Text("System: \\(profiles.selectedSystemProfileName)\\(profiles.selectedSystemProfileIsDirty ? " •" : "")")
            }
        }
''',
)

# The detail pages already have their own large content headings. Remove the
# duplicate NavigationSplitView toolbar titles while keeping the app/sidebar title.
page_title_pattern = re.compile(r'\n\s*\.navigationTitle\("(Dashboard|Equalizer|Dynamics|Meters|Active Crossover|Room Correction)"\)')
for path in (ROOT / "NotchSixty" / "UI").glob("Production*.swift"):
    source = path.read_text(encoding="utf-8")
    updated = page_title_pattern.sub("", source)
    if updated != source:
        path.write_text(updated, encoding="utf-8")

# Give the Dynamics module navigator a transparent scrolling surface within a
# glass card instead of the old opaque gray sidebar/table background.
replace_once(
    dynamics,
    "        .listStyle(.sidebar)\n",
    "        .listStyle(.plain)\n        .scrollContentBackground(.hidden)\n        .background(.clear)\n        .padding(8)\n        .glassEffect(.regular, in: .rect(cornerRadius: 18))\n",
)

# Defer the main-window Start/Stop action out of the Button transaction as well.
replace_once(
    root_view,
    '''            Button {
                if engine.lifecycleState == .running { engine.stop() }
                else { try? engine.start() }
            } label: {
''',
    '''            Button {
                Task { @MainActor in
                    await Task.yield()
                    if engine.lifecycleState == .running { engine.stop() }
                    else if engine.lifecycleState == .idle { try? engine.start() }
                }
            } label: {
''',
)

# The PR45 guard should validate the new glass Settings structure rather than the
# superseded Form/Section implementation.
val = validator.read_text(encoding="utf-8")
val = val.replace("'Section(\"Appearance\")',", "'settingsCard(title: \"Appearance\"',")
val = val.replace("'Section(\"App Presence\")',", "'settingsCard(title: \"App Presence\"',")
val = val.replace("'Section(\"Startup\")',", "'settingsCard(title: \"Startup\"',")
val = val.replace("'Section(\"Permissions\")',", "'settingsCard(title: \"Permissions\"',")
val = val.replace("'Section(\"Support\")',", "'settingsCard(title: \"Support\"',")
validator.write_text(val, encoding="utf-8")

print("Applied final PR45 acceptance polish")
