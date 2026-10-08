#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
def read(path):
    file = root / path
    if not file.is_file():
        raise SystemExit(f"PR94 missing {path}")
    return file.read_text()
def require(test, message):
    if not test:
        raise SystemExit(f"PR94 validation failed: {message}")

model = read("NotchSixty/Audio/RoomPassiveTreatment.swift")
verification = read("NotchSixty/Audio/RoomTreatmentVerification.swift")
controller = read("NotchSixty/State/RoomTreatmentAdvisorController.swift")
ui = read("NotchSixty/UI/ProductionRoomTreatmentDesignSection.swift")
advisor = read("NotchSixty/UI/ProductionRoomTreatmentAdvisorWorkspace.swift")
tests = read("NotchSixtyTests/RoomTreatmentDesignVerificationTests.swift")
project = read("NotchSixty.xcodeproj/project.pbxproj")
docs = read("docs/PR94_TREATMENT_DESIGN_VERIFICATION.md").lower()
room = read("NotchSixty/Audio/RoomTreatmentAdvisor.swift")

for needle in ("RoomPassiveTreatmentPlan", "RoomPassiveTreatmentPlacement",
               "RoomPassiveTreatmentDesigner", "RoomPassiveTreatmentStore",
               "overlappingPlacements", "quarterWavelengthContextHz",
               "RoomPassiveTreatmentSuggestion", "advisor-treatment-v1.json"):
    require(needle in model, f"treatment model missing {needle}")
for needle in ("RoomTreatmentVerifier", "RoomTreatmentVerificationMetric",
               "RoomTreatmentVerificationReport", "matchedPositionCount",
               "beforeReport.bandDecayMeasurements", "meanSeatSpread",
               "reflectionPeak", "var afterByName:"):
    require(needle in verification, f"verification missing {needle}")

for needle in ("bandDecayMeasurements", "RoomTreatmentAdvisorBandDecay"):
    require(needle in room, f"PR92 reusable decay evidence missing {needle}")

for forbidden in ("AudioIOEngine", "ProductProfileController",
                  "replaceRoomCorrection", "stageRoomTreatment",
                  "requestArm", "setPlaybackAdaptationMode"):
    require(forbidden not in model + verification,
            f"offline treatment engine must not touch live DSP: {forbidden}")
    require(forbidden not in controller, f"Advisor controller must not depend on {forbidden}")

for needle in ("createTreatmentPlan()", "addTreatmentSuggestion(",
               "addManualTreatment(", "updateTreatmentPlacement(",
               "saveTreatmentPlan()", "revertTreatmentPlan()",
               "treatmentStore.load", "treatmentStore.save",
               "verifyTreatmentFollowUp(", "treatmentFollowUpProjects"):
    require(needle in controller, f"controller missing {needle}")

for needle in ('Text("Treatment Design & Verification")',
               '"Evidence-Based Placement Candidates"',
               '"Before / After Measurements"',
               '"Save Treatment Plan"', '"Add Placement"',
               "TreatmentPlanRoomSketch", "advisor.verifyTreatmentFollowUp(",
               "room" if False else "advisor.addTreatmentSuggestion("):
    require(needle in ui, f"treatment UI missing {needle}")
require("ProductionRoomTreatmentDesignSection(" in advisor,
        "Room Advisor is not showing treatment workspace")

for needle in ("testTreatmentPlanRejectsOutOfBoundsAndOverlap",
               "testMeasuredRingingSuggestsSubstantialBassTreatmentNotThinPanel",
               "testNoEvidenceDoesNotRecommendBlanketAbsorption",
               "testTreatmentPlanIsSeparateFromPersistedRoomCorrectionProject",
               "testVerificationRejectsMismatchedMicOrSystem",
               "testVerificationRejectsDuplicatePositionNamesRatherThanCrashing",
               "testVerificationMeasuresImprovedBassSeatConsistency",
               "testVerificationFailsClosedOnClippedFollowUp",
               "testTreatmentDraftDoesNotOverwritePlanUntilExplicitSave"):
    require(needle in tests, f"missing safety test: {needle}")
for needle in ("RoomPassiveTreatment.swift in Sources",
               "RoomTreatmentVerification.swift in Sources",
               "ProductionRoomTreatmentDesignSection.swift in Sources",
               "RoomTreatmentDesignVerificationTests.swift in Sources"):
    require(needle in project, f"Xcode target integration missing {needle}")
for needle in ("project-scoped", "same routing", "mic", "t20",
               "read-only", "no filter", "not comparable", "baseline"):
    # 'read-only' refers to comparison view; adding/editing plan is allowed.
    if needle == "read-only":
        require("read-only" in docs, "verification must be observational")
    else:
        require(needle in docs, f"contract missing {needle}")

print("PR94 Treatment Design & Verification architecture validation passed")
