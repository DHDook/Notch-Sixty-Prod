#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
HEADER = REALTIME / "N60MIMORoomTreatment.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"
SWIFT = ROOT / "NotchSixty/Audio/MIMORoomTreatmentDesigner.swift"
TESTS = ROOT / "NotchSixtyTests/MIMORoomTreatmentDesignerTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR73_MIMO_ACTIVE_ROOM_TREATMENT.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR73 validation failed: {message}")


header = HEADER.read_text()
bridge = BRIDGE.read_text()
swift = SWIFT.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "N60MIMORoomTreatmentSettings",
    "N60MIMORoomTreatmentDesignSpatialEqualization",
    "N60MIMODesignRegularizedCorrection",
    "targetHeadroomDB",
    "maximumAggregateSourceGainDB",
    "maximumPerSourcePowerGainDB",
    "maximumRobustnessDegradationDB",
    "robustnessMagnitudeFraction",
    "robustnessPhaseDegrees",
    "minimumColumnSafetyScale",
    "N60MIMORoomTreatmentSetIdentityAtFrequency",
    "N60MIMORoomTreatmentApplyPerSourcePowerBound",
):
    require(token in header, f"room-treatment core missing {token}")

require(".targetHeadroomDB = 0.0" in header,
        "default policy must not manufacture improvement through attenuation")
require(".maximumCoefficientGainDB = 0.0" in header,
        "default coefficient gain must remain unity-bounded")
require(".maximumAggregateSourceGainDB = 0.0" in header,
        "default column power must remain unity-bounded")
require(".maximumPerSourcePowerGainDB = 0.0" in header,
        "default physical-source effort must remain unity-bounded")
require("free(desired)" in header and "calloc(" in header,
        "large control-plane MIMO workspace must use explicit heap lifecycle")
require('#import "N60MIMORoomTreatment.h"' in bridge,
        "room-treatment API is not exposed to Swift")

for token in (
    "struct MIMORoomTreatmentDesigner",
    "MultichannelCalibrationMeasurement",
    "simulationOnly",
    "N60MIMORoomTreatmentTransferSetCreate",
    "N60MIMORoomTreatmentDesignCreate",
    "N60MIMORoomTreatmentDesignReport",
    "N60MIMORoomTreatmentDesignCoefficient",
    "maximumPerSourcePower",
):
    require(token in swift, f"product-facing designer missing {token}")

require("func applying(" not in swift and "func apply(" not in swift,
        "PR73 must not expose a live deployment/apply API")
for forbidden in (
    "AudioDeviceStart",
    "AudioDeviceCreateIOProcID",
    "N60LiveNChannelOutputIOProc",
    "N60OutputIOProc",
    "N60RenderKernelPublishSnapshot",
):
    require(forbidden not in swift and forbidden not in header,
            f"simulation-only PR73 unexpectedly references live actuator path {forbidden}")

require("configuration.maximumFrequencyHz <= N60_MIMO_ROOM_TREATMENT_DEFAULT_MAX_HZ" in swift,
        "product-facing designer must remain bounded to 150 Hz")
require("MIMORoomTreatmentDesigner.swift in Sources" in project,
        "room-treatment designer is missing from app target")
require("MIMORoomTreatmentDesignerTests.swift in Sources" in project,
        "room-treatment tests are missing from test target")

for token in (
    "testMeasuredTwoSourceTwoSeatDesignProducesBoundedSimulationPlan",
    "testSpatiallyUniformFieldProducesNoTreatmentAndExactIdentity",
    "testMissingSourceSeatMeasurementFailsClosed",
    "testMissingPhaseDataFailsClosed",
    "testDuplicateActuatorSourceIsRejected",
):
    require(token in tests, f"Swift acceptance is missing {token}")

for phrase in (
    "20–150 hz",
    "simulation-only",
    "exact identity",
    "regularization",
    "per-source effort",
    "robustness",
    "excursion/thermal proxy",
    "no apply/deploy method",
    "active quiet zone",
    "hardware acceptance",
):
    require(phrase.lower() in doc.lower(), f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr59_advanced_spatial.py").exists(),
        "inherited PR59 MIMO validation is missing")
require((ROOT / "ci/validate_pr72_ambient_analysis.py").exists(),
        "inherited PR72 ambient-analysis validation is missing")

print("PR73 MIMO active-room-treatment structural validation passed")
