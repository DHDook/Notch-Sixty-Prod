#include "N60AudioUnitLiveRackBridge.h"

#include <stdatomic.h>
#include <stdlib.h>

struct N60AudioUnitLiveRackFaultLatch {
    _Atomic uint64_t faultCount;
    _Atomic uint32_t lastSlotIndex;
    _Atomic uint32_t lastReason;
    _Atomic int32_t lastRenderStatus;
};

N60AudioUnitLiveRackFaultLatch *
N60AudioUnitLiveRackFaultLatchCreate(void) {
    N60AudioUnitLiveRackFaultLatch *latch =
        (N60AudioUnitLiveRackFaultLatch *)calloc(
            1u, sizeof(N60AudioUnitLiveRackFaultLatch)
        );
    if (latch == NULL) return NULL;
    atomic_store_explicit(&latch->lastSlotIndex, UINT32_MAX, memory_order_relaxed);
    return latch;
}

void N60AudioUnitLiveRackFaultLatchDestroy(
    N60AudioUnitLiveRackFaultLatch *latch
) {
    free(latch);
}

void N60AudioUnitLiveRackFaultLatchRecord(
    N60AudioUnitLiveRackFaultLatch *latch,
    uint32_t slotIndex,
    N60AudioUnitLiveRackFaultReason reason,
    int32_t renderStatus
) {
    if (latch == NULL || reason == N60AudioUnitLiveRackFaultNone) return;
    atomic_store_explicit(
        &latch->lastSlotIndex, slotIndex, memory_order_relaxed
    );
    atomic_store_explicit(
        &latch->lastReason, (uint32_t)reason, memory_order_relaxed
    );
    atomic_store_explicit(
        &latch->lastRenderStatus, renderStatus, memory_order_relaxed
    );
    atomic_fetch_add_explicit(
        &latch->faultCount, 1u, memory_order_release
    );
}

N60AudioUnitLiveRackFaultSnapshot
N60AudioUnitLiveRackFaultLatchGetSnapshot(
    const N60AudioUnitLiveRackFaultLatch *latch
) {
    N60AudioUnitLiveRackFaultSnapshot result = {0};
    result.lastSlotIndex = UINT32_MAX;
    if (latch == NULL) return result;
    result.faultCount = atomic_load_explicit(
        &latch->faultCount, memory_order_acquire
    );
    result.lastSlotIndex = atomic_load_explicit(
        &latch->lastSlotIndex, memory_order_relaxed
    );
    result.lastReason = (N60AudioUnitLiveRackFaultReason)atomic_load_explicit(
        &latch->lastReason, memory_order_relaxed
    );
    result.lastRenderStatus = atomic_load_explicit(
        &latch->lastRenderStatus, memory_order_relaxed
    );
    return result;
}
