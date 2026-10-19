// libn60core snapshot build and lane stages (E6 S3). Portable C++20: standard library
// only, no Apple framework, compiled without exceptions or RTTI.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runSnapshot and applyParam:
//  - allocation: none. Everything a stage needs lives in the snapshot arena.
//  - synchronisation: none except relaxed atomics for meters; stage state is owned by
//    the realtime thread once the snapshot is published.
//  - latency: GAIN, PEQ, sanitise, meters and M/S add 0 frames; DELAY adds its target.
//  - sample rate: any rate in [8 kHz, 768 kHz]. The ramp window is 5 ms of frames,
//    clamped to 32..4096. PEQ state and coefficients are double precision.
//  - channels: 1..64 lanes; stages address lanes by index; M/S needs two distinct lanes.
//  - reset: a fresh snapshot starts with zero filter and delay memory and meters at 0.
//    There is no in-place reset; a new topology is a new snapshot.
#include "snapshot.hpp"

#include "stages_dsp.hpp"
#include "stages_system.hpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr size_t kMaxArenaBytes = size_t(1) << 31;
constexpr size_t kAlign = 16;

struct GainLane {
    float cur;        // value after the last rendered sample
    float step;
    float target;     // ramp destination
    uint32_t remaining;
};

struct DelayLane {
    uint32_t wp;
    uint32_t dCur;
    uint32_t dNew;
    uint32_t xfLeft;
    int32_t pending;
    uint32_t pad[3];
    // followed by float ring[capacity + 1]
};

struct PeqLane {
    double z[N60_PEQ_MAX_SECTIONS][2];
    double zn[N60_PEQ_MAX_SECTIONS][2];  // incoming section state during a coefficient crossfade
};

// Per-section control block, stored in the stage's coefficient region (shared by all lanes).
struct PeqSec {
    double cur[5];       // live coefficients (b0 b1 b2 a1 a2)
    double nxt[5];       // incoming coefficients while xfLeft != 0
    float seen[4];       // parameters the live/incoming design was made from
    uint32_t xfLeft;     // frames left in the crossfade (0 = none)
    uint32_t pad;
};

struct MeterLane {
    std::atomic<uint32_t> peakBits;  // positive floats order like their bit patterns
    std::atomic<uint32_t> rmsBits;
};

size_t alignUp(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }

uint32_t floatBits(float v) {
    uint32_t b;
    std::memcpy(&b, &v, sizeof b);
    return b;
}
float bitsFloat(uint32_t b) {
    float v;
    std::memcpy(&v, &b, sizeof v);
    return v;
}

uint32_t rampFramesFor(double rate) {
    long frames = std::lround(0.005 * rate);
    return static_cast<uint32_t>(std::clamp<long>(frames, 32, 4096));
}

}  // namespace

// RBJ Audio EQ Cookbook biquads, normalised by a0, in double precision.
// Same forms and limits as the kernel's control-plane design (N60Biquad.h).
bool designBiquad(uint32_t type, double rate, double f, double gainDb, double q, double out[5]) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(gainDb) || gainDb < -24.0 ||
        gainDb > 24.0 || !std::isfinite(q) || q <= 0.0) {
        return false;
    }
    const double w = 2.0 * kPi * f / rate;
    const double cw = std::cos(w);
    const double sw = std::sin(w);
    const double alpha = sw / (2.0 * q);
    double b0 = 0, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (type) {
        case 0: {  // peaking
            const double A = std::pow(10.0, gainDb / 40.0);
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
            break;
        }
        case 1: {  // low shelf
            const double A = std::pow(10.0, gainDb / 40.0);
            const double beta = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) - (A - 1) * cw + beta);
            b1 = 2 * A * ((A - 1) - (A + 1) * cw);
            b2 = A * ((A + 1) - (A - 1) * cw - beta);
            a0 = (A + 1) + (A - 1) * cw + beta;
            a1 = -2 * ((A - 1) + (A + 1) * cw);
            a2 = (A + 1) + (A - 1) * cw - beta;
            break;
        }
        case 2: {  // high shelf
            const double A = std::pow(10.0, gainDb / 40.0);
            const double beta = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) + (A - 1) * cw + beta);
            b1 = -2 * A * ((A - 1) + (A + 1) * cw);
            b2 = A * ((A + 1) + (A - 1) * cw - beta);
            a0 = (A + 1) - (A - 1) * cw + beta;
            a1 = 2 * ((A - 1) - (A + 1) * cw);
            a2 = (A + 1) - (A - 1) * cw - beta;
            break;
        }
        case 3:  // low pass
            b0 = (1 - cw) * 0.5; b1 = 1 - cw; b2 = (1 - cw) * 0.5;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 4:  // high pass
            b0 = (1 + cw) * 0.5; b1 = -(1 + cw); b2 = (1 + cw) * 0.5;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 5:  // notch
            b0 = 1; b1 = -2 * cw; b2 = 1;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 6:  // all pass
            b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 7:  // band pass, constant 0 dB peak
            b0 = alpha; b1 = 0; b2 = -alpha;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        default:
            return false;
    }
    if (!std::isfinite(a0) || std::fabs(a0) < 1e-20) return false;
    out[0] = b0 / a0; out[1] = b1 / a0; out[2] = b2 / a0; out[3] = a1 / a0; out[4] = a2 / a0;
    for (int i = 0; i < 5; ++i) {
        if (!std::isfinite(out[i])) return false;
    }
    return true;
}

