// libn60core ABI v4 system stages (E6 S5, design note section 5). Portable C++20,
// standard library only, no Apple framework.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runSystem:
//  - allocation: none. All state lives in the snapshot arena (lane state and stage-shared
//    state), laid out on the control thread. Nothing is allocated, locked or logged.
//  - synchronisation: none between stages. The howl-guard status and the ANC capture ring
//    are relaxed/acquire/release atomics the control thread reads; everything else is owned
//    by the realtime thread once the snapshot is published.
//  - latency: every stage adds 0 frames except PROTECTION, whose latency is the half-band
//    oversampling delay (32 frames at 2x, 48 at 4x) plus ceil(look-ahead high samples / factor).
//  - sample rate: any rate in [8 kHz, 768 kHz]. Times are converted to frames from the
//    snapshot rate. Filters and one-pole detectors are double precision.
//  - channels: 1..64 lanes. Pair stages need two distinct lanes. Protection and the pause
//    gate link all of their lanes (one detector); bass management reads its main lanes and
//    replaces its sub lane.
//  - reset: a fresh snapshot starts with zero filter, delay and detector memory, gains at
//    their targets (the injection gain and the pause gate start at their open/silent
//    values as documented per stage). A topology change is a new snapshot; the ANC capture
//    ring and the guard history restart with it (continuity across swaps belongs to S6).
//  - authorisation: ANC injection and capture are enabled only by a snapshot parameter
//    that the core never sets and a live post can never change.
#include "stages_system.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr uint32_t kMaxLanes = N60_GRAPH_MAX_CHANNELS;
constexpr uint32_t kBassFixed = 9;     // BASS_MGMT: globals plus subwoofer 0 (its lane, gain, polarity, section count)
constexpr uint32_t kBassMaxSubs = 8;
constexpr uint32_t kBassMaxEq = 8;

size_t up(size_t v) { return (v + 15) & ~size_t(15); }
double db2lin(double db) { return std::pow(10.0, db / 20.0); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }

struct Ramp {
    float cur, target, step;
    uint32_t remaining;
};
void rampInit(Ramp &r, float v) {
    r.cur = r.target = v;
    r.step = 0.0f;
    r.remaining = 0;
}
void rampSet(Ramp &r, float t, uint32_t frames) {
    if (frames == 0) {
        rampInit(r, t);
        return;
    }
    r.target = t;
    r.remaining = frames;
    r.step = (t - r.cur) / static_cast<float>(frames);
}
// Same formula as the GAIN stage: computed from the destination so the last sample is exact.
inline float rampNext(Ramp &r) {
    if (r.remaining != 0) {
        --r.remaining;
        r.cur = r.target - r.step * static_cast<float>(r.remaining);
    }
    return r.cur;
}

struct Bq {
    double z1, z2;
};
inline double bqRun(const double *c, Bq &s, double x) {  // transposed direct form II
    const double y = c[0] * x + s.z1;
    s.z1 = c[1] * x - c[3] * y + s.z2;
    s.z2 = c[2] * x - c[4] * y;
    return y;
}
inline void bqFlush(Bq &s) {
    if (!(std::fabs(s.z1) >= 1e-30) || !std::isfinite(s.z1)) s.z1 = 0.0;
    if (!(std::fabs(s.z2) >= 1e-30) || !std::isfinite(s.z2)) s.z2 = 0.0;
}

constexpr double kButterQ = 0.70710678118654752440;

// ---- lane rules --------------------------------------------------------------------

enum class Lanes { MaskOnly, MaskOrOne, Pair, Single };

bool lanesOk(const n60_stage_desc &s, uint32_t outCh, Lanes rule) {
    const bool maskInRange = outCh >= 64 || (s.laneMask >> outCh) == 0;
    switch (rule) {
        case Lanes::MaskOnly: return s.laneMask != 0 && s.laneA == 0 && s.laneB == 0 && maskInRange;
        case Lanes::MaskOrOne:
            if (s.laneMask != 0) return s.laneA == 0 && s.laneB == 0 && maskInRange;
            return s.laneB == 0 && (s.laneA == N60_LANE_ALL || s.laneA < outCh);
        case Lanes::Pair: return s.laneMask == 0 && s.laneA < outCh && s.laneB < outCh && s.laneA != s.laneB;
        case Lanes::Single: return s.laneMask == 0 && s.laneB == 0 && s.laneA < outCh;
    }
    return false;
}

Lanes ruleOf(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_BASS_MGMT:
        case N60_STAGE_PAUSE_GATE:
        case N60_STAGE_ANC_CAPTURE: return Lanes::MaskOnly;
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED:
        case N60_STAGE_CROSSTALK:
        case N60_STAGE_HEADPHONE: return Lanes::Pair;
        case N60_STAGE_ANC_GUARD:
        case N60_STAGE_ANC_INJECT: return Lanes::Single;
        default: return Lanes::MaskOrOne;
    }
}

// ---- parameter layouts ---------------------------------------------------------------

constexpr uint32_t kHpFixed = 11;
constexpr uint32_t kGuardParams = 12 + N60_ANC_GUARD_BANDS;
constexpr uint32_t kHpRing = 512;

bool sectionOk(const float *p, double rate) {
    double c[5];
    return isInt(p[0]) && p[0] >= 0.0f && p[0] <= 7.0f &&
           designBiquad(static_cast<uint32_t>(p[0]), rate, p[1], p[2], p[3], c);
}

// BASS_MGMT parameter layout (ABI v7). Subwoofer 0 is the v6 fixed block: [2] lane, [6] gain, [7] polarity, [8] section
// count n0, then 4 per section. When more follow, the next value is the extension word w (0..15): m = w mod 8 extra
// subs, and w >= 8 selects host-weighted mode (no 1/N). Each extra sub is: lane, gain dB, polarity, section count n,
// then 4 per section. A v6 parameter list is a one-sub list in the default mode (1/N, which is 1 for one sub).
struct BassSubIdx {
    uint32_t lane, gain, pol, nEq, eq;
};
struct BassLayout {
    uint32_t subs, end, ext;  // ext: index of the extension word, 0 when absent
    bool weighted;
    BassSubIdx s[kBassMaxSubs];
};
bool parseBass(const float *p, uint32_t have, BassLayout &L) {
    if (have < kBassFixed || !isInt(p[8]) || p[8] < 0.0f || p[8] > static_cast<float>(kBassMaxEq)) return false;
    L.subs = 1;
    L.ext = 0;
    L.weighted = false;
    L.s[0] = {2, 6, 7, 8, 9};
    uint32_t pos = kBassFixed + 4u * static_cast<uint32_t>(p[8]);
    if (have < pos) return false;
    if (have > pos) {
        if (!isInt(p[pos]) || p[pos] < 0.0f || p[pos] > 15.0f) return false;
        const uint32_t w = static_cast<uint32_t>(p[pos]);
        L.ext = pos++;
        L.weighted = w >= 8;
        const uint32_t m = w & 7u;
        for (uint32_t k = 0; k < m; ++k) {
            if (have < pos + 4) return false;
            const float n = p[pos + 3];
            if (!isInt(n) || n < 0.0f || n > static_cast<float>(kBassMaxEq)) return false;
            L.s[L.subs++] = {pos, pos + 1, pos + 2, pos + 3, pos + 4};
            pos += 4u + 4u * static_cast<uint32_t>(n);
            if (have < pos) return false;
        }
    }
    L.end = pos;
    return true;
}

uint32_t expectedParamCount(uint32_t kind, const float *p, uint32_t have) {
    switch (kind) {
        case N60_STAGE_BASS_MGMT: {
            BassLayout L;
            return parseBass(p, have, L) ? L.end : 0u;
        }
        case N60_STAGE_AMBIENT: return 10;
        case N60_STAGE_SYMMETRY: return 1;
        case N60_STAGE_CROSSFEED: return 1;
        case N60_STAGE_CROSSTALK: return 2;
        case N60_STAGE_HEADPHONE:
            return have >= kHpFixed && isInt(p[9]) && isInt(p[10]) && p[9] >= 0.0f && p[9] <= 16.0f && p[10] >= 0.0f &&
                           p[10] <= 16.0f
                       ? kHpFixed + 4u * (static_cast<uint32_t>(p[9]) + static_cast<uint32_t>(p[10]))
                       : 0u;
        case N60_STAGE_PAUSE_GATE: return 5;
        case N60_STAGE_PROTECTION: return 7;
        case N60_STAGE_MUTE: return 1;
        case N60_STAGE_FRAC_DELAY: return 2;
        case N60_STAGE_ANC_GUARD: return kGuardParams;
        case N60_STAGE_ANC_INJECT: return have == 4 ? 4u : 3u;
        case N60_STAGE_ANC_CAPTURE: return 1;
        default: return 0;
    }
}

struct ProtCfg {
    bool limiter;
    float ceilLin;
    uint32_t factor;
    uint32_t laHigh;
    uint32_t atkHigh;
    double relCoef;
    uint32_t latency;
};

uint32_t osLatency(uint32_t factor) { return factor == 2 ? 32u : (factor == 4 ? 48u : 0u); }

ProtCfg protCfg(const float *p, double rate) {
    ProtCfg c{};
    c.limiter = p[0] != 0.0f;
    const bool tp = p[5] != 0.0f;
    c.factor = !c.limiter ? 1u : (tp ? 4u : static_cast<uint32_t>(p[6]));  // limiter off = bypass
    const double highRate = rate * static_cast<double>(c.factor);
    c.ceilLin = std::pow(10.0f, p[1] / 20.0f);
    c.laHigh = c.limiter ? static_cast<uint32_t>(std::ceil(static_cast<double>(p[4]) * 0.001 * highRate)) : 0u;
    c.atkHigh = c.limiter ? static_cast<uint32_t>(std::fmax(1.0, std::ceil(static_cast<double>(p[2]) * 0.001 * highRate))) : 1u;
    c.relCoef = c.limiter ? std::exp(-1.0 / std::fmax(1.0, static_cast<double>(p[3]) * 0.001 * highRate)) : 0.0;
    const uint32_t laFrames = c.laHigh == 0 ? 0u : (c.laHigh + c.factor - 1u) / c.factor;
    c.latency = osLatency(c.factor) + laFrames;
    return c;
}

// ---- state layouts ------------------------------------------------------------------

