#ifndef N60Downmix_h
#define N60Downmix_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "N60ChannelRouter.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60DownmixLFEDrop = 0,
    N60DownmixLFEFoldToFronts = 1,
} N60DownmixLFEPolicy;

typedef struct {
    N60ProgramChannelLayout sourceLayout;
    N60ProgramChannelLayout destinationLayout;
    N60DownmixLFEPolicy lfePolicy;
    N60ChannelRoutingMatrix matrix;
    float recommendedPreampDB;
    bool lfeFolded;
} N60DownmixPlan;

static inline bool N60DownmixAddGain(
    N60ChannelRoutingMatrix * _Nonnull matrix,
    uint32_t source,
    int32_t destination,
    float gain
) {
    if (matrix == NULL
        || source >= matrix->sourceChannelCount
        || destination < 0
        || (uint32_t)destination >= matrix->destinationChannelCount
        || !isfinite(gain)) {
        return false;
    }
    matrix->matrix[N60ChannelRoutingMatrixOffset(source, (uint32_t)destination)] += gain;
    return true;
}

static inline int32_t N60DownmixDestinationIndex(
    const N60ProgramChannelLayout * _Nonnull layout,
    N60ProgramChannelRole role
) {
    return N60ProgramChannelLayoutIndexOfRole(layout, role);
}

static inline bool N60DownmixMapToSide(
    N60ChannelRoutingMatrix * _Nonnull matrix,
    const N60ProgramChannelLayout * _Nonnull destination,
    uint32_t source,
    bool left,
    float gain
) {
    const N60ProgramChannelRole front = left
        ? N60ProgramChannelRoleFrontLeft
        : N60ProgramChannelRoleFrontRight;
    const N60ProgramChannelRole side = left
        ? N60ProgramChannelRoleSideLeft
        : N60ProgramChannelRoleSideRight;
    const int32_t sideIndex = N60DownmixDestinationIndex(destination, side);
    if (sideIndex >= 0) return N60DownmixAddGain(matrix, source, sideIndex, gain);
    return N60DownmixAddGain(matrix, source, N60DownmixDestinationIndex(destination, front), gain);
}

static inline bool N60DownmixMapToRearOrSide(
    N60ChannelRoutingMatrix * _Nonnull matrix,
    const N60ProgramChannelLayout * _Nonnull destination,
    uint32_t source,
    bool left,
    float gain
) {
    const N60ProgramChannelRole rear = left
        ? N60ProgramChannelRoleRearLeft
        : N60ProgramChannelRoleRearRight;
    const int32_t rearIndex = N60DownmixDestinationIndex(destination, rear);
    if (rearIndex >= 0) return N60DownmixAddGain(matrix, source, rearIndex, gain);
    return N60DownmixMapToSide(matrix, destination, source, left, gain);
}

