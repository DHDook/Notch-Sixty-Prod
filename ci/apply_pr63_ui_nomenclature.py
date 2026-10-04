#!/usr/bin/env python3
from __future__ import annotations
import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
VALIDATOR = ROOT / "ci/validate_pr62_output_device_profiles.py"
TOOLBAR = ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift"
WORKFLOW = ROOT / ".github/workflows/pr63-apply-ui-nomenclature.yml"
SELF = pathlib.Path(__file__)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} matched {count} times, expected 1")
    return text.replace(old, new, 1)

validator = VALIDATOR.read_text(encoding="utf-8")
validator = replace_once(
    validator,
    '''    require("outputDeviceProfile: selectedSystemProfile?.state.outputDeviceProfile" in product,\n            "profile capture does not preserve Output Device Profile state")\n''',
    '''    require(\n        "outputDeviceProfile: selectedSystemProfile?.state.outputDeviceProfile" in product\n        or "outputDeviceProfile: engine.outputDeviceProfileConfiguration" in product,\n        "profile capture does not preserve Output Device Profile state"\n    )\n''',
    "PR62 ownership compatibility guard",
)
VALIDATOR.write_text(validator, encoding="utf-8")

toolbar = TOOLBAR.read_text(encoding="utf-8")
toolbar = replace_once(
    toolbar,
    '''                            Text(system.name)\n''',
    '''                            Text(displayName(for: system))\n''',
    "system menu label",
)
toolbar = replace_once(
    toolbar,
    '''                Text("System: \\(profiles.selectedSystemProfileName)\\(profiles.selectedSystemProfileIsDirty ? " •" : "")")\n''',
    '''                Text("System: \\(selectedSystemDisplayName)\\(profiles.selectedSystemProfileIsDirty ? " •" : "")")\n''',
    "selected system label",
)
toolbar = replace_once(
    toolbar,
    '''    private func begin(_ prompt: EditorPrompt, defaultName: String) {\n''',
    '''    private var selectedSystemDisplayName: String {\n        guard let system = profiles.selectedSystemProfile else {\n            return profiles.selectedSystemProfileName\n        }\n        return displayName(for: system)\n    }\n\n    private func displayName(for system: PlaybackSystemProfile) -> String {\n        guard let outputProfile = system.state.outputDeviceProfile, outputProfile.enabled else {\n            return system.name\n        }\n        return "\\(system.name) · \\(outputProfile.systemDisplayName)"\n    }\n\n    private func begin(_ prompt: EditorPrompt, defaultName: String) {\n''',
    "system display helper",
)
TOOLBAR.write_text(toolbar, encoding="utf-8")

if WORKFLOW.exists(): WORKFLOW.unlink()
if SELF.exists(): SELF.unlink()
