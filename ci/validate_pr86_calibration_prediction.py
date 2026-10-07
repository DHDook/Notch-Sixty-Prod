#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DESIGNER = ROOT / "NotchSixty/Audio/MultichannelCalibrationDesigner.swift"
CONTROLLER = ROOT / "NotchSixty/State/MultichannelCalibrationController.swift"
UI = ROOT / "NotchSixty/UI/ProductionMultichannelCalibrationWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/CalibrationPredictionVerifierTests.swift"
DOC = ROOT / "docs/PR86_CALIBRATION_VERIFICATION_PREDICTION.md"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR86 validation failed: {message}")

designer = DESIGNER.read_text()
controller = CONTROLLER.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
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

for phrase in (
    "second implementation path",
    "fail closed",
    "confidence",
    "no source may regress",
    "no seat may regress",
    "do not replace later repeat-measurement verification",
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
