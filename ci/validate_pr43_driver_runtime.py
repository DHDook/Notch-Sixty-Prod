#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "NotchSixty" / "Audio" / "Realtime" / "N60SpeakerDriverProcessing.h").read_text()
BRIDGE = (ROOT / "NotchSixty" / "Audio" / "Realtime" / "N60RealtimeAudioBridge.c").read_text()
ROUTE = (ROOT / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift").read_text()
CORE = (ROOT / "NotchSixty" / "Audio" / "CoreAudio" / "CoreAudioError.swift").read_text()
ENGINE = (ROOT / "NotchSixty" / "Audio" / "AudioIOEngine.swift").read_text()


def fail(message: str) -> None:
    print(f"PR43 driver-runtime validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

for token in [
    "N60_SPEAKER_DRIVER_MAX_EQ_SECTIONS 8u",
    "N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES 19201u",
    "N60SpeakerDriverProcessingRuntimeProcessValues",
    "fractionalAllPassCoefficient",
    "limiterReleaseCoefficient",
]:
    if token not in HEADER:
        fail(f"missing fixed-runtime token: {token}")
if "process_speaker_bus_splitter" not in BRIDGE or "N60SpeakerDriverProcessingRuntimeProcessValues" not in BRIDGE:
    fail("bridge does not contain splitter then driver processing")
if BRIDGE.index("process_speaker_bus_splitter") > BRIDGE.rindex("N60SpeakerDriverProcessingRuntimeProcessValues"):
    fail("driver processing is not downstream of mandatory speaker splitting")
for forbidden in ["malloc(", "calloc(", "realloc(", "free("]:
    process_tail = HEADER.split("N60SpeakerDriverProcessingRuntimeProcessValues", 1)[1]
    if forbidden in process_tail:
        fail(f"realtime driver processor contains forbidden allocation token {forbidden}")
for token in [
    "makeRealtimeSnapshot(sampleRate: Double)",
    "compiledSections(sampleRate: sampleRate)",
    "realtimeDriverIndex",
]:
    if token not in ROUTE:
        fail(f"missing Swift compile token: {token}")
for token in [
    "speakerDriverProcessingSnapshot: N60SpeakerDriverProcessingSnapshot?",
    "N60RealtimeAudioBridgeConfigureSpeakerDriverProcessing",
]:
    if token not in CORE:
        fail(f"missing transport configuration token: {token}")
if "speakerDriverProcessingSnapshot: speakerDriverProcessingSnapshot" not in ENGINE:
    fail("AudioIOEngine does not pass the immutable driver snapshot to transport")
print("PR43 per-driver realtime architecture guard: PASS")