struct AmbLane {
    Ramp g;
    float seen;
    float pad;
    Bq z[3];
};
struct AmbShared {
    double coef[3][5];
};
struct SymShared {
    Ramp gl, gr;
    float seen;
};
struct CfShared {
    Ramp a;
    float seen;
};
struct CtShared {
    Ramp amt;
    float seenAmt, seenHz;
    double alpha, sL, sR;
    double alphaTarget, alphaStep;  // shadow low-pass coefficient ramps over the ramp window
    uint32_t alphaLeft, pad;
};
struct HpShared {
    Ramp mix, gA, gB;
    float seenMix, seenGA, seenGB, headroom;
    float polA, polB;
    uint32_t delay, nA, nB, wp;
    double alpha, lowA, lowB, dlowA, dlowB;
    float ringA[kHpRing], ringB[kHpRing];
    Bq zA[16], zB[16];
    double coef[32][5];
};
struct GateShared {
    double env, gain;
    uint32_t open, below, holdFrames, pad;
    double thr, hystLin, atk, rel, cOut, cIn;
};
struct BassLane {
    Bq hp1, hp2, lp1, lp2;
    Bq nhp1, nhp2, nlp1, nlp2;  // incoming crossover during a coefficient crossfade
};
// One subwoofer output of BASS_MGMT (ABI v7): own gain, polarity and EQ sections, all live.
struct BassSub {
    Ramp g, pol;                        // gain and polarity (+1 / -1) ramps: a flip passes through zero
    float seenG, seenPol;
    float seenEq[kBassMaxEq][3];        // last acted-on Hz, dB, Q of each section
    double eq[kBassMaxEq][5], eqN[kBassMaxEq][5];  // live and incoming coefficients
    Bq z[kBassMaxEq], zN[kBassMaxEq];
    uint32_t xf[kBassMaxEq];            // frames left in a section's coefficient crossfade
    uint32_t lane, nEq, gainIdx, polIdx, eqIdx;
};
struct BassShared {
    double hp[5], lp[5], lfe[5];
    Bq lfe1, lfe2;
    double hpN[5], lpN[5], lfeN[5];  // incoming coefficients during a crossfade
    Bq lfe1n, lfe2n;
    uint32_t xfX, xfLfe;             // frames left in the crossover and LFE low-pass crossfades
    Ramp redirect, lfeG;
    float seenX, seenR, seenLfeHz, seenLfeG;
    uint32_t nSubs, clearLfe;
    double norm;  // 1/N in the default mode, 1 when host-weighted
    int32_t lfeLane;
    BassSub sub[kBassMaxSubs];
};
// Fractional delay (ABI v11): the kernel's causal Thiran all-pass (N60FractionalDelay.h), designed in double.
constexpr uint32_t kFdCapacity = 8192;
struct FdLane {
    uint32_t wp, order, intFrames, pad;
    float den[4];
    float inH[3], outH[3];
    float ring[kFdCapacity];
};
void fdDesign(double total, FdLane &d) {
    d.order = 0;
    d.den[0] = 1.0f;
    const double fl = std::floor(total);
    const double fr = total - fl;
    if (fr < 1.0e-6 || (1.0 - fr) < 1.0e-6) {
        d.intFrames = static_cast<uint32_t>(std::llround(total));
        return;
    }
    const uint32_t floorFrames = static_cast<uint32_t>(fl);
    const uint32_t order = floorFrames >= 2u ? 3u : floorFrames + 1u;
    const uint32_t designedInt = floorFrames - (order - 1u);
    d.intFrames = floorFrames;  // plain integer delay if the design below is rejected
    const double want = static_cast<double>(order - 1u) + fr;
    static const double binom[4][4] = {{1, 0, 0, 0}, {1, 1, 0, 0}, {1, 2, 1, 0}, {1, 3, 3, 1}};
    float den[4] = {1.0f, 0.0f, 0.0f, 0.0f};
    for (uint32_t k = 1; k <= order; ++k) {
        double prod = 1.0;
        for (uint32_t n = 0; n <= order; ++n) {
            prod *= (want - order + n) / (want - order + k + n);
        }
        const double c = ((k & 1u) ? -1.0 : 1.0) * binom[order][k] * prod;
        if (!std::isfinite(c) || std::fabs(c) >= 1.0) return;  // unreachable for validated ranges: stay a plain integer delay
        den[k] = static_cast<float>(c);
    }
    d.order = order;
    d.intFrames = designedInt;
    for (uint32_t k = 0; k <= order; ++k) d.den[k] = den[k];
}
struct MuteLane {
    Ramp g;
    float seen;
};
struct InjectShared {
    Ramp g;
    Ramp hold;        // 10 ms mute ramp driven by rebuilds (E6 S6): 1 = passing, 0 = held
    float seen;
    float seenRev;    // last re-arm revision acted on (params[3])
    float holdWant;   // target the hold ramp was last aimed at
    uint32_t authorised;
    uint32_t held;    // set by a rebuild; cleared only by a change of the re-arm revision
};
struct CapShared {
    std::atomic<uint64_t> written;  // frames fully published
    std::atomic<uint64_t> claimed;  // frames the writer has started overwriting (seqlock)
};
struct Hb {
    float s[130];  // history stored twice (at i and i+65) so a read window never wraps
    uint32_t w;
};
struct ProtLane {
    Hb up1, up2, dn2, dn1;
    std::atomic<uint32_t> inTpBits;   // ABI v8: peak at the oversampled limiter input, since the last read
    std::atomic<uint32_t> outTpBits;  // and at its output
    std::atomic<uint32_t> grMaxBits;  // deepest limiter reduction (dB) since the last read (the same on every lane)
    std::atomic<uint32_t> grNowBits;  // reduction at the end of the last block
    // followed by float ring[laHigh + 2]
};
struct ProtShared {
    uint64_t seq;
    double gain;
    uint32_t ph2, ph1, head, count, cap, cfgValid;
    float seenCeil, seenAtk, seenRel, pad2;  // protCfg inputs the cached cfg was derived from
    std::atomic<uint32_t> guardActive;       // ABI v8: 1 when the limiter runs with oversampling
    uint32_t pad3;
    ProtCfg cfg;                              // cached: pow/exp are not redone every block
    // followed by float val[cap]; uint64_t idx[cap]
};

struct GuardBand {
    double b0, b2, a1, a2, z1, z2;
};
struct GuardState {
    uint32_t hasBaseline, growthBlocks, errBlocks, blockFrames, decimation, rampFrames;
    int32_t errLane, refLane;
    float ceiling, seenRev;
    double growthRatio, refAllow, errRatio, floorLin;
    double baseline[N60_ANC_GUARD_BANDS];
    GuardBand bands[N60_ANC_GUARD_BANDS];
    uint32_t blockPos, blocksSeen, decPos, bandCount, growthRun, errRun, rampRemaining, pad;
    double outSum, refSum, outHist[2], refHist[2], decSum;
    double bandSum[N60_ANC_GUARD_BANDS];
    uint64_t framesSinceArm;
    float gain, rampStart, gainTarget, pad2;
    std::atomic<uint32_t> trip, muted;
    std::atomic<uint64_t> tripFrame, processed, tripCount;
};

double fromDb10(double db) { return std::pow(10.0, db / 10.0); }

size_t protRingBytes(const ProtCfg &c) { return up((size_t(c.laHigh) + 2) * sizeof(float)); }
size_t protSharedBytes(const ProtCfg &c) {
    const size_t cap = size_t(c.laHigh) + 2;
    return up(sizeof(ProtShared) + cap * sizeof(float)) + up(cap * sizeof(uint64_t));
}
inline float *protVal(ProtShared *s) { return reinterpret_cast<float *>(s + 1); }
inline uint64_t *protIdx(ProtShared *s) {
    return reinterpret_cast<uint64_t *>(reinterpret_cast<uint8_t *>(s) + up(sizeof(ProtShared) + size_t(s->cap) * sizeof(float)));
}
inline float *protRing(ProtLane *l) { return reinterpret_cast<float *>(l + 1); }

}  // namespace

bool isSystemKind(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_BASS_MGMT:
        case N60_STAGE_AMBIENT:
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED:
        case N60_STAGE_CROSSTALK:
        case N60_STAGE_HEADPHONE:
        case N60_STAGE_PAUSE_GATE:
        case N60_STAGE_ANC_GUARD:
        case N60_STAGE_ANC_INJECT:
        case N60_STAGE_PROTECTION:
        case N60_STAGE_MUTE:
        case N60_STAGE_FRAC_DELAY:
        case N60_STAGE_ANC_CAPTURE: return true;
        default: return false;
    }
}

// ---- validation ----------------------------------------------------------------------

