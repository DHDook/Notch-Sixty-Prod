#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty" / "Audio" / "SpeakerOptimizerMeasurementEvidence.swift"
TESTS = ROOT / "NotchSixtyTests" / "SpeakerOptimizerMeasurementEvidenceTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj" / "project.pbxproj"
DOC = ROOT / "docs" / "PR103_SPEAKER_OPTIMIZER_MEASUREMENT_FOUNDATION.md"


def fail(message: str) -> None:
    print(f"PR103 measurement-foundation validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def require(condition: bool, message: str) -> None:
    if not condition:
        fail(message)


for path in (SOURCE, TESTS, PROJECT, DOC):
    require(path.is_file(), f"missing required file {path.relative_to(ROOT)}")

source = SOURCE.read_text(encoding="utf-8")
tests = TESTS.read_text(encoding="utf-8")
project = PROJECT.read_text(encoding="utf-8")
doc = DOC.read_text(encoding="utf-8")

for token in (
    "enum SpeakerOptimizerMeasurementRole",
    "case baseline",
    "case candidate",
    "case verification",
    "struct SpeakerOptimizerMeasurementSet",
    "struct SpeakerOptimizerMeasurementCapture",
    "struct SpeakerOptimizerMeasurementEvidenceEvaluator",
    "static let minimumRepeatCount = 3",
    "static let minimumSNRDB = 30.0",
    "static let maximumMagnitudeRepeatabilityRMSDB = 1.5",
    "static let maximumArrivalSpreadMilliseconds = 0.5",
    "static let minimumPhaseConsistency = 0.80",
    "inter-repeat phase consistency",
    "init(",
    "compacting measurement: MultichannelCalibrationMeasurement",
    "Capture identity changed across playback routing, microphone, sample rate, position, or source.",
    "enum SpeakerOptimizerMeasurementExcitationTarget",
    "case protectedDriverBus(SpeakerOutputBus)",
    "struct SpeakerOptimizerMeasurementTransportPlan",
    "struct SpeakerOptimizerMeasurementTransportPlanner",
    "activeCrossoverRoutingPresent",
    "configuredLimiterWouldBeBypassed",
    "preservesMandatoryProtection",
    "struct SpeakerOptimizerMeasurementSessionStep",
    "struct SpeakerOptimizerMeasurementSessionProgress",
    "struct SpeakerOptimizerMeasurementSessionOrchestrator",
    "struct SpeakerOptimizerMeasurementSetStore",
    "validatePersistenceStructure",
    "retryLatestCapture",
    "Position-major ordering intentionally minimizes microphone moves.",
):
    require(token in source, f"measurement evidence model missing {token!r}")

# Compact optimizer persistence must never grow a raw sweep/impulse payload.
capture_start = source.index("struct SpeakerOptimizerMeasurementCapture")
capture_end = source.index("struct SpeakerOptimizerMeasurementSet", capture_start)
capture_block = source[capture_start:capture_end]
for forbidden in ("var rawCapture", "var impulseResponse"):
    require(forbidden not in capture_block, f"compact capture unexpectedly stores {forbidden}")

# Phase repeatability is deliberately named as such rather than claiming
# conventional magnitude-squared coherence from data the model does not hold.
require(
    "not conventional" in source and "magnitude-squared coherence" in source,
    "phase-consistency semantics are no longer explicit",
)

for token in (
    "testThreeStableRepeatsAreOptimizerReady",
    "testTwoRepeatsFailClosed",
    "testLowSNRAndClippingFailClosed",
    "testMagnitudeRepeatabilityRegressionFailsClosed",
    "testArrivalInstabilityFailsClosed",
    "testPhaseConsistencyIsCircularAndFailsForIncoherentRepeats",
    "testIdentityContinuityRejectsMixedRoutingOrMicrophone",
    "testMissingPlannedSourceCoverageFailsClosed",
    "testCompactionRetainsAnalyzedEvidenceWithoutRawSweepStorage",
    "testBaselineCandidateVerificationRolesRemainDistinct",
    "testWholeSpeakerCanReuseExistingTargetedCalibrationTransport",
    "testSubwooferCanReuseExistingTargetedCalibrationTransport",
    "testProtectedDriverBusFailsClosedInsteadOfRawPhysicalSweep",
    "testActiveSplitDriverRoutingBlocksDirectCalibrationReuse",
    "testConfiguredDriverLimiterBlocksDirectCalibrationReuse",
    "testUnavailablePhysicalRouteFailsClosed",
    "testSessionPlanIsPositionMajorToMinimizeMicrophoneMoves",
    "testSessionResumesAtFirstIncompleteRepeatAfterReloadStyleState",
    "testSessionRejectsCaptureIdentityDrift",
    "testRetryLatestCaptureMakesThatRepeatPendingAgain",
    "testMeasurementSetStoreRoundTripPreservesCompactEvidence",
    "testPersistenceRejectsCaptureOutsideSessionIdentity",
):
    require(token in tests, f"targeted PR103 test missing {token!r}")

for token in (
    "F10300000000000000000001 /* SpeakerOptimizerMeasurementEvidence.swift in Sources */",
    "F10300000000000000000002 /* SpeakerOptimizerMeasurementEvidenceTests.swift in Sources */",
    "F10300000000000000000011 /* SpeakerOptimizerMeasurementEvidence.swift */",
    "F10300000000000000000012 /* SpeakerOptimizerMeasurementEvidenceTests.swift */",
):
    require(token in project, f"Xcode integration missing {token!r}")

for token in (
    "one movable measurement microphone",
    "baseline",
    "candidate",
    "verification",
    "repeatability",
    "SNR",
    "phase/coherence",
    "preserve mandatory crossover/protection filters",
    "Remote CI cannot establish",
    "Slice 2 implementation checkpoint",
    "Protected driver measurement remains blocked",
    "enabled per-driver limiter",
    "Slice 3 implementation checkpoint",
    "Deterministic one-mic plan",
    "Interruption and resume",
    "Compact versioned persistence",
):
    require(token in doc, f"PR103 design contract missing {token!r}")

print("PR103 Speaker Optimizer measurement foundation validation passed")
