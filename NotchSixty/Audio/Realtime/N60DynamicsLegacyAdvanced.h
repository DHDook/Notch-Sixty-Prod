#ifndef N60_DYNAMICS_LEGACY_ADVANCED_H
#define N60_DYNAMICS_LEGACY_ADVANCED_H

#include "N60Dynamics.h"

#ifdef __cplusplus
extern "C" {
#endif

bool N60DynamicsSnapshotSetSpectralDenoiserLegacyAdvanced(
    N60DynamicsSnapshot *snapshot,
    double sampleRate,
    bool enabled,
    N60DenoiserTuning tuning,
    N60DenoiserQuality quality,
    float reductionAmount,
    float thresholdDBFS,
    bool protectedRangeEnabled,
    float protectedLowHz,
    float protectedHighHz,
    uint32_t profileRevision,
    N60DenoiserProfileCommand profileCommand,
    bool advancedTuningEnabled,
    float minimumGain,
    float legacyAttackMs,
    float legacyReleaseMs
);

#ifdef __cplusplus
}
#endif

#endif
