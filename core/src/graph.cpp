// libn60core graph host and C ABI (E6 S2 skeleton, S3 snapshot swap). Portable C++20:
// standard library only, no Apple framework. Compiled without exceptions or RTTI.
//
// Realtime documentation (docs/REALTIME_RULES.md), for n60_graph_process:
//  - allocation: none. Snapshots are built on the control thread; the callback only
//    exchanges a pointer, drains a fixed ring and runs stages over preallocated state.
//  - synchronisation: lock-free only. One atomic exchange adopts a snapshot (acquire);
//    the mailbox and retire queue are single-producer single-consumer rings.
//    Retiring never frees on the realtime thread.
//  - topology rebuild (S6): the incoming snapshot runs in parallel with the live one on scratch buffers
//    allocated at build, warms up silently, then an equal-power crossfade replaces the live one. Both
//    graphs run for the duration, so the block cost is the sum of both; an optional CPU budget refuses a
//    rebuild whose measured warm-up cost is too high. The timing call (steady_clock) is the only
//    system interaction on the callback and only happens while a budget is set and a rebuild is warming.
//  - latency: reported by n60_graph_latency_frames (sum of DELAY stages per lane).
//  - sample rate: fixed at build, any rate in [8 kHz, 768 kHz]; no resampling.
//  - channels: 1..N60_GRAPH_MAX_CHANNELS in and out, fixed at build.
//  - reset: a topology change is a new snapshot with fresh state, warmed up before it is heard; there is
//    no in-place reset, and parameters never reset state. One exception, the denoiser noise profile (ABI v9):
//    it is the only state that takes seconds of program audio to learn or is captured by the user, so the
//    adopting realtime block copies it from the live stage into the new one (a bounded copy of at most three
//    arrays of 2049 floats and a few counters), parks it in a preallocated slot while no stage exists, and
//    restores it when a stage of the same FFT size returns. The stream state (input, overlap-add, gain
//    history) is not copied: the new stage's warm-up covers it. The second exception, ABI v10 (E6 S8d): a FIR
//    stage that is the same filter in the new snapshot (id, taps, lanes) has its running state copied at adoption
//    (one bounded memcpy per lane), so an unrelated topology change never restarts a convolver; a new or changed
//    one warms for its whole tap length before the crossfade.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <new>

#include "n60/graph.h"
#include "snapshot.hpp"
#include "stages_cleanup.hpp"
#include "stages_loudness.hpp"
#include "stages_dsp.hpp"
#include "stages_system.hpp"

namespace {

constexpr uint32_t kRetireSlots = 16;
constexpr uint32_t kMailboxSlots = 1024;  // power of two
constexpr uint32_t kDrainCap = 256;       // mailbox records applied per block
// Bulk clear / copy per callback (E9 S2, design note 5; scaled with the block length in S2b so the memset/memcpy share
// of a callback is the same at 32 frames at 384 kHz as at 256 frames at 48 kHz): 1 KiB per frame, between 4 KiB and
// 256 KiB. A block of 256 frames or more gets the full 256 KiB.
constexpr uint64_t kRtBudgetMax = 256 * 1024;
constexpr uint64_t kRtBudgetMin = 4 * 1024;
constexpr uint64_t kRtBudgetPerFrame = 1024;
constexpr uint64_t rtBudgetFor(uint32_t frames) {
    const uint64_t b = static_cast<uint64_t>(frames) * kRtBudgetPerFrame;
    return b < kRtBudgetMin ? kRtBudgetMin : (b > kRtBudgetMax ? kRtBudgetMax : b);
}

struct MailboxRecord {
    uint32_t stageId;
    uint32_t paramIndex;
    float value;
    uint32_t epoch;
};

}  // namespace

struct n60_graph {
    // Fixed for the life of the handle.
    double sampleRate;
    uint32_t maxBlockFrames;
    uint32_t inputChannels;
    uint32_t outputChannels;

    // Hand-off. pending: control -> realtime. retire ring: realtime -> control.
    std::atomic<n60::SnapHeader *> pending{nullptr};
    n60::SnapHeader *retireSlots[kRetireSlots] = {};
    std::atomic<uint32_t> retireHead{0};  // control consumes
    std::atomic<uint32_t> retireTail{0};  // realtime produces

    MailboxRecord mailbox[kMailboxSlots];
    std::atomic<uint32_t> mailHead{0};  // realtime consumes
    std::atomic<uint32_t> mailTail{0};  // control produces

    n60::SnapHeader *current = nullptr;   // realtime thread only
    n60::SnapHeader *incoming = nullptr;  // realtime thread only; the snapshot being faded in
    n60::SnapHeader *latest = nullptr;    // control thread only; newest published, not owned
    uint32_t nextEpoch = 2;               // control thread only

    // Rebuild options. Control writes; fadeFrames is stamped into each snapshot at publish.
    uint32_t fadeFrames = 0;
    uint32_t fadeLinear = 0;  // E27 S3b: rebuild option bit 0, stamped into each snapshot at publish
    std::atomic<uint32_t> cpuBudgetBits{0};  // float percent; 0 = no budget (realtime reads)

