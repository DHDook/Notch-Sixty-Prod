#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERIFY = ROOT / "NotchSixty/Audio/MIMORoomTreatmentVerification.swift"
TESTS = ROOT / "NotchSixtyTests/MIMORoomTreatmentVerificationTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR75_ROOM_TREATMENT_VERIFICATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR75 validation failed: {message}")


verify = VERIFY.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "MIMORoomTreatmentSourceSafetyDeclaration",
    "reservedHeadroomDB >= 3.0",
    "excursionModelConfirmed",
    "thermalModelConfirmed",
    "finalProtectionChainConfirmed",
    "struct MIMORoomTreatmentVerifier",
    "minimumSpatialRMSErrorImprovementDB = 0.50",
    "maximumAbsoluteMeanLevelShiftDB = 1.50",
    "maximumWorstSeatErrorIncreaseDB = 1.50",
    "maximumPerSourceSpatialRMSErrorDegradationDB = 0.25",
    "MIMORoomTreatmentHardwareAcceptance",
    "MIMORoomTreatmentDeploymentGate",
    "eligibleForFutureLiveIntegration",
):
    require(token in verify, f"verification/safety layer missing {token}")

order = [
    "case blockedBySourceSafety",
    "case repeatMeasurementRequired",
    "case repeatMeasurementFailed",
    "case hardwareAcceptanceRequired",
    "case eligibleForFutureLiveIntegration",
]
positions = [verify.find(token) for token in order]
require(all(position >= 0 for position in positions),
        "deployment gate states are incomplete")
require(positions == sorted(positions),
        "deployment gate states are not documented in fail-closed order")

require("guard let verification else" in verify,
        "repeat measurement is not mandatory after source safety")
require("guard verification.accepted" in verify,
        "failed repeat measurement can advance")
require("guard let hardwareAcceptance" in verify,
        "manual hardware acceptance is not mandatory")
require("hardwareAcceptance.isComplete" in verify,
        "hardware acceptance completeness is not checked")

for forbidden in (
    "AudioDeviceStart",
    "AudioDeviceCreateIOProcID",
    "N60LiveNChannelRenderProcessFrame",
    "N60MIMOFIRRuntimeProcessFrame",
    "N60RenderKernelPublishSnapshot",
    "func apply(",
    "func applying(",
):
    require(forbidden not in verify,
            f"PR75 unexpectedly references live activation primitive {forbidden}")

require("MIMORoomTreatmentVerification.swift in Sources" in project,
        "PR75 verification source missing from app target")
require("MIMORoomTreatmentVerificationTests.swift in Sources" in project,
        "PR75 tests missing from test target")

for token in (
    "testRepeatMeasurementAcceptsMaterialSpatialImprovementWithoutLevelShift",
    "testRepeatMeasurementRejectsFakeWinFromOverallLevelShift",
    "testAggregateImprovementCannotHideOneSourceGettingWorse",
    "testMissingRepeatMeasurementFailsClosed",
    "testDeploymentGateRequiresSafetyThenMeasurementThenHardwareAcceptance",
    "testSourceSafetyRequiresBandHeadroomAndPhysicalModels",
    "testFailedRepeatMeasurementCannotAdvanceToHardwareAcceptance",
):
    require(token in tests, f"PR75 acceptance missing {token}")

normalized_doc = doc.lower().replace(chr(96), "")
for phrase in (
    "at least **3 db reserved headroom**",
    "repeat acoustic verification",
    "hardware acceptance record",
    "eligibleforfutureliveintegration",
    "is not an active state",
    "cannot be generated",
    "does not connect",
):
    require(phrase.lower() in normalized_doc,
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr74_mimo_fir_runtime.py").exists(),
        "inherited PR74 structural validation is missing")
require((ROOT / "ci/validate_pr74_mimo_fir_runtime.c").exists(),
        "inherited PR74 runtime validation is missing")

print("PR75 room-treatment verification/safety structural validation passed")
