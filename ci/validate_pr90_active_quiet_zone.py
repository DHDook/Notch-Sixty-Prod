#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CORE = ROOT / "NotchSixty/Audio/ActiveQuietZone.swift"
RT_H = ROOT / "NotchSixty/Audio/Realtime/N60ActiveQuietZone.h"
RT_C = ROOT / "NotchSixty/Audio/Realtime/N60ActiveQuietZone.c"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
KERNEL_H = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h"
KERNEL_C = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
TESTS = ROOT / "NotchSixtyTests/ActiveQuietZoneTests.swift"
DOC = ROOT / "docs/PR90_ACTIVE_QUIET_ZONE.md"

def require(condition, message):
    if not condition:
        raise SystemExit(f"PR90 validation failed: {message}")

core = CORE.read_text()
rt_h = RT_H.read_text()
rt_c = RT_C.read_text()
engine = ENGINE.read_text()
kernel_h = KERNEL_H.read_text()
kernel_c = KERNEL_C.read_text()
tests = TESTS.read_text()
doc = DOC.read_text().lower()

for token in (
    "hardMaximumFrequencyHz = 150.0",
    "minimumSeparationConfidence = 0.85",
    "minimumStationarity = 0.80",
    "requiredStableWindows = 4",
    "maximumPerSourceTonePeakDBFS = -24.0",
    "maximumAggregateSourcePeakDBFS = -18.0",
    "minimumProbeImprovementDB = 1.0",
    "maximumAllowedRegressionDB = 1.0",
    "struct ActiveQuietZonePlanner",
    "func secondaryPath(",
    "func tonePhasor(",
    "func solveStereo(",
    "func availableInjectionPeak(",
    "func verify(",
    "struct ActiveQuietZoneTonePersistenceTracker",
):
    require(token in core, f"core ANC model missing {token}")

for token in (
    "N60_ACTIVE_QUIET_ZONE_MAX_TONES",
    "N60ActiveQuietZoneToneSnapshot",
    "N60ActiveQuietZoneSnapshot",
    "N60ActiveQuietZoneRuntime",
    "N60ActiveQuietZoneRuntimeSchedule",
    "N60ActiveQuietZoneRuntimeProcessFrame",
):
    require(token in rt_h + rt_c, f"realtime ANC runtime missing {token}")

for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fft", "mutex", "lock("):
    process = rt_c.split("N60ActiveQuietZoneRuntimeProcessFrame", 1)[1]
    require(forbidden.lower() not in process.lower(), f"realtime ANC process contains {forbidden}")

for token in (
    "activeQuietZoneRuntimeTarget",
    "activeQuietZoneStereoSpeakerRuntimeAvailable",
    "activeQuietZoneAvailableInjectionPeak",
    "replaceActiveQuietZoneRuntimeTarget",
    "frequencyChangeRequiresDisarm",
    "activeQuietZoneTargetAfterHeadroomChange",
    "attachActiveQuietZone(to: &graph)",
):
    require(token in engine, f"engine ANC integration missing {token}")

for token in (
    "N60DSPGraphSnapshotSetActiveQuietZone",
    "activeQuietZone",
):
    require(token in kernel_h + kernel_c, f"render graph ANC integration missing {token}")

quiet_pos = kernel_c.find("N60ActiveQuietZoneRuntimeProcessFrame")
dyn_pos = kernel_c.find("N60DynamicsProcessCoreStereoFrameWithMasterGain")
require(quiet_pos >= 0 and dyn_pos > quiet_pos, "anti-noise is not upstream of dynamics/protection")

for token in (
    "testConfigurationRejectsBroadbandOrUnsafeLimits",
    "testEligibilityRequiresTrustedStationaryProminentLowFrequencyTone",
    "testStereoSolveCancelsModeledDisturbanceWithinBounds",
    "testVerificationAcceptsImprovementAndFaultsRegression",
    "testTonePersistenceRequiresStableWindows",
    "testRealtimeRuntimeRejectsFrequencyChangeUntilDisarmed",
    "testRenderGraphRejectsQuietZoneToneBeyondHardFrequencyBand",
):
    require(token in tests, f"ANC tests missing {token}")

for phrase in (
    "25–150 hz",
    "closed-loop",
    "error microphone",
    "maximum 4 simultaneous tones",
    "upstream of dynamics/protection",
    "no claim of whole-room silence",
    "no speech cancellation",
):
    require(phrase in doc, f"PR90 contract missing '{phrase}'")

print("PR90 Active Quiet Zone architecture validation passed")
