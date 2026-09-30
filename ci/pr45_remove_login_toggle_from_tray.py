#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text(encoding="utf-8")

replacements = [
    (
        "    @ObservedObject private var engine: AudioIOEngine\n    @ObservedObject private var preferences: ApplicationPreferences\n    @Environment(\\.openWindow) private var openWindow\n",
        "    @ObservedObject private var engine: AudioIOEngine\n    @Environment(\\.openWindow) private var openWindow\n",
        "menu preference observer",
    ),
    (
        "    init(product: ProductController, preferences: ApplicationPreferences) {\n        self.product = product\n        _profiles = ObservedObject(wrappedValue: product.profiles)\n        _engine = ObservedObject(wrappedValue: product.audioEngine)\n        _preferences = ObservedObject(wrappedValue: preferences)\n    }\n",
        "    init(product: ProductController) {\n        self.product = product\n        _profiles = ObservedObject(wrappedValue: product.profiles)\n        _engine = ObservedObject(wrappedValue: product.audioEngine)\n    }\n",
        "menu initializer",
    ),
    (
        '''            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { preferences.launchAtLoginEnabled },
                    set: { preferences.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.switch)

            if preferences.launchAtLoginEnabled || preferences.launchAtLoginStatusDescription != "Off" {
                Text("Login: \\(preferences.launchAtLoginStatusDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = preferences.launchAtLoginError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

''',
        "",
        "tray Launch at Login controls",
    ),
    (
        '''            ProductionMenuBarView(product: product, preferences: preferences)
                .task {
                    preferences.refreshLaunchAtLoginStatus()
                    product.prepareForUse()
                }
''',
        '''            ProductionMenuBarView(product: product)
                .task { product.prepareForUse() }
''',
        "menu construction",
    ),
]

for old, new, label in replacements:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"Expected exactly one {label}, found {count}")
    text = text.replace(old, new)

# The settings UI remains the sole user-facing Launch at Login control.
if text.count('"Launch at Login"') != 1:
    raise SystemExit(f"Expected exactly one Launch at Login control after correction, found {text.count(chr(34) + 'Launch at Login' + chr(34))}")
if 'Section("Startup")' not in text:
    raise SystemExit("Startup settings section missing")

path.write_text(text, encoding="utf-8")
print("Moved Launch at Login exclusively to Settings / app preferences UI")
