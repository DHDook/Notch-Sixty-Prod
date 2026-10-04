#ifndef N60LinkedDynamics_h
#define N60LinkedDynamics_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_LINKED_DYNAMICS_MAX_GROUPS N60_MAX_PROGRAM_CHANNELS

typedef enum {
    N60LinkedDynamicsDetectorPeak = 0,
    N60LinkedDynamicsDetectorRMS = 1,
} N60LinkedDynamicsDetectorMode;

typedef struct {
    uint32_t channelMask;
    N60LinkedDynamicsDetectorMode detectorMode;
} N60LinkedDynamicsGroup;

typedef struct {
    N60ProgramChannelLayout layout;
    uint32_t groupCount;
    N60LinkedDynamicsGroup groups[N60_LINKED_DYNAMICS_MAX_GROUPS];
    int8_t groupForChannel[N60_MAX_PROGRAM_CHANNELS];
} N60LinkedDynamicsLinkMap;

static inline bool N60LinkedDynamicsGroupIsValid(
    N60LinkedDynamicsGroup group,
    uint32_t channelCount
) {
    if (channelCount == 0u || channelCount > N60_MAX_PROGRAM_CHANNELS) return false;
    if (group.channelMask == 0u
        || group.detectorMode < N60LinkedDynamicsDetectorPeak
        || group.detectorMode > N60LinkedDynamicsDetectorRMS) {
        return false;
    }
    const uint32_t validMask = channelCount == 32u
        ? UINT32_MAX
        : ((1u << channelCount) - 1u);
    return (group.channelMask & ~validMask) == 0u;
}

static inline bool N60LinkedDynamicsLinkMapMake(
    N60ProgramChannelLayout layout,
    const N60LinkedDynamicsGroup * _Nonnull groups,
    uint32_t groupCount,
    N60LinkedDynamicsLinkMap * _Nonnull mapOut
) {
    if (groups == NULL
        || mapOut == NULL
        || !N60ProgramChannelLayoutIsValid(&layout)
        || groupCount == 0u
        || groupCount > N60_LINKED_DYNAMICS_MAX_GROUPS) {
        return false;
    }
    N60LinkedDynamicsLinkMap result = {0};
    result.layout = layout;
    result.groupCount = groupCount;
    for (uint32_t channel = 0; channel < N60_MAX_PROGRAM_CHANNELS; ++channel) {
        result.groupForChannel[channel] = -1;
    }

    uint32_t assignedMask = 0u;
    for (uint32_t group = 0; group < groupCount; ++group) {
        if (!N60LinkedDynamicsGroupIsValid(groups[group], layout.channelCount)
            || (assignedMask & groups[group].channelMask) != 0u) {
            return false;
        }
        result.groups[group] = groups[group];
        assignedMask |= groups[group].channelMask;
        for (uint32_t channel = 0; channel < layout.channelCount; ++channel) {
            if ((groups[group].channelMask & (1u << channel)) != 0u) {
                result.groupForChannel[channel] = (int8_t)group;
            }
        }
    }
    *mapOut = result;
    return true;
}

static inline bool N60LinkedDynamicsAppendRolePairOrSingles(
    const N60ProgramChannelLayout * _Nonnull layout,
    N60ProgramChannelRole leftRole,
    N60ProgramChannelRole rightRole,
    N60LinkedDynamicsGroup * _Nonnull groups,
    uint32_t * _Nonnull count
) {
    const int32_t left = N60ProgramChannelLayoutIndexOfRole(layout, leftRole);
    const int32_t right = N60ProgramChannelLayoutIndexOfRole(layout, rightRole);
    if (left < 0 && right < 0) return true;
    if (*count >= N60_LINKED_DYNAMICS_MAX_GROUPS) return false;
    uint32_t mask = 0u;
    if (left >= 0) mask |= 1u << (uint32_t)left;
    if (right >= 0) mask |= 1u << (uint32_t)right;
    groups[*count] = (N60LinkedDynamicsGroup){
        .channelMask = mask,
        .detectorMode = N60LinkedDynamicsDetectorPeak,
    };
    *count += 1u;
    return true;
}

static inline bool N60LinkedDynamicsAppendSingletonRole(
    const N60ProgramChannelLayout * _Nonnull layout,
    N60ProgramChannelRole role,
    N60LinkedDynamicsGroup * _Nonnull groups,
    uint32_t * _Nonnull count
) {
    const int32_t index = N60ProgramChannelLayoutIndexOfRole(layout, role);
    if (index < 0) return true;
    if (*count >= N60_LINKED_DYNAMICS_MAX_GROUPS) return false;
    groups[*count] = (N60LinkedDynamicsGroup){
        .channelMask = 1u << (uint32_t)index,
        .detectorMode = N60LinkedDynamicsDetectorPeak,
    };
    *count += 1u;
    return true;
}

