#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "N60Dynamics.h"
#include "N60SpectralDenoiser.h"

static int validate_denoiser(double sampleRate) {
    N60SpectralDenoiserRuntime *runtime = N60SpectralDenoiserCreate();
    if (runtime == NULL) {
        fprintf(stderr, "failed to create denoiser runtime at %.0f Hz\n", sampleRate);
        return 1;
    }

    N60SpectralDenoiserSnapshot snapshot = N60SpectralDenoiserSnapshotMakeBypassed(sampleRate);
    const uint32_t frameCount = snapshot.fftSize * 4u;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        float leftIn = 0.31f * sinf((float)frame * 0.017f);
        float rightIn = 0.23f * cosf((float)frame * 0.013f);
        float leftOut = 0.0f;
        float rightOut = 0.0f;
        N60SpectralDenoiserProcessStereoFrameValidated(
            runtime,
            &snapshot,
            sampleRate,
            leftIn,
            rightIn,
            &leftOut,
            &rightOut
        );
        if (leftOut != leftIn || rightOut != rightIn) {
            fprintf(stderr, "disabled denoiser changed audio at %.0f Hz frame %u\n", sampleRate, frame);
            N60SpectralDenoiserDestroy(runtime);
            return 1;
        }
    }

    N60SpectralDenoiserTelemetry telemetry = N60SpectralDenoiserRuntimeTelemetry(runtime);
    if (telemetry.spectralFramesProcessed != 0u) {
        fprintf(stderr,
                "disabled denoiser ran spectral work at %.0f Hz: %llu frames\n",
                sampleRate,
                (unsigned long long)telemetry.spectralFramesProcessed);
        N60SpectralDenoiserDestroy(runtime);
        return 1;
    }

    N60SpectralDenoiserDestroy(runtime);
    return 0;
}

static int validate_dynamics(double sampleRate) {
    N60DynamicsSnapshot snapshot = N60DynamicsSnapshotMakeBypassed(sampleRate);

    // Match the product graph: mains detection remains available even when its
    // notch is bypassed. The detector is deliberately decimated and must not
    // prevent the audible pre-EQ stages from parking.
    if (!N60DynamicsSnapshotSetMainsHumDetector(&snapshot, sampleRate, true, 60.0)) {
        fprintf(stderr, "failed to configure mains detector at %.0f Hz\n", sampleRate);
        return 1;
    }

    N60DynamicsRuntime runtime;
    N60DynamicsRuntimeReset(&runtime);
    if (!runtime.preEQParked || !runtime.coreParked) {
        fprintf(stderr, "bypassed dynamics did not start parked at %.0f Hz\n", sampleRate);
        return 1;
    }

    const uint32_t frameCount = 20000u;
    for (uint32_t frame = 0; frame < frameCount; ++frame) {
        float leftIn = 0.27f * sinf((float)frame * 0.019f);
        float rightIn = -0.19f * cosf((float)frame * 0.011f);
        float left = leftIn;
        float right = rightIn;

        N60DynamicsProcessPreEQStereoFrame(&runtime, &snapshot, &left, &right);
        N60DynamicsProcessDynamicEQStereoFrame(&runtime, &snapshot, &left, &right);
        N60DynamicsProcessCoreStereoFrame(&runtime, &snapshot, &left, &right);
        N60DynamicsProcessPauseGateStereoFrame(&runtime, &snapshot, &left, &right);

        if (left != leftIn || right != rightIn) {
            fprintf(stderr, "bypassed dynamics changed audio at %.0f Hz frame %u\n", sampleRate, frame);
            return 1;
        }
        if (!runtime.preEQParked || !runtime.coreParked) {
            fprintf(stderr, "bypassed dynamics left parked state at %.0f Hz frame %u\n", sampleRate, frame);
            return 1;
        }
    }

    return 0;
}

int main(void) {
    static const double sampleRates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    for (uint32_t index = 0; index < sizeof(sampleRates) / sizeof(sampleRates[0]); ++index) {
        if (validate_denoiser(sampleRates[index]) != 0) return 1;
        if (validate_dynamics(sampleRates[index]) != 0) return 1;
    }

    puts("PR35 disabled-DSP fast-path validation passed");
    return 0;
}
