#!/usr/bin/env python3
"""Permanent PR60 guard for semantic N-channel transport and Core Audio mapping."""

from __future__ import annotations

import pathlib
import platform
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
CORE = REALTIME / "N60ProgramTransportCore.h"
APPLE = REALTIME / "N60ProgramTransport.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR60 validation failed: {message}")


def compile_and_run(clang: str, source_text: str, name: str) -> None:
    with tempfile.TemporaryDirectory(prefix=f"notch-sixty-pr60-{name}-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / f"{name}.c"
        binary = temp / name
        source.write_text(source_text, encoding="utf-8")
        subprocess.run([
            clang,
            "-std=c11",
            "-O2",
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-I{REALTIME}",
            str(source),
            "-lm",
            "-o",
            str(binary),
        ], check=True)
        subprocess.run([str(binary)], check=True)


def main() -> None:
    for path in (CORE, APPLE, BRIDGE):
        require(path.exists(), f"{path.name} is missing")
    core = CORE.read_text(encoding="utf-8")
    apple = APPLE.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("N60ProgramTransportFrame" in core, "semantic frame type is missing")
    require("_Atomic uint64_t writeIndex" in core, "SPSC write index is missing")
    require("Never overwrites unread frames" in core, "bounded overrun policy is missing")
    require("Empty reads return silence" in core, "fail-closed underrun policy is missing")
    require("N60ProgramInputMapCompile" in apple, "Core Audio input semantic mapping is missing")
    require("N60ProgramOutputMapCompile" in apple, "Core Audio output semantic mapping is missing")
    require("Unknown labels are never guessed" in apple, "strict output-label policy is missing")
    require("once per callback" in apple, "callback-level atomic publication contract is missing")
    require('#import "N60ProgramTransport.h"' in bridge, "transport ABI is not exposed to Swift")

    enqueue = core.split("static inline bool N60ProgramTransportEnqueueFrame", 1)[1]
    enqueue = enqueue.split("static inline bool N60ProgramTransportDequeueFrame", 1)[0]
    dequeue = core.split("static inline bool N60ProgramTransportDequeueFrame", 1)[1]
    dequeue = dequeue.split("static inline void N60ProgramTransportRecordUnsupportedBufferLayout", 1)[0]
    for body, label in ((enqueue, "enqueue"), (dequeue, "dequeue")):
        require("malloc(" not in body and "calloc(" not in body and "free(" not in body,
                f"{label} performs allocation")

    capture = apple.split("static inline uint32_t N60ProgramTransportCaptureBuffer", 1)[1]
    capture = capture.split("#ifdef __cplusplus", 1)[0]
    require("malloc(" not in capture and "calloc(" not in capture and "free(" not in capture,
            "Core Audio capture adapter performs allocation")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    portable = r'''
#include <assert.h>
#include <math.h>
#include "N60ProgramTransportCore.h"

int main(void) {
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOneFour);
    assert(N60ProgramChannelLayoutIsValid(&layout));
    N60ProgramTransport *transport = N60ProgramTransportCreate(3u, layout);
    assert(transport != NULL);
    assert(N60ProgramTransportLayoutMatches(transport, &layout));

    for (uint32_t frameIndex = 0; frameIndex < 3u; ++frameIndex) {
        N60ProgramTransportFrame frame = {0};
        for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
            frame.channels[channel] = (float)(100u * frameIndex + channel);
        }
        assert(N60ProgramTransportEnqueueFrame(transport, &frame));
    }
    N60ProgramTransportFrame overflow = {0};
    assert(!N60ProgramTransportEnqueueFrame(transport, &overflow));
    N60ProgramTransportSnapshot snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 3u);
    assert(snapshot.overrunFrames == 1u);
    assert(snapshot.bufferedFrames == 3u);

    for (uint32_t frameIndex = 0; frameIndex < 3u; ++frameIndex) {
        N60ProgramTransportFrame frame = {0};
        assert(N60ProgramTransportDequeueFrame(transport, &frame));
        for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
            assert(frame.channels[channel] == (float)(100u * frameIndex + channel));
        }
    }
    N60ProgramTransportFrame underflow;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        underflow.channels[channel] = 9.0f;
    }
    assert(!N60ProgramTransportDequeueFrame(transport, &underflow));
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        assert(underflow.channels[channel] == 0.0f);
    }
    snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.consumedFrames == 3u);
    assert(snapshot.underrunFrames == 1u);
    assert(snapshot.bufferedFrames == 0u);

    N60ProgramTransportReset(transport);
    snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 0u && snapshot.consumedFrames == 0u);
    N60ProgramTransportDestroy(transport);
    return 0;
}
'''
    compile_and_run(clang, portable, "transport_core")

    if platform.system() == "Darwin":
        apple_harness = r'''
#include <assert.h>
#include <math.h>
#include <string.h>
#include "N60ProgramTransport.h"

static AudioChannelDescription description(AudioChannelLabel label) {
    AudioChannelDescription d = {0};
    d.mChannelLabel = label;
    return d;
}

static void closef(float actual, float expected) {
    assert(fabsf(actual - expected) <= 1.0e-7f);
}

int main(void) {
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    assert(N60ProgramChannelLayoutIsValid(&fiveOne));

    // External stream order: R, L, C, LFE, RS, LS. Canonical order must be L,R,C,LFE,LS,RS.
    AudioChannelDescription inputDescriptions[6] = {
        description(kAudioChannelLabel_Right),
        description(kAudioChannelLabel_Left),
        description(kAudioChannelLabel_Center),
        description(kAudioChannelLabel_LFEScreen),
        description(kAudioChannelLabel_RightSurround),
        description(kAudioChannelLabel_LeftSurround),
    };
    N60ProgramInputMap inputMap = {0};
    assert(N60ProgramInputMapCompile(inputDescriptions, 6u, fiveOne, &inputMap));
    assert(!N60ChannelRoutingMatrixIsIdentity(&inputMap.streamToCanonical));

    float interleavedInput[12] = {
        20, 10, 30, 40, 60, 50,
        21, 11, 31, 41, 61, 51,
    };
    AudioBufferList inputABL = {0};
    inputABL.mNumberBuffers = 1u;
    inputABL.mBuffers[0].mNumberChannels = 6u;
    inputABL.mBuffers[0].mDataByteSize = sizeof(interleavedInput);
    inputABL.mBuffers[0].mData = interleavedInput;

    N60ProgramTransportFrame canonical = {0};
    assert(N60ProgramInputMapReadFrame(&inputMap, &inputABL, 0u, &canonical));
    closef(canonical.channels[0], 10.0f);
    closef(canonical.channels[1], 20.0f);
    closef(canonical.channels[2], 30.0f);
    closef(canonical.channels[3], 40.0f);
    closef(canonical.channels[4], 50.0f);
    closef(canonical.channels[5], 60.0f);

    // Physical device order: C,R,L,Unknown,LFE,RS,LS. Unknown aux channel must be silenced.
    AudioChannelDescription outputDescriptions[7] = {
        description(kAudioChannelLabel_Center),
        description(kAudioChannelLabel_Right),
        description(kAudioChannelLabel_Left),
        description(kAudioChannelLabel_Unknown),
        description(kAudioChannelLabel_LFEScreen),
        description(kAudioChannelLabel_RightSurround),
        description(kAudioChannelLabel_LeftSurround),
    };
    N60ProgramOutputMap outputMap = {0};
    assert(N60ProgramOutputMapCompile(outputDescriptions, 7u, fiveOne, &outputMap));
    float interleavedOutput[7] = {9,9,9,9,9,9,9};
    AudioBufferList outputABL = {0};
    outputABL.mNumberBuffers = 1u;
    outputABL.mBuffers[0].mNumberChannels = 7u;
    outputABL.mBuffers[0].mDataByteSize = sizeof(interleavedOutput);
    outputABL.mBuffers[0].mData = interleavedOutput;
    assert(N60ProgramOutputMapWriteFrame(&outputMap, &canonical, &outputABL, 0u));
    closef(interleavedOutput[0], 30.0f);
    closef(interleavedOutput[1], 20.0f);
    closef(interleavedOutput[2], 10.0f);
    closef(interleavedOutput[3], 0.0f);
    closef(interleavedOutput[4], 40.0f);
    closef(interleavedOutput[5], 60.0f);
    closef(interleavedOutput[6], 50.0f);

    AudioChannelDescription missing[6];
    memcpy(missing, inputDescriptions, sizeof(missing));
    missing[5] = description(kAudioChannelLabel_Unknown);
    assert(!N60ProgramOutputMapCompile(missing, 6u, fiveOne, &outputMap));

    AudioChannelDescription duplicate[6];
    memcpy(duplicate, inputDescriptions, sizeof(duplicate));
    duplicate[5] = description(kAudioChannelLabel_RightSurround);
    assert(!N60ProgramOutputMapCompile(duplicate, 6u, fiveOne, &outputMap));

    // Capture callback adapter publishes a canonical semantic ring.
    N60ProgramTransport *transport = N60ProgramTransportCreate(4u, fiveOne);
    assert(transport != NULL);
    assert(N60ProgramTransportCaptureBuffer(transport, &inputMap, &inputABL) == 2u);
    N60ProgramTransportFrame first = {0}, second = {0};
    assert(N60ProgramTransportDequeueFrame(transport, &first));
    assert(N60ProgramTransportDequeueFrame(transport, &second));
    closef(first.channels[0], 10.0f);
    closef(first.channels[5], 60.0f);
    closef(second.channels[0], 11.0f);
    closef(second.channels[5], 61.0f);
    N60ProgramTransportSnapshot snapshot = N60ProgramTransportGetSnapshot(transport);
    assert(snapshot.capturedFrames == 2u && snapshot.consumedFrames == 2u);
    assert(snapshot.unsupportedBufferLayouts == 0u);
    N60ProgramTransportDestroy(transport);

    return 0;
}
'''
        compile_and_run(clang, apple_harness, "coreaudio_transport")

    print("PR60 N-channel transport validation passed")


if __name__ == "__main__":
    main()