    // Rebuild state, realtime thread only.
    uint32_t phase = 0;  // 0 idle, 1 warming, 2 fading
    uint32_t warmLeft = 0;
    uint32_t fadePos = 0;
    uint32_t ancStages = 0;
    double warmSeconds = 0.0;  // audio time covered by the warm-up so far
    double warmCost = 0.0;     // processing time spent on it
    float *scratch = nullptr;  // outputChannels * maxBlockFrames, incoming render target
    float *scratchLane[N60_GRAPH_MAX_CHANNELS] = {};

    std::atomic<uint32_t> rbState{0};
    std::atomic<uint32_t> rbLast{0};
    std::atomic<uint32_t> rbAnc{0};
    std::atomic<uint32_t> rbCpuBits{0};
    std::atomic<uint64_t> rbCompleted{0};
    std::atomic<uint64_t> rbRefused{0};
    std::atomic<uint64_t> rbCancelled{0};

    // A rebuild that is refused or cancelled retires its incoming snapshot. failedEpoch (newest such epoch,
    // written by the realtime thread) lets control re-point `latest` at the live snapshot before it frees it,
    // and lets the mailbox drop records aimed at a dead epoch instead of stalling behind them.
    std::atomic<uint32_t> failedEpoch{0};
    std::atomic<n60::SnapHeader *> liveSnap{nullptr};  // current, for control to fall back on (freed only by collect)

    std::atomic<uint32_t> liveEpoch{0};
    std::atomic<uint32_t> publishedEpoch{0};
    std::atomic<uint32_t> latency{0};
    std::atomic<uint64_t> paramsApplied{0};
    std::atomic<uint64_t> paramsDropped{0};
    std::atomic<uint64_t> sanitised{0};
    std::atomic<uint64_t> snapshotsRetired{0};

    // ABI v9. Realtime thread only: the denoiser profile kept while the live snapshot has no DENOISER stage
    // (fftSize 0 = none). Part of the handle, so nothing is allocated when it is used.
    n60_denoiser_state parked{};

    // E9 S2. Bulk clearing and copying left in the current callback (bytes); the snapshots point at it. Realtime
    // thread only. `budgetPeak` is the most any callback has used, for the tests (graph_debug.hpp).
    uint64_t rtBudget = 0;
    uint64_t rtBudgetStart = 0;  // this callback's allowance, for the peak
    std::atomic<uint64_t> budgetPeak{0};
    std::atomic<uint32_t> carryAbandoned{0};  // lazy carries given up for an upstream parameter post (S2b)
    bool carryActive = false;  // a lazy FIR carry from current to incoming still has bytes to copy
    n60::FirCarryCursor carry;

    // ABI v13: the EXTERNAL stage's host callback and its rebuild-fade scratch.
    n60::ExternalSlot external;
};

namespace {

uint32_t retireOccupancy(const n60_graph *g) {
    return g->retireTail.load(std::memory_order_acquire) - g->retireHead.load(std::memory_order_relaxed);
}

// Control thread: if the newest published snapshot was refused or cancelled, fall back to the live one.
void syncLatest(n60_graph *g) {
    if (g->latest->epoch == g->failedEpoch.load(std::memory_order_acquire)) {
        n60::SnapHeader *live = g->liveSnap.load(std::memory_order_acquire);
        if (live != nullptr) g->latest = live;
    }
}

void retireSnapshot(n60_graph *g, n60::SnapHeader *snap) {
    const uint32_t tail = g->retireTail.load(std::memory_order_relaxed);
    g->retireSlots[tail % kRetireSlots] = snap;  // room guaranteed by publish
    g->retireTail.store(tail + 1, std::memory_order_release);
}

float loadFloat(const std::atomic<uint32_t> &a) {
    const uint32_t bits = a.load(std::memory_order_relaxed);
    float f;
    std::memcpy(&f, &bits, sizeof f);
    return f;
}

void storeFloat(std::atomic<uint32_t> &a, float f) {
    uint32_t bits;
    std::memcpy(&bits, &f, sizeof bits);
    a.store(bits, std::memory_order_relaxed);
}

bool hasDenoiser(const n60::SnapHeader *h) {
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        if (n60::stages(h)[i].kind == N60_STAGE_DENOISER) return true;
    }
    return false;
}

// Copies the used part of a denoiser state (the header and three arrays of fftSize / 2 + 1 floats).
void copyDenoiserState(n60_denoiser_state *dst, const n60_denoiser_state *src) {
    const size_t bins = src->fftSize / 2 + 1;
    std::memcpy(dst, src, offsetof(n60_denoiser_state, noise));
    std::memcpy(dst->noise, src->noise, sizeof(float) * bins);
    std::memcpy(dst->adaptiveMin, src->adaptiveMin, sizeof(float) * bins);
    std::memcpy(dst->captureSum, src->captureSum, sizeof(float) * bins);
}

