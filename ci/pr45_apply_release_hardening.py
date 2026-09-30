#!/usr/bin/env python3
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected one anchor, found {count}")
    return text.replace(old, new, 1)


root = Path(__file__).resolve().parents[1]

# -----------------------------------------------------------------------------
# Shipping app shell: keep engineering validation UI DEBUG-only, add launch-at-
# login and user-copyable diagnostics, and surface the permission model.
# -----------------------------------------------------------------------------
app_path = root / "NotchSixty" / "NotchSixtyApp.swift"
app = app_path.read_text(encoding="utf-8")

app = replace_once(
    app,
    "import Combine\nimport SwiftUI\n",
    "import Combine\nimport ServiceManagement\nimport SwiftUI\n",
    "ServiceManagement import",
)

app = replace_once(
    app,
    "private struct PR27ProtectionValidationView: View {",
    "#if DEBUG\nprivate struct PR27ProtectionValidationView: View {",
    "DEBUG engineering start",
)
app = replace_once(
    app,
    "\nprivate enum ApplicationAppearanceMode: String, CaseIterable, Identifiable {",
    "\n#endif\n\nprivate enum ApplicationAppearanceMode: String, CaseIterable, Identifiable {",
    "DEBUG engineering end",
)

presence_block = '''    @Published var presence: ApplicationPresenceMode {
        didSet {
            defaults.set(presence.rawValue, forKey: Key.presence)
            applyActivationPolicy()
        }
    }

    init(defaults: UserDefaults = .standard) {'''
presence_replacement = '''    @Published var presence: ApplicationPresenceMode {
        didSet {
            defaults.set(presence.rawValue, forKey: Key.presence)
            applyActivationPolicy()
        }
    }

    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var launchAtLoginError: String?

    init(defaults: UserDefaults = .standard) {'''
app = replace_once(app, presence_block, presence_replacement, "launch-at-login properties")

init_tail = '''        presence = ApplicationPresenceMode(
            rawValue: defaults.string(forKey: Key.presence) ?? ""
        ) ?? .both
    }

    var isTrayInserted: Bool { presence != .dock }
'''
init_tail_replacement = '''        presence = ApplicationPresenceMode(
            rawValue: defaults.string(forKey: Key.presence) ?? ""
        ) ?? .both
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginError = nil
    }

    var isTrayInserted: Bool { presence != .dock }

    var launchAtLoginStatusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .requiresApproval:
            return "Requires approval in System Settings"
        case .notRegistered:
            return "Off"
        case .notFound:
            return "Unavailable"
        @unknown default:
            return "Unknown"
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }
'''
app = replace_once(app, init_tail, init_tail_replacement, "launch-at-login implementation")

settings_header = '''private struct ProductionSettingsView: View {
    @ObservedObject var preferences: ApplicationPreferences

    private var version: String {'''
settings_header_replacement = '''private struct ProductionSettingsView: View {
    @ObservedObject var preferences: ApplicationPreferences
    @ObservedObject var product: ProductController

    private var version: String {'''
app = replace_once(app, settings_header, settings_header_replacement, "settings product observation")

build_block = '''    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {'''
build_replacement = '''    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticsReport: String {
        let engine = product.audioEngine
        let output = engine.selectedOutputDevice
        let kernel = engine.diagnosticsSnapshot().renderKernelDiagnostics

        let outputName = output?.name ?? "None selected"
        let outputUID = output?.uid ?? "None"
        let outputRate = output.map {
            String(format: "%.1f kHz", $0.nominalSampleRate / 1_000.0)
        } ?? "Unavailable"
        let latency: String
        if let kernel, kernel.sampleRate > 0 {
            latency = String(
                format: "%u frames / %.3f ms",
                kernel.latencyFrames,
                Double(kernel.latencyFrames) / kernel.sampleRate * 1_000.0
            )
        } else {
            latency = "Unavailable"
        }

        return [
            "Notch Sixty Diagnostics",
            "Version: \\(version) (\\(build))",
            "macOS: \\(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Architecture: Apple Silicon",
            "Lifecycle: \\(engine.lifecycleState.rawValue)",
            "Output: \\(outputName)",
            "Output UID: \\(outputUID)",
            "Output Rate: \\(outputRate)",
            "Content Preset: \\(product.profiles.selectedContentPresetName)",
            "Playback System: \\(product.profiles.selectedSystemProfileName)",
            "Global Bypass: \\(engine.playbackControlConfiguration.globalBypassed ? \"On\" : \"Off\")",
            "EQ Phase: \\(engine.stereoEQConfiguration.phaseMode.displayName)",
            "EQ Bands Enabled: \\(engine.stereoEQConfiguration.enabledBandCount)",
            "Bass Management: \\(engine.bassManagementConfiguration.enabled ? \"On\" : \"Off\")",
            "Room Correction: \\(engine.roomCorrectionConfiguration.enabled ? \"On\" : \"Off\")",
            "DSP Latency: \\(latency)",
        ].joined(separator: "\\n")
    }

    private func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
    }

    var body: some View {'''
