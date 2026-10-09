#!/usr/bin/env python3
from pathlib import Path
root=Path(__file__).resolve().parents[1]
core=(root/"NotchSixty/Audio/QuietZoneHardwareCalibration.swift").read_text()
tests=(root/"NotchSixtyTests/QuietZoneHardwareCalibrationTests.swift").read_text()
pbx=(root/"NotchSixty.xcodeproj/project.pbxproj").read_text()
ui=(root/"NotchSixty/UI/ProductionFeedForwardReadinessCard.swift").read_text()
for item in ("QuietZoneHardwareCalibrationSession", "QuietZoneHALClockAnalyzer",
             "QuietZoneBenchLoopbackAnalyzer", "QuietZoneFeedForwardSurveySession",
             "maximumSessionSeconds", "liveANCQualified: Bool = false",
             "outputConnected: Bool = false"):
    assert item in core,item
for item in ("testProgressionAndFailClosedReceipt",
             "testClockMismatchAndOutOfOrderCaptureAreRejected",
             "testReplayedCapturesAndExpiredSessionAreRejected",
             "testListenerDriftInvalidatesEntireAcousticSurvey"):
    assert item in tests,item
for item in ("QuietZoneHardwareCalibration.swift in Sources",
             "QuietZoneHardwareCalibrationTests.swift in Sources"):
    assert item in pbx,item
assert "PR97 · HARDWARE SETUP" in ui
capture=(root/"NotchSixty/Audio/QuietZoneHardwareClockCapture.swift").read_text()
capture_tests=(root/"NotchSixtyTests/QuietZoneHardwareClockCaptureTests.swift").read_text()
for item in ("QuietZoneHardwareHALClockAcquisition", "AudioConvertHostTimeToNanos",
             "N60FeedForwardOutputTimingSnapshot", "QuietZoneHALClockAnalyzer",
             "liveANCQualified: Bool = false", "reference.read(maximumFrames:"):
    assert item in capture,item
for item in ("testSyntheticConcurrentStableTracesAreBenchOnly",
             "testNonOverlappingSnapshotsNeverQualify",
             "testReplayedTimestampsAndDiscontinuityFailClosed",
             "testIndependentClockDriftIsRejected"):
    assert item in capture_tests,item
engine=(root/"NotchSixty/Audio/AudioIOEngine.swift").read_text()
transport=(root/"NotchSixty/Audio/CoreAudio/CoreAudioError.swift").read_text()
for item in ("makeHardwareClockAcquisition(", "hardwareClockAcquisitionRoute()",
             "self.transportSession === session", "passiveFeedForwardOutputTimingSnapshot"):
    assert item in engine,item
for item in ("calibrationTimingRouteLeaseID = UUID().uuidString",
             "func passiveFeedForwardOutputTimingSnapshot()",
             "aggregateDeviceOutputPlan == nil", "isOutputStarted"):
    assert item in transport,item
assert "addInstrumentedSourceCapture(" in core
assert "usedPhysicalLaunchIDs.contains(launch.launchID)" in core
assert "testInstrumentedCaptureRejectsReplayedLaunchAndSwappedSource" in tests
assert "testLiveRouteLeaseInvalidatesRestartDeviceAndSampleRate" in capture_tests
probe=(root/"NotchSixty/Audio/QuietZoneInstrumentedProbeCapture.swift").read_text()
probe_tests=(root/"NotchSixtyTests/QuietZoneInstrumentedProbeCaptureTests.swift").read_text()
for token in ("QuietZoneInstrumentedSourceLaunch", "physicalClockCalibrationVerified",
              "AudioConvertHostTimeToNanos", "QuietZoneInstrumentedProbeAcquisition",
              "missingPreRoll", "discontinuousInput", "reference.read(maximumFrames:"):
    assert token in probe,token
for token in ("testMeasuredSourceCaptureBuildsRealProbePayload",
              "testRejectsMissingOrUncalibratedSourceWitness",
              "testNoPreRollOrLateTriggerFailsClosed",
              "testDroppedSampleAndClippingAreRejected"):
    assert token in probe_tests,token
for token in ("QuietZoneInstrumentedProbeCapture.swift in Sources",
              "QuietZoneInstrumentedProbeCaptureTests.swift in Sources"):
    assert token in pbx,token
for unsafe in ("AudioDeviceStart(", "requestArm(", "setEnabled(", "stageRoomTreatment"):
    assert unsafe not in probe,unsafe
for item in ("QuietZoneHardwareClockCapture.swift in Sources",
             "QuietZoneHardwareClockCaptureTests.swift in Sources"):
    assert item in pbx,item
for forbidden in ("requestArm(", "setEnabled(", "stageRoomTreatment"):
    assert forbidden not in capture,forbidden
for unsafe in ("AudioDeviceStart(", "requestArm(", "setEnabled(", "stageRoomTreatment"):
    assert unsafe not in core, unsafe
print("PR97 calibration safety guard passed")
