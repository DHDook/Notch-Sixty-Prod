#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h"
SOURCE = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
STEREO = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
NCHANNEL = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
METERS = ROOT / "NotchSixty/UI/ProductionMetersView.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR70_STEREO_ADAPTIVE_SRC_ACTIVATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR70 validation failed: {message}")


def function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    require(start >= 0, f"missing function {signature}")
    brace = text.find("{", start)
    require(brace >= 0, f"missing body for {signature}")
    depth = 0
    for index in range(brace, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
    raise SystemExit(f"PR70 validation failed: unterminated function {signature}")


header = HEADER.read_text()
source = SOURCE.read_text()
stereo = STEREO.read_text()
nchannel = NCHANNEL.read_text()
meters = METERS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "N60RealtimeAudioBridgeConfigureAdaptiveSampleRate",
    "adaptiveSampleRateEnabled",
    "N60AdaptiveSRCSnapshot adaptiveSampleRate",
):
    require(token in header, f"bridge contract missing {token}")

require("N60AdaptiveSRCCreate" in source, "bridge never prepares PR69 adaptive SRC")
require("N60AdaptiveSRCPushInterleaved" in function_body(source, "N60CaptureIOProc("),
        "capture callback does not feed adaptive SRC")
output_body = function_body(source, "N60OutputIOProc(")
require("N60AdaptiveSRCPullInterleaved" in output_body,
        "output callback does not consume adaptive SRC")
require("framesToRead < frameCount" in output_body
        and "outputGateOpen, false" in output_body
        and "N60AdaptiveSRCRelockConsumer" in output_body,
        "adaptive starvation does not relock, fail closed, and re-prime")
require("adaptiveCaptureScratch" in source and "adaptiveOutputScratch" in source,
        "preallocated callback scratch buffers missing")

for signature in ("N60CaptureIOProc(", "N60OutputIOProc("):
    body = function_body(source, signature)
    for forbidden in (
        "malloc(", "calloc(", "realloc(", "free(", "printf(", "fprintf(",
        "pthread_mutex", "dispatch_sync", "os_log", "NSLog",
    ):
        require(forbidden not in body, f"{signature} contains realtime-forbidden operation {forbidden}")

require("adaptiveSampleRateRequired" in stereo, "stereo session does not detect native-rate mismatch")
require("N60RealtimeAudioBridgeConfigureAdaptiveSampleRate" in stereo,
        "stereo session does not activate bridge ASRC")
require("tapFormat.sampleRate : outputFormat.sampleRate" in stereo,
        "capture aggregate does not preserve tap-native clock when ASRC is active")
require("aggregateDeviceOutputPlan != nil" in stereo and "sampleRateMismatch" in stereo,
        "legacy aggregate-clock stereo path must remain fail-closed on mismatch")
require("adaptiveSampleRateEnabled" in meters and "Adaptive SRC" in meters,
        "Transport diagnostics do not expose adaptive SRC state")
require("N60AdaptiveSampleRate.c in Sources" in project,
        "adaptive SRC implementation is not linked into the app target")

# PR71 owns semantic N-channel activation. PR70 must not silently widen scope.
require("sampleRateMismatch" in nchannel, "semantic N-channel mismatch guard disappeared")
require("N60AdaptiveSampleRate" not in nchannel, "semantic N-channel ASRC activation belongs in PR71")
require("N60RealtimeAudioBridgeConfigureAdaptiveSampleRate" not in nchannel,
        "semantic N-channel bridge activation belongs in PR71")

for phrase in (
    "stereo",
    "adaptive",
    "startup",
    "relock",
    "44.1",
    "48",
    "drift",
    "manual validation",
    "PR71",
):
    require(phrase.lower() in doc.lower(), f"architecture document missing '{phrase}'")

print("PR70 stereo adaptive-SRC structural validation passed")
