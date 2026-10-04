#!/usr/bin/env python3
"""Permanent PR63 guard for fail-closed live N-channel product activation."""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
PROJECT = ROOT / "NotchSixty.xcodeproj/project.pbxproj"
BRIDGE = ROOT / "NotchSixty/Audio/Realtime/N60LiveNChannelBridge.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR63 activation validation failed: {message}")


def ordered(text: str, *needles: str) -> bool:
    cursor = -1
    for needle in needles:
        cursor = text.find(needle, cursor + 1)
        if cursor < 0:
            return False
    return True


def main() -> None:
    for path in (ENGINE, SESSION, PROFILES, PROJECT, BRIDGE):
        require(path.exists(), f"{path.name} is missing")

    engine = ENGINE.read_text(encoding="utf-8")
    session = SESSION.read_text(encoding="utf-8")
    profiles = PROFILES.read_text(encoding="utf-8")
    project = PROJECT.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("private var nChannelTransportSession: CoreAudioNChannelTransportSession?" in engine,
            "AudioIOEngine does not own the N-channel session")
    require("@Published private(set) var outputDeviceProfileConfiguration" in engine,
            "AudioIOEngine does not own the active Output Device Profile")
    require("var liveNChannelActive: Bool" in engine,
            "engine does not expose active transport mode")
    require("func replaceOutputDeviceProfileConfiguration" in engine,
            "engine cannot install persisted semantic profiles")
    require("configurationChangeRequiresRestart" in engine,
            "immutable N-channel graph mutations are not restart-gated")

    require(ordered(
        engine,
        "private func buildTransport(output: AudioOutputDevice)",
        "if outputDeviceProfileConfiguration?.enabled == true",
        "try buildNChannelTransport(output: output)",
        "try buildStereoTransport(output: output)",
    ), "transport selector does not fail closed to the legacy stereo path")
    require("private func validateLiveNChannelActivation()" in engine,
            "preflight activation validation is missing")
    for feature in (
        "legacy per-driver speaker processing",
        "stereo EQ",
        "stereo playback/image controls",
        "stereo dynamics/protection",
        "legacy stereo room correction",
        "legacy stereo Speaker IR",
        "legacy physical crossover routing",
        "legacy single-sub phase alignment",
        "stereo crossover monitor audition",
    ):
        require(feature in engine, f"unsupported active DSP is not rejected: {feature}")

    require(ordered(
        engine,
        "private func buildNChannelTransport(output: AudioOutputDevice)",
        "profile.makeLivePlan(",
        "LiveNChannelRenderGraphCompiler.makeGraph(",
        "CoreAudioNChannelTransportSession(",
        "nChannelTransportSession = session",
    ), "N-channel control-plane compile/start sequence is incomplete")
    require("session.setOutputGain(newSoftwareGain)" in engine,
            "master-volume changes do not reach the live N-channel bridge")
    require("session.setOutputGain(newGain)" in engine,
            "external device/master-volume synchronization misses N-channel mode")
    require("if let session = nChannelTransportSession" in engine
            and "nChannelTransportSession = nil" in engine,
            "N-channel session is not torn down and accounted")
    require("nChannelTransportSession?.counters()" in engine,
            "N-channel diagnostics counters are not surfaced")
    require("nChannelTransportSession?.tapFormat.sampleRate" in engine
            and "nChannelTransportSession?.outputFormat.sampleRate" in engine,
            "N-channel active sample-rate diagnostics are missing")

    require("final class CoreAudioNChannelTransportSession" in session,
            "dedicated N-channel Core Audio owner is missing")
    require("description.isMixdown = false" in session and "description.isMono = false" in session,
            "process tap is not preserving multichannel program content")
    require("resolveInputChannelDescriptions" in session and "N60ProgramInputMapCompile" in session,
            "semantic input mapping is not explicit")
    require("inputChannelLayoutUnavailable" in session,
            "ambiguous multichannel input order does not fail closed")
    require("N60LiveNChannelBridgeCreate" in session,
            "PR61 live bridge is not the active N-channel realtime boundary")
    require("N60LiveNChannelCaptureIOProc" in session and "N60LiveNChannelOutputIOProc" in session,
            "N-channel Core Audio callbacks are not using the PR61 bridge")

    require("CoreAudioNChannelTransportSession.swift in Sources" in project,
            "N-channel transport session is not an app-target source")
    require("outputDeviceProfile: engine.outputDeviceProfileConfiguration" in profiles,
            "Playback System capture is not sourced from engine state")
    require("try engine.replaceOutputDeviceProfileConfiguration(configuration)" in profiles,
            "profile edits are not installed into the engine")
    require(ordered(
        profiles,
        "let playback = state.playback.applying(to: engine.playbackControlConfiguration)",
        "try engine.replaceOutputDeviceProfileConfiguration(nil)",
        "try engine.replaceBassManagementConfiguration(state.bassManagement)",
        "try engine.replaceOutputDeviceProfileConfiguration(state.outputDeviceProfile)",
    ), "Playback System application does not clear old profile before bass/profile switch")
    require(ordered(
        profiles,
        "let playback = previous.playback.applying(to: engine.playbackControlConfiguration)",
        "try? engine.replaceOutputDeviceProfileConfiguration(nil)",
        "try? engine.replaceBassManagementConfiguration(previous.bassManagement)",
        "try? engine.replaceOutputDeviceProfileConfiguration(previous.outputDeviceProfile)",
    ), "Playback System rollback ordering is not transactional")

    # Realtime callbacks remain C-only bounded primitives. The bridge implementation
    # must not introduce allocation/locking/logging calls in the per-frame entry points.
    require("N60LiveNChannelCaptureIOProc" in bridge and "N60LiveNChannelOutputIOProc" in bridge,
            "live bridge callbacks are missing")
    for banned in ("printf(", "fprintf(", "NSLog", "pthread_mutex", "dispatch_sync"):
        require(banned not in bridge, f"realtime bridge contains banned callback primitive: {banned}")

    require(not (ROOT / "ci/apply_pr63_engine_activation.py").exists(),
            "one-shot engine patch helper was not removed")
    require(not (ROOT / "ci/apply_pr63_profile_ordering.py").exists(),
            "one-shot profile patch helper was not removed")
    require(not (ROOT / ".github/workflows/pr63-apply-engine-activation.yml").exists(),
            "one-shot engine workflow was not removed")
    require(not (ROOT / ".github/workflows/pr63-apply-profile-ordering.yml").exists(),
            "one-shot profile workflow was not removed")

    print("PR63 live N-channel activation architecture validation passed")


if __name__ == "__main__":
    main()
