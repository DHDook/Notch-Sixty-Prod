#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
TRANSITION = ROOT / "NotchSixty/Audio/Realtime/N60MIMOTreatmentTransition.h"
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
PERMIT = ROOT / "NotchSixty/Audio/MIMORoomTreatmentActivationPermit.swift"
TESTS = ROOT / "NotchSixtyTests/MIMORoomTreatmentActivationPermitTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR76_TREATMENT_ARMING_RUNTIME.md"
AUDIO_ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
LIVE_CORE = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelRenderCore.h"
NCHANNEL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR76 validation failed: {message}")


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
    raise SystemExit(f"PR76 validation failed: unterminated function {signature}")


transition = TRANSITION.read_text()
bridge = BRIDGE.read_text()
permit = PERMIT.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()
audio_engine = AUDIO_ENGINE.read_text()
live_core = LIVE_CORE.read_text()
nchannel_session = NCHANNEL_SESSION.read_text()

for token in (
    "N60MIMOTreatmentStateBypassed",
    "N60MIMOTreatmentStateArming",
    "N60MIMOTreatmentStateActive",
    "N60MIMOTreatmentStateDisarming",
    "N60MIMOTreatmentStateFaultFading",
    "N60MIMOTreatmentStateFaulted",
    "N60MIMOTreatmentFaultAuthorizationRevoked",
    "N60MIMOTreatmentCreateLatencyMatchedIdentity",
    "N60MIMOTreatmentTransitionAtomicsAreLockFree",
    "N60MIMOTreatmentTransitionRequestArm",
    "N60MIMOTreatmentTransitionLatchFault",
    "N60MIMOTreatmentTransitionProcessFrame",
    "totalLatencyFrames",
):
    require(token in transition, f"transition runtime missing {token}")

process = function_body(
    transition,
    "N60MIMOTreatmentTransitionProcessFrame("
)
require(process.count("N60MIMOFIRRuntimeProcessFrame(") == 2,
        "transition must keep both identity and treatment FIR histories warm")
require("N60MIMOTreatmentStateFaultFading" in process,
        "transition callback lacks bounded fault fade")
require("N60MIMOTreatmentFaultIdentityRuntimeFailure" in process,
        "identity-path hard failure is not explicit")
require("output[channel] = 0.0f" in process,
        "identity-runtime failure must fail closed to zero")
require("N60MIMOTreatmentFaultAuthorizationRevoked" in process,
        "authorization revocation is not callback-visible")

for forbidden in (
    "malloc(", "calloc(", "realloc(", "free(",
    "printf(", "fprintf(", "pthread_mutex",
    "dispatch_sync", "os_log", "NSLog",
    "cos(", "sin(", "lrintf(",
):
    require(forbidden not in process,
            f"realtime transition contains forbidden operation {forbidden}")

require("atomic_is_lock_free" in transition,
        "transition does not require lock-free atomics")
require("N60MIMOTreatmentTransitionAtomicsAreLockFree(runtime)" in transition,
        "runtime creation does not enforce lock-free atomics")
require('#import "N60MIMOTreatmentTransition.h"' in bridge,
        "transition API is not exposed to Swift")

for token in (
    "struct MIMORoomTreatmentActivationPermit",
    "private init(",
    "MIMORoomTreatmentDeploymentGate().evaluate",
    ".eligibleForFutureLiveIntegration",
    "firProgram.taps.allSatisfy",
    "firProgram.declaredLatencyFrames == firProgram.tapCount / 2",
    "maximumEdgeEnergyFraction",
    "maximumCoefficientOvershootDB",
    "maximumColumnPowerOvershootDB",
    "maximumPerSourcePowerOvershootDB",
    "final class MIMORoomTreatmentPreparedTransition",
):
    require(token in permit, f"activation permit boundary missing {token}")

for forbidden in (
    "AudioDeviceStart",
    "AudioDeviceCreateIOProcID",
    "N60LiveNChannelRenderProcessFrame",
    "N60RenderKernelPublishSnapshot",
):
    require(forbidden not in permit,
            f"PR76 Swift layer unexpectedly references live output primitive {forbidden}")

# PR76 is deliberately standalone. The production audio path must not reference it.
for name, text in (
    ("AudioIOEngine", audio_engine),
    ("N-channel render core", live_core),
    ("N-channel transport session", nchannel_session),
):
    require("N60MIMOTreatmentTransition" not in text,
            f"{name} unexpectedly activates PR76 transition runtime")
    require("MIMORoomTreatmentPreparedTransition" not in text,
            f"{name} unexpectedly owns PR76 prepared transition")

require("MIMORoomTreatmentActivationPermit.swift in Sources" in project,
        "PR76 permit source missing from app target")
require("MIMORoomTreatmentActivationPermitTests.swift in Sources" in project,
        "PR76 tests missing from test target")

for token in (
    "testPermitRequiresCompletePR75Evidence",
    "testPermitRejectsUnsafeOrForgedFIRProgram",
    "testPreparedStandaloneTransitionArmsAndAuthorizationRevocationFaultsClosed",
    "testPreparedTransitionRejectsPermitProgramMismatch",
    "testTransitionFadeConfigurationProducesBoundedFrameCounts",
):
    require(token in tests, f"PR76 XCTest acceptance missing {token}")

normalized = doc.lower().replace(chr(96), "")
for phrase in (
    "latency-matched identity",
    "2304 total frames",
    "both identity and treatment runtimes process every frame",
    "authorization revoked",
    "lock-free",
    "does not connect treatment to core audio",
    "no user-facing enable button",
    "remains non-actuating",
):
    require(phrase in normalized,
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr75_room_treatment_verification.py").exists(),
        "inherited PR75 verification guard is missing")
require((ROOT / "ci/validate_pr74_mimo_fir_runtime.c").exists(),
        "inherited PR74 runtime harness is missing")

print("PR76 treatment arming/runtime structural validation passed")
