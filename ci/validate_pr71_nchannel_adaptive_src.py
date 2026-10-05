#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelBridge.h"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
STEREO = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
ASRC = ROOT / "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c"
DOC = ROOT / "docs/PR71_NCHANNEL_ADAPTIVE_SRC_ACTIVATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR71 validation failed: {message}")


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
    raise SystemExit(f"PR71 validation failed: unterminated function {signature}")


bridge = BRIDGE.read_text()
session = SESSION.read_text()
stereo = STEREO.read_text()
engine = ENGINE.read_text()
asrc = ASRC.read_text()
doc = DOC.read_text()

for token in (
    '#include "N60AdaptiveSampleRate.h"',
    "N60LiveNChannelBridgeConfigureAdaptiveSampleRate",
    "adaptiveSampleRateEnabled",
    "N60AdaptiveSRCSnapshot adaptiveSampleRate",
    "adaptiveTransportLatencyFrames",
):
    require(token in bridge, f"N-channel bridge missing {token}")

capture = function_body(bridge, "N60LiveNChannelCaptureIOProc(")
output = function_body(bridge, "N60LiveNChannelOutputIOProc(")
require("N60ProgramInputMapReadFrame" in capture,
        "capture must canonicalize semantic channel order before ASRC")
require("N60AdaptiveSRCPushInterleaved" in capture,
        "capture callback does not feed N-channel ASRC")
require("N60AdaptiveSRCPullInterleaved" in output,
        "output callback does not consume N-channel ASRC")
require("N60AdaptiveSRCRelockConsumer" in output,
        "N-channel starvation path does not relock adaptive controller")
require("outputGateOpen" in output and "startupFadeRemaining" in output,
        "N-channel adaptive failure path must re-arm gate/fade")

for name, body in (("capture", capture), ("output", output)):
    for forbidden in (
        "malloc(", "calloc(", "realloc(", "free(", "printf(", "fprintf(",
        "pthread_mutex", "dispatch_sync", "os_log", "NSLog",
    ):
        require(forbidden not in body, f"{name} callback contains forbidden operation {forbidden}")

require("adaptiveSampleRateRequired" in session,
        "semantic session does not detect native-rate mismatch")
require("N60LiveNChannelBridgeConfigureAdaptiveSampleRate" in session,
        "semantic session does not configure live N-channel ASRC")
require("routePlan.usesMultiplePhysicalDevices" in session
        and "sampleRateMismatch" in session,
        "multi-device aggregate-clock mismatch must remain fail-closed")
require("adaptiveSampleRateRequired ? tapFormat.sampleRate : outputFormat.sampleRate" in session,
        "single-device adaptive capture aggregate must remain tap-native")
require("adaptiveSampleRateEnabled" in session and "adaptiveCorrectionPPM" in session,
        "N-channel transport counters do not publish ASRC telemetry")
require("raw.algorithmicLatencyFrames + raw.adaptiveTransportLatencyFrames" in engine,
        "product transport latency does not include adaptive buffering")

# PR71 must not regress or replace PR70 stereo activation.
require("N60RealtimeAudioBridgeConfigureAdaptiveSampleRate" in stereo,
        "PR70 stereo adaptive activation disappeared")
require("adaptiveSampleRateRequired" in stereo,
        "PR70 stereo mismatch policy disappeared")

# PR71 optimization: shared phase/tap coefficient work should be outside the channel loop.
require("double sums[N60_ADAPTIVE_SRC_MAX_CHANNELS]" in asrc,
        "multichannel ASRC accumulator optimization missing")
require("The fractional phase is shared by every channel" in asrc,
        "shared-tap optimization rationale missing")

for phrase in (
    "semantic",
    "32-channel",
    "7.1.4",
    "adaptive",
    "drift",
    "performance",
    "multi-device",
    "manual acceptance",
    "PR70",
):
    require(phrase.lower() in doc.lower(), f"architecture document missing '{phrase}'")

print("PR71 semantic N-channel adaptive-SRC structural validation passed")
