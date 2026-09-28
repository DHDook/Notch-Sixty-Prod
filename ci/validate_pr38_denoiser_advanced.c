#include "../NotchSixty/Audio/Realtime/N60DynamicsLegacyAdvanced.h"
#include <math.h>
#include <stdio.h>

static int closef(float a, float b, float tolerance) { return fabsf(a - b) <= tolerance; }

int main(void) {
    const double sampleRate = 48000.0;
    N60DynamicsSnapshot baseline = N60DynamicsSnapshotMakeBypassed(sampleRate);
    N60DynamicsSnapshot wrapped = N60DynamicsSnapshotMakeBypassed(sampleRate);
    if (!N60DynamicsSnapshotSetSpectralDenoiser(&baseline, sampleRate, true,
            N60DenoiserTuningStandard, N60DenoiserQualityHigh, 0.5f, -60.0f,
            false, 0.0f, 150.0f, 0u, N60DenoiserProfileCommandNone)) return 1;
    if (!N60DynamicsSnapshotSetSpectralDenoiserLegacyAdvanced(&wrapped, sampleRate, true,
            N60DenoiserTuningStandard, N60DenoiserQualityHigh, 0.5f, -60.0f,
            false, 0.0f, 150.0f, 0u, N60DenoiserProfileCommandNone,
            false, 0.01f, 11.0f, 21.0f)) return 2;
    if (!closef(baseline.spectralDenoiser.minimumGain, wrapped.spectralDenoiser.minimumGain, 1e-7f)
        || !closef(baseline.spectralDenoiser.suppressionAttack, wrapped.spectralDenoiser.suppressionAttack, 1e-7f)
        || !closef(baseline.spectralDenoiser.suppressionRelease, wrapped.spectralDenoiser.suppressionRelease, 1e-7f)) return 3;

    N60DynamicsSnapshot custom = N60DynamicsSnapshotMakeBypassed(sampleRate);
    if (!N60DynamicsSnapshotSetSpectralDenoiserLegacyAdvanced(&custom, sampleRate, true,
            N60DenoiserTuningStandard, N60DenoiserQualityHigh, 0.5f, -60.0f,
            false, 0.0f, 150.0f, 0u, N60DenoiserProfileCommandNone,
            true, 0.01f, 11.0f, 21.0f)) return 4;
    double frameMs = ((double)custom.spectralDenoiser.hopSize / sampleRate) * 1000.0;
    float expectedLegacyAttack = (float)exp(-frameMs / 11.0);
    float expectedLegacyRelease = (float)exp(-frameMs / 21.0);
    if (!closef(custom.spectralDenoiser.minimumGain, 0.01f, 1e-7f)) return 5;
    if (!closef(custom.spectralDenoiser.suppressionRelease, expectedLegacyAttack, 1e-6f)) return 6;
    if (!closef(custom.spectralDenoiser.suppressionAttack, expectedLegacyRelease, 1e-6f)) return 7;
    puts("PR38 denoiser advanced parity: PASS");
    return 0;
}