namespace {

bool paramsFinite(const n60_stage_desc &s) {
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!std::isfinite(s.params[i])) return false;
    }
    return true;
}

uint32_t laneCountFor(const n60_stage_desc &s, uint32_t outCh) {
    if (s.laneMask != 0) return static_cast<uint32_t>(std::popcount(s.laneMask));
    return s.laneA == N60_LANE_ALL ? outCh : 1u;
}

// Position of a kind in the processing order (the numeric values predate ABI v3 and are
// kept for compatibility; the new kinds slot in by rank).
uint32_t rankOf(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_SANITISE: return 1;
        case N60_STAGE_METER_IN: return 2;
        case N60_STAGE_GAIN: return 3;
        case N60_STAGE_DENOISER: return 4;
        case N60_STAGE_MS_ENCODE: return 5;
        case N60_STAGE_PEQ: return 6;
        case N60_STAGE_DYN_EQ: return 7;
        case N60_STAGE_MS_DECODE: return 8;
        case N60_STAGE_FIR: return 9;
        case N60_STAGE_COMPRESSOR: return 10;
        case N60_STAGE_EXPANDER: return 11;
        case N60_STAGE_METER_OUT: return 12;
        case N60_STAGE_BASS_MGMT: return 13;
        case N60_STAGE_ROOM_FIR: return 14;
        case N60_STAGE_SPEAKER_IR: return 15;
        case N60_STAGE_AMBIENT: return 16;
        case N60_STAGE_CORE_DYNAMICS: return 17;
        case N60_STAGE_SYMMETRY: return 18;
        case N60_STAGE_CROSSFEED: return 19;
        case N60_STAGE_CROSSTALK: return 20;
        case N60_STAGE_OUTPUT_GAIN: return 21;
        case N60_STAGE_HEADPHONE: return 22;
        case N60_STAGE_PAUSE_GATE: return 23;
        case N60_STAGE_DELAY: return 24;
        case N60_STAGE_ANC_GUARD: return 25;
        case N60_STAGE_ANC_INJECT: return 26;
        case N60_STAGE_PROTECTION: return 27;
        case N60_STAGE_MUTE: return 28;
        case N60_STAGE_ANC_CAPTURE: return 29;
        case N60_STAGE_FINAL_SANITISE: return 30;
        case N60_STAGE_FINAL_METER: return 31;
        default: return 0;
    }
}

// Kinds that reuse another stage's implementation run as that canonical kind; only the
// rank (position in the chain) differs.
uint32_t canonKind(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_ROOM_FIR:
        case N60_STAGE_SPEAKER_IR: return N60_STAGE_FIR;
        case N60_STAGE_CORE_DYNAMICS: return N60_STAGE_COMPRESSOR;
        case N60_STAGE_OUTPUT_GAIN: return N60_STAGE_GAIN;
        case N60_STAGE_FINAL_SANITISE: return N60_STAGE_SANITISE;
        case N60_STAGE_FINAL_METER: return N60_STAGE_METER_OUT;
        default: return kind;
    }
}