bool validFft(uint32_t n) { return n == 1024 || n == 2048 || n == 4096; }

// Realtime thread: `next` starts running next to (or in place of) `cur`. Its denoiser starts from the live
// stage's profile, or from the parked one when the live snapshot had no stage.
void carryDenoiserIn(n60_graph *g, n60::SnapHeader *cur, n60::SnapHeader *next) {
    if (!hasDenoiser(next)) return;
    if (n60::dspDenoiserCarry(cur, next)) return;
    if (!hasDenoiser(cur) && g->parked.fftSize != 0) n60::dspDenoiserImport(next, &g->parked);
}

// Realtime thread: `next` is now the live snapshot and `old` stops. A stage that disappears parks its profile,
// a parked profile is updated with the kernel's "denoiser off" bookkeeping, and a stage that came back owns it.
void settleDenoiser(n60_graph *g, n60::SnapHeader *old, n60::SnapHeader *next) {
    if (hasDenoiser(next)) {
        g->parked.fftSize = 0;
        return;
    }
    if (hasDenoiser(old)) {
        if (!n60::dspDenoiserExport(old, &g->parked)) g->parked.fftSize = 0;
    }
    if (next->parkFftSize != 0) {
        n60::denoiserParkedApplyView(&g->parked, next->parkFftSize, next->parkRevision, next->parkCommand);
    }
}

// Realtime thread: take a published snapshot. A fade-less snapshot replaces the live one at once;
// otherwise it starts a rebuild. While a rebuild runs the next published snapshot waits in pending.
void adopt(n60_graph *g) {
    if (g->incoming != nullptr) return;
    if (g->pending.load(std::memory_order_relaxed) == nullptr) return;
    n60::SnapHeader *next = g->pending.exchange(nullptr, std::memory_order_acq_rel);
    if (next == nullptr) return;
    carryDenoiserIn(g, g->current, next);
    // ABI v10: a FIR stage that is unchanged keeps its running state; one that is new or changed needs its whole
    // tap length of silent history before it is heard.
    bool carryPending = false;
    const uint32_t firWarm = n60::dspFirCarry(g->current, next, next->fadeFrames != 0, &carryPending, &g->rtBudget);
    n60::systemRiderCarry(g->current, next);  // ABI v12
    // A fade-less snapshot replaces the live one at once, unless a FIR lane is too large to copy within this
    // callback's budget (E9 S2b): then it runs next to the live one in lockstep, is swapped in without a fade
    // when the copy and settle are done, and is never refused for CPU.
    const bool deferred = next->fadeFrames == 0 && carryPending;
    if (next->fadeFrames == 0 && !deferred) {
        settleDenoiser(g, g->current, next);
        retireSnapshot(g, g->current);
        g->current = next;
        g->liveSnap.store(next, std::memory_order_release);
        g->liveEpoch.store(next->epoch, std::memory_order_release);
        g->latency.store(n60::snapshotLatency(next), std::memory_order_relaxed);
        return;
    }
    g->incoming = next;
    const uint32_t latency = n60::snapshotLatency(next);
    const uint32_t cap = static_cast<uint32_t>(std::min(g->sampleRate, 4.0e6));
    g->warmLeft = deferred ? firWarm : std::max({next->rampFrames, std::min(latency, cap), firWarm});
    g->carry = n60::FirCarryCursor{0, 0, 0, g->current->historyEpoch, next->historyEpoch};
    g->carryActive = carryPending;
    g->fadePos = 0;
    g->warmSeconds = 0.0;
    g->warmCost = 0.0;
    // Live ANC injection goes silent in both instances for the whole rebuild and stays so until the host
    // re-arms it with a new revision.
    // Mute both instances; the count is the larger of the two (the same stage in each is one stage).
    g->ancStages = std::max(n60::systemRebuildMute(g->current, false), n60::systemRebuildMute(next, true));
    g->phase = 1;
    g->rbAnc.store(g->ancStages, std::memory_order_relaxed);
    g->rbState.store(1, std::memory_order_release);
}

void finishRebuild(n60_graph *g, uint32_t result) {
    // result: 1 completed (incoming becomes live), 2 refused for CPU budget, 3 cancelled on non-finite output.
    if (result == 1) {
        settleDenoiser(g, g->current, g->incoming);
        retireSnapshot(g, g->current);
        g->current = g->incoming;
        g->liveSnap.store(g->current, std::memory_order_release);
        g->liveEpoch.store(g->current->epoch, std::memory_order_release);
        g->latency.store(n60::snapshotLatency(g->current), std::memory_order_relaxed);
        g->rbCompleted.fetch_add(1, std::memory_order_relaxed);
    } else {
        g->failedEpoch.store(g->incoming->epoch, std::memory_order_release);  // before the retire is visible
        retireSnapshot(g, g->incoming);
        (result == 2 ? g->rbRefused : g->rbCancelled).fetch_add(1, std::memory_order_relaxed);
    }
    g->incoming = nullptr;
    g->carryActive = false;
    g->phase = 0;
    g->ancStages = 0;  // rbAnc keeps the count from the last rebuild
    g->rbLast.store(result, std::memory_order_relaxed);
    g->rbState.store(0, std::memory_order_release);
}

