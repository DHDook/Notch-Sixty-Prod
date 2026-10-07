#ifndef N60AudioUnitRackExchange_h
#define N60AudioUnitRackExchange_h

#include "N60AudioUnitLiveRackBridge.h"

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_AUDIO_UNIT_RACK_EXCHANGE_SLOT_COUNT 3u
#define N60_AUDIO_UNIT_RACK_EXCHANGE_NO_SLOT UINT32_MAX

typedef struct N60AudioUnitRackExchange N60AudioUnitRackExchange;
typedef struct N60AudioUnitStageFaultGate N60AudioUnitStageFaultGate;

// Per-stage fail-closed gate. Created/destroyed on the control plane. A gate
// is only returned when its atomic flag is lock-free on the current platform.
N60AudioUnitStageFaultGate * _Nullable
N60AudioUnitStageFaultGateCreate(void);

void N60AudioUnitStageFaultGateDestroy(
    N60AudioUnitStageFaultGate * _Nullable gate
);

void N60AudioUnitStageFaultGateTrip(
    N60AudioUnitStageFaultGate * _Nonnull gate
);

bool N60AudioUnitStageFaultGateIsTripped(
    const N60AudioUnitStageFaultGate * _Nonnull gate
);


typedef struct {
    uint64_t publishedGeneration;
    uint64_t renderedGeneration;
    uint64_t transitionFailureCount;
    uint64_t cancelledGeneration;
    uint32_t activeSlot;
    uint32_t requestedSlot;
    uint32_t transitionFramesRemaining;
} N60AudioUnitRackExchangeStatus;

// Control-plane lifecycle. Scratch memory is allocated here, never in render.
N60AudioUnitRackExchange * _Nullable
N60AudioUnitRackExchangeCreate(
    uint32_t channelCount,
    uint32_t maximumFramesPerSlice,
    uint64_t latencyFrames,
    const N60AudioUnitLiveRackProcessor * _Nullable initialProcessor,
    uint64_t initialGeneration
);

void N60AudioUnitRackExchangeDestroy(
    N60AudioUnitRackExchange * _Nullable exchange
);

// Control-plane publication. Call FindWritableSlot first, retain the processor
// context for that slot, then publish. Publication is release/acquire ordered.
int32_t N60AudioUnitRackExchangeFindWritableSlot(
    const N60AudioUnitRackExchange * _Nonnull exchange
);

bool N60AudioUnitRackExchangePublish(
    N60AudioUnitRackExchange * _Nonnull exchange,
    uint32_t slotIndex,
    const N60AudioUnitLiveRackProcessor * _Nullable processor,
    uint64_t generation,
    uint32_t transitionFrames
);

bool N60AudioUnitRackExchangeCancelPending(
    N60AudioUnitRackExchange * _Nonnull exchange,
    uint64_t generation
);

bool N60AudioUnitRackExchangeSlotIsReclaimable(
    const N60AudioUnitRackExchange * _Nonnull exchange,
    uint32_t slotIndex
);

N60AudioUnitRackExchangeStatus N60AudioUnitRackExchangeGetStatus(
    const N60AudioUnitRackExchange * _Nonnull exchange
);

bool N60AudioUnitRackExchangeAtomicsAreLockFree(
    const N60AudioUnitRackExchange * _Nonnull exchange
);

N60AudioUnitLiveRackProcessor N60AudioUnitRackExchangeGetProcessor(
    N60AudioUnitRackExchange * _Nonnull exchange
);

// Realtime entry point. No allocation, locks, logging, dispatch, discovery,
// state serialization, or graph construction.
bool N60AudioUnitRackExchangeProcess(
    void * _Nullable context,
    const float * _Nonnull inputInterleaved,
    float * _Nonnull outputInterleaved,
    uint32_t frameCount,
    uint32_t channelCount,
    double sampleTime
);

#ifdef __cplusplus
}
#endif

#endif
