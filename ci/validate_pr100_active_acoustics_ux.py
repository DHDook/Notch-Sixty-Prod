#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
READINESS = ROOT / "NotchSixty/UI/ProductionFeedForwardReadinessCard.swift"
WORKSPACE = ROOT / "NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionInformationArchitectureTests.swift"
DOC = ROOT / "docs/PR100_ACTIVE_ACOUSTICS_UX.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR100 validation failed: {message}")


readiness = READINESS.read_text()
workspace = WORKSPACE.read_text()
tests = TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "ActiveAcousticsCommissioningUXSnapshot",
    "Commissioning & Verification",
    "PR100 · READ ONLY",
    "HARDWARE REQUIRED",
    "DISCONNECTED",
    "PR99 A/B/A",
):
    require(token in readiness, f"commissioning UX missing {token!r}")

for token in (
    "instrumentEvidenceAuthenticated = false",
    "physicalAttenuationVerified = false",
    "emergencyMuteHardwareVerified = false",
    "liveANCOutputAuthorized = false",
):
    require(token in readiness, f"fail-closed fact missing {token!r}")

for forbidden in (
    "liveANCOutputAuthorized = true",
    "physicalAttenuationVerified = true",
    "emergencyMuteHardwareVerified = true",
    "outputConnected = true",
):
    require(forbidden not in readiness,
            f"PR100 UI must not authorize hardware state: {forbidden}")

for token in (
    'case quietZone',
    'ProductionFeedForwardReadinessCard(quietZone: quietZone)',
    'Text("Live Cancellation Detail")',
    'Text("Active Acoustics")',
):
    require(token in workspace, f"Active Acoustics integration missing {token!r}")

for token in (
    "testActiveAcousticsUXRequiresCalibrationBeforeTimingReview",
    "testPhysicallyPlausibleTimingStillRequiresHardwareVerification",
    "testNonCausalTimingNeverLooksReady",
):
    require(token in tests, f"PR100 XCTest missing {token}")

for phrase in (
    "read-only",
    "commissioning & verification",
    "hardware-gated",
    "speaker-connected anc remains disconnected",
    "pr99",
):
    require(phrase in doc, f"PR100 document missing {phrase!r}")

for inherited in (
    ROOT / "ci/validate_pr99_physical_verification.py",
    ROOT / "ci/audit_pr98_disconnected_boundary.py",
    ROOT / "docs/PR99_PHYSICAL_ANC_VERIFICATION.md",
    ROOT / "docs/PR98_SOFTWARE_CLOSURE.md",
):
    require(inherited.exists(), f"inherited safety artifact missing {inherited.name}")

print("PR100 Active Acoustics UX validation passed")
