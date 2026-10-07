#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / "NotchSixty/Audio/RoomCorrectionTargetDesigner.swift"
ROOM_CONTROLLER = ROOT / "NotchSixty/State/RoomCorrectionProjectController.swift"
ROOM_UI = ROOT / "NotchSixty/UI/ProductionRoomCorrectionWorkspace.swift"
MULTI_CONTROLLER = ROOT / "NotchSixty/State/MultichannelCalibrationController.swift"
MULTI_UI = ROOT / "NotchSixty/UI/ProductionMultichannelCalibrationWorkspace.swift"
TARGET_TESTS = ROOT / "NotchSixtyTests/RoomCorrectionTargetDesignerTests.swift"
ROOM_CONTROLLER_TESTS = ROOT / "NotchSixtyTests/RoomCorrectionProjectControllerTests.swift"
DOC = ROOT / "docs/PR88_INTELLIGENT_TARGET_GENERATION.md"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR88 validation failed: {message}")

target = TARGET.read_text()
room_controller = ROOM_CONTROLLER.read_text()
room_ui = ROOM_UI.read_text()
multi_controller = MULTI_CONTROLLER.read_text()
multi_ui = MULTI_UI.read_text()
target_tests = TARGET_TESTS.read_text()
room_controller_tests = ROOM_CONTROLLER_TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "enum IntelligentTargetPreference",
    "case neutral",
    "case warm",
    "case studio",
    "struct IntelligentTargetGenerationReport",
    "struct IntelligentRoomTargetGenerator",
    "analysisSmoothingOctaves = 2.0 / 3.0",
    "maximumBassShelfDB = 4.0",
    "minimumTrebleAt20KDB = -4.0",
    "maximumTrebleAt20KDB = -1.0",
    "referenceBandLowHz = 300.0",
    "referenceBandHighHz = 2_000.0",
    "meanSpatialDeviation",
    "measurementConfidence",
    "estimateBassExtension",
    "robustBandLevel",
    "clampDecisions",
    "fallbackUsed",
):
    require(token in target, f"target generator missing {token}")

for token in (
    "func generateIntelligentTarget(",
    "IntelligentRoomTargetGenerator().generate",
    "lastGeneratedTargetReport",
    "lastGeneratedTargetReport = nil",
):
    require(token in room_controller, f"room integration missing {token}")

for token in (
    'GroupBox("Adaptive Target")',
    "Generate from Measurements",
    "Bass Extension",
    "Spatial Variation",
    "lastGeneratedTargetReport",
):
    require(token in room_ui, f"room UI missing {token}")

for token in (
    "@Published private(set) var intelligentTargetReport",
    "func generateIntelligentTarget(",
    "IntelligentRoomTargetGenerator().generate",
    "let resolvedTarget = target ?? intelligentTargetReport?.target",
    "intelligentTargetReport = nil",
):
    require(token in multi_controller, f"multichannel integration missing {token}")

# A successful generation must not immediately erase itself.
generated_block = multi_controller.split(
    "func generateIntelligentTarget(", 1
)[1].split("func clearIntelligentTarget()", 1)[0]
require(
    "intelligentTargetReport = report" in generated_block,
    "multichannel target report is not retained",
)
after_assignment = generated_block.split("intelligentTargetReport = report", 1)[1]
require(
    "intelligentTargetReport = nil" not in after_assignment,
    "multichannel target report is immediately invalidated after generation",
)

for token in (
    'GroupBox("Adaptive Target")',
    "Generate from Campaign",
    "Use Flat",
    "intelligentTargetReport",
    "PR86",
):
    require(token in multi_ui, f"multichannel UI missing {token}")

for token in (
    "testIntelligentTargetsAreDeterministicBoundedAndPreferenceOrdered",
    "testIntelligentTargetLowConfidenceFallsBackConservatively",
    "testIntelligentTargetSpatialVarianceReducesAggressiveness",
    "testIntelligentTargetDoesNotTraceNarrowRoomNull",
    "testIntelligentTargetClampsToConfiguredCorrectionLimits",
):
    require(token in target_tests, f"adaptive target tests missing {token}")

require(
    "testIntelligentTargetGenerationPersistsAndManualTargetInvalidatesReport"
    in room_controller_tests,
    "room controller target persistence/invalidation test missing",
)

for phrase in (
    "do not fit narrow room structure",
    "do not ask for impossible bass",
    "do not force flat in-room treble",
    "respect spatial disagreement",
    "respect correction limits",
    "remain control-plane only",
    "pr86",
):
    require(phrase in doc, f"PR88 contract missing '{phrase}'")

# No generator/report type can enter C realtime code.
for realtime_file in (ROOT / "NotchSixty/Audio/Realtime").glob("*.[ch]"):
    text = realtime_file.read_text(errors="ignore")
    require(
        "IntelligentRoomTargetGenerator" not in text
        and "IntelligentTargetGenerationReport" not in text,
        f"adaptive target generation leaked into realtime file {realtime_file.name}",
    )

print("PR88 intelligent target generation validation passed")
