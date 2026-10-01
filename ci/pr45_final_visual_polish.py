#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROOT_VIEW = ROOT / "NotchSixty" / "UI" / "ProductionRootView.swift"
DYNAMICS = ROOT / "NotchSixty" / "UI" / "ProductionDynamicsView.swift"
APP = ROOT / "NotchSixty" / "NotchSixtyApp.swift"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    return text.replace(old, new, 1)


# 1) Keep the app identity in the sidebar only. The richer page heading remains
# the detail-view title; the split-view toolbar no longer repeats Notch Sixty.
root = ROOT_VIEW.read_text(encoding="utf-8")
root = replace_once(
    root,
    '''            .navigationTitle("Notch Sixty")\n            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)''',
    '''            .navigationSplitViewColumnWidth(min: 200, ideal: 232, max: 290)''',
    "remove duplicate app navigation title",
)

# 2) The selected output is already inside the native toolbar. Do not put a
# second glass capsule inside that toolbar glass group; render it as quiet status
# text with a little breathing room instead.
root = replace_once(
    root,
    '''            if let output = engine.selectedOutputDevice {\n                Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")\n                    .font(.caption)\n                    .foregroundStyle(.secondary)\n                    .lineLimit(1)\n                    .padding(.horizontal, 11)\n                    .padding(.vertical, 6)\n                    .glassEffect(.regular, in: .capsule)\n            }''',
    '''            if let output = engine.selectedOutputDevice {\n                HStack(spacing: 5) {\n                    Image(systemName: "hifispeaker")\n                    Text("\\(output.name) · \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kHz")\n                }\n                .font(.caption)\n                .foregroundStyle(.secondary)\n                .lineLimit(1)\n                .padding(.horizontal, 8)\n                .accessibilityElement(children: .combine)\n                .accessibilityLabel("Output \\(output.name), \\(output.nominalSampleRate / 1_000, specifier: \"%.1f\") kilohertz")\n            }''',
    "flatten output status treatment",
)
ROOT_VIEW.write_text(root, encoding="utf-8")

# 3) A SwiftUI List brings an NSScrollView-owned rectangular surface with it.
# Use an explicit ScrollView/LazyVStack navigator so the rounded glass card owns
# the only background/clipping geometry.
dynamics = DYNAMICS.read_text(encoding="utf-8")
old_nav = '''    private var moduleNavigator: some View {\n        List(selection: $selectedModule) {\n            ForEach(ProductionDynamicsGroup.allCases) { group in\n                Section(group.title) {\n                    ForEach(group.modules) { module in\n                        HStack(spacing: 9) {\n                            Image(systemName: module.systemImage)\n                                .frame(width: 18)\n                                .foregroundStyle(selectedModule == module ? .primary : .secondary)\n                            VStack(alignment: .leading, spacing: 2) {\n                                Text(module.title)\n                                Text(module.subtitle)\n                                    .font(.caption2)\n                                    .foregroundStyle(.secondary)\n                                    .lineLimit(1)\n                            }\n                            Spacer(minLength: 4)\n                            Circle()\n                                .fill(moduleIsActive(module) ? Color.green : Color.secondary.opacity(0.28))\n                                .frame(width: 7, height: 7)\n                        }\n                        .tag(module)\n                    }\n                }\n            }\n        }\n        .listStyle(.plain)\n        .scrollContentBackground(.hidden)\n        .background(.clear)\n        .padding(8)\n        .glassEffect(.regular, in: .rect(cornerRadius: 18))\n    }'''
new_nav = '''    private var moduleNavigator: some View {\n        ScrollView {\n            LazyVStack(alignment: .leading, spacing: 4) {\n                ForEach(ProductionDynamicsGroup.allCases) { group in\n                    Text(group.title.uppercased())\n                        .font(.caption2.bold())\n                        .tracking(0.6)\n                        .foregroundStyle(.tertiary)\n                        .padding(.horizontal, 8)\n                        .padding(.top, 8)\n                        .padding(.bottom, 2)\n\n                    ForEach(group.modules) { module in\n                        Button {\n                            selectedModule = module\n                        } label: {\n                            HStack(spacing: 9) {\n                                Image(systemName: module.systemImage)\n                                    .frame(width: 18)\n                                    .foregroundStyle(selectedModule == module ? .primary : .secondary)\n                                VStack(alignment: .leading, spacing: 2) {\n                                    Text(module.title)\n                                        .foregroundStyle(.primary)\n                                    Text(module.subtitle)\n                                        .font(.caption2)\n                                        .foregroundStyle(.secondary)\n                                        .lineLimit(1)\n                                }\n                                Spacer(minLength: 4)\n                                Circle()\n                                    .fill(moduleIsActive(module) ? Color.green : Color.secondary.opacity(0.28))\n                                    .frame(width: 7, height: 7)\n                            }\n                            .contentShape(.rect)\n                            .padding(.horizontal, 9)\n                            .padding(.vertical, 5)\n                            .background {\n                                if selectedModule == module {\n                                    RoundedRectangle(cornerRadius: 8, style: .continuous)\n                                        .fill(.primary.opacity(0.09))\n                                }\n                            }\n                        }\n                        .buttonStyle(.plain)\n                    }\n                }\n            }\n            .padding(8)\n        }\n        .scrollIndicators(.visible)\n        .background(.clear)\n        .clipShape(.rect(cornerRadius: 18))\n        .glassEffect(.regular, in: .rect(cornerRadius: 18))\n    }'''
dynamics = replace_once(dynamics, old_nav, new_nav, "replace dynamics List navigator")
DYNAMICS.write_text(dynamics, encoding="utf-8")

# 4) Permission explanations are prose, not value columns. Leading-aligned
# stacks read correctly at every Settings window width and avoid ragged trailing
# multiline text.
app = APP.read_text(encoding="utf-8")
old_permissions = '''                    settingsCard(title: "Permissions", systemImage: "lock.shield") {\n                        LabeledContent("System Audio") {\n                            Text("Requested by macOS when processing needs system-audio capture.")\n                                .foregroundStyle(.secondary)\n                                .multilineTextAlignment(.trailing)\n                        }\n                        LabeledContent("Measurement Microphone") {\n                            Text("Requested only from Room Correction when you choose Request Access.")\n                                .foregroundStyle(.secondary)\n                                .multilineTextAlignment(.trailing)\n                        }\n                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                    }'''
new_permissions = '''                    settingsCard(title: "Permissions", systemImage: "lock.shield") {\n                        VStack(alignment: .leading, spacing: 4) {\n                            Text("System Audio")\n                                .font(.subheadline.weight(.medium))\n                            Text("Requested by macOS when processing needs system-audio capture.")\n                                .foregroundStyle(.secondary)\n                        }\n                        .frame(maxWidth: .infinity, alignment: .leading)\n\n                        VStack(alignment: .leading, spacing: 4) {\n                            Text("Measurement Microphone")\n                                .font(.subheadline.weight(.medium))\n                            Text("Requested only from Room Correction when you choose Request Access.")\n                                .foregroundStyle(.secondary)\n                        }\n                        .frame(maxWidth: .infinity, alignment: .leading)\n\n                        Text("If processing starts but receives no system audio after permission was denied, allow Notch Sixty under Privacy & Security → Screen & System Audio Recording, then relaunch the app.")\n                            .font(.caption)\n                            .foregroundStyle(.secondary)\n                            .frame(maxWidth: .infinity, alignment: .leading)\n                    }'''
app = replace_once(app, old_permissions, new_permissions, "align Settings permissions")
APP.write_text(app, encoding="utf-8")

print("Applied final PR45 visual polish")