// Per-stage state size in bytes for one lane.
size_t stateStrideFor(const n60_stage_desc &s, double rate) {
    switch (s.kind) {
        case N60_STAGE_METER_IN:
        case N60_STAGE_METER_OUT: return sizeof(MeterLane);
        case N60_STAGE_GAIN: return sizeof(GainLane);
        case N60_STAGE_PEQ: return sizeof(PeqLane);
        case N60_STAGE_DELAY:
            return alignUp(sizeof(DelayLane) + (size_t(s.capacityFrames) + 1) * sizeof(float));
        default: {
            size_t lane = 0, shared = 0;
            if (isDspKind(s.kind)) dspSizes(s, lane, shared);
            else if (isSystemKind(s.kind)) systemSizes(s, rate, lane, shared);
            return lane;
        }
    }
}

size_t sharedBytesFor(const n60_stage_desc &s, double rate) {
    size_t lane = 0, shared = 0;
    if (isDspKind(s.kind)) dspSizes(s, lane, shared);
    else if (isSystemKind(s.kind)) systemSizes(s, rate, lane, shared);
    return shared;
}

}  // namespace

n60_status validateDesc(const n60_graph_desc &d) {
    if (d.abiVersion != N60_GRAPH_ABI_VERSION || d.structSize != sizeof(n60_graph_desc)) {
        return N60_STATUS_ABI_MISMATCH;
    }
    if (!std::isfinite(d.sampleRate) || d.sampleRate < N60_GRAPH_MIN_SAMPLE_RATE ||
        d.sampleRate > N60_GRAPH_MAX_SAMPLE_RATE) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    auto validChannels = [](uint32_t n) { return n >= 1 && n <= N60_GRAPH_MAX_CHANNELS; };
    if (d.maxBlockFrames < 1 || d.maxBlockFrames > N60_GRAPH_MAX_BLOCK_FRAMES || !validChannels(d.inputChannels) ||
        !validChannels(d.outputChannels) || d.reserved != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (d.stageCount > N60_GRAPH_MAX_STAGES || (d.stageCount > 0 && d.stages == nullptr)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    uint32_t lastRank = 0;
    size_t total = 0;
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        if (s.structSize != sizeof(n60_stage_desc)) return N60_STATUS_ABI_MISMATCH;
        const uint32_t rank = rankOf(s.kind);
        s.kind = canonKind(s.kind);
        if (rank == 0 || rank < lastRank || s.reserved != 0) return N60_STATUS_BAD_ARGUMENT;
        lastRank = rank;
        for (uint32_t j = 0; j < i; ++j) {
            if (d.stages[j].stageId == s.stageId) return N60_STATUS_BAD_ARGUMENT;
        }
        if (s.paramCount > 0 && s.params == nullptr) return N60_STATUS_BAD_ARGUMENT;
        if (!paramsFinite(s)) return N60_STATUS_BAD_ARGUMENT;
        const bool isMS = s.kind == N60_STAGE_MS_ENCODE || s.kind == N60_STAGE_MS_DECODE;
        if (isSystemKind(s.kind)) {
            const n60_status v = validateSystemStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isDspKind(s.kind)) {
            const n60_status v = validateDspStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (s.laneMask != 0) return N60_STATUS_BAD_ARGUMENT;
        if (isMS) {
            if (s.laneA >= d.outputChannels || s.laneB >= d.outputChannels || s.laneA == s.laneB) {
                return N60_STATUS_BAD_ARGUMENT;
            }
        } else if (s.laneA != N60_LANE_ALL && s.laneA >= d.outputChannels) {
            return N60_STATUS_BAD_ARGUMENT;
        }
        if (s.kind != N60_STAGE_DELAY && s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
        switch (s.kind) {
            case N60_STAGE_GAIN:
                if (s.paramCount != 1 || s.params[0] < 0.0f || s.params[0] > 10000.0f) return N60_STATUS_BAD_ARGUMENT;
                break;
            case N60_STAGE_DELAY:
                if (s.paramCount != 1 || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES || s.params[0] < 0.0f ||
                    s.params[0] > static_cast<float>(s.capacityFrames)) {
                    return N60_STATUS_BAD_ARGUMENT;
                }
                break;
            case N60_STAGE_PEQ: {
                if (s.paramCount == 0 || s.paramCount % 4 != 0 || s.paramCount / 4 > N60_PEQ_MAX_SECTIONS) {
                    return N60_STATUS_BAD_ARGUMENT;
                }
                for (uint32_t k = 0; k < s.paramCount / 4; ++k) {
                    const float *p = s.params + 4 * k;
                    double c[5];
                    if (!(p[0] >= 0.0f && p[0] <= 7.0f) || p[0] != std::floor(p[0]) ||
                        !designBiquad(static_cast<uint32_t>(p[0]), d.sampleRate, p[1], p[2], p[3], c)) {
                        return N60_STATUS_BAD_ARGUMENT;
                    }
                }
                break;
            }
            default:
                if (s.paramCount != 0) return N60_STATUS_BAD_ARGUMENT;
                break;
        }
        total += stateStrideFor(s, d.sampleRate) * laneCountFor(s, d.outputChannels);
        if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
    }
    // Every M/S decode must undo exactly one earlier encode on the same lane pair.
    bool used[N60_GRAPH_MAX_STAGES] = {};
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        if (d.stages[i].kind != N60_STAGE_MS_DECODE) continue;
        bool matched = false;
        for (uint32_t j = 0; j < i && !matched; ++j) {
            const n60_stage_desc &e = d.stages[j];
            if (e.kind == N60_STAGE_MS_ENCODE && !used[j] && e.laneA == d.stages[i].laneA &&
                e.laneB == d.stages[i].laneB) {
                used[j] = true;
                matched = true;
            }
        }
        if (!matched) return N60_STATUS_BAD_ARGUMENT;
    }
    for (uint32_t j = 0; j < d.stageCount; ++j) {
        if (d.stages[j].kind == N60_STAGE_MS_ENCODE && !used[j]) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

n60_status buildSnapshot(const n60_graph_desc &d, uint32_t epoch, SnapHeader **out) {
    *out = nullptr;
    const n60_status valid = validateDesc(d);
    if (valid != N60_STATUS_OK) return valid;

    // Pass 1: lay out the arena.
    size_t off = alignUp(sizeof(SnapHeader));
    const size_t tableOff = off;
    off += alignUp(sizeof(StageRec) * d.stageCount);
    struct Plan { size_t params, state, coef, shared; };
    Plan plan[N60_GRAPH_MAX_STAGES];
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        s.kind = canonKind(s.kind);
        plan[i].params = off;
        off += alignUp(sizeof(float) * s.paramCount);
        plan[i].state = off;
        off += alignUp(stateStrideFor(s, d.sampleRate) * laneCountFor(s, d.outputChannels));
        plan[i].coef = off;
        if (s.kind == N60_STAGE_PEQ) off += alignUp(sizeof(PeqSec) * (s.paramCount / 4));
        plan[i].shared = off;
        off += alignUp(sharedBytesFor(s, d.sampleRate));
        if (off > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
    }

    // One allocation, aligned to 64 bytes by hand (no aligned-new on the build path).
    uint8_t *raw = new (std::nothrow) uint8_t[off + 64];
    if (raw == nullptr) return N60_STATUS_OUT_OF_MEMORY;
    uint8_t *base = raw + ((64 - (reinterpret_cast<uintptr_t>(raw) & 63)) & 63);
    std::memset(base, 0, off);
    SnapHeader *h = reinterpret_cast<SnapHeader *>(base);
    h->abiVersion = N60_GRAPH_ABI_VERSION;
    h->epoch = epoch;
    h->sampleRate = d.sampleRate;
    h->maxBlockFrames = d.maxBlockFrames;
    h->inputChannels = d.inputChannels;
    h->outputChannels = d.outputChannels;
    h->stageCount = d.stageCount;
    h->stageTableOff = static_cast<uint32_t>(tableOff);
    h->rampFrames = rampFramesFor(d.sampleRate);
    h->rawPad = static_cast<uint32_t>(base - raw);

    // Pass 2: fill the stage table, parameters and initial state.
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        s.kind = canonKind(s.kind);
        StageRec &r = stages(h)[i];
        r.laneMask = s.laneMask;
        r.kind = s.kind;
        r.id = s.stageId;
        r.laneA = s.laneA;
        r.laneB = s.laneB;
        r.laneFirst = s.laneMask != 0 ? static_cast<uint32_t>(std::countr_zero(s.laneMask))
                                     : (s.laneA == N60_LANE_ALL ? 0u : s.laneA);
        r.laneCount = laneCountFor(s, d.outputChannels);
        r.paramCount = s.paramCount;
        r.paramsOff = static_cast<uint32_t>(plan[i].params);
        r.stateOff = static_cast<uint32_t>(plan[i].state);
        r.stateStride = static_cast<uint32_t>(stateStrideFor(s, d.sampleRate));
        r.capacity = s.capacityFrames;
        r.coefOff = static_cast<uint32_t>(plan[i].coef);
        r.sharedOff = static_cast<uint32_t>(plan[i].shared);
        float *params = paramsOf(h, r);
        for (uint32_t k = 0; k < s.paramCount; ++k) params[k] = s.params[k];
        if (s.kind == N60_STAGE_DELAY) params[0] = std::floor(params[0] + 0.5f);
        r.applied = s.paramCount > 0 ? params[0] : 0.0f;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            uint8_t *st = laneState(h, r, l);
            switch (s.kind) {
                case N60_STAGE_METER_IN:
                case N60_STAGE_METER_OUT: {
                    MeterLane *m = new (st) MeterLane;
                    m->peakBits.store(0, std::memory_order_relaxed);
                    m->rmsBits.store(0, std::memory_order_relaxed);
                    break;
                }
                case N60_STAGE_GAIN: {
                    GainLane *g = reinterpret_cast<GainLane *>(st);
                    g->cur = g->target = params[0];
                    break;
                }
                case N60_STAGE_DELAY: {
                    DelayLane *dl = reinterpret_cast<DelayLane *>(st);
                    dl->dCur = dl->dNew = static_cast<uint32_t>(params[0]);
                    dl->pending = -1;
                    break;
                }
                default: break;
            }
        }
        if (isDspKind(s.kind)) dspInit(h, r);
        if (isSystemKind(s.kind)) systemInit(h, r);
        if (s.kind == N60_STAGE_PEQ) {
            PeqSec *sec = reinterpret_cast<PeqSec *>(bytes(h) + r.coefOff);
            for (uint32_t k = 0; k < s.paramCount / 4; ++k) {
                const float *p = s.params + 4 * k;
                designBiquad(static_cast<uint32_t>(p[0]), d.sampleRate, p[1], p[2], p[3], sec[k].cur);
                for (int j = 0; j < 4; ++j) sec[k].seen[j] = p[j];
            }
        }
    }
    *out = h;
    return N60_STATUS_OK;
}

void freeSnapshot(SnapHeader *snap) {
    if (snap == nullptr) return;
    uint8_t *raw = bytes(snap) - snap->rawPad;
    delete[] raw;
}

const StageRec *findStage(const SnapHeader *snap, uint32_t stageId) {
    const StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount; ++i) {
        if (table[i].id == stageId) return &table[i];
    }
    return nullptr;
}

n60_status validateParam(const SnapHeader *snap, const StageRec &r, uint32_t paramIndex, float value) {
    if (!std::isfinite(value)) return N60_STATUS_BAD_ARGUMENT;
    switch (r.kind) {
        case N60_STAGE_GAIN:
            return (paramIndex != 0 || value < 0.0f || value > 10000.0f) ? N60_STATUS_BAD_ARGUMENT : N60_STATUS_OK;
        case N60_STAGE_DELAY:
            return (paramIndex != 0 || value < 0.0f || value > static_cast<float>(r.capacity))
                       ? N60_STATUS_BAD_ARGUMENT
                       : N60_STATUS_OK;
        case N60_STAGE_PEQ: {
            // Every section parameter is live. Ranges are chosen so that any combination of valid
            // values designs successfully (the realtime thread designs; it cannot report failure).
            if (paramIndex >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
            const double v = value;
            switch (paramIndex % 4) {
                case 0: return (v >= 0.0 && v <= 7.0 && v == std::floor(v)) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                case 1: return (v > 0.0 && v < snap->sampleRate * 0.5) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                case 2: return (v >= -24.0 && v <= 24.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                default: return (v >= 0.01 && v <= 1000.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
            }
        }
        default:
            if (isSystemKind(r.kind)) return validateSystemParam(snap, r, paramIndex, value);
            return isDspKind(r.kind) ? validateDspParam(snap, r, paramIndex, value) : N60_STATUS_UNSUPPORTED;
    }
}

bool applyParam(SnapHeader *snap, uint32_t stageId, uint32_t paramIndex, float value, bool *latencyMayChange) {
    StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount; ++i) {
        StageRec &r = table[i];
        if (r.id != stageId) continue;
        if (validateParam(snap, r, paramIndex, value) != N60_STATUS_OK) return false;
        float *params = paramsOf(snap, r);
        params[paramIndex] = r.kind == N60_STAGE_DELAY ? std::floor(value + 0.5f) : value;
        // Only DELAY targets and protection look-ahead/oversampling feed the reported latency
        // (protection's latency inputs are not live, so DELAY is the only kind that changes it).
        if (latencyMayChange != nullptr && r.kind == N60_STAGE_DELAY) *latencyMayChange = true;
        return true;
    }
    return false;
}

uint32_t snapshotLatency(const SnapHeader *snap) {
    uint32_t perLane[N60_GRAPH_MAX_CHANNELS] = {};
    const StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount; ++i) {
        const StageRec &r = table[i];
        uint32_t frames = 0;
        if (r.kind == N60_STAGE_DELAY) {
            frames = static_cast<uint32_t>(reinterpret_cast<const float *>(bytes(snap) + r.paramsOff)[0]);
        } else if (isDspKind(r.kind)) {
            frames = dspLatency(snap, r);
        } else if (isSystemKind(r.kind)) {
            frames = systemLatency(snap, r);
        }
        if (frames == 0) continue;
        for (uint32_t l = 0; l < r.laneCount; ++l) perLane[laneOf(r, l)] += frames;
    }
    uint32_t worst = 0;
    for (uint32_t l = 0; l < snap->outputChannels; ++l) worst = std::max(worst, perLane[l]);
    return worst;
}

bool readMeter(SnapHeader *snap, uint32_t stageId, uint32_t lane, float *peak, float *rms) {
    const StageRec *r = findStage(snap, stageId);
    if (r == nullptr || (r->kind != N60_STAGE_METER_IN && r->kind != N60_STAGE_METER_OUT) ||
        lane < r->laneFirst || lane >= r->laneFirst + r->laneCount) {
        return false;
    }
    MeterLane *m = reinterpret_cast<MeterLane *>(laneState(snap, *r, lane - r->laneFirst));
    *peak = bitsFloat(m->peakBits.exchange(0, std::memory_order_relaxed));
    *rms = bitsFloat(m->rmsBits.load(std::memory_order_relaxed));
    return true;
}

namespace {

void runSanitise(float *buf, uint32_t frames, uint64_t &bad) {
    for (uint32_t i = 0; i < frames; ++i) {
        if (!(std::fabs(buf[i]) <= FLT_MAX)) {  // false for NaN and Inf
            buf[i] = 0.0f;
            ++bad;
        }
    }
}

void runMeter(MeterLane &m, const float *buf, uint32_t frames) {
    float peak = 0.0f;
    double sum = 0.0;
    for (uint32_t i = 0; i < frames; ++i) {
        const float a = std::fabs(buf[i]);
        peak = a > peak ? a : peak;
        sum += double(buf[i]) * double(buf[i]);
    }
    const uint32_t pb = floatBits(peak);
    uint32_t seen = m.peakBits.load(std::memory_order_relaxed);
    while (pb > seen && !m.peakBits.compare_exchange_weak(seen, pb, std::memory_order_relaxed)) {
    }
    m.rmsBits.store(floatBits(static_cast<float>(std::sqrt(sum / frames))), std::memory_order_relaxed);
}

void runGain(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float target = paramsOf(h, r)[0];
    const bool retarget = target != r.applied;
    r.applied = target;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        GainLane &g = *reinterpret_cast<GainLane *>(laneState(h, r, l));
        if (retarget) {
            g.remaining = h->rampFrames;
            g.target = target;
            g.step = (target - g.cur) / static_cast<float>(h->rampFrames);
        }
        float *buf = lanes[r.laneFirst + l];
        uint32_t i = 0;
        const uint32_t n = std::min(g.remaining, frames);
        // Computed from the destination so the last ramp sample is exactly the target
        // and the ramp is monotone in float.
        for (; i < n; ++i) {
            --g.remaining;
            g.cur = g.target - g.step * static_cast<float>(g.remaining);
            buf[i] *= g.cur;
        }
        const float c = g.cur;
        for (; i < frames; ++i) buf[i] *= c;
    }
}

void runMSEncode(float *a, float *b, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float l = a[i], r = b[i];
        a[i] = 0.5f * (l + r);
        b[i] = 0.5f * (l - r);
    }
}

void runMSDecode(float *a, float *b, uint32_t frames) {
    for (uint32_t i = 0; i < frames; ++i) {
        const float m = a[i], s = b[i];
        a[i] = m + s;
        b[i] = m - s;
    }
}

void runPeq(SnapHeader *h, const StageRec &r, float *const *lanes, uint32_t frames) {
    const uint32_t sections = r.paramCount / 4;
    PeqSec *sec = reinterpret_cast<PeqSec *>(bytes(h) + r.coefOff);
    const float *params = paramsOf(h, r);
    const uint32_t ramp = h->rampFrames;
    // A changed section is rendered twice: old coefficients, and new coefficients with state
    // continued from the old section. The two outputs are crossfaded over the ramp window and the
    // old one is dropped. An edit that lands during a crossfade starts the next one afterwards.
    for (uint32_t s = 0; s < sections; ++s) {
        const float *p = params + 4 * s;
        PeqSec &q = sec[s];
        if (q.xfLeft != 0 || (p[0] == q.seen[0] && p[1] == q.seen[1] && p[2] == q.seen[2] && p[3] == q.seen[3])) continue;
        if (!designBiquad(static_cast<uint32_t>(p[0]), h->sampleRate, p[1], p[2], p[3], q.nxt)) {
            for (int j = 0; j < 4; ++j) q.seen[j] = p[j];  // unreachable for validated values; keep the old design
            continue;
        }
        for (int j = 0; j < 4; ++j) q.seen[j] = p[j];
        q.xfLeft = ramp;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            PeqLane &st = *reinterpret_cast<PeqLane *>(laneState(h, r, l));
            st.zn[s][0] = st.z[s][0];
            st.zn[s][1] = st.z[s][1];
        }
    }
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        PeqLane &st = *reinterpret_cast<PeqLane *>(laneState(h, r, l));
        float *buf = lanes[r.laneFirst + l];
        double z[N60_PEQ_MAX_SECTIONS][2], zn[N60_PEQ_MAX_SECTIONS][2];
        std::memcpy(z, st.z, sizeof z);
        std::memcpy(zn, st.zn, sizeof zn);
        uint32_t xf[N60_PEQ_MAX_SECTIONS];
        const double *live[N60_PEQ_MAX_SECTIONS];
        for (uint32_t s = 0; s < sections; ++s) {
            xf[s] = sec[s].xfLeft;
            live[s] = sec[s].cur;
        }
        for (uint32_t i = 0; i < frames; ++i) {
            double x = buf[i];
            for (uint32_t s = 0; s < sections; ++s) {  // transposed direct form II
                const double *c = live[s];
                double y = c[0] * x + z[s][0];
                z[s][0] = c[1] * x - c[3] * y + z[s][1];
                z[s][1] = c[2] * x - c[4] * y;
                if (xf[s] != 0) {
                    const double *n = sec[s].nxt;
                    const double yn = n[0] * x + zn[s][0];
                    zn[s][0] = n[1] * x - n[3] * yn + zn[s][1];
                    zn[s][1] = n[2] * x - n[4] * yn;
                    y += (static_cast<double>(ramp - xf[s] + 1) / static_cast<double>(ramp)) * (yn - y);
                    if (--xf[s] == 0) {  // the incoming section takes over, state and all
                        z[s][0] = zn[s][0];
                        z[s][1] = zn[s][1];
                        live[s] = sec[s].nxt;
                    }
                }
                x = y;
            }
            buf[i] = static_cast<float>(x);
        }
        // Flush decayed state so a quiet tail never lingers in denormals (slow on some CPUs).
        for (uint32_t s = 0; s < sections; ++s) {
            for (int k = 0; k < 2; ++k) {
                if (std::fabs(z[s][k]) < 1e-30) z[s][k] = 0.0;
                if (std::fabs(zn[s][k]) < 1e-30) zn[s][k] = 0.0;
            }
        }
        std::memcpy(st.z, z, sizeof z);
        std::memcpy(st.zn, zn, sizeof zn);
    }
    for (uint32_t s = 0; s < sections; ++s) {
        PeqSec &q = sec[s];
        if (q.xfLeft == 0) continue;
        if (q.xfLeft <= frames) {
            std::memcpy(q.cur, q.nxt, sizeof q.cur);
            q.xfLeft = 0;
        } else {
            q.xfLeft -= frames;
        }
    }
}

