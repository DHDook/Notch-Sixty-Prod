#!/usr/bin/env python3
from pathlib import Path
r=Path(__file__).resolve().parents[1]
core=(r/"NotchSixty/Audio/QuietZoneFeedForward.swift").read_text()
virtual=(r/"NotchSixty/Audio/QuietZoneVirtualSeatDesigner.swift").read_text()
virtual_tests=(r/"NotchSixtyTests/QuietZoneVirtualSeatDesignerTests.swift").read_text()
dry_c=(r/"NotchSixty/Audio/Realtime/N60FeedForwardPreviewFIR.c").read_text()
dry_h=(r/"NotchSixty/Audio/Realtime/N60FeedForwardPreviewFIR.h").read_text()
dry_tests=(r/"NotchSixtyTests/FeedForwardPreviewFIRTests.swift").read_text()
survey=(r/"NotchSixty/Audio/QuietZoneFeedForwardSurvey.swift").read_text()
reference_c=(r/"NotchSixty/Audio/Realtime/N60FeedForwardReferenceBridge.c").read_text()
reference_h=(r/"NotchSixty/Audio/Realtime/N60FeedForwardReferenceBridge.h").read_text()
reference_swift=(r/"NotchSixty/Audio/CoreAudio/FeedForwardReferenceTransport.swift").read_text()
survey_tests=(r/"NotchSixtyTests/QuietZoneFeedForwardSurveyTests.swift").read_text()
reference_tests=(r/"NotchSixtyTests/FeedForwardReferenceBridgeTests.swift").read_text()
bridging=(r/"NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h").read_text()
tests=(r/"NotchSixtyTests/QuietZoneFeedForwardTests.swift").read_text()
probe=(r/"NotchSixty/Audio/QuietZoneFeedForwardProbe.swift").read_text()
probe_tests=(r/"NotchSixtyTests/QuietZoneFeedForwardProbeTests.swift").read_text()
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
for token in ("QuietZoneFeedForwardProbeDetector", "synchronizedClockID",
"firstInputFrameAfterTriggerSeconds", "minimumRecoveredSNRDB"):
    assert token in probe,token
for token in ("testKnownCodedProbeArrivalIsRecovered",
"testRelativeHallwayAndListenerPreviewFromOneMic",
"testUncorrelatedCaptureNeverInventsArrival"):
    assert token in probe_tests,token
for token in ("QuietZoneFeedForwardSurveySession", "maximumSurveyDuration",
"maximumListenerRepeatDifferenceSeconds", "committed("):
    assert token in survey,token
for token in ("N60FeedForwardReferenceBridgeProcessPlanar",
"N60FeedForwardReferenceBridgeRead", "invalidTimestamps", "droppedFrames"):
    assert token in reference_c and token in reference_h,token
for token in ("FeedForwardReferenceTransport", "N60FeedForwardReferenceIOProc",
"AudioDeviceStart", "read(maximumFrames:"):
    assert token in reference_swift,token
for token in ("testSequentialSurveyCollectsOnlyListenerUpstreamListener",
"testListenerReturnDriftInvalidatesSurvey"):
    assert token in survey_tests,token
for token in ("testTimestampedRingPreservesSamplesAndInputClock",
"testFullRingDropsExcessWithoutOverwritingUnreadSamples"):
    assert token in reference_tests,token
assert '#import "N60FeedForwardReferenceBridge.h"' in bridging
for token in ("QuietZoneVirtualSeatDesigner", "measuredCoherence", "leftLeakageAtReference",
"conservativeReserveSeconds", "maximumLeakageFraction", "safePreviewOnly"):
    assert token in virtual,token
for token in ("testModelCandidateImprovesListenerYetCannotArmLiveANC",
"testJointBandHeadroomLimitsSumOfOutputs",
"testPoorRepeatabilityAndSpeakerEchoAreRejected",
"testNegativeCausalityMarginCannotGenerateControls"):
    assert token in virtual_tests,token
for token in ("N60FeedForwardPreviewFIRProcessFrame",
"N60FeedForwardPreviewFIRConfigure",
"N60_FEED_FORWARD_PREVIEW_MAX_OUTPUT_PEAK"):
    assert token in dry_c and token in dry_h,token
for token in ("testImpulseResponseIsCausalAndMatchesTaps",
"testRejectExcessiveGainAndNonfiniteFilterWithoutReplacingConfiguration",
"testNonFiniteMicrophoneInputSilencesAndFlushesHistory"):
    assert token in dry_tests,token
assert '#import "N60FeedForwardPreviewFIR.h"' in bridging
for token in ("prepareFeedForwardPlan()","refreshFeedForwardCalibration()",
"importMeasuredFeedForwardCalibration","feedForwardBudget"):
    assert token in controller,token
for token in ('Text("Virtual-Position Feed-Forward ANC")',"Causality reserve",
"Measured preview","Anti-noise path","Feed-forward remains unarmed"):
    assert token in ui,token
assert "ProductionFeedForwardReadinessCard(quietZone: quietZone)" in root
for token in ("QuietZoneFeedForward.swift in Sources",
"QuietZoneFeedForwardTests.swift in Sources",
"ProductionFeedForwardReadinessCard.swift in Sources",
"QuietZoneFeedForwardProbe.swift in Sources",
"QuietZoneFeedForwardProbeTests.swift in Sources",
"QuietZoneFeedForwardSurvey.swift in Sources",
"QuietZoneFeedForwardSurveyTests.swift in Sources",
"N60FeedForwardReferenceBridge.c in Sources",
"FeedForwardReferenceTransport.swift in Sources",
"FeedForwardReferenceBridgeTests.swift in Sources",
"QuietZoneVirtualSeatDesigner.swift in Sources",
"QuietZoneVirtualSeatDesignerTests.swift in Sources",
"N60FeedForwardPreviewFIR.c in Sources",
"FeedForwardPreviewFIRTests.swift in Sources"):
    assert token in pbx,token
for forbidden in ("replaceActiveQuietZoneRuntimeTarget","setEnabled(","requestArm","stageRoomTreatment"):
    assert forbidden not in core,"Unsafe runtime path in diagnostics: "+forbidden
print("PR96 feed-forward timing safety validator passed")
