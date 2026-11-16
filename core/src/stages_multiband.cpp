// libn60core ABI v25 (v42 for N bands) multiband compressor stage (E6 S12d): the stereo kernel's three-band compressor, ported from
// N60Dynamics.c (process_multiband_compressor) with the same float arithmetic, so the output matches the kernel to
// rounding. One pair stage, N60_STAGE_MULTIBAND, at rank 9.9: after the de-esser, directly before the compressor, which
// is where the kernel runs it.
//
// Derivations (public specifications):
//  - Band split: Linkwitz-Riley low-pass at the low/mid corner and high-pass at the mid/high corner, each LR4 (two
//    cascaded 2nd-order Butterworth biquads, Q = 1/sqrt(2)) or LR8 (two cascaded 4th-order Butterworth filters, section
//    Qs 0.5412 and 1.3066; Linkwitz and Riley, JAES 1976). The mid band is the residual: dry - low - high.
//  - Band-pass tree (E28 G42, paramCount 44 with parameter 43 = 1; otherwise the residual above): low = LP1(LP2 x),
//    mid = HP1(LP2 x), high = AP1(HP2 x), where AP1 is the all-pass LP1 + HP1 of the low crossover (LR4: one Q = 1/sqrt(2)
//    section, since (1 + s^4) / D(s)^2 = D(-s) / D(s) for the Butterworth-2 polynomial D; LR8: the two Butterworth-4
//    sections). The sum is AP1.AP2, flat in magnitude (Linkwitz and Riley, JAES 1976; Lipshitz and Vanderkooy, JAES 1986,
//    for all-pass compensation of a cascaded split). Latency: none (IIR); the sum carries the all-pass phase, so the stage
//    fades against the dry signal when it enables or disables (5 ms, no lookahead). Every band holds only its own range.
//  - N bands (E33 S5b, paramCount 73, 2 to 5 bands): the same tree from the top corner down. Band c+1 = AP_0..AP_(c-1)
//    (HP_c(y_(c+1))), y_c = LP_c(y_(c+1)), y_(N-1) = x; the lowest corner gives bands 0 and 1 as LP_0(y_1) and HP_0(y_1).
//    The sum is the product of the corner all-passes, flat in magnitude. A count of 3 with split 0 keeps the residual mid.
//  - Detector: per band, a 2nd-order Butterworth high-pass sidechain (0 Hz = off), detector = max(|L|, |R|) in dB.
//  - Gain computer: downward compressor with a quadratic soft knee (Giannoulis, Massberg and Reiss, JAES 60(6), 2012)
//    plus make-up, smoothed in dB with the attack pole (gain falling) or the release pole (gain rising).
//  - Auto release (per band, off = kernel parity): the compressor's program-dependent rule. The release pole moves from
//    the fast pole (half the release time, at least 1 ms) to the slow pole (twice the release time, at most 5 s) as the
//    band's current gain reduction deepens from 0 to 12 dB.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runMultiband:
//  - allocation: none. All state is in the snapshot arena (one shared record), built off the audio thread.
//  - synchronisation: none. Once published, the realtime thread owns the state; every parameter except the two slopes is
//    a live plain float the mailbox wrote at block start. The band gain reduction is relaxed atomics read by the control
//    thread.
//  - latency: 0 frames.
//  - sample rate: 8 kHz to 768 kHz (tested 44.1 to 384 kHz). Coefficients and filter state are double (E23 S1b); the
//    crossover split runs left and right together with fused multiply-adds (E20 S10 part 4), so the output matches the kernel
//    to rounding, not bit for bit. Decayed state is flushed to zero once per block. At a
//    block start a changed parameter redesigns its coefficients (at most 11 biquads: bounded libm, no allocation). A crossover
//    corner edit keeps the previous filters (preallocated copy, E32 S4) and blends the bands to the new ones over 5 ms at any
//    rate; no latency; a reset clears the blend.
//    Per-sample log10/pow are kernel-identical (hoisting them is deferred, as for the loudness stage).
//  - channels: a stereo pair (laneA, laneB), as the kernel.
//  - reset: a new snapshot starts parked and neutral; enabling from parked clears the state, as the kernel does. State is
//    not carried across a rebuild (ledger).
#include "simd/simd.hpp"
#include "stages_multiband.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr size_t kAlign = 16;
constexpr float kParkEps = 1.0e-5f;
constexpr float kEpsilon = 1.0e-12f;  // the kernel's N60_DYNAMICS_EPSILON
constexpr double kQ = 0.7071067811865476;
constexpr uint32_t kBands = 5;       // E33 S5b: at most five bands
constexpr uint32_t kCorners = kBands - 1;
constexpr uint32_t kMaxSections = 4;
constexpr uint32_t kApPairs = 6;     // (band, lower corner) all-pass pairs: bands 2..4 hold 1 + 2 + 3
constexpr uint32_t kKinds = 12;      // per-band parameter kinds, in the legacy order below

enum MbParam : uint32_t {
    kOn = 0,           // 0/1
    kLowMidHz = 1,     // corner 0, 40..16000
    kMidHighHz = 2,    // corner 1
    kLowSlope = 3,     // corner 0: 0 LR4, 1 LR8 (topology: not live)
    kHighSlope = 4,    // corner 1 (topology: not live)
    kBandBase = 5,     // 12 kinds of 3 bands (bands 0..2): thr, ratio, attack, release, knee, sidechain, makeup, auto,
                       // bypass, solo, listen, detector at 5 + 3 * kind + band
    kWindow = 41,      // ABI v37: RMS window ms, 5..200
    kLookahead = 42,   // ABI v37: lookahead frames, 0..8192 (topology: not live)
    kBandSplit = 43,   // E28 G42: 0 residual mid (dry - low - high), 1 band-pass tree (topology; three bands only)
    kBandCount = 44,   // ABI v42 (E33 S5b): 2..5 (topology: not live)
    kCorner2 = 45,     // corner 2 Hz
    kCorner3 = 46,     // corner 3 Hz
    kSlope2 = 47,      // corner 2 slope (topology)
    kSlope3 = 48,      // corner 3 slope (topology)
    kExtBase = 49,     // bands 3 and 4 of each kind at 49 + 2 * kind + (band - 3)
    kParams = 29,      // the v25 block
    kParamsX = 43,     // the v37 block
    kParamsS = 44,     // the v37 block plus the band-split mode (E28 G42)
    kParamsN = 73      // ABI v42: the 44-value block plus the band count, corners 2 and 3, their slopes and bands 3 and 4
};
enum Kind : uint32_t { kThr, kRatio, kAtk, kRel, kKnee, kSc, kMk, kAuto, kByp, kSolo, kListenK, kDet };
constexpr uint32_t kMaxLookahead = 16384;  // 20 ms at 768 kHz is 15,360 frames
constexpr double kMinRatio = 1.4142135623730951;  // half an octave between neighbouring corners

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isFlag(float v) { return v == 0.0f || v == 1.0f; }

