
#include <assert.h>
#include <math.h>
#include "N60ChannelRouter.h"

int main(void) {
    N60ProgramChannelLayout stereo = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60ChannelRoutingMatrix identity = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&stereo, &stereo, &identity));
    assert(N60ChannelRoutingMatrixIsIdentity(&identity));

    const float stereoIn[2] = {0.25f, -0.5f};
    float stereoOut[2] = {0.0f, 0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&identity, stereoIn, stereoOut));
    assert(fabsf(stereoOut[0] - stereoIn[0]) < 1.0e-7f);
    assert(fabsf(stereoOut[1] - stereoIn[1]) < 1.0e-7f);

    N60ProgramChannelRole reversedRoles[2] = {
        N60ProgramChannelRoleFrontRight,
        N60ProgramChannelRoleFrontLeft,
    };
    N60ProgramChannelLayout reversed = N60ProgramChannelLayoutMakeCustom(reversedRoles, 2u);
    assert(N60ProgramChannelLayoutIsValid(&reversed));

    N60ChannelRoutingMatrix reorder = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&reversed, &stereo, &reorder));
    assert(!N60ChannelRoutingMatrixIsIdentity(&reorder));
    const float reversedIn[2] = {-0.75f, 0.125f};
    float canonicalOut[2] = {0.0f, 0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&reorder, reversedIn, canonicalOut));
    assert(fabsf(canonicalOut[0] - 0.125f) < 1.0e-7f);
    assert(fabsf(canonicalOut[1] + 0.75f) < 1.0e-7f);

    N60ChannelRoute mixRoutes[2] = {
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
        { .sourceChannelIndex = 1u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
    };
    N60ChannelRoutingMatrix monoMix = {0};
    assert(N60ChannelRoutingMatrixCompile(2u, 1u, mixRoutes, 2u, &monoMix));
    const float mixIn[2] = {0.8f, 0.2f};
    float mixOut[1] = {0.0f};
    assert(N60ChannelRoutingMatrixProcessFrame(&monoMix, mixIn, mixOut));
    assert(fabsf(mixOut[0] - 0.5f) < 1.0e-7f);

    N60ChannelRoute duplicateRoutes[2] = {
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 1.0f },
        { .sourceChannelIndex = 0u, .destinationChannelIndex = 0u, .gainLinear = 0.5f },
    };
    N60ChannelRoutingMatrix rejected = {0};
    assert(!N60ChannelRoutingMatrixCompile(2u, 2u, duplicateRoutes, 2u, &rejected));

    N60ChannelRoute invalidGain = {
        .sourceChannelIndex = 0u,
        .destinationChannelIndex = 0u,
        .gainLinear = NAN,
    };
    assert(!N60ChannelRoutingMatrixCompile(2u, 2u, &invalidGain, 1u, &rejected));

    N60ProgramChannelRole wrongRoles[2] = {
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontCenter,
    };
    N60ProgramChannelLayout wrong = N60ProgramChannelLayoutMakeCustom(wrongRoles, 2u);
    assert(N60ProgramChannelLayoutIsValid(&wrong));
    assert(!N60ChannelRoutingMatrixCompileSemanticReorder(&wrong, &stereo, &rejected));

    N60ProgramChannelLayout sevenOne = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutSevenOne);
    N60ProgramChannelRole sevenOneReorderedRoles[8] = {
        N60ProgramChannelRoleFrontCenter,
        N60ProgramChannelRoleFrontLeft,
        N60ProgramChannelRoleFrontRight,
        N60ProgramChannelRoleLowFrequencyEffects,
        N60ProgramChannelRoleRearLeft,
        N60ProgramChannelRoleRearRight,
        N60ProgramChannelRoleSideLeft,
        N60ProgramChannelRoleSideRight,
    };
    N60ProgramChannelLayout sevenOneReordered = N60ProgramChannelLayoutMakeCustom(sevenOneReorderedRoles, 8u);
    assert(N60ProgramChannelLayoutIsValid(&sevenOneReordered));
    N60ChannelRoutingMatrix sevenOneMatrix = {0};
    assert(N60ChannelRoutingMatrixCompileSemanticReorder(&sevenOneReordered, &sevenOne, &sevenOneMatrix));

    return 0;
}
