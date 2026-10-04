#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def text(path: str) -> str:
    return (ROOT / path).read_text()

profile = text("NotchSixty/Audio/Routing/HeadphoneDeviceProfileConfiguration.swift")
asset = text("NotchSixty/Audio/Routing/BinauralProfileAsset.swift")
engine = text("NotchSixty/Audio/AudioIOEngine.swift")
profiles = text("NotchSixty/State/ProductProfiles.swift")
stereo_session = text("NotchSixty/Audio/CoreAudio/CoreAudioError.swift")
binaural_session = text("NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift")
render_h = text("NotchSixty/Audio/Realtime/N60RenderKernel.h")
render_c = text("NotchSixty/Audio/Realtime/N60RenderKernel.c")
bridge_h = text("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.h")
bridge_c = text("NotchSixty/Audio/Realtime/N60RealtimeAudioBridge.c")
binaural_bridge = text("NotchSixty/Audio/Realtime/N60BinauralHeadphoneBridge.h")
workspace = text("NotchSixty/UI/ProductionHeadphoneWorkspace.swift")
root_view = text("NotchSixty/UI/ProductionRootView.swift")
pbx = text("NotchSixty.xcodeproj/project.pbxproj")

build_stereo_start = engine.index("private func buildStereoTransport")
build_stereo_end = engine.index("private func tearDownTransport", build_stereo_start)
build_stereo = engine[build_stereo_start:build_stereo_end]

process_start = render_c.index("void N60RenderKernelProcessStereoFrameInContext")
process_end = render_c.index("void N60RenderKernelEndRender", process_start)
process_body = render_c[process_start:process_end]

binaural_output_start = binaural_bridge.index("static inline OSStatus N60BinauralHeadphoneOutputIOProc")
binaural_output = binaural_bridge[binaural_output_start:]

checks = {
    "headphone profile target member": "HeadphoneDeviceProfileConfiguration.swift in Sources" in pbx,
    "binaural asset target member": "BinauralProfileAsset.swift in Sources" in pbx,
    "binaural session target member": "CoreAudioBinauralHeadphoneTransportSession.swift in Sources" in pbx,
    "semantic support target member": "CoreAudioSemanticTransportSupport.swift in Sources" in pbx,
    "headphones workspace target member": "ProductionHeadphoneWorkspace.swift in Sources" in pbx,
    "headphones sidebar destination": "case headphones" in root_view and 'case .headphones: return "Headphones"' in root_view,
    "headphones workspace routed": "ProductionHeadphoneWorkspace(engine: engine, profiles: product.profiles)" in root_view,
    "workspace edits selected playback system": "replaceSelectedSystemHeadphoneDeviceProfile" in workspace,
    "workspace normalized spatial import": "importNormalizedBinauralProfile" in workspace and "func importNormalizedBinauralProfile" in engine,
    "workspace documents sofa boundary": "Native AES69 .sofa files" in workspace,
    "headphone profile persisted optional": "var headphoneDeviceProfile: HeadphoneDeviceProfileConfiguration?" in profiles,
    "playback schema remains v1": "struct PlaybackSystemState" in profiles and "static let currentSchemaVersion = 1" in profiles,
    "engine owns headphone profile": "var headphoneDeviceProfileConfiguration: HeadphoneDeviceProfileConfiguration?" in engine,
    "engine owns binaural session": "binauralHeadphoneTransportSession" in engine,
    "engine replacement API": "func replaceHeadphoneDeviceProfileConfiguration" in engine,
    "speaker profile conflict": "HeadphoneDeviceProfileError.speakerProfileConflict" in engine,
    "legacy physical routing conflict": "HeadphoneDeviceProfileError.legacyPhysicalRoutingConflict" in engine,
    "profile compiles realtime snapshot": "makeRealtimeSnapshot(sampleRate:" in build_stereo,
    "session config before graph publish": build_stereo.index("session.configureHeadphoneDSP(headphoneSnapshot)") < build_stereo.index("session.publishDSPGraph(graph)"),
    "session stopped-only config": "!isOutputStarted, !isCaptureStarted" in stereo_session and "func configureHeadphoneDSP" in stereo_session,
    "bridge config API": "N60RealtimeAudioBridgeConfigureHeadphoneDSP" in bridge_h and "N60RenderKernelConfigureHeadphoneDSP" in bridge_c,
    "render kernel owns headphone runtime": "N60HeadphoneDSPRuntime *headphoneDSPRuntime" in render_c,
    "render kernel control-plane config": "N60RenderKernelConfigureHeadphoneDSP" in render_h and "N60HeadphoneDSPRuntimePrepare" in render_c,
    "stereo headphone processing before protection": process_body.index("N60HeadphoneDSPProcessStereoFrame") < process_body.index("N60ProtectionProcessStereoFrame"),
    "virtual speakers activated": "buildBinauralHeadphoneTransport" in engine and "CoreAudioBinauralHeadphoneTransportSession" in engine,
    "program source separate from headphone output": "programSource: AudioOutputDevice" in binaural_session and "selectedOutput: AudioOutputDevice" in binaural_session,
    "tap preserves decoded channel count": "description.isMixdown = false" in binaural_session,
    "semantic source layout never guessed": "resolveInputChannelDescriptions" in binaural_session and "programLayoutMismatch" in binaural_session,
    "native-rate only": "sampleRateMismatch(source:" in binaural_session,
    "binaural bridge pipeline order": binaural_output.index("N60BinauralRendererProcessFrame") < binaural_output.index("N60HeadphoneDSPProcessStereoFrame") < binaural_output.index("N60ProtectionProcessStereoFrame"),
    "content gain upstream of renderer": binaural_output.index("program.channels[channel] *= bridge->programGainLinear") < binaural_output.index("N60BinauralRendererProcessFrame"),
    "crossfeed bypassed for virtual speakers": "spatialMode == .stereo && crossfeed.preset != .off" in profile,
    "normalized asset boundary": "struct BinauralProfileAsset" in asset and "measurements: [BinauralMeasurement]" in asset,
    "native sofa not mislabeled": "nativeSOFAParserUnavailable" in asset and 'pathExtension.lowercased() == "sofa"' in asset,
    "crossfeed profile exposed": "HeadphoneCrossfeedConfiguration" in profile,
    "headroom guard exposed": "conservativeRequiredHeadroomDB" in profile and "insufficientHeadroom" in profile,
}

failed = [name for name, ok in checks.items() if not ok]
if failed:
    raise SystemExit("PR65 validation failed: " + ", ".join(failed))

# Realtime guards: inspect only frame/callback bodies, not control-plane creators.
hp = text("NotchSixty/Audio/Realtime/N60HeadphoneDSP.h")
hp_start = hp.index("static inline bool N60HeadphoneDSPProcessStereoFrame")
hp_body = hp[hp_start:]
for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf(", "fopen(", "pthread_mutex"):
    if forbidden in hp_body:
        raise SystemExit(f"forbidden realtime operation in headphone frame processor: {forbidden}")

for forbidden in ("malloc(", "calloc(", "free(", "printf(", "fprintf(", "fopen(", "pthread_mutex"):
    if forbidden in binaural_output:
        raise SystemExit(f"forbidden realtime operation in binaural output callback: {forbidden}")

print("PR65 headphone + binaural integration validation passed")