// Realtime thread (E9 S2b). The two instances no longer see the same input at a lazily carried FIR stage (a parameter
// of a stage upstream of it was posted during the copy window), so the history being copied would not be what the
// incoming lane would hold. Give the carry up: the incoming FIR lanes drop their history (the epoch bump ends the
// copy and resets the lanes) and the swap waits for the full tap-length warm instead.
void abandonCarry(n60_graph *g) {
    g->carryActive = false;
    g->incoming->historyEpoch++;
    g->warmLeft = std::max(g->warmLeft, n60::dspFirHistoryFrames(g->incoming));
    g->carryAbandoned.fetch_add(1, std::memory_order_relaxed);
}

// Realtime thread: coalesce the mailbox (latest wins), then the stages see only targets.
// At most kDrainCap records are taken per block so a flood cannot stretch a callback; the rest wait.
void drainMailbox(n60_graph *g) {
    uint32_t head = g->mailHead.load(std::memory_order_relaxed);
    const uint32_t tail = g->mailTail.load(std::memory_order_acquire);
    if (head == tail) return;
    const uint32_t newest = g->incoming != nullptr ? g->incoming->epoch : g->current->epoch;
    uint64_t applied = 0, dropped = 0;
    bool delayChanged = false;
    bool upstreamPost = false;  // E9 S2b: a post that changes what a lazily carried FIR stage hears
    uint32_t taken = 0;
    while (head != tail && taken < kDrainCap) {
        const MailboxRecord &rec = g->mailbox[head % kMailboxSlots];
        // Aimed at a snapshot published after this block adopted one: leave it for the
        // block that adopts that snapshot.
        // (A record aimed at a refused or cancelled epoch is dead: it falls through and is dropped.)
        if (rec.epoch > newest && rec.epoch > g->failedEpoch.load(std::memory_order_relaxed)) break;
        ++head;
        ++taken;
        n60::SnapHeader *target = rec.epoch == g->current->epoch                         ? g->current
                                  : (g->incoming != nullptr && rec.epoch == g->incoming->epoch) ? g->incoming
                                                                                         : nullptr;
        bool latency = false;
        if (target != nullptr && n60::applyParam(target, rec.stageId, rec.paramIndex, rec.value, &latency)) {
            ++applied;
            if (latency && target == g->current) delayChanged = true;
            if (g->carryActive && n60::dspFirCarryUpstream(g->incoming, rec.stageId)) upstreamPost = true;
        } else {
            ++dropped;
        }
    }
    g->mailHead.store(head, std::memory_order_release);
    if (applied) g->paramsApplied.fetch_add(applied, std::memory_order_relaxed);
    if (dropped) g->paramsDropped.fetch_add(dropped, std::memory_order_relaxed);
    if (delayChanged) g->latency.store(n60::snapshotLatency(g->current), std::memory_order_relaxed);
    if (upstreamPost) abandonCarry(g);
}

bool allFinite(const float *p, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) {
        if (!std::isfinite(p[i])) return false;
    }
    return true;
}