namespace {

bool paramOk(uint32_t kind, uint32_t i, float v, const float *p, double rate, uint32_t outCh) {
    switch (kind) {
        case N60_STAGE_BASS_MGMT:
            switch (i) {
                case 0: return inR(v, 20.0, std::min(20000.0, rate * 0.45));
                case 1: return inR(v, -24.0, 12.0);
                case 2: return isInt(v) && v >= 0.0f && v < static_cast<float>(outCh);
                case 3: return isInt(v) && v >= -1.0f && v < static_cast<float>(outCh);
                case 4: return inR(v, 20.0, std::min(500.0, rate * 0.45));
                case 5: return inR(v, -24.0, 24.0);
                case 6: return inR(v, -60.0, 24.0);
                case 7: return v == 0.0f || v == 1.0f;
                case 8: return true;  // checked by expectedParamCount
                default: return true;  // extra subs and sections: checked by parseBass and the full validation
            }
        case N60_STAGE_AMBIENT:
            if (i == 0) return inR(v, -60.0, 24.0);
            return true;  // bands: checked below
        case N60_STAGE_SYMMETRY: return inR(v, -1.0, 1.0);
        case N60_STAGE_CROSSFEED: return inR(v, 0.0, 0.5);
        case N60_STAGE_CROSSTALK: return i == 0 ? inR(v, 200.0, 2000.0) : inR(v, 0.0, 1.0);
        case N60_STAGE_HEADPHONE:
            switch (i) {
                case 0: return inR(v, -24.0, 0.0);
                case 1: return inR(v, 0.0, 1.0);
                case 2: return inR(v, 15.0, 90.0);
                case 3: return inR(v, 0.06, 0.12);
                case 4: return inR(v, 200.0, 2000.0);
                case 5:
                case 6: return inR(v, -24.0, 24.0);
                case 7:
                case 8: return v == 0.0f || v == 1.0f;
                default: return true;
            }
        case N60_STAGE_PAUSE_GATE:
            switch (i) {
                case 0: return inR(v, -120.0, -20.0);
                case 1: return inR(v, 0.0, 24.0);
                case 2: return inR(v, 0.0, 5000.0);
                case 3: return inR(v, 0.05, 1000.0);
                default: return inR(v, 0.05, 5000.0);
            }
        case N60_STAGE_PROTECTION:
            switch (i) {
                case 0:
                case 5: return v == 0.0f || v == 1.0f;
                case 1: return inR(v, -20.0, 0.0);
                case 2: return inR(v, 0.1, 50.0);
                case 3: return inR(v, 5.0, 500.0);
                case 4: return inR(v, 0.0, 20.0);
                default: return v == 1.0f || v == 2.0f || v == 4.0f;
            }
        case N60_STAGE_MUTE: return v == 0.0f || v == 1.0f;
        case N60_STAGE_FRAC_DELAY: return i == 0 ? (isInt(v) && v >= 0.0f && v <= static_cast<float>(kFdCapacity - 2u)) : inR(v, 0.0, 1.0);
        case N60_STAGE_ANC_GUARD:
            switch (i) {
                case 0:
                case 1: return isInt(v) && v >= -1.0f && v < static_cast<float>(outCh);
                case 2: return inR(v, 0.5, 40.0);
                case 3:
                case 6: return isInt(v) && v >= 1.0f && v <= 10.0f;
                case 4: return inR(v, 0.0, 20.0);
                case 5: return inR(v, 0.5, 40.0);
                case 7: return v > 0.0f && v <= 1.0f && std::isfinite(v);
                case 8: return inR(v, -160.0, 0.0);
                case 9: return inR(v, 0.001, 0.1);
                case 10: return v == 0.0f || v == 1.0f;
                case 11: return isInt(v) && v >= 0.0f && v <= 16777216.0f;
                default: return p[10] == 0.0f || inR(v, -200.0, 0.0);
            }
        case N60_STAGE_ANC_INJECT:
            switch (i) {
                case 0: return isInt(v) && v >= 0.0f && v < static_cast<float>(outCh);
                case 1: return v == 0.0f || v == 1.0f;
                case 3: return isInt(v) && v >= 0.0f && v <= 16777216.0f;
                default: return inR(v, -96.0, 0.0);
            }
        case N60_STAGE_ANC_CAPTURE: return v == 0.0f || v == 1.0f;
        default: return false;
    }
}

}  // namespace

n60_status validateSystemStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!lanesOk(s, outCh, ruleOf(s.kind))) return N60_STATUS_BAD_ARGUMENT;
    if (s.kind == N60_STAGE_ANC_CAPTURE) {
        if (s.capacityFrames < 1 || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES) return N60_STATUS_BAD_ARGUMENT;
    } else if (s.capacityFrames != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.params == nullptr) return N60_STATUS_BAD_ARGUMENT;
    const uint32_t expect = expectedParamCount(s.kind, s.params, s.paramCount);
    if (expect == 0 || s.paramCount != expect) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!paramOk(s.kind, i, p[i], p, rate, outCh)) return N60_STATUS_BAD_ARGUMENT;
    }
    switch (s.kind) {
        case N60_STAGE_BASS_MGMT: {
            BassLayout L;
            if (!parseBass(p, s.paramCount, L)) return N60_STATUS_BAD_ARGUMENT;
            uint64_t seen = 0;
            for (uint32_t q = 0; q < L.subs; ++q) {
                const BassSubIdx &x = L.s[q];
                if (!isInt(p[x.lane]) || p[x.lane] < 0.0f || p[x.lane] >= static_cast<float>(outCh)) return N60_STATUS_BAD_ARGUMENT;
                const uint32_t sub = static_cast<uint32_t>(p[x.lane]);
                if (((s.laneMask >> sub) & 1u) != 0 || ((seen >> sub) & 1u) != 0) return N60_STATUS_BAD_ARGUMENT;
                seen |= uint64_t(1) << sub;
                if (!inR(p[x.gain], -60.0, 24.0) || (p[x.pol] != 0.0f && p[x.pol] != 1.0f)) return N60_STATUS_BAD_ARGUMENT;
                for (uint32_t k = 0; k < static_cast<uint32_t>(p[x.nEq]); ++k) {
                    if (!sectionOk(p + x.eq + 4 * k, rate)) return N60_STATUS_BAD_ARGUMENT;
                }
            }
            if (p[3] >= 0.0f) {
                const uint32_t lfe = static_cast<uint32_t>(p[3]);
                if (((s.laneMask >> lfe) & 1u) != 0) return N60_STATUS_BAD_ARGUMENT;
            }
            break;
        }
        case N60_STAGE_AMBIENT:
            for (uint32_t k = 0; k < 3; ++k) {
                double c[5];
                if (!designBiquad(0, rate, p[1 + 3 * k], p[2 + 3 * k], p[3 + 3 * k], c)) return N60_STATUS_BAD_ARGUMENT;
            }
            break;
        case N60_STAGE_HEADPHONE: {
            const uint32_t n = static_cast<uint32_t>(p[9]) + static_cast<uint32_t>(p[10]);
            for (uint32_t k = 0; k < n; ++k) {
                if (!sectionOk(p + kHpFixed + 4 * k, rate)) return N60_STATUS_BAD_ARGUMENT;
            }
            break;
        }
        case N60_STAGE_ANC_GUARD: {
            const uint32_t src = s.laneA;
            if ((p[0] >= 0.0f && static_cast<uint32_t>(p[0]) == src) || (p[1] >= 0.0f && static_cast<uint32_t>(p[1]) == src)) {
                return N60_STATUS_BAD_ARGUMENT;
            }
            if (rate < 8000.0) return N60_STATUS_BAD_ARGUMENT;
            break;
        }
        case N60_STAGE_ANC_INJECT:
            if (static_cast<uint32_t>(p[0]) == s.laneA) return N60_STATUS_BAD_ARGUMENT;
            break;
        case N60_STAGE_PROTECTION: {
            const ProtCfg c = protCfg(p, rate);
            if (c.laHigh > 65536u) return N60_STATUS_BAD_ARGUMENT;
            break;
        }
        default: break;
    }
    return N60_STATUS_OK;
}

void systemSizes(const n60_stage_desc &s, double rate, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = 0;
    switch (s.kind) {
        case N60_STAGE_AMBIENT: perLane = up(sizeof(AmbLane)); shared = up(sizeof(AmbShared)); break;
        case N60_STAGE_SYMMETRY: shared = up(sizeof(SymShared)); break;
        case N60_STAGE_CROSSFEED: shared = up(sizeof(CfShared)); break;
        case N60_STAGE_CROSSTALK: shared = up(sizeof(CtShared)); break;
        case N60_STAGE_HEADPHONE: shared = up(sizeof(HpShared)); break;
        case N60_STAGE_PAUSE_GATE: shared = up(sizeof(GateShared)); break;
        case N60_STAGE_BASS_MGMT: perLane = up(sizeof(BassLane)); shared = up(sizeof(BassShared)); break;
        case N60_STAGE_MUTE: perLane = up(sizeof(MuteLane)); break;
        case N60_STAGE_FRAC_DELAY: perLane = up(sizeof(FdLane)); break;
        case N60_STAGE_ANC_INJECT: shared = up(sizeof(InjectShared)); break;
        case N60_STAGE_ANC_GUARD: shared = up(sizeof(GuardState)); break;
        case N60_STAGE_ANC_CAPTURE:
            perLane = up(size_t(s.capacityFrames) * sizeof(std::atomic<uint32_t>));
            shared = up(sizeof(CapShared));
            break;
        case N60_STAGE_PROTECTION: {
            const ProtCfg c = protCfg(s.params, rate);
            perLane = up(sizeof(ProtLane)) + protRingBytes(c);
            shared = protSharedBytes(c);
            break;
        }
        default: break;
    }
}

// ---- initialisation ---------------------------------------------------------------------

namespace {

void designInto(uint32_t type, double rate, double f, double db, double q, double *out) {
    double c[5];
    if (designBiquad(type, rate, f, db, q, c)) std::memcpy(out, c, sizeof c);
}

void guardArm(GuardState &g) {
    g.blockPos = g.blocksSeen = g.decPos = g.bandCount = g.growthRun = g.errRun = 0;
    g.outSum = g.refSum = g.decSum = 0.0;
    g.outHist[0] = g.outHist[1] = g.refHist[0] = g.refHist[1] = 0.0;
    for (double &b : g.bandSum) b = 0.0;
    for (GuardBand &b : g.bands) b.z1 = b.z2 = 0.0;
    g.framesSinceArm = 0;
    g.rampStart = g.gain;
    g.gainTarget = 1.0f;
    g.rampRemaining = g.gain == 1.0f ? 0u : g.rampFrames;
    g.muted.store(0, std::memory_order_release);
    g.trip.store(0, std::memory_order_release);
}

}  // namespace