/// Conservative semantic defaults: stereo pairs share one detector/gain value,
/// while Center and native LFE remain independent. This preserves image motion
/// within symmetric speaker pairs and never links LFE to redirected bass/subs.
static inline bool N60LinkedDynamicsLinkMapMakeSemanticDefaults(
    N60ProgramChannelLayout layout,
    N60LinkedDynamicsLinkMap * _Nonnull mapOut
) {
    if (mapOut == NULL || !N60ProgramChannelLayoutIsValid(&layout)) return false;
    N60LinkedDynamicsGroup groups[N60_LINKED_DYNAMICS_MAX_GROUPS] = {0};
    uint32_t count = 0u;
    if (!N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleFrontLeft, N60ProgramChannelRoleFrontRight, groups, &count)
        || !N60LinkedDynamicsAppendSingletonRole(&layout, N60ProgramChannelRoleFrontCenter, groups, &count)
        || !N60LinkedDynamicsAppendSingletonRole(&layout, N60ProgramChannelRoleLowFrequencyEffects, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleSideLeft, N60ProgramChannelRoleSideRight, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleRearLeft, N60ProgramChannelRoleRearRight, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleWideLeft, N60ProgramChannelRoleWideRight, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleTopFrontLeft, N60ProgramChannelRoleTopFrontRight, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleTopMiddleLeft, N60ProgramChannelRoleTopMiddleRight, groups, &count)
        || !N60LinkedDynamicsAppendRolePairOrSingles(&layout, N60ProgramChannelRoleTopRearLeft, N60ProgramChannelRoleTopRearRight, groups, &count)) {
        return false;
    }
    return count > 0u && N60LinkedDynamicsLinkMapMake(layout, groups, count, mapOut);
}

/// Realtime-safe detector extraction. Envelope timing and compressor/limiter gain
/// computation remain owned by the existing dynamics engine; this primitive only
/// defines which channels share the detector signal.
static inline bool N60LinkedDynamicsMeasureFrame(
    const N60LinkedDynamicsLinkMap * _Nonnull map,
    const float * _Nonnull input,
    float * _Nonnull groupDetectorOut
) {
    if (map == NULL
        || input == NULL
        || groupDetectorOut == NULL
        || !N60ProgramChannelLayoutIsValid(&map->layout)
        || map->groupCount == 0u
        || map->groupCount > N60_LINKED_DYNAMICS_MAX_GROUPS) {
        return false;
    }
    for (uint32_t group = 0; group < map->groupCount; ++group) {
        float peak = 0.0f;
        double sumSquares = 0.0;
        uint32_t count = 0u;
        for (uint32_t channel = 0; channel < map->layout.channelCount; ++channel) {
            if ((map->groups[group].channelMask & (1u << channel)) == 0u) continue;
            const float sample = isfinite(input[channel]) ? input[channel] : 0.0f;
            const float absolute = fabsf(sample);
            if (absolute > peak) peak = absolute;
            sumSquares += (double)sample * (double)sample;
            count += 1u;
        }
        if (count == 0u) return false;
        groupDetectorOut[group] = map->groups[group].detectorMode == N60LinkedDynamicsDetectorRMS
            ? (float)sqrt(sumSquares / (double)count)
            : peak;
    }
    return true;
}

/// Applies one already-computed linear gain per linked detector group. Channels
/// outside a configured group pass at unity. Every channel in a group receives
/// exactly the same gain, preserving the pair/group image.
static inline bool N60LinkedDynamicsApplyGroupGains(
    const N60LinkedDynamicsLinkMap * _Nonnull map,
    const float * _Nonnull input,
    const float * _Nonnull groupGainLinear,
    float * _Nonnull output
) {
    if (map == NULL || input == NULL || groupGainLinear == NULL || output == NULL) return false;
    for (uint32_t group = 0; group < map->groupCount; ++group) {
        if (!isfinite(groupGainLinear[group]) || groupGainLinear[group] < 0.0f || groupGainLinear[group] > 4.0f) {
            return false;
        }
    }
    for (uint32_t channel = 0; channel < map->layout.channelCount; ++channel) {
        const float sample = isfinite(input[channel]) ? input[channel] : 0.0f;
        const int8_t group = map->groupForChannel[channel];
        output[channel] = group >= 0
            ? sample * groupGainLinear[(uint32_t)group]
            : sample;
    }
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