// E23 S1b: coefficients and state are double (E6 G25: float state at the 38 Hz-class corners loses about 50 dB at
// 384 kHz); input and output stay float.
struct Bq {
    double b0, b1, b2, a1, a2;
};
struct BqState {
    double z1, z2;
};

float smoothToward(float current, float target, double coef) {
    return static_cast<float>(double(target) + coef * (double(current) - double(target)));
}
bool nearZero(float v) { return std::fabs(v) <= kParkEps; }
Bq identityBq() { return Bq{1.0, 0.0, 0.0, 0.0, 0.0}; }

double runBqD(const Bq &c, BqState &s, double in) {
    const double out = c.b0 * in + s.z1;
    s.z1 = c.b1 * in - c.a1 * out + s.z2;
    s.z2 = c.b2 * in - c.a2 * out;
    return out;
}
float runBq(const Bq &c, BqState &s, float in) { return static_cast<float>(runBqD(c, s, static_cast<double>(in))); }

// RBJ low-pass and high-pass, normalised in double and stored as float (the kernel's N60BiquadDesign).
bool designBq(bool highPass, double rate, double f, double q, Bq &out) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(q) || q <= 0.0) return false;
    const double omega = 2.0 * kPi * f / rate;
    const double cosO = std::cos(omega);
    const double sinO = std::sin(omega);
    const double alpha = sinO / (2.0 * q);
    double b0, b1, b2;
    if (!highPass) {
        b0 = (1.0 - cosO) * 0.5; b1 = 1.0 - cosO; b2 = (1.0 - cosO) * 0.5;
    } else {
        b0 = (1.0 + cosO) * 0.5; b1 = -(1.0 + cosO); b2 = (1.0 + cosO) * 0.5;
    }
    const double a0 = 1.0 + alpha, a1 = -2.0 * cosO, a2 = 1.0 - alpha;
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const Bq c{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.b2) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) return false;
    out = c;
    return true;
}

// RBJ all-pass (same denominator as the low-pass at the same Q).
bool designAllPass(double rate, double f, double q, Bq &out) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(q) || q <= 0.0) return false;
    const double omega = 2.0 * kPi * f / rate;
    const double cosO = std::cos(omega);
    const double alpha = std::sin(omega) / (2.0 * q);
    const double a0 = 1.0 + alpha;
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const Bq c{(1.0 - alpha) / a0, -2.0 * cosO / a0, 1.0, -2.0 * cosO / a0, (1.0 - alpha) / a0};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) return false;
    out = c;
    return true;
}

// The kernel's N60CrossoverTopologyQValues.
uint32_t sectionQs(bool lr8, double q[kMaxSections]) {
    if (!lr8) {
        q[0] = q[1] = kQ;
        return 2;
    }
    q[0] = q[2] = 0.5411961001461970;
    q[1] = q[3] = 1.3065629648763766;
    return 4;
}

// The kernel's coefficient_for_time_ms (clamped to 0.05 .. 5000 ms).
double poleForMs(double rate, float ms) {
    const float safe = std::min(std::max(ms, 0.05f), 5000.0f);
    return std::exp(-1.0 / (rate * (double(safe) / 1000.0)));  // double: a float pole at 5 s and 384 kHz is 1 - 5e-7, below its own spacing (E28 G40)
}

float dbToLinear(float db) { return std::pow(10.0f, db / 20.0f); }
float linearToDb(float x) { return 20.0f * std::log10(std::fmax(x, kEpsilon)); }

// The kernel's compressor law (soft knee, no make-up), as dynamics_compression_target.
float bandTarget(float detectorDb, float thr, float ratio, float knee) {
    const float over = detectorDb - thr;
    const float slope = (1.0f / ratio) - 1.0f;
    float comp = 0.0f;
    if (knee <= 0.0f) {
        if (over > 0.0f) comp = slope * over;
    } else {
        const float half = knee * 0.5f;
        if (over >= half) {
            comp = slope * over;
        } else if (over > -half) {
            const float pos = over + half;
            comp = slope * pos * pos / (2.0f * knee);
        }
    }
    return comp;
}

// One crossover set: per corner c the low-pass LP_c and high-pass HP_c (2 or 4 sections) and the all-pass AP_c (1 or 2 sections,
// the phase of LP_c + HP_c). The band-pass tree (see the header derivation) runs each all-pass once per band above its corner,
// so the all-pass states are per (band, corner) pair. Coefficients and states are split so a crossfade copies both cheaply.
struct XCoef {
    Bq lp[kCorners][kMaxSections], hp[kCorners][kMaxSections], ap[kCorners][2];
};
struct XState {
    BqState lpL[kCorners][kMaxSections], lpR[kCorners][kMaxSections], hpL[kCorners][kMaxSections], hpR[kCorners][kMaxSections];
    BqState apL[kApPairs][2], apR[kApPairs][2];
};
uint32_t apPair(uint32_t band, uint32_t corner) { return (band - 1) * (band - 2) / 2 + corner; }  // band >= 2, corner <= band - 2