void systemInit(SnapHeader *h, const StageRec &r) {
    float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    uint8_t *sh = sharedState(h, r);
    const uint32_t ramp = h->rampFrames;
    switch (r.kind) {
        case N60_STAGE_AMBIENT: {
            AmbShared *s = reinterpret_cast<AmbShared *>(sh);
            for (uint32_t k = 0; k < 3; ++k) designInto(k == 0 ? 1u : (k == 2 ? 2u : 0u), rate, p[1 + 3 * k], p[2 + 3 * k], p[3 + 3 * k], s->coef[k]);
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                AmbLane *a = reinterpret_cast<AmbLane *>(laneState(h, r, l));
                rampInit(a->g, static_cast<float>(db2lin(p[0])));
                a->seen = p[0];
            }
            break;
        }
        case N60_STAGE_SYMMETRY: {
            SymShared *s = reinterpret_cast<SymShared *>(sh);
            const double a = (static_cast<double>(p[0]) + 1.0) * kPi * 0.25;
            rampInit(s->gl, static_cast<float>(std::sqrt(2.0) * std::cos(a)));
            rampInit(s->gr, static_cast<float>(std::sqrt(2.0) * std::sin(a)));
            s->seen = p[0];
            break;
        }
        case N60_STAGE_CROSSFEED: {
            CfShared *s = reinterpret_cast<CfShared *>(sh);
            rampInit(s->a, p[0]);
            s->seen = p[0];
            break;
        }
        case N60_STAGE_CROSSTALK: {
            CtShared *s = reinterpret_cast<CtShared *>(sh);
            rampInit(s->amt, p[1]);
            s->seenAmt = p[1];
            s->seenHz = p[0];
            s->alpha = s->alphaTarget = 1.0 - std::exp(-2.0 * kPi * p[0] / rate);
            break;
        }
        case N60_STAGE_HEADPHONE: {
            HpShared *s = reinterpret_cast<HpShared *>(sh);
            s->headroom = static_cast<float>(db2lin(p[0]));
            rampInit(s->mix, 0.5f * p[1]);
            rampInit(s->gA, static_cast<float>(db2lin(p[5])));
            rampInit(s->gB, static_cast<float>(db2lin(p[6])));
            s->seenMix = p[1];
            s->seenGA = p[5];
            s->seenGB = p[6];
            s->polA = p[7] != 0.0f ? -1.0f : 1.0f;
            s->polB = p[8] != 0.0f ? -1.0f : 1.0f;
            s->nA = static_cast<uint32_t>(p[9]);
            s->nB = static_cast<uint32_t>(p[10]);
            const double f = p[4];
            s->alpha = 1.0 - std::exp(-2.0 * kPi * f / rate);
            const double d = std::llround(rate * (static_cast<double>(p[3]) / 343.0) * std::sin(static_cast<double>(p[2]) * kPi / 180.0));
            s->delay = static_cast<uint32_t>(std::min<double>(d, kHpRing - 1));
            for (uint32_t k = 0; k < s->nA + s->nB; ++k) {
                const float *q = p + kHpFixed + 4 * k;
                designInto(static_cast<uint32_t>(q[0]), rate, q[1], q[2], q[3], s->coef[k]);
            }
            break;
        }
        case N60_STAGE_PAUSE_GATE: {
            GateShared *s = reinterpret_cast<GateShared *>(sh);
            s->env = 0.0;
            s->gain = 1.0;
            s->open = 1;
            s->below = 0;
            s->thr = db2lin(p[0]);
            s->hystLin = db2lin(p[1]);
            s->holdFrames = static_cast<uint32_t>(std::lround(static_cast<double>(p[2]) * 0.001 * rate));
            s->atk = std::exp(-1.0 / (rate * 0.001));
            s->rel = std::exp(-1.0 / (rate * 0.010));
            s->cOut = std::exp(-1.0 / (rate * static_cast<double>(p[3]) * 0.001));
            s->cIn = std::exp(-1.0 / (rate * static_cast<double>(p[4]) * 0.001));
            break;
        }
        case N60_STAGE_BASS_MGMT: {
            BassShared *s = reinterpret_cast<BassShared *>(sh);
            designInto(4, rate, p[0], 0.0, kButterQ, s->hp);
            designInto(3, rate, p[0], 0.0, kButterQ, s->lp);
            designInto(3, rate, p[4], 0.0, kButterQ, s->lfe);
            BassLayout L;
            if (!parseBass(p, r.paramCount, L)) break;  // unreachable: validated at build
            s->nSubs = L.subs;
            s->norm = L.weighted ? 1.0 : 1.0 / static_cast<double>(L.subs);
            s->clearLfe = p[3] >= 0.0f ? 1u : 0u;
            for (uint32_t q = 0; q < L.subs; ++q) {
                const BassSubIdx &x = L.s[q];
                BassSub &b = s->sub[q];
                b.nEq = static_cast<uint32_t>(p[x.nEq]);
                b.lane = static_cast<uint32_t>(p[x.lane]);
                b.gainIdx = x.gain;
                b.polIdx = x.pol;
                b.eqIdx = x.eq;
                for (uint32_t k = 0; k < b.nEq; ++k) {
                    const float *e = p + x.eq + 4 * k;
                    designInto(static_cast<uint32_t>(e[0]), rate, e[1], e[2], e[3], b.eq[k]);
                    b.seenEq[k][0] = e[1];
                    b.seenEq[k][1] = e[2];
                    b.seenEq[k][2] = e[3];
                }
                if (static_cast<int32_t>(b.lane) == static_cast<int32_t>(p[3])) s->clearLfe = 0u;
                rampInit(b.g, static_cast<float>(db2lin(p[x.gain])));
                rampInit(b.pol, p[x.pol] != 0.0f ? -1.0f : 1.0f);
                b.seenG = p[x.gain];
                b.seenPol = p[x.pol];
            }
            rampInit(s->redirect, static_cast<float>(db2lin(p[1])));
            rampInit(s->lfeG, static_cast<float>(db2lin(p[5])));
            s->seenX = p[0];
            s->seenR = p[1];
            s->seenLfeHz = p[4];
            s->seenLfeG = p[5];
            s->lfeLane = static_cast<int32_t>(p[3]);
            break;
        }
        case N60_STAGE_FRAC_DELAY:
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                FdLane *d = reinterpret_cast<FdLane *>(laneState(h, r, l));
                fdDesign(static_cast<double>(p[0]) + static_cast<double>(p[1]), *d);
            }
            break;
        case N60_STAGE_MUTE:
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                MuteLane *m = reinterpret_cast<MuteLane *>(laneState(h, r, l));
                rampInit(m->g, p[0] != 0.0f ? 0.0f : 1.0f);
                m->seen = p[0];
            }
            break;
        case N60_STAGE_ANC_INJECT: {
            InjectShared *s = reinterpret_cast<InjectShared *>(sh);
            s->authorised = p[1] != 0.0f ? 1u : 0u;
            s->seen = p[2];
            s->seenRev = r.paramCount > 3 ? p[3] : 0.0f;
            s->holdWant = 1.0f;
            rampInit(s->hold, 1.0f);
            rampInit(s->g, 0.0f);
            if (s->authorised != 0) rampSet(s->g, static_cast<float>(db2lin(p[2])), ramp);  // fade in, no click
            break;
        }
        case N60_STAGE_ANC_CAPTURE: new (sh) CapShared{};
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                std::atomic<uint32_t> *ring = reinterpret_cast<std::atomic<uint32_t> *>(laneState(h, r, l));
                for (uint32_t i = 0; i < r.capacity; ++i) new (&ring[i]) std::atomic<uint32_t>(0);
            }
            break;
        case N60_STAGE_PROTECTION: {
            const ProtCfg c = protCfg(p, rate);
            ProtShared *s = reinterpret_cast<ProtShared *>(sh);
            s->gain = 1.0;
            s->cap = c.laHigh + 2;
            break;
        }
        case N60_STAGE_ANC_GUARD: {
            GuardState *g = new (sh) GuardState{};
            g->hasBaseline = p[10] != 0.0f ? 1u : 0u;
            g->growthBlocks = static_cast<uint32_t>(p[3]);
            g->errBlocks = static_cast<uint32_t>(p[6]);
            g->blockFrames = std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(rate * 0.010)));
            g->decimation = std::max<uint32_t>(1u, static_cast<uint32_t>(rate / 4000.0));
            g->rampFrames = std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(rate * static_cast<double>(p[9]))));
            g->errLane = static_cast<int32_t>(p[0]);
            g->refLane = static_cast<int32_t>(p[1]);
            g->ceiling = p[7];
            g->seenRev = p[11];
            g->growthRatio = fromDb10(p[2]);
            g->refAllow = fromDb10(p[4]);
            g->errRatio = fromDb10(p[5]);
            g->floorLin = fromDb10(p[8]);
            const double decRate = rate / g->decimation;
            for (uint32_t k = 0; k < N60_ANC_GUARD_BANDS; ++k) {
                g->baseline[k] = fromDb10(p[12 + k]);
                const double hz = 20.0 * std::pow(500.0 / 20.0, k / double(N60_ANC_GUARD_BANDS - 1));
                const double w0 = 2.0 * kPi * hz / decRate;
                const double alpha = std::sin(w0) / (2.0 * 4.3);
                const double a0 = 1.0 + alpha;
                g->bands[k].b0 = alpha / a0;
                g->bands[k].b2 = -alpha / a0;
                g->bands[k].a1 = -2.0 * std::cos(w0) / a0;
                g->bands[k].a2 = (1.0 - alpha) / a0;
            }
            g->gain = 1.0f;
            guardArm(*g);
            break;
        }
        default: break;
    }
}

// ---- live parameters and latency --------------------------------------------------------

n60_status validateSystemParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    bool live = false;
    switch (r.kind) {
        case N60_STAGE_BASS_MGMT: {
            // Live: crossover, redirect, LFE low-pass and gain, and per sub the gain, polarity and each section's
            // Hz / dB / Q (a section's type is fixed). Sub lanes and counts need a new snapshot (a rebuild).
            if (idx <= 1 || idx == 4 || idx == 5) {
                live = true;
                break;
            }
            BassLayout L;
            const float *bp = paramsOf(h, r);
            if (!parseBass(bp, r.paramCount, L)) return N60_STATUS_BAD_ARGUMENT;
            for (uint32_t q = 0; q < L.subs; ++q) {
                const BassSubIdx &x = L.s[q];
                if (idx == x.gain) {
                    if (!inR(value, -60.0, 24.0)) return N60_STATUS_BAD_ARGUMENT;
                    return N60_STATUS_OK;
                }
                if (idx == x.pol) {
                    if (value != 0.0f && value != 1.0f) return N60_STATUS_BAD_ARGUMENT;
                    return N60_STATUS_OK;
                }
                if (idx >= x.eq && idx < x.eq + 4u * static_cast<uint32_t>(bp[x.nEq])) {
                    float sec[4];
                    std::memcpy(sec, bp + x.eq + 4 * ((idx - x.eq) / 4), sizeof sec);
                    const uint32_t f = (idx - x.eq) % 4;
                    sec[f] = value;
                    if (!sectionOk(sec, h->sampleRate)) return N60_STATUS_BAD_ARGUMENT;
                    return f == 0 ? N60_STATUS_UNSUPPORTED : N60_STATUS_OK;
                }
            }
            if (L.ext != 0 && idx == L.ext) return N60_STATUS_UNSUPPORTED;  // mode and counts are topology
            if (idx == 2 || idx == 3 || idx == 8) return paramOk(r.kind, idx, value, bp, h->sampleRate, h->outputChannels) ? N60_STATUS_UNSUPPORTED : N60_STATUS_BAD_ARGUMENT;
            return N60_STATUS_UNSUPPORTED;  // lane indexes, section counts, extra-sub count
        }
        case N60_STAGE_AMBIENT: live = idx == 0; break;
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED: live = true; break;
        case N60_STAGE_CROSSTALK: live = true; break;
        case N60_STAGE_HEADPHONE: live = idx == 1 || idx == 5 || idx == 6; break;
        case N60_STAGE_PROTECTION: live = idx >= 1 && idx <= 3; break;
        case N60_STAGE_MUTE: live = true; break;
        case N60_STAGE_ANC_GUARD: live = idx == 11; break;
        case N60_STAGE_ANC_INJECT: live = idx == 2 || idx == 3; break;
        default: live = false; break;  // pause gate, capture, authorisation: new snapshot only
    }
    const float *p = paramsOf(h, r);
    if (!paramOk(r.kind, idx, value, p, h->sampleRate, h->outputChannels)) return N60_STATUS_BAD_ARGUMENT;
    return live ? N60_STATUS_OK : N60_STATUS_UNSUPPORTED;
}

