#!/usr/bin/env python3
from pathlib import Path
root = Path(__file__).resolve().parents[1]
code = (root/"NotchSixty/Audio/QuietZoneFeedForwardShadowScheduler.swift").read_text()
tests = (root/"NotchSixtyTests/QuietZoneFeedForwardShadowSchedulerTests.swift").read_text()
pbx = (root/"NotchSixty.xcodeproj/project.pbxproj").read_text()
for item in ("QuietZoneFeedForwardSchedulingPlan",
             "QuietZoneFeedForwardShadowScheduler",
             "QuietZoneFeedForwardOutputClockAnchor",
             "QuietZoneFeedForwardReferenceDeadlineEvent",
             "QuietZonePhysicalLatencyReport",
             "deadlineGuardSeconds",
             "firstOutputSampleHostSeconds",
             "referenceAcousticHostSeconds",
             "N60FeedForwardPreviewFIRProcessFrame(",
             "discardedLeft", "discardedRight",
             "missedDeadline", "staleOutputClock", "discontinuity",
             "liveANCQualified: Bool = false",
             "outputConnected: Bool = false"):
    assert item in code, item
for item in ("testContinuousSampleTimelineProducesStrictDeadlinesAndNoOutput",
             "testRouteLeaseChangeStopsAndPermanentlyDisablesRehearsal",
             "testLateProcessingAndStaleOutputWitnessFailClosed",
             "testReferenceGapAndClockRewindStopProcessing",
             "testNonfiniteMicAndUnrealisticAcquisitionRejectImmediately",
             "testNegativePhysicalReserveCannotCreateSchedulingPlan",
             "testInvalidFIRAndMismatchedMeasurementRouteAreRejected"):
    assert item in tests,item
for item in ("QuietZoneFeedForwardShadowScheduler.swift in Sources",
             "QuietZoneFeedForwardShadowSchedulerTests.swift in Sources"):
    assert item in pbx,item
for bad in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
            "requestArm(", "setEnabled(", "stageRoomTreatment",
            "N60RenderKernelProcess", "N60RealtimeAudioBridgeRender"):
    assert bad not in code,bad
print("PR98 shadow scheduler safety guards passed")
