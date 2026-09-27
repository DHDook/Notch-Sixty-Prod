#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

#include "N60DynamicEQ.h"
#include "N60Dynamics.h"
#include "N60Protection.h"
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
    if (snapshot.mainsHumDetector.enabled) {
        fprintf(stderr, "bypassed dynamics unexpectedly enables mains analysis at %.0f Hz\n", sampleRate);
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

    if (runtime.mainsDetectorDecimationCounter != 0u || runtime.mainsDetectorSampleCount != 0u) {
        fprintf(stderr, "disabled mains detector advanced at %.0f Hz\n", sampleRate);
        return 1;
    }
    return 0;
}

static int validate_dynamic_eq(double sampleRate) {
    N60DynamicEQSnapshot snapshot = N60DynamicEQSnapshotMakeBypassed(sampleRate);
    if (!N60DynamicEQSnapshotSetBand(
            &snapshot,
            sampleRate,
            0u,
            true,
            1000.0,
            1.0f,
            -3.0f,
            -24.0f,
            2.0f,
            -12.0f,
            10.0f,
            100.0f,
            N60DynamicEQDirectionCutOnly,
            -40.0f,
            2.0f,
            6.0f,
            N60DynamicEQDetectorPeak,
            50.0f)) {
        fprintf(stderr, "failed to configure Dynamic EQ at %.0f Hz\n", sampleRate);
        return 1;
    }

    N60DynamicEQRuntime runtime;
    N60DynamicEQRuntimeReset(&runtime);
    if (!runtime.parked || snapshot.enabled) {
        fprintf(stderr, "disabled configured Dynamic EQ did not start parked at %.0f Hz\n", sampleRate);
        return 1;
    }

    for (uint32_t frame = 0; frame < 4096u; ++frame) {
        float leftIn = 0.18f * sinf((float)frame * 0.021f);
        float rightIn = 0.14f * cosf((float)frame * 0.017f);
        float left = leftIn;
        float right = rightIn;
        N60DynamicEQProcessStereoFrame(&runtime, &snapshot, &left, &right);
        if (left != leftIn || right != rightIn || !runtime.parked) {
            fprintf(stderr, "disabled configured Dynamic EQ processed audio at %.0f Hz frame %u\n", sampleRate, frame);
            return 1;
        }
    }

    if (!N60DynamicEQSnapshotSetEnabled(&snapshot, true)) return 1;
    for (uint32_t frame = 0; frame < 4096u; ++frame) {
        float left = 0.22f * sinf((float)frame * 0.019f);
        float right = 0.17f * cosf((float)frame * 0.015f);
        N60DynamicEQProcessStereoFrame(&runtime, &snapshot, &left, &right);
    }
    if (runtime.parked) {
        fprintf(stderr, "enabled Dynamic EQ remained parked at %.0f Hz\n", sampleRate);
        return 1;
    }

    if (!N60DynamicEQSnapshotSetEnabled(&snapshot, false)) return 1;
    bool parkedAgain = false;
    for (uint32_t frame = 0; frame < 30000u; ++frame) {
        float left = 0.20f * sinf((float)frame * 0.013f);
        float right = 0.15f * cosf((float)frame * 0.009f);
        N60DynamicEQProcessStereoFrame(&runtime, &snapshot, &left, &right);
        if (runtime.parked) {
            parkedAgain = true;
            break;
        }
    }
    if (!parkedAgain) {
        fprintf(stderr, "disabled Dynamic EQ never parked after its tail at %.0f Hz\n", sampleRate);
        return 1;
    }
    return 0;
}

static int validate_protection(double sampleRate) {
    N60ProtectionRuntime *runtime = N60ProtectionRuntimeCreate();
    if (runtime == NULL) {
        fprintf(stderr, "failed to create protection runtime at %.0f Hz\n", sampleRate);
        return 1;
    }
    N60ProtectionSnapshot snapshot = N60ProtectionSnapshotMakeBypassed(sampleRate);
    if (snapshot.effectiveFactor != N60OversamplingFactor1x
        || snapshot.softClipperEnabled
        || snapshot.limiterEnabled) {
        fprintf(stderr, "protection bypass snapshot is not neutral at %.0f Hz\n", sampleRate);
        N60ProtectionRuntimeDestroy(runtime);
        return 1;
    }

    N60ProtectionRuntimeBeginBuffer(runtime);
    for (uint32_t frame = 0; frame < 20000u; ++frame) {
        float leftIn = 0.33f * sinf((float)frame * 0.014f);
        float rightIn = -0.29f * cosf((float)frame * 0.010f);
        float left = leftIn;
        float right = rightIn;
        N60ProtectionProcessStereoFrame(runtime, &snapshot, &left, &right);
        if (left != leftIn || right != rightIn) {
            fprintf(stderr, "neutral protection changed audio at %.0f Hz frame %u\n", sampleRate, frame);
            N60ProtectionRuntimeDestroy(runtime);
            return 1;
        }
    }

    N60ProtectionTelemetry telemetry = N60ProtectionRuntimeTelemetry(runtime);
    if (telemetry.inputTruePeakLinear != 0.0f
        || telemetry.outputTruePeakLinear != 0.0f
        || telemetry.limiterGainReductionDB != 0.0f
        || telemetry.limiterSafetyClampSamples != 0u
        || telemetry.gainRiderAttenuationDB != 0.0f
        || telemetry.sustainedLimiterGainReductionDB != 0.0f
        || telemetry.truePeakGuardActive) {
        fprintf(stderr, "neutral protection performed hidden analysis at %.0f Hz\n", sampleRate);
        N60ProtectionRuntimeDestroy(runtime);
        return 1;
    }

    N60ProtectionRuntimeDestroy(runtime);
    return 0;
}

int main(void) {
    static const double sampleRates[] = {44100.0, 48000.0, 96000.0, 192000.0, 384000.0};
    for (uint32_t index = 0; index < sizeof(sampleRates) / sizeof(sampleRates[0]); ++index) {
        if (validate_denoiser(sampleRates[index]) != 0) return 1;
        if (validate_dynamics(sampleRates[index]) != 0) return 1;
        if (validate_dynamic_eq(sampleRates[index]) != 0) return 1;
        if (validate_protection(sampleRates[index]) != 0) return 1;
    }

    puts("PR35 disabled-DSP fast-path validation passed");
    return 0;
}