uint32_t systemLatency(const SnapHeader *h, const StageRec &r) {
    if (r.kind == N60_STAGE_FRAC_DELAY) return static_cast<uint32_t>(paramsOf(h, r)[0]);
    if (r.kind != N60_STAGE_PROTECTION) return 0;
    return protCfg(paramsOf(h, r), h->sampleRate).latency;
}

// ---- run ----------------------------------------------------------------------------------

namespace {

void runAmbient(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    const double(*coef)[5] = reinterpret_cast<AmbShared *>(sharedState(h, r))->coef;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        AmbLane &a = *reinterpret_cast<AmbLane *>(laneState(h, r, l));
        if (p[0] != a.seen) {
            a.seen = p[0];
            rampSet(a.g, static_cast<float>(db2lin(p[0])), h->rampFrames);
        }
        float *buf = lanes[laneOf(r, l)];
        for (uint32_t i = 0; i < frames; ++i) {
            double x = buf[i];
            for (uint32_t b = 0; b < 3; ++b) x = bqRun(coef[b], a.z[b], x);
            buf[i] = static_cast<float>(x) * rampNext(a.g);
        }
        for (Bq &z : a.z) bqFlush(z);
    }
}

void runSymmetry(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    SymShared &s = *reinterpret_cast<SymShared *>(sharedState(h, r));
    const float pos = paramsOf(h, r)[0];
    if (pos != s.seen) {
        s.seen = pos;
        const double a = (static_cast<double>(pos) + 1.0) * kPi * 0.25;
        rampSet(s.gl, static_cast<float>(std::sqrt(2.0) * std::cos(a)), h->rampFrames);
        rampSet(s.gr, static_cast<float>(std::sqrt(2.0) * std::sin(a)), h->rampFrames);
    }
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    for (uint32_t i = 0; i < frames; ++i) {
        a[i] *= rampNext(s.gl);
        b[i] *= rampNext(s.gr);
    }
}

void runCrossfeed(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    CfShared &s = *reinterpret_cast<CfShared *>(sharedState(h, r));
    const float amt = paramsOf(h, r)[0];
    if (amt != s.seen) {
        s.seen = amt;
        rampSet(s.a, amt, h->rampFrames);
    }
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    for (uint32_t i = 0; i < frames; ++i) {
        const float c = rampNext(s.a);
        const float d = 1.0f - c;
        const float l = a[i], rr = b[i];
        a[i] = d * l + c * rr;
        b[i] = d * rr + c * l;
    }
}

void runCrosstalk(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    CtShared &s = *reinterpret_cast<CtShared *>(sharedState(h, r));
    const float *p = paramsOf(h, r);
    if (p[0] != s.seenHz) {
        s.seenHz = p[0];
        s.alphaTarget = 1.0 - std::exp(-2.0 * kPi * static_cast<double>(p[0]) / h->sampleRate);
        s.alphaLeft = h->rampFrames;  // ramped, not stepped: a step changes the filter output by d(alpha)*(x-s)
        s.alphaStep = (s.alphaTarget - s.alpha) / static_cast<double>(h->rampFrames);
    }
    if (p[1] != s.seenAmt) {
        s.seenAmt = p[1];
        rampSet(s.amt, p[1], h->rampFrames);
    }
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    for (uint32_t i = 0; i < frames; ++i) {
        if (s.alphaLeft != 0) {
            --s.alphaLeft;
            s.alpha = s.alphaTarget - s.alphaStep * static_cast<double>(s.alphaLeft);
        }
        const double l = a[i], rr = b[i];
        s.sL += s.alpha * (l - s.sL);
        s.sR += s.alpha * (rr - s.sR);
        const double amt = rampNext(s.amt);
        a[i] = static_cast<float>(l - amt * s.sR);
        b[i] = static_cast<float>(rr - amt * s.sL);
    }
    if (std::fabs(s.sL) < 1e-30) s.sL = 0.0;
    if (std::fabs(s.sR) < 1e-30) s.sR = 0.0;
}

void runHeadphone(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    HpShared &s = *reinterpret_cast<HpShared *>(sharedState(h, r));
    const float *p = paramsOf(h, r);
    if (p[1] != s.seenMix) {
        s.seenMix = p[1];
        rampSet(s.mix, 0.5f * p[1], h->rampFrames);
    }
    if (p[5] != s.seenGA) {
        s.seenGA = p[5];
        rampSet(s.gA, static_cast<float>(db2lin(p[5])), h->rampFrames);
    }
    if (p[6] != s.seenGB) {
        s.seenGB = p[6];
        rampSet(s.gB, static_cast<float>(db2lin(p[6])), h->rampFrames);
    }
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    uint32_t wp = s.wp;
    for (uint32_t i = 0; i < frames; ++i) {
        float xa = a[i], xb = b[i];
        xa = std::isfinite(xa) ? xa * s.headroom : 0.0f;
        xb = std::isfinite(xb) ? xb * s.headroom : 0.0f;
        s.ringA[wp] = xa;
        s.ringB[wp] = xb;
        const uint32_t rp = (wp + kHpRing - s.delay) & (kHpRing - 1);
        s.lowA += s.alpha * (static_cast<double>(xa) - s.lowA);
        s.lowB += s.alpha * (static_cast<double>(xb) - s.lowB);
        s.dlowA += s.alpha * (static_cast<double>(s.ringA[rp]) - s.dlowA);
        s.dlowB += s.alpha * (static_cast<double>(s.ringB[rp]) - s.dlowB);
        const double mix = rampNext(s.mix);
        double ya = (xa - s.lowA) + (1.0 - mix) * s.lowA + mix * s.dlowB;
        double yb = (xb - s.lowB) + (1.0 - mix) * s.lowB + mix * s.dlowA;
        for (uint32_t k = 0; k < s.nA; ++k) ya = bqRun(s.coef[k], s.zA[k], ya);
        for (uint32_t k = 0; k < s.nB; ++k) yb = bqRun(s.coef[s.nA + k], s.zB[k], yb);
        a[i] = static_cast<float>(ya) * rampNext(s.gA) * s.polA;
        b[i] = static_cast<float>(yb) * rampNext(s.gB) * s.polB;
        wp = (wp + 1) & (kHpRing - 1);
    }
    s.wp = wp;
    for (uint32_t k = 0; k < s.nA; ++k) bqFlush(s.zA[k]);
    for (uint32_t k = 0; k < s.nB; ++k) bqFlush(s.zB[k]);
    if (std::fabs(s.lowA) < 1e-30) s.lowA = 0.0;
    if (std::fabs(s.lowB) < 1e-30) s.lowB = 0.0;
    if (std::fabs(s.dlowA) < 1e-30) s.dlowA = 0.0;
    if (std::fabs(s.dlowB) < 1e-30) s.dlowB = 0.0;
}

void runGate(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    GateShared &s = *reinterpret_cast<GateShared *>(sharedState(h, r));
    float *ptr[kMaxLanes];
    for (uint32_t l = 0; l < r.laneCount; ++l) ptr[l] = lanes[laneOf(r, l)];
    double env = s.env;
    double gain = s.gain;
    for (uint32_t i = 0; i < frames; ++i) {
        double x = 0.0;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            if (!std::isfinite(ptr[l][i])) ptr[l][i] = 0.0f;  // a gate never passes NaN or Inf through
            x = std::max(x, std::fabs(static_cast<double>(ptr[l][i])));
        }
        const double coef = x > env ? s.atk : s.rel;
        env = x + coef * (env - x);
        if (s.open == 0) {
            if (env >= s.thr * s.hystLin) {
                s.open = 1;
                s.below = 0;
            }
        } else if (env < s.thr) {
            if (++s.below >= s.holdFrames) s.open = 0;
        } else {
            s.below = 0;
        }
        const double target = s.open != 0 ? 1.0 : 0.0;
        const double c = s.open != 0 ? s.cIn : s.cOut;
        gain = target + c * (gain - target);
        if (s.open == 0 && gain < 1e-9) gain = 0.0;
        if (s.open != 0 && gain > 1.0 - 1e-9) gain = 1.0;
        const float g = static_cast<float>(gain);
        for (uint32_t l = 0; l < r.laneCount; ++l) ptr[l][i] *= g;
    }
    s.env = (env < 1e-30 || !std::isfinite(env)) ? 0.0 : env;
    s.gain = std::isfinite(gain) ? gain : 1.0;
}

