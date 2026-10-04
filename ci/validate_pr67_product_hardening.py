#!/usr/bin/env python3
"""Permanent PR67 guard for product diagnostics, persistence, and acceptance hardening."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
NCHANNEL_CORE = REALTIME / "N60LiveNChannelRenderCore.h"
NCHANNEL_BRIDGE = REALTIME / "N60LiveNChannelBridge.h"
BINAURAL_BRIDGE = REALTIME / "N60BinauralHeadphoneBridge.h"
ENGINE = ROOT / "NotchSixty/Audio/AudioIOEngine.swift"
DIAGNOSTICS = ROOT / "NotchSixty/Diagnostics/AudioDiagnosticsSnapshot.swift"
METERS = ROOT / "NotchSixty/UI/ProductionMetersView.swift"
ROOT_VIEW = ROOT / "NotchSixty/UI/ProductionRootView.swift"
PROFILES = ROOT / "NotchSixty/State/ProductProfiles.swift"
NCHANNEL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioNChannelTransportSession.swift"
BINAURAL_SESSION = ROOT / "NotchSixty/Audio/CoreAudio/CoreAudioBinauralHeadphoneTransportSession.swift"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR67 validation failed: {message}")


def section(text: str, start: str, end: str) -> str:
    require(start in text, f"missing section start: {start}")
    body = text.split(start, 1)[1]
    require(end in body, f"missing section end: {end}")
    return body.split(end, 1)[0]


def main() -> None:
    paths = (
        NCHANNEL_CORE,
        NCHANNEL_BRIDGE,
        BINAURAL_BRIDGE,
        ENGINE,
        DIAGNOSTICS,
        METERS,
        ROOT_VIEW,
        PROFILES,
        NCHANNEL_SESSION,
        BINAURAL_SESSION,
    )
    for path in paths:
        require(path.exists(), f"{path.name} is missing")

    ncore = NCHANNEL_CORE.read_text(encoding="utf-8")
    nbridge = NCHANNEL_BRIDGE.read_text(encoding="utf-8")
    bbridge = BINAURAL_BRIDGE.read_text(encoding="utf-8")
    engine = ENGINE.read_text(encoding="utf-8")
    diagnostics = DIAGNOSTICS.read_text(encoding="utf-8")
    meters = METERS.read_text(encoding="utf-8")
    root_view = ROOT_VIEW.read_text(encoding="utf-8")
    profiles = PROFILES.read_text(encoding="utf-8")
    nsession = NCHANNEL_SESSION.read_text(encoding="utf-8")
    bsession = BINAURAL_SESSION.read_text(encoding="utf-8")

    # Semantic-speaker metering and published latency.
    require("N60LiveNChannelRenderGraphLatencyFrames" in ncore,
            "semantic graph maximum-path latency helper is missing")
    require("N60LiveNChannelMeterSnapshot" in nbridge,
            "semantic program/physical meter snapshot is missing")
    require("N60LiveNChannelBridgeSetMeteringDemand" in nbridge,
            "semantic demand-driven meter control is missing")
    require("meterDemand ? &programMeter : NULL" in nbridge,
            "PR54 lane meter is not demand-routed into the live graph")
    require("physicalSquareSum" in nbridge and "physicalOverRange" in nbridge,
            "final physical-output RMS/over-range accumulation is missing")
    require(".algorithmicLatencyFrames = N60LiveNChannelRenderGraphLatencyFrames" in nbridge,
            "semantic latency is not published in the bridge snapshot")
    require("func setDetailedMeteringDemand(_ enabled: Bool)" in nsession
            and "func bridgeSnapshot() -> N60LiveNChannelBridgeSnapshot?" in nsession,
            "semantic session meter control/snapshot is missing")

    # Virtual-speaker final-output metering and complete path latency.
    require("N60BinauralHeadphoneMeterSnapshot" in bbridge,
            "virtual-speaker headphone meter snapshot is missing")
    require("N60BinauralHeadphoneBridgeSetMeteringDemand" in bbridge,
            "virtual-speaker demand-driven meter control is missing")
    require("correctionDelay" in bbridge
            and "N60ProtectionSnapshotLatencyFrames" in bbridge,
            "virtual-speaker latency does not include headphone/protection delay")
    require("meterSquareLeft" in bbridge and "meterOverLeft" in bbridge,
            "final headphone output RMS/over-range accumulation is missing")
    require("func setDetailedMeteringDemand(_ enabled: Bool)" in bsession
            and "func bridgeSnapshot() -> N60BinauralHeadphoneBridgeSnapshot?" in bsession,
            "binaural session meter control/snapshot is missing")

    # Product-facing model/UI/engine routing.
    require("enum ProductionTransportMeterKind" in diagnostics,
            "product transport meter domain is missing")
    require("struct ProductionTransportMeterSnapshot" in diagnostics,
            "product transport meter snapshot is missing")
    require("func productionTransportMeterSnapshot()" in engine,
            "engine product transport meter projection is missing")
    demand = section(engine, "func setDetailedMeteringDemand(_ enabled: Bool)",
                     "func setAnalysisDemand")
    require("nChannelTransportSession" in demand and "binauralHeadphoneTransportSession" in demand,
            "detailed meter demand is not routed to semantic and binaural sessions")
    require(demand.index("nChannelTransportSession") < demand.index("N60RealtimeAudioBridgeMeteringDemand"),
            "semantic meter routing must precede legacy stereo fallback")
    require("case transport" in meters and "Transport & Recovery" in meters,
            "transport/recovery workspace is missing")
    require("Semantic Program Channels" in meters and "Physical Outputs" in meters,
            "semantic program/physical level UI is missing")
    require("Sub " in engine and "programPhysicalChannels" in engine,
            "physical sub/speaker labeling is missing from the engine projection")
    require("Playback Path" in root_view and "playbackPathSummary" in root_view,
            "dashboard playback-path summary is missing")

    # Persistence remains backward-compatible but contradictory hardware domains fail closed.
    require("static let currentSchemaVersion = 1" in profiles,
            "Playback System schema should remain backward-compatible")
    require("storedSystemTopologyIsValid" in profiles,
            "stored Playback System topology validation is missing")
    require("Self.storedSystemTopologyIsValid($0.state)" in profiles,
            "archive load does not apply topology validation")
    require("outputRouting?.enabled == true, state.outputDeviceProfile?.enabled == true" in profiles,
            "legacy/semantic speaker conflict is not rejected")
    require("outputDeviceProfile?.enabled == true, state.headphoneDeviceProfile?.enabled == true" in profiles,
            "speaker/headphone domain conflict is not rejected")
    require("headTracking.enabled && headphone.spatialMode != .virtualSpeakers" in profiles,
            "invalid persisted head-tracking mode is not rejected")

    # Realtime callback bodies: metering can add arithmetic/atomics, never control-plane work.
    ncallback = section(
        nbridge,
        "static inline OSStatus N60LiveNChannelOutputIOProc",
        "#ifdef __cplusplus",
    )
    bcallback = section(
        bbridge,
        "static inline OSStatus N60BinauralHeadphoneOutputIOProc",
        "#ifdef __cplusplus",
    )
    forbidden = (
        "malloc(", "calloc(", "realloc(", "free(",
        "printf(", "fprintf(", "fopen(", "pthread_mutex",
    )
    for name, body in (("semantic output callback", ncallback), ("binaural output callback", bcallback)):
        for token in forbidden:
            require(token not in body, f"{name} performs forbidden realtime work: {token}")

    # Meter work is demand-gated in both callbacks rather than becoming a permanent CPU tax.
    require("const bool meterDemand" in ncallback and "if (meterDemand)" in ncallback,
            "semantic callback meter work is not demand-gated")
    require("const bool meterDemand" in bcallback and "if (meterDemand)" in bcallback,
            "binaural callback meter work is not demand-gated")

    # Portable compile/runtime sanity for the reused PR54 accumulator and PR67 latency helper.
    clang = shutil.which("clang")
    require(clang is not None, "clang is required")
    harness = r'''
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include "N60LiveNChannelRenderCore.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

int main(void) {
    N60ProgramLaneMeterAccumulator meter = {0};
    N60ProgramLaneMeterAccumulatorReset(&meter, 2u);
    const float first[2] = {1.0f, 0.5f};
    const float second[2] = {0.0f, -0.5f};
    N60ProgramLaneMeterAccumulatorAccumulate(&meter, first);
    N60ProgramLaneMeterAccumulatorAccumulate(&meter, second);
    N60ProgramLaneMeterReading reading = N60ProgramLaneMeterAccumulatorReading(&meter);
    assert(reading.channelCount == 2u);
    closef(reading.peak[0], 1.0f, 1.0e-6f);
    closef(reading.peak[1], 0.5f, 1.0e-6f);
    closef(reading.rms[0], 0.70710678f, 1.0e-6f);
    closef(reading.rms[1], 0.5f, 1.0e-6f);

    assert(N60LiveNChannelRenderGraphLatencyFrames(NULL) == 0u);
    N60LiveNChannelRenderGraph invalid = {0};
    assert(N60LiveNChannelRenderGraphLatencyFrames(&invalid) == 0u);
    return 0;
}
'''
    with tempfile.TemporaryDirectory() as directory:
        directory = pathlib.Path(directory)
        source = directory / "pr67.c"
        binary = directory / "pr67"
        source.write_text(harness, encoding="utf-8")
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

    print("PR67 product hardening validation passed")


if __name__ == "__main__":
    main()
