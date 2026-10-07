#include "N60AudioUnitRackExchange.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    N60AudioUnitLiveRackProcessor processor;
    bool passthrough;
    uint64_t generation;
    _Atomic uint32_t readers;
} N60AudioUnitRackExchangeSlot;

struct N60AudioUnitRackExchange {
    uint32_t channelCount;
    uint32_t maximumFramesPerSlice;
    uint64_t latencyFrames;
    float *scratchOld;
    float *scratchNew;

    N60AudioUnitRackExchangeSlot
        slots[N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT];

    _Atomic uint32_t activeSlot;
    _Atomic uint32_t requestedSlot;
    _Atomic uint32_t requestedTransitionFrames;
    _Atomic uint64_t publishedGeneration;
    _Atomic uint64_t renderedGeneration;
    _Atomic uint64_t transitionFailureCount;

    // Realtime-thread-owned transition cursor.
    _Atomic uint32_t transitionPosition;
};

static bool N60AudioUnitRackExchangeProcessorCompatible(
    const N60AudioUnitRackExchange *exchange,
    const N60AudioUnitLiveRackProcessor *processor
) {
    if (processor == NULL) return true;
    return N60AudioUnitLiveRackProcessorIsValid(processor)
        && processor->channelCount == exchange->channelCount
        && processor->maximumFramesPerSlice
            >= exchange->maximumFramesPerSlice
        && processor->latencyFrames == exchange->latencyFrames;
}

static bool N60AudioUnitRackExchangeRunSlot(
    N60AudioUnitRackExchangeSlot *slot,
    const float *inputInterleaved,
    float *outputInterleaved,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
) {
    if (slot->passthrough) {
        memcpy(
            outputInterleaved,
            inputInterleaved,
            (size_t)frameCount * channelCount * sizeof(float)
        );
        return true;
    }
    return N60AudioUnitLiveRackProcess(
        &slot->processor,
        inputInterleaved,
        outputInterleaved,
        frameCount,
        channelCount,
        sampleTime
    );
}

static N60AudioUnitRackExchangeSlot *
N60AudioUnitRackExchangeAcquireSlot(
    N60AudioUnitRackExchange *exchange,
    uint32_t slotIndex
) {
    if (slotIndex >= N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT) {
        return NULL;
    }
    N60AudioUnitRackExchangeSlot *slot = &exchange->slots[slotIndex];
    atomic_fetch_add_explicit(
        &slot->readers,
        1u,
        memory_order_acquire
    );
    return slot;
}

static void N60AudioUnitRackExchangeReleaseSlot(
    N60AudioUnitRackExchangeSlot *slot
) {
    if (slot == NULL) return;
    atomic_fetch_sub_explicit(
        &slot->readers,
        1u,
        memory_order_release
    );
}

N60AudioUnitRackExchange *
N60AudioUnitRackExchangeCreate(
    uint32_t channelCount,
    uint32_t maximumFramesPerSlice,
    uint64_t latencyFrames,
    const N60AudioUnitLiveRackProcessor *initialProcessor,
    uint64_t initialGeneration
) {
    if (channelCount == 0u
        || channelCount > 32u
        || maximumFramesPerSlice < 16u
        || maximumFramesPerSlice > 65536u
        || initialGeneration == 0u) {
        return NULL;
    }

    N60AudioUnitRackExchange *exchange =
        (N60AudioUnitRackExchange *)calloc(1u, sizeof(*exchange));
    if (exchange == NULL) return NULL;

    exchange->channelCount = channelCount;
    exchange->maximumFramesPerSlice = maximumFramesPerSlice;
    exchange->latencyFrames = latencyFrames;

    const size_t sampleCount =
        (size_t)maximumFramesPerSlice * channelCount;
    exchange->scratchOld = (float *)calloc(
        sampleCount, sizeof(float)
    );
    exchange->scratchNew = (float *)calloc(
        sampleCount, sizeof(float)
    );
    if (exchange->scratchOld == NULL || exchange->scratchNew == NULL) {
        free(exchange->scratchOld);
        free(exchange->scratchNew);
        free(exchange);
        return NULL;
    }

    if (!N60AudioUnitRackExchangeProcessorCompatible(
            exchange, initialProcessor)) {
        free(exchange->scratchOld);
        free(exchange->scratchNew);
        free(exchange);
        return NULL;
    }

    for (uint32_t index = 0u;
         index < N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT;
         ++index) {
        atomic_init(&exchange->slots[index].readers, 0u);
        exchange->slots[index].passthrough = true;
        exchange->slots[index].generation = 0u;
    }

    if (initialProcessor != NULL) {
        exchange->slots[0].processor = *initialProcessor;
        exchange->slots[0].passthrough = false;
    }
    exchange->slots[0].generation = initialGeneration;

    atomic_init(&exchange->activeSlot, 0u);
    atomic_init(
        &exchange->requestedSlot,
        N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT
    );
    atomic_init(&exchange->requestedTransitionFrames, 0u);
    atomic_init(&exchange->publishedGeneration, initialGeneration);
    atomic_init(&exchange->renderedGeneration, initialGeneration);
    atomic_init(&exchange->transitionFailureCount, 0u);
    atomic_init(&exchange->transitionPosition, 0u);
    return exchange;
}

