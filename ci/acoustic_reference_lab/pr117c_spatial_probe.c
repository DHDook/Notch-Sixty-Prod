/*
 * PR117C normalized SOFA / spatial reference probe.
 * This uses the actual production direction matcher and binaural renderer.
 * Every HRIR and position below is synthetic, normalized in memory and
 * delay-baked. No HDF5 parser, input device, headphone or SOFA file is used.
 */
#include <assert.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60BinauralRenderer.h"

#define PR117C_M 4u
#define PR117C_T 8u

static void verify_direction_wrap(void) {
    const double azimuth[] = {-179.0, 155.0};
    const double elevation[] = {0.0, 0.0};
    const double distance[] = {1.0, 1.0};
    const float zeros[2] = {0.0f, 0.0f};
    N60SOFAHRTFNormalizedView view = {
        .sampleRate = 48000.0, .measurementCount = 2u, .tapCount = 1u,
        .azimuthDegrees = azimuth, .elevationDegrees = elevation,
        .distanceMeters = distance, .leftIR = zeros, .rightIR = zeros
    };
    N60BinauralSourcePosition target =
        N60BinauralDefaultPositionForRole(N60ProgramChannelRoleFrontCenter);
    target.azimuthDegrees = 179.0;
    const int32_t nearest = N60SOFAFindNearestMeasurement(&view, target);
    assert(nearest == 0);
    printf("WRAP %d\n", (int)nearest);

    double invalidAzimuth[] = {NAN, 155.0};
    N60SOFAHRTFNormalizedView malformed = view;
    malformed.azimuthDegrees = invalidAzimuth;
    assert(!N60SOFAHRTFNormalizedViewIsValid(&malformed, 8192u));
    assert(N60SOFAFindNearestMeasurement(&malformed, target) == -1);
    puts("BADVIEW 1");
}

static void probe_rate(double rate) {
    /* Input directions deliberately out of channel order: indices 1,2. */
    const double azimuth[PR117C_M] = {0.0, 30.0, -30.0, 120.0};
    const double elevation[PR117C_M] = {0.0, 0.0, 0.0, 0.0};
    const double distance[PR117C_M] = {1.0, 1.0, 1.0, 1.0};
    float left[PR117C_M * PR117C_T] = {0};
    float right[PR117C_M * PR117C_T] = {0};

    /* Left virtual speaker (-30°), SOFA measurement index 2. */
    left[2u * PR117C_T + 0u] = 0.7f;
    left[2u * PR117C_T + 1u] = 0.1f;
    right[2u * PR117C_T + 2u] = 0.2f;

    /* Right virtual speaker (+30°), SOFA measurement index 1. */
    left[1u * PR117C_T + 3u] = 0.15f;
    right[1u * PR117C_T + 1u] = 0.6f;
    right[1u * PR117C_T + 4u] = 0.1f;

    const N60SOFAHRTFNormalizedView view = {
        .sampleRate = rate, .measurementCount = PR117C_M,
        .tapCount = PR117C_T, .azimuthDegrees = azimuth,
        .elevationDegrees = elevation, .distanceMeters = distance,
        .leftIR = left, .rightIR = right
    };
    const N60ProgramChannelLayout layout =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor profile = N60BinauralProfileDescriptorMake(
        rate, layout, N60BinauralProfileKindHRTF, PR117C_T
    );
    assert(N60BinauralProfileDescriptorIsValid(&profile, 8192u));
    for (uint32_t channel = 0; channel < 2u; ++channel) {
        const int32_t selected = N60SOFAFindNearestMeasurement(
            &view, profile.sources[channel]
        );
        printf("SELECT %.0f %u %d\n", rate, channel, (int)selected);
        assert(selected == (channel == 0u ? 2 : 1));
    }

    N60BinauralRenderer *renderer = N60BinauralRendererCreate();
    assert(renderer != NULL);
    N60SOFAHRTFNormalizedView wrongRate = view;
    wrongRate.sampleRate = rate * 0.5;
    assert(!N60BinauralRendererPrepareFromSOFAView(
        renderer, profile, &wrongRate));
    assert(!renderer->prepared);
    printf("RATEREJECT %.0f 1\n", rate);

    /* Prepare once per rate, reset for each isolated input speaker. */
    assert(N60BinauralRendererPrepareFromSOFAView(renderer, profile, &view));
    assert(N60BinauralRendererLatencyFrames(renderer) == 128u);
    printf("SPATLAT %.0f %llu\n", rate,
           (unsigned long long)N60BinauralRendererLatencyFrames(renderer));
    for (uint32_t channel = 0; channel < 2u; ++channel) {
        N60BinauralRendererResetRuntime(renderer);
        for (uint32_t frame = 0; frame <= 138u; ++frame) {
            float source[2] = {0.0f, 0.0f};
            source[channel] = frame == 0u ? 1.0f : 0.0f;
            float earL = 0.0f;
            float earR = 0.0f;
            assert(N60BinauralRendererProcessFrame(
                renderer, source, 2u, &earL, &earR));
            assert(isfinite(earL) && isfinite(earR));
            if (frame == 0u || frame == 127u ||
                (frame >= 128u && frame <= 137u)) {
                printf("SPAT %.0f %u %u %.9g %.9g\n",
                       rate, channel, frame, (double)earL, (double)earR);
            }
        }
    }
    N60BinauralRendererDestroy(renderer);
}

int main(void) {
    verify_direction_wrap();
    const double rates[] = {
        44100., 48000., 88200., 96000.,
        176400., 192000., 352800., 384000.
    };
    for (size_t i = 0u; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        probe_rate(rates[i]);
    }
    puts("END");
    return 0;
}
