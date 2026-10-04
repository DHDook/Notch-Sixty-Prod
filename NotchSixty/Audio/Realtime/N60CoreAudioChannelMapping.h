#ifndef N60CoreAudioChannelMapping_h
#define N60CoreAudioChannelMapping_h

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Translate an explicit Core Audio channel description label into Notch Sixty's
/// semantic program-channel identity. Unsupported/ambiguous roles return Unused
/// rather than being guessed into a speaker position.
static inline N60ProgramChannelRole N60ProgramChannelRoleFromAudioChannelLabel(
    AudioChannelLabel label
) {
    switch (label) {
        case kAudioChannelLabel_Left:
        case kAudioChannelLabel_HeadphonesLeft:
            return N60ProgramChannelRoleFrontLeft;

        case kAudioChannelLabel_Right:
        case kAudioChannelLabel_HeadphonesRight:
            return N60ProgramChannelRoleFrontRight;

        case kAudioChannelLabel_Center:
            return N60ProgramChannelRoleFrontCenter;

        case kAudioChannelLabel_LFEScreen:
            return N60ProgramChannelRoleLowFrequencyEffects;

        case kAudioChannelLabel_LeftSurround:
        case kAudioChannelLabel_LeftSurroundDirect:
        case kAudioChannelLabel_LeftSideSurround:
            return N60ProgramChannelRoleSideLeft;

        case kAudioChannelLabel_RightSurround:
        case kAudioChannelLabel_RightSurroundDirect:
        case kAudioChannelLabel_RightSideSurround:
            return N60ProgramChannelRoleSideRight;

        case kAudioChannelLabel_RearSurroundLeft:
        case kAudioChannelLabel_LeftBackSurround:
            return N60ProgramChannelRoleRearLeft;

        case kAudioChannelLabel_RearSurroundRight:
        case kAudioChannelLabel_RightBackSurround:
            return N60ProgramChannelRoleRearRight;

        case kAudioChannelLabel_LeftWide:
            return N60ProgramChannelRoleWideLeft;

        case kAudioChannelLabel_RightWide:
            return N60ProgramChannelRoleWideRight;

        case kAudioChannelLabel_LeftTopFront:
            return N60ProgramChannelRoleTopFrontLeft;

        case kAudioChannelLabel_RightTopFront:
            return N60ProgramChannelRoleTopFrontRight;

        case kAudioChannelLabel_LeftTopMiddle:
            return N60ProgramChannelRoleTopMiddleLeft;

        case kAudioChannelLabel_RightTopMiddle:
            return N60ProgramChannelRoleTopMiddleRight;

        case kAudioChannelLabel_LeftTopRear:
        case kAudioChannelLabel_TopBackLeft:
            return N60ProgramChannelRoleTopRearLeft;

        case kAudioChannelLabel_RightTopRear:
        case kAudioChannelLabel_TopBackRight:
            return N60ProgramChannelRoleTopRearRight;

        default:
            return N60ProgramChannelRoleUnused;
    }
}

static inline N60ProgramLayoutIdentifier N60ProgramLayoutIdentifierForExactRoles(
    const N60ProgramChannelRole * _Nonnull roles,
    uint32_t channelCount
) {
    if (roles == NULL || channelCount == 0u || channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return N60ProgramLayoutCustom;
    }

    const N60ProgramLayoutIdentifier candidates[] = {
        N60ProgramLayoutStereo,
        N60ProgramLayoutFiveOne,
        N60ProgramLayoutSevenOne,
        N60ProgramLayoutFiveOneTwo,
        N60ProgramLayoutFiveOneFour,
        N60ProgramLayoutSevenOneFour,
        N60ProgramLayoutNineOneSix,
    };
    const uint32_t candidateCount = (uint32_t)(sizeof(candidates) / sizeof(candidates[0]));

    for (uint32_t candidateIndex = 0; candidateIndex < candidateCount; ++candidateIndex) {
        const N60ProgramChannelLayout candidate = N60ProgramChannelLayoutMakeStandard(
            candidates[candidateIndex]
        );
        if (candidate.channelCount != channelCount) {
            continue;
        }
        bool equal = true;
        for (uint32_t channel = 0; channel < channelCount; ++channel) {
            if (candidate.channels[channel] != roles[channel]) {
                equal = false;
                break;
            }
        }
        if (equal) {
            return candidates[candidateIndex];
        }
    }

    return N60ProgramLayoutCustom;
}

/// Build a semantic source layout from explicit Core Audio channel descriptions.
/// The source ordering is retained exactly. If that order matches a canonical
/// Notch Sixty layout, its canonical identifier is restored; otherwise it remains
/// a valid custom/reordered semantic layout ready for the PR53 matrix compiler.
static inline bool N60ProgramChannelLayoutFromAudioChannelDescriptions(
    const AudioChannelDescription * _Nullable descriptions,
    uint32_t channelCount,
    N60ProgramChannelLayout * _Nonnull layoutOut
) {
    if (descriptions == NULL
        || layoutOut == NULL
        || channelCount == 0u
        || channelCount > N60_MAX_PROGRAM_CHANNELS) {
        return false;
    }

    N60ProgramChannelRole roles[N60_MAX_PROGRAM_CHANNELS] = {0};
    for (uint32_t index = 0; index < channelCount; ++index) {
        roles[index] = N60ProgramChannelRoleFromAudioChannelLabel(
            descriptions[index].mChannelLabel
        );
        if (!N60ProgramChannelRoleIsSemantic(roles[index])) {
            return false;
        }
    }

    N60ProgramChannelLayout result = N60ProgramChannelLayoutMakeCustom(roles, channelCount);
    if (!N60ProgramChannelLayoutIsValid(&result)) {
        return false;
    }
    result.identifier = N60ProgramLayoutIdentifierForExactRoles(roles, channelCount);
    *layoutOut = result;
    return true;
}

/// PR53 intentionally accepts expanded channel descriptions rather than guessing
/// a standard tag's hidden order. Standard tags and channel bitmaps must be
/// expanded off the realtime thread with Audio Toolbox's documented channel-
/// layout properties before calling the mapper.
static inline bool N60CoreAudioChannelLayoutUsesExplicitDescriptions(
    const AudioChannelLayout * _Nullable layout
) {
    return layout != NULL
        && layout->mChannelLayoutTag == kAudioChannelLayoutTag_UseChannelDescriptions
        && layout->mNumberChannelDescriptions > 0u;
}

#ifdef __cplusplus
}
#endif

#endif
