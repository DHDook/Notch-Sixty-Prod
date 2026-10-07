#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ABI_H = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitLiveRackBridge.h"
ABI_C = ROOT / "NotchSixty/Audio/Realtime/N60AudioUnitLiveRackBridge.c"
RUNTIME = ROOT / "NotchSixty/Audio/AudioUnitLiveRackRuntime.swift"
HOST = ROOT / "NotchSixty/Audio/AudioUnitHostController.swift"
STEREO_H = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.h"
STEREO_C = ROOT / "NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c"
KERNEL_C = ROOT / "NotchSixty/Audio/Realtime/N60RenderKernel.c"
NCHANNEL = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelBridge.h"
BINAURAL = ROOT / "NotchSixty/Audio/Realtime/N60BinauralHeadphoneBridge.h"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
PRODUCT = ROOT / "NotchSixty/NotchSixtyApp.swift"
STEREO_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioError.swift"
NCHANNEL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
BINAURAL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift"
UI = ROOT / "NotchSixty/UI/ProductionPluginWorkspace.swift"
TESTS = ROOT / "NotchSixtyTests/AudioUnitLiveRackRuntimeTests.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
DOC = ROOT / "docs/PR81_LIVE_AUDIO_UNIT_RACK.md"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR81 validation failed: {message}")


def function_body(text: str, name: str) -> str:
    start = text.find(name)
    require(start >= 0, f"missing function {name}")
    brace = text.find("{", start)
    require(brace >= 0, f"missing body for {name}")
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace:index + 1]
    raise SystemExit(f"PR81 validation failed: unterminated body for {name}")


abi_h = ABI_H.read_text()
abi_c = ABI_C.read_text()
runtime = RUNTIME.read_text()
host = HOST.read_text()
stereo_h = STEREO_H.read_text()
stereo_c = STEREO_C.read_text()
kernel_c = KERNEL_C.read_text()
nchannel = NCHANNEL.read_text()
binaural = BINAURAL.read_text()
engine = ENGINE.read_text()
product = PRODUCT.read_text()
stereo_session = STEREO_SESSION.read_text()
nchannel_session = NCHANNEL_SESSION.read_text()
binaural_session = BINAURAL_SESSION.read_text()
ui = UI.read_text()
tests = TESTS.read_text()
project = PROJECT.read_text()
doc = DOC.read_text().lower().replace("**", "")

for token in (
    "N60AudioUnitLiveRackProcessor",
    "N60AudioUnitLiveRackProcessFunction",
    "N60AudioUnitLiveRackFaultLatchRecord",
    "N60AudioUnitLiveRackProcessorIsValid",
    "latencyFrames",
):
    require(token in abi_h, f"live rack ABI missing {token}")

for token in ("_Atomic uint64_t faultCount", "memory_order_release", "memory_order_acquire"):
    require(token in abi_c, f"fault latch missing {token}")

for token in (
    "AudioUnitLiveRackRuntime",
    "AudioUnitLiveProcessStage",
    "AudioUnitLiveBypassStage",
    "AVAudioUnit.instantiate",
    "withAUAudioUnit",
    "allocateRenderResources",
    "renderBlock",
    "AURenderPullInputBlock",
    "AudioUnitLiveDelayLine",
    "maximumDelayMemoryBytes",
    "N60AudioUnitLiveRackFaultLatchRecord",
    '@_cdecl("N60AudioUnitLiveRackSwiftProcess")',
):
    require(token in runtime, f"live Swift runtime missing {token}")

require("prepareActiveSlotsForLive" in host,
        "host does not revalidate active slots before live activation")
require("makeLiveRackRuntime" in host,
        "host does not construct live runtime")
require("quarantineComponent" in host and "fault.description" in host,
        "runtime faults are not routed to control-plane quarantine")

for token in (
    "N60StereoPlaybackFrame",
    "N60RenderKernelProcessStereoPlaybackFrameInContext",
    "N60RenderKernelProcessStereoSystemFrameInContext",
):
    require(token in stereo_h, f"stereo boundary missing {token}")
require(
    kernel_c.find("N60RenderKernelProcessStereoPlaybackFrameInContext")
    < kernel_c.find("N60RenderKernelProcessStereoSystemFrameInContext"),
    "stereo playback/system implementation order is invalid"
)

stereo_output = function_body(stereo_c, "OSStatus N60OutputIOProc")
for token in (
    "N60RenderKernelProcessStereoPlaybackFrameInContext",
    "N60AudioUnitLiveRackProcess",
    "N60RenderKernelProcessStereoSystemFrameInContext",
):
    require(token in stereo_output, f"stereo output missing {token}")
require(
    stereo_output.find("N60RenderKernelProcessStereoPlaybackFrameInContext")
    < stereo_output.find("N60AudioUnitLiveRackProcess")
    < stereo_output.find("N60RenderKernelProcessStereoSystemFrameInContext"),
    "stereo rack is not between Playback and System stages"
)

