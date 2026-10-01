#!/usr/bin/env python3
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
ROUTE = (ROOT / "NotchSixty" / "Audio" / "Routing" / "AudioRouteConfiguration.swift").read_text()
ENGINE = (ROOT / "NotchSixty" / "Audio" / "AudioIOEngine.swift").read_text()
PROFILES = (ROOT / "NotchSixty" / "State" / "ProductProfiles.swift").read_text()
TESTS = (ROOT / "NotchSixtyTests" / "NotchSixtyTests.swift").read_text()


def fail(message: str) -> None:
    print(f"PR43 driver-model validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)

for token in [
    "SpeakerDriverBusProcessingConfiguration",
    "SpeakerDriverProcessingConfiguration",
    "maximumEQBandCount = 8",
    "delayRangeMilliseconds = 0.0 ... 50.0",
    "limiterThresholdRange = -30.0 ... 0.0",
    "cannot be bypassed",
]:
    if token not in ROUTE:
        fail(f"missing route/model token: {token}")
for token in [
    "speakerDriverProcessingConfiguration = SpeakerDriverProcessingConfiguration()",
    "replaceSpeakerDriverProcessingConfiguration",
    "SpeakerDriverProcessingError.changesRequireIdle",
]:
    if token not in ENGINE:
        fail(f"missing engine ownership token: {token}")
for token in [
    "var speakerDriverProcessing: SpeakerDriverProcessingConfiguration?",
    "replaceSelectedSystemSpeakerDriverProcessing",
    "state.speakerDriverProcessing ?? SpeakerDriverProcessingConfiguration()",
]:
    if token not in PROFILES:
        fail(f"missing Playback System persistence token: {token}")
if "testPR43SpeakerDriverProcessingValidationAndBackwardPersistence" not in TESTS:
    fail("missing deterministic model/backward-persistence test")
print("PR43 per-driver Playback System model guard: PASS")