// Realtime thread: one block while a rebuild is in flight. `out` holds the pre-stage lanes.
void rebuildBlock(n60_graph *g, float *const *out, uint32_t frames) {
    const uint32_t outCount = g->outputChannels;
    const float budget = loadFloat(g->cpuBudgetBits);
    const bool timed = g->phase == 1 && budget > 0.0f && g->incoming->fadeFrames != 0;
    std::chrono::steady_clock::time_point t0{};  // epoch unless timed
    if (timed) t0 = std::chrono::steady_clock::now();

    const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
    for (uint32_t c = 0; c < outCount; ++c) std::memcpy(g->scratchLane[c], out[c], bytes);
    if (g->ancStages != 0) {  // a revision that arrived during the rebuild is not a re-arm
        n60::systemRebuildMute(g->current, false);
        n60::systemRebuildMute(g->incoming, false);
    }
    g->external.deltaFrames = 0;
    n60::runSnapshot(g->current, out, frames, g->sanitised);
    n60::runSnapshot(g->incoming, g->scratchLane, frames, g->sanitised, true);

    for (uint32_t c = 0; c < outCount; ++c) {
        if (!allFinite(g->scratchLane[c], frames)) {
            finishRebuild(g, 3);
            return;
        }
    }

    // The CPU cost of the block is what the two instances took to render it: read the clock before the carry copy
    // (E9 S2b), which is one-off bulk memory traffic and must not push the load over the refusal budget.
    double blockCost = 0.0;
    if (timed) blockCost = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();

    // Lazy FIR carry (E9 S2). Both instances have just rendered the same block, so they are at the same tick: copy
    // what is left of the budget of the outgoing lanes' bulk state, any order. The warm-up waits for it.
    if (g->carryActive) {
        bool done = false;
        const uint64_t left = g->rtBudget;
        g->rtBudget -= n60::dspFirCarryStep(g->current, g->incoming, g->carry, left, &done);
        if (done) g->carryActive = false;
    }

    if (g->phase == 1) {
        if (timed) {
            g->warmCost += blockCost;
            g->warmSeconds += static_cast<double>(frames) / g->sampleRate;
        }
        if (!g->carryActive) g->warmLeft -= std::min(g->warmLeft, frames);
        if (g->warmLeft == 0 && !g->carryActive) {
            if (budget > 0.0f) {
                const double load = g->warmSeconds > 0.0 ? 100.0 * g->warmCost / g->warmSeconds : 0.0;
                storeFloat(g->rbCpuBits, static_cast<float>(load));
                if (load > static_cast<double>(budget)) {
                    finishRebuild(g, 2);
                    return;
                }
            }
            g->phase = 2;
            g->rbState.store(2, std::memory_order_release);
        }
        return;
    }

    // Equal-power crossfade: old * cos + new * sin, advanced by rotation so no trig per sample.
    const uint32_t fade = g->incoming->fadeFrames;
    if (fade == 0) {  // deferred fade-less snapshot: the incoming instance is heard from now on
        for (uint32_t c = 0; c < outCount; ++c) std::memcpy(out[c], g->scratchLane[c], bytes);
        finishRebuild(g, 1);
        return;
    }
    const double halfPi = 1.5707963267948966;
    const double step = halfPi / static_cast<double>(fade);
    const double cd = std::cos(step), sd = std::sin(step);
    const uint32_t pos = g->fadePos;
    const uint32_t active = pos >= fade ? 0u : std::min(frames, fade - pos);
    if (g->incoming->fadeLinear != 0) {
        // E27 S3b linear law for correlated old/new signals (an EQ bypass, A/B or audition switch):
        // old * (1 - t) + new * t keeps a shared component at constant gain, with no equal-power bump.
        const double inv = 1.0 / static_cast<double>(fade);
        for (uint32_t c = 0; c < outCount; ++c) {
            float *dst = out[c];
            const float *nw = g->scratchLane[c];
            for (uint32_t i = 0; i < active; ++i) {
                const double t = static_cast<double>(pos + i) * inv;
                dst[i] = static_cast<float>(dst[i] * (1.0 - t) + nw[i] * t);
            }
            if (active < frames) std::memcpy(dst + active, nw + active, sizeof(float) * (frames - active));
        }
        g->fadePos = pos + frames;
        if (g->fadePos >= fade) finishRebuild(g, 1);
        return;
    }
    for (uint32_t c = 0; c < outCount; ++c) {
        float *dst = out[c];
        const float *nw = g->scratchLane[c];
        double cs = std::cos(step * pos), sn = std::sin(step * pos);
        for (uint32_t i = 0; i < active; ++i) {
            dst[i] = static_cast<float>(dst[i] * cs + nw[i] * sn);
            const double c2 = cs * cd - sn * sd;
            sn = sn * cd + cs * sd;
            cs = c2;
        }
        if (active < frames) std::memcpy(dst + active, nw + active, sizeof(float) * (frames - active));
    }
    g->fadePos = pos + frames;
    if (g->fadePos >= fade) finishRebuild(g, 1);
}

bool sameFixed(const n60_graph *g, const n60_graph_desc *d) {
    return d->sampleRate == g->sampleRate && d->maxBlockFrames == g->maxBlockFrames &&
           d->inputChannels == g->inputChannels && d->outputChannels == g->outputChannels;
}

}  // namespace

