#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / "NotchSixty/Audio/Realtime/N60MIMOFIRRuntime.h"
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/NotchSixty-Bridging-Header.h"
COMPILER = ROOT / "NotchSixty/Audio/MIMORoomTreatmentFIRCompiler.swift"
TESTS = ROOT / "NotchSixtyTests/MIMORoomTreatmentFIRCompilerTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR74_MIMO_FIR_RUNTIME.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR74 validation failed: {message}")


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
    raise SystemExit(f"PR74 validation failed: unterminated function {signature}")


runtime = RUNTIME.read_text()
bridge = BRIDGE.read_text()
compiler = COMPILER.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text()

for token in (
    "N60_MIMO_FIR_MAX_CHANNELS 4u",
    "N60_MIMO_FIR_PARTITION_FRAMES 256u",
    "N60_MIMO_FIR_MAX_TAPS 4096u",
    "N60MIMOFIRProgramCreate",
    "N60MIMOFIRRuntimeCreate",
    "N60MIMOFIRRuntimeProcessFrame",
    "N60MIMOFIRTapOffset",
):
    require(token in runtime, f"matrix FIR runtime missing {token}")

process = function_body(runtime, "N60MIMOFIRRuntimeProcessFrame(")
block = function_body(runtime, "N60MIMOFIRProcessBlock(")
transform = function_body(runtime, "N60MIMOFIRTransform(")
for name, body in (
    ("process frame", process),
    ("process block", block),
    ("FFT transform", transform),
):
    for forbidden in (
        "malloc(", "calloc(", "realloc(", "free(",
        "printf(", "fprintf(", "pthread_mutex",
        "dispatch_sync", "os_log", "NSLog",
        "cos(", "sin(",
    ):
        require(forbidden not in body,
                f"{name} contains realtime-forbidden operation {forbidden}")

require('#import "N60MIMOFIRRuntime.h"' in bridge,
        "standalone matrix FIR runtime is not exposed to Swift")

for token in (
    "struct MIMORoomTreatmentFIRCompiler",
    "MIMORoomTreatmentFIRProgram",
    "tapCount = 4_096",
    "transitionWidthHz = 15.0",
    "maximumEdgeEnergyFraction",
    "maximumCoefficientOvershootDB",
    "maximumColumnPowerOvershootDB",
    "maximumPerSourcePowerOvershootDB",
    "applyEdgeTaper",
    "denseSafetyDiagnostics",
    "simulationOnly",
):
    require(token in compiler, f"FIR compiler missing {token}")

require("sourceCountUnsupported" in compiler,
        "compiler does not explicitly reject unsupported actuator counts")
require("N60_MIMO_FIR_MAX_CHANNELS" in compiler,
        "compiler actuator limit is not tied to runtime limit")
require("declaredLatency = half" in compiler,
        "compiler does not make causal half-FIR delay explicit")
require("func apply(" not in compiler and "func applying(" not in compiler,
        "PR74 must not expose live deployment API")

for forbidden in (
    "N60LiveNChannelRenderProcessFrame",
    "N60LiveNChannelRenderRuntimePrepare",
    "AudioDeviceStart",
    "AudioDeviceCreateIOProcID",
    "N60RenderKernelPublishSnapshot",
):
    require(forbidden not in compiler and forbidden not in runtime,
            f"PR74 unexpectedly references live graph/IO primitive {forbidden}")

require("MIMORoomTreatmentFIRCompiler.swift in Sources" in project,
        "FIR compiler is missing from app target")
require("MIMORoomTreatmentFIRCompilerTests.swift in Sources" in project,
        "FIR compiler tests are missing from test target")

for token in (
    "testIdentityPlanCompilesToCenteredDiagonalImpulse",
    "testBoundedCrossCoupledPlanCompilesAndRunsThroughStandaloneRuntime",
    "testCompilerRejectsMoreThanFourTreatmentActuators",
    "testRealizedUnsafePlanIsRejectedEvenIfInputClaimsAcceptance",
    "testInvalidNonPowerOfTwoTapCountFailsClosed",
):
    require(token in tests, f"PR74 Swift acceptance missing {token}")

for phrase in (
    "four treatment actuators",
    "4096 fir taps",
    "256-frame",
    "dense post-compile safety",
    "48 ms",
    "not live activation",
    "no user-facing apply/deploy path",
    "physical excursion/thermal safety",
):
    require(phrase.lower() in doc.lower(),
            f"architecture document missing '{phrase}'")

require((ROOT / "ci/validate_pr73_mimo_room_treatment.py").exists(),
        "inherited PR73 validation is missing")
require((ROOT / "ci/validate_pr73_mimo_room_treatment.c").exists(),
        "inherited PR73 numerical harness is missing")

print("PR74 MIMO FIR compiler/runtime structural validation passed")
