#include <assert.h>
#include <math.h>
#include <stdio.h>

#include "../NotchSixty/Audio/Realtime/N60SpeakerDriverProcessing.h"

static int close_enough(float a, float b) {
    return fabsf(a - b) < 1.0e-5f;
}

int main(void) {
    N60SpeakerDriverProcessingSnapshot snapshot =
        N60SpeakerDriverProcessingSnapshotMakeBypassed();

    // Trim/polarity are bus-local and deterministic.
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 2u, true, NULL, 0u, 0.5f, true,
        0u, 0.0f, false, 1.0f, 0.99f
    ));
    N60SpeakerDriverProcessingRuntime runtime;
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    float values[N60_SPEAKER_DRIVER_BUS_COUNT] = {0};
    values[2] = 1.0f;
    N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
    assert(close_enough(values[2], -0.5f));

    // Exact integer delay uses only preallocated memory.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 3u, true, NULL, 0u, 1.0f, false,
        2u, 0.0f, false, 1.0f, 0.99f
    ));
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    for (int n = 0; n < 3; ++n) {
        for (uint32_t i = 0; i < N60_SPEAKER_DRIVER_BUS_COUNT; ++i) values[i] = 0.0f;
        values[3] = n == 0 ? 1.0f : 0.0f;
        N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
        if (n < 2) assert(close_enough(values[3], 0.0f));
        else assert(close_enough(values[3], 1.0f));
    }

    // Limiter is instantaneous on attack and cannot emit above threshold.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 4u, true, NULL, 0u, 1.0f, false,
        0u, 0.0f, true, 0.25f, 0.99f
    ));
    assert(N60SpeakerDriverProcessingRuntimeConfigure(&runtime, snapshot));
    for (uint32_t i = 0; i < N60_SPEAKER_DRIVER_BUS_COUNT; ++i) values[i] = 0.0f;
    values[4] = 1.0f;
    N60SpeakerDriverProcessingRuntimeProcessValues(&runtime, values);
    assert(values[4] <= 0.25001f);

    // Delay capacity is fail-closed.
    snapshot = N60SpeakerDriverProcessingSnapshotMakeBypassed();
    assert(!N60SpeakerDriverProcessingSnapshotSetBus(
        &snapshot, 5u, true, NULL, 0u, 1.0f, false,
        N60_SPEAKER_DRIVER_MAX_DELAY_FRAMES, 0.0f, false, 1.0f, 0.99f
    ));

    puts("PR43 per-driver realtime runtime: PASS");
    return 0;
}
