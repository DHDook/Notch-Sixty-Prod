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
//    oversampling delay (32 frames at 2x, 48 at 4x) plus ceil(look-ahead high samples / factor). It applies whenever the
//    factor is above 1, also with the limiter and the clipper off (E6 S12f); only factor 1 with both off is a bypass.
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
#include <bit>
#include <cmath>
#include <cstring>
#include <new>

#include "n60/xover.h"
#include "simd/simd.hpp"

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
    // E20 S3: denormals are flushed in hardware (platform/fpenv.hpp); only a non-finite burst needs healing.
    if (!std::isfinite(s.z1)) s.z1 = 0.0;
    if (!std::isfinite(s.z2)) s.z2 = 0.0;
}

constexpr double kButterQ = 0.70710678118654752440;

// ---- lane rules --------------------------------------------------------------------

enum class Lanes { MaskOnly, MaskOrOne, Pair, PairOrMask, Single };

bool lanesOk(const n60_stage_desc &s, uint32_t outCh, Lanes rule) {
    const bool maskInRange = outCh >= 64 || (s.laneMask >> outCh) == 0;
    switch (rule) {
        case Lanes::MaskOnly: return s.laneMask != 0 && s.laneA == 0 && s.laneB == 0 && maskInRange;
        case Lanes::MaskOrOne:
            if (s.laneMask != 0) return s.laneA == 0 && s.laneB == 0 && maskInRange;
            return s.laneB == 0 && (s.laneA == N60_LANE_ALL || s.laneA < outCh);
        case Lanes::Pair: return s.laneMask == 0 && s.laneA < outCh && s.laneB < outCh && s.laneA != s.laneB;
        case Lanes::PairOrMask:
            if (s.laneMask != 0) return s.laneA == 0 && s.laneB == 0 && maskInRange;
            return s.laneA < outCh && s.laneB < outCh && s.laneA != s.laneB;
        case Lanes::Single: return s.laneMask == 0 && s.laneB == 0 && s.laneA < outCh;
    }
    return false;
}

inline bool isAnalyserTap(uint32_t kind) {
    return kind == N60_STAGE_ANALYSER_TAP_EQ || kind == N60_STAGE_ANALYSER_TAP_DYN;
}

Lanes ruleOf(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_BASS_MGMT:
        case N60_STAGE_PAUSE_GATE:
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
        case N60_STAGE_ANC_CAPTURE: return Lanes::MaskOnly;
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED:
        case N60_STAGE_CROSSTALK:
        case N60_STAGE_STEREO_CROSSOVER:
        case N60_STAGE_HEADPHONE: return Lanes::Pair;
        case N60_STAGE_DELTA_CAPTURE:
        case N60_STAGE_DELTA_SUBTRACT: return Lanes::PairOrMask;  // ABI v31: a lane pair, or a lane mask
        case N60_STAGE_ANC_GUARD:
        case N60_STAGE_ANC_INJECT: return Lanes::Single;
        default: return Lanes::MaskOrOne;
    }
}

// ---- parameter layouts ---------------------------------------------------------------