void N60AudioUnitRackExchangeDestroy(
    N60AudioUnitRackExchange *exchange
) {
    if (exchange == NULL) return;
    free(exchange->scratchOld);
    free(exchange->scratchNew);
    free(exchange);
}

int32_t N60AudioUnitRackExchangeFindWritableSlot(
    const N60AudioUnitRackExchange *exchange
) {
    if (exchange == NULL) return -1;
    const uint32_t active = atomic_load_explicit(
        &exchange->activeSlot, memory_order_acquire
    );
    const uint32_t requested = atomic_load_explicit(
        &exchange->requestedSlot, memory_order_acquire
    );
    if (requested != N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT) {
        return -1;
    }

    for (uint32_t index = 0u;
         index < N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT;
         ++index) {
        if (index == active || index == requested) continue;
        if (atomic_load_explicit(
                &exchange->slots[index].readers,
                memory_order_acquire) == 0u) {
            return (int32_t)index;
        }
    }
    return -1;
}

bool N60AudioUnitRackExchangePublish(
    N60AudioUnitRackExchange *exchange,
    uint32_t slotIndex,
    const N60AudioUnitLiveRackProcessor *processor,
    uint64_t generation,
    uint32_t transitionFrames
) {
    if (exchange == NULL
        || slotIndex >= N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT
        || generation == 0u
        || !N60AudioUnitRackExchangeProcessorCompatible(
            exchange, processor)) {
        return false;
    }

    const uint32_t active = atomic_load_explicit(
        &exchange->activeSlot, memory_order_acquire
    );
    const uint32_t requested = atomic_load_explicit(
        &exchange->requestedSlot, memory_order_acquire
    );
    if (requested != N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT
        || slotIndex == active
        || atomic_load_explicit(
            &exchange->slots[slotIndex].readers,
            memory_order_acquire) != 0u) {
        return false;
    }

    N60AudioUnitRackExchangeSlot *slot =
        &exchange->slots[slotIndex];
    memset(&slot->processor, 0, sizeof(slot->processor));
    if (processor != NULL) {
        slot->processor = *processor;
        slot->passthrough = false;
    } else {
        slot->passthrough = true;
    }
    slot->generation = generation;

    atomic_store_explicit(
        &exchange->requestedTransitionFrames,
        transitionFrames,
        memory_order_relaxed
    );
    atomic_store_explicit(
        &exchange->publishedGeneration,
        generation,
        memory_order_release
    );
    atomic_store_explicit(
        &exchange->requestedSlot,
        slotIndex,
        memory_order_release
    );
    return true;
}

bool N60AudioUnitRackExchangeSlotIsReclaimable(
    const N60AudioUnitRackExchange *exchange,
    uint32_t slotIndex
) {
    if (exchange == NULL
        || slotIndex >= N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT) {
        return false;
    }
    const uint32_t active = atomic_load_explicit(
        &exchange->activeSlot, memory_order_acquire
    );
    const uint32_t requested = atomic_load_explicit(
        &exchange->requestedSlot, memory_order_acquire
    );
    return slotIndex != active
        && slotIndex != requested
        && atomic_load_explicit(
            &exchange->slots[slotIndex].readers,
            memory_order_acquire) == 0u;
}

