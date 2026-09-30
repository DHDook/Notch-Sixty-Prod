#!/usr/bin/env python3
from pathlib import Path

path = Path("NotchSixty/NotchSixtyApp.swift")
text = path.read_text(encoding="utf-8")

old_props = '''private struct ProductionMenuBarView: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    @ObservedObject private var engine: AudioIOEngine
    @Environment(\\.openWindow) private var openWindow
    @State private var commandError: String?

    init(product: ProductController) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        _engine = ObservedObject(wrappedValue: product.audioEngine)
    }
'''
new_props = '''private struct ProductionMenuBarView: View {
    let product: ProductController
    @ObservedObject private var profiles: ProductProfileController
    @ObservedObject private var engine: AudioIOEngine
    @ObservedObject private var preferences: ApplicationPreferences
    @Environment(\\.openWindow) private var openWindow
    @State private var commandError: String?

    init(product: ProductController, preferences: ApplicationPreferences) {
        self.product = product
        _profiles = ObservedObject(wrappedValue: product.profiles)
        _engine = ObservedObject(wrappedValue: product.audioEngine)
        _preferences = ObservedObject(wrappedValue: preferences)
    }
'''
if text.count(old_props) != 1:
    raise SystemExit("Unexpected ProductionMenuBarView initializer anchor count")
text = text.replace(old_props, new_props, 1)

old_menu = '''            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }

            Divider()
'''
new_menu = '''            Toggle(
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

            SettingsLink {
                Label("Settings…", systemImage: "gearshape")
            }

            Divider()
'''
if text.count(old_menu) != 1:
    raise SystemExit("Unexpected SettingsLink anchor count")
text = text.replace(old_menu, new_menu, 1)

old_scene = '''            ProductionMenuBarView(product: product)
                .task { product.prepareForUse() }
'''
new_scene = '''            ProductionMenuBarView(product: product, preferences: preferences)
                .task {
                    preferences.refreshLaunchAtLoginStatus()
                    product.prepareForUse()
                }
'''
if text.count(old_scene) != 1:
    raise SystemExit("Unexpected MenuBarExtra scene anchor count")
text = text.replace(old_scene, new_scene, 1)

path.write_text(text, encoding="utf-8")
print("Added synchronized Launch at Login control to the menu-bar app menu")
