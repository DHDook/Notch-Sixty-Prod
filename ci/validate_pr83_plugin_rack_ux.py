#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

workspace = (ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift").read_text()
app = (ROOT / "NotchSixty/NotchSixtyApp.swift").read_text()
profiles = (ROOT / "NotchSixty/State/ProductProfiles.swift").read_text()
mutation = (ROOT / "NotchSixty/Audio/AudioUnitRackMutation.swift").read_text()
host = (ROOT / "NotchSixty/Audio/AudioUnitHostController.swift").read_text()
root_view = (ROOT / "NotchSixty/UI/ProductionRootView.swift").read_text()
toolbar = (ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift").read_text()

required_workspace = [
    "product.mutateAudioUnitRack",
    ".install(",
    ".append(",
    ".remove(",
    ".move(",
    ".setBypassed(",
    ".setWetDryMix(",
    ".setOpaqueFullState(",
    "AVAudioUnit.instantiate",
    "requestViewController",
    "fullStateForDocument",
    "Clear Quarantine",
    "bounded click-safe transition",
]
for needle in required_workspace:
    assert needle in workspace, f"PR83 workspace missing {needle!r}"

assert "ProductionPluginWorkspace(product: product)" in root_view
assert "ProductionProfileToolbar(product: product)" in root_view

assert "func selectContentPreset(_ id: UUID) async throws" in app
assert "applying: .replaceConfiguration(targetRack)" in app
assert "activateAudioUnitRackMutation" in app
assert "commitMutationCandidate(candidate)" in app
assert "profiles.commitContentPresetSelection(id)" in app

assert "applyContentStateWithoutAudioUnitRack" in profiles
assert "commitContentPresetSelection" in profiles
assert "try await product.selectContentPreset" in toolbar

assert "case append(" in mutation
assert "case replaceConfiguration(AudioUnitRackConfiguration)" in mutation
assert "case rackFull(maximum: Int)" in mutation
assert "case .append(" in host
assert "case .replaceConfiguration" in host
assert "func preparationReport(" in host

# The PR83 editor must never receive or mutate the live rack runtime.
for forbidden in [
    "AudioUnitLiveRackRuntime",
    "AudioUnitLiveProcessStage",
    "renderBlock",
    "allocateRenderResources",
]:
    assert forbidden not in workspace, (
        f"PR83 vendor editor crossed the live-runtime boundary via {forbidden!r}"
    )

print("PR83 plug-in rack UX structural validation passed.")
