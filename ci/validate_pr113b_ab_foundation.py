#!/usr/bin/env python3
"""PR113B Slice 1 safe A/B snapshot-boundary contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
DOC = ROOT / "docs/PR113B_WORLD_CLASS_PRODUCT_FINISH.md"
ROADMAP = ROOT / "docs/ROADMAP.md"
WORKFLOW = ROOT / ".github/workflows/pr113b-world-class-product-finish.yml"

for path in (PROFILES, TESTS, DOC, ROADMAP, WORKFLOW):
    assert path.is_file(), f"PR113B Slice 1 missing artifact: {path}"

profiles = PROFILES.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")

start = profiles.index("enum ContentABSlot:")
end = profiles.index("struct PlaybackSystemControlState:")
ab = profiles[start:end]

for token in (
    "enum ContentABSlot:",
    "struct ContentABAuditionState:",
    "var stereoEQ: StereoEQConfiguration",
    "var inputPreampDB: Double",
    "var headroomAttenuationDB: Double",
    "var dynamics: DynamicsConfiguration",
    "func merging(into current: ContentPresetState)",
    "struct ContentABSystemBoundary:",
    "selectedSystemProfileID: UUID?",
    "systemState: PlaybackSystemState",
    "case playbackSystemChanged",
    "case playbackSystemStateChanged",
    "struct ContentABSnapshot:",
    "final class ContentABComparisonController: ObservableObject",
    "func capture(_ slot: ContentABSlot)",
    "func clear(_ slot: ContentABSlot)",
    "func clearAll()",
    "func swapSnapshots()",
    "func compatibility(for slot: ContentABSlot)",
    "func currentContentDiffers(from slot: ContentABSlot)",
):
    assert token in ab, f"PR113B A/B foundation missing {token}"

# The safe audition value itself must remain exactly the deterministic
# content-facing engine state. Audio Unit topology and all system/hardware
# domains are excluded.
state_start = ab.index("struct ContentABAuditionState:")
state_end = ab.index("enum ContentABSystemCompatibility:")
audition_state = ab[state_start:state_end]
for forbidden in (
    "outputRouting",
    "outputDeviceProfile",
    "headphoneDeviceProfile",
    "bassManagement",
    "roomCorrection",
    "speakerDriverProcessing",
    "speakerIR",
    "associatedOutputUID",
    "outputGainDB",
):
    assert forbidden not in audition_state, (
        f"PR113B A/B audition state gained forbidden system field: {forbidden}"
    )

# Slice 1 must not gain live mutation authority. AudioUnitRack is mentioned only
# to state/preserve its exclusion from the snapshot payload.
for forbidden_call in (
    "selectOutput(",
    "replacePlaybackControlConfiguration(",
    "replaceBassManagementConfiguration(",
    "replaceMultiOutputRoutingConfiguration(",
    "replaceOutputDeviceProfileConfiguration(",
    "replaceHeadphoneDeviceProfileConfiguration(",
    "replaceSpeakerDriverProcessingConfiguration(",
    "replaceRoomCorrectionConfiguration(",
    "replaceSpeakerIRConfiguration(",
    "replaceRackConfiguration(",
    "applyContentStateWithoutAudioUnitRack(",
):
    assert forbidden_call not in ab, (
        f"PR113B Slice 1 gained live mutation authority: {forbidden_call}"
    )

for token in (
    "testABAuditionStateContainsOnlySafeContentDSP",
    "testABAuditionMergePreservesCurrentAudioUnitRack",
    "testABSystemBoundaryFailsClosedOnIdentityAndStateDrift",
    "testABSlotsHaveStableIdentityAndOpposites",
):
    assert token in tests, f"PR113B A/B regression missing {token}"

for token in (
    "Slice 1 — Safe A/B comparison foundation",
    "Audio Unit rack topology",
    "Playback System boundary",
    "No live mutation in Slice 1",
    "OPEN, DRAFT and UNMERGED",
):
    assert token in doc, f"PR113B Slice 1 documentation missing {token}"

for token in (
    "Current execution status — PR113B",
    "safe A/B comparison foundation",
    "full Notch Sixty backup & restore bundle",
    "full-fidelity Measurement Lab export",
    "Safe Launch / Recovery Mode",
    "Headroom Assistant",
    "Getting Started",
):
    assert token in roadmap, f"PR113B roadmap missing {token}"

for token in (
    "validate_pr113b_ab_foundation.py",
    "validate_pr113_production_ux.py",
    "ProductionInformationArchitectureTests",
):
    assert token in workflow, f"PR113B workflow missing {token}"

print("PR113B Slice 1 safe A/B foundation contract: PASS")
