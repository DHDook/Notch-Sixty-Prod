/* E20 S1: per-stage-kind timing hooks for the benchmark harness (core/bench/n60_bench.cpp).
 *
 * Compiled only when libn60core is built with -DN60_GRAPH_PROFILE. Product builds do not define it, so
 * n60_profile_reset and n60_profile_read do not exist in them (core/tests/test_profile.cpp checks that
 * by linking against a weak reference). The counters are plain globals for one audio thread; a harness resets
 * and reads them between runs, never while a graph is rendering on another thread.
 * Realtime (AGENTS.md section 4): profiling builds only, no allocation, no locks, one steady_clock read pair per
 * stage per block; never shipped. Not safe with parallel render workers (E20 S5/S6): make the counters per-thread then. */
#ifndef N60_PROFILE_H
#define N60_PROFILE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct n60_profile_entry {
    uint32_t kind;        /* n60_stage_kind */
    uint32_t reserved;
    uint64_t ns;          /* total time in the stage */
    uint64_t calls;       /* stage invocations */
    uint64_t frames;      /* sum of block lengths */
    uint64_t laneFrames;  /* sum of block length x lanes the stage processed (ns per sample = ns / laneFrames) */
} n60_profile_entry;

void n60_profile_reset(void);
/* Copies up to capacity entries with calls > 0; returns the count. */
uint32_t n60_profile_read(n60_profile_entry *out, uint32_t capacity);

#ifdef __cplusplus
}
#endif

#endif /* N60_PROFILE_H */
