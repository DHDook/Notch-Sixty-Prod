#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "NotchSixty/Audio/ActiveQuietZoneFeasibility.swift"
TESTS = ROOT / "NotchSixtyTests/ActiveQuietZoneFeasibilityTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR77_ACTIVE_QUIET_ZONE_FEASIBILITY.md"
AUDIO_ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
LIVE_CORE = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"

def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR77 validation failed: {message}")

source = SOURCE.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
audio_engine = AUDIO_ENGINE.read_text()
live_core = LIVE_CORE.read_text()

for token in (
    "struct ActiveQuietZoneFeasibilityAnalyzer",
    "referenceLeadFrames",
    "referenceToActuatorProcessingLatencyFrames",
    "commandToErrorArrivalFrames",
    "causalitySafetyMarginFrames",
    "minimumMagnitudeSquaredCoherence = 0.80",
    "minimumActuatorHeadroomDB = 6.0",
    "quietZoneRadiusMeters = 0.45",
    "maximumTimingPhaseUncertaintyDegrees = 20.0",
    "timingUncertaintyMaximumHz",
    "coherenceBandResult",
    "spatialQuarterWavelengthMaximumHz",
    "recommendedMaximumHz",
    "ActiveQuietZoneFeasibilityStatus",
):
    require(token in source, f"feasibility planner missing {token}")

require(
    "reference.referenceLeadFrames - requiredFrames" in source,
    "causality margin does not explicitly subtract required control path delay",
)
require(
    "configuration.speedOfSoundMetersPerSecond" in source
    and "/ (4.0 * configuration.quietZoneRadiusMeters)" in source,
    "quarter-wavelength planning bound is missing",
)
require(
    "maximumPhaseDegrees / 360.0 / jitterSeconds" in source,
    "timing phase-uncertainty bound is missing",
)

for forbidden in (
    "AudioDeviceStart",
    "AudioDeviceCreateIOProcID",
    "N60OutputIOProc",
    "N60LiveNChannelOutputIOProc",
    "N60MIMOFIRRuntimeProcessFrame",
    "N60MIMOTreatmentTransitionProcessFrame",
    "FxLMS",
    "filteredX",
):
    require(
        forbidden not in source,
        f"passive PR77 planner unexpectedly references live/adaptive primitive {forbidden}",
    )

require(
    "ActiveQuietZoneFeasibility" not in audio_engine,
    "AudioIOEngine unexpectedly owns PR77 feasibility planning",
)
require(
    "ActiveQuietZoneFeasibility" not in live_core,
    "live N-channel core unexpectedly owns PR77 feasibility planning",
)

require(
    "ActiveQuietZoneFeasibility.swift in Sources" in project,
    "PR77 source missing from app target",
)
require(
    "ActiveQuietZoneFeasibilityTests.swift in Sources" in project,
    "PR77 tests missing from test target",
)

for token in (
    "testStrongReferenceLeadSupportsFullConservativeBand",
    "testInsufficientReferenceLeadIsCausallyInfeasible",
    "testLargeQuietZoneNarrowsBandByQuarterWavelength",
    "testTimingJitterCanNarrowOtherwiseCausalBand",
    "testCoherenceRolloffProducesMeasuredBandCeiling",
    "testEveryErrorMicrophoneRequiresQualifiedCoverage",
    "testBestReferenceActuatorPairIsSelectedPerErrorMicrophone",
    "testInvalidCoherenceDataFailsClosed",
):
    require(token in tests, f"PR77 XCTest acceptance missing {token}")

normalized = doc.lower().replace(chr(96), "")
for phrase in (
    "does not generate anti-noise",
    "causality margin",
    "magnitude-squared coherence",
    "quarter-wavelength",
    "20–150 hz",
    "does not reuse pr74's high-latency room-treatment fir path",
    "strictly offline filtered-x adaptive-control simulator",
):
    require(phrase in normalized, f"architecture document missing '{phrase}'")

require(
    (ROOT / "ci/validate_pr76_treatment_transition.py").exists(),
    "inherited PR76 isolation guard is missing",
)

print("PR77 Active Quiet Zone feasibility structural validation passed")