constexpr uint32_t kHpFixed = 11;
constexpr uint32_t kAmbMaxTrailer = 17;                // ABI v32: live peaking sections after the three bands
constexpr uint32_t kAmbMaxSec = 3 + kAmbMaxTrailer;
constexpr double kAmbMinDb = -8.0, kAmbMaxDb = 0.0;    // trailer sections cut only
constexpr double kAmbMinQ = 0.3, kAmbMaxQ = 20.0;
constexpr uint32_t kProtParamsV12 = 18;
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
    uint32_t spec;            // ABI v17: index of the 4-value filter-spec trailer, 0 when absent
    bool weighted;
    BassSubIdx s[kBassMaxSubs];
};
bool parseBass(const float *p, uint32_t have, BassLayout &L) {
    if (have < kBassFixed || !isInt(p[8]) || p[8] < 0.0f || p[8] > static_cast<float>(kBassMaxEq)) return false;
    L.subs = 1;
    L.ext = 0;
    L.spec = 0;
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
        if (have == pos + 4) {  // ABI v17: filter-spec trailer (needs the extension word)
            L.spec = pos;
            pos += 4;
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
        case N60_STAGE_AMBIENT:  // ABI v32: 10, or 11 + 3 n with the section trailer (n 0..17)
            if (have == 10) return 10;
            return have >= 11 && isInt(p[10]) && p[10] >= 0.0f && p[10] <= static_cast<float>(kAmbMaxTrailer)
                       ? 11u + 3u * static_cast<uint32_t>(p[10])
                       : 0u;
        case N60_STAGE_SYMMETRY: return 1;
        case N60_STAGE_CROSSFEED: return 1;
        case N60_STAGE_CROSSTALK: return 2;
        case N60_STAGE_HEADPHONE:
            return have >= kHpFixed && isInt(p[9]) && isInt(p[10]) && p[9] >= 0.0f && p[9] <= 16.0f && p[10] >= 0.0f &&
                           p[10] <= 16.0f
                       ? kHpFixed + 4u * (static_cast<uint32_t>(p[9]) + static_cast<uint32_t>(p[10]))
                       : 0u;
        case N60_STAGE_PAUSE_GATE: return 5;
        case N60_STAGE_PROTECTION: return have == 7 ? 7u : (have == kProtParamsV12 ? kProtParamsV12 : 0u);
        case N60_STAGE_STEREO_CROSSOVER: return have == 8 || have == 12 ? have : 0u;  // ABI v19: 8, or 12 with a filter-spec trailer
        case N60_STAGE_MUTE: return 1;
        case N60_STAGE_DELTA_CAPTURE:
        case N60_STAGE_DELTA_SUBTRACT: return 1;
        case N60_STAGE_EXTERNAL: return 1;
        case N60_STAGE_FRAC_DELAY: return 2;
        case N60_STAGE_ANC_GUARD: return kGuardParams;
        case N60_STAGE_ANC_INJECT: return have == 4 ? 4u : 3u;
        case N60_STAGE_ANC_CAPTURE:
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN: return 1;
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
    // ABI v12: soft clipper (per oversampled sample, before the limiter) and gain rider (per frame).
    bool clipper;
    uint32_t curve;
    float drive, threshold, knee, comp, trimPos, trimNeg;
    bool riderCfg;  // the stage carries the v12 parameters: the rider state tracks even while it is off
    bool rider;
    float riderTarget, riderMax;
    double riderMeasCoef, riderRespCoef;  // double: float cannot hold 1 - 9e-8 (30 s at 384 kHz)
};

uint32_t osLatency(uint32_t factor) { return factor == 2 ? 32u : (factor == 4 ? 48u : 0u); }

inline float dbToLin(float db) { return std::pow(10.0f, db / 20.0f); }

// n is the stage's parameter count: 7 (limiter only) or 18 (ABI v12).
ProtCfg protCfg(const float *p, double rate, uint32_t n) {
    ProtCfg c{};
    c.limiter = p[0] != 0.0f;
    const bool tp = p[5] != 0.0f;
    c.clipper = n >= kProtParamsV12 && p[7] != 0.0f;
    // The user's oversampling factor applies whenever it is above 1, as in the kernel: with the limiter and the clipper
    // both off the stage is a pure half-band round trip (E6 S12f, ABI v27), and a factor of 1 with both off is a bypass.
    c.factor = (c.limiter && tp) ? 4u : static_cast<uint32_t>(p[6]);
    const double highRate = rate * static_cast<double>(c.factor);
    c.ceilLin = std::pow(10.0f, p[1] / 20.0f);
    c.laHigh = c.limiter ? static_cast<uint32_t>(std::ceil(static_cast<double>(p[4]) * 0.001 * highRate)) : 0u;
    c.atkHigh = c.limiter ? static_cast<uint32_t>(std::fmax(1.0, std::ceil(static_cast<double>(p[2]) * 0.001 * highRate))) : 1u;
    c.relCoef = c.limiter ? std::exp(-1.0 / std::fmax(1.0, static_cast<double>(p[3]) * 0.001 * highRate)) : 0.0;
    const uint32_t laFrames = c.laHigh == 0 ? 0u : (c.laHigh + c.factor - 1u) / c.factor;
    c.latency = osLatency(c.factor) + laFrames;
    if (c.clipper) {
        c.drive = dbToLin(p[8]);
        c.threshold = dbToLin(p[9]);
        c.knee = p[10];
        c.curve = static_cast<uint32_t>(p[11]);
        c.comp = p[12] != 0.0f ? 1.0f / c.drive : 1.0f;
        c.trimPos = dbToLin(p[13]);
        c.trimNeg = dbToLin(-p[13]);
    }
    if (n >= kProtParamsV12) {
        c.riderCfg = true;
        c.rider = p[14] != 0.0f;
        c.riderTarget = p[15];
        c.riderMax = p[16];
        const float seconds = p[17] == 0.0f ? 3.0f : (p[17] == 2.0f ? 30.0f : 10.0f);
        c.riderMeasCoef = std::exp(-1.0 / std::fmax(1.0, static_cast<double>(rate)));
        c.riderRespCoef = std::exp(-1.0 / std::fmax(1.0, static_cast<double>(seconds) * static_cast<double>(rate)));
    }
    return c;
}

// ---- state layouts ------------------------------------------------------------------

struct AmbLane {
    Ramp g;
    float seen;
    float pad;
    Bq z[kAmbMaxSec];
    Bq zN[kAmbMaxSec];  // incoming section during a coefficient crossfade
};
struct AmbShared {
    double coef[kAmbMaxSec][5];
    double coefN[kAmbMaxSec][5];
    float seen[kAmbMaxSec][3];  // Hz, dB, Q the current design was made from (or is fading to)
    uint32_t xf[kAmbMaxSec];    // frames left in a section's coefficient crossfade
    uint32_t n;                 // sections in use: 3 + trailer count
    uint32_t pad;
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
// HEADPHONE (E13 S3): headroom, crossfeed amount, angle, radius, low-pass, gains and every section's type / Hz / dB / Q are
// live. Sections are indexed 0..nA-1 (A) then nA..nA+nB-1 (B). A changed section crossfades old and new coefficients over
// the ramp window; a changed angle or radius crossfades between the old and new ring tap; the low-pass coefficient ramps.
struct HpShared {
    Ramp mix, gA, gB, hr;
    float seenMix, seenGA, seenGB, seenHr;
    float seenAngle, seenRadius, seenLp, pad0;
    float polA, polB;
    uint32_t delay, delayN, delayLeft, nA, nB, wp;
    double alpha, alphaTarget, alphaStep, lowA, lowB, dlowA, dlowB;
    uint32_t alphaLeft, pad1;
    float ringA[kHpRing], ringB[kHpRing];
    Bq z[32], zN[32];
    float seenSec[32][4];
    uint32_t xf[32];
    double coef[32][5], coefN[32][5];
};
struct GateShared {
    double env, gain;
    uint32_t open, below, holdFrames, pad;
    double thr, hystLin, atk, rel, cOut, cIn;
};
constexpr uint32_t kBassSplitSec = N60_XOVER_MAX_SECTIONS;
struct BassLane {
    Bq hp[kBassSplitSec], lp[kBassSplitSec];
    Bq nhp[kBassSplitSec], nlp[kBassSplitSec];  // incoming crossover during a coefficient crossfade
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
    double hp[kBassSplitSec][5], lp[kBassSplitSec][5], lfe[5];  // split sections (default: LR4 = two identical Butterworth biquads)
    Bq lfe1, lfe2;
    double hpN[kBassSplitSec][5], lpN[kBassSplitSec][5], lfeN[5];  // incoming coefficients during a crossfade
    n60_xover_prototype hpProto, lpProto;  // ABI v17 filter spec (general == 1)
    uint32_t nHp, nLp, general, pad2;
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
    double riderSustained, riderAtten;       // ABI v12: sustained limiter reduction and rider attenuation (dB)
    float seenCeil, seenAtk, seenRel, pad2;  // protCfg inputs the cached cfg was derived from
    std::atomic<uint32_t> guardActive;       // ABI v8: 1 when the limiter runs with oversampling
    uint32_t pad3;
    ProtCfg cfg;                              // cached: pow/exp are not redone every block
    // followed by float val[cap]; uint64_t idx[cap]
};

constexpr uint32_t kXoSections = 4;
struct XoLane {  // a pair stage has one state slot: the mains high-pass sections of both lanes
    Bq hp[2][kXoSections];
};
struct XoShared {
    double hp[kXoSections][5];
    double lp[kXoSections][5];
    double ap[5];
    Bq lpState[kXoSections];
    Bq apState;
    uint32_t nHp, nLp, mode;
    uint32_t align, invert;
    float gain, pad;
};

// ABI v30 delta audition. CAPTURE keeps the last `cap` input frames of each lane; `wp` is the next write slot of both.
// ABI v31: n lanes (a pair, or the lanes of a mask in ascending order). delay[k] is the whole-frame delay of lane k's
// aligned reference; frac[k] is non-zero when the lane's protection look-ahead leaves a fraction of a frame (the reference
// is then read through a windowed-sinc interpolator of kDeltaTaps taps).
constexpr uint32_t kDeltaTaps = 32;
struct DeltaShared {
    uint32_t cap, wp, n, keepNeed;
    uint32_t delay[N60_GRAPH_MAX_CHANNELS];
    float frac[N60_GRAPH_MAX_CHANNELS];
    // followed by float ring[n][cap], then float taps[n][kDeltaTaps]
};
struct DeltaTie {  // SUBTRACT: the index of its CAPTURE in the stage table, bound when the snapshot is built
    uint32_t capture, bound;
};
inline float *deltaRing(DeltaShared *d, uint32_t k) { return reinterpret_cast<float *>(d + 1) + size_t(k) * d->cap; }
inline float *deltaTaps(DeltaShared *d, uint32_t k) {
    return reinterpret_cast<float *>(d + 1) + size_t(d->n) * d->cap + size_t(k) * kDeltaTaps;
}
inline uint32_t deltaLaneCount(const n60_stage_desc &s) {
    return s.laneMask != 0 ? static_cast<uint32_t>(std::popcount(s.laneMask)) : 2u;
}
inline uint32_t deltaLaneCount(const StageRec &r) { return r.laneMask != 0 ? r.laneCount : 2u; }
inline uint32_t deltaLane(const StageRec &r, uint32_t k) {
    return r.laneMask != 0 ? laneOf(r, k) : (k == 0 ? r.laneA : r.laneB);
}

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

bool isSystemKind(uint32_t kind) N60_RT_NONBLOCKING {
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
        case N60_STAGE_STEREO_CROSSOVER:
        case N60_STAGE_DELTA_CAPTURE:
        case N60_STAGE_DELTA_SUBTRACT:
        case N60_STAGE_EXTERNAL:
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
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
        case N60_STAGE_AMBIENT: {
            if (i == 0) return inR(v, -60.0, 24.0);
            if (i == 10) return isInt(v) && v >= 0.0f && v <= static_cast<float>(kAmbMaxTrailer);
            // A band or trailer section field: the section as it would be with this value must design.
            const uint32_t sec = i <= 9 ? (i - 1) / 3 : 3 + (i - 11) / 3;
            const uint32_t base = i <= 9 ? 1 + 3 * sec : 11 + 3 * (sec - 3);
            double t[3];
            for (uint32_t f = 0; f < 3; ++f) t[f] = base + f == i ? static_cast<double>(v) : static_cast<double>(p[base + f]);
            double c[5];
            if (!designBiquad(i <= 9 ? (sec == 0 ? 1u : (sec == 2 ? 2u : 0u)) : 0u, rate, t[0], t[1], t[2], c)) return false;
            if (i >= 11) return inR(t[0], 20.0, rate * 0.45) && inR(t[1], kAmbMinDb, kAmbMaxDb) && inR(t[2], kAmbMinQ, kAmbMaxQ);
            return true;
        }
        case N60_STAGE_SYMMETRY: return inR(v, -1.0, 1.0);
        case N60_STAGE_CROSSFEED: return inR(v, 0.0, 0.5);
        case N60_STAGE_CROSSTALK: return i == 0 ? inR(v, 200.0, 2000.0) : inR(v, 0.0, 1.0);
        case N60_STAGE_HEADPHONE:
            switch (i) {
                case 0: return inR(v, -30.0, 0.0);
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
                case 6: return v == 1.0f || v == 2.0f || v == 4.0f;
                case 7:
                case 12:
                case 14: return v == 0.0f || v == 1.0f;
                case 8: return inR(v, 0.0, 12.0);
                case 9: return inR(v, -6.0, 0.0);
                case 10: return inR(v, 0.0, 1.0);
                case 11: return v == 0.0f || v == 1.0f || v == 2.0f || v == 3.0f;
                case 13: return inR(v, -3.0, 3.0);
                case 15: return inR(v, 0.5, 6.0);
                case 16: return inR(v, 3.0, 12.0);
                default: return v == 0.0f || v == 1.0f || v == 2.0f;  // 17: rider speed
            }
        case N60_STAGE_STEREO_CROSSOVER:
            switch (i) {
                case 0:
                case 6: return v > 0.0f && static_cast<double>(v) < rate * 0.5;
                case 1:
                case 4:
                case 5: return v == 0.0f || v == 1.0f;
                case 2: return v == 0.0f || v == 1.0f || v == 2.0f;
                case 3: return v >= 0.0f;
                case 7: return v > 0.0f;  // alignment Q
                default: return isInt(v) && v >= 0.0f && v <= 8.0f;  // 8..11: trailer family / order (checked as a pair below)
            }
        case N60_STAGE_MUTE: return v == 0.0f || v == 1.0f;
        case N60_STAGE_DELTA_CAPTURE:
        case N60_STAGE_DELTA_SUBTRACT: return v == 1.0f;
        case N60_STAGE_EXTERNAL: return v == 0.0f || v == 1.0f;
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
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
        case N60_STAGE_ANC_CAPTURE: return v == 0.0f || v == 1.0f;
        default: return false;
    }
}

}  // namespace

