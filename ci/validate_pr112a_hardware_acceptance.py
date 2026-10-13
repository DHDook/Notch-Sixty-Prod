#!/usr/bin/env python3
"""PR112A remote-only hardware acceptance infrastructure contract audit."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Acceptance/HardwareAcceptance.swift"
TESTS = ROOT / "NotchSixtyTests/HardwareAcceptanceTests.swift"
DOC = ROOT / "docs/PR112A_REMOTE_HARDWARE_ACCEPTANCE.md"
WORKFLOW = ROOT / ".github/workflows/pr112a-remote-hardware-acceptance.yml"
MANIFEST = ROOT / "ci/build_pr112a_remote_hardware_readiness.py"
ROADMAP = ROOT / "docs/ROADMAP.md"

for path in (SOURCE, TESTS, DOC, WORKFLOW, MANIFEST, ROADMAP):
    assert path.is_file(), f"PR112A missing artifact: {path}"

source = SOURCE.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")
workflow = WORKFLOW.read_text(encoding="utf-8")
manifest = MANIFEST.read_text(encoding="utf-8")
roadmap = ROADMAP.read_text(encoding="utf-8")

for gate in ("H01", "H02", "H03", "H04", "H05", "H06", "H07", "H08"):
    assert f'"{gate}"' in source or f'= "{gate}"' in source, f"missing gate {gate}"
    assert gate in doc, f"documentation missing gate {gate}"

for token in (
    "enum HardwareAcceptanceEvidenceAuthority:",
    "case remoteSoftware = 0",
    "case physicalHardware = 1",
    "case independentPhysicalReview = 2",
    "struct HardwareAcceptanceCampaign:",
    "struct HardwareAcceptanceObservation:",
    "struct HardwareAcceptanceEnvironment:",
    "struct HardwareAcceptanceCampaignStore: Sendable",
    "scopeDecisions:",
    "supplementalCapabilities:",
    "coveredCapabilities:",
    ".insufficientScope(",
    ".liveFeedForwardANC",
    "physicalAcceptanceComplete",
    "liveFeedForwardANCAuthorized",
    "newest.outcome",
    ".insufficientAuthority(",
    "options: .atomic",
):
    assert token in source, f"PR112A acceptance contract missing {token}"

for forbidden in (
    "AudioIOEngine",
    "replaceSelectedSystem",
    "makeRealtimeSnapshot(",
    "startPhysical",
    "approveAndApply(",
    "func apply(",
):
    assert forbidden not in source, f"PR112A evidence model gained runtime authority: {forbidden}"

for token in (
    "testRemoteSoftwarePassCannotSatisfyPhysicalGate",
    "testSplitDriverExclusionDoesNotWaiveMandatoryH05",
    "testIncludedSplitDriverScopeRequiresExplicitH05Coverage",
    "testRequiredPhysicalCampaignCanCompleteWithConditionalFeaturesExcluded",
    "testLiveANCAuthorizationRequiresIncludedH08IndependentReviewAndAllGates",
    "testNewestObservationCanRegressPreviouslyPassedGate",
    "testDuplicateEvidenceIDIsRejected",
    "testCampaignPersistenceRoundTripAndCorruptionFailClosed",
):
    assert token in tests, f"PR112A regression missing {token}"

for key in (
    '"physicalAcceptanceComplete": False',
    '"releaseAcceptanceComplete": False',
    '"liveFeedForwardANCAuthorized": False',
    '"mayMergeIntoMain": False',
    '"physicalEvidenceSuppliedByCI": False',
):
    assert key in manifest, f"PR112A readiness manifest authority changed: {key}"

for token in (
    "remoteSoftware",
    "physicalHardware",
    "independentPhysicalReview",
    "append-only",
    "H05 is **not waived**",
    "PR112A remains OPEN, DRAFT and UNMERGED",
):
    assert token in doc, f"PR112A documentation boundary missing {token}"

assert "HardwareAcceptanceTests" in workflow
assert "build_pr112a_remote_hardware_readiness.py" in workflow
assert "validate_pr111_protected_driver_optimizer.py" in workflow
assert "PR112A" in roadmap

print("PR112A remote acceptance infrastructure safety contract: PASS")