void runDelay(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const uint32_t target = static_cast<uint32_t>(paramsOf(h, r)[0]);
    const uint32_t ramp = h->rampFrames;
    const uint32_t ringSize = r.capacity + 1;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        DelayLane &d = *reinterpret_cast<DelayLane *>(laneState(h, r, l));
        float *ring = reinterpret_cast<float *>(&d + 1);
        if (d.xfLeft == 0) {
            if (target != d.dCur) {
                d.dNew = target;
                d.xfLeft = ramp;
            }
        } else if (target == d.dNew) {
            d.pending = -1;
        } else {
            d.pending = static_cast<int32_t>(target);
        }
        float *buf = lanes[r.laneFirst + l];
        uint32_t wp = d.wp;
        for (uint32_t i = 0; i < frames; ++i) {
            ring[wp] = buf[i];
            int64_t oi = int64_t(wp) - d.dCur;
            if (oi < 0) oi += ringSize;
            float y = ring[oi];
            if (d.xfLeft != 0) {
                int64_t ni = int64_t(wp) - d.dNew;
                if (ni < 0) ni += ringSize;
                const float t = static_cast<float>(ramp - d.xfLeft + 1) / static_cast<float>(ramp);
                y += t * (ring[ni] - y);
                if (--d.xfLeft == 0) {
                    d.dCur = d.dNew;
                    if (d.pending >= 0 && static_cast<uint32_t>(d.pending) != d.dCur) {
                        d.dNew = static_cast<uint32_t>(d.pending);
                        d.xfLeft = ramp;
                    }
                    d.pending = -1;
                }
            }
            buf[i] = y;
            if (++wp == ringSize) wp = 0;
        }
        d.wp = wp;
    }
    r.applied = static_cast<float>(target);
}

}  // namespace