bool N60AudioUnitRackExchangeAtomicsAreLockFree(
    const N60AudioUnitRackExchange *exchange
) {
    if (exchange == NULL) return false;
    if (!atomic_is_lock_free(&exchange->activeSlot)
        || !atomic_is_lock_free(&exchange->requestedSlot)
        || !atomic_is_lock_free(&exchange->requestedTransitionFrames)
        || !atomic_is_lock_free(&exchange->publishedGeneration)
        || !atomic_is_lock_free(&exchange->renderedGeneration)
        || !atomic_is_lock_free(&exchange->transitionFailureCount)
        || !atomic_is_lock_free(&exchange->transitionPosition)) {
        return false;
    }
    for (uint32_t index = 0u;
         index < N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT;
         ++index) {
        if (!atomic_is_lock_free(&exchange->slots[index].readers)) {
            return false;
        }
    }
    return true;
}

N60AudioUnitRackExchangeStatus N60AudioUnitRackExchangeGetStatus(
    const N60AudioUnitRackExchange *exchange
) {
    N60AudioUnitRackExchangeStatus result = {0};
    result.activeSlot = N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT;
    result.requestedSlot = N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT;
    if (exchange == NULL) return result;

    result.publishedGeneration = atomic_load_explicit(
        &exchange->publishedGeneration, memory_order_acquire
    );
    result.renderedGeneration = atomic_load_explicit(
        &exchange->renderedGeneration, memory_order_acquire
    );
    result.transitionFailureCount = atomic_load_explicit(
        &exchange->transitionFailureCount, memory_order_acquire
    );
    result.activeSlot = atomic_load_explicit(
        &exchange->activeSlot, memory_order_acquire
    );
    result.requestedSlot = atomic_load_explicit(
        &exchange->requestedSlot, memory_order_acquire
    );

    if (result.requestedSlot
        != N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT) {
        const uint32_t total = atomic_load_explicit(
            &exchange->requestedTransitionFrames,
            memory_order_relaxed
        );
        const uint32_t position = atomic_load_explicit(
            &exchange->transitionPosition,
            memory_order_acquire
        );
        result.transitionFramesRemaining =
            position >= total ? 0u : total - position;
    }
    return result;
}