struct MbShared {
    float bypassCoef;
    uint32_t parked;
    uint32_t n;            // band count 2..5, fixed by the snapshot
    uint32_t split;        // 0 residual mid (three bands only), 1 band-pass tree
    uint32_t lr8[kCorners];  // per corner: fixed by the snapshot
    uint32_t sec[kCorners], apN[kCorners];
    float seenCorner[kCorners];
    XCoef coef;
    XState st;
    float seenHpf[kBands];
    Bq hp[kBands];
    BqState hpL[kBands], hpR[kBands];
    float seenAttack[kBands], seenRelease[kBands];
    double attackPole[kBands], releasePole[kBands], fastPole[kBands], slowPole[kBands];
    float gainDb[kBands];
    std::atomic<uint32_t> grMaxBits[kBands];
    std::atomic<uint32_t> grNowBits[kBands];
    // ABI v37 (E28 S7c): solo gains and listen weights ramp over 5 ms; one lookahead ring set follows the struct.
    float soloG[kBands], listenSide[kBands], listenDelta[kBands];
    double meanSq[kBands];  // RMS mean square in double (E28 S7d, G40)
    BqState lhpL[kBands], lhpR[kBands];  // sidechain filters of the listened band, run on the delayed band
    uint32_t ringLen, ringPos;
    // The tree's sum carries the all-pass phase, so the mix ramps the stage in and out against the dry signal (no lookahead
    // only), so parking cannot step by the all-pass phase.
    double splitMix;  // double: a float one-pole stalls short of 1 at high rates (its step falls under half an ulp)
    // E32 S4 (R10): a crossover edit runs the previous filters (coefficients and state copied at the edit) beside the new ones
    // and blends the band signals over 5 ms. Preallocated here; no allocation at the edit. xActive is realtime-thread only.
    uint32_t xActive;
    double xw;  // blend weight of the new filters, 0..1
    XCoef oCoef;
    XState oSt;
};

// The parameters of a block as one band-indexed view (E33 S5b). The legacy 29, 43 and 44-value blocks decode as three bands;
// the 73-value block carries 2..5. Decoded once per call: it is a few dozen float loads.
struct Eff {
    uint32_t n = 3;
    float corner[kCorners] = {0, 0, 0, 0};
    float v[kKinds][kBands] = {};
    float window = 50.0f;
};
void decode(const float *p, uint32_t pc, Eff &e) {
    const bool wide = pc >= kParamsN;
    e.n = wide ? static_cast<uint32_t>(p[kBandCount]) : 3u;
    e.corner[0] = p[kLowMidHz];
    e.corner[1] = p[kMidHighHz];
    e.corner[2] = wide ? p[kCorner2] : 0.0f;
    e.corner[3] = wide ? p[kCorner3] : 0.0f;
    for (uint32_t k = 0; k < kKinds; ++k) {
        for (uint32_t b = 0; b < kBands; ++b) {
            float val = 0.0f;
            if (b < 3) {
                const uint32_t idx = kBandBase + 3 * k + b;
                if (idx < pc && !(k >= kByp && pc < kParamsX)) val = p[idx];
            } else if (wide) {
                val = p[kExtBase + 2 * k + (b - 3)];
            }
            e.v[k][b] = val;
        }
    }
    e.window = pc >= kParamsX ? p[kWindow] : 50.0f;
}

uint32_t lookaheadOf(const n60_stage_desc &s) {
    return (s.params != nullptr && s.paramCount >= kParamsX) ? static_cast<uint32_t>(s.params[kLookahead]) : 0u;
}
uint32_t bandsOf(const n60_stage_desc &s) {
    return (s.params != nullptr && s.paramCount >= kParamsN) ? static_cast<uint32_t>(s.params[kBandCount]) : 3u;
}
// 2 * n rings of ringLen floats after the struct: one per ring slot for the left lane, then for the right.
float *ringsOf(MbShared &S) { return reinterpret_cast<float *>(reinterpret_cast<uint8_t *>(&S) + up(sizeof(MbShared))); }

void designCorner(MbShared &S, double rate, uint32_t c, float hz) {
    double q[kMaxSections] = {};
    const bool lr8 = S.lr8[c] != 0;
    const uint32_t n = sectionQs(lr8, q);
    for (uint32_t i = 0; i < kMaxSections; ++i) {
        S.coef.lp[c][i] = identityBq();
        if (i < n && !designBq(false, rate, double(hz), q[i], S.coef.lp[c][i])) S.coef.lp[c][i] = identityBq();
        S.coef.hp[c][i] = identityBq();
        if (i < n && !designBq(true, rate, double(hz), q[i], S.coef.hp[c][i])) S.coef.hp[c][i] = identityBq();
    }
    // AP has half the sections: LR4 is one Q = 1/sqrt(2) section, LR8 the two Butterworth-4 sections (LP + HP of an LRn is the
    // all-pass of Butterworth n/2).
    S.apN[c] = lr8 ? 2u : 1u;
    for (uint32_t i = 0; i < 2; ++i) {
        S.coef.ap[c][i] = identityBq();
        if (i < S.apN[c] && !designAllPass(rate, double(hz), lr8 ? (i == 0 ? q[0] : q[1]) : kQ, S.coef.ap[c][i])) S.coef.ap[c][i] = identityBq();
    }
    S.sec[c] = n;
    S.seenCorner[c] = hz;
}

void designHpf(MbShared &S, double rate, uint32_t b, float hz) {
    S.hp[b] = identityBq();
    if (hz > 0.0f && !designBq(true, rate, double(hz), kQ, S.hp[b])) S.hp[b] = identityBq();
    S.seenHpf[b] = hz;
}

void clearState(MbShared &S) {
    std::memset(&S.st, 0, sizeof S.st);
    std::memset(S.hpL, 0, sizeof S.hpL);
    std::memset(S.hpR, 0, sizeof S.hpR);
    std::memset(S.meanSq, 0, sizeof S.meanSq);
    std::memset(S.lhpL, 0, sizeof S.lhpL);
    std::memset(S.lhpR, 0, sizeof S.lhpR);
    S.splitMix = 0.0;
    S.xActive = 0;
    S.xw = 1.0;
    if (S.ringLen != 0) std::memset(ringsOf(S), 0, size_t(2) * S.n * S.ringLen * sizeof(float));
    S.ringPos = 0;
}

