#!/usr/bin/env python3
"""PR113B Slice 1 safe A/B snapshot-boundary contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
BACKUP = ROOT / "NotchSixty/Backup/NotchSixtyBackup.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
APP = ROOT / "NotchSixty/NotchSixtyApp.swift"
TOOLBAR = ROOT / "NotchSixty/UI/ProductionProfileToolbar.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
DOC = ROOT / "docs/PR113B_WORLD_CLASS_PRODUCT_FINISH.md"
ROADMAP = ROOT / "docs/ROADMAP.md"
WORKFLOW = ROOT / ".github/workflows/pr113b-world-class-product-finish.yml"

for path in (
    PROFILES, BACKUP, PROJECT, ENGINE, APP, TOOLBAR, TESTS, DOC, ROADMAP,
    WORKFLOW
):
    assert path.is_file(), f"PR113B Slice 1 missing artifact: {path}"

profiles = PROFILES.read_text(encoding="utf-8")
backup = BACKUP.read_text(encoding="utf-8")
project = PROJECT.read_text(encoding="utf-8")
engine = ENGINE.read_text(encoding="utf-8")
app = APP.read_text(encoding="utf-8")
toolbar = TOOLBAR.read_text(encoding="utf-8")
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
    "struct ContentABLoudnessMatchPlan:",
    "static let maximumAttenuationDB = 12.0",
    "levelMatchingEnabled",
    "loudnessMatchPlan",
    "func audition(_ slot: ContentABSlot) async",
    "func endAudition(restoringBaseline: Bool = true) async",
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
    "testABLoudnessMatchOnlyAttenuatesTheLouderCapture",
    "testABLoudnessMatchIsBoundedAndRequiresValidSignal",
    "testABSnapshotCanCarryMeasuredLoudnessWithoutBroadeningAuditionState",
):
    assert token in tests, f"PR113B A/B regression missing {token}"


for token in (
    "func transitionContentAuditionState(",
    "additionalInputAttenuationDB: Double = 0",
    "try session.transitionDSPGraph(graph)",
    "renderBassManagementConfiguration()",
    "attachActiveRoomCorrectionProgramIfNeeded(",
    "attachActiveSpeakerIRProgramIfNeeded(",
    "applyAudioUnitRackLatency(to: &graph)",
):
    assert token in engine, f"PR113B Slice 2 engine contract missing {token}"

# The A/B executor may only call the dedicated content-domain transition.
# It must not gain direct system/hardware mutation authority.
controller_start = ab.index("final class ContentABComparisonController")
controller = ab[controller_start:]
for forbidden_call in (
    "selectOutput(",
    "replaceBassManagementConfiguration(",
    "replaceMultiOutputRoutingConfiguration(",
    "replaceOutputDeviceProfileConfiguration(",
    "replaceHeadphoneDeviceProfileConfiguration(",
    "replaceSpeakerDriverProcessingConfiguration(",
    "replaceRoomCorrectionConfiguration(",
    "replaceSpeakerIRConfiguration(",
    "replaceRackConfiguration(",
):
    assert forbidden_call not in controller, (
        f"PR113B A/B controller gained hardware/system authority: {forbidden_call}"
    )

for token in (
    "let abComparison: ContentABComparisonController",
    "ContentABComparisonController(profiles: profiles)",
):
    assert token in app, f"PR113B product ownership missing {token}"

for token in (
    "abComparisonControl",
    'Label("A/B", systemImage: "arrow.left.arrow.right")',
    '"Capture Current as A"',
    '"Capture Current as B"',
    '"Measured Level Match"',
    '"Swap A / B"',
    '"Exit A/B and Restore"',
    "await comparison.audition(.a)",
    "await comparison.audition(.b)",
):
    assert token in toolbar, f"PR113B A/B production UI missing {token}"


for token in (
    "struct PlaybackSystemHardwareMappingRequirement:",
    "struct ProductProfileBackupSnapshot:",
    "var referencedHardwareDeviceUIDs: Set<String>",
    "case hardwareMappingRequired(profile: String)",
    "func makeBackupSnapshot()",
    "func restoreBackupSnapshot(",
    "availableOutputUIDs: Set<String>? = nil",
    "recomputeHardwareRequirements: Bool = true",
    "func confirmSelectedSystemHardwareMapping()",
    "hardwareMappingRequiredSystemIDs",
):
    assert token in profiles, f"PR113B Slice 3 profile backup contract missing {token}"

for token in (
    "struct NotchSixtyBackupPreferences:",
    "struct NotchSixtyBackupManifestEntry:",
    "struct NotchSixtyBackupManifest:",
    "struct NotchSixtyBackupBundle:",
    "final class NotchSixtyBackupService",
    "func exportData(",
    "func inspect(_ data: Data)",
    "func restore(",
    "SHA256.hash(data: data)",
    "roomCorrectionProjects",
    "measurementLabSessions",
    "binauralAssets",
):
    assert token in backup, f"PR113B Slice 3 backup service missing {token}"

# General backup must never recreate physical acceptance authority.
for forbidden in (
    "HardwareAcceptanceCampaign",
    "HardwareAcceptanceCampaignStore",
    "physicalAcceptanceComplete",
    "mayMergeIntoMain",
):
    assert forbidden not in backup, (
        f"PR113B backup gained acceptance authority/evidence coupling: {forbidden}"
    )

for token in (
    "NotchSixtyBackup.swift in Sources",
    "NotchSixtyBackup.swift",
):
    assert token in project, f"PR113B backup target membership missing {token}"

assert "ProductBackup.swift" not in project
assert not (ROOT / "NotchSixty/State/ProductBackup.swift").exists()

for token in (
    "let backup: NotchSixtyBackupService",
    "NotchSixtyBackupService(",
    'title: "Backup & Restore"',
    '"Save Backup…"',
    '"Restore Backup…"',
    '"n60backup"',
    "product.backup.restore(data)",
    "preferences.makeBackupSnapshot()",
    "preferences.restoreBackupSnapshot(",
):
    assert token in app, f"PR113B backup production UI missing {token}"

for token in (
    '"Needs Mapping"',
    '"Confirm Hardware Mapping"',
    "selectedSystemHardwareMappingRequirement",
):
    assert token in toolbar, f"PR113B hardware remapping UI missing {token}"

for token in (
    "testBackupRestoreMarksUnavailablePlaybackHardwareForMapping",
    "testBackupRestoreKeepsKnownHardwareEligibleWithoutRemapping",
    "testBackupPreferencesExcludeOSOwnedLaunchState",
    "testBackupInspectionRejectsDomainTampering",
):
    assert token in tests, f"PR113B Slice 3 regression missing {token}"

for token in (
    "Slice 1 — Safe A/B comparison foundation",
    "Audio Unit rack topology",
    "Playback System boundary",
    "No live mutation in Slice 1",
    "Slice 2 — Click-free, measured-level A/B audition",
    "attenuation-only",
    "Exit A/B and Restore",
    "Slice 3 — Full Notch Sixty backup & restore",
    "binaural",
    "Needs Mapping",
    "SHA-256",
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

print("PR113B Slices 1–3 world-class product contract: PASS")
