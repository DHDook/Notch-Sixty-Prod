#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text()

profile = text("NotchSixty/Audio/Routing/HeadphoneDeviceProfileConfiguration.swift")
engine = text("NotchSixty/Audio/AudioIOEngine.swift")
profiles = text("NotchSixty/State/ProductProfiles.swift")
session = text("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
render_h = text("NotchSixty/Audio/Realtime/N60RenderKernel.h")
render_c = text("NotchSixty/Audio/Realtime/N60RenderKernel.c")
bridge_h = text("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h")
bridge_c = text("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c")
pbx = text("NotchSixty.xcodeproj/project.pbxproj")

checks = {
    "headphone profile target member": "HeadphoneDeviceProfileConfiguration.swift in Sources" in pbx,
    "headphone profile persisted optional": "var headphoneDeviceProfile: HeadphoneDeviceProfileConfiguration?" in profiles,
    "playback schema remains v1": "struct PlaybackSystemState" in profiles and "static let currentSchemaVersion = 1" in profiles,
    "engine owns headphone profile": "var headphoneDeviceProfileConfiguration: HeadphoneDeviceProfileConfiguration?" in engine,
    "engine replacement API": "func replaceHeadphoneDeviceProfileConfiguration" in engine,
    "speaker profile conflict": "HeadphoneDeviceProfileError.speakerProfileConflict" in engine,
    "legacy physical routing conflict": "HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict" in engine,
    "profile compiles realtime snapshot": "makeRealtimeSnapshot(sampleRate:" in engine,
    "session config before graph publish": engine.index("session.configureHeadphoneDSP(headphoneSnapshot)") < engine.index("session.publishDSPGraph(graph)"),
    "session stopped-only config": "!isOutputStarted, !isCaptureStarted" in session and "func configureHeadphoneDSP" in session,
    "bridge config API": "N60RealtimeAudioBridgeConfigureHeadphoneDSP" in bridge_h and "N60RenderKernelConfigureHeadphoneDSP" in bridge_c,
    "render kernel owns headphone runtime": "N60HeadphoneDSPRuntime *headphoneDSPRuntime" in render_c,
    "render kernel control-plane config": "N60RenderKernelConfigureHeadphoneDSP" in render_h and "N60HeadphoneDSPRuntimePrepare" in render_c,
    "headphone processing before protection": render_c.index("N60HeadphoneDSPProcessStereoFrame") < render_c.index("N60ProtectionProcessStereoFrame"),
    "virtual speakers fail closed until renderer integration": "HeadphoneDeviceProfileError.binauralRuntimeUnavailable" in engine,
    "crossfeed profile exposed": "HeadphoneCrossfeedConfiguration" in profile,
    "headroom guard exposed": "conservativeRequiredHeadroomDB" in profile and "insufficientHeadroom" in profile,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("PR65 validation failed: " + ", ".join(failed))

# Realtime guard: the already-prepared PR56 frame processor must stay allocation/I/O free.
hp = text("NotchSixty/Audio/Realtime/N60HeadphoneDSP.h")
start = hp.index("static inline bool N60HeadphoneDSPProcessStereoFrame")
body = hp[start:]
for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf(", "fopen(", "pthread_mutex"):
    if forbidden in body:
        raise SystemExit(f"forbidden realtime operation in headphone frame processor: {forbidden}")

print("PR65 headphone stereo integration validation passed")
