#!/usr/bin/env python3
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
FRACTIONAL_DELAY = ROOT / "NotchSixty/Audio/Realtime/N60FractionalDelay.h"
CORE_AUDIO = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"


def fail(message: str) -> None:
    print(f"PR35 realtime/control-plane validation: FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def function_body(source: str, signature_pattern: str) -> str:
    match = re.search(signature_pattern, source, re.MULTILINE)
    if match is None:
        fail(f"missing function matching {signature_pattern!r}")
    opening = source.find("{", match.end())
    if opening < 0:
        fail(f"missing opening brace for {signature_pattern!r}")

    depth = 0
    index = opening
    state = "code"
    while index < len(source):
        ch = source[index]
        nxt = source[index + 1] if index + 1 < len(source) else ""

        if state == "code":
            if ch == '"':
                state = "string"
            elif ch == "'":
                state = "char"
            elif ch == "/" and nxt == "/":
                state = "line_comment"
                index += 1
            elif ch == "/" and nxt == "*":
                state = "block_comment"
                index += 1
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return source[opening + 1:index]
        elif state == "string":
            if ch == "\\":
                index += 1
            elif ch == '"':
                state = "code"
        elif state == "char":
            if ch == "\\":
                index += 1
            elif ch == "'":
                state = "code"
        elif state == "line_comment":
            if ch == "\n":
                state = "code"
        elif state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "code"
                index += 1
        index += 1

    fail(f"unterminated function matching {signature_pattern!r}")
    return ""


def require(haystack: str, needle: str, context: str) -> None:
    if needle not in haystack:
        fail(f"{context} must contain {needle!r}")


def forbid(haystack: str, needle: str, context: str) -> None:
    if needle in haystack:
        fail(f"{context} must not contain {needle!r}")


bridge = BRIDGE.read_text()
fractional_delay = FRACTIONAL_DELAY.read_text()
core_audio = CORE_AUDIO.read_text()

# The hot gain helpers are called for every rendered frame, so they must remain
# pure callback-local arithmetic. The output loop is allowed to retain bounded
# diagnostic atomics on exceptional paths (for example unsupported layouts).
transition_helper = function_body(bridge, r"static\s+float\s+next_transition_gain\s*\(")
startup_helper = function_body(bridge, r"static\s+float\s+startup_fade_gain\s*\(")
for helper_name, helper_body in (
    ("next_transition_gain", transition_helper),
    ("startup_fade_gain", startup_helper),
):
    forbid(helper_body, "atomic_", helper_name)

# Core Audio buffer layout discovery/validation belongs at callback granularity,
# not in the sample loop. Hot loops should advance already-validated pointers.
require(bridge, "N60InputBufferView", "bridge input layout view")
require(bridge, "N60OutputBufferView", "bridge output layout view")
require(bridge, "make_input_buffer_view", "bridge input layout setup")
require(bridge, "make_output_buffer_view", "bridge output layout setup")
forbid(bridge, "read_input_frame(", "bridge per-frame input layout helper")
forbid(bridge, "write_output_frame(", "bridge per-frame output layout helper")

capture_callback = function_body(bridge, r"OSStatus\s+N60CaptureIOProc\s*\(")
require(capture_callback, "make_input_buffer_view(inInputData, &inputView)", "N60CaptureIOProc callback layout setup")
require(capture_callback, "uint32_t ringWriteIndex = (uint32_t)(writeIndex % bridge->capacityFrames);", "N60CaptureIOProc")
require(capture_callback, "N60StereoFrame frame = {*inputLeft, *inputRight};", "N60CaptureIOProc hot frame path")
require(capture_callback, "inputLeft += inputView.leftStride;", "N60CaptureIOProc hot frame path")
require(capture_callback, "inputRight += inputView.rightStride;", "N60CaptureIOProc hot frame path")
require(capture_callback, "bridge->frames[ringWriteIndex] = frame;", "N60CaptureIOProc")
require(capture_callback, "if (ringWriteIndex == bridge->capacityFrames) ringWriteIndex = 0u;", "N60CaptureIOProc")
forbid(capture_callback, "bridge->frames[(writeIndex + frameIndex) % bridge->capacityFrames]", "N60CaptureIOProc per-frame ring path")

output_callback = function_body(bridge, r"OSStatus\s+N60OutputIOProc\s*\(")
require(output_callback, "make_output_buffer_view(outOutputData, &outputView)", "N60OutputIOProc callback layout setup")
require(output_callback, "latch_transition_command(bridge);", "N60OutputIOProc callback preamble")
require(output_callback, "latch_startup_fade_command(bridge);", "N60OutputIOProc callback preamble")
require(output_callback, "N60TransitionRampRuntime transitionRamp = bridge->transitionRuntime;", "N60OutputIOProc")
require(output_callback, "N60StartupFadeRuntime startupFade = bridge->startupFadeRuntime;", "N60OutputIOProc")
require(output_callback, "next_transition_gain(&transitionRamp)", "N60OutputIOProc rendered-frame path")
require(output_callback, "startup_fade_gain(&startupFade, masterGain)", "N60OutputIOProc rendered-frame path")
require(output_callback, "publish_transition_runtime(bridge, &transitionRamp);", "N60OutputIOProc")
require(output_callback, "uint32_t ringReadIndex = (uint32_t)(readIndex % bridge->capacityFrames);", "N60OutputIOProc")
require(output_callback, "N60StereoFrame frame = bridge->frames[ringReadIndex];", "N60OutputIOProc")
require(output_callback, "if (ringReadIndex == bridge->capacityFrames) ringReadIndex = 0u;", "N60OutputIOProc")
require(output_callback, "*outputLeft = processed.left * gain;", "N60OutputIOProc hot frame path")
require(output_callback, "*outputRight = processed.right * gain;", "N60OutputIOProc hot frame path")
require(output_callback, "outputLeft += outputView.leftStride;", "N60OutputIOProc hot frame path")
require(output_callback, "outputRight += outputView.rightStride;", "N60OutputIOProc hot frame path")
forbid(output_callback, "bridge->frames[(readIndex + frameIndex) % bridge->capacityFrames]", "N60OutputIOProc per-frame ring path")

# Alignment history is a fixed power-of-two ring. Preserve its click-free warm
# history semantics while forbidding integer division/modulo in its per-sample
# read and write paths.
require(fractional_delay, "#define N60_FRACTIONAL_DELAY_MASK (N60_FRACTIONAL_DELAY_CAPACITY - 1u)", "fractional-delay ring")
require(fractional_delay, "& N60_FRACTIONAL_DELAY_MASK;", "fractional-delay ring wrapping")
require(fractional_delay, "runtime->writeIndex = (runtime->writeIndex + 1u) & N60_FRACTIONAL_DELAY_MASK;", "fractional-delay write path")
forbid(fractional_delay, "% N60_FRACTIONAL_DELAY_CAPACITY", "fractional-delay per-sample ring path")

# Command publication must remain sequence-protected rather than mutating the
# callback-owned runtime from the control thread.
require(bridge, "transitionCommandSequence", "bridge transition command state")
require(bridge, "startupFadeCommandSequence", "bridge startup-fade command state")
require(bridge, "begin_command_write", "bridge command publication")
require(bridge, "end_command_write", "bridge command publication")

# Interactive graph mutation must remain off the caller/MainActor and free of
# explicit sleep choreography. Teardown may retain a bounded synchronous
# lifetime barrier because the Core Audio callbacks must be stopped before the
# bridge can be freed.
transition_graph = function_body(core_audio, r"func\s+transitionDSPGraph\s*\(")
forbid(transition_graph, "usleep(", "transitionDSPGraph")
forbid(transition_graph, "for step", "transitionDSPGraph")
require(transition_graph, "enqueueTransition", "transitionDSPGraph")

publish_graph = function_body(core_audio, r"func\s+publishDSPGraph\s*\(")
require(publish_graph, "enqueuePublish", "publishDSPGraph running-transport path")

# Structural transitions must be registered synchronously before returning to
# the single MainActor control writer. That closes the race where another FIR
# generation could otherwise wrap the three-slot prepared-program ring while a
# prior structural graph was only queued for publication.
enqueue_transition = function_body(core_audio, r"func\s+enqueueTransition\s*\(")
require(enqueue_transition, "queue.sync", "DSPGraphPublicationCoordinator.enqueueTransition")
can_prepare = function_body(core_audio, r"func\s+canPrepareProgram\s*\(")
require(can_prepare, "!transitionActive", "prepared-program transition gate")

for function_name, pattern in (
    ("prepareConvolutionProgram", r"func\s+prepareConvolutionProgram\s*\(\s*slot:\s*UInt32,\s*leftTaps:"),
    ("prepareRoomCorrectionProgram", r"func\s+prepareRoomCorrectionProgram\s*\("),
    ("prepareSpeakerIRProgram", r"func\s+prepareSpeakerIRProgram\s*\("),
):
    body = function_body(core_audio, pattern)
    require(body, "canPrepareProgram()", function_name)

require(core_audio, "DSPGraphPublicationCoordinator", "Core Audio control plane")
require(core_audio, "DispatchQueue(", "DSP graph publication coordinator")
require(core_audio, "pendingSnapshot", "DSP graph publication coalescing")
require(core_audio, "graphPublicationCoalescedUpdates", "publication instrumentation")
require(core_audio, "graphPublicationFailures", "publication instrumentation")
require(core_audio, "graphTransitionsScheduled", "publication instrumentation")
forbid(core_audio, "fadeStepMicroseconds", "CoreAudioTransportSession stale transition scaffolding")
forbid(core_audio, "fadeStepCount", "CoreAudioTransportSession stale transition scaffolding")

print("PR35 realtime/control-plane architecture: PASS")