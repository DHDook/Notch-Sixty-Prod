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
for unsafe in ("AudioDeviceStart(", "requestArm(", "setEnabled(", "stageRoomTreatment"):
    assert unsafe not in core, unsafe
print("PR97 calibration safety guard passed")
