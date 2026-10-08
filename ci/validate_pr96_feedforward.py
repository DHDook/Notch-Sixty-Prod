#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
core=(r/"NotchSixty/Audio/QuietZoneFeedForward.swift").read_text()
tests=(r/"NotchSixtyTests/QuietZoneFeedForwardTests.swift").read_text()
controller=(r/"NotchSixty/State/ActiveQuietZoneController.swift").read_text()
ui=(r/"NotchSixty/UI/ProductionFeedForwardReadinessCard.swift").read_text()
root=(r/"NotchSixty/UI/ProductionActiveAcousticsWorkspace.swift").read_text()
pbx=(r/"NotchSixty.xcodeproj/project.pbxproj").read_text()
for token in ("QuietZoneFeedForwardCalibration","QuietZoneFeedForwardBudgetAnalyzer",
"referenceAcquisitionSeconds","referenceProcessingSeconds","commandToSeatSeconds",
"conservativeReserveSeconds","maximumListenerRepeatDifferenceSeconds",
"synchronizedClockID","sourceTriggerID","QuietZoneFeedForwardStore",
"runtimeAvailable: false"):
    assert token in core,token
for token in ("testPositiveMeasuredMarginIsPlausibleButNeverArmsLiveANC",
"testNegativeMarginFailsCausality","testRejectsTriggerClockMismatchAndListenerDrift",
"testSidecarDoesNotChangePlaybackOrRoomProjectState"):
    assert token in tests,token
for token in ("prepareFeedForwardPlan()","refreshFeedForwardCalibration()",
"importMeasuredFeedForwardCalibration","feedForwardBudget"):
    assert token in controller,token
for token in ('Text("Virtual-Position Feed-Forward ANC")',"Causality reserve",
"Measured preview","Anti-noise path","Feed-forward remains unarmed"):
    assert token in ui,token
assert "ProductionFeedForwardReadinessCard(quietZone: quietZone)" in root
for token in ("QuietZoneFeedForward.swift in Sources",
"QuietZoneFeedForwardTests.swift in Sources",
"ProductionFeedForwardReadinessCard.swift in Sources"):
    assert token in pbx,token
for forbidden in ("replaceActiveQuietZoneRuntimeTarget","setEnabled(","requestArm","stageRoomTreatment"):
    assert forbidden not in core,"Unsafe runtime path in diagnostics: "+forbidden
print("PR96 feed-forward timing safety validator passed")
