#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
core = (root / "NotchSixty/Audio/ActiveQuietZoneSpatial.swift").read_text()
survey = (root / "NotchSixty/Audio/ActiveQuietZoneSpatialSurvey.swift").read_text()
ambient = (root / "NotchSixty/State/AmbientCompensationController.swift").read_text()
controller = (root / "NotchSixty/State/ActiveQuietZoneController.swift").read_text()
ui = (root / "NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift").read_text()
tests = (root / "NotchSixtyTests/ActiveQuietZoneSpatialTests.swift").read_text()
project = (root / "NotchSixty.xcodeproj/project.pbxproj").read_text()
doc = (root / "docs/PR95_MULTI_POSITION_QUIET_ZONE.md").read_text().lower()

def require(condition, label):
    if not condition:
        raise SystemExit("PR95 validation failed: " + label)

for token in (
    "struct ActiveQuietZoneSpatialCalibration",
    "struct ActiveQuietZoneSpatialToneSurvey",
    "struct ActiveQuietZoneSpatialPlanner",
    "struct ActiveQuietZoneSpatialStore",
    "commonPhaseReferenceValidated",
    "maximumPhaseClosureRadians",
    "minimumCoherence",
    "maximumPredictedSeatRegressionDB",
    "minimumWeightedReductionDB",
    "spatialInjectionEnvelope(",
    "noSpatialBenefit",
):
    require(token in core, "missing spatial ANC contract " + token)

require("AudioIOEngine" not in core, "pure planner must not own realtime engine")
for token in ("struct ActiveQuietZoneSpatialSurveyBuilder",
              "func refinedToneFrequency(", "func capture(", "func finish(",
              "firstSampleIndex", "phaseClosureRadians"):
    require(token in survey, "shared-clock survey logic missing " + token)
for token in ("phaseReferencedMicWindow()", "spatialMicrophoneEpoch",
              "spatialMicrophoneFrameEnd", "spatialLatestWindowEndFrame"):
    require(token in ambient, "microphone survey clock missing " + token)
require("ProductProfileController" not in core, "spatial calibration must be project-scoped")
for token in (
    "spatialPlanner.solve(",
    "prepareSpatialPositions()",
    "refreshSpatialCalibration()",
    "setSpatialEnabled(",
    "beginSpatialSurvey()",
    "captureSpatialSurveyWindow()",
    "cancelSpatialSurvey()",
    "calibration.anchorPositionID == model.id",
    "ambient.roomProjectMatchesSelectedMicrophone",
    "Date().timeIntervalSince(survey.capturedAt) < 1800",
):
    require(token in controller, "spatial runtime guard missing " + token)

for token in (
    '"Multi-Position Quiet Zone"',
    "quietZone.prepareSpatialPositions()",
    "quietZone.setSpatialEnabled(",
    "requires a shared phase reference",
    "Modeled spatial effect",
    '"One-Microphone Coherent Tone Survey"',
    "quietZone.beginSpatialSurvey()",
    "quietZone.captureSpatialSurveyWindow()",
):
    require(token in ui, "spatial UI contract missing " + token)
for token in (
    "testUnreferencedSequentialNoiseCannotAuthorizeSpatialANC",
    "testPhaseDriftOrPoorCoherenceFailsClosed",
    "testPhaseReferencedEqualSeatsYieldBoundedSpatialReduction",
    "testContradictorySpatialNoiseRejectsHarmfulCandidate",
    "testSpatialInjectionEnvelopeDoesNotClaimCancellation",
    "testSpatialCalibrationPersistsBesideProjectWithoutMutatingProject",
    "testSubBinToneEstimatorResolves60Point04Hz",
    "testSequentialMicSurveyClosesStableAnchorAndUsesSharedPhaseClock",
    "testSequentialMicSurveyRejectsAnchorReturnPhaseDrift",
    "testSequentialMicSurveyRejectsInterruptedInputClock",
):
    require(token in tests, "spatial test missing " + token)
for token in ("ActiveQuietZoneSpatial.swift in Sources",
              "ActiveQuietZoneSpatialSurvey.swift in Sources",
              "ActiveQuietZoneSpatialTests.swift in Sources"):
    require(token in project, "Xcode target missing " + token)
for word in ("phase", "sequential", "live", "do-no-harm", "project-scoped"):
    require(word in doc, "documentation missing " + word)
print("PR95 Multi-Position Quiet Zone architecture validation passed")
