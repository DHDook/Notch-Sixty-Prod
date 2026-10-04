#!/usr/bin/env python3
"""Permanent PR59 guard for head tracking, MIMO, linked dynamics and downmix."""

from __future__ import annotations

import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
REALTIME = ROOT / "NotchSixty/Audio/Realtime"
HEAD = REALTIME / "N60HeadTracking.h"
MIMO = REALTIME / "N60MIMOCorrection.h"
LINKED = REALTIME / "N60LinkedDynamics.h"
DOWNMIX = REALTIME / "N60Downmix.h"
BRIDGE = REALTIME / "NotchSixty-Bridging-Header.h"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"PR59 validation failed: {message}")


def main() -> None:
    for path in (HEAD, MIMO, LINKED, DOWNMIX, BRIDGE):
        require(path.exists(), f"{path.name} is missing")

    head = HEAD.read_text(encoding="utf-8")
    mimo = MIMO.read_text(encoding="utf-8")
    linked = LINKED.read_text(encoding="utf-8")
    downmix = DOWNMIX.read_text(encoding="utf-8")
    bridge = BRIDGE.read_text(encoding="utf-8")

    require("_Atomic uint64_t packedPose" in head, "single-snapshot atomic head pose is missing")
    require("one atomic load, no retry loop" in head, "realtime pose-read contract is missing")
    require("N60BinauralProfileDescriptorApplyHeadPose" in head, "head-relative scene transform is missing")
    require("N60SpatialCrossfadeProcessStereo" in head, "prepared-generation crossfade is missing")
    require("Hᴴ W H + λI" in mimo, "regularized least-squares MIMO contract is missing")
    require("targetSafetyScale" in mimo, "MIMO matrix safety scaling is missing")
    require("N60LinkedDynamicsLinkMapMakeSemanticDefaults" in linked, "semantic linked-dynamics defaults are missing")
    require("exactly the same gain" in linked, "image-preserving linked gain contract is missing")
    require("recommendedPreampDB" in downmix, "downmix headroom contract is missing")
    require("N60DownmixLFEFoldToFronts" in downmix, "explicit LFE downmix policy is missing")

    for header in (
        "N60HeadTracking.h",
        "N60MIMOCorrection.h",
        "N60LinkedDynamics.h",
        "N60Downmix.h",
    ):
        require(f'#import "{header}"' in bridge, f"{header} is not exposed to Swift")

    pose_load = head.split("static inline N60HeadPose N60HeadPoseAtomicLoad", 1)[1]
    pose_load = pose_load.split("static inline double N60HeadPoseAngularDeltaDegrees", 1)[0]
    require("while (" not in pose_load and "for (" not in pose_load, "realtime pose load has a retry loop")
    crossfade = head.split("static inline void N60SpatialCrossfadeProcessStereo", 1)[1]
    crossfade = crossfade.split("#ifdef __cplusplus", 1)[0]
    require("malloc(" not in crossfade and "calloc(" not in crossfade and "cos(" not in crossfade,
            "realtime crossfade performs forbidden work")

    clang = shutil.which("clang")
    require(clang is not None, "clang is required")

    harness = r'''
#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <string.h>
#include "N60HeadTracking.h"
#include "N60MIMOCorrection.h"
#include "N60LinkedDynamics.h"
#include "N60Downmix.h"

static void closef(float actual, float expected, float tolerance) {
    assert(fabsf(actual - expected) <= tolerance);
}

static void closed(double actual, double expected, double tolerance) {
    assert(fabs(actual - expected) <= tolerance);
}

int main(void) {
    // One packed atomic publishes a coherent yaw/pitch/roll tuple.
    N60HeadPoseAtomic atomicPose;
    N60HeadPoseAtomicInitialize(&atomicPose, (N60HeadPose){0});
    assert(N60HeadPoseAtomicIsLockFree(&atomicPose));
    N60HeadPose pose = {.yawDegrees = 30.123, .pitchDegrees = -12.5, .rollDegrees = 4.25};
    assert(N60HeadPoseAtomicPublish(&atomicPose, pose));
    N60HeadPose loaded = N60HeadPoseAtomicLoad(&atomicPose);
    closed(loaded.yawDegrees, 30.123, 0.0011);
    closed(loaded.pitchDegrees, -12.5, 0.0011);
    closed(loaded.rollDegrees, 4.25, 0.0011);
    assert(!N60HeadPoseAtomicPublish(&atomicPose, (N60HeadPose){.yawDegrees = 181.0}));

    // Turning the head +30° makes the +30° front-right virtual speaker head-relative center.
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor world =
        N60BinauralProfileDescriptorMake(48000.0, stereo, N60BinauralProfileKindHRTF, 1u);
    N60BinauralProfileDescriptor relative = {0};
    assert(N60BinauralProfileDescriptorApplyHeadPose(
        &world,
        (N60HeadPose){.yawDegrees = 30.0, .pitchDegrees = 0.0, .rollDegrees = 0.0},
        &relative));
    closed(relative.sources[1].azimuthDegrees, 0.0, 1.0e-6);
    closed(relative.sources[0].azimuthDegrees, -60.0, 1.0e-6);

    // Smoothstep crossfade starts on the old generation and lands exactly on new.
    N60SpatialCrossfade fade = {0};
    assert(N60SpatialCrossfadeStart(&fade, 4u));
    float outL = 0.0f, outR = 0.0f;
    N60SpatialCrossfadeProcessStereo(&fade, 1.0f, -1.0f, 0.0f, 0.5f, &outL, &outR);
    closef(outL, 1.0f, 1.0e-7f);
    closef(outR, -1.0f, 1.0e-7f);
    for (uint32_t frame = 1u; frame < 4u; ++frame) {
        N60SpatialCrossfadeProcessStereo(&fade, 1.0f, -1.0f, 0.0f, 0.5f, &outL, &outR);
    }
    assert(!fade.active);
    closef(outL, 0.0f, 1.0e-7f);
    closef(outR, 0.5f, 1.0e-7f);

    // Regularized MIMO solves a mildly cross-coupled 2x2 system toward identity.
    N60MIMOTransferSet transfer = {0};
    transfer.sourceCount = 2u;
    transfer.measurementCount = 2u;
    transfer.frequencyCount = 1u;
    transfer.sampleRate = 48000.0;
    transfer.frequenciesHz[0] = 1000.0f;
    transfer.measurementWeights[0] = 1.0f;
    transfer.measurementWeights[1] = 1.0f;
    transfer.measured[N60MIMOMeasuredOffset(0u, 0u, 0u)] = (N60MIMOComplex){1.0, 0.0};
    transfer.measured[N60MIMOMeasuredOffset(0u, 0u, 1u)] = (N60MIMOComplex){0.2, 0.0};
    transfer.measured[N60MIMOMeasuredOffset(0u, 1u, 0u)] = (N60MIMOComplex){0.1, 0.0};
    transfer.measured[N60MIMOMeasuredOffset(0u, 1u, 1u)] = (N60MIMOComplex){1.0, 0.0};
    assert(N60MIMOTransferSetIsValid(&transfer));

    N60MIMOComplex desired[N60_MIMO_MAX_FREQUENCY_BINS * N60_MIMO_MAX_MEASUREMENTS * N60_MIMO_MAX_SOURCES] = {0};
    desired[(0u * N60_MIMO_MAX_MEASUREMENTS + 0u) * N60_MIMO_MAX_SOURCES + 0u] = (N60MIMOComplex){1.0, 0.0};
    desired[(0u * N60_MIMO_MAX_MEASUREMENTS + 1u) * N60_MIMO_MAX_SOURCES + 1u] = (N60MIMOComplex){1.0, 0.0};
    N60MIMODesignSettings mimoSettings = N60MIMODesignSettingsMakeDefault();
    mimoSettings.regularization = 1.0e-5;
    mimoSettings.maximumCoefficientGainDB = 12.0;
    N60MIMOCorrectionDesign mimoDesign = {0};
    assert(N60MIMODesignRegularizedCorrection(&transfer, desired, mimoSettings, &mimoDesign));
    assert(mimoDesign.weightedResidualPower[0] < 1.0e-5);
    for (uint32_t target = 0; target < 2u; ++target) {
        assert(mimoDesign.targetSafetyScale[0][target] > 0.0f);
        assert(mimoDesign.targetSafetyScale[0][target] <= 1.0f);
        for (uint32_t source = 0; source < 2u; ++source) {
            N60MIMOComplex c = mimoDesign.correction[N60MIMOCorrectionOffset(0u, source, target)];
            assert(isfinite(c.real) && isfinite(c.imaginary));
        }
    }

    // A singular transfer remains bounded/finite because regularization is mandatory.
    for (uint32_t measurement = 0; measurement < 2u; ++measurement) {
        for (uint32_t source = 0; source < 2u; ++source) {
            transfer.measured[N60MIMOMeasuredOffset(0u, measurement, source)] = (N60MIMOComplex){1.0, 0.0};
        }
    }
    mimoSettings.regularization = 0.1;
    mimoSettings.maximumCoefficientGainDB = 0.0;
    assert(N60MIMODesignRegularizedCorrection(&transfer, desired, mimoSettings, &mimoDesign));
    for (uint32_t target = 0; target < 2u; ++target) {
        for (uint32_t source = 0; source < 2u; ++source) {
            N60MIMOComplex c = mimoDesign.correction[N60MIMOCorrectionOffset(0u, source, target)];
            assert(isfinite(c.real) && isfinite(c.imaginary));
            assert(sqrt(N60MIMOComplexPower(c)) <= 1.000001);
        }
    }

    // Semantic detector links preserve level ratio/image within a speaker pair.
    N60ProgramChannelLayout sevenOneFour =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOneFour);
    N60LinkedDynamicsLinkMap linkMap = {0};
    assert(N60LinkedDynamicsLinkMapMakeSemanticDefaults(sevenOneFour, &linkMap));
    const int32_t fl = N60ProgramChannelLayoutIndexOfRole(&sevenOneFour, N60ProgramChannelRoleFrontLeft);
    const int32_t fr = N60ProgramChannelLayoutIndexOfRole(&sevenOneFour, N60ProgramChannelRoleFrontRight);
    const int32_t center = N60ProgramChannelLayoutIndexOfRole(&sevenOneFour, N60ProgramChannelRoleFrontCenter);
    assert(fl >= 0 && fr >= 0 && center >= 0);
    assert(linkMap.groupForChannel[(uint32_t)fl] == linkMap.groupForChannel[(uint32_t)fr]);
    assert(linkMap.groupForChannel[(uint32_t)center] != linkMap.groupForChannel[(uint32_t)fl]);

    float multichannel[N60_MAX_PROGRAM_CHANNELS] = {0};
    multichannel[(uint32_t)fl] = 1.0f;
    multichannel[(uint32_t)fr] = 0.25f;
    float detectors[N60_LINKED_DYNAMICS_MAX_GROUPS] = {0};
    assert(N60LinkedDynamicsMeasureFrame(&linkMap, multichannel, detectors));
    const uint32_t frontGroup = (uint32_t)linkMap.groupForChannel[(uint32_t)fl];
    closef(detectors[frontGroup], 1.0f, 1.0e-7f);
    float groupGain[N60_LINKED_DYNAMICS_MAX_GROUPS];
    for (uint32_t group = 0; group < linkMap.groupCount; ++group) groupGain[group] = 1.0f;
    groupGain[frontGroup] = 0.5f;
    float linkedOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    assert(N60LinkedDynamicsApplyGroupGains(&linkMap, multichannel, groupGain, linkedOutput));
    closef(linkedOutput[(uint32_t)fl], 0.5f, 1.0e-7f);
    closef(linkedOutput[(uint32_t)fr], 0.125f, 1.0e-7f);
    closef(linkedOutput[(uint32_t)fl] / linkedOutput[(uint32_t)fr], 4.0f, 1.0e-6f);

    // RMS detector mode is also deterministic.
    N60LinkedDynamicsGroup stereoGroup = {
        .channelMask = 0x3u,
        .detectorMode = N60LinkedDynamicsDetectorRMS,
    };
    N60LinkedDynamicsLinkMap stereoLinks = {0};
    assert(N60LinkedDynamicsLinkMapMake(stereo, &stereoGroup, 1u, &stereoLinks));
    float stereoFrame[2] = {1.0f, 0.0f};
    float stereoDetector[1] = {0};
    assert(N60LinkedDynamicsMeasureFrame(&stereoLinks, stereoFrame, stereoDetector));
    closef(stereoDetector[0], 0.70710678f, 1.0e-6f);

    // Explicit 7.1.4 -> 5.1 downmix retains semantic direct channels and folds heights/rears.
    N60ProgramChannelLayout fiveOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60DownmixPlan downmix = {0};
    assert(N60DownmixCompile(sevenOneFour, fiveOne, N60DownmixLFEDrop, &downmix));
    assert(downmix.recommendedPreampDB < 0.0f);
    float surroundInput[N60_MAX_PROGRAM_CHANNELS] = {0};
    float surroundOutput[N60_MAX_PROGRAM_CHANNELS] = {0};
    const int32_t topFrontLeft = N60ProgramChannelLayoutIndexOfRole(&sevenOneFour, N60ProgramChannelRoleTopFrontLeft);
    const int32_t fiveFrontLeft = N60ProgramChannelLayoutIndexOfRole(&fiveOne, N60ProgramChannelRoleFrontLeft);
    assert(topFrontLeft >= 0 && fiveFrontLeft >= 0);
    surroundInput[(uint32_t)topFrontLeft] = 1.0f;
    assert(N60ChannelRoutingMatrixProcessFrame(&downmix.matrix, surroundInput, surroundOutput));
    closef(surroundOutput[(uint32_t)fiveFrontLeft], 0.70710678f, 1.0e-6f);

    // 5.1 -> stereo center fold and explicit LFE drop/fold behavior.
    N60DownmixPlan stereoDrop = {0};
    assert(N60DownmixCompile(fiveOne, stereo, N60DownmixLFEDrop, &stereoDrop));
    memset(surroundInput, 0, sizeof(surroundInput));
    memset(surroundOutput, 0, sizeof(surroundOutput));
    const int32_t fiveCenter = N60ProgramChannelLayoutIndexOfRole(&fiveOne, N60ProgramChannelRoleFrontCenter);
    const int32_t fiveLFE = N60ProgramChannelLayoutIndexOfRole(&fiveOne, N60ProgramChannelRoleLowFrequencyEffects);
    surroundInput[(uint32_t)fiveCenter] = 1.0f;
    assert(N60ChannelRoutingMatrixProcessFrame(&stereoDrop.matrix, surroundInput, surroundOutput));
    closef(surroundOutput[0], 0.70710678f, 1.0e-6f);
    closef(surroundOutput[1], 0.70710678f, 1.0e-6f);
    memset(surroundInput, 0, sizeof(surroundInput));
    memset(surroundOutput, 0, sizeof(surroundOutput));
    surroundInput[(uint32_t)fiveLFE] = 1.0f;
    assert(N60ChannelRoutingMatrixProcessFrame(&stereoDrop.matrix, surroundInput, surroundOutput));
    closef(surroundOutput[0], 0.0f, 1.0e-7f);
    closef(surroundOutput[1], 0.0f, 1.0e-7f);

    N60DownmixPlan stereoFold = {0};
    assert(N60DownmixCompile(fiveOne, stereo, N60DownmixLFEFoldToFronts, &stereoFold));
    assert(stereoFold.lfeFolded);
    memset(surroundOutput, 0, sizeof(surroundOutput));
    assert(N60ChannelRoutingMatrixProcessFrame(&stereoFold.matrix, surroundInput, surroundOutput));
    closef(surroundOutput[0], 0.5f, 1.0e-7f);
    closef(surroundOutput[1], 0.5f, 1.0e-7f);

    return 0;
}
'''

    with tempfile.TemporaryDirectory(prefix="notch-sixty-pr59-") as temporary:
        temp = pathlib.Path(temporary)
        source = temp / "advanced_spatial_test.c"
        binary = temp / "advanced_spatial_test"
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

    print("PR59 advanced spatial validation passed")


if __name__ == "__main__":
    main()