void runBass(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    BassShared &s = *reinterpret_cast<BassShared *>(sharedState(h, r));
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    const uint32_t ramp = h->rampFrames;
    float *ptr[kMaxLanes];
    BassLane *st[kMaxLanes];
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        ptr[l] = lanes[laneOf(r, l)];
        st[l] = reinterpret_cast<BassLane *>(laneState(h, r, l));
    }
    // A changed crossover runs as a second instance (new coefficients, state continued from the
    // old one) and the two are crossfaded over the ramp window; an edit that arrives while a
    // crossfade runs is picked up when it ends (seenX still differs).
    if (p[0] != s.seenX && s.xfX == 0) {
        s.seenX = p[0];
        designInto(4, rate, p[0], 0.0, kButterQ, s.hpN);
        designInto(3, rate, p[0], 0.0, kButterQ, s.lpN);
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            st[l]->nhp1 = st[l]->hp1; st[l]->nhp2 = st[l]->hp2;
            st[l]->nlp1 = st[l]->lp1; st[l]->nlp2 = st[l]->lp2;
        }
        s.xfX = ramp;
    }
    if (p[1] != s.seenR) {
        s.seenR = p[1];
        rampSet(s.redirect, static_cast<float>(db2lin(p[1])), ramp);
    }
    if (p[4] != s.seenLfeHz && s.xfLfe == 0) {
        s.seenLfeHz = p[4];
        designInto(3, rate, p[4], 0.0, kButterQ, s.lfeN);
        s.lfe1n = s.lfe1;
        s.lfe2n = s.lfe2;
        s.xfLfe = ramp;
    }
    if (p[5] != s.seenLfeG) {
        s.seenLfeG = p[5];
        rampSet(s.lfeG, static_cast<float>(db2lin(p[5])), ramp);
    }
    for (uint32_t q = 0; q < s.nSubs; ++q) {
        BassSub &b = s.sub[q];
        if (p[b.gainIdx] != b.seenG) {
            b.seenG = p[b.gainIdx];
            rampSet(b.g, static_cast<float>(db2lin(p[b.gainIdx])), ramp);
        }
        if (p[b.polIdx] != b.seenPol) {
            b.seenPol = p[b.polIdx];
            rampSet(b.pol, b.seenPol != 0.0f ? -1.0f : 1.0f, ramp);
        }
        for (uint32_t k = 0; k < b.nEq; ++k) {
            const float *e = p + b.eqIdx + 4 * k;
            if ((e[1] != b.seenEq[k][0] || e[2] != b.seenEq[k][1] || e[3] != b.seenEq[k][2]) && b.xf[k] == 0) {
                b.seenEq[k][0] = e[1];
                b.seenEq[k][1] = e[2];
                b.seenEq[k][2] = e[3];
                designInto(static_cast<uint32_t>(e[0]), rate, e[1], e[2], e[3], b.eqN[k]);
                if (ramp == 0) {
                    std::memcpy(b.eq[k], b.eqN[k], sizeof b.eq[k]);
                } else {
                    b.zN[k] = b.z[k];  // incoming section continues from the live one's state
                    b.xf[k] = ramp;
                }
            }
        }
    }
    float *sub[kBassMaxSubs];
    for (uint32_t q = 0; q < s.nSubs; ++q) sub[q] = lanes[s.sub[q].lane];
    float *lfe = s.lfeLane >= 0 ? lanes[static_cast<uint32_t>(s.lfeLane)] : nullptr;
    const bool clearLfe = lfe != nullptr && s.clearLfe != 0;
    const double invRamp = 1.0 / static_cast<double>(ramp);
    for (uint32_t i = 0; i < frames; ++i) {
        const bool xf = s.xfX != 0;
        const double t = xf ? static_cast<double>(ramp - s.xfX + 1) * invRamp : 0.0;
        double acc = 0.0;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            const double x = ptr[l][i];
            double hp = bqRun(s.hp, st[l]->hp2, bqRun(s.hp, st[l]->hp1, x));
            double lp = bqRun(s.lp, st[l]->lp2, bqRun(s.lp, st[l]->lp1, x));
            if (xf) {
                const double hn = bqRun(s.hpN, st[l]->nhp2, bqRun(s.hpN, st[l]->nhp1, x));
                const double ln = bqRun(s.lpN, st[l]->nlp2, bqRun(s.lpN, st[l]->nlp1, x));
                hp += t * (hn - hp);
                lp += t * (ln - lp);
            }
            acc += lp;
            ptr[l][i] = static_cast<float>(hp);
        }
        if (xf && --s.xfX == 0) {  // finished: the incoming instance becomes the live one
            std::memcpy(s.hp, s.hpN, sizeof s.hp);
            std::memcpy(s.lp, s.lpN, sizeof s.lp);
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                st[l]->hp1 = st[l]->nhp1; st[l]->hp2 = st[l]->nhp2;
                st[l]->lp1 = st[l]->nlp1; st[l]->lp2 = st[l]->nlp2;
            }
        }
        double v = acc * rampNext(s.redirect);
        if (lfe != nullptr) {
            double lf = bqRun(s.lfe, s.lfe2, bqRun(s.lfe, s.lfe1, static_cast<double>(lfe[i])));
            if (s.xfLfe != 0) {
                const double ln = bqRun(s.lfeN, s.lfe2n, bqRun(s.lfeN, s.lfe1n, static_cast<double>(lfe[i])));
                lf += (static_cast<double>(ramp - s.xfLfe + 1) * invRamp) * (ln - lf);
                if (--s.xfLfe == 0) {
                    std::memcpy(s.lfe, s.lfeN, sizeof s.lfe);
                    s.lfe1 = s.lfe1n;
                    s.lfe2 = s.lfe2n;
                }
            }
            v += lf * rampNext(s.lfeG);
        } else {
            if (s.xfLfe != 0 && --s.xfLfe == 0) std::memcpy(s.lfe, s.lfeN, sizeof s.lfe);  // no LFE lane: adopt the design
            rampNext(s.lfeG);
        }
        // One bass sum, then each sub's own gain, polarity and EQ. (The LFE lane may be a sub lane: it is read above.)
        const double vn = v * s.norm;
        for (uint32_t q = 0; q < s.nSubs; ++q) {
            BassSub &b = s.sub[q];
            double y = vn * (static_cast<double>(rampNext(b.g)) * static_cast<double>(rampNext(b.pol)));
            for (uint32_t k = 0; k < b.nEq; ++k) {
                double o = bqRun(b.eq[k], b.z[k], y);
                if (b.xf[k] != 0) {
                    const double on = bqRun(b.eqN[k], b.zN[k], y);
                    o += (static_cast<double>(ramp - b.xf[k] + 1) * invRamp) * (on - o);
                    if (--b.xf[k] == 0) {
                        std::memcpy(b.eq[k], b.eqN[k], sizeof b.eq[k]);
                        b.z[k] = b.zN[k];
                    }
                }
                y = o;
            }
            sub[q][i] = static_cast<float>(y);
        }
        if (clearLfe) lfe[i] = 0.0f;
    }
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        bqFlush(st[l]->hp1); bqFlush(st[l]->hp2); bqFlush(st[l]->lp1); bqFlush(st[l]->lp2);
        if (s.xfX != 0) {
            bqFlush(st[l]->nhp1); bqFlush(st[l]->nhp2); bqFlush(st[l]->nlp1); bqFlush(st[l]->nlp2);
        }
    }
    bqFlush(s.lfe1); bqFlush(s.lfe2);
    if (s.xfLfe != 0) { bqFlush(s.lfe1n); bqFlush(s.lfe2n); }
    for (uint32_t q = 0; q < s.nSubs; ++q) {
        for (uint32_t k = 0; k < s.sub[q].nEq; ++k) {
            bqFlush(s.sub[q].z[k]);
            if (s.sub[q].xf[k] != 0) bqFlush(s.sub[q].zN[k]);
        }
    }
}

void runFracDelay(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    constexpr uint32_t mask = kFdCapacity - 1u;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        FdLane &d = *reinterpret_cast<FdLane *>(laneState(h, r, l));
        float *buf = lanes[laneOf(r, l)];
        uint32_t wp = d.wp;
        for (uint32_t i = 0; i < frames; ++i) {
            d.ring[wp] = buf[i];
            const float x = d.ring[(wp + kFdCapacity - d.intFrames) & mask];
            float y = x;
            if (d.order != 0) {
                const uint32_t n = d.order;
                y = d.den[n] * x;
                for (uint32_t k = 1; k <= n; ++k) y += d.den[n - k] * d.inH[k - 1] - d.den[k] * d.outH[k - 1];
                for (uint32_t k = n - 1; k > 0; --k) {
                    d.inH[k] = d.inH[k - 1];
                    d.outH[k] = d.outH[k - 1];
                }
                d.inH[0] = x;
                d.outH[0] = y;
            }
            buf[i] = y;
            wp = (wp + 1u) & mask;
        }
        d.wp = wp;
    }
}

void runMute(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float muted = paramsOf(h, r)[0];
    const uint32_t ramp = std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(0.010 * h->sampleRate)));
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        MuteLane &m = *reinterpret_cast<MuteLane *>(laneState(h, r, l));
        if (muted != m.seen) {
            m.seen = muted;
            rampSet(m.g, muted != 0.0f ? 0.0f : 1.0f, ramp);
        }
        float *buf = lanes[laneOf(r, l)];
        if (m.g.remaining == 0 && m.g.cur == 1.0f) continue;
        for (uint32_t i = 0; i < frames; ++i) buf[i] *= rampNext(m.g);
    }
}

void runInject(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    InjectShared &s = *reinterpret_cast<InjectShared *>(sharedState(h, r));
    const float *p = paramsOf(h, r);
    float *src = lanes[static_cast<uint32_t>(p[0])];
    if (s.authorised != 0) {
        if (p[2] != s.seen) {
            s.seen = p[2];
            rampSet(s.g, static_cast<float>(db2lin(p[2])), h->rampFrames);
        }
        // A rebuild holds injection at zero. The hold ends only when the host posts a different
        // re-arm revision, which it does from the ANC authorisation path; the core never re-arms itself.
        const float rev = r.paramCount > 3 ? p[3] : 0.0f;
        if (rev != s.seenRev) {
            s.seenRev = rev;
            s.held = 0;
        }
        const float want = s.held != 0 ? 0.0f : 1.0f;
        if (want != s.holdWant) {
            s.holdWant = want;
            rampSet(s.hold, want, std::max<uint32_t>(1u, static_cast<uint32_t>(std::lround(0.010 * h->sampleRate))));
        }
        float *dst = lanes[r.laneA];
        for (uint32_t i = 0; i < frames; ++i) dst[i] += src[i] * rampNext(s.g) * rampNext(s.hold);
    }
    std::memset(src, 0, sizeof(float) * frames);  // the anti-noise source never reaches an output unrouted
}

void runCapture(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    if (paramsOf(h, r)[0] == 0.0f) return;  // not authorised: nothing is recorded
    CapShared &cs = *reinterpret_cast<CapShared *>(sharedState(h, r));
    const uint64_t w = cs.written.load(std::memory_order_relaxed);
    const uint32_t cap = r.capacity;
    cs.claimed.store(w + frames, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);  // claim is visible before any slot is overwritten
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        std::atomic<uint32_t> *ring = reinterpret_cast<std::atomic<uint32_t> *>(laneState(h, r, l));
        const float *buf = lanes[laneOf(r, l)];
        uint32_t pos = static_cast<uint32_t>(w % cap);
        for (uint32_t i = 0; i < frames; ++i) {
            uint32_t bits;
            std::memcpy(&bits, &buf[i], sizeof bits);
            ring[pos].store(bits, std::memory_order_relaxed);
            if (++pos == cap) pos = 0;
        }
    }
    cs.written.store(w + frames, std::memory_order_release);
}

