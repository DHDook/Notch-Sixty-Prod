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
clock=(root/"NotchSixty/Audio/QuietZoneFeedForwardClockMonitor.swift").read_text()
clock_tests=(root/"NotchSixtyTests/QuietZoneFeedForwardClockMonitorTests.swift").read_text()
native_integration=(root/"NotchSixtyTests/QuietZoneNativeShadowTimingTransportTests.swift").read_text()
for token in ("QuietZoneFeedForwardClockMonitor", "QuietZoneClockGuardedShadowTransport",
              "QuietZoneHALClockAnalyzer().analyze(", "requireFrameMapping(",
              "requireFresh(", "shadow.stopForClockFault()",
              "excessiveDrift", "staleWitness", "clockJump",
              "physicalLatencyVerified: Bool = false",
              "liveANCQualified: Bool { false }"):
    assert token in clock,token
for token in ("testQualifiedBaselineAndFreshMatchedFramesAreOnlyDiagnostic",
              "testClockRewindAndCounterJumpPermanentlyStop",
              "testExpiredClockAndChangedRouteFailClosed",
              "testGradualClockDriftFailsMovingQualification",
              "testClockTraceCannotLegitimizeUnrelatedReferenceOrOutputFrames"):
    assert token in clock_tests,token
for token in ("testClockGuardedNativeTransportOnlyEmitsDiagnostics",
              "testUnrelatedReferenceFrameRevokesQueuedNativeMetadata",
              "testClockRouteRestartHaltsNativeBridge"):
    assert token in native_integration,token
for token in ("QuietZoneFeedForwardClockMonitor.swift in Sources",
              "QuietZoneFeedForwardClockMonitorTests.swift in Sources"):
    assert token in pbx,token
assert "func stopForClockFault()" in native_adapter
for forbidden in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
                  "requestArm(", "setEnabled(", "N60RenderKernelProcess("):
    assert forbidden not in clock,forbidden
leakage=(root/"NotchSixty/Audio/QuietZoneReferenceLeakageStability.swift").read_text()
leakage_tests=(root/"NotchSixtyTests/QuietZoneReferenceLeakageStabilityTests.swift").read_text()
for token in ("QuietZoneReferenceLeakageStabilityAnalyzer", "QuietZoneLeakageGuardedShadowSession",
              "QuietZoneReferenceLeakageCapture", "QuietZoneReferenceLeakageStabilityReport",
              "maximumConservativeLoopGain = 0.10", "errorSigmaMultiplier = 3.0",
              "oneSigmaError", "maximumRepeatDeviation",
              "candidateLeftL1Gain", "conservativeFeedbackLoopL1",
              "acousticFeedbackVerified: Bool = false",
              "echoCancellerEnabled: Bool = false",
              "outputConnected: Bool = false",
              "liveANCQualified: Bool = false"):
    assert token in leakage,token
for token in ("testRepeatedLowLeakageProvidesConservativeDiagnosticOnly",
              "testStrongSpeakerLeakageIsRejectedEvenIfCandidatePredictedLittleEcho",
              "testUncertaintyCanExceedFeedbackBoundEvenWithSmallNominalLeakage",
              "testMissingDuplicateAndWrongSpeakerRepetitionsFailClosed",
              "testStaleOrMismatchedRigNeverPasses",
              "testLowCoherenceAndNonfiniteValuesAreRejected",
              "testRepeatabilityDriftCannotBeHiddenByAveraging",
              "testFIRFilterHeadroomAndSelfReportedEchoAreNotTrusted"):
    assert token in leakage_tests,token
for token in ("QuietZoneReferenceLeakageStability.swift in Sources",
              "QuietZoneReferenceLeakageStabilityTests.swift in Sources"):
    assert token in pbx,token
for forbidden in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
                  "N60RenderKernelProcess(", "requestArm(", "setEnabled(",
                  "stageRoomTreatment("):
    assert forbidden not in leakage,forbidden
