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
spectral=(root/"NotchSixty/Audio/QuietZonePhysicalSpectralEvidence.swift").read_text()
for token in ("import CryptoKit", "QuietZonePhysicalSpectralEvidenceAnalyzer",
              "QuietZonePhysicalEvidencePackage", "QuietZonePhysicalFrequencyVerification",
              "maximumPrimaryBandRepeatDifferenceDB = 1.5",
              "QuietZonePhysicalVerificationCampaignAnalyzer().analyze(",
              "String(format: \"%016llx\", value.bitPattern)",
              "SHA256.hash(data: data)", "verifyDigest(",
              "instrumentEvidenceIndependentlyAuthenticated: Bool = false",
              "physicalAcousticReductionVerified: Bool = false",
              "emergencyAnalogMuteVerified: Bool = false",
              "outputConnected: Bool = false", "liveANCQualified: Bool = false"):
    assert token in spectral,token
for token in ("testFrequencyResolvedBandsRetainWeakObserverAndWorstBand",
              "testEvidenceCanonicalJSONAndDigestAreDeterministic",
              "testSameRawRecordsHaveSameManifestAcrossLaterReviewTimes",
              "testEvidenceDigestChangesIfAcousticMeasurementChanges",
              "testSpectralRepeatGateDetectsHiddenBandVariationInStableAggregate",
              "testTamperedManifestIsRejectedButCannotAuthenticateRealInstrument",
              "testEvidenceManifestEscapesInstrumentNamesWithoutFieldCollisions",
              "testSpectralCompilerRefusesEvenOneFailedRawCampaign"):
    assert token in tests,token
assert "QuietZonePhysicalSpectralEvidence.swift in Sources" in project
for forbidden in ("AudioDeviceStart(", "N60RenderKernelProcess(",
                  "N60FFDeadlineBridgeProcess(", "requestArm(",
                  "setEnabled(", "N60RealtimeAudioBridgeRender("):
    assert forbidden not in spectral,forbidden
review=(root/"NotchSixty/Audio/QuietZoneIndependentReviewPacket.swift").read_text()
for token in ("QuietZoneIndependentReviewPacketAnalyzer", "QuietZoneExternalReviewRole",
              "maximumReviewAgeSeconds", "duplicateReviewer",
              "mismatchedEvidence", "rejectEvidence" if False else "rejectedEvidence",
              "reviewerIdentityCryptographicallyVerified: Bool = false",
              "instrumentEvidenceIndependentlyAuthenticated: Bool = false",
              "liveANCQualified: Bool = false", "outputConnected: Bool = false"):
    assert token in review, token
for token in ("testTwoDistinctReviewerRolesRemainUnverifiedAndDisconnected",
              "testReviewRejectsSamePersonAndSameRoleRepeated",
              "testReviewerDigestMismatchAndRejectionBlockReview",
              "testReviewerTimeWindowAndEmptyNotesAreRejected"):
    assert token in tests, token
assert "QuietZoneIndependentReviewPacket.swift in Sources" in project
assert "F98900000000000000000001" in project
assert "F98900000000000000000011" in project
assert project.count("F98800000000000000000001 /* QuietZonePhysicalSpectralEvidence.swift") == 3
for forbidden in ("AudioDeviceStart(", "N60RenderKernelProcess(",
                  "N60FFDeadlineBridgeProcess(", "requestArm(", "setEnabled("):
    assert forbidden not in review, forbidden
print("PR99 offline physical verification campaign safety guard passed")