// ---- protection ---------------------------------------------------------------------------

constexpr uint32_t kHbTaps = 65;
constexpr uint32_t kHbCenter = 32;
const float kHalfBand[kHbTaps] = {
    0.0f, -8.93785157026247e-06f, 0.0f, 8.8329163000838e-05f,
    0.0f, -0.000276868159748326f, 0.0f, 0.000625180796064176f,
    0.0f, -0.00120674594714632f, 0.0f, 0.00211986552642504f,
    0.0f, -0.00349032377425427f, 0.0f, 0.00547729190001286f,
    0.0f, -0.00828756826069623f, 0.0f, 0.0122089119142877f,
    0.0f, -0.0176878320018053f, 0.0f, 0.0255207897268248f,
    0.0f, -0.037383473403991f, 0.0f, 0.0576394659334684f,
    0.0f, -0.102387515243912f, 0.0f, 0.31705153844599f,
    0.499995782474098f,
    0.317051538445991f, 0.0f, -0.102387515243912f, 0.0f,
    0.0576394659334684f, 0.0f, -0.0373834734039911f, 0.0f,
    0.0255207897268248f, 0.0f, -0.0176878320018053f, 0.0f,
    0.0122089119142877f, 0.0f, -0.00828756826069622f, 0.0f,
    0.00547729190001286f, 0.0f, -0.00349032377425427f, 0.0f,
    0.00211986552642504f, 0.0f, -0.00120674594714632f, 0.0f,
    0.000625180796064177f, 0.0f, -0.000276868159748327f, 0.0f,
    8.83291630008379e-05f, 0.0f, -8.93785157026247e-06f, 0.0f};

inline float hbPush(Hb &f, float in) {
    const uint32_t newest = f.w;
    f.s[newest] = in;
    f.s[newest + kHbTaps] = in;
    const float *base = f.s + newest + kHbTaps;  // base[-tap] is the sample `tap` steps old
    float out = kHalfBand[kHbCenter] * base[-static_cast<int>(kHbCenter)];
    for (uint32_t tap = 1; tap < kHbTaps; tap += 2) out += kHalfBand[tap] * base[-static_cast<int>(tap)];
    f.w = newest + 1 == kHbTaps ? 0u : newest + 1;
    return out;
}
inline void interp2(Hb &f, float in, float out[2]) {
    out[0] = 2.0f * hbPush(f, in);
    out[1] = 2.0f * hbPush(f, 0.0f);
}

constexpr float kEps = 1.0e-12f;

void runProtection(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    ProtShared &sh = *reinterpret_cast<ProtShared *>(sharedState(h, r));
    if (sh.cfgValid == 0 || p[1] != sh.seenCeil || p[2] != sh.seenAtk || p[3] != sh.seenRel) {
        sh.cfg = protCfg(p, h->sampleRate);  // only the live parameters 1..3 can differ from the snapshot's
        sh.seenCeil = p[1];
        sh.seenAtk = p[2];
        sh.seenRel = p[3];
        sh.cfgValid = 1;
    }
    const ProtCfg c = sh.cfg;
    if (c.factor == 1 && !c.limiter) {
        // Bypass: no processing, no latency. Clear the "now" readbacks so a switched-off limiter
        // never reads as active; the peaks and max reduction stay as the reader left them.
        sh.guardActive.store(0u, std::memory_order_relaxed);
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            reinterpret_cast<ProtLane *>(laneState(h, r, l))->grNowBits.store(0u, std::memory_order_relaxed);
        }
        return;
    }
    float *val = protVal(&sh);
    uint64_t *idx = protIdx(&sh);
    const uint32_t n = r.laneCount;
    float *ptr[kMaxLanes];
    ProtLane *pl[kMaxLanes];
    float *ring[kMaxLanes];
    for (uint32_t l = 0; l < n; ++l) {
        ptr[l] = lanes[laneOf(r, l)];
        pl[l] = reinterpret_cast<ProtLane *>(laneState(h, r, l));
        ring[l] = protRing(pl[l]);
    }
    const uint32_t cap = sh.cap;
    const double attackStep = 1.0 / static_cast<double>(std::max(1u, c.atkHigh));
    float hi[kMaxLanes][4];
    float inPeak[kMaxLanes] = {};   // readback peaks for this block (merged into the lane atomics at the end)
    float outPeak[kMaxLanes] = {};
    double minGain = 1.0;

    auto limitHigh = [&](uint32_t k) {  // one high-rate sample across all lanes
        const uint64_t seq = sh.seq;
        const uint32_t w = static_cast<uint32_t>(seq % cap);
        float peak = 0.0f;
        for (uint32_t l = 0; l < n; ++l) {
            ring[l][w] = hi[l][k];
            const float a = std::fabs(hi[l][k]);
            peak = std::fmax(peak, a);
            inPeak[l] = std::fmax(inPeak[l], a);
        }
        while (sh.count > 0) {  // deque_push
            const uint32_t tail = (sh.head + sh.count - 1u) % cap;
            if (val[tail] > peak) break;
            sh.count -= 1u;
        }
        const uint32_t ins = (sh.head + sh.count) % cap;
        val[ins] = peak;
        idx[ins] = seq;
        sh.count += 1u;
        const uint64_t outSeq = seq >= c.laHigh ? seq - c.laHigh : 0u;
        while (sh.count > 0 && idx[sh.head] < outSeq) {  // deque_remove_expired
            sh.head = (sh.head + 1u) % cap;
            sh.count -= 1u;
        }
        const float window = sh.count > 0 ? val[sh.head] : 0.0f;
        const double target = window > c.ceilLin ? static_cast<double>(c.ceilLin) / std::fmax(window, kEps) : 1.0;
        if (target < sh.gain) {
            sh.gain = std::fmax(target, sh.gain - attackStep);
        } else {
            sh.gain = target + c.relCoef * (sh.gain - target);
        }
        minGain = std::fmin(minGain, sh.gain);
        float safety = 0.0f;
        for (uint32_t l = 0; l < n; ++l) {
            const float delayed = seq >= c.laHigh ? ring[l][static_cast<uint32_t>(outSeq % cap)] : 0.0f;
            hi[l][k] = static_cast<float>(delayed * sh.gain);
            safety = std::fmax(safety, std::fabs(hi[l][k]));
        }
        if (safety > c.ceilLin) {
            const float sg = c.ceilLin / std::fmax(safety, kEps);
            for (uint32_t l = 0; l < n; ++l) hi[l][k] *= sg;
        }
        for (uint32_t l = 0; l < n; ++l) outPeak[l] = std::fmax(outPeak[l], std::fabs(hi[l][k]));
        sh.seq = seq + 1u;
    };

    for (uint32_t l = 0; l < n; ++l) {  // non-finite input must never reach the filter or window state
        for (uint32_t i = 0; i < frames; ++i) {
            if (!(std::fabs(ptr[l][i]) <= 3.0e38f)) ptr[l][i] = 0.0f;
        }
    }
    for (uint32_t i = 0; i < frames; ++i) {
        if (c.factor == 1) {
            for (uint32_t l = 0; l < n; ++l) hi[l][0] = ptr[l][i];
            limitHigh(0);
            for (uint32_t l = 0; l < n; ++l) ptr[l][i] = hi[l][0];
            continue;
        }
        float l1[kMaxLanes][2];
        for (uint32_t l = 0; l < n; ++l) {
            interp2(pl[l]->up1, ptr[l][i], l1[l]);
            if (c.factor == 2) {
                hi[l][0] = l1[l][0];
                hi[l][1] = l1[l][1];
            } else {
                for (uint32_t k = 0; k < 2; ++k) {
                    float pair[2];
                    interp2(pl[l]->up2, l1[l][k], pair);
                    hi[l][2 * k] = pair[0];
                    hi[l][2 * k + 1] = pair[1];
                }
            }
        }
        if (c.factor == 2) {
            for (uint32_t k = 0; k < 2; ++k) limitHigh(k);
            for (uint32_t k = 0; k < 2; ++k) {
                const bool emit = sh.ph1 == 0u;
                sh.ph1 ^= 1u;
                for (uint32_t l = 0; l < n; ++l) {
                    const float f = hbPush(pl[l]->dn1, hi[l][k]);
                    if (emit) ptr[l][i] = f;
                }
            }
            continue;
        }
        for (uint32_t k = 0; k < 4; ++k) limitHigh(k);
        float down[kMaxLanes][2];
        uint32_t emitted = 0;
        for (uint32_t k = 0; k < 4; ++k) {
            const bool emit = sh.ph2 == 0u;
            sh.ph2 ^= 1u;
            for (uint32_t l = 0; l < n; ++l) {
                const float f = hbPush(pl[l]->dn2, hi[l][k]);
                if (emit && emitted < 2u) down[l][emitted] = f;
            }
            if (emit) emitted += 1u;
        }
        for (uint32_t k = 0; k < 2; ++k) {
            const bool emit = sh.ph1 == 0u;
            sh.ph1 ^= 1u;
            for (uint32_t l = 0; l < n; ++l) {
                const float f = hbPush(pl[l]->dn1, down[l][k]);
                if (emit) ptr[l][i] = f;
            }
        }
    }

    // Readbacks for the control thread (relaxed atomics; peaks reset by the reader).
    const float grMax = minGain < 1.0 ? static_cast<float>(-20.0 * std::log10(std::fmax(minGain, 1e-12))) : 0.0f;
    const float grNow = sh.gain < 1.0 ? static_cast<float>(-20.0 * std::log10(std::fmax(sh.gain, 1e-12))) : 0.0f;
    sh.guardActive.store(c.limiter && c.factor > 1 ? 1u : 0u, std::memory_order_relaxed);
    for (uint32_t l = 0; l < n; ++l) {
        atomicMaxFloat(pl[l]->inTpBits, inPeak[l]);
        atomicMaxFloat(pl[l]->outTpBits, outPeak[l]);
        atomicMaxFloat(pl[l]->grMaxBits, grMax);
        pl[l]->grNowBits.store(floatToBits(grNow), std::memory_order_relaxed);
    }
}

// ---- howl guard -----------------------------------------------------------------------------

