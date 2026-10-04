#ifndef N60SubwooferTuning_h
#define N60SubwooferTuning_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>

#include "N60MultichannelBassManagement.h"

#ifdef __cplusplus
extern "C" {
#endif

// The physical-sub filter bank is intentionally generic at the realtime layer.
// The product/control plane reserves two deterministic slots for dedicated
// subwoofer conditioning and exposes the remaining six as ordinary user PEQ.
#define N60_SUBWOOFER_SUBSONIC_SECTION 0u
#define N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION 1u
#define N60_SUBWOOFER_USER_EQ_FIRST_SECTION 2u
#define N60_SUBWOOFER_USER_EQ_SECTIONS \
    (N60_SUBWOOFER_MAX_EQ_SECTIONS - N60_SUBWOOFER_USER_EQ_FIRST_SECTION)

static inline bool N60SubwooferOutputSetEnabled(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    bool enabled
) {
    if (snapshot == NULL || subwooferIndex >= snapshot->subwooferCount) return false;
    snapshot->subwoofers[subwooferIndex].enabled = enabled;
    return true;
}

// Dedicated subsonic protection HPF. This uses one reserved biquad slot rather
// than introducing a second filter implementation into the realtime path.
static inline bool N60SubwooferOutputSetSubsonicHighPass(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    double frequencyHz,
    double q,
    bool enabled
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(frequencyHz)
        || frequencyHz <= 0.0
        || frequencyHz >= snapshot->sampleRate * 0.5
        || !isfinite(q)
        || q <= 0.0) {
        return false;
    }
    return N60SubwooferOutputSetEQBand(
        snapshot,
        subwooferIndex,
        N60_SUBWOOFER_SUBSONIC_SECTION,
        N60BiquadFilterTypeHighPass,
        frequencyHz,
        0.0,
        q,
        enabled
    );
}

// Dedicated second-order all-pass phase-alignment control for mains/sub
// integration. Delay remains a separate coarse time-alignment control.
static inline bool N60SubwooferOutputSetPhaseAlignment(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    double frequencyHz,
    double q,
    bool enabled
) {
    if (snapshot == NULL
        || subwooferIndex >= snapshot->subwooferCount
        || !isfinite(frequencyHz)
        || frequencyHz <= 0.0
        || frequencyHz >= snapshot->sampleRate * 0.5
        || !isfinite(q)
        || q <= 0.0) {
        return false;
    }
    return N60SubwooferOutputSetEQBand(
        snapshot,
        subwooferIndex,
        N60_SUBWOOFER_PHASE_ALIGNMENT_SECTION,
        N60BiquadFilterTypeAllPass,
        frequencyHz,
        0.0,
        q,
        enabled
    );
}

// User-facing per-sub PEQ is kept disjoint from the two dedicated conditioning
// sections so editing ordinary EQ can never silently remove subsonic or phase
// alignment processing.
static inline bool N60SubwooferOutputSetUserEQBand(
    N60MultichannelBassManagementSnapshot * _Nonnull snapshot,
    uint32_t subwooferIndex,
    uint32_t userBandIndex,
    N60BiquadFilterType type,
    double frequencyHz,
    double gainDB,
    double q,
    bool enabled
) {
    if (userBandIndex >= N60_SUBWOOFER_USER_EQ_SECTIONS) return false;
    return N60SubwooferOutputSetEQBand(
        snapshot,
        subwooferIndex,
        N60_SUBWOOFER_USER_EQ_FIRST_SECTION + userBandIndex,
        type,
        frequencyHz,
        gainDB,
        q,
        enabled
    );
}

#ifdef __cplusplus
}
#endif

#endif