// E20 S10 part 4 (G14): `n` cascaded sections for the left and right lane at once over `cn` samples (x element 0 is left, 1 is
// right), the same per-section arithmetic as runBqD with fused multiply-adds (simd::biquadPair). Double in and out; the callers
// round to float where the scalar cascade() did, so every lane's result is the single-lane result.
static_assert(sizeof(Bq) == 5 * sizeof(double), "cascadePair reads the five coefficients as an array");
void cascadePair(const Bq *c, BqState *sl, BqState *sr, uint32_t n, simd::f64x2 *x, uint32_t cn) {
    for (uint32_t i = 0; i < n; ++i) simd::biquadPair(&c[i].b0, sl[i].z1, sl[i].z2, &sr[i].z1, &sr[i].z2, x, cn);
}
void roundToFloat(simd::f64x2 *x, uint32_t cn) {
    for (uint32_t i = 0; i < cn; ++i) x[i] = simd::pair(static_cast<double>(static_cast<float>(simd::lane(x[i], 0))), static_cast<double>(static_cast<float>(simd::lane(x[i], 1))));
}
void storePair(const simd::f64x2 *x, float *l, float *r, uint32_t cn) {
    for (uint32_t i = 0; i < cn; ++i) {
        l[i] = static_cast<float>(simd::lane(x[i], 0));
        r[i] = static_cast<float>(simd::lane(x[i], 1));
    }
}

// E28 S7d, G35: one lookahead delay as block passes. Reads the oldest `n` samples into `out` and writes `in` (non-finite values
// stored as zero, so they are never replayed `len` frames later), in contiguous runs; returns the new position.
uint32_t ringExchange(float *ring, uint32_t len, uint32_t pos, const float *in, float *out, uint32_t n) {
    uint32_t done = 0;
    if (pos >= len) pos = 0;
    while (done < n) {
        const uint32_t run = std::min(n - done, len - pos);
        std::memcpy(out + done, ring + pos, size_t(run) * sizeof(float));
        for (uint32_t k = 0; k < run; ++k) ring[pos + k] = std::isfinite(in[done + k]) ? in[done + k] : 0.0f;
        done += run;
        pos += run;
        if (pos == len) pos = 0;
    }
    return pos;
}

constexpr uint32_t kChunk = 128;

}  // namespace

bool isMultibandKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_MULTIBAND; }

bool multibandParamOk(uint32_t idx, float v, double rate) {
    if (idx == kOn || idx == kBandSplit || idx == kLowSlope || idx == kHighSlope || idx == kSlope2 || idx == kSlope3) return isFlag(v);
    if (idx == kBandCount) return v == 2.0f || v == 3.0f || v == 4.0f || v == 5.0f;
    if (idx == kLowMidHz || idx == kMidHighHz || idx == kCorner2 || idx == kCorner3) return inR(v, 40.0, 16000.0) && double(v) < rate * 0.45;
    if (idx == kWindow) return inR(v, 5.0, 200.0);
    if (idx == kLookahead) return inR(v, 0.0, double(kMaxLookahead)) && v == std::floor(v);
    uint32_t kind;
    if (idx >= kBandBase && idx < kWindow) kind = (idx - kBandBase) / 3;
    else if (idx >= kExtBase && idx < kParamsN) kind = (idx - kExtBase) / 2;
    else return false;
    // The wideband compressor's limits (E33 decision 4).
    switch (kind) {
        case kThr: return inR(v, -96.0, 0.0);
        case kRatio: return inR(v, 1.0, 100.0);
        case kAtk: return inR(v, 0.05, 1000.0);
        case kRel: return inR(v, 1.0, 5000.0);
        case kKnee: return inR(v, 0.0, 24.0);
        case kSc: return inR(v, 0.0, 300.0) && double(v) < rate * 0.45;
        case kMk: return inR(v, -24.0, 24.0);
        case kListenK: return v == 0.0f || v == 1.0f || v == 2.0f;
        default: return isFlag(v);  // auto release, bypass, solo, detector
    }
}

