#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DIAG = ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
TESTS = ROOT / "NotchSixtyTests/ProductionAnalysisTests.swift"
DOC = ROOT / "docs/PR101_RELIABILITY_ACOUSTIC_ACCEPTANCE.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR101 validation failed: {message}")


diag = DIAG.read_text()
tests = TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "FullSystemReliabilityEvidenceAuthority",
    "FullSystemReliabilityRequirementCatalog",
    "FullSystemReliabilityObservation",
    "FullSystemReliabilityAcceptanceEvaluator",
    "remoteSoftwareAccepted",
    "physicalAcceptanceComplete",
    "releaseAcceptanceComplete",
    "physicalDeviceRecovery",
    "sleepWakeRecovery",
    "prolongedThermalRuntime",
    "speakerSafety",
    "acousticAcceptance",
    "minimumEvidence: .independentPhysicalReview",
):
    require(token in diag, f"acceptance framework missing {token!r}")

for token in (
    "unexpectedDropouts > 0",
    "nonFiniteSamples > 0",
    "unrecoveredFaults > 0",
    "crashes > 0",
    "duplicateRunID",
    "insufficientEvidence",
    "hardwareRequired",
):
    require(token in diag, f"fail-closed reliability rule missing {token!r}")

for token in (
    "testPR101AcceptanceCatalogSeparatesRemoteAndHardwareRequirements",
    "testPR101RemoteSoftwareCanPassWithoutClaimingPhysicalAcceptance",
    "testPR101SyntheticEvidenceCannotSatisfyPhysicalSafetyOrAcoustics",
    "testPR101FailureSignalsFailEvenStrongEvidence",
    "testPR101InjectedFaultsAreAllowedWhenEveryFaultRecovers",
    "testPR101RejectsDuplicateRunIDsAndInvalidResourceTelemetry",
):
    require(token in tests, f"PR101 XCTest missing {token}")

for phrase in (
    "full-system reliability",
    "deterministic simulation",
    "macos ci",
    "physical hardware",
    "independent physical review",
    "hardware-only requirements",
    "release acceptance remains false",
):
    require(phrase in doc, f"PR101 documentation missing {phrase!r}")

for inherited in (
    ROOT / "ci/validate_pr100_active_acoustics_ux.py",
    ROOT / "ci/validate_pr99_physical_verification.py",
    ROOT / "ci/audit_pr98_disconnected_boundary.py",
    ROOT / "docs/PR100_ACTIVE_ACOUSTICS_UX.md",
):
    require(inherited.exists(), f"inherited acceptance artifact missing {inherited.name}")

print("PR101 reliability and acoustic acceptance validation passed")