app = replace_once(app, build_block, build_replacement, "diagnostics report")

presence_section_tail = '''                Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)'''
presence_section_replacement = '''                Text("Menu Bar mode keeps processing and preset controls available without a Dock icon. Both shows the app in both places.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Startup") {
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

            Section("Permissions") {
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

            Section("Support") {
                Button {
                    copyDiagnostics()
                } label: {
                    Label("Copy Diagnostics", systemImage: "doc.on.doc")
                }

                Text("Copies app/build, macOS, audio device/rate, active preset/system, bypass state, and DSP latency. It does not include captured audio or room-measurement samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { preferences.refreshLaunchAtLoginStatus() }'''
app = replace_once(app, presence_section_tail, presence_section_replacement, "settings launch/support sections")

app = replace_once(
    app,
    "ProductionSettingsView(preferences: preferences)",
    "ProductionSettingsView(preferences: preferences, product: product)",
    "settings scene product injection",
)

engineering_scene = '''        Window("Engineering Validation", id: "engineering-validation") {
            EngineeringValidationView(engine: product.audioEngine)
                .task { product.prepareForUse() }
        }
        .defaultSize(width: 1000, height: 760)'''
engineering_scene_replacement = '''        #if DEBUG
        Window("Engineering Validation", id: "engineering-validation") {
            EngineeringValidationView(engine: product.audioEngine)
                .task { product.prepareForUse() }
        }
        .defaultSize(width: 1000, height: 760)
        #endif'''
app = replace_once(app, engineering_scene, engineering_scene_replacement, "DEBUG engineering scene")

app_path.write_text(app, encoding="utf-8")

# -----------------------------------------------------------------------------
# Production root: remove the engineering entry point from Release builds.
# -----------------------------------------------------------------------------
root_view_path = root / "NotchSixty" / "UI" / "ProductionRootView.swift"
root_view = root_view_path.read_text(encoding="utf-8")
root_view = replace_once(
    root_view,
    '''    @ObservedObject var product: ProductController
    @Environment(\\.openWindow) private var openWindow
    @State private var selection: ProductionSection? = .dashboard''',
    '''    @ObservedObject var product: ProductController
    #if DEBUG
    @Environment(\\.openWindow) private var openWindow
    #endif
    @State private var selection: ProductionSection? = .dashboard''',
    "DEBUG openWindow environment",
)
engineering_button = '''            Button {
                openWindow(id: "engineering-validation")
            } label: {
                Label("Engineering Validation", systemImage: "wrench.and.screwdriver")
            }
            .buttonStyle(.glass)
            .help("Open the retained engineering validation tools")
'''
root_view = replace_once(
    root_view,
    engineering_button,
    "            #if DEBUG\n" + engineering_button + "            #endif\n",
    "DEBUG engineering toolbar button",
)
root_view_path.write_text(root_view, encoding="utf-8")

# -----------------------------------------------------------------------------
# Legacy/engineering ContentView is retained for internal validation but Release
# compilation excludes its implementation entirely.
# -----------------------------------------------------------------------------
content_view_path = root / "NotchSixty" / "ContentView.swift"
content_view = content_view_path.read_text(encoding="utf-8")
if not content_view.startswith("#if DEBUG\n"):
    content_view = "#if DEBUG\n" + content_view.rstrip() + "\n#endif\n"
content_view_path.write_text(content_view, encoding="utf-8")

# -----------------------------------------------------------------------------
# Public repository status should describe the v1 product rather than the old
# bootstrap state and accurately describe stereo-program / speaker-output scope.
# -----------------------------------------------------------------------------
readme_path = root / "README.md"
readme = readme_path.read_text(encoding="utf-8")
readme = replace_once(
    readme,
    "**Commercial bootstrap / architecture foundation.**",
    "**v1.0 release-candidate hardening.**",
    "README status",
)
readme = replace_once(
    readme,
    "- actual multichannel output is out of scope",
    "- stereo program material only; speaker-integration routing may fan out to 2–8 physical outputs for mains/sub and active bi-/tri-amp systems",
    "README speaker-routing scope",
)
readme_path.write_text(readme, encoding="utf-8")

print("Applied PR45 v1 release hardening source patch")