n60_status validateSystemStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!lanesOk(s, outCh, ruleOf(s.kind))) return N60_STATUS_BAD_ARGUMENT;
    if (s.kind == N60_STAGE_ANC_CAPTURE || isAnalyserTap(s.kind)) {
        if (s.capacityFrames < 1 || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES) return N60_STATUS_BAD_ARGUMENT;
    } else if (s.kind == N60_STAGE_DELTA_CAPTURE) {
        if (s.capacityFrames < 1 || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES) return N60_STATUS_BAD_ARGUMENT;
    } else if (s.kind == N60_STAGE_EXTERNAL) {
        if (s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES) return N60_STATUS_BAD_ARGUMENT;
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
        case N60_STAGE_STEREO_CROSSOVER:
            if (s.paramCount == 12) {  // ABI v19 filter-spec trailer: HP family, order, LP family, order
                for (uint32_t k = 8; k < 12; k += 2) {
                    n60_xover_prototype pr;
                    if (p[k] > 2.0f || n60_xover_prototype_design(static_cast<uint32_t>(p[k]), static_cast<uint32_t>(p[k + 1]), &pr) != N60_XOVER_OK) {
                        return N60_STATUS_BAD_ARGUMENT;
                    }
                    n60_xover_cascade c;  // the corner must also realise at this rate
                    if (n60_xover_realise(&pr, k == 8, static_cast<double>(p[0]), rate, &c) != N60_XOVER_OK) {
                        return N60_STATUS_BAD_ARGUMENT;
                    }
                }
            }
            break;
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
            if (L.spec != 0) {  // filter-spec trailer: HP family, order, LP family, order (no OFF)
                for (uint32_t k = 0; k < 4; k += 2) {
                    const float fam = p[L.spec + k], ord = p[L.spec + k + 1];
                    n60_xover_prototype pr;
                    if (!isInt(fam) || !isInt(ord) || fam < 0.0f || fam > 2.0f || ord < 1.0f ||
                        n60_xover_prototype_design(static_cast<uint32_t>(fam), static_cast<uint32_t>(ord), &pr) != N60_XOVER_OK) {
                        return N60_STATUS_BAD_ARGUMENT;
                    }
                }
            }
            break;
        }
        case N60_STAGE_AMBIENT:
            for (uint32_t k = 0; k < 3; ++k) {
                double c[5];
                if (!designBiquad(0, rate, p[1 + 3 * k], p[2 + 3 * k], p[3 + 3 * k], c)) return N60_STATUS_BAD_ARGUMENT;
            }
            break;  // trailer sections: paramOk (range) and the full-parameter loop above
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
            const ProtCfg c = protCfg(p, rate, s.paramCount);
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
        case N60_STAGE_STEREO_CROSSOVER: perLane = up(sizeof(XoLane)); shared = up(sizeof(XoShared)); break;
        case N60_STAGE_DELTA_CAPTURE:
            shared = up(sizeof(DeltaShared) + size_t(deltaLaneCount(s)) * (size_t(s.capacityFrames) + kDeltaTaps) * sizeof(float));
            break;
        case N60_STAGE_DELTA_SUBTRACT: shared = up(sizeof(DeltaTie)); break;
        case N60_STAGE_ANC_INJECT: shared = up(sizeof(InjectShared)); break;
        case N60_STAGE_ANC_GUARD: shared = up(sizeof(GuardState)); break;
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
        case N60_STAGE_ANC_CAPTURE:
            perLane = up(size_t(s.capacityFrames) * sizeof(std::atomic<uint32_t>));
            shared = up(sizeof(CapShared));
            break;
        case N60_STAGE_PROTECTION: {
            const ProtCfg c = protCfg(s.params, rate, s.paramCount);
            perLane = up(sizeof(ProtLane)) + protRingBytes(c);
            shared = protSharedBytes(c);
            break;
        }
        default: break;
    }
}

// ---- initialisation ---------------------------------------------------------------------

