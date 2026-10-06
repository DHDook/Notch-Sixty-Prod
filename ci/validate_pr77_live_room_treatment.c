#include <assert.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60MIMOTreatmentLiveIntegration.h"

static void set_tap(
    float *taps,
    uint32_t channels,
    uint32_t tapCount,
    uint32_t output,
    uint32_t input,
    uint32_t tap,
    float value
) {
    taps[N60MIMOFIRTapOffset(
        channels, tapCount, output, input, tap
    )] = value;
}

static N60MIMOTreatmentLiveIntegration *make_identity_integration(
    uint32_t physicalChannels
) {
    const uint32_t treatmentChannels = 2u;
    const uint32_t tapCount = 512u;
    const uint32_t declared = 256u;
    uint32_t map[2] = {1u, 3u};
    float *taps = calloc(
        (size_t)treatmentChannels
            * treatmentChannels
            * tapCount,
        sizeof(float)
    );
    assert(taps != NULL);
    set_tap(taps, treatmentChannels, tapCount, 0u, 0u, declared, 1.0f);
    set_tap(taps, treatmentChannels, tapCount, 1u, 1u, declared, 1.0f);
    N60MIMOTreatmentLiveIntegration *integration =
        N60MIMOTreatmentLiveIntegrationCreate(
            physicalChannels,
            treatmentChannels,
            map,
            taps,
            tapCount,
            declared,
            8u,
            4u
        );
    free(taps);
    return integration;
}

static void test_all_physical_channels_latency_match(void) {
    N60MIMOTreatmentLiveIntegration *integration =
        make_identity_integration(4u);
    assert(integration != NULL);
    N60MIMOTreatmentLiveSetAuthorized(integration, true);

    const uint32_t latency =
        N60MIMOTreatmentLiveGetSnapshot(integration).totalLatencyFrames;
    assert(latency == 512u);

    float frame[4] = {0};
    for (uint32_t index = 0u; index < latency + 4u; ++index) {
        frame[0] = index == 0u ? 0.1f : 0.0f;
        frame[1] = index == 0u ? 0.2f : 0.0f;
        frame[2] = index == 0u ? 0.3f : 0.0f;
        frame[3] = index == 0u ? 0.4f : 0.0f;
        assert(N60MIMOTreatmentLiveProcessPhysicalFrame(
            integration, frame, 4u
        ));
        if (index < latency) {
            for (uint32_t channel = 0u; channel < 4u; ++channel) {
                assert(fabsf(frame[channel]) < 1.0e-5f);
            }
        } else if (index == latency) {
            assert(fabsf(frame[0] - 0.1f) < 1.0e-5f);
            assert(fabsf(frame[1] - 0.2f) < 1.0e-5f);
            assert(fabsf(frame[2] - 0.3f) < 1.0e-5f);
            assert(fabsf(frame[3] - 0.4f) < 1.0e-5f);
        }
    }
    N60MIMOTreatmentLiveIntegrationDestroy(integration);
}