void guardTrip(GuardState &g, uint32_t reason) {
    if (g.trip.load(std::memory_order_relaxed) != 0) return;
    g.rampStart = g.gain;
    g.gainTarget = 0.0f;
    g.rampRemaining = g.gain == 0.0f ? 0u : g.rampFrames;
    if (g.gain == 0.0f) g.muted.store(1, std::memory_order_release);
    g.tripFrame.store(g.framesSinceArm, std::memory_order_relaxed);
    g.tripCount.fetch_add(1, std::memory_order_relaxed);
    g.trip.store(reason, std::memory_order_release);
}

float guardGain(GuardState &g, float x) {
    if (g.rampRemaining > 0) {
        --g.rampRemaining;
        const float left = static_cast<float>(g.rampRemaining) / static_cast<float>(g.rampFrames);
        g.gain = g.gainTarget + (g.rampStart - g.gainTarget) * left;
        if (g.rampRemaining == 0 && g.gain == 0.0f) g.muted.store(1, std::memory_order_release);
    }
    return x * g.gain;
}

void guardEndBlock(GuardState &g) {
    const double out = g.outSum / g.blockFrames;
    const double ref = g.refSum / g.blockFrames;
    const bool active = out > g.floorLin;
    if (g.blocksSeen >= 2) {
        const double outGrowth = out / std::max(g.outHist[1], g.floorLin);
        const double refGrowth = std::clamp(ref / std::max(g.refHist[1], g.floorLin), 1.0, g.refAllow);
        g.growthRun = (active && outGrowth > g.growthRatio * refGrowth) ? g.growthRun + 1 : 0;
        if (g.growthRun >= g.growthBlocks) guardTrip(g, 1);
    }
    if (g.hasBaseline != 0 && g.bandCount > 0) {
        bool risen = false;
        for (uint32_t k = 0; k < N60_ANC_GUARD_BANDS; ++k) {
            risen |= g.bandSum[k] / g.bandCount > g.baseline[k] * g.errRatio;
        }
        g.errRun = (active && risen) ? g.errRun + 1 : 0;
        if (g.errRun >= g.errBlocks) guardTrip(g, 2);
    }
    g.outHist[1] = g.outHist[0];
    g.outHist[0] = out;
    g.refHist[1] = g.refHist[0];
    g.refHist[0] = ref;
    g.blocksSeen = std::min<uint32_t>(g.blocksSeen + 1, 2);
    g.outSum = g.refSum = 0.0;
    for (double &b : g.bandSum) b = 0.0;
    g.bandCount = 0;
    g.blockPos = 0;
}

void runGuard(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    GuardState &g = *reinterpret_cast<GuardState *>(sharedState(h, r));
    const float rev = paramsOf(h, r)[11];
    if (rev != g.seenRev) {
        g.seenRev = rev;
        guardArm(g);
    }
    float *anti = lanes[r.laneA];
    const float *ref = g.refLane >= 0 ? lanes[static_cast<uint32_t>(g.refLane)] : nullptr;
    const float *err = g.errLane >= 0 ? lanes[static_cast<uint32_t>(g.errLane)] : nullptr;
    const bool useError = g.hasBaseline != 0 && err != nullptr;
    for (uint32_t i = 0; i < frames; ++i) {
        float x = anti[i];
        if (!std::isfinite(x)) {
            guardTrip(g, 3);
            x = 0.0f;
        } else if (std::fabs(x) > g.ceiling) {
            guardTrip(g, 4);
            x = std::copysign(g.ceiling, x);
        }
        g.outSum += static_cast<double>(x) * x;
        if (ref != nullptr) {
            const float rf = ref[i];
            if (std::isfinite(rf)) {
                g.refSum += static_cast<double>(rf) * rf;
            } else {
                guardTrip(g, 3);
            }
        }
        if (useError) {
            float e = err[i];
            if (!std::isfinite(e)) {
                guardTrip(g, 3);
                e = 0.0f;
            }
            g.decSum += e;
            if (++g.decPos == g.decimation) {
                const double sample = g.decSum / g.decimation;
                for (uint32_t k = 0; k < N60_ANC_GUARD_BANDS; ++k) {
                    GuardBand &b = g.bands[k];
                    const double y = b.b0 * sample + b.z1;
                    b.z1 = -b.a1 * y + b.z2;
                    b.z2 = b.b2 * sample - b.a2 * y;
                    if (b.z1 > -1e-200 && b.z1 < 1e-200) b.z1 = 0;
                    if (b.z2 > -1e-200 && b.z2 < 1e-200) b.z2 = 0;
                    g.bandSum[k] += y * y;
                }
                ++g.bandCount;
                g.decPos = 0;
                g.decSum = 0.0;
            }
        }
        anti[i] = guardGain(g, x);
        ++g.framesSinceArm;
        if (++g.blockPos == g.blockFrames) guardEndBlock(g);
    }
    g.processed.fetch_add(frames, std::memory_order_relaxed);
}

}  // namespace

void runSystem(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    switch (r.kind) {
        case N60_STAGE_AMBIENT: runAmbient(h, r, lanes, frames); break;
        case N60_STAGE_SYMMETRY: runSymmetry(h, r, lanes, frames); break;
        case N60_STAGE_CROSSFEED: runCrossfeed(h, r, lanes, frames); break;
        case N60_STAGE_CROSSTALK: runCrosstalk(h, r, lanes, frames); break;
        case N60_STAGE_HEADPHONE: runHeadphone(h, r, lanes, frames); break;
        case N60_STAGE_PAUSE_GATE: runGate(h, r, lanes, frames); break;
        case N60_STAGE_BASS_MGMT: runBass(h, r, lanes, frames); break;
        case N60_STAGE_MUTE: runMute(h, r, lanes, frames); break;
        case N60_STAGE_FRAC_DELAY: runFracDelay(h, r, lanes, frames); break;
        case N60_STAGE_ANC_INJECT: runInject(h, r, lanes, frames); break;
        case N60_STAGE_ANC_CAPTURE: runCapture(h, r, lanes, frames); break;
        case N60_STAGE_PROTECTION: runProtection(h, r, lanes, frames); break;
        case N60_STAGE_ANC_GUARD: runGuard(h, r, lanes, frames); break;
        default: break;
    }
}

// ---- rebuild support ---------------------------------------------------------------------------

uint32_t systemRebuildMute(SnapHeader *h, bool silentNow) {
    uint32_t n = 0;
    StageRec *table = stages(h);
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        if (table[i].kind != N60_STAGE_ANC_INJECT) continue;
        InjectShared &s = *reinterpret_cast<InjectShared *>(sharedState(h, table[i]));
        const float *p = paramsOf(h, table[i]);
        s.held = 1;
        // A revision already in the snapshot (or posted during the rebuild) is not a re-arm.
        s.seenRev = table[i].paramCount > 3 ? p[3] : 0.0f;
        if (silentNow) {  // the incoming instance has never been audible: start it at zero
            rampInit(s.hold, 0.0f);
            s.holdWant = 0.0f;
        }
        ++n;
    }
    return n;
}

// ---- control-thread reads ---------------------------------------------------------------------

bool readProtectionDynamics(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out) {
    if (r.kind != N60_STAGE_PROTECTION) return false;
    uint32_t k = 0;
    for (; k < r.laneCount; ++k) {
        if (laneOf(r, k) == lane) break;
    }
    if (k == r.laneCount) return false;
    ProtShared &sh = *reinterpret_cast<ProtShared *>(sharedState(h, r));
    ProtLane &pl = *reinterpret_cast<ProtLane *>(laneState(h, r, k));
    out->kind = r.kind;
    out->grMaxDb = bitsToFloat(pl.grMaxBits.exchange(0, std::memory_order_relaxed));
    out->grNowDb = bitsToFloat(pl.grNowBits.load(std::memory_order_relaxed));
    out->inTruePeak = bitsToFloat(pl.inTpBits.exchange(0, std::memory_order_relaxed));
    out->outTruePeak = bitsToFloat(pl.outTpBits.exchange(0, std::memory_order_relaxed));
    out->guardActive = sh.guardActive.load(std::memory_order_relaxed);
    out->reserved = 0;
    return true;
}

bool readGuardStatus(const SnapHeader *h, uint32_t stageId, n60_guard_status *out) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_ANC_GUARD) return false;
    const GuardState &g = *reinterpret_cast<const GuardState *>(bytes(h) + r->sharedOff);
    out->trip = g.trip.load(std::memory_order_acquire);
    out->muted = g.muted.load(std::memory_order_acquire);
    out->tripFrame = g.tripFrame.load(std::memory_order_relaxed);
    out->processedFrames = g.processed.load(std::memory_order_relaxed);
    out->tripCount = g.tripCount.load(std::memory_order_relaxed);
    return true;
}

n60_status readCapture(const SnapHeader *h, uint32_t stageId, uint32_t lane, uint64_t startSample, float *dst,
                       uint32_t frames, uint64_t *written) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_ANC_CAPTURE || lane >= h->outputChannels) return N60_STATUS_BAD_ARGUMENT;
    uint32_t k = 0;
    for (; k < r->laneCount; ++k) {
        if (laneOf(*r, k) == lane) break;
    }
    if (k == r->laneCount) return N60_STATUS_BAD_ARGUMENT;
    const CapShared &cs = *reinterpret_cast<const CapShared *>(bytes(h) + r->sharedOff);
    const uint64_t w = cs.written.load(std::memory_order_acquire);
    if (written != nullptr) *written = w;
    if (frames == 0) return N60_STATUS_OK;
    const uint32_t cap = r->capacity;
    if (startSample + frames > w || w - startSample > cap) return N60_STATUS_UNSUPPORTED;
    const std::atomic<uint32_t> *ring =
        reinterpret_cast<const std::atomic<uint32_t> *>(bytes(h) + r->stateOff + size_t(k) * r->stateStride);
    for (uint32_t i = 0; i < frames; ++i) {
        const uint32_t bits = ring[(startSample + i) % cap].load(std::memory_order_relaxed);
        std::memcpy(&dst[i], &bits, sizeof bits);
    }
    std::atomic_thread_fence(std::memory_order_acquire);
    const uint64_t w2 = cs.claimed.load(std::memory_order_relaxed);
    if (w2 - startSample > cap) return N60_STATUS_UNSUPPORTED;  // overwritten while copying
    return N60_STATUS_OK;
}

}  // namespace n60
