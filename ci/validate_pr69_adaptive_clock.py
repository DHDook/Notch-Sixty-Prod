#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.h"
SOURCE = ROOT / "NotchSixty/Audio/Realtime/N60AdaptiveSampleRate.c"
STEREO = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
NCHANNEL = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
DOC = ROOT / "docs/PR69_ADAPTIVE_CLOCK_SRC_FOUNDATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR69 validation failed: {message}")


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
    raise SystemExit(f"PR69 validation failed: unterminated function {signature}")


header = HEADER.read_text()
source = SOURCE.read_text()
stereo = STEREO.read_text()
nchannel = NCHANNEL.read_text()
doc = DOC.read_text()

for token in (
    "N60AdaptiveClockController",
    "N60AdaptiveSRCConfiguration",
    "N60AdaptiveSRCSnapshot",
    "N60AdaptiveSRCPushInterleaved",
    "N60AdaptiveSRCPullInterleaved",
    "N60AdaptiveSRCRealtimeAtomicsAreLockFree",
):
    require(token in header, f"public contract missing {token}")

require("N60_ADAPTIVE_SRC_MAX_CHANNELS 40u" in header, "physical channel ceiling must remain 40")
require("N60_ADAPTIVE_SRC_DEFAULT_TAPS 96u" in header, "expected 96-tap default quality")
require("N60_ADAPTIVE_SRC_DEFAULT_PHASES 2048u" in header, "expected 2048-phase default quality")
require("N60_ASRC_KAISER_BETA 10.0" in source, "Kaiser design constant missing")
require("N60_ASRC_NYQUIST_FRACTION 0.95" in source, "anti-alias transition margin missing")
require("Back-calculate the integral term" in source, "PI controller anti-windup missing")
require("atomic_is_lock_free" in source, "runtime must reject non-lock-free atomic implementation")

for signature in ("N60AdaptiveSRCPushInterleaved(", "N60AdaptiveSRCPullInterleaved("):
    body = function_body(source, signature)
    for forbidden in (
        "malloc(", "calloc(", "realloc(", "free(", "printf(", "fprintf(",
        "pthread_mutex", "dispatch_sync", "os_log", "NSLog",
    ):
        require(forbidden not in body, f"{signature} contains realtime-forbidden operation {forbidden}")

# PR69 is intentionally foundation-only: shipping transports must continue to
# fail closed on native-rate mismatches until a later activation PR wires the
# new primitive into the callback boundary.
require("sampleRateMismatch" in stereo, "stereo mismatch guard disappeared")
require("sampleRateMismatch" in nchannel, "N-channel mismatch guard disappeared")
require("N60AdaptiveSampleRate" not in stereo, "stereo live activation belongs in a later PR")
require("N60AdaptiveSampleRate" not in nchannel, "N-channel live activation belongs in a later PR")

for phrase in (
    "foundation only",
    "no live transport activation",
    "allocation",
    "latency",
    "44.1",
    "384 kHz",
    "windowed-sinc",
    "manual validation",
):
    require(phrase.lower() in doc.lower(), f"architecture document missing '{phrase}'")

print("PR69 adaptive clock/SRC structural validation passed")