void runSnapshot(SnapHeader *h, float *const *lanes, uint32_t frames, std::atomic<uint64_t> &sanitisedSamples) {
    StageRec *table = stages(h);
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        StageRec &r = table[i];
        switch (r.kind) {
            case N60_STAGE_SANITISE: {
                uint64_t bad = 0;
                for (uint32_t l = 0; l < r.laneCount; ++l) runSanitise(lanes[r.laneFirst + l], frames, bad);
                if (bad != 0) sanitisedSamples.fetch_add(bad, std::memory_order_relaxed);
                break;
            }
            case N60_STAGE_METER_IN:
            case N60_STAGE_METER_OUT:
                for (uint32_t l = 0; l < r.laneCount; ++l) {
                    runMeter(*reinterpret_cast<MeterLane *>(laneState(h, r, l)), lanes[r.laneFirst + l], frames);
                }
                break;
            case N60_STAGE_GAIN: runGain(h, r, lanes, frames); break;
            case N60_STAGE_MS_ENCODE: runMSEncode(lanes[r.laneA], lanes[r.laneB], frames); break;
            case N60_STAGE_PEQ: runPeq(h, r, lanes, frames); break;
            case N60_STAGE_MS_DECODE: runMSDecode(lanes[r.laneA], lanes[r.laneB], frames); break;
            case N60_STAGE_DELAY: runDelay(h, r, lanes, frames); break;
            default:
                if (isSystemKind(r.kind)) {
                    runSystem(h, r, lanes, frames);
                } else {
                    runDsp(h, r, lanes, frames);
                }
                break;
        }
    }
}

}  // namespace n60