/// Explicit semantic downmix compiler. Matching roles remain at unity; roles not
/// present in the destination are folded by documented policy. The resulting
/// matrix is ordinary PR53 routing data and adds no hidden render-path behavior.
static inline bool N60DownmixCompile(
    N60ProgramChannelLayout source,
    N60ProgramChannelLayout destination,
    N60DownmixLFEPolicy lfePolicy,
    N60DownmixPlan * _Nonnull planOut
) {
    if (planOut == NULL
        || !N60ProgramChannelLayoutIsValid(&source)
        || !N60ProgramChannelLayoutIsValid(&destination)
        || lfePolicy < N60DownmixLFEDrop
        || lfePolicy > N60DownmixLFEFoldToFronts) {
        return false;
    }
    N60DownmixPlan plan = {0};
    plan.sourceLayout = source;
    plan.destinationLayout = destination;
    plan.lfePolicy = lfePolicy;
    plan.matrix = N60ChannelRoutingMatrixMakeZero(source.channelCount, destination.channelCount);
    if (plan.matrix.sourceChannelCount == 0u) return false;

    const int32_t destinationLeft = N60DownmixDestinationIndex(&destination, N60ProgramChannelRoleFrontLeft);
    const int32_t destinationRight = N60DownmixDestinationIndex(&destination, N60ProgramChannelRoleFrontRight);

    for (uint32_t sourceIndex = 0; sourceIndex < source.channelCount; ++sourceIndex) {
        const N60ProgramChannelRole role = source.channels[sourceIndex];
        const int32_t direct = N60DownmixDestinationIndex(&destination, role);
        if (direct >= 0) {
            if (!N60DownmixAddGain(&plan.matrix, sourceIndex, direct, 1.0f)) return false;
            continue;
        }

        bool mapped = false;
        switch (role) {
        case N60ProgramChannelRoleLowFrequencyEffects:
            if (lfePolicy == N60DownmixLFEDrop) {
                mapped = true;
                break;
            }
            if (destinationLeft < 0 || destinationRight < 0) return false;
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationLeft, 0.5f)
                && N60DownmixAddGain(&plan.matrix, sourceIndex, destinationRight, 0.5f);
            plan.lfeFolded = mapped;
            break;

        case N60ProgramChannelRoleFrontCenter:
            if (destinationLeft < 0 || destinationRight < 0) return false;
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationLeft, 0.70710678f)
                && N60DownmixAddGain(&plan.matrix, sourceIndex, destinationRight, 0.70710678f);
            break;

        case N60ProgramChannelRoleSideLeft:
            mapped = N60DownmixMapToSide(&plan.matrix, &destination, sourceIndex, true, 0.70710678f);
            break;
        case N60ProgramChannelRoleSideRight:
            mapped = N60DownmixMapToSide(&plan.matrix, &destination, sourceIndex, false, 0.70710678f);
            break;

        case N60ProgramChannelRoleRearLeft:
            mapped = N60DownmixMapToRearOrSide(&plan.matrix, &destination, sourceIndex, true, 0.70710678f);
            break;
        case N60ProgramChannelRoleRearRight:
            mapped = N60DownmixMapToRearOrSide(&plan.matrix, &destination, sourceIndex, false, 0.70710678f);
            break;

        case N60ProgramChannelRoleWideLeft: {
            const int32_t side = N60DownmixDestinationIndex(&destination, N60ProgramChannelRoleSideLeft);
            if (destinationLeft < 0) return false;
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationLeft, side >= 0 ? 0.5f : 0.70710678f);
            if (side >= 0) mapped = mapped && N60DownmixAddGain(&plan.matrix, sourceIndex, side, 0.5f);
            break;
        }
        case N60ProgramChannelRoleWideRight: {
            const int32_t side = N60DownmixDestinationIndex(&destination, N60ProgramChannelRoleSideRight);
            if (destinationRight < 0) return false;
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationRight, side >= 0 ? 0.5f : 0.70710678f);
            if (side >= 0) mapped = mapped && N60DownmixAddGain(&plan.matrix, sourceIndex, side, 0.5f);
            break;
        }

        case N60ProgramChannelRoleTopFrontLeft:
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationLeft, 0.70710678f);
            break;
        case N60ProgramChannelRoleTopFrontRight:
            mapped = N60DownmixAddGain(&plan.matrix, sourceIndex, destinationRight, 0.70710678f);
            break;
        case N60ProgramChannelRoleTopMiddleLeft:
            mapped = N60DownmixMapToSide(&plan.matrix, &destination, sourceIndex, true, 0.70710678f);
            break;
        case N60ProgramChannelRoleTopMiddleRight:
            mapped = N60DownmixMapToSide(&plan.matrix, &destination, sourceIndex, false, 0.70710678f);
            break;
        case N60ProgramChannelRoleTopRearLeft:
            mapped = N60DownmixMapToRearOrSide(&plan.matrix, &destination, sourceIndex, true, 0.70710678f);
            break;
        case N60ProgramChannelRoleTopRearRight:
            mapped = N60DownmixMapToRearOrSide(&plan.matrix, &destination, sourceIndex, false, 0.70710678f);
            break;

        case N60ProgramChannelRoleFrontLeft:
        case N60ProgramChannelRoleFrontRight:
        case N60ProgramChannelRoleUnused:
        default:
            mapped = false;
            break;
        }
        if (!mapped) return false;
    }

    float maximumAbsoluteRowSum = 0.0f;
    for (uint32_t destinationIndex = 0; destinationIndex < destination.channelCount; ++destinationIndex) {
        float rowSum = 0.0f;
        for (uint32_t sourceIndex = 0; sourceIndex < source.channelCount; ++sourceIndex) {
            rowSum += fabsf(plan.matrix.matrix[
                N60ChannelRoutingMatrixOffset(sourceIndex, destinationIndex)
            ]);
        }
        if (rowSum > maximumAbsoluteRowSum) maximumAbsoluteRowSum = rowSum;
    }
    plan.recommendedPreampDB = maximumAbsoluteRowSum > 1.0f
        ? (float)(-20.0 * log10((double)maximumAbsoluteRowSum))
        : 0.0f;
    if (!N60ChannelRoutingMatrixIsStructurallyValid(&plan.matrix)) return false;
    *planOut = plan;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
