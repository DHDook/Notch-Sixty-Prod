
#include <assert.h>
#include <math.h>
#include "N60SubwooferTuning.h"

int main(void) {
    N60ProgramChannelLayout layout = N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutFiveOne);
    N60MultichannelBassManagementSnapshot snapshot =
        N60MultichannelBassManagementSnapshotMake(48000.0, layout, 2u);

    assert(N60SubwooferOutputSetEnabled(&snapshot, 1u, false));
    assert(!snapshot.subwoofers[1].enabled);

    assert(N60SubwooferOutputSetSubsonicHighPass(&snapshot, 0u, 20.0, 0.70710678, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].type == N60BiquadFilterTypeHighPass);

    assert(N60SubwooferOutputSetPhaseAlignment(&snapshot, 0u, 80.0, 0.7, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].type == N60BiquadFilterTypeAllPass);

    assert(N60SubwooferOutputSetUserEQBand(
        &snapshot, 0u, 0u, N60BiquadFilterTypePeaking, 50.0, -3.0, 1.0, true));
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_USER_EQ_FIRST_SECTION].enabled);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_SUBSONIC_SECTION].type == N60BiquadFilterTypeHighPass);
    assert(snapshot.subwoofers[0].eqSections[N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION].type == N60BiquadFilterTypeAllPass);
    assert(!N60SubwooferOutputSetUserEQBand(
        &snapshot, 0u, N60_SUBWOOFER_USER_EQ_SECTIONS,
        N60BiquadFilterTypePeaking, 60.0, 1.0, 1.0, true));

    assert(!N60SubwooferOutputSetSubsonicHighPass(&snapshot, 0u, 0.0, 0.707, true));
    assert(!N60SubwooferOutputSetPhaseAlignment(&snapshot, 0u, 24000.0, 0.7, true));
    assert(N60MultichannelBassManagementSnapshotIsValid(&snapshot));

    N60MultichannelBassManagementRuntime *runtime =
        N60MultichannelBassManagementRuntimeCreate();
    assert(runtime != NULL);
    assert(N60MultichannelBassManagementSetLFERoute(&snapshot, 0u, 1.0f));
    assert(N60MultichannelBassManagementRuntimePrepare(runtime, &snapshot));

    float in[6] = {0};
    float speakers[6] = {0};
    float subs[N60_MAX_SUBWOOFER_OUTPUTS] = {0};
    in[3] = 1.0f;
    for (uint32_t frame = 0; frame < 2048u; ++frame) {
        assert(N60MultichannelBassManagementProcessFrame(runtime, &snapshot, in, speakers, subs));
        assert(isfinite(subs[0]));
        assert(subs[1] == 0.0f);
        in[3] = 0.0f;
    }
    N60MultichannelBassManagementRuntimeDestroy(runtime);
    return 0;
}