echo=(root/"NotchSixty/Audio/QuietZoneReferenceEchoSuppression.swift").read_text()
echo_tests=(root/"NotchSixtyTests/QuietZoneReferenceEchoSuppressionTests.swift").read_text()
for token in ("QuietZoneReferenceEchoModelBuilder", "QuietZoneReferenceEchoOfflineSimulator",
              "QuietZoneReferenceEchoAdaptationGuard", "QuietZoneReferenceEchoAdaptationProbe",
              "previewDecontaminatedReference", "predictedSpeakerEcho",
              "candidate: candidate, rig: rig, captures: captures",
              "maximumTotalTapAdjustment = 0.002", "minimumValidationImprovement = 0.01",
              "maximumCaptureAge", "sourceIsSilent", "independentSourceLaunchIDs",
              "automaticallyApplied: Bool = false",
              "outputConnected: Bool = false", "liveANCQualified: Bool = false"):
    assert token in echo,token
for token in ("testStereoEchoPredictionPreservesIndependentAmbientReference",
              "testBlockBoundariesPreserveImpulseHistoryAndRejectMissingFrames",
              "testWrongRouteExpiredModelAndUnalignedSpeakerFramesStop",
              "testInvalidMeasurementsAndImplausibleSubtractionFailClosed",
              "testRepeatRigAndInsufficientEchoConfidenceCannotCreateModel",
              "testHeldOutSpeakerOnlyProbeCanProposeButCannotApplyAdaptation",
              "testAdaptiveProposalRejectsDoubleTalkAndSameProbe",
              "testAdaptiveProposalMustImproveIndependentValidation",
              "testAdaptiveUpdateExceedingMeasuredUncertaintyIsRejected"):
    assert token in echo_tests,token
for token in ("QuietZoneReferenceEchoSuppression.swift in Sources",
              "QuietZoneReferenceEchoSuppressionTests.swift in Sources"):
    assert token in pbx,token
for token in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
              "N60RenderKernelProcess(", "requestArm(", "setEnabled(",
              "stageRoomTreatment(", "N60FeedForwardPreviewFIRProcessFrame("):
    assert token not in echo,token
envelope=(root/"NotchSixty/Audio/QuietZoneFeedForwardSafetyAcceptance.swift").read_text()
envelope_tests=(root/"NotchSixtyTests/QuietZoneFeedForwardSafetyAcceptanceTests.swift").read_text()
deadline_source=(root/"NotchSixty/Audio/Realtime/N60FeedForwardDeadlineBridge.c").read_text()
deadline_header=(root/"NotchSixty/Audio/Realtime/N60FeedForwardDeadlineBridge.h").read_text()
for token in ("N60_FF_SHADOW_MAX_STEREO_SUM 0.10f",
              "N60_FF_SHADOW_FADE_FRAMES 128u",
              "N60FFDeadlineFaultOutputEnvelope",
              "N60FFDeadlineBridgeAdvanceFaultFade(",
              "faultFadeFramesRemaining", "simulatedFaultFadeGain",
              "simulatedBypassReached"):
    assert token in deadline_source or token in deadline_header,token
for token in ("N60FeedForwardPreviewFIRGetSnapshot(b->fir)",
              "firState.limitedOutputFrames != 0",
              "sum > N60_FF_SHADOW_MAX_STEREO_SUM",
              "halt_bridge(b, N60FFDeadlineFaultOutputEnvelope)",
              "maximumObservedStereoSumMicro"):
    assert token in deadline_source,token
for token in ("QuietZoneFeedForwardSafetyAcceptanceEvaluator",
              "QuietZoneFeedForwardAcceptanceGate",
              "independentPhysicalReviewRequired",
              "speakerOutputConnected: Bool = false",
              "independentlyCommissioned: Bool = false",
              "liveANCQualified: Bool = false",
              "maximumCombinedStereoPeak = 0.10"):
    assert token in envelope,token