extern "C" {

uint32_t n60_graph_abi_version(void) { return N60_GRAPH_ABI_VERSION; }

int n60_graph_denoiser_export(n60_graph *g, n60_denoiser_state *out) {
    if (g == nullptr || out == nullptr) return 0;
    if (n60::dspDenoiserExport(g->current, out)) return 1;
    if (g->parked.fftSize == 0) return 0;
    copyDenoiserState(out, &g->parked);
    return 1;
}

void n60_graph_invalidate_history(n60_graph *g) {
    if (g == nullptr) return;
    g->current->historyEpoch++;
    if (g->incoming != nullptr) g->incoming->historyEpoch++;
    // A published snapshot not adopted yet is only ever taken on this (realtime) thread, so bumping it is race-free.
    n60::SnapHeader *waiting = g->pending.load(std::memory_order_acquire);
    if (waiting != nullptr) waiting->historyEpoch++;
}

uint32_t n60_graph_history_frames(n60_graph *g) {
    if (g == nullptr) return 0;
    uint32_t frames = n60::dspFirHistoryFrames(g->current);
    frames = std::max(frames, n60::dspFirHistoryFrames(g->incoming));
    return std::max(frames, n60::dspFirHistoryFrames(g->pending.load(std::memory_order_acquire)));
}

void n60_graph_denoiser_import(n60_graph *g, const n60_denoiser_state *in) {
    if (g == nullptr || in == nullptr) return;
    const bool live = n60::dspDenoiserImport(g->current, in);
    if (g->incoming != nullptr) n60::dspDenoiserImport(g->incoming, in);
    if (live) return;
    if (in->fftSize == 0 || !validFft(in->fftSize)) {
        g->parked.fftSize = 0;
    } else {
        copyDenoiserState(&g->parked, in);
    }
}

n60_status n60_graph_build(const n60_graph_desc *desc, n60_graph **outGraph) {
    if (outGraph == nullptr) return N60_STATUS_BAD_ARGUMENT;
    *outGraph = nullptr;
    if (desc == nullptr) return N60_STATUS_BAD_ARGUMENT;
    n60::SnapHeader *snap = nullptr;
    const n60_status st = n60::buildSnapshot(*desc, 1, &snap);
    if (st != N60_STATUS_OK) return st;
    n60_graph *g = new (std::nothrow) n60_graph;
    if (g == nullptr) {
        n60::freeSnapshot(snap);
        return N60_STATUS_OUT_OF_MEMORY;
    }
    snap->external = &g->external;
    snap->rtBudget = &g->rtBudget;
    g->sampleRate = desc->sampleRate;
    g->maxBlockFrames = desc->maxBlockFrames;
    g->inputChannels = desc->inputChannels;
    g->outputChannels = desc->outputChannels;
    g->scratch = new (std::nothrow) float[static_cast<size_t>(desc->outputChannels) * desc->maxBlockFrames];
    if (g->scratch == nullptr) {
        n60::freeSnapshot(snap);
        delete g;
        return N60_STATUS_OUT_OF_MEMORY;
    }
    for (uint32_t c = 0; c < desc->outputChannels; ++c) {
        g->scratchLane[c] = g->scratch + static_cast<size_t>(c) * desc->maxBlockFrames;
    }
    g->fadeFrames = static_cast<uint32_t>(std::lround(0.020 * desc->sampleRate));
    g->parked.fftSize = 0;
    if (!hasDenoiser(snap)) settleDenoiser(g, snap, snap);
    g->current = snap;
    g->latest = snap;
    g->liveSnap.store(snap, std::memory_order_relaxed);
    g->liveEpoch.store(1, std::memory_order_relaxed);
    g->publishedEpoch.store(1, std::memory_order_relaxed);
    g->latency.store(n60::snapshotLatency(snap), std::memory_order_relaxed);
    *outGraph = g;
    return N60_STATUS_OK;
}

n60_status n60_graph_publish(n60_graph *g, const n60_graph_desc *desc) {
    if (g == nullptr || desc == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (desc->abiVersion != N60_GRAPH_ABI_VERSION || desc->structSize != sizeof(n60_graph_desc)) {
        return N60_STATUS_ABI_MISMATCH;
    }
    if (!sameFixed(g, desc)) return N60_STATUS_BAD_ARGUMENT;
    // While this runs the realtime thread can retire at most three snapshots before the next publish check:
    // a cancelled/completed incoming, the old current of an immediate adoption, and the previous pending.
    static_assert(kRetireSlots >= 8, "retire ring must cover the reserve");
    if (retireOccupancy(g) > kRetireSlots - 3) return N60_STATUS_QUEUE_FULL;
    n60::SnapHeader *snap = nullptr;
    const n60_status st = n60::buildSnapshot(*desc, g->nextEpoch, &snap);
    if (st != N60_STATUS_OK) return st;
    ++g->nextEpoch;
    snap->external = &g->external;
    snap->rtBudget = &g->rtBudget;
    snap->fadeFrames = g->fadeFrames;
    snap->fadeLinear = g->fadeLinear;
    g->latest = snap;
    g->publishedEpoch.store(snap->epoch, std::memory_order_release);
    n60::SnapHeader *superseded = g->pending.exchange(snap, std::memory_order_acq_rel);
    n60::freeSnapshot(superseded);  // never reached the realtime thread
    return N60_STATUS_OK;
}

uint32_t n60_graph_collect(n60_graph *g) {
    if (g == nullptr) return 0;
    uint32_t head = g->retireHead.load(std::memory_order_relaxed);
    const uint32_t tail = g->retireTail.load(std::memory_order_acquire);
    syncLatest(g);  // after reading tail: any snapshot about to be freed is no longer `latest`
    uint32_t freed = 0;
    while (head != tail) {
        n60::freeSnapshot(g->retireSlots[head % kRetireSlots]);
        g->retireSlots[head % kRetireSlots] = nullptr;
        ++head;
        ++freed;
    }
    g->retireHead.store(head, std::memory_order_release);
    if (freed) g->snapshotsRetired.fetch_add(freed, std::memory_order_relaxed);
    return freed;
}

n60_status n60_graph_process(n60_graph *g, const float *const *in, float *const *out, uint32_t frames) {
    if (g == nullptr || in == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (frames > g->maxBlockFrames) return N60_STATUS_BAD_ARGUMENT;
    if (frames == 0) return N60_STATUS_OK;
    const uint32_t inCount = g->inputChannels;
    const uint32_t outCount = g->outputChannels;
    // Validate every pointer before touching any buffer, so an error never leaves a half-written block.
    for (uint32_t c = 0; c < outCount; ++c) {
        if (out[c] == nullptr || (c < inCount && in[c] == nullptr)) return N60_STATUS_BAD_ARGUMENT;
    }
    g->rtBudgetStart = g->rtBudget = rtBudgetFor(frames);
    adopt(g);
    drainMailbox(g);
    const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
    for (uint32_t c = 0; c < outCount; ++c) {
        float *dst = out[c];
        if (dst == nullptr) return N60_STATUS_BAD_ARGUMENT;
        if (c < inCount) {
            const float *src = in[c];
            if (src == nullptr) return N60_STATUS_BAD_ARGUMENT;
            if (src != dst) std::memmove(dst, src, bytes);
        } else {
            std::memset(dst, 0, bytes);
        }
    }
    if (g->incoming == nullptr) {
        n60::runSnapshot(g->current, out, frames, g->sanitised);
    } else {
        rebuildBlock(g, out, frames);
    }
    g->budgetPeak.store(std::max(g->budgetPeak.load(std::memory_order_relaxed), g->rtBudgetStart - g->rtBudget),
                        std::memory_order_relaxed);
    return N60_STATUS_OK;
}

n60_status n60_graph_post_params(n60_graph *g, const n60_param_record *records, uint32_t count) {
    if (g == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (count == 0) return N60_STATUS_OK;
    if (records == nullptr) return N60_STATUS_BAD_ARGUMENT;
    syncLatest(g);
    // Validate the whole batch against the newest published snapshot first.
    for (uint32_t i = 0; i < count; ++i) {
        const n60_param_record &r = records[i];
        if (r.reserved != 0 || !std::isfinite(r.value)) return N60_STATUS_BAD_ARGUMENT;
        const n60::StageRec *stage = n60::findStage(g->latest, r.stageId);
        if (stage == nullptr) return N60_STATUS_BAD_ARGUMENT;
        const n60_status v = n60::validateParam(g->latest, *stage, r.paramIndex, r.value);
        if (v != N60_STATUS_OK) return v;
    }
    const uint32_t head = g->mailHead.load(std::memory_order_acquire);
    uint32_t tail = g->mailTail.load(std::memory_order_relaxed);
    if (count > kMailboxSlots - (tail - head)) return N60_STATUS_QUEUE_FULL;
    for (uint32_t i = 0; i < count; ++i) {
        g->mailbox[tail % kMailboxSlots] = {records[i].stageId, records[i].paramIndex, records[i].value,
                                            g->latest->epoch};
        ++tail;
    }
    g->mailTail.store(tail, std::memory_order_release);
    return N60_STATUS_OK;
}

n60_status n60_graph_read_meter(n60_graph *g, uint32_t stageId, uint32_t lane, float *peak, float *rms) {
    if (g == nullptr || peak == nullptr || rms == nullptr) return N60_STATUS_BAD_ARGUMENT;
    syncLatest(g);
    return n60::readMeter(g->latest, stageId, lane, peak, rms) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_dynamics(n60_graph *g, uint32_t stageId, uint32_t lane, n60_dynamics_readback *out) {
    if (g == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (out->structSize != sizeof(n60_dynamics_readback)) return N60_STATUS_ABI_MISMATCH;
    syncLatest(g);
    return n60::readDynamics(g->latest, stageId, lane, out) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_mains(n60_graph *g, uint32_t stageId, n60_mains_readback *out) {
    if (g == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (out->structSize != sizeof(n60_mains_readback)) return N60_STATUS_ABI_MISMATCH;
    syncLatest(g);
    return n60::readMains(g->latest, stageId, out) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_loudness(n60_graph *g, uint32_t stageId, n60_loudness_readback *out) {
    if (g == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (out->structSize != sizeof(n60_loudness_readback)) return N60_STATUS_ABI_MISMATCH;
    syncLatest(g);
    return n60::readLoudness(g->latest, stageId, out) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_over_range(n60_graph *g, uint32_t stageId, uint32_t lane, uint64_t *count) {
    if (g == nullptr || count == nullptr) return N60_STATUS_BAD_ARGUMENT;
    syncLatest(g);
    return n60::readOverRange(g->latest, stageId, lane, count) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_guard(n60_graph *g, uint32_t stageId, n60_guard_status *out) {
    if (g == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (out->structSize != sizeof(n60_guard_status)) return N60_STATUS_ABI_MISMATCH;
    syncLatest(g);
    return n60::readGuardStatus(g->latest, stageId, out) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_capture(n60_graph *g, uint32_t stageId, uint32_t lane, uint64_t startSample, float *dst,
                                  uint32_t frames, uint64_t *written) {
    if (g == nullptr || (dst == nullptr && frames != 0)) return N60_STATUS_BAD_ARGUMENT;
    syncLatest(g);
    return n60::readCapture(g->latest, stageId, lane, startSample, dst, frames, written);
}

void n60_graph_get_stats(const n60_graph *g, n60_graph_stats *s) {
    if (g == nullptr || s == nullptr) return;
    s->liveEpoch = g->liveEpoch.load(std::memory_order_acquire);
    s->publishedEpoch = g->publishedEpoch.load(std::memory_order_acquire);
    s->paramsApplied = g->paramsApplied.load(std::memory_order_relaxed);
    s->paramsDropped = g->paramsDropped.load(std::memory_order_relaxed);
    s->sanitisedSamples = g->sanitised.load(std::memory_order_relaxed);
    s->snapshotsRetired = g->snapshotsRetired.load(std::memory_order_relaxed);
}

uint64_t n60_graph_debug_rt_budget(uint32_t frames) { return rtBudgetFor(frames); }
uint32_t n60_graph_debug_carry_abandoned(const n60_graph *g) { return g == nullptr ? 0 : g->carryAbandoned.load(std::memory_order_relaxed); }
uint64_t n60_graph_debug_peak_rt_bytes(const n60_graph *g) { return g == nullptr ? 0 : g->budgetPeak.load(std::memory_order_relaxed); }

void n60_graph_retire(n60_graph *g) {
    if (g == nullptr) return;
    n60_graph_collect(g);
    n60::freeSnapshot(g->pending.exchange(nullptr, std::memory_order_acq_rel));
    n60::freeSnapshot(g->incoming);
    n60::freeSnapshot(g->current);
    delete[] g->scratch;
    delete[] g->external.delta;
    delete g;
}

n60_status n60_graph_set_external_processor(n60_graph *g, n60_external_process_fn process, void *context,
                                            uint32_t channels) {
    if (g == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (process == nullptr) {
        g->external.fn.store(nullptr, std::memory_order_release);
        return N60_STATUS_OK;
    }
    if (channels == 0 || channels > N60_GRAPH_MAX_CHANNELS || channels > g->outputChannels) return N60_STATUS_BAD_ARGUMENT;
    n60::ExternalSlot &x = g->external;
    x.fn.store(nullptr, std::memory_order_release);
    if (x.delta == nullptr || x.channels < channels) {
        float *fresh = new (std::nothrow) float[static_cast<size_t>(channels) * g->maxBlockFrames]();
        if (fresh == nullptr) return N60_STATUS_OUT_OF_MEMORY;
        delete[] x.delta;
        x.delta = fresh;
    }
    x.deltaStride = g->maxBlockFrames;
    x.channels = channels;
    x.context = context;
    x.calls.store(0, std::memory_order_relaxed);
    x.faults.store(0, std::memory_order_relaxed);
    x.fn.store(process, std::memory_order_release);
    return N60_STATUS_OK;
}

void n60_graph_external_stats(const n60_graph *g, uint64_t *calls, uint64_t *faults) {
    if (calls != nullptr) *calls = g != nullptr ? g->external.calls.load(std::memory_order_relaxed) : 0;
    if (faults != nullptr) *faults = g != nullptr ? g->external.faults.load(std::memory_order_relaxed) : 0;
}

n60_status n60_graph_set_rebuild_options(n60_graph *g, const n60_rebuild_options *o) {
    if (g == nullptr || o == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (o->structSize != sizeof(n60_rebuild_options)) return N60_STATUS_ABI_MISMATCH;
    if ((o->reserved & ~1u) != 0 || !std::isfinite(o->fadeMs) || !std::isfinite(o->cpuBudgetPercent) || o->fadeMs < 0.0f ||
        o->fadeMs > 500.0f || o->cpuBudgetPercent < 0.0f || o->cpuBudgetPercent > 1000.0f) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    g->fadeFrames = o->fadeMs == 0.0f
                        ? 0u
                        : std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(o->fadeMs * 1e-3 * g->sampleRate)));
    g->fadeLinear = o->reserved & 1u;
    storeFloat(g->cpuBudgetBits, o->cpuBudgetPercent);
    return N60_STATUS_OK;
}

n60_status n60_graph_get_rebuild_status(const n60_graph *g, n60_rebuild_status *s) {
    if (g == nullptr || s == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (s->structSize != sizeof(n60_rebuild_status)) return N60_STATUS_ABI_MISMATCH;
    s->state = g->rbState.load(std::memory_order_acquire);
    s->lastResult = g->rbLast.load(std::memory_order_relaxed);
    s->ancStagesHeld = g->rbAnc.load(std::memory_order_relaxed);
    s->completed = g->rbCompleted.load(std::memory_order_relaxed);
    s->refused = g->rbRefused.load(std::memory_order_relaxed);
    s->cancelled = g->rbCancelled.load(std::memory_order_relaxed);
    s->lastWarmupCpuPercent = loadFloat(g->rbCpuBits);
    s->reserved = 0;
    return N60_STATUS_OK;
}

uint32_t n60_graph_latency_frames(const n60_graph *g) {
    return g == nullptr ? 0u : g->latency.load(std::memory_order_relaxed);
}

}  // extern "C"
