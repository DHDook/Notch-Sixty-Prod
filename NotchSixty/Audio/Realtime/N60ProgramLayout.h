#ifndef N60ProgramLayout_h
#define N60ProgramLayout_h

#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Maximum semantic program-channel count supported by the post-v1 architecture.
/// The realtime representation remains fixed-size/allocation-free while leaving
/// substantial room beyond the currently named 9.1.6 standard layout.
#define N60_MAX_PROGRAM_CHANNELS 32u

/// Stable semantic identities for program channels. These are intentionally
/// independent of Core Audio stream order and physical output channel numbers.
/// Custom1...Custom16 are stable manually-assigned identities for future/custom
/// layouts; automatic Core Audio label mapping must never infer them.
typedef enum {
    N60ProgramChannelRoleUnused = 0,
    N60ProgramChannelRoleFrontLeft,
    N60ProgramChannelRoleFrontRight,
    N60ProgramChannelRoleFrontCenter,
    N60ProgramChannelRoleLowFrequencyEffects,
    N60ProgramChannelRoleSideLeft,
    N60ProgramChannelRoleSideRight,
    N60ProgramChannelRoleRearLeft,
    N60ProgramChannelRoleRearRight,
    N60ProgramChannelRoleWideLeft,
    N60ProgramChannelRoleWideRight,
    N60ProgramChannelRoleTopFrontLeft,
    N60ProgramChannelRoleTopFrontRight,
    N60ProgramChannelRoleTopMiddleLeft,
    N60ProgramChannelRoleTopMiddleRight,
    N60ProgramChannelRoleTopRearLeft,
    N60ProgramChannelRoleTopRearRight,
    N60ProgramChannelRoleCustom1,
    N60ProgramChannelRoleCustom2,
    N60ProgramChannelRoleCustom3,
    N60ProgramChannelRoleCustom4,
    N60ProgramChannelRoleCustom5,
    N60ProgramChannelRoleCustom6,
    N60ProgramChannelRoleCustom7,
    N60ProgramChannelRoleCustom8,
    N60ProgramChannelRoleCustom9,
    N60ProgramChannelRoleCustom10,
    N60ProgramChannelRoleCustom11,
    N60ProgramChannelRoleCustom12,
    N60ProgramChannelRoleCustom13,
    N60ProgramChannelRoleCustom14,
    N60ProgramChannelRoleCustom15,
    N60ProgramChannelRoleCustom16,
} N60ProgramChannelRole;

/// Canonical internal layouts. A custom layout remains available for future
/// layouts without changing the fixed realtime representation.
typedef enum {
    N60ProgramLayoutCustom = 0,
    N60ProgramLayoutStereo,
    N60ProgramLayoutFiveOne,
    N60ProgramLayoutSevenOne,
    N60ProgramLayoutFiveOneTwo,
    N60ProgramLayoutFiveOneFour,
    N60ProgramLayoutSevenOneFour,
    N60ProgramLayoutNineOneSix,
} N60ProgramLayoutIdentifier;

typedef struct {
    N60ProgramLayoutIdentifier identifier;
    uint32_t channelCount;
    N60ProgramChannelRole channels[N60_MAX_PROGRAM_CHANNELS];
} N60ProgramChannelLayout;

static inline bool N60ProgramChannelRoleIsSemantic(N60ProgramChannelRole role) {
    return role > N60ProgramChannelRoleUnused && role <= N60ProgramChannelRoleCustom16;
}

static inline bool N60ProgramChannelRoleIsNamedSpeaker(N60ProgramChannelRole role) {
    return role > N60ProgramChannelRoleUnused && role <= N60ProgramChannelRoleTopRearRight;
}

static inline bool N60ProgramChannelRoleIsCustom(N60ProgramChannelRole role) {
    return role >= N60ProgramChannelRoleCustom1 && role <= N60ProgramChannelRoleCustom16;
}

static inline N60ProgramChannelLayout N60ProgramChannelLayoutMakeCustom(
    const N60ProgramChannelRole * _Nullable roles,
    uint32_t channelCount
) {
    N60ProgramChannelLayout layout = {0};
    layout.identifier = N60ProgramLayoutCustom;
    if (roles == NULL || channelCount == 0u || channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return layout;
    }
    layout.channelCount = channelCount;
    for (uint32_t index = 0; index < channelCount; ++index) {
        layout.channels[index] = roles[index];
    }
    return layout;
}