namespace {

// Same RBJ designs as the kernel's N60CrossoverPreciseDesign (double precision, normalised by a0).
// type: 0 low-pass, 1 high-pass, 2 all-pass.
void xoDesign(uint32_t type, double rate, double hz, double q, double *c) {
    const double omega = 2.0 * kPi * hz / rate;
    const double cosine = std::cos(omega);
    const double alpha = std::sin(omega) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    c[3] = (-2.0 * cosine) / a0;
    c[4] = (1.0 - alpha) / a0;
    if (type == 0) {
        c[0] = (1.0 - cosine) / (2.0 * a0);
        c[1] = 2.0 * c[0];
        c[2] = c[0];
    } else if (type == 1) {
        c[0] = (1.0 + cosine) / (2.0 * a0);
        c[1] = -2.0 * c[0];
        c[2] = c[0];
    } else {
        c[0] = (1.0 - alpha) / a0;
        c[1] = (-2.0 * cosine) / a0;
        c[2] = 1.0;
    }
}

uint32_t hpDelay(double rate, double angleDeg, double radiusM) {
    const double d = std::llround(rate * (radiusM / 343.0) * std::sin(angleDeg * kPi / 180.0));
    return static_cast<uint32_t>(std::min<double>(d, kHpRing - 1));
}

void designInto(uint32_t type, double rate, double f, double db, double q, double *out) {
    double c[5];
    if (designBiquad(type, rate, f, db, q, c)) std::memcpy(out, c, sizeof c);
}

// The mains high-pass and sub low-pass at one corner. Default (no filter-spec trailer): the v16 Butterworth biquad
// squared. General: the stored prototypes realised by the crossover library (realtime-safe).
void designBassSplit(const BassShared &s, double rate, double fc, double hp[][5], double lp[][5]) {
    if (s.general == 0) {
        designInto(4, rate, fc, 0.0, kButterQ, hp[0]);
        std::memcpy(hp[1], hp[0], sizeof hp[1]);
        designInto(3, rate, fc, 0.0, kButterQ, lp[0]);
        std::memcpy(lp[1], lp[0], sizeof lp[1]);
        return;
    }
    n60_xover_cascade c;
    if (n60_xover_realise(&s.hpProto, 1, fc, rate, &c) == N60_XOVER_OK) {
        for (uint32_t k = 0; k < c.count; ++k) std::memcpy(hp[k], &c.sections[k], sizeof hp[k]);
    }
    if (n60_xover_realise(&s.lpProto, 0, fc, rate, &c) == N60_XOVER_OK) {
        for (uint32_t k = 0; k < c.count; ++k) std::memcpy(lp[k], &c.sections[k], sizeof lp[k]);
    }
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
            s->n = r.paramCount > 10 ? 3u + static_cast<uint32_t>(p[10]) : 3u;
            for (uint32_t k = 0; k < s->n; ++k) {
                const float *q = k < 3 ? p + 1 + 3 * k : p + 11 + 3 * (k - 3);
                designInto(k == 0 ? 1u : (k == 2 ? 2u : 0u), rate, q[0], q[1], q[2], s->coef[k]);
                std::memcpy(s->seen[k], q, sizeof s->seen[k]);
                s->xf[k] = 0;
            }
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
            rampInit(s->hr, static_cast<float>(db2lin(p[0])));
            s->seenHr = p[0];
            s->seenAngle = p[2];
            s->seenRadius = p[3];
            s->seenLp = p[4];
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
            s->alpha = s->alphaTarget = 1.0 - std::exp(-2.0 * kPi * f / rate);
            s->delay = s->delayN = hpDelay(rate, p[2], p[3]);
            for (uint32_t k = 0; k < s->nA + s->nB; ++k) {
                const float *q = p + kHpFixed + 4 * k;
                designInto(static_cast<uint32_t>(q[0]), rate, q[1], q[2], q[3], s->coef[k]);
                std::memcpy(s->seenSec[k], q, sizeof s->seenSec[k]);
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
            BassLayout L;
            if (!parseBass(p, r.paramCount, L)) break;  // unreachable: validated at build
            s->nHp = s->nLp = 2;
            if (L.spec != 0) {
                s->general = 1;
                n60_xover_prototype_design(static_cast<uint32_t>(p[L.spec]), static_cast<uint32_t>(p[L.spec + 1]), &s->hpProto);
                n60_xover_prototype_design(static_cast<uint32_t>(p[L.spec + 2]), static_cast<uint32_t>(p[L.spec + 3]), &s->lpProto);
                s->nHp = s->hpProto.count * s->hpProto.copies;
                s->nLp = s->lpProto.count * s->lpProto.copies;
            }
            designBassSplit(*s, rate, p[0], s->hp, s->lp);
            designInto(3, rate, p[4], 0.0, kButterQ, s->lfe);
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
        case N60_STAGE_STEREO_CROSSOVER: {
            XoShared *x = reinterpret_cast<XoShared *>(sh);
            if (r.paramCount == 12) {  // ABI v19 filter spec: the crossover library realises the prototypes
                n60_xover_prototype hpP, lpP;
                n60_xover_cascade c;
                n60_xover_prototype_design(static_cast<uint32_t>(p[8]), static_cast<uint32_t>(p[9]), &hpP);
                n60_xover_prototype_design(static_cast<uint32_t>(p[10]), static_cast<uint32_t>(p[11]), &lpP);
                x->nHp = x->nLp = 0;
                if (n60_xover_realise(&hpP, 1, static_cast<double>(p[0]), rate, &c) == N60_XOVER_OK) {
                    x->nHp = c.count;
                    for (uint32_t k = 0; k < c.count; ++k) std::memcpy(x->hp[k], &c.sections[k], sizeof x->hp[k]);
                }
                if (n60_xover_realise(&lpP, 0, static_cast<double>(p[0]), rate, &c) == N60_XOVER_OK) {
                    x->nLp = c.count;
                    for (uint32_t k = 0; k < c.count; ++k) std::memcpy(x->lp[k], &c.sections[k], sizeof x->lp[k]);
                }
            } else {  // no trailer: exactly the v18 LR24 / LR48 arithmetic
                static const double q24[2] = {0.7071067811865476, 0.7071067811865476};
                static const double q48[4] = {0.5411961001461970, 1.3065629648763766, 0.5411961001461970, 1.3065629648763766};
                const bool lr48 = p[1] != 0.0f;
                x->nHp = x->nLp = lr48 ? 4u : 2u;
                for (uint32_t k = 0; k < x->nHp; ++k) {
                    const double q = lr48 ? q48[k] : q24[k];
                    xoDesign(1, rate, static_cast<double>(p[0]), q, x->hp[k]);
                    xoDesign(0, rate, static_cast<double>(p[0]), q, x->lp[k]);
                }
            }
            x->mode = static_cast<uint32_t>(p[2]);
            x->gain = p[3];
            x->invert = p[4] != 0.0f ? 1u : 0u;
            x->align = p[5] != 0.0f ? 1u : 0u;
            if (x->align != 0u) xoDesign(2, rate, static_cast<double>(p[6]), static_cast<double>(p[7]), x->ap);
            break;
        }
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
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
        case N60_STAGE_ANC_CAPTURE: new (sh) CapShared{};
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                std::atomic<uint32_t> *ring = reinterpret_cast<std::atomic<uint32_t> *>(laneState(h, r, l));
                for (uint32_t i = 0; i < r.capacity; ++i) new (&ring[i]) std::atomic<uint32_t>(0);
            }
            break;
        case N60_STAGE_PROTECTION: {
            const ProtCfg c = protCfg(p, rate, r.paramCount);
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

n60_status validateSystemParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
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
        case N60_STAGE_AMBIENT: live = idx != 10; break;  // ABI v32: bands and trailer sections are live; the count is topology
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED: live = true; break;
        case N60_STAGE_CROSSTALK: live = true; break;
        case N60_STAGE_HEADPHONE: {
            if (idx >= kHpFixed) {  // section type / Hz / dB / Q (E13 S3); counts and polarity stay topology
                const float *hp = paramsOf(h, r);
                float sec[4];
                const uint32_t k = (idx - kHpFixed) / 4;
                std::memcpy(sec, hp + kHpFixed + 4 * k, sizeof sec);
                sec[(idx - kHpFixed) % 4] = value;
                return sectionOk(sec, h->sampleRate) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
            }
            live = idx <= 6;
            break;
        }
        case N60_STAGE_PROTECTION: live = idx >= 1 && idx <= 3; break;
        case N60_STAGE_MUTE: live = true; break;
        case N60_STAGE_EXTERNAL: live = idx == 0; break;
        case N60_STAGE_ANC_GUARD: live = idx == 11; break;
        case N60_STAGE_ANC_INJECT: live = idx == 2 || idx == 3; break;
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN: live = idx == 0; break;  // the demand switch
        default: live = false; break;  // pause gate, ANC capture, authorisation: new snapshot only
    }
    const float *p = paramsOf(h, r);
    if (!paramOk(r.kind, idx, value, p, h->sampleRate, h->outputChannels)) return N60_STATUS_BAD_ARGUMENT;
    return live ? N60_STATUS_OK : N60_STATUS_UNSUPPORTED;
}

uint32_t systemLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING {
    if (r.kind == N60_STAGE_FRAC_DELAY) return static_cast<uint32_t>(paramsOf(h, r)[0]);
    if (r.kind == N60_STAGE_EXTERNAL) return r.capacity;
    if (r.kind != N60_STAGE_PROTECTION) return 0;
    return protCfg(paramsOf(h, r), h->sampleRate, r.paramCount).latency;
}

// ---- run ----------------------------------------------------------------------------------

namespace {

void runAmbient(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    AmbShared &s = *reinterpret_cast<AmbShared *>(sharedState(h, r));
    const uint32_t ramp = h->rampFrames;
    const double rate = h->sampleRate;
    // A changed section runs as a second instance (new coefficients, state continued from the old one) and the
    // two are crossfaded over the ramp window; an edit that arrives mid-crossfade is picked up when it ends.
    for (uint32_t k = 0; k < s.n; ++k) {
        const float *q = k < 3 ? p + 1 + 3 * k : p + 11 + 3 * (k - 3);
        if ((q[0] != s.seen[k][0] || q[1] != s.seen[k][1] || q[2] != s.seen[k][2]) && s.xf[k] == 0) {
            std::memcpy(s.seen[k], q, sizeof s.seen[k]);
            designInto(k == 0 ? 1u : (k == 2 ? 2u : 0u), rate, q[0], q[1], q[2], s.coefN[k]);
            if (ramp == 0) {
                std::memcpy(s.coef[k], s.coefN[k], sizeof s.coef[k]);
            } else {
                for (uint32_t l = 0; l < r.laneCount; ++l) {
                    AmbLane &a = *reinterpret_cast<AmbLane *>(laneState(h, r, l));
                    a.zN[k] = a.z[k];
                }
                s.xf[k] = ramp;
            }
        }
    }
    const double invRamp = ramp != 0 ? 1.0 / static_cast<double>(ramp) : 0.0;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        AmbLane &a = *reinterpret_cast<AmbLane *>(laneState(h, r, l));
        if (p[0] != a.seen) {
            a.seen = p[0];
            rampSet(a.g, static_cast<float>(db2lin(p[0])), ramp);
        }
        uint32_t left[kAmbMaxSec];
        const double *cur[kAmbMaxSec];
        bool idle[kAmbMaxSec];
        for (uint32_t k = 0; k < s.n; ++k) {
            left[k] = s.xf[k];
            cur[k] = s.coef[k];
            // Trailer sections at 0 dB with no state are an exact identity: skipped at no cost.
            idle[k] = k >= 3 && left[k] == 0 && s.seen[k][1] == 0.0f && a.z[k].z1 == 0.0 && a.z[k].z2 == 0.0;
        }
        float *buf = lanes[laneOf(r, l)];
        for (uint32_t i = 0; i < frames; ++i) {
            double x = buf[i];
            for (uint32_t b = 0; b < s.n; ++b) {
                if (idle[b]) continue;
                double o = bqRun(cur[b], a.z[b], x);
                if (left[b] != 0) {
                    const double on = bqRun(s.coefN[b], a.zN[b], x);
                    o += (static_cast<double>(ramp - left[b] + 1) * invRamp) * (on - o);
                    if (--left[b] == 0) {
                        a.z[b] = a.zN[b];
                        cur[b] = s.coefN[b];
                    }
                }
                x = o;
            }
            buf[i] = static_cast<float>(x) * rampNext(a.g);
        }
        for (uint32_t k = 0; k < s.n; ++k) {
            bqFlush(a.z[k]);
            if (left[k] != 0) bqFlush(a.zN[k]);
        }
    }
    for (uint32_t k = 0; k < s.n; ++k) {  // adopt finished designs (every lane has run the same frames)
        if (s.xf[k] == 0) continue;
        if (s.xf[k] <= frames) {
            std::memcpy(s.coef[k], s.coefN[k], sizeof s.coef[k]);
            s.xf[k] = 0;
        } else {
            s.xf[k] -= frames;
        }
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
}

void runHeadphone(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    HpShared &s = *reinterpret_cast<HpShared *>(sharedState(h, r));
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    const uint32_t ramp = h->rampFrames;
    if (p[0] != s.seenHr) {
        s.seenHr = p[0];
        rampSet(s.hr, static_cast<float>(db2lin(p[0])), ramp);
    }
    if (p[1] != s.seenMix) {
        s.seenMix = p[1];
        rampSet(s.mix, 0.5f * p[1], ramp);
    }
    if (p[5] != s.seenGA) {
        s.seenGA = p[5];
        rampSet(s.gA, static_cast<float>(db2lin(p[5])), ramp);
    }
    if (p[6] != s.seenGB) {
        s.seenGB = p[6];
        rampSet(s.gB, static_cast<float>(db2lin(p[6])), ramp);
    }
    if ((p[2] != s.seenAngle || p[3] != s.seenRadius) && s.delayLeft == 0) {
        s.seenAngle = p[2];
        s.seenRadius = p[3];
        s.delayN = hpDelay(rate, p[2], p[3]);
        if (s.delayN != s.delay) {
            if (ramp == 0) s.delay = s.delayN;
            else s.delayLeft = ramp;
        }
    }
    if (p[4] != s.seenLp && s.alphaLeft == 0) {
        s.seenLp = p[4];
        s.alphaTarget = 1.0 - std::exp(-2.0 * kPi * static_cast<double>(p[4]) / rate);
        if (ramp == 0) {
            s.alpha = s.alphaTarget;
        } else {
            s.alphaLeft = ramp;  // ramped, not stepped (see CROSSTALK)
            s.alphaStep = (s.alphaTarget - s.alpha) / static_cast<double>(ramp);
        }
    }
    const uint32_t nSec = s.nA + s.nB;
    for (uint32_t k = 0; k < nSec; ++k) {
        const float *e = p + kHpFixed + 4 * k;
        if (s.xf[k] == 0 && (e[0] != s.seenSec[k][0] || e[1] != s.seenSec[k][1] || e[2] != s.seenSec[k][2] || e[3] != s.seenSec[k][3])) {
            // validateSystemParam has already vetted type/Hz/dB/Q, so the design cannot fail here.
            std::memcpy(s.seenSec[k], e, sizeof s.seenSec[k]);
            designInto(static_cast<uint32_t>(e[0]), rate, e[1], e[2], e[3], s.coefN[k]);
            if (ramp == 0) {
                std::memcpy(s.coef[k], s.coefN[k], sizeof s.coef[k]);
            } else {
                s.zN[k] = s.z[k];  // incoming section continues from the live one's state
                s.xf[k] = ramp;
            }
        }
    }
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    uint32_t wp = s.wp;
    const double invRamp = ramp != 0 ? 1.0 / static_cast<double>(ramp) : 0.0;
    for (uint32_t i = 0; i < frames; ++i) {
        const float hr = rampNext(s.hr);
        float xa = a[i], xb = b[i];
        xa = std::isfinite(xa) ? xa * hr : 0.0f;
        xb = std::isfinite(xb) ? xb * hr : 0.0f;
        s.ringA[wp] = xa;
        s.ringB[wp] = xb;
        if (s.alphaLeft != 0) {
            --s.alphaLeft;
            s.alpha = s.alphaTarget - s.alphaStep * static_cast<double>(s.alphaLeft);
        }
        const uint32_t rp = (wp + kHpRing - s.delay) & (kHpRing - 1);
        double dA = s.ringA[rp], dB = s.ringB[rp];
        if (s.delayLeft != 0) {
            const uint32_t rn = (wp + kHpRing - s.delayN) & (kHpRing - 1);
            const double t = static_cast<double>(ramp - s.delayLeft + 1) * invRamp;
            dA += t * (static_cast<double>(s.ringA[rn]) - dA);
            dB += t * (static_cast<double>(s.ringB[rn]) - dB);
            if (--s.delayLeft == 0) s.delay = s.delayN;
        }
        s.lowA += s.alpha * (static_cast<double>(xa) - s.lowA);
        s.lowB += s.alpha * (static_cast<double>(xb) - s.lowB);
        s.dlowA += s.alpha * (dA - s.dlowA);
        s.dlowB += s.alpha * (dB - s.dlowB);
        const double mix = rampNext(s.mix);
        double ya = (xa - s.lowA) + (1.0 - mix) * s.lowA + mix * s.dlowB;
        double yb = (xb - s.lowB) + (1.0 - mix) * s.lowB + mix * s.dlowA;
        for (uint32_t k = 0; k < nSec; ++k) {
            double &y = k < s.nA ? ya : yb;
            double o = bqRun(s.coef[k], s.z[k], y);
            if (s.xf[k] != 0) {
                const double on = bqRun(s.coefN[k], s.zN[k], y);
                o += (static_cast<double>(ramp - s.xf[k] + 1) * invRamp) * (on - o);
                if (--s.xf[k] == 0) {
                    std::memcpy(s.coef[k], s.coefN[k], sizeof s.coef[k]);
                    s.z[k] = s.zN[k];
                }
            }
            y = o;
        }
        a[i] = static_cast<float>(ya) * rampNext(s.gA) * s.polA;
        b[i] = static_cast<float>(yb) * rampNext(s.gB) * s.polB;
        wp = (wp + 1) & (kHpRing - 1);
    }
    s.wp = wp;
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
    s.env = std::isfinite(env) ? env : 0.0;
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
        designBassSplit(s, rate, p[0], s.hpN, s.lpN);
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            std::memcpy(st[l]->nhp, st[l]->hp, sizeof st[l]->nhp);
            std::memcpy(st[l]->nlp, st[l]->lp, sizeof st[l]->nlp);
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
            double hp = x, lp = x;
            for (uint32_t k = 0; k < s.nHp; ++k) hp = bqRun(s.hp[k], st[l]->hp[k], hp);
            for (uint32_t k = 0; k < s.nLp; ++k) lp = bqRun(s.lp[k], st[l]->lp[k], lp);
            if (xf) {
                double hn = x, ln = x;
                for (uint32_t k = 0; k < s.nHp; ++k) hn = bqRun(s.hpN[k], st[l]->nhp[k], hn);
                for (uint32_t k = 0; k < s.nLp; ++k) ln = bqRun(s.lpN[k], st[l]->nlp[k], ln);
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
                std::memcpy(st[l]->hp, st[l]->nhp, sizeof st[l]->hp);
                std::memcpy(st[l]->lp, st[l]->nlp, sizeof st[l]->lp);
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
        for (uint32_t k = 0; k < s.nHp; ++k) bqFlush(st[l]->hp[k]);
        for (uint32_t k = 0; k < s.nLp; ++k) bqFlush(st[l]->lp[k]);
        if (s.xfX != 0) {
            for (uint32_t k = 0; k < s.nHp; ++k) bqFlush(st[l]->nhp[k]);
            for (uint32_t k = 0; k < s.nLp; ++k) bqFlush(st[l]->nlp[k]);
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

// Float in, float out, double section state: the kernel's N60CrossoverPreciseProcessSample.
inline float xoRun(const double *c, Bq &s, float in) {
    const double x = static_cast<double>(in);
    const double y = c[0] * x + s.z1;
    s.z1 = c[1] * x - c[3] * y + s.z2;
    s.z2 = c[2] * x - c[4] * y;
    return static_cast<float>(y);
}

// Blockwise: each section runs over a whole chunk before the next, so the loops carry one recursion each.
void runStereoCrossover(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    XoShared &x = *reinterpret_cast<XoShared *>(sharedState(h, r));
    XoLane &st = *reinterpret_cast<XoLane *>(laneState(h, r, 0));
    float *a = lanes[r.laneA];
    float *b = lanes[r.laneB];
    constexpr uint32_t kChunk = 256;
    float ml[kChunk], mr[kChunk], sub[kChunk];
    for (uint32_t base = 0; base < frames; base += kChunk) {
        const uint32_t len = std::min(kChunk, frames - base);
        for (uint32_t i = 0; i < len; ++i) {  // non-finite input must never reach the filter state
            float l = a[base + i], rr = b[base + i];
            if (!(std::fabs(l) <= 3.0e38f)) l = 0.0f;
            if (!(std::fabs(rr) <= 3.0e38f)) rr = 0.0f;
            ml[i] = l;
            mr[i] = rr;
            sub[i] = (l + rr) * 0.5f;
        }
        for (uint32_t k = 0; k < x.nHp; ++k) {
            for (uint32_t i = 0; i < len; ++i) ml[i] = xoRun(x.hp[k], st.hp[0][k], ml[i]);
            for (uint32_t i = 0; i < len; ++i) mr[i] = xoRun(x.hp[k], st.hp[1][k], mr[i]);
        }
        for (uint32_t k = 0; k < x.nLp; ++k) {
            for (uint32_t i = 0; i < len; ++i) sub[i] = xoRun(x.lp[k], x.lpState[k], sub[i]);
        }
        if (x.align != 0u) {
            for (uint32_t i = 0; i < len; ++i) sub[i] = xoRun(x.ap, x.apState, sub[i]);
        }
        for (uint32_t i = 0; i < len; ++i) {
            const float sb = sub[i] * x.gain;
            const float s2 = x.invert != 0u ? -sb : sb;
            if (x.mode == 1u) {
                a[base + i] = ml[i];
                b[base + i] = mr[i];
            } else if (x.mode == 2u) {
                a[base + i] = s2;
                b[base + i] = s2;
            } else {
                a[base + i] = ml[i] + s2;
                b[base + i] = mr[i] + s2;
            }
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

// ABI v13. Host callback stage. The live snapshot calls the host once per block and keeps the processor's effect
// (output minus input) for the incoming snapshot of a rebuild, which adds it instead of calling the host again.
// The cached effect is exact for a processor that is linear in its input; during the short rebuild crossfade it is an
// approximation for nonlinear or time-varying racks and settles exactly when the fade ends. The host owns processor
// reset; the callback sees the graph's sample rate.
// The host callback is documented (graph.h) to obey the realtime rules itself; the compiler cannot verify a function pointer.
bool callExternal(n60_external_process_fn fn, void *context, float *const *ptr, uint32_t n, uint32_t frames) N60_RT_NONBLOCKING {
    N60_RT_TRUST_BEGIN
    return fn(context, ptr, ptr, n, frames) != 0;
    N60_RT_TRUST_END
}

void runExternal(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    ExternalSlot *x = h->external;
    if (x == nullptr || paramsOf(h, r)[0] == 0.0f) return;
    const n60_external_process_fn fn = x->fn.load(std::memory_order_acquire);
    const uint32_t n = r.laneCount;
    if (fn == nullptr) return;
    if (n != x->channels || frames > x->deltaStride) {
        x->faults.fetch_add(1, std::memory_order_relaxed);  // misconfigured host: pass through, but never silently
        return;
    }
    if (h->follower != 0) {
        if (x->deltaFrames != frames) return;
        for (uint32_t k = 0; k < n; ++k) {
            float *buf = lanes[laneOf(r, k)];
            const float *d = x->delta + static_cast<size_t>(k) * x->deltaStride;
            for (uint32_t i = 0; i < frames; ++i) buf[i] += d[i];
        }
        return;
    }
    float *ptr[N60_GRAPH_MAX_CHANNELS];
    for (uint32_t k = 0; k < n; ++k) {
        ptr[k] = lanes[laneOf(r, k)];
        std::memcpy(x->delta + static_cast<size_t>(k) * x->deltaStride, ptr[k], sizeof(float) * frames);
    }
    x->calls.fetch_add(1, std::memory_order_relaxed);
    const bool ok = callExternal(fn, x->context, ptr, n, frames);
    for (uint32_t k = 0; k < n; ++k) {
        float *d = x->delta + static_cast<size_t>(k) * x->deltaStride;
        if (!ok) std::memset(ptr[k], 0, sizeof(float) * frames);
        for (uint32_t i = 0; i < frames; ++i) d[i] = ptr[k][i] - d[i];
    }
    if (!ok) x->faults.fetch_add(1, std::memory_order_relaxed);
    x->deltaFrames = frames;
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
    if (paramsOf(h, r)[0] == 0.0f) return;  // not authorised (ANC) or no analyser demand (taps): nothing is recorded
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

// ---- delta audition (ABI v30) ---------------------------------------------------------------

void runDeltaCapture(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    DeltaShared &d = *reinterpret_cast<DeltaShared *>(sharedState(h, r));
    const uint32_t cap = d.cap;
    for (uint32_t k = 0; k < d.n; ++k) {
        float *ring = deltaRing(&d, k);
        const float *in = lanes[deltaLane(r, k)];
        uint32_t pos = d.wp;
        for (uint32_t i = 0; i < frames; ++i) {
            ring[pos] = in[i];
            if (++pos == cap) pos = 0;
        }
    }
    d.wp = (d.wp + frames) % cap;
}

void runDeltaSubtract(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    DeltaTie &t = *reinterpret_cast<DeltaTie *>(sharedState(h, r));
    if (t.bound == 0) return;
    StageRec &c = stages(h)[t.capture];
    DeltaShared &d = *reinterpret_cast<DeltaShared *>(sharedState(h, c));
    const uint32_t cap = d.cap;
    for (uint32_t k = 0; k < d.n; ++k) {
        float *ring = deltaRing(&d, k);
        float *out = lanes[deltaLane(c, k)];
        const uint32_t delay = d.delay[k];
        // The capture ran first in this block: frame i of the block sits `frames - i` slots behind d.wp.
        uint32_t pos = (d.wp + cap - ((frames + delay) % cap)) % cap;
        if (d.frac[k] == 0.0f) {
            for (uint32_t i = 0; i < frames; ++i) {
                out[i] -= ring[pos];
                if (++pos == cap) pos = 0;
            }
            continue;
        }
        // Fractional alignment (a protection look-ahead that is not a whole number of frames): ring[pos] is the input
        // delayed by the whole part; the taps read it from kDeltaTaps / 2 - 1 frames newer to kDeltaTaps / 2 older.
        // The 32 history samples newest-first end at `newest`; when they do not wrap the ring they are a contiguous run read
        // backwards, so the dot product has no per-tap wrap test. The float32 accumulator is enough: the taps sum to 1
        // (designDeltaTaps normalises them) and the 32 products are of one signal, so the rounding error is a few 1e-7
        // relative to the signal, far below the 24-bit-equivalent floor of the delta being listened to. Four partial sums
        // keep the loop free of a serial dependency.
        const float *tap = deltaTaps(&d, k);
        constexpr uint32_t kOldest = kDeltaTaps - 1;
        for (uint32_t i = 0; i < frames; ++i) {
            uint32_t newest = pos + kDeltaTaps / 2 - 1;
            if (newest >= cap) newest -= cap;
            const float *run;
            float window[kDeltaTaps];
            if (newest >= kOldest) {
                run = ring + (newest - kOldest);  // oldest..newest, ascending
            } else {  // the run wraps (rare: once per ring revolution); gather it in the same order
                for (uint32_t j = 0; j < kDeltaTaps; ++j) window[kOldest - j] = ring[newest >= j ? newest - j : newest + cap - j];
                run = window;
            }
            float a0 = 0.0f, a1 = 0.0f, a2 = 0.0f, a3 = 0.0f;
            for (uint32_t j = 0; j < kDeltaTaps; j += 4) {
                a0 += run[kOldest - j] * tap[j];
                a1 += run[kOldest - j - 1] * tap[j + 1];
                a2 += run[kOldest - j - 2] * tap[j + 2];
                a3 += run[kOldest - j - 3] * tap[j + 3];
            }
            out[i] -= (a0 + a1) + (a2 + a3);
            if (++pos == cap) pos = 0;
        }
    }
}

// ---- protection ---------------------------------------------------------------------------

constexpr uint32_t kHbTaps = 65;
constexpr float kHalfBand[kHbTaps] = {
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

// The half-band taps in window order: kHalfBandRev[j] pairs with the sample j - 63 steps from the newest, so the 64-tap
// dot product reads the history window forwards (the 65th tap is zero). E20 S3: four independent SIMD accumulators
// replace the serial float chain, in both the SIMD and scalar builds (simd::dot16), so the two agree bit for bit.
struct HalfBandRev {
    alignas(16) float t[64];
    constexpr HalfBandRev() : t{} { for (uint32_t j = 0; j < 64; ++j) t[j] = kHalfBand[63 - j]; }
};
constexpr HalfBandRev kHalfBandRev;

// E20 S4 (G15 c): the half-band's even taps are zero, so each polyphase branch is half the length.
//  - A decimating filter still takes every input into its history, but only computes the 64-tap dot product when its output
//    is kept (hbWrite then hbDot); a discarded output costs a store. The kept outputs are bit-identical to before.
//  - An interpolating filter (zero-stuffed input) keeps only its real inputs: out[0] is the centre tap on the input 16 back
//    (one multiply, equal to the old sum of one non-zero product and zeros), out[1] is a 32-tap dot over the odd taps.
inline void hbWrite(Hb &f, float in) {
    const uint32_t newest = f.w;
    f.s[newest] = in;
    f.s[newest + kHbTaps] = in;
    f.w = newest + 1 == kHbTaps ? 0u : newest + 1;
}
inline float hbDot(const Hb &f) {
    const uint32_t newest = f.w == 0 ? kHbTaps - 1 : f.w - 1;  // the sample hbWrite stored last
    return simd::dot16(f.s + newest + kHbTaps - 63u, kHalfBandRev.t, 64);
}

constexpr uint32_t kHbUp = 32;  // real inputs an interpolating half-band holds (kHbUp doubled in Hb::s)
// Odd taps in window order: kHalfBandOddRev[j] pairs with the input kHbUp - 1 - j steps old.
struct HalfBandOddRev {
    alignas(16) float t[kHbUp];
    constexpr HalfBandOddRev() : t{} { for (uint32_t j = 0; j < kHbUp; ++j) t[j] = kHalfBand[63 - 2 * j]; }
};
constexpr HalfBandOddRev kHalfBandOddRev;

inline void interp2(Hb &f, float in, float out[2]) {
    const uint32_t newest = f.w;
    f.s[newest] = in;
    f.s[newest + kHbUp] = in;
    f.w = newest + 1 == kHbUp ? 0u : newest + 1;
    const float *win = f.s + newest + 1;  // oldest .. newest (= in)
    out[0] = 2.0f * (kHalfBand[32] * win[kHbUp - 1 - 16]);
    out[1] = 2.0f * simd::dot16(win, kHalfBandOddRev.t, kHbUp);
}

constexpr float kEps = 1.0e-12f;

// The kernel's soft_clip_sample (N60Protection.c), in float, with the trim powers precomputed.
inline float clipCurve(uint32_t curve, float u, bool negative) {
    u = std::fmin(std::fmax(u, 0.0f), 1.0f);
    const float halfPi = static_cast<float>(kPi) * 0.5f;
    switch (curve) {
        case 1: return 1.0f - (1.0f - u) * (1.0f - u) * (1.0f - u);
        case 2: return std::sin(halfPi * u);
        case 3: return negative ? 1.0f - (1.0f - u) * (1.0f - u) * std::sqrt(1.0f - u) : std::sin(halfPi * u);
        default: return 2.0f * u - u * u;
    }
}

inline float softClip(const ProtCfg &c, float input) {
    const float driven = input * c.drive * (input < 0.0f ? c.trimNeg : c.trimPos);
    const float sign = driven < 0.0f ? -1.0f : 1.0f;
    const float magnitude = std::fabs(driven);
    const float linearLimited = std::fmin(magnitude, 1.0f);
    float shaped = linearLimited;
    if (magnitude > c.threshold) {
        const float headroom = std::fmax(1.0f - c.threshold, 1.0e-6f);
        const float u = (magnitude - c.threshold) / headroom;
        shaped = std::fmin(c.threshold + headroom * clipCurve(c.curve, u, sign < 0.0f), 1.0f);
    }
    const float mixed = linearLimited + (shaped - linearLimited) * c.knee;
    return sign * std::fmin(mixed, 1.0f) * c.comp;
}

void runProtection(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    ProtShared &sh = *reinterpret_cast<ProtShared *>(sharedState(h, r));
    if (sh.cfgValid == 0 || p[1] != sh.seenCeil || p[2] != sh.seenAtk || p[3] != sh.seenRel) {
        sh.cfg = protCfg(p, h->sampleRate, r.paramCount);  // only the live parameters 1..3 can differ from the snapshot's
        sh.seenCeil = p[1];
        sh.seenAtk = p[2];
        sh.seenRel = p[3];
        sh.cfgValid = 1;
    }
    const ProtCfg c = sh.cfg;
    if (c.factor == 1 && !c.limiter && !c.clipper) {
        // Bypass: no processing, no latency. Clear the "now" readbacks so a switched-off limiter
        // never reads as active; the peaks and max reduction stay as the reader left them. The rider resets,
        // as the kernel's bypass does.
        sh.riderSustained = 0.0;
        sh.riderAtten = 0.0;
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
            peak = std::fmax(peak, std::fabs(hi[l][k]));
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
        sh.seq = seq + 1u;
    };

    // One high-rate sample: input peak (before the clipper, as the kernel measures it), clipper, limiter, output peak.
    auto procHigh = [&](uint32_t k) {
        for (uint32_t l = 0; l < n; ++l) inPeak[l] = std::fmax(inPeak[l], std::fabs(hi[l][k]));
        if (c.clipper) {
            for (uint32_t l = 0; l < n; ++l) hi[l][k] = softClip(c, hi[l][k]);
        }
        if (c.limiter) limitHigh(k);
        for (uint32_t l = 0; l < n; ++l) outPeak[l] = std::fmax(outPeak[l], std::fabs(hi[l][k]));
    };

    for (uint32_t l = 0; l < n; ++l) {  // non-finite input must never reach the filter or window state
        for (uint32_t i = 0; i < frames; ++i) {
            if (!(std::fabs(ptr[l][i]) <= 3.0e38f)) ptr[l][i] = 0.0f;
        }
    }
    double sustained = sh.riderSustained;
    double atten = sh.riderAtten;
    double gainAtten = -1.0;
    float riderGain = 1.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        if (c.riderCfg) {
            // The kernel's update_gain_rider, once per frame from the limiter gain as the previous frame left it.
            const double inst = c.limiter && sh.gain < 1.0
                                    ? std::fmax(0.0, static_cast<double>(-20.0f * std::log10(std::fmax(static_cast<float>(sh.gain), kEps))))
                                    : 0.0;
            sustained = inst + c.riderMeasCoef * (sustained - inst);
            double desired = 0.0;
            if (c.rider && c.limiter) {
                desired = std::fmin(static_cast<double>(c.riderMax), std::fmax(0.0, atten + (sustained - static_cast<double>(c.riderTarget))));
            }
            atten = desired + c.riderRespCoef * (atten - desired);
            if (atten < 1e-6) atten = 0.0;  // idle cutoff: below 1e-6 dB the rider is off (skips the lane multiply), not a denormal flush
            if (atten != 0.0) {
                // The rider moves over seconds: redo the pow only after a 1e-4 dB change (a 1e-5 relative gain error).
                if (std::fabs(atten - gainAtten) > 1.0e-4) {
                    gainAtten = atten;
                    riderGain = dbToLin(static_cast<float>(-atten));
                }
                const float g = riderGain;
                for (uint32_t l = 0; l < n; ++l) ptr[l][i] *= g;
            }
        }
        if (c.factor == 1) {
            for (uint32_t l = 0; l < n; ++l) hi[l][0] = ptr[l][i];
            procHigh(0);
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
            for (uint32_t k = 0; k < 2; ++k) procHigh(k);
            for (uint32_t k = 0; k < 2; ++k) {
                const bool emit = sh.ph1 == 0u;
                sh.ph1 ^= 1u;
                for (uint32_t l = 0; l < n; ++l) {
                    hbWrite(pl[l]->dn1, hi[l][k]);
                    if (emit) ptr[l][i] = hbDot(pl[l]->dn1);
                }
            }
            continue;
        }
        for (uint32_t k = 0; k < 4; ++k) procHigh(k);
        float down[kMaxLanes][2];
        uint32_t emitted = 0;
        for (uint32_t k = 0; k < 4; ++k) {
            const bool emit = sh.ph2 == 0u;
            sh.ph2 ^= 1u;
            for (uint32_t l = 0; l < n; ++l) {
                hbWrite(pl[l]->dn2, hi[l][k]);
                if (emit && emitted < 2u) down[l][emitted] = hbDot(pl[l]->dn2);
            }
            if (emit) emitted += 1u;
        }
        for (uint32_t k = 0; k < 2; ++k) {
            const bool emit = sh.ph1 == 0u;
            sh.ph1 ^= 1u;
            for (uint32_t l = 0; l < n; ++l) {
                hbWrite(pl[l]->dn1, down[l][k]);
                if (emit) ptr[l][i] = hbDot(pl[l]->dn1);
            }
        }
    }

    sh.riderSustained = sustained;
    sh.riderAtten = atten;

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

void runSystem(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    switch (r.kind) {
        case N60_STAGE_AMBIENT: runAmbient(h, r, lanes, frames); break;
        case N60_STAGE_SYMMETRY: runSymmetry(h, r, lanes, frames); break;
        case N60_STAGE_CROSSFEED: runCrossfeed(h, r, lanes, frames); break;
        case N60_STAGE_CROSSTALK: runCrosstalk(h, r, lanes, frames); break;
        case N60_STAGE_HEADPHONE: runHeadphone(h, r, lanes, frames); break;
        case N60_STAGE_PAUSE_GATE: runGate(h, r, lanes, frames); break;
        case N60_STAGE_BASS_MGMT: runBass(h, r, lanes, frames); break;
        case N60_STAGE_MUTE: runMute(h, r, lanes, frames); break;
        case N60_STAGE_EXTERNAL: runExternal(h, r, lanes, frames); break;
        case N60_STAGE_FRAC_DELAY: runFracDelay(h, r, lanes, frames); break;
        case N60_STAGE_STEREO_CROSSOVER: runStereoCrossover(h, r, lanes, frames); break;
        case N60_STAGE_DELTA_CAPTURE: runDeltaCapture(h, r, lanes, frames); break;
        case N60_STAGE_DELTA_SUBTRACT: runDeltaSubtract(h, r, lanes, frames); break;
        case N60_STAGE_ANC_INJECT: runInject(h, r, lanes, frames); break;
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN:
        case N60_STAGE_ANC_CAPTURE: runCapture(h, r, lanes, frames); break;
        case N60_STAGE_PROTECTION: runProtection(h, r, lanes, frames); break;
        case N60_STAGE_ANC_GUARD: runGuard(h, r, lanes, frames); break;
        default: break;
    }
}

// ---- rebuild support ---------------------------------------------------------------------------

uint64_t systemRiderCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING {
    uint64_t bytes = 0;
    if (from == nullptr || to == nullptr) return bytes;
    const StageRec *src = stages(from);
    StageRec *dst = stages(to);
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (dst[i].kind != N60_STAGE_PROTECTION) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != N60_STAGE_PROTECTION || src[j].id != dst[i].id) continue;
            const ProtShared &a = *reinterpret_cast<const ProtShared *>(sharedState(from, src[j]));
            ProtShared &b = *reinterpret_cast<ProtShared *>(sharedState(to, dst[i]));
            b.riderSustained = a.riderSustained;
            b.riderAtten = a.riderAtten;
            bytes += 2 * sizeof(float);
            break;
        }
    }
    return bytes;
}

uint32_t systemRebuildMute(SnapHeader *h, bool silentNow) N60_RT_NONBLOCKING {
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
    if (r == nullptr || (r->kind != N60_STAGE_ANC_CAPTURE && !isAnalyserTap(r->kind)) || lane >= h->outputChannels) return N60_STATUS_BAD_ARGUMENT;
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

// ---- delta audition: binding and rebuild carry -----------------------------------------------

namespace n60 {

static double besselI0(double x) {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 60; ++k) {
        term *= (x / (2.0 * k)) * (x / (2.0 * k));
        sum += term;
    }
    return sum;
}

// Windowed-sinc taps (Kaiser, beta 9) for a delay of M + f frames read as x[n - M - j], j = -15..16 (tap index j + 15).
static void designDeltaTaps(double f, float *taps) {
    constexpr double kPi = 3.14159265358979323846;
    constexpr double beta = 9.0;
    const int half = static_cast<int>(kDeltaTaps / 2);
    double sum = 0.0;
    double v[kDeltaTaps];
    for (int t = 0; t < static_cast<int>(kDeltaTaps); ++t) {
        const double x = static_cast<double>(t - (half - 1)) - f;
        const double w = besselI0(beta * std::sqrt(std::fmax(0.0, 1.0 - (x / half) * (x / half)))) / besselI0(beta);
        v[t] = (std::fabs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x)) * w;
        sum += v[t];
    }
    for (uint32_t t = 0; t < kDeltaTaps; ++t) taps[t] = static_cast<float>(v[t] / sum);
}

bool deltaFinalize(SnapHeader *h) {
    StageRec *table = stages(h);
    uint32_t capIdx = h->stageCount, subIdx = h->stageCount;
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        if (table[i].kind == N60_STAGE_DELTA_CAPTURE) capIdx = i;
        if (table[i].kind == N60_STAGE_DELTA_SUBTRACT) subIdx = i;
    }
    if (capIdx == h->stageCount && subIdx == h->stageCount) return true;
    if (capIdx >= subIdx || subIdx >= h->stageCount) return false;
    uint32_t perLane[N60_GRAPH_MAX_CHANNELS];
    uint32_t atCapture[N60_GRAPH_MAX_CHANNELS];
    snapshotLaneLatency(h, subIdx, perLane);
    snapshotLaneLatency(h, capIdx, atCapture);  // only the latency between the two stages must be bridged
    for (uint32_t l = 0; l < N60_GRAPH_MAX_CHANNELS; ++l) perLane[l] = perLane[l] >= atCapture[l] ? perLane[l] - atCapture[l] : 0;
    // ABI v31 (G52): a protection look-ahead of a non-whole number of frames is reported rounded up, so the lane's true
    // delay is the reported latency minus the rounding. Track it per lane as a fraction of a frame.
    double over[N60_GRAPH_MAX_CHANNELS] = {};
    for (uint32_t i = capIdx + 1; i < subIdx; ++i) {
        const StageRec &r = table[i];
        if (r.kind != N60_STAGE_PROTECTION) continue;
        const ProtCfg pc = protCfg(paramsOf(h, r), h->sampleRate, r.paramCount);
        if (pc.factor < 2 || pc.laHigh % pc.factor == 0) continue;
        const double rounding = static_cast<double>(pc.factor - pc.laHigh % pc.factor) / static_cast<double>(pc.factor);
        for (uint32_t l = 0; l < r.laneCount; ++l) over[laneOf(r, l)] += rounding;
    }
    StageRec &c = table[capIdx];
    DeltaShared &d = *reinterpret_cast<DeltaShared *>(sharedState(h, c));
    d.cap = c.capacity;
    d.wp = 0;
    d.n = deltaLaneCount(c);
    if (d.n > N60_GRAPH_MAX_CHANNELS) return false;
    uint64_t need = 0;
    uint32_t keepNeed = 0;
    for (uint32_t k = 0; k < d.n; ++k) {
        const uint32_t lane = deltaLane(c, k);
        double exact = static_cast<double>(perLane[lane]) - over[lane];
        if (exact < 0.0) exact = 0.0;
        uint32_t whole = static_cast<uint32_t>(std::floor(exact + 1e-9));
        double f = exact - static_cast<double>(whole);
        if (f < 1e-6) f = 0.0;
        d.frac[k] = static_cast<float>(f);
        d.delay[k] = whole;
        uint32_t extra = 0;
        if (f != 0.0) {
            // The interpolator reads kDeltaTaps / 2 - 1 frames newer than the whole delay, so that must not be the future.
            if (whole < kDeltaTaps / 2 - 1) return false;
            designDeltaTaps(f, deltaTaps(&d, k));
            extra = kDeltaTaps / 2;
        }
        need = std::max<uint64_t>(need, uint64_t(h->maxBlockFrames) + whole + extra);
        keepNeed = std::max(keepNeed, whole + extra);
    }
    d.keepNeed = keepNeed;
    if (need > d.cap) return false;
    DeltaTie &t = *reinterpret_cast<DeltaTie *>(sharedState(h, table[subIdx]));
    t.capture = capIdx;
    t.bound = 1;
    return true;
}

uint64_t deltaCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING {
    if (from == nullptr || to == nullptr) return 0;
    StageRec *dst = stages(to);
    const StageRec *src = stages(from);
    uint64_t bytes = 0;
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (dst[i].kind != N60_STAGE_DELTA_CAPTURE) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != N60_STAGE_DELTA_CAPTURE || src[j].id != dst[i].id) continue;
            DeltaShared &a = *reinterpret_cast<DeltaShared *>(sharedState(from, src[j]));
            DeltaShared &b = *reinterpret_cast<DeltaShared *>(sharedState(to, dst[i]));
            if (a.n != b.n) break;  // another lane set: the history belongs to other lanes
            // Copy the newest frames the new ring can keep and still take a block, and no more than its alignment can
            // read: oldest first, so the history ends at wp.
            uint32_t keep = std::min(a.cap, b.cap) > to->maxBlockFrames ? std::min(a.cap, b.cap) - to->maxBlockFrames : 0u;
            keep = std::min(keep, b.keepNeed);
            for (uint32_t k = 0; k < b.n; ++k) {
                const float *ra = deltaRing(&a, k);
                float *rb = deltaRing(&b, k);
                uint32_t pa = (a.wp + a.cap - keep % a.cap) % a.cap;
                for (uint32_t n = 0; n < keep; ++n) {
                    rb[n] = ra[pa];
                    if (++pa == a.cap) pa = 0;
                }
                for (uint32_t n = keep; n < b.cap; ++n) rb[n] = 0.0f;
            }
            b.wp = keep % b.cap;
            bytes += uint64_t(b.n) * uint64_t(keep) * sizeof(float);
            break;
        }
    }
    return bytes;
}

}  // namespace n60