static void test_arming_replaces_only_selected_physical_sources(void) {
    const uint32_t treatmentChannels = 2u;
    const uint32_t tapCount = 512u;
    const uint32_t declared = 256u;
    uint32_t map[2] = {0u, 2u};
    float *taps = calloc(
        (size_t)treatmentChannels
            * treatmentChannels
            * tapCount,
        sizeof(float)
    );
    assert(taps != NULL);
    set_tap(taps, treatmentChannels, tapCount, 0u, 0u, declared, 0.5f);
    set_tap(taps, treatmentChannels, tapCount, 0u, 1u, declared, 0.25f);
    set_tap(taps, treatmentChannels, tapCount, 1u, 0u, declared, 0.25f);
    set_tap(taps, treatmentChannels, tapCount, 1u, 1u, declared, 0.5f);

    N60MIMOTreatmentLiveIntegration *integration =
        N60MIMOTreatmentLiveIntegrationCreate(
            4u, treatmentChannels, map, taps, tapCount, declared, 1u, 1u
        );
    free(taps);
    assert(integration != NULL);
    N60MIMOTreatmentLiveSetAuthorized(integration, true);
    assert(N60MIMOTreatmentLiveRequestArm(integration));

    const uint32_t latency =
        N60MIMOTreatmentLiveGetSnapshot(integration).totalLatencyFrames;
    float frame[4] = {0};

    for (uint32_t index = 0u; index < latency + 2u; ++index) {
        frame[0] = index == 0u ? 0.8f : 0.0f;
        frame[1] = index == 0u ? 0.3f : 0.0f;
        frame[2] = index == 0u ? 0.4f : 0.0f;
        frame[3] = index == 0u ? 0.2f : 0.0f;
        assert(N60MIMOTreatmentLiveProcessPhysicalFrame(
            integration, frame, 4u
        ));
        if (index == latency) {
            // selected 0/2 are matrix-treated: [0.5 .25; .25 .5] * [.8 .4]
            assert(fabsf(frame[0] - 0.5f) < 1.0e-4f);
            assert(fabsf(frame[2] - 0.4f) < 1.0e-4f);
            // untreated channels preserve their exact latency-matched identity.
            assert(fabsf(frame[1] - 0.3f) < 1.0e-5f);
            assert(fabsf(frame[3] - 0.2f) < 1.0e-5f);
        }
    }

    const N60MIMOTreatmentLiveSnapshot snapshot =
        N60MIMOTreatmentLiveGetSnapshot(integration);
    assert(snapshot.transition.authorized);
    assert(snapshot.transition.state == N60MIMOTreatmentStateActive);
    assert(snapshot.transition.treatmentMix > 0.999f);
    assert(snapshot.integrationFailures == 0u);
    N60MIMOTreatmentLiveIntegrationDestroy(integration);
}

static void test_protection_clamp_latches_fault(void) {
    const uint32_t tapCount = 512u;
    const uint32_t declared = 256u;
    uint32_t map[1] = {0u};
    float *taps = calloc(tapCount, sizeof(float));
    assert(taps != NULL);
    taps[declared] = 2.0f;

    N60MIMOTreatmentLiveIntegration *integration =
        N60MIMOTreatmentLiveIntegrationCreate(
            1u, 1u, map, taps, tapCount, declared, 1u, 1u
        );
    free(taps);
    assert(integration != NULL);
    N60MIMOTreatmentLiveSetAuthorized(integration, true);
    assert(N60MIMOTreatmentLiveRequestArm(integration));

    const uint32_t latency =
        N60MIMOTreatmentLiveGetSnapshot(integration).totalLatencyFrames;
    float frame[1] = {0};
    for (uint32_t index = 0u; index < latency + 3u; ++index) {
        frame[0] = index == 0u ? 0.75f : 0.0f;
        assert(N60MIMOTreatmentLiveProcessPhysicalFrame(
            integration, frame, 1u
        ));
        assert(isfinite(frame[0]));
        assert(frame[0] <= 1.000001f);
        assert(frame[0] >= -1.000001f);
    }

    const N60MIMOTreatmentLiveSnapshot snapshot =
        N60MIMOTreatmentLiveGetSnapshot(integration);
    assert(snapshot.protectionClampSamples > 0u);
    assert(snapshot.transition.fault == N60MIMOTreatmentFaultProtection
        || snapshot.transition.state == N60MIMOTreatmentStateFaultFading
        || snapshot.transition.state == N60MIMOTreatmentStateFaulted);
    N60MIMOTreatmentLiveIntegrationDestroy(integration);
}

static void test_invalid_physical_map_fails_closed(void) {
    uint32_t duplicate[2] = {1u, 1u};
    float taps[2u * 2u * 512u] = {0};
    assert(N60MIMOTreatmentLiveIntegrationCreate(
        4u, 2u, duplicate, taps, 512u, 256u, 8u, 4u
    ) == NULL);

    uint32_t outOfRange[1] = {4u};
    assert(N60MIMOTreatmentLiveIntegrationCreate(
        4u, 1u, outOfRange, taps, 512u, 256u, 8u, 4u
    ) == NULL);
}

int main(void) {
    test_all_physical_channels_latency_match();
    test_arming_replaces_only_selected_physical_sources();
    test_protection_clamp_latches_fault();
    test_invalid_physical_map_fails_closed();
    printf("PR77 live room-treatment integration validation passed\n");
    return 0;
}