/// Internal canonical order is semantic and explicit; it must never be assumed
/// to equal a device's Core Audio stream order. The router performs that mapping
/// explicitly from channel labels/layout metadata.
static inline N60ProgramChannelLayout N60ProgramChannelLayoutMakeStandard(
    N60ProgramLayoutIdentifier identifier
) {
    N60ProgramChannelLayout layout = {0};
    layout.identifier = identifier;

    switch (identifier) {
        case N60ProgramLayoutStereo:
            layout.channelCount = 2u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            break;

        case N60ProgramLayoutFiveOne:
            layout.channelCount = 6u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            break;

        case N60ProgramLayoutSevenOne:
            layout.channelCount = 8u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            layout.channels[6] = N60ProgramChannelRoleRearLeft;
            layout.channels[7] = N60ProgramChannelRoleRearRight;
            break;

        case N60ProgramLayoutFiveOneTwo:
            layout.channelCount = 8u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            layout.channels[6] = N60ProgramChannelRoleTopMiddleLeft;
            layout.channels[7] = N60ProgramChannelRoleTopMiddleRight;
            break;

        case N60ProgramLayoutFiveOneFour:
            layout.channelCount = 10u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            layout.channels[6] = N60ProgramChannelRoleTopFrontLeft;
            layout.channels[7] = N60ProgramChannelRoleTopFrontRight;
            layout.channels[8] = N60ProgramChannelRoleTopRearLeft;
            layout.channels[9] = N60ProgramChannelRoleTopRearRight;
            break;

        case N60ProgramLayoutSevenOneFour:
            layout.channelCount = 12u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            layout.channels[6] = N60ProgramChannelRoleRearLeft;
            layout.channels[7] = N60ProgramChannelRoleRearRight;
            layout.channels[8] = N60ProgramChannelRoleTopFrontLeft;
            layout.channels[9] = N60ProgramChannelRoleTopFrontRight;
            layout.channels[10] = N60ProgramChannelRoleTopRearLeft;
            layout.channels[11] = N60ProgramChannelRoleTopRearRight;
            break;

        case N60ProgramLayoutNineOneSix:
            layout.channelCount = 16u;
            layout.channels[0] = N60ProgramChannelRoleFrontLeft;
            layout.channels[1] = N60ProgramChannelRoleFrontRight;
            layout.channels[2] = N60ProgramChannelRoleFrontCenter;
            layout.channels[3] = N60ProgramChannelRoleLowFrequencyEffects;
            layout.channels[4] = N60ProgramChannelRoleSideLeft;
            layout.channels[5] = N60ProgramChannelRoleSideRight;
            layout.channels[6] = N60ProgramChannelRoleRearLeft;
            layout.channels[7] = N60ProgramChannelRoleRearRight;
            layout.channels[8] = N60ProgramChannelRoleWideLeft;
            layout.channels[9] = N60ProgramChannelRoleWideRight;
            layout.channels[10] = N60ProgramChannelRoleTopFrontLeft;
            layout.channels[11] = N60ProgramChannelRoleTopFrontRight;
            layout.channels[12] = N60ProgramChannelRoleTopMiddleLeft;
            layout.channels[13] = N60ProgramChannelRoleTopMiddleRight;
            layout.channels[14] = N60ProgramChannelRoleTopRearLeft;
            layout.channels[15] = N60ProgramChannelRoleTopRearRight;
            break;

        case N60ProgramLayoutCustom:
        default:
            layout.identifier = N60ProgramLayoutCustom;
            layout.channelCount = 0u;
            break;
    }

    return layout;
}

/// Structural validation is control-plane safe and allocation-free. Standard
/// layouts must exactly match their canonical semantic order. Custom layouts may
/// use any unique semantic roles within the fixed 32-channel limit.
static inline bool N60ProgramChannelLayoutIsValid(
    const N60ProgramChannelLayout * _Nullable layout
) {
    if (layout == NULL || layout->channelCount == 0u || layout->channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return false;
    }

    for (uint32_t index = 0; index < layout->channelCount; ++index) {
        const N60ProgramChannelRole role = layout->channels[index];
        if (!N60ProgramChannelRoleIsSemantic(role)) {
            return false;
        }
        for (uint32_t previous = 0; previous < index; ++previous) {
            if (layout->channels[previous] == role) {
                return false;
            }
        }
    }

    if (layout->identifier != N60ProgramLayoutCustom) {
        const N60ProgramChannelLayout canonical = N60ProgramChannelLayoutMakeStandard(layout->identifier);
        if (canonical.channelCount != layout->channelCount) {
            return false;
        }
        for (uint32_t index = 0; index < layout->channelCount; ++index) {
            if (canonical.channels[index] != layout->channels[index]) {
                return false;
            }
        }
    }

    return true;
}

static inline int32_t N60ProgramChannelLayoutIndexOfRole(
    const N60ProgramChannelLayout * _Nullable layout,
    N60ProgramChannelRole role
) {
    if (layout == NULL || !N60ProgramChannelRoleIsSemantic(role)) {
        return -1;
    }
    for (uint32_t index = 0; index < layout->channelCount && index < N60_MAX_PROGRAM_CHANNELS; ++index) {
        if (layout->channels[index] == role) {
            return (int32_t)index;
        }
    }
    return -1;
}

/// Compatibility gate for the existing shipping stereo render kernel.
static inline bool N60ProgramChannelLayoutIsStereoCompatible(
    const N60ProgramChannelLayout * _Nullable layout
) {
    return layout != NULL
        && layout->channelCount == 2u
        && layout->channels[0] == N60ProgramChannelRoleFrontLeft
        && layout->channels[1] == N60ProgramChannelRoleFrontRight;
}

#ifdef __cplusplus
}
#endif

#endif