#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60AdaptiveSampleRate.h"

#define PI 3.14159265358979323846

static int failures = 0;

static void check(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures += 1;
    }
}

static double rms(const float *samples, uint32_t frames, uint32_t channels, uint32_t channel, uint32_t skip) {
    if (frames <= skip) return 0.0;
    double sum = 0.0;
    uint32_t count = 0u;
    for (uint32_t frame = skip; frame < frames; ++frame) {
        double value = samples[(size_t)frame * channels + channel];
        sum += value * value;
        count += 1u;
    }
    return count > 0u ? sqrt(sum / (double)count) : 0.0;
}

static double estimate_frequency(
    const float *samples,
    uint32_t frames,
    uint32_t channels,
    uint32_t channel,
    double sampleRate,
    uint32_t skip
) {
    uint32_t crossings = 0u;
    for (uint32_t frame = skip + 1u; frame < frames; ++frame) {
        float previous = samples[(size_t)(frame - 1u) * channels + channel];
        float current = samples[(size_t)frame * channels + channel];
        if (previous <= 0.0f && current > 0.0f) crossings += 1u;
    }
    double duration = (double)(frames - skip) / sampleRate;
    return duration > 0.0 ? (double)crossings / duration : 0.0;
}

static uint32_t run_sine_conversion(
    double inputRate,
    double outputRate,
    double frequency,
    uint32_t inputFrames,
    float **outputOut
) {
    const uint32_t channels = 2u;
    uint32_t capacity = inputFrames + 4096u;
    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        inputRate,
        outputRate,
        channels,
        capacity,
        1024u
    );
    configuration.proportionalGainPPM = 0.0;
    configuration.integralGainPPMPerSecond = 0.0;
    N60AdaptiveSRC *src = N60AdaptiveSRCCreate(configuration);
    check(src != NULL, "create sine conversion SRC");
    if (src == NULL) return 0u;

    float *input = calloc((size_t)inputFrames * channels, sizeof(float));
    uint32_t outputCapacity = (uint32_t)ceil((double)inputFrames * outputRate / inputRate) + 2048u;
    float *output = calloc((size_t)outputCapacity * channels, sizeof(float));
    check(input != NULL && output != NULL, "allocate test buffers");
    if (input == NULL || output == NULL) {
        free(input);
        free(output);
        N60AdaptiveSRCDestroy(src);
        return 0u;
    }

    for (uint32_t frame = 0u; frame < inputFrames; ++frame) {
        float value = (float)(0.5 * sin(2.0 * PI * frequency * (double)frame / inputRate));
        input[(size_t)frame * channels] = value;
        input[(size_t)frame * channels + 1u] = -value;
    }

    check(N60AdaptiveSRCPushInterleaved(src, input, inputFrames) == inputFrames, "push full sine buffer");
    uint32_t produced = N60AdaptiveSRCPullInterleaved(src, output, outputCapacity);
    N60AdaptiveSRCSnapshot snapshot = N60AdaptiveSRCGetSnapshot(src);
    check(snapshot.valid, "snapshot is valid");
    check(snapshot.droppedInputFrames == 0u, "no input drops in offline test");
    check(snapshot.producedOutputFrames == produced, "produced-frame telemetry matches");
    check(N60AdaptiveSRCRealtimeAtomicsAreLockFree(src), "realtime atomics are lock-free");
    check(N60AdaptiveSRCLatencyInputFrames(src) == configuration.tapCount / 2u, "latency reports half-kernel lookahead");

    free(input);
    N60AdaptiveSRCDestroy(src);
    *outputOut = output;
    return produced;
}

static void test_rate_conversion(void) {
    float *output = NULL;
    uint32_t produced = run_sine_conversion(44100.0, 48000.0, 1000.0, 44100u, &output);
    check(produced > 47000u && produced < 48100u, "44.1 to 48 output frame count is plausible");
    if (output != NULL && produced > 4000u) {
        double frequency = estimate_frequency(output, produced, 2u, 0u, 48000.0, 2000u);
        double level = rms(output, produced, 2u, 0u, 2000u);
        check(fabs(frequency - 1000.0) < 3.0, "44.1 to 48 preserves sine frequency");
        check(fabs(level - (0.5 / sqrt(2.0))) < 0.01, "44.1 to 48 preserves passband amplitude");
    }
    free(output);

    output = NULL;
    produced = run_sine_conversion(44100.0, 48000.0, 20000.0, 44100u, &output);
    if (output != NULL && produced > 4000u) {
        double level = rms(output, produced, 2u, 0u, 2000u);
        double reference = 0.5 / sqrt(2.0);
        double levelDB = 20.0 * log10(level / reference);
        check(levelDB > -0.30 && levelDB < 0.10, "44.1 to 48 keeps 20 kHz within reference passband tolerance");
    }
    free(output);

    output = NULL;
    produced = run_sine_conversion(48000.0, 44100.0, 5000.0, 48000u, &output);
    check(produced > 43000u && produced < 44200u, "48 to 44.1 output frame count is plausible");
    if (output != NULL && produced > 4000u) {
        double frequency = estimate_frequency(output, produced, 2u, 0u, 44100.0, 2000u);
        check(fabs(frequency - 5000.0) < 8.0, "48 to 44.1 preserves sine frequency");
    }
    free(output);
}

static void test_downsample_alias_rejection(void) {
    float *output = NULL;
    uint32_t produced = run_sine_conversion(48000.0, 44100.0, 22500.0, 48000u, &output);
    if (output != NULL && produced > 3000u) {
        double level = rms(output, produced, 2u, 0u, 2000u);
        check(level < 0.00010, "48 to 44.1 strongly rejects content above destination Nyquist");
    }
    free(output);

    output = NULL;
    produced = run_sine_conversion(48000.0, 32000.0, 20000.0, 48000u, &output);
    if (output != NULL && produced > 3000u) {
        double level = rms(output, produced, 2u, 0u, 2000u);
        check(level < 0.0025, "20 kHz aliases are strongly attenuated when downsampling to 32 kHz");
    }
    free(output);
}

static void test_clock_controller(void) {
    N60AdaptiveClockController controller;
    N60AdaptiveClockPolicy policy = N60AdaptiveClockPolicyMakeDefault(1024.0);
    policy.maximumCorrectionPPM = 500.0;
    policy.slewLimitPPMPerSecond = 100.0;
    check(N60AdaptiveClockControllerConfigure(&controller, policy), "configure clock controller");

    double previous = 0.0;
    for (uint32_t index = 0u; index < 100u; ++index) {
        double correction = N60AdaptiveClockControllerUpdate(&controller, 1228.8, 0.01);
        check(correction >= previous - 1.0e-9, "positive fill error increases correction monotonically during initial ramp");
        check(correction - previous <= 1.000001, "clock correction respects 100 ppm/s slew limit");
        previous = correction;
    }
    check(controller.correctionPPM > 70.0 && controller.correctionPPM <= 100.1, "controller accumulates bounded positive correction");

    for (uint32_t index = 0u; index < 2000u; ++index) {
        (void)N60AdaptiveClockControllerUpdate(&controller, 100000.0, 0.01);
    }
    check(fabs(controller.correctionPPM) <= 500.000001, "controller correction obeys hard ppm bound");
    check(controller.saturationEvents > 0u, "controller reports saturation telemetry");

    N60AdaptiveClockControllerReset(&controller);
    check(fabs(controller.correctionPPM) < 1.0e-12, "controller reset clears correction");
}

static void test_invalid_configuration(void) {
    N60AdaptiveSRCConfiguration configuration = N60AdaptiveSRCConfigurationMakeDefault(
        48000.0, 48000.0, 2u, 4096u, 1024u
    );
    check(N60AdaptiveSRCConfigurationIsValid(configuration), "default configuration is valid");
    configuration.channelCount = N60_ADAPTIVE_SRC_MAX_CHANNELS + 1u;
    check(!N60AdaptiveSRCConfigurationIsValid(configuration), "channel ceiling is enforced");

    N60AdaptiveSRCConfiguration highRate = N60AdaptiveSRCConfigurationMakeDefault(
        192000.0, 384000.0, 8u, 8192u, 2048u
    );
    check(N60AdaptiveSRCConfigurationIsValid(highRate), "configuration accepts high-rate operation through 384 kHz");
}

int main(void) {
    test_invalid_configuration();
    test_clock_controller();
    test_rate_conversion();
    test_downsample_alias_rejection();
    if (failures != 0) {
        fprintf(stderr, "%d PR69 adaptive SRC validation failure(s)\n", failures);
        return 1;
    }
    printf("PR69 adaptive clock + SRC validation passed\n");
    return 0;
}
