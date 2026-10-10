#!/usr/bin/env python3
"""PR99 never turns third-party acoustic records into live ANC authorization."""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root/"NotchSixty/Audio/QuietZonePhysicalVerificationCampaign.swift").read_text()
tests = (root/"NotchSixtyTests/QuietZonePhysicalVerificationCampaignTests.swift").read_text()
project = (root/"NotchSixty.xcodeproj/project.pbxproj").read_text()
work = (root/".github/workflows/pr99-physical-anc-verification.yml").read_text()
for token in (
    "QuietZonePhysicalVerificationCampaignAnalyzer",
    "QuietZonePhysicalVerificationVisit",
    "QuietZoneHardwareAcceptanceAnalyzer().analyze(",
    "QuietZonePhysicalVerificationPosition.allCases",
    "changedNoiseBaseline", "unstableAttenuation",
    "duplicatedEvidence", "mismatchedFrequencyBands",
    "minimumReturnBaselineDifferenceDB" if False else
        "maximumReturnBaselineDifferenceDB = 1.5",
    "maximumPrimaryImprovementDifferenceDB = 1.5",
    "instrumentEvidenceIndependentlyAuthenticated: Bool = false",
    "physicalAcousticReductionVerified: Bool = false",
    "emergencyAnalogMuteVerified: Bool = false",
    "liveANCQualified: Bool = false", "outputConnected: Bool = false",
):
    assert token in source,token
for token in (
    "testThreeIndependentVisitsProduceProvisionalRepeatabilityReview",
    "testMissingReorderedOrRepeatedSessionRejected",
    "testDuplicateSourceLaunchAcrossIndependentVisitsIsNotPermitted",
    "testMovedReturnSeatAndUnexpectedRigCannotBeCounted",
    "testDifferentCalibrationMeterAndExternalSourceFailAcrossVisits",
    "testIndependentVisitFrequencyGridMustMatch",
    "testReturningToSeatRevealsDriftingNoiseBaseline",
    "testPrimaryAcousticGainMustRemainStableAfterMicMovedAwayAndBack",
    "testObserverPositionWithNoCancellationIsNotSilentlyIgnored",
    "testStaleOrOverlappingCampaignIsRejected",
):
    assert token in tests,token
for token in (
    "QuietZonePhysicalVerificationCampaign.swift in Sources",
    "QuietZonePhysicalVerificationCampaignTests.swift in Sources",
):
    assert token in project,token
assert "-only-testing:NotchSixtyTests/QuietZonePhysicalVerificationCampaignTests" in work
for forbidden in (
    "AudioDeviceStart(", "AudioDeviceCreateIOProcID(",
    "N60RenderKernelProcess(", "N60RealtimeAudioBridgeRender(",
    "N60FFDeadlineBridgeProcess(", "N60FFDeadlineBridgeAdvanceFaultFade(",
    "requestArm(", "setEnabled(", "stageRoomTreatment(",
):
    assert forbidden not in source,forbidden
assert (root/"docs/PR99_PHYSICAL_ANC_VERIFICATION.md").exists()
print("PR99 offline physical verification campaign safety guard passed")