bool N60AudioUnitRackExchangeProcess(
    void *context,
    const float *inputInterleaved,
    float *outputInterleaved,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
) {
    N60AudioUnitRackExchange *exchange =
        (N60AudioUnitRackExchange *)context;
    if (exchange == NULL
        || inputInterleaved == NULL
        || outputInterleaved == NULL
        || channelCount != exchange->channelCount
        || frameCount > exchange->maximumFramesPerSlice) {
        return false;
    }

    const uint32_t activeIndex = atomic_load_explicit(
        &exchange->activeSlot, memory_order_acquire
    );
    const uint32_t requestedIndex = atomic_load_explicit(
        &exchange->requestedSlot, memory_order_acquire
    );

    N60AudioUnitRackExchangeSlot *active =
        N60AudioUnitRackExchangeAcquireSlot(
            exchange, activeIndex
        );
    if (active == NULL) return false;

    if (requestedIndex == N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT) {
        const bool ok = N60AudioUnitRackExchangeRunSlot(
            active,
            inputInterleaved,
            outputInterleaved,
            frameCount,
            channelCount,
            sampleTime
        );
        N60AudioUnitRackExchangeReleaseSlot(active);
        return ok;
    }

    N60AudioUnitRackExchangeSlot *requested =
        N60AudioUnitRackExchangeAcquireSlot(
            exchange, requestedIndex
        );
    if (requested == NULL) {
        N60AudioUnitRackExchangeReleaseSlot(active);
        return false;
    }

    const bool oldOK = N60AudioUnitRackExchangeRunSlot(
        active,
        inputInterleaved,
        exchange->scratchOld,
        frameCount,
        channelCount,
        sampleTime
    );
    const bool newOK = N60AudioUnitRackExchangeRunSlot(
        requested,
        inputInterleaved,
        exchange->scratchNew,
        frameCount,
        channelCount,
        sampleTime
    );

    if (!newOK && oldOK) {
        memcpy(
            outputInterleaved,
            exchange->scratchOld,
            (size_t)frameCount * channelCount * sizeof(float)
        );
        atomic_store_explicit(
            &exchange->transitionPosition,
            0u,
            memory_order_relaxed
        );
        atomic_fetch_add_explicit(
            &exchange->transitionFailureCount,
            1u,
            memory_order_release
        );
        atomic_store_explicit(
            &exchange->requestedSlot,
            N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT,
            memory_order_release
        );
        N60AudioUnitRackExchangeReleaseSlot(requested);
        N60AudioUnitRackExchangeReleaseSlot(active);
        return true;
    }

    if (!oldOK && newOK) {
        memcpy(
            outputInterleaved,
            exchange->scratchNew,
            (size_t)frameCount * channelCount * sizeof(float)
        );
        atomic_store_explicit(
            &exchange->transitionPosition,
            0u,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &exchange->activeSlot,
            requestedIndex,
            memory_order_release
        );
        atomic_store_explicit(
            &exchange->renderedGeneration,
            requested->generation,
            memory_order_release
        );
        atomic_store_explicit(
            &exchange->requestedSlot,
            N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT,
            memory_order_release
        );
        N60AudioUnitRackExchangeReleaseSlot(requested);
        N60AudioUnitRackExchangeReleaseSlot(active);
        return true;
    }

    if (!oldOK || !newOK) {
        N60AudioUnitRackExchangeReleaseSlot(requested);
        N60AudioUnitRackExchangeReleaseSlot(active);
        return false;
    }

    const uint32_t transitionFrames = atomic_load_explicit(
        &exchange->requestedTransitionFrames,
        memory_order_relaxed
    );
    if (transitionFrames == 0u) {
        memcpy(
            outputInterleaved,
            exchange->scratchNew,
            (size_t)frameCount * channelCount * sizeof(float)
        );
        atomic_store_explicit(
            &exchange->transitionPosition,
            0u,
            memory_order_relaxed
        );
        atomic_store_explicit(
            &exchange->activeSlot,
            requestedIndex,
            memory_order_release
        );
        atomic_store_explicit(
            &exchange->renderedGeneration,
            requested->generation,
            memory_order_release
        );
        atomic_store_explicit(
            &exchange->requestedSlot,
            N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT,
            memory_order_release
        );
    } else {
        for (uint32_t frame = 0u; frame < frameCount; ++frame) {
            const uint32_t transitionPosition =
                atomic_load_explicit(
                    &exchange->transitionPosition,
                    memory_order_relaxed
                );
            const uint64_t absolute =
                (uint64_t)transitionPosition + frame + 1u;
            float alpha =
                absolute >= transitionFrames
                    ? 1.0f
                    : (float)absolute / (float)transitionFrames;
            const float oldGain = 1.0f - alpha;
            const size_t base = (size_t)frame * channelCount;
            for (uint32_t channel = 0u;
                 channel < channelCount;
                 ++channel) {
                const size_t index = base + channel;
                outputInterleaved[index] =
                    exchange->scratchOld[index] * oldGain
                    + exchange->scratchNew[index] * alpha;
            }
        }

        const uint32_t priorPosition =
            atomic_load_explicit(
                &exchange->transitionPosition,
                memory_order_relaxed
            );
        const uint64_t next =
            (uint64_t)priorPosition + frameCount;
        const uint32_t nextPosition =
            next >= transitionFrames
                ? transitionFrames
                : (uint32_t)next;
        atomic_store_explicit(
            &exchange->transitionPosition,
            nextPosition,
            memory_order_release
        );
        if (nextPosition >= transitionFrames) {
            atomic_store_explicit(
                &exchange->transitionPosition,
                0u,
                memory_order_relaxed
            );
            atomic_store_explicit(
                &exchange->activeSlot,
                requestedIndex,
                memory_order_release
            );
            atomic_store_explicit(
                &exchange->renderedGeneration,
                requested->generation,
                memory_order_release
            );
            atomic_store_explicit(
                &exchange->requestedSlot,
                N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT,
                memory_order_release
            );
        }
    }

    N60AudioUnitRackExchangeReleaseSlot(requested);
    N60AudioUnitRackExchangeReleaseSlot(active);
    return true;
}

N60AudioUnitLiveRackProcessor N60AudioUnitRackExchangeGetProcessor(
    N60AudioUnitRackExchange *exchange
) {
    N60AudioUnitLiveRackProcessor result = {0};
    if (exchange == NULL) return result;
    result.context = exchange;
    result.process = N60AudioUnitRackExchangeProcess;
    result.channelCount = exchange->channelCount;
    result.maximumFramesPerSlice = exchange->maximumFramesPerSlice;
    result.latencyFrames = exchange->latencyFrames;
    return result;
}