for token in ("testGoodSoftwareEvidenceStillCannotQualifyLiveOutput",
              "testCombinedStereoCoefficientBudgetRejectsIndividuallyValidFIR",
              "testFaultedShadowNeverClaimsDeadlineOrPhysicalReadiness",
              "testMissingEvidenceIsNeverImplicitlyGreen",
              "testFaultedClockAndExcessiveReportedOutputPeakBlockDiagnostic",
              "testMismatchedModelAndRigCannotCountAsEchoAcceptance"):
    assert token in envelope_tests,token
for token in ("testNativeCombinedStereoPeakTripsEvenIfEachChannelWithinCap",
              "testSafeStereoHeadroomRecordsOnlyPeakMetadata",
              "testSimulatedBypassFadeIsMonotoneAndNeverRearmsEngine",
              "testRouteFaultAlsoStartsSameHypotheticalBypass"):
    assert token in native_tests,token
assert "func advanceSimulatedFaultBypass(frames:" in native_adapter
for token in ("QuietZoneFeedForwardSafetyAcceptance.swift in Sources",
              "QuietZoneFeedForwardSafetyAcceptanceTests.swift in Sources"):
    assert token in pbx,token
for forbidden in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
                  "N60RenderKernelProcess(", "requestArm(", "setEnabled(",
                  "stageRoomTreatment("):
    assert forbidden not in envelope,forbidden
hardware_protocol=(root/"NotchSixty/Audio/QuietZoneHardwareAcceptanceProtocol.swift").read_text()
hardware_protocol_tests=(root/"NotchSixtyTests/QuietZoneHardwareAcceptanceProtocolTests.swift").read_text()
for token in ("QuietZoneHardwareAcceptanceAnalyzer",
              "QuietZonePhysicalCommissioningRunbook",
              "QuietZoneSeatAcceptanceCapture",
              "QuietZoneHardwareFaultShutdownWitness",
              "maximumMeasuredMuteSeconds = 0.100",
              "maximumResidualLevelDBFS = -60.0",
              "maximumBaselineDifferenceDB = 1.5",
              "maximumStereoSumPeak = 0.10",
              "minimumIntegratedReductionDB = 1.0",
              "acousticRegression", "unrepeatableNoise",
              "liveSpeakerConnectionAuthorized: Bool = false",
              "emergencyMuteHardwareVerified: Bool = false",
              "liveANCQualified: Bool = false"):
    assert token in hardware_protocol,token
for token in ("testNumericalBenchPassNeverClaimsRealAttenuationOrLiveOutput",
              "testOffOffPowerBaselineDoesNotAverageDbValues",
              "testMissingOrDuplicatePhysicalLaunchCannotPass",
              "testWrongTreatmentOrderOrSeatOrInstrumentFails",
              "testUnstableNoiseCoherenceOrChronologyFails",
              "testUnsafeSeatSignalOrJointStereoOutputIsRejected",
              "testSpectralGridMustMatchAndMissingBinsMustNotCrash",
              "testNoRealImprovementAndFrequencyRegressionFail",
              "testSlowMuteLoudResidualAndAutoRearmAllFail",
              "testReplayedFaultAndChangedHardwareSessionFail",
              "testRunbookIsOrderedReadOnlyAndExplicitlyHardwareBlocked"):
    assert token in hardware_protocol_tests,token
for token in ("QuietZoneHardwareAcceptanceProtocol.swift in Sources",
              "QuietZoneHardwareAcceptanceProtocolTests.swift in Sources"):
    assert token in pbx,token
for forbidden in ("AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
                  "N60RenderKernelProcess(", "requestArm(", "setEnabled(",
                  "stageRoomTreatment(", "N60FeedForwardPreviewFIRProcessFrame("):
    assert forbidden not in hardware_protocol,forbidden
assert (root/"ci/audit_pr98_disconnected_boundary.py").exists()
assert (root/"docs/PR98_SOFTWARE_CLOSURE.md").exists()
print("PR98 shadow scheduler safety guards passed")