n60_status validateMultibandStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0) || !isMultibandKind(s.kind) || s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneMask != 0 || s.laneA >= outCh || s.laneB >= outCh || s.laneA == s.laneB) return N60_STATUS_BAD_ARGUMENT;
    if (s.params == nullptr || (s.paramCount != kParams && s.paramCount != kParamsX && s.paramCount != kParamsS && s.paramCount != kParamsN)) return N60_STATUS_BAD_ARGUMENT;
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!multibandParamOk(i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    Eff e;
    decode(s.params, s.paramCount, e);
    // The used corners ascend, at least half an octave apart (the unused ones only need to be in range).
    for (uint32_t c = 0; c + 2 < e.n; ++c) {
        if (!(double(e.corner[c + 1]) >= double(e.corner[c]) * kMinRatio * (1.0 - 1.0e-6))) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void multibandSizes(const n60_stage_desc &s, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(sizeof(MbShared)) + up(size_t(2) * bandsOf(s) * lookaheadOf(s) * sizeof(float));
}

uint32_t multibandLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING {
    return r.paramCount >= kParamsX ? static_cast<uint32_t>(paramsOf(h, r)[kLookahead]) : 0u;
}

void multibandInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    MbShared &S = *new (sharedState(h, r)) MbShared{};
    Eff e;
    decode(p, r.paramCount, e);
    S.n = e.n;
    S.bypassCoef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    S.parked = 1;
    for (uint32_t b = 0; b < kBands; ++b) S.soloG[b] = 1.0f;
    S.split = (e.n != 3 || (r.paramCount >= kParamsS && p[kBandSplit] > 0.5f)) ? 1u : 0u;
    if (r.paramCount >= kParamsX) {
        S.ringLen = static_cast<uint32_t>(p[kLookahead]);
        for (uint32_t b = 0; b < e.n; ++b) {
            S.listenSide[b] = e.v[kListenK][b] == 1.0f ? 1.0f : 0.0f;
            S.listenDelta[b] = e.v[kListenK][b] == 2.0f ? 1.0f : 0.0f;
        }
    }
    const float slopes[kCorners] = {p[kLowSlope], p[kHighSlope], r.paramCount >= kParamsN ? p[kSlope2] : 0.0f, r.paramCount >= kParamsN ? p[kSlope3] : 0.0f};
    for (uint32_t c = 0; c + 1 < e.n; ++c) {
        S.lr8[c] = slopes[c] > 0.5f ? 1u : 0u;
        designCorner(S, rate, c, e.corner[c]);
    }
    for (uint32_t b = 0; b < e.n; ++b) {
        designHpf(S, rate, b, e.v[kSc][b]);
        S.attackPole[b] = poleForMs(rate, e.v[kAtk][b]);
        S.seenAttack[b] = e.v[kAtk][b];
        const float rel = e.v[kRel][b];
        S.releasePole[b] = poleForMs(rate, rel);
        S.fastPole[b] = poleForMs(rate, std::fmax(rel * 0.5f, 1.0f));
        S.slowPole[b] = poleForMs(rate, std::fmin(rel * 2.0f, 5000.0f));
        S.seenRelease[b] = rel;
    }
}

uint64_t multibandCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING {
    uint64_t bytes = 0;
    if (from == nullptr || to == nullptr || from->sampleRate != to->sampleRate) return bytes;
    const StageRec *src = stages(from);
    StageRec *dst = stages(to);
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (dst[i].kind != N60_STAGE_MULTIBAND) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != N60_STAGE_MULTIBAND || src[j].id != dst[i].id) continue;
            const MbShared &a = *reinterpret_cast<const MbShared *>(sharedState(from, src[j]));
            MbShared &b = *reinterpret_cast<MbShared *>(sharedState(to, dst[i]));
            if (a.n != b.n) break;  // a band-count change is a rebuild with the normal fade: the new bands start clean (E33 S5b)
            bytes += sizeof(MbShared);
            if (a.split == b.split) {
                std::memcpy(&b.st, &a.st, sizeof b.st);
                if (b.split != 0) b.splitMix = a.splitMix;
            } else {
                // The split mode is topology: only the residual mode's own filters (low-pass 0, high-pass 1) carry across it.
                std::memcpy(b.st.lpL[0], a.st.lpL[0], sizeof b.st.lpL[0]);
                std::memcpy(b.st.lpR[0], a.st.lpR[0], sizeof b.st.lpR[0]);
                std::memcpy(b.st.hpL[1], a.st.hpL[1], sizeof b.st.hpL[1]);
                std::memcpy(b.st.hpR[1], a.st.hpR[1], sizeof b.st.hpR[1]);
            }
            std::memcpy(b.hpL, a.hpL, sizeof b.hpL);
            std::memcpy(b.hpR, a.hpR, sizeof b.hpR);
            std::memcpy(b.gainDb, a.gainDb, sizeof b.gainDb);
            b.parked = a.parked;
            std::memcpy(b.soloG, a.soloG, sizeof b.soloG);
            std::memcpy(b.listenSide, a.listenSide, sizeof b.listenSide);
            std::memcpy(b.listenDelta, a.listenDelta, sizeof b.listenDelta);
            std::memcpy(b.meanSq, a.meanSq, sizeof b.meanSq);
            std::memcpy(b.lhpL, a.lhpL, sizeof b.lhpL);
            std::memcpy(b.lhpR, a.lhpR, sizeof b.lhpR);
            if (b.ringLen != 0 && a.ringLen != 0 && a.split == b.split) {  // slot 0 holds mid in split mode: carry only within one mode
                // The lookahead is topology, so a change rebuilds: carry the most recent min(old, new) frames of each ring, aligned
                // by age (oldest first, read position 0). A longer new ring starts with zeros (the extra delay is silence).
                const float *ra = ringsOf(const_cast<MbShared &>(a));
                float *rb = ringsOf(b);
                const uint32_t la = a.ringLen, lb = b.ringLen, rings = 2 * b.n;
                for (uint32_t r6 = 0; r6 < rings; ++r6) {
                    const float *s = ra + size_t(r6) * la;
                    float *dstp = rb + size_t(r6) * lb;
                    for (uint32_t k = 0; k < lb; ++k) {
                        const uint32_t age = lb - k;  // 1 is the newest sample
                        dstp[k] = age <= la ? s[(a.ringPos + la - age) % la] : 0.0f;
                    }
                }
                b.ringPos = 0;
                bytes += size_t(rings) * lb * sizeof(float);
            }
            for (uint32_t k = 0; k < kBands; ++k) {
                b.grNowBits[k].store(a.grNowBits[k].load(std::memory_order_relaxed), std::memory_order_relaxed);
            }
            break;
        }
    }
    return bytes;
}

// E20 S3: denormals are flushed in hardware (platform/fpenv.hpp, the guard in n60_graph_process), so no per-block flush.
static_assert(std::atomic<uint32_t>::is_always_lock_free, "telemetry atomics must be lock free");

