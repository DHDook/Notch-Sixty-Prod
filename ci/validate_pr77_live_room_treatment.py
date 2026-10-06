#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
LIVE = REALTIME / "N60MIMOTreatmentLiveIntegration.h"
BRIDGE = REALTIME / "N60LiveNChannelBridge.h"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
DIAG = ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
UI = ROOT / "NotchSixty/UI/ProductionMetersView.swift"
TESTS = ROOT / "NotchSixtyTests/LiveMIMORoomTreatmentIntegrationTests.swift"
DOC = ROOT / "docs/PR77_LIVE_ROOM_TREATMENT_INTEGRATION.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR77 validation failed: {message}")


def function_body(text: str, signature: str) -> str:
    start = text.find(signature)
    require(start >= 0, f"missing function {signature}")
    brace = text.find("{", start)
    require(brace >= 0, f"missing body for {signature}")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
    raise SystemExit(f"PR77 validation failed: unterminated function {signature}")


live = LIVE.read_text()
bridge = BRIDGE.read_text()
session = SESSION.read_text()
engine = ENGINE.read_text()
diag = DIAG.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
doc = DOC.read_text()

for token in (
    "N60MIMOTreatmentLiveIntegrationCreate",
    "N60MIMOTreatmentLiveProcessPhysicalFrame",
    "N60MIMOTreatmentLiveSetAuthorized",
    "N60MIMOTreatmentLiveRequestArm",
    "N60MIMOTreatmentLiveRequestBypass",
    "N60MIMOTreatmentLiveLatchFault",
    "protectionClampSamples",
    "integrationFailures",
):
    require(token in live, f"live integration missing {token}")

process = function_body(live, "N60MIMOTreatmentLiveProcessPhysicalFrame(")
for forbidden in (
    "malloc(", "calloc(", "realloc(", "free(",
    "printf(", "fprintf(", "pthread_mutex", "dispatch_sync",
    "os_log", "NSLog", "cos(", "sin(",
):
    require(forbidden not in process,
            f"realtime live integration contains forbidden operation {forbidden}")

require("delayRingFrames = totalLatencyFrames + 1u" in live,
        "full physical-output latency matching is missing")
require("physicalValues[physical] = readFrame[physical]" in live,
        "untreated physical outputs are not latency matched")
require("N60MIMOTreatmentFaultProtection" in live,
        "emergency clamp does not latch treatment protection fault")
require("value > 1.0f" in live and "value < -1.0f" in live,
        "emergency physical-output clamp is missing")

require('#include "N60MIMOTreatmentLiveIntegration.h"' in bridge,
        "live bridge does not include room-treatment integration")
output_callback = function_body(bridge, "N60LiveNChannelOutputIOProc(")
require("N60LiveNChannelRenderProcessFrame" in output_callback,
        "base N-channel rendering disappeared")
require("N60MIMOTreatmentLiveProcessPhysicalFrame" in output_callback,
        "treatment is not in physical-output callback path")
require(
    output_callback.find("N60LiveNChannelRenderProcessFrame")
    < output_callback.find("N60MIMOTreatmentLiveProcessPhysicalFrame")
    < output_callback.find("N60LiveNChannelWritePhysicalFrame"),
    "treatment must run after bass-managed physical render and before output write"
)
require("roomTreatmentLatencyFrames" in bridge,
        "treatment latency is not published by bridge snapshot")

for token in (
    "LiveMIMORoomTreatmentPreparation",
    "acceptedProfile",
    "acceptedSelectedOutputUID",
    "roomTreatmentPermitMismatch",
    "roomTreatmentSourceUnavailable",
    "physicalChannels(",
    "N60LiveNChannelBridgeConfigureRoomTreatment",
    "N60LiveNChannelBridgeSetRoomTreatmentAuthorized",
):
    require(token in session, f"Core Audio treatment gate missing {token}")

for token in (
    "private var stagedRoomTreatment",
    "stageRoomTreatmentForNextStart",
    "clearStagedRoomTreatment",
    "requestRoomTreatmentArm",
    "requestRoomTreatmentBypass",
    "revokeRoomTreatmentAuthorization",
    "stagedRoomTreatment.acceptedProfile == profile",
    "stagedRoomTreatment.acceptedSelectedOutputUID == output.uid",
    "roomTreatment: stagedRoomTreatment",
):
    require(token in engine, f"AudioIOEngine treatment integration missing {token}")

require("private var stagedRoomTreatment" in engine,
        "treatment staging must remain internal engine state")
require("stagedRoomTreatment: LiveMIMORoomTreatmentPreparation? = nil" not in engine,
        "treatment must not be initialized enabled")
require("@Published private(set) var stagedRoomTreatment" not in engine,
        "armed/staged treatment must not become persisted/published product state in PR77")

# PR77 may show health, but must not add a UI control that can arm treatment.
for forbidden in (
    "requestRoomTreatmentArm()",
    "requestRoomTreatmentBypass()",
    "stageRoomTreatmentForNextStart(",
):
    require(forbidden not in ui,
            f"PR77 UI unexpectedly exposes treatment control {forbidden}")
require("Room Treatment" in ui,
        "Transport diagnostics do not expose treatment health")
require("ProductionRoomTreatmentDiagnostics" in diag,
        "production treatment diagnostics contract missing")

for token in (
    "testPreparationMapsAcceptedSubwooferSourcesToPhysicalChannels",
    "testPreparationMapsMixedSpeakerAndSubwooferSourcesInPermitOrder",
    "testUnavailablePhysicalTreatmentSourceFailsClosed",
    "testPermitSampleRateMismatchFailsBeforeLivePreparation",
):
    require(token in tests, f"Swift PR77 acceptance missing {token}")

normalized_doc = doc.lower().replace(chr(96), "")
for phrase in (
    "hardware-gated",
    "default-off",
    "no ui arm control",
    "physical-output boundary",
    "all physical outputs",
    "route binding",
    "emergency sample clamp",
    "not a substitute",
    "48 ms",
):
    require(phrase in normalized_doc,
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr76_treatment_transition.py").exists(),
        "inherited PR76 structural validation missing")
require((ROOT / "ci/validate_pr76_treatment_transition.c").exists(),
        "inherited PR76 transition simulation missing")

print("PR77 hardware-gated live room-treatment integration validation passed")
