#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ANALYZER = ROOT / "NotchSixty/Audio/AmbientFieldAnalyzer.swift"
TESTS = ROOT / "NotchSixtyTests/AmbientFieldAnalyzerTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR72_AMBIENT_ANALYSIS_FOUNDATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR72 validation failed: {message}")


analyzer = ANALYZER.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "struct AmbientFieldAnalyzer",
    "AmbientPlaybackSourceReference",
    "AmbientAnalysisSnapshot",
    "modeledPlaybackSubtraction",
    "playbackModelUnavailable",
    "separationConfidence",
    "stationarityScore",
    "periodicityScore",
    "lowFrequencyEnergyFraction",
    "cancellationCandidateScore",
    "makeTonalComponents",
    "predictPlayback",
    "vDSP_DFT_Execute",
):
    require(token in analyzer, f"ambient analyzer missing {token}")

require("playbackSources: [AmbientPlaybackSourceReference]" in analyzer,
        "ambient estimator is not semantic/multichannel ready")
require("audibleSources.contains(where: { $0.acousticImpulseResponse == nil })" in analyzer,
        "audible unmodeled playback must fail confidence closed")
require("separationMode = .playbackModelUnavailable" in analyzer,
        "missing-model fail-closed mode not assigned")
require("confidence = 0.15" in analyzer,
        "missing-model confidence cap is missing")

# PR72 must remain passive. These are deliberately broad actuator/realtime guards.
for forbidden in (
    "AudioDeviceCreateIOProcID",
    "AudioDeviceStart(",
    "AudioDeviceStop(",
    "N60LiveNChannelOutputIOProc",
    "N60OutputIOProc",
    "N60RenderKernelPublishSnapshot",
    "N60AdaptiveSRC",
    "filtered-x",
    "FxLMS",
):
    require(forbidden not in analyzer,
            f"passive analyzer unexpectedly references live/actuating primitive {forbidden}")

require("AmbientFieldAnalyzer.swift in Sources" in project,
        "ambient analyzer is not in the app target")
require("AmbientFieldAnalyzerTests.swift in Sources" in project,
        "ambient analyzer tests are not in the test target")

for token in (
    "testMicrophoneOnlyStableToneIsDetectedAsPeriodicAmbientNoise",
    "testKnownPlaybackPredictionRecoversIndependentAmbientTone",
    "testSemanticPlaybackSourcesSumInTheAcousticDomain",
    "testOneAudibleUnmodeledSemanticSourceFailsSeparationClosed",
    "testStationarityDistinguishesSteadyFromBurstingNoise",
    "testCancellationCandidateScorePrefersStableLowFrequencyEnergy",
):
    require(token in tests, f"synthetic acceptance missing {token}")

for phrase in (
    "passive",
    "generate anti-noise",
    "semantic",
    "multichannel",
    "confidence",
    "stationarity",
    "periodicity",
    "250 hz",
    "active quiet zone",
    "filtered-x",
    "hardware acceptance",
):
    require(phrase.lower() in doc.lower(), f"architecture document missing '{phrase}'")

# Inheritance gates: the previous adaptive-clock activation stack must still exist.
require((ROOT / "ci/validate_pr71_nchannel_adaptive_src.py").exists(),
        "PR71 inherited validation is missing")
require((ROOT / "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c").exists(),
        "PR69-71 adaptive SRC primitive disappeared")

print("PR72 passive ambient-analysis structural validation passed")
