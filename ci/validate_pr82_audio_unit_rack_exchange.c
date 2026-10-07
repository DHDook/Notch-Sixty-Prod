#include "N60AudioUnitRackExchange.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct {
    float gain;
    bool fail;
} GainProcessor;

static bool process_gain(
    void *context,
    const float *input,
    float *output,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
) {
    (void)sampleTime;
    GainProcessor *processor = (GainProcessor *)context;
    if (processor == NULL || processor->fail) return false;
    const size_t count = (size_t)frameCount * channelCount;
    for (size_t index = 0; index < count; ++index) {
        output[index] = input[index] * processor->gain;
    }
    return true;
}

static int fail(const char *message) {
    fprintf(stderr, "PR82 rack exchange: FAIL: %s\n", message);
    return EXIT_FAILURE;
}

static N60AudioUnitLiveRackProcessor make_processor(
    GainProcessor *context,
    uint64_t latency
) {
    N60AudioUnitLiveRackProcessor result = {0};
    result.context = context;
    result.process = process_gain;
    result.channelCount = 2u;
    result.maximumFramesPerSlice = 16u;
    result.latencyFrames = latency;
    return result;
}

static bool near(float lhs, float rhs) {
    return fabsf(lhs - rhs) <= 1.0e-6f;
}

int main(void) {
    GainProcessor a = {.gain = 1.0f, .fail = false};
    GainProcessor b = {.gain = 3.0f, .fail = false};
    GainProcessor bad = {.gain = 9.0f, .fail = true};

    N60AudioUnitLiveRackProcessor initial =
        make_processor(&a, 0u);
    N60AudioUnitRackExchange *exchange =
        N60AudioUnitRackExchangeCreate(
            2u, 16u, 0u, &initial, 1u
        );
    if (exchange == NULL) return fail("create");
    if (!N60AudioUnitRackExchangeAtomicsAreLockFree(exchange)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("required atomics are not lock-free");
    }

    N60AudioUnitLiveRackProcessor outer =
        N60AudioUnitRackExchangeGetProcessor(exchange);
    if (!N60AudioUnitLiveRackProcessorIsValid(&outer)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("outer processor invalid");
    }

    float input[8] = {
        1, 1,
        1, 1,
        1, 1,
        1, 1,
    };
    float output[8] = {0};

    if (!N60AudioUnitLiveRackProcess(
            &outer, input, output, 4u, 2u, 0.0)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("initial render");
    }
    for (size_t i = 0; i < 8u; ++i) {
        if (!near(output[i], 1.0f)) {
            N60AudioUnitRackExchangeDestroy(exchange);
            return fail("initial gain");
        }
    }

    const int32_t slotB =
        N60AudioUnitRackExchangeFindWritableSlot(exchange);
    if (slotB < 0) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("find slot B");
    }
    N60AudioUnitLiveRackProcessor processorB =
        make_processor(&b, 0u);
    if (!N60AudioUnitRackExchangePublish(
            exchange,
            (uint32_t)slotB,
            &processorB,
            2u,
            4u)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("publish B");
    }

    if (!N60AudioUnitLiveRackProcess(
            &outer, input, output, 4u, 2u, 4.0)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("transition render");
    }
    const float expected[4] = {1.5f, 2.0f, 2.5f, 3.0f};
    for (size_t frame = 0; frame < 4u; ++frame) {
        if (!near(output[frame * 2u], expected[frame])
            || !near(output[frame * 2u + 1u], expected[frame])) {
            N60AudioUnitRackExchangeDestroy(exchange);
            return fail("linear crossfade");
        }
    }

    N60AudioUnitRackExchangeStatus status =
        N60AudioUnitRackExchangeGetStatus(exchange);
    if (status.renderedGeneration != 2u
        || status.requestedSlot
            != N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT
        || status.transitionFramesRemaining != 0u) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("transition acknowledgement");
    }
    if (!N60AudioUnitRackExchangeSlotIsReclaimable(exchange, 0u)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("retired slot not reclaimable");
    }

    const int32_t slotBad =
        N60AudioUnitRackExchangeFindWritableSlot(exchange);
    if (slotBad < 0) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("find bad slot");
    }
    N60AudioUnitLiveRackProcessor badProcessor =
        make_processor(&bad, 0u);
    if (!N60AudioUnitRackExchangePublish(
            exchange,
            (uint32_t)slotBad,
            &badProcessor,
            3u,
            4u)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("publish bad processor");
    }

    if (!N60AudioUnitLiveRackProcess(
            &outer, input, output, 4u, 2u, 8.0)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("fallback render");
    }
    for (size_t i = 0; i < 8u; ++i) {
        if (!near(output[i], 3.0f)) {
            N60AudioUnitRackExchangeDestroy(exchange);
            return fail("old generation not preserved after candidate failure");
        }
    }
    status = N60AudioUnitRackExchangeGetStatus(exchange);
    if (status.renderedGeneration != 2u
        || status.transitionFailureCount != 1u
        || status.requestedSlot
            != N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("candidate failure acknowledgement");
    }

    const int32_t slotPass =
        N60AudioUnitRackExchangeFindWritableSlot(exchange);
    if (slotPass < 0) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("find passthrough slot");
    }
    if (!N60AudioUnitRackExchangePublish(
            exchange,
            (uint32_t)slotPass,
            NULL,
            4u,
            4u)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("publish passthrough");
    }
    if (!N60AudioUnitLiveRackProcess(
            &outer, input, output, 4u, 2u, 12.0)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("passthrough transition");
    }
    const float expectedPass[4] = {
        2.5f, 2.0f, 1.5f, 1.0f
    };
    for (size_t frame = 0; frame < 4u; ++frame) {
        if (!near(output[frame * 2u], expectedPass[frame])
            || !near(
                output[frame * 2u + 1u],
                expectedPass[frame])) {
            N60AudioUnitRackExchangeDestroy(exchange);
            return fail("passthrough crossfade");
        }
    }

    const int32_t mismatchSlot =
        N60AudioUnitRackExchangeFindWritableSlot(exchange);
    if (mismatchSlot < 0) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("find mismatch slot");
    }
    N60AudioUnitLiveRackProcessor mismatch =
        make_processor(&a, 1u);
    if (N60AudioUnitRackExchangePublish(
            exchange,
            (uint32_t)mismatchSlot,
            &mismatch,
            5u,
            4u)) {
        N60AudioUnitRackExchangeDestroy(exchange);
        return fail("latency-changing publish was accepted");
    }

    N60AudioUnitRackExchangeDestroy(exchange);
    puts("PR82 rack exchange: PASS");
    return EXIT_SUCCESS;
}
