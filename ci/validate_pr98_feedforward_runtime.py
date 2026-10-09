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
native=(root/"NotchSixty/Audio/Realtime/N60FeedForwardDeadlineBridge.c").read_text()
native_header=(root/"NotchSixty/Audio/Realtime/N60FeedForwardDeadlineBridge.h").read_text()
native_adapter=(root/"NotchSixty/Audio/QuietZoneNativeShadowTimingTransport.swift").read_text()
native_tests=(root/"NotchSixtyTests/QuietZoneNativeShadowTimingTransportTests.swift").read_text()
brd=(root/"NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h").read_text()
for token in ("N60FFDeadlineBridgeCreate(", "N60FFDeadlineBridgeProcess(",
              "N60FFDeadlineBridgeRead(", "N60FFDeadlineFaultOverflow",
              "N60FFDeadlineFaultStaleWitness",
              "N60FFDeadlineFaultClockDiscontinuity",
              "N60FeedForwardPreviewFIRProcessFrame(",
              "discardedLeft", "discardedRight",
              "atomic_store_explicit", "memory_order_release",
              "outputConnected = false", "liveANCQualified = false"):
    assert token in native or token in native_header,token
for token in ("N60_FF_DEADLINE_MAX_FRAMES", "N60FFDeadlineRecord",
              "N60FFDeadlineSnapshot", "N60FFDeadlineOutputWitness",
              "N60FFDeadlineReference"):
    assert token in native_header,token
for token in ("N60FeedForwardReferenceFrame", "N60FFDeadlineBridgeProcess(",
              "firstFrameHostTime", "firstFrameSampleTime",
              "outputConnected: Bool { false }", "liveANCQualified: Bool { false }"):
    assert token in native_adapter,token
for token in ("testNativeBridgeSchedulesFIFOWithoutEverProducingPCM",
              "testOverflowStopsPermanentlyAndRevokesAllQueuedMetadata",
              "testOutputLeaseAndClockAnchorDiscontinuityFailClosed",
              "testSourceFrameRewindAndWitnessMutationCannotBeIgnored",
              "testMissedDeadlineAndStaleClockFailClosed",
              "testWraparoundAfterDrainsKeepsFIFOAndDoesNotRepeatAudio",
              "testInvalidNativePlanAndFIRAreRejectedAtConstruction"):
    assert token in native_tests,token
for token in ("N60FeedForwardDeadlineBridge.c in Sources",
              "QuietZoneNativeShadowTimingTransport.swift in Sources",
              "QuietZoneNativeShadowTimingTransportTests.swift in Sources",
              "N60FeedForwardDeadlineBridge.h"):
    assert token in pbx,token
assert "#import \"N60FeedForwardDeadlineBridge.h\"" in brd
for forbidden in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
                  "N60RealtimeAudioBridgeRender(", "N60RenderKernelProcess("):
    assert forbidden not in native,forbidden
for forbidden in ("requestArm(", "setEnabled(", "stageRoomTreatment("):
    assert forbidden not in native_adapter,forbidden
print("PR98 shadow scheduler safety guards passed")