n_output = function_body(nchannel, "N60LiveNChannelOutputIOProc")
require("N60AudioUnitLiveRackProcess" in n_output,
        "semantic callback does not run AU rack")
require("N60LiveNChannelRenderProcessFrame" in n_output,
        "semantic callback lost System render core")
require(
    n_output.find("N60AudioUnitLiveRackProcess")
    < n_output.find("N60LiveNChannelRenderProcessFrame"),
    "semantic rack must run before per-channel/System render core"
)

b_output = function_body(binaural, "N60BinauralHeadphoneOutputIOProc")
for token in (
    "N60AudioUnitLiveRackProcess",
    "N60HeadTrackedBinauralRuntimeProcessFrame",
    "N60HeadphoneDSPProcessStereoFrame",
    "N60ProtectionProcessStereoFrame",
):
    require(token in b_output, f"Virtual Speakers callback missing {token}")
require(
    b_output.find("N60AudioUnitLiveRackProcess")
    < b_output.find("N60HeadTrackedBinauralRuntimeProcessFrame")
    < b_output.find("N60HeadphoneDSPProcessStereoFrame")
    < b_output.find("N60ProtectionProcessStereoFrame"),
    "Virtual Speakers rack/headphone/protection order is invalid"
)

# Host-side callback code may copy/zero preallocated memory and invoke prepared
# DSP, but must never construct or schedule work.
for name, body in (
    ("stereo", stereo_output),
    ("semantic", n_output),
    ("binaural", b_output),
):
    for forbidden in (
        "malloc(",
        "calloc(",
        "realloc(",
        "free(",
        "dispatch_",
        "Task {",
        "NSLog(",
        "os_log",
        "AVAudioUnit.instantiate",
        "allocateRenderResources",
        "deallocateRenderResources",
        "fullState",
        "components(matching:",
        "AudioDeviceCreateIOProcID",
    ):
        require(forbidden not in body,
                f"{name} callback contains forbidden realtime token {forbidden}")

for source, label in (
    (stereo_session, "stereo"),
    (nchannel_session, "semantic"),
    (binaural_session, "Virtual Speakers"),
):
    require("audioUnitRack: AudioUnitLiveRackRuntime?" in source,
            f"{label} session does not strongly own rack runtime")
    require("audioUnitRack?.stopFaultMonitoring()" in source,
            f"{label} session does not stop fault monitor after transport teardown")

require("N60RealtimeAudioBridgeConfigureAudioUnitRack" in stereo_session,
        "stereo session does not configure rack processor")
require("N60LiveNChannelBridgeConfigureAudioUnitRack" in nchannel_session,
        "semantic session does not configure rack processor")
require("N60BinauralHeadphoneBridgeConfigureAudioUnitRack" in binaural_session,
        "Virtual Speakers session does not configure rack processor")

for token in (
    "audioUnitRackProcessingFormatForNextStart",
    "stageAudioUnitRackForNextStart",
    "applyAudioUnitRackLatency",
    "audioUnitRack: stagedAudioUnitRack",
):
    require(token in engine, f"engine staging/latency policy missing {token}")

for token in (
    "func startProcessing() async throws",
    "prepareActiveSlotsForLive",
    "makeLiveRackRuntime",
    "stageAudioUnitRackForNextStart",
    "try await product.startProcessing()",
):
    require(token in product, f"production start path missing {token}")

require("LIVE HOST READY" in ui, "Plug-ins workspace does not expose live-host status")
require("LIVE ENGINE READY" in ui, "rack card does not expose live-engine status")
require('Label("Add Plug-in", systemImage: "plus")' in ui,
        "Add Plug-in affordance disappeared")
require(".disabled(true)" in ui,
        "Add Plug-in must remain disabled in PR81")
for forbidden in ("requestViewController", "NSViewController", "viewConfiguration"):
    require(forbidden not in ui, f"vendor UI crossed PR81 scope with {forbidden}")

for token in (
    "testLatencyMatchedBypassStageDelaysExactly",
    "testSerialLatencyMatchedBypassesAccumulateExactly",
    "testRuntimeFailsClosedWhenCallbackExceedsPreparedQuantum",
    "testRealAppleLowPassCanRunThroughPreparedLiveRack",
    "testStereoPlaybackSystemSplitMatchesLegacyWrapperWithoutRack",
):
    require(token in tests, f"PR81 test coverage missing {token}")

for token in (
    "N60AudioUnitLiveRackBridge.c in Sources",
    "AudioUnitLiveRackRuntime.swift in Sources",
    "AudioUnitLiveRackRuntimeTests.swift in Sources",
):
    require(token in project, f"Xcode target wiring missing {token}")

for phrase in (
    "already-prepared third-party effects execute from the live audio callback",
    "latency-matched dry",
    "canonical semantic program channels",
    "virtual speakers",
    "no stereo-only plug-in is silently inserted",
    "sample-rate or semantic-layout change",
    "add plug-in remains disabled",
):
    require(phrase in doc, f"architecture doc missing '{phrase}'")

print("PR81 live Audio Unit rack structural validation passed")
