#include "N60DynamicsLegacyAdvanced.h"

#include <math.h>

static float legacy_gain_smoothing_coefficient(double frameMs, float timeMs) {
    return (float)exp(-frameMs / (double)timeMs);
}

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
) {
    if (!N60DynamicsSnapshotSetSpectralDenoiser(
            snapshot, sampleRate, enabled, tuning, quality, reductionAmount,
            thresholdDBFS, protectedRangeEnabled, protectedLowHz, protectedHighHz,
            profileRevision, profileCommand)) return false;
    if (!advancedTuningEnabled) return true;
    if (snapshot == NULL || !isfinite(sampleRate) || sampleRate <= 0.0
        || !isfinite(minimumGain) || minimumGain < 0.001f || minimumGain > 0.5f
        || !isfinite(legacyAttackMs) || legacyAttackMs < 1.0f || legacyAttackMs > 100.0f
        || !isfinite(legacyReleaseMs) || legacyReleaseMs < 5.0f || legacyReleaseMs > 500.0f) return false;

    N60SpectralDenoiserSnapshot *denoiser = &snapshot->spectralDenoiser;
    double frameMs = ((double)denoiser->hopSize / sampleRate) * 1000.0;
    float legacyAttackAlpha = legacy_gain_smoothing_coefficient(frameMs, legacyAttackMs);
    float legacyReleaseAlpha = legacy_gain_smoothing_coefficient(frameMs, legacyReleaseMs);
    denoiser->minimumGain = minimumGain;
    // Legacy Attack raises gain toward unity; legacy Release lowers gain into suppression.
    // The commercial names are suppression-direction names, so this cross-map is intentional.
    denoiser->suppressionRelease = legacyAttackAlpha;
    denoiser->suppressionAttack = legacyReleaseAlpha;
    return N60SpectralDenoiserSnapshotIsValid(*denoiser, sampleRate);
}
