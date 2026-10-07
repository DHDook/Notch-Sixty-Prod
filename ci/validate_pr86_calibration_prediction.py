#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGNER = ROOT / "NotchSixty/Audio/MultichannelCalibrationDesigner.swift"
CONTROLLER = ROOT / "NotchSixty/State/MultichannelCalibrationController.swift"
UI = ROOT / "NotchSixty/UI/ProductionMultichannelCalibrationWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/CalibrationPredictionVerifierTests.swift"
ROOM_FIR = ROOT / "NotchSixty/Audio/RoomCorrectionFIRDesigner.swift"
ROOM_CONTROLLER = ROOT / "NotchSixty/State/RoomCorrectionProjectController.swift"
ROOM_UI = ROOT / "NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift"
ROOM_TESTS = ROOT / "NotchSixtyTests/RoomCorrectionFIRDesignerTests.swift"
ROOM_CONTROLLER_TESTS = ROOT / "NotchSixtyTests/RoomCorrectionProjectControllerTests.swift"
DOC = ROOT / "docs/PR86_CALIBRATION_VERIFICATION_PREDICTION.md"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR86 validation failed: {message}")

designer = DESIGNER.read_text()
controller = CONTROLLER.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
room_fir = ROOM_FIR.read_text()
room_controller = ROOM_CONTROLLER.read_text()
room_ui = ROOM_UI.read_text()
room_tests = ROOM_TESTS.read_text()
room_controller_tests = ROOM_CONTROLLER_TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "struct MultichannelCalibrationPredictionVerifier",
    "struct CalibrationPredictionReport",
    "CalibrationPredictionSourceReport",
    "CalibrationPredictionSeatReport",
    "minimumConfidence = 0.70",
    "minimumMeaningfulImprovementDB = 0.25",
    "maximumSourceRegressionDB = 0.25",
    "maximumSeatRegressionDB = 0.75",
    "evaluateSummedSubwoofers",
    "peakingResponse",
    "designer/verifier trends disagree",
):
    require(token in designer, f"prediction engine missing {token}")

for token in (
    "@Published private(set) var latestPrediction",
    "predictionVerifier.verify",
    "guard let prediction = latestPrediction",
    "guard prediction.accepted",
    "predictionRejected",
):
    require(token in controller, f"deployment gate missing {token}")

require(
    controller.count("latestPrediction = nil") >= 5,
    "prediction evidence is not invalidated with campaign mutations",
)

for token in (
    "Prediction Verified",
    "Prediction Blocked",
    "Independent RMS Before",
    "Independent RMS After",
    "Summed Subs",
    "calibration.latestPrediction?.accepted != true",
):
    require(token in ui, f"review UI missing {token}")

for token in (
    "testIndependentPredictionAcceptsUsefulCorrection",
    "testLowConfidenceCaptureFailsClosed",
    "testIndependentPredictionRejectsDesignerRegression",
    "testCoherentSubPredictionCatchesDelayInducedCancellation",
    "testSpeakerDelayPredictionTracksArrivalAlignment",
):
    require(token in tests, f"prediction regression coverage missing {token}")

for token in (
    "struct RoomCorrectionDesignPredictionVerifier",
    "RoomCorrectionDesignVerificationReport",
    "firMagnitudeDB",
    "maximumOutOfBandDeviationDB",
    "storedPredictionDisagreement",
    "maximumDeploymentFilterGainDB",
):
    require(token in room_fir, f"room prediction verifier missing {token}")

for token in (
    "@Published private(set) var selectedDesignVerification",
    "designVerifier.verify",
    "func deploySelectedDesign()",
    "guard report.accepted",
    "designVerificationRejected",
):
    require(token in room_controller, f"room deployment gate missing {token}")

for token in (
    "Prediction Verified",
    "Prediction Blocked",
    "FIR Peak",
    "Out-of-band",
    "projects.deploySelectedDesign()",
    "projects.selectedDesignVerification?.accepted != true",
):
    require(token in room_ui, f"room review UI missing {token}")

for token in (
    "testIndependentRoomDesignVerificationAcceptsActualDeploymentFIR",
    "testRoomDesignVerificationFailsClosedOnLowConfidenceCapture",
    "testRoomDesignVerificationRejectsInsufficientHeadroom",
    "testRoomDesignVerificationRejectsTamperedStoredPrediction",
):
    require(token in room_tests, f"room FIR prediction coverage missing {token}")

require(
    "testRoomCorrectionDeploymentIsBlockedByFreshPredictionGate"
    in room_controller_tests,
    "room controller fail-closed deployment test missing",
)

for phrase in (
    "second implementation path",
    "fail closed",
    "confidence",
    "no source may regress",
    "no seat may regress",
    "do not replace later repeat-measurement verification",
    "exact fir taps",
    "fresh accepted verification report",
):
    require(phrase in doc, f"PR86 contract missing '{phrase}'")

# Explicit realtime boundary: no PR86 prediction symbol may enter C realtime code.
for realtime_file in (ROOT / "NotchSixty/Audio/Realtime").glob("*.[ch]"):
    text = realtime_file.read_text(errors="ignore")
    require(
        "CalibrationPrediction" not in text
        and "MultichannelCalibrationPredictionVerifier" not in text,
        f"prediction leaked into realtime file {realtime_file.name}",
    )

print("PR86 calibration verification/prediction validation passed")