namespace {
// One crossover split of a chunk through the set (c, s) into `n` bands (output pointers per band; in the residual mode
// band 1 is left to the caller, which forms dry - low - high). Band-pass tree (E28 G42, generalised to N bands in E33 S5b): from the
// top corner down, band c+1 = AP_0..AP_{c-1}(HP_c(y_{c+1})) and y_c = LP_c(y_{c+1}), with y_{n-1} = x; the lowest corner then
// gives the two bottom bands LP_0(y_1) and HP_0(y_1). Each band holds only its own range and the sum is AP_0.AP_1... (flat).
void splitChunk(const XCoef &k, XState &s, const uint32_t *sec, const uint32_t *apN, uint32_t n, bool tree, const simd::f64x2 *xin, uint32_t cn,
                float *const *bl, float *const *br) N60_RT_NONBLOCKING {
    simd::f64x2 y[kChunk], t[kChunk];
    if (!tree) {
        // Residual three-band mode: low = LP_0 x, high = HP_1 x.
        std::memcpy(y, xin, sizeof(simd::f64x2) * cn);
        cascadePair(k.lp[0], s.lpL[0], s.lpR[0], sec[0], y, cn);
        storePair(y, bl[0], br[0], cn);
        std::memcpy(t, xin, sizeof(simd::f64x2) * cn);
        cascadePair(k.hp[1], s.hpL[1], s.hpR[1], sec[1], t, cn);
        storePair(t, bl[2], br[2], cn);
        return;
    }
    std::memcpy(y, xin, sizeof(simd::f64x2) * cn);
    for (uint32_t c = n - 2; c >= 1; --c) {
        std::memcpy(t, y, sizeof(simd::f64x2) * cn);
        cascadePair(k.hp[c], s.hpL[c], s.hpR[c], sec[c], t, cn);
        roundToFloat(t, cn);
        for (uint32_t a = 0; a < c; ++a) cascadePair(k.ap[a], s.apL[apPair(c + 1, a)], s.apR[apPair(c + 1, a)], apN[a], t, cn);
        storePair(t, bl[c + 1], br[c + 1], cn);
        cascadePair(k.lp[c], s.lpL[c], s.lpR[c], sec[c], y, cn);
        roundToFloat(y, cn);
    }
    std::memcpy(t, y, sizeof(simd::f64x2) * cn);
    cascadePair(k.lp[0], s.lpL[0], s.lpR[0], sec[0], t, cn);
    storePair(t, bl[0], br[0], cn);
    cascadePair(k.hp[0], s.hpL[0], s.hpR[0], sec[0], y, cn);
    storePair(y, bl[1], br[1], cn);
}
}  // namespace

