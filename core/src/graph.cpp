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
//    no in-place reset, and parameters never reset state.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <new>

#include "n60/graph.h"
#include "snapshot.hpp"
#include "stages_system.hpp"

namespace {

constexpr uint32_t kRetireSlots = 16;
constexpr uint32_t kMailboxSlots = 1024;  // power of two
constexpr uint32_t kDrainCap = 256;       // mailbox records applied per block

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

// Realtime thread: take a published snapshot. A fade-less snapshot replaces the live one at once;
// otherwise it starts a rebuild. While a rebuild runs the next published snapshot waits in pending.
void adopt(n60_graph *g) {
    if (g->incoming != nullptr) return;
    if (g->pending.load(std::memory_order_relaxed) == nullptr) return;
    n60::SnapHeader *next = g->pending.exchange(nullptr, std::memory_order_acq_rel);
    if (next == nullptr) return;
    if (next->fadeFrames == 0) {
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
    g->warmLeft = std::max(next->rampFrames, std::min(latency, cap));
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
    g->phase = 0;
    g->ancStages = 0;  // rbAnc keeps the count from the last rebuild
    g->rbLast.store(result, std::memory_order_relaxed);
    g->rbState.store(0, std::memory_order_release);
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
        } else {
            ++dropped;
        }
    }
    g->mailHead.store(head, std::memory_order_release);
    if (applied) g->paramsApplied.fetch_add(applied, std::memory_order_relaxed);
    if (dropped) g->paramsDropped.fetch_add(dropped, std::memory_order_relaxed);
    if (delayChanged) g->latency.store(n60::snapshotLatency(g->current), std::memory_order_relaxed);
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
    const bool timed = g->phase == 1 && budget > 0.0f;
    std::chrono::steady_clock::time_point t0{};  // epoch unless timed
    if (timed) t0 = std::chrono::steady_clock::now();

    const size_t bytes = static_cast<size_t>(frames) * sizeof(float);
    for (uint32_t c = 0; c < outCount; ++c) std::memcpy(g->scratchLane[c], out[c], bytes);
    if (g->ancStages != 0) {  // a revision that arrived during the rebuild is not a re-arm
        n60::systemRebuildMute(g->current, false);
        n60::systemRebuildMute(g->incoming, false);
    }
    n60::runSnapshot(g->current, out, frames, g->sanitised);
    n60::runSnapshot(g->incoming, g->scratchLane, frames, g->sanitised);

    for (uint32_t c = 0; c < outCount; ++c) {
        if (!allFinite(g->scratchLane[c], frames)) {
            finishRebuild(g, 3);
            return;
        }
    }

    if (g->phase == 1) {
        if (timed) {
            g->warmCost += std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
            g->warmSeconds += static_cast<double>(frames) / g->sampleRate;
        }
        g->warmLeft -= std::min(g->warmLeft, frames);
        if (g->warmLeft == 0) {
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
    const double halfPi = 1.5707963267948966;
    const double step = halfPi / static_cast<double>(fade);
    const double cd = std::cos(step), sd = std::sin(step);
    const uint32_t pos = g->fadePos;
    const uint32_t active = pos >= fade ? 0u : std::min(frames, fade - pos);
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
    snap->fadeFrames = g->fadeFrames;
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

void n60_graph_retire(n60_graph *g) {
    if (g == nullptr) return;
    n60_graph_collect(g);
    n60::freeSnapshot(g->pending.exchange(nullptr, std::memory_order_acq_rel));
    n60::freeSnapshot(g->incoming);
    n60::freeSnapshot(g->current);
    delete[] g->scratch;
    delete g;
}

n60_status n60_graph_set_rebuild_options(n60_graph *g, const n60_rebuild_options *o) {
    if (g == nullptr || o == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (o->structSize != sizeof(n60_rebuild_options)) return N60_STATUS_ABI_MISMATCH;
    if (o->reserved != 0 || !std::isfinite(o->fadeMs) || !std::isfinite(o->cpuBudgetPercent) || o->fadeMs < 0.0f ||
        o->fadeMs > 500.0f || o->cpuBudgetPercent < 0.0f || o->cpuBudgetPercent > 1000.0f) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    g->fadeFrames = o->fadeMs == 0.0f
                        ? 0u
                        : std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(o->fadeMs * 1e-3 * g->sampleRate)));
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
