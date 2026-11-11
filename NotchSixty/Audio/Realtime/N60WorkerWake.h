#ifndef N60_WORKER_WAKE_H
#define N60_WORKER_WAKE_H

// E20 S6: the semaphores that wake the parallel-render worker threads.
//
// n60_graph_wake_fn runs on the realtime audio thread, where the only permitted action is signalling a semaphore. This
// header holds three Mach semaphores (one per worker, indices 1..3) and a stop flag. Mach semaphores are the primitive
// Core Audio's own workers use: semaphore_signal does not allocate, take a lock or enter the scheduler for a waiter that
// is already runnable beyond the wake itself.
//
// - allocation: N60WorkerWakeCreate allocates once, on the control thread; nothing on the realtime path allocates.
// - synchronisation: lock-free. Signal is semaphore_signal; Wait is semaphore_wait (worker threads only).
// - latency: none added to the audio path; a worker wakes within one scheduler turn.
// - rates and channels: independent of both.
// - reset: Create returns the semaphores at zero. Stop sets the flag and signals every semaphore so a waiting worker
//   returns false and exits; a context is not reused after Stop.

#include <mach/mach.h>
#include <mach/semaphore.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>

#define N60_WORKER_WAKE_MAX 3u

#include <stdatomic.h>
typedef struct N60WorkerWake {
    semaphore_t sem[N60_WORKER_WAKE_MAX];
    atomic_bool stop;
    atomic_uint signals;  // wake calls since Create (diagnostic; tests read it)
} N60WorkerWake;

static inline void *N60WorkerWakeCreate(void) {
    N60WorkerWake *w = (N60WorkerWake *)calloc(1, sizeof(N60WorkerWake));
    if (w == NULL) return NULL;
    for (uint32_t i = 0; i < N60_WORKER_WAKE_MAX; ++i) {
        if (semaphore_create(mach_task_self(), &w->sem[i], SYNC_POLICY_FIFO, 0) != KERN_SUCCESS) {
            for (uint32_t k = 0; k < i; ++k) semaphore_destroy(mach_task_self(), w->sem[k]);
            free(w);
            return NULL;
        }
    }
    atomic_init(&w->stop, false);
    atomic_init(&w->signals, 0);
    return w;
}

// Only after every worker thread has returned from Wait.
static inline void N60WorkerWakeDestroy(void *context) {
    N60WorkerWake *w = (N60WorkerWake *)context;
    if (w == NULL) return;
    for (uint32_t i = 0; i < N60_WORKER_WAKE_MAX; ++i) semaphore_destroy(mach_task_self(), w->sem[i]);
    free(w);
}


// n60_graph_wake_fn: realtime thread. Wakes workers 1..count (count <= N60_WORKER_WAKE_MAX).
static inline void N60WorkerWakeSignal(void *context, uint32_t count) {
    N60WorkerWake *w = (N60WorkerWake *)context;
    if (w == NULL) return;
    if (count > N60_WORKER_WAKE_MAX) count = N60_WORKER_WAKE_MAX;
    atomic_fetch_add_explicit(&w->signals, 1, memory_order_relaxed);
    for (uint32_t i = 0; i < count; ++i) semaphore_signal(w->sem[i]);
}

// Worker thread: blocks until worker `index` (1...3) is woken. False when the pool is stopping.
static inline bool N60WorkerWakeWait(void *context, uint32_t index) {
    N60WorkerWake *w = (N60WorkerWake *)context;
    if (w == NULL || index == 0 || index > N60_WORKER_WAKE_MAX) return false;
    for (;;) {
        kern_return_t kr = semaphore_wait(w->sem[index - 1]);
        if (atomic_load_explicit(&w->stop, memory_order_acquire)) return false;
        if (kr == KERN_SUCCESS) return true;
        if (kr != KERN_ABORTED) return false;
    }
}

// Control thread: tells every waiting worker to exit.
static inline void N60WorkerWakeStop(void *context) {
    N60WorkerWake *w = (N60WorkerWake *)context;
    if (w == NULL) return;
    atomic_store_explicit(&w->stop, true, memory_order_release);
    for (uint32_t i = 0; i < N60_WORKER_WAKE_MAX; ++i) semaphore_signal(w->sem[i]);
}

// Audio Workgroup membership for a worker thread. The Swift overlay's WorkGroup.join() has no failure result, so the C
// calls are used and a refused join (a cancelled or otherwise unjoinable workgroup) is reported instead of trapping.
// `workgroup` is an os_workgroup_t passed as an unretained pointer. Join returns a token to hand to Leave, or NULL on
// failure. Control and worker threads only; allocates the token.
#include <os/workgroup.h>
#if __has_feature(objc_arc)
#define N60_WG_CAST(p) ((__bridge os_workgroup_t)(p))
#else
#define N60_WG_CAST(p) ((os_workgroup_t)(p))
#endif

static inline void *N60WorkgroupJoin(void *workgroup) {
    if (workgroup == NULL) return NULL;
    os_workgroup_join_token_s *token = (os_workgroup_join_token_s *)calloc(1, sizeof(os_workgroup_join_token_s));
    if (token == NULL) return NULL;
    if (os_workgroup_join(N60_WG_CAST(workgroup), token) != 0) {
        free(token);
        return NULL;
    }
    return token;
}

static inline void N60WorkgroupLeave(void *workgroup, void *membership) {
    if (workgroup == NULL || membership == NULL) return;
    os_workgroup_leave(N60_WG_CAST(workgroup), (os_workgroup_join_token_s *)membership);
    free(membership);
}

static inline uint32_t N60WorkerWakeSignalCount(void *context) {
    N60WorkerWake *w = (N60WorkerWake *)context;
    return w == NULL ? 0 : atomic_load_explicit(&w->signals, memory_order_relaxed);
}

#endif