void runMultiband(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    const float *p = paramsOf(h, r);
    MbShared &S = *reinterpret_cast<MbShared *>(sharedState(h, r));
    const double rate = h->sampleRate;
    float *L = lanes[r.laneA];
    float *R = lanes[r.laneB];
    const bool enabled = p[kOn] > 0.5f;
    if (!enabled && S.parked != 0) return;
    Eff e;
    decode(p, r.paramCount, e);
    const uint32_t N = S.n;
    {
        bool cornerEdit = false;
        for (uint32_t c = 0; c + 1 < N; ++c) cornerEdit = cornerEdit || e.corner[c] != S.seenCorner[c];
        if (cornerEdit) {
            // The slopes are topology (fixed at build), so the section counts do not change here.
            if (S.xActive == 0) {
                // E32 S4 (R10): keep the previous filters (coefficients and state) for a 5 ms crossfade to the new ones.
                std::memcpy(&S.oCoef, &S.coef, sizeof S.coef);
                std::memcpy(&S.oSt, &S.st, sizeof S.st);
                S.xw = 0.0;
                S.xActive = 1;
            }
            for (uint32_t c = 0; c + 1 < N; ++c) {
                if (e.corner[c] != S.seenCorner[c]) designCorner(S, rate, c, e.corner[c]);
            }
        }
    }
    for (uint32_t b = 0; b < N; ++b) {
        if (e.v[kSc][b] != S.seenHpf[b]) designHpf(S, rate, b, e.v[kSc][b]);
        if (e.v[kAtk][b] != S.seenAttack[b]) {
            S.attackPole[b] = poleForMs(rate, e.v[kAtk][b]);
            S.seenAttack[b] = e.v[kAtk][b];
        }
        if (e.v[kRel][b] != S.seenRelease[b]) {
            const float rel = e.v[kRel][b];
            S.releasePole[b] = poleForMs(rate, rel);
            S.fastPole[b] = poleForMs(rate, std::fmax(rel * 0.5f, 1.0f));
            S.slowPole[b] = poleForMs(rate, std::fmin(rel * 2.0f, 5000.0f));
            S.seenRelease[b] = rel;
        }
    }
    if (enabled && S.parked != 0) {
        clearState(S);
        for (uint32_t b = 0; b < kBands; ++b) S.gainDb[b] = 0.0f;
        S.parked = 0;
    }
    float grMax[kBands] = {0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
    // ABI v37 (E28 S7c). With the 29-value block every extra below is at its default and the arithmetic is the v25 one.
    const bool x = r.paramCount >= kParamsX;
    const uint32_t ringLen = x ? S.ringLen : 0;
    const bool split = S.split != 0;
    const bool three = N == 3;  // ring slots and the residual mid are the three-band layout; other counts use one slot per band
    const double mixTarget = enabled ? 1.0 : 0.0;
    const double mixPole = std::exp(-1.0 / (rate * 0.005));
    float *rings = ringLen != 0 ? ringsOf(S) : nullptr;
    const float rampC = static_cast<float>(poleForMs(rate, 5.0f));
    const double rmsC = x ? std::exp(-1.0 / (rate * (double(std::min(std::max(e.window, 0.05f), 5000.0f)) / 1000.0))) : 0.0;
    bool soloAny = false;
    float soloT[kBands], sideT[kBands], deltaT[kBands], mk[kBands];
    bool bypass[kBands], rms[kBands];
    bool listening = false;
    for (uint32_t b = 0; b < kBands; ++b) {
        soloT[b] = 1.0f; sideT[b] = deltaT[b] = mk[b] = 0.0f;
        bypass[b] = rms[b] = false;
    }
    for (uint32_t b = 0; b < N; ++b) {
        soloAny = soloAny || (x && e.v[kSolo][b] > 0.5f);
        bypass[b] = x && e.v[kByp][b] > 0.5f;
        rms[b] = x && e.v[kDet][b] > 0.5f;
        sideT[b] = x && e.v[kListenK][b] == 1.0f ? 1.0f : 0.0f;
        deltaT[b] = x && e.v[kListenK][b] == 2.0f ? 1.0f : 0.0f;
        mk[b] = bypass[b] ? 0.0f : e.v[kMk][b];
        if (sideT[b] == 0.0f && S.listenSide[b] == 0.0f) {  // not listened: the sidechain filter state starts clean
            S.lhpL[b] = BqState{};
            S.lhpR[b] = BqState{};
        }
        listening = listening || sideT[b] != 0.0f || deltaT[b] != 0.0f || S.listenSide[b] != 0.0f || S.listenDelta[b] != 0.0f;
    }
    for (uint32_t b = 0; b < N; ++b) soloT[b] = (soloAny && e.v[kSolo][b] < 0.5f) ? 0.0f : 1.0f;
    bool parkedNow = false;
    for (uint32_t base = 0; base < frames && !parkedNow; base += kChunk) {
        const uint32_t cn = std::min(kChunk, frames - base);
        // Pass 1: the crossover split of the block (the IIR state is sequential, the rest is not).
        float dryLa[kChunk], dryRa[kChunk];
        float bandLa[kBands][kChunk], bandRa[kBands][kChunk];  // residual mode leaves band 1 for the per-sample loop
        float *bl[kBands], *br[kBands];
        for (uint32_t b = 0; b < kBands; ++b) { bl[b] = bandLa[b]; br[b] = bandRa[b]; }
        simd::f64x2 xin[kChunk];
        for (uint32_t c = 0; c < cn; ++c) {
            dryLa[c] = L[base + c];
            dryRa[c] = R[base + c];
            xin[c] = simd::toDouble(dryLa[c], dryRa[c]);
        }
        splitChunk(S.coef, S.st, S.sec, S.apN, N, split, xin, cn, bl, br);
        if (S.xActive != 0) {
            // E32 S4 (R10): the previous crossover keeps running; the bands blend to the new one over 5 ms (linear, exact end).
            float oLa[kBands][kChunk], oRa[kBands][kChunk];
            float *ol[kBands], *orr[kBands];
            for (uint32_t b = 0; b < kBands; ++b) { ol[b] = oLa[b]; orr[b] = oRa[b]; }
            splitChunk(S.oCoef, S.oSt, S.sec, S.apN, N, split, xin, cn, ol, orr);
            const double step = 1.0 / (rate * 0.005);
            double w = S.xw;
            for (uint32_t c = 0; c < cn; ++c) {
                w = std::fmin(1.0, w + step);
                const float wf = static_cast<float>(w);
                for (uint32_t b = 0; b < N; ++b) {
                    if (!split && b == 1) continue;  // the residual mid is formed after the blend
                    bandLa[b][c] = oLa[b][c] + wf * (bandLa[b][c] - oLa[b][c]);
                    bandRa[b][c] = oRa[b][c] + wf * (bandRa[b][c] - oRa[b][c]);
                }
            }
            S.xw = w;
            if (w >= 1.0) S.xActive = 0;
        }
        // Pass 2: one lookahead for the whole stage. The detectors read the undelayed bands, the audio path the delayed ones,
        // so the bands stay aligned and the crossover sum stays flat. Three bands keep the original ring slots (slot 0 the mid
        // band in split mode, dry otherwise, then low, high); other counts hold one slot per band.
        float oSlotL[kBands][kChunk], oSlotR[kBands][kChunk];
        if (ringLen != 0) {
            const uint32_t pos = S.ringPos;
            uint32_t np = pos;
            float *rl = rings, *rr = rings + size_t(N) * ringLen;
            for (uint32_t j = 0; j < N; ++j) {
                const float *sl, *sr;
                if (three) {
                    sl = j == 0 ? (split ? bandLa[1] : dryLa) : (j == 1 ? bandLa[0] : bandLa[2]);
                    sr = j == 0 ? (split ? bandRa[1] : dryRa) : (j == 1 ? bandRa[0] : bandRa[2]);
                } else {
                    sl = bandLa[j];
                    sr = bandRa[j];
                }
                ringExchange(rl + size_t(j) * ringLen, ringLen, pos, sl, oSlotL[j], cn);
                np = ringExchange(rr + size_t(j) * ringLen, ringLen, pos, sr, oSlotR[j], cn);
            }
            S.ringPos = np;
        }
        for (uint32_t c = 0; c < cn; ++c) {
        const uint32_t i = base + c;
        const float dryL = dryLa[c], dryR = dryRa[c];
        float bandL[kBands], bandR[kBands];
        for (uint32_t b = 0; b < N; ++b) { bandL[b] = bandLa[b][c]; bandR[b] = bandRa[b][c]; }
        if (three && !split) {
            bandL[1] = dryL - bandL[0] - bandL[2];
            bandR[1] = dryR - bandR[0] - bandR[2];
        }
        float dBandL[kBands], dBandR[kBands];
        for (uint32_t b = 0; b < N; ++b) { dBandL[b] = bandL[b]; dBandR[b] = bandR[b]; }
        if (ringLen != 0) {
            if (three) {
                dBandL[0] = oSlotL[1][c]; dBandL[1] = split ? oSlotL[0][c] : oSlotL[0][c] - oSlotL[1][c] - oSlotL[2][c]; dBandL[2] = oSlotL[2][c];
                dBandR[0] = oSlotR[1][c]; dBandR[1] = split ? oSlotR[0][c] : oSlotR[0][c] - oSlotR[1][c] - oSlotR[2][c]; dBandR[2] = oSlotR[2][c];
            } else {
                for (uint32_t b = 0; b < N; ++b) { dBandL[b] = oSlotL[b][c]; dBandR[b] = oSlotR[b][c]; }
            }
        }
        float outL = 0.0f, outR = 0.0f;
        float lsL = 0.0f, lsR = 0.0f, wSum = 0.0f;
        bool neutral = true;
        for (uint32_t b = 0; b < N; ++b) {
            float targetDb = 0.0f;
            if (enabled) {
                const float detL = runBq(S.hp[b], S.hpL[b], bandL[b]);
                const float detR = runBq(S.hp[b], S.hpR[b], bandR[b]);
                float detector = std::fmax(std::fabs(detL), std::fabs(detR));
                if (rms[b]) {
                    const double yy = std::fmin(detector, 1.0e6f);
                    S.meanSq[b] = yy * yy + rmsC * (S.meanSq[b] - yy * yy);
                    if (S.meanSq[b] < 1e-30) S.meanSq[b] = 0.0;  // no denormals in silence
                    detector = static_cast<float>(std::sqrt(std::fmax(S.meanSq[b], 0.0)));
                }
                if (!bypass[b]) {
                    targetDb = bandTarget(linearToDb(detector), e.v[kThr][b], e.v[kRatio][b], e.v[kKnee][b]);
                    targetDb += e.v[kMk][b];
                }
            }
            double coef;
            if (!enabled) {
                coef = S.bypassCoef;
            } else if (targetDb < S.gainDb[b]) {
                coef = S.attackPole[b];
            } else if (e.v[kAuto][b] > 0.5f) {
                const float depth = std::fmin(std::fmax(-S.gainDb[b] / 12.0f, 0.0f), 1.0f);
                coef = S.fastPole[b] + depth * (S.slowPole[b] - S.fastPole[b]);
            } else {
                coef = S.releasePole[b];
            }
            S.gainDb[b] = smoothToward(S.gainDb[b], targetDb, coef);
            if (nearZero(S.gainDb[b])) S.gainDb[b] = 0.0f;
            else neutral = false;
            const float gain = dbToLinear(S.gainDb[b]);
            if (x) {
                // Solo: a 0/1 band gain ramped over 5 ms (soloed bands sum). Exactly 1 when no band is soloed.
                const float v = soloT[b] + rampC * (S.soloG[b] - soloT[b]);
                S.soloG[b] = std::fabs(v - soloT[b]) < 1.0e-6f ? soloT[b] : v;
            }
            const float sg = S.soloG[b];
            outL += dBandL[b] * gain * sg;
            outR += dBandR[b] * gain * sg;
            if (listening) {
                // Listen: the delayed band after its sidechain filter, or what the stage removed from it (dry minus wet
                // before make-up). Ramped over 5 ms; the listened signal never carries make-up or the solo gain.
                float &wS = S.listenSide[b], &wD = S.listenDelta[b];
                wS = sideT[b] + rampC * (wS - sideT[b]);
                if (std::fabs(wS - sideT[b]) < 1.0e-6f) wS = sideT[b];
                wD = deltaT[b] + rampC * (wD - deltaT[b]);
                if (std::fabs(wD - deltaT[b]) < 1.0e-6f) wD = deltaT[b];
                if (wS != 0.0f) {
                    lsL += wS * runBq(S.hp[b], S.lhpL[b], dBandL[b]);
                    lsR += wS * runBq(S.hp[b], S.lhpR[b], dBandR[b]);
                    wSum += wS;
                }
                if (wD != 0.0f) {
                    const float removed = 1.0f - dbToLinear(S.gainDb[b] - mk[b]);
                    lsL += wD * dBandL[b] * removed;
                    lsR += wD * dBandR[b] * removed;
                    wSum += wD;
                }
            }
            const float gr = std::fmax(0.0f, mk[b] - S.gainDb[b]);  // E32 S4 (R8): reduction without make-up
            grMax[b] = gr > grMax[b] ? gr : grMax[b];
        }
        // With a lookahead the stage keeps running (it is the delay) so the audio does not jump when it would park.
        if (split && ringLen == 0) {
            // The tree's sum carries the all-pass phase, so the stage fades against the dry signal on enable and disable
            // and parks only once dry (a step at park would be the all-pass difference).
            S.splitMix = mixTarget + mixPole * (S.splitMix - mixTarget);
            if (std::fabs(S.splitMix - mixTarget) < 1.0e-9) S.splitMix = mixTarget;
            if (S.splitMix != 1.0) {
                const float mix = static_cast<float>(S.splitMix);
                outL = dryL + mix * (outL - dryL);
                outR = dryR + mix * (outR - dryR);
            }
            if (!enabled && neutral && S.splitMix != 0.0) neutral = false;
        }
        if (!enabled && neutral && ringLen == 0) {
            clearState(S);
            S.parked = 1;
            parkedNow = true;
            break;
        }
        if (listening && wSum != 0.0f) {
            const float keep = std::fmax(0.0f, 1.0f - wSum);
            outL = keep * outL + lsL;
            outR = keep * outR + lsR;
        }
        L[i] = outL;
        R[i] = outR;
        }
    }
    for (uint32_t b = 0; b < N; ++b) {
        S.grNowBits[b].store(floatToBits(std::fmax(0.0f, mk[b] - S.gainDb[b])), std::memory_order_relaxed);
        atomicMaxFloat(S.grMaxBits[b], grMax[b]);
    }
}

n60_status validateMultibandParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount || !multibandParamOk(idx, value, h->sampleRate)) return N60_STATUS_BAD_ARGUMENT;
    // Topology: the slopes, the lookahead, the band split and the band count need a rebuild. Corners are live (range only here;
    // the build checks their order, and a live edit that crosses a neighbour is the caller's to avoid).
    return (idx == kLowSlope || idx == kHighSlope || idx == kSlope2 || idx == kSlope3 || idx == kLookahead || idx == kBandSplit || idx == kBandCount)
               ? N60_STATUS_UNSUPPORTED : N60_STATUS_OK;
}

bool readMultiband(const SnapHeader *h, uint32_t stageId, n60_multiband_readback *out) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_MULTIBAND) return false;
    MbShared &S = *reinterpret_cast<MbShared *>(sharedState(const_cast<SnapHeader *>(h), *r));
    for (uint32_t b = 0; b < kBands; ++b) {
        out->grMaxDb[b] = bitsToFloat(S.grMaxBits[b].exchange(0, std::memory_order_relaxed));
        out->grNowDb[b] = bitsToFloat(S.grNowBits[b].load(std::memory_order_relaxed));
    }
    out->bandCount = S.n;
    return true;
}

}  // namespace n60
