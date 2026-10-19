// libn60core graph host and C ABI (E6 S2 skeleton, S3 snapshot swap). Portable C++20:
// standard library only, no Apple framework. Compiled without exceptions or RTTI.
//
// Realtime documentation (docs/REALTIME_RULES.md), for n60_graph_process:
//  - allocation: none. Snapshots are built on the control thread; the callback only
//    exchanges a pointer, drains a fixed ring and runs stages over preallocated state.
//  - synchronisation: lock-free only. One atomic exchange adopts a snapshot (acquire);
//    the mailbox and retire queue are single-producer single-consumer rings.
//    Retiring never frees on the realtime thread.
//  - latency: reported by n60_graph_latency_frames (sum of DELAY stages per lane).
//  - sample rate: fixed at build, any rate in [8 kHz, 768 kHz]; no resampling.
//  - channels: 1..N60_GRAPH_MAX_CHANNELS in and out, fixed at build.
//  - reset: a topology change is a new snapshot with fresh state; there is no in-place
//    reset, and parameters never reset state.
#include <atomic>
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

    n60::SnapHeader *current = nullptr;  // realtime thread only
    n60::SnapHeader *latest = nullptr;   // control thread only; newest published, not owned
    uint32_t nextEpoch = 2;              // control thread only

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

// Realtime thread: take a published snapshot, hand the old one back.
void adopt(n60_graph *g) {
    if (g->pending.load(std::memory_order_relaxed) == nullptr) return;
    n60::SnapHeader *next = g->pending.exchange(nullptr, std::memory_order_acq_rel);
    if (next == nullptr) return;
    const uint32_t tail = g->retireTail.load(std::memory_order_relaxed);
    g->retireSlots[tail % kRetireSlots] = g->current;  // room guaranteed by publish
    g->retireTail.store(tail + 1, std::memory_order_release);
    g->current = next;
    g->liveEpoch.store(next->epoch, std::memory_order_release);
    g->latency.store(n60::snapshotLatency(next), std::memory_order_relaxed);
}

// Realtime thread: coalesce the mailbox (latest wins), then the stages see only targets.
void drainMailbox(n60_graph *g) {
    uint32_t head = g->mailHead.load(std::memory_order_relaxed);
    const uint32_t tail = g->mailTail.load(std::memory_order_acquire);
    if (head == tail) return;
    uint64_t applied = 0, dropped = 0;
    bool delayChanged = false;
    while (head != tail) {
        const MailboxRecord &rec = g->mailbox[head % kMailboxSlots];
        // Aimed at a snapshot published after this block adopted one: leave it for the
        // next block, which adopts that snapshot first.
        if (rec.epoch > g->current->epoch) break;
        ++head;
        if (rec.epoch < g->current->epoch) {
            ++dropped;
        } else if (n60::applyParam(g->current, rec.stageId, rec.paramIndex, rec.value)) {
            ++applied;
            delayChanged = true;
        } else {
            ++dropped;
        }
    }
    g->mailHead.store(head, std::memory_order_release);
    if (applied) g->paramsApplied.fetch_add(applied, std::memory_order_relaxed);
    if (dropped) g->paramsDropped.fetch_add(dropped, std::memory_order_relaxed);
    if (delayChanged) g->latency.store(n60::snapshotLatency(g->current), std::memory_order_relaxed);
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
    g->current = snap;
    g->latest = snap;
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
    // Up to two adoptions can land while this runs, so keep two slots in reserve.
    if (retireOccupancy(g) > kRetireSlots - 2) return N60_STATUS_QUEUE_FULL;
    n60::SnapHeader *snap = nullptr;
    const n60_status st = n60::buildSnapshot(*desc, g->nextEpoch, &snap);
    if (st != N60_STATUS_OK) return st;
    ++g->nextEpoch;
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
    n60::runSnapshot(g->current, out, frames, g->sanitised);
    return N60_STATUS_OK;
}

n60_status n60_graph_post_params(n60_graph *g, const n60_param_record *records, uint32_t count) {
    if (g == nullptr) return N60_STATUS_BAD_ARGUMENT;
    if (count == 0) return N60_STATUS_OK;
    if (records == nullptr) return N60_STATUS_BAD_ARGUMENT;
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
    return n60::readMeter(g->latest, stageId, lane, peak, rms) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_guard(n60_graph *g, uint32_t stageId, n60_guard_status *out) {
    if (g == nullptr || out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    return n60::readGuardStatus(g->latest, stageId, out) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

n60_status n60_graph_read_capture(n60_graph *g, uint32_t stageId, uint32_t lane, uint64_t startSample, float *dst,
                                  uint32_t frames, uint64_t *written) {
    if (g == nullptr || (dst == nullptr && frames != 0)) return N60_STATUS_BAD_ARGUMENT;
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
    n60::freeSnapshot(g->current);
    delete g;
}

uint32_t n60_graph_latency_frames(const n60_graph *g) {
    return g == nullptr ? 0u : g->latency.load(std::memory_order_relaxed);
}

}  // extern "C"
