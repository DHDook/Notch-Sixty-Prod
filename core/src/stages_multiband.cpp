// libn60core ABI v25 multiband compressor stage (E6 S12d): the stereo kernel's three-band compressor, ported from
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
//    block start a changed parameter redesigns its coefficients (at most 11 biquads: bounded libm, no allocation).
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
constexpr uint32_t kBands = 3;
constexpr uint32_t kMaxSections = 4;

enum MbParam : uint32_t {
    kOn = 0,           // 0/1
    kLowMidHz = 1,     // 40..250
    kMidHighHz = 2,    // 1000..8000
    kLowSlope = 3,     // 0 LR4, 1 LR8 (topology: not live)
    kHighSlope = 4,    // 0 LR4, 1 LR8 (topology: not live)
    kThreshold = 5,    // 3 bands, -60..0 dB
    kRatio = 8,        // 3 bands, 1..20
    kAttack = 11,      // 3 bands, 1..200 ms
    kRelease = 14,     // 3 bands, 10..1000 ms
    kKnee = 17,        // 3 bands, 0..20 dB
    kSidechain = 20,   // 3 bands, 0..300 Hz (0 off)
    kMakeup = 23,      // 3 bands, -12..12 dB
    kAutoRelease = 26, // 3 bands, 0/1
    kBypass = 29,      // ABI v37: 3 bands, 0/1 (band at unity)
    kSolo = 32,        // ABI v37: 3 bands, 0/1 (live; session state in Swift)
    kListen = 35,      // ABI v37: 3 bands, 0 off, 1 sidechain, 2 delta (live; session state in Swift)
    kDetector = 38,    // ABI v37: 3 bands, 0 peak, 1 RMS
    kWindow = 41,      // ABI v37: RMS window ms, 5..200
    kLookahead = 42,   // ABI v37: lookahead frames, 0..8192 (topology: not live)
    kBandSplit = 43,   // E28 G42: 0 residual mid (dry - low - high), 1 band-pass tree (topology: not live)
    kParams = 29,      // the v25 block
    kParamsX = 43,     // the v37 block
    kParamsS = 44      // the v37 block plus the band-split mode (E28 G42, no ABI number)
};
constexpr uint32_t kMaxLookahead = 16384;  // 20 ms at 768 kHz is 15,360 frames

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

struct MbShared {
    float bypassCoef;
    uint32_t parked;
    uint32_t lowN, highN;  // LR4 = 2 sections, LR8 = 4; fixed by the snapshot
    float seenLowMid, seenMidHigh;
    Bq lowPass[kMaxSections], highPass[kMaxSections];
    BqState lowL[kMaxSections], lowR[kMaxSections], highL[kMaxSections], highR[kMaxSections];
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
    // E28 G42 band-pass tree (split == 1): low = LP1(LP2 x), mid = HP1(LP2 x), high = AP1(HP2 x), the allpass AP1 having
    // the phase of the low crossover (LP1 + HP1), so the bands sum to AP1.AP2 (flat). lowPass/highPass above are LP1 and
    // HP2; these are LP2 (the high crossover's low-pass), HP1 and AP1 (half the low crossover's sections). The ring's
    // first slot holds the mid band in this mode. Zero in the residual mode. The mix ramps the stage in and out against the
    // dry signal (no lookahead only), so parking cannot step by the allpass phase.
    uint32_t split;
    uint32_t apN;
    double splitMix;  // double: a float one-pole stalls short of 1 at high rates (its step falls under half an ulp)
    Bq lp2[kMaxSections], hp1[kMaxSections], ap1[kMaxSections / 2];
    BqState lp2L[kMaxSections], lp2R[kMaxSections], hp1L[kMaxSections], hp1R[kMaxSections];
    BqState ap1L[kMaxSections / 2], ap1R[kMaxSections / 2];
};

uint32_t lookaheadOf(const n60_stage_desc &s) {
    return (s.params != nullptr && s.paramCount >= kParamsX) ? static_cast<uint32_t>(s.params[kLookahead]) : 0u;
}
// Six rings of ringLen floats after the struct: dry, low, high for the left lane, then for the right.
float *ringsOf(MbShared &S) { return reinterpret_cast<float *>(reinterpret_cast<uint8_t *>(&S) + up(sizeof(MbShared))); }

void designSplit(MbShared &S, double rate, float lowMid, float midHigh, bool lowLr8, bool highLr8) {
    double q[kMaxSections] = {};
    const uint32_t ln = sectionQs(lowLr8, q);
    for (uint32_t i = 0; i < kMaxSections; ++i) {
        S.lowPass[i] = identityBq();
        if (i < ln && !designBq(false, rate, double(lowMid), q[i], S.lowPass[i])) S.lowPass[i] = identityBq();
    }
    const uint32_t hn = sectionQs(highLr8, q);
    for (uint32_t i = 0; i < kMaxSections; ++i) {
        S.highPass[i] = identityBq();
        if (i < hn && !designBq(true, rate, double(midHigh), q[i], S.highPass[i])) S.highPass[i] = identityBq();
    }
    if (S.split != 0) {
        // LP2 has the high crossover's Qs (hn sections), HP1 the low crossover's (ln), AP1 half of them: LR4 is one
        // Q = 1/sqrt(2) section, LR8 the two Butterworth-4 sections (LP + HP of an LRn is the all-pass of Butterworth n/2).
        double qh[kMaxSections] = {};
        sectionQs(highLr8, qh);
        sectionQs(lowLr8, q);
        for (uint32_t i = 0; i < kMaxSections; ++i) {
            S.lp2[i] = identityBq();
            if (i < hn && !designBq(false, rate, double(midHigh), qh[i], S.lp2[i])) S.lp2[i] = identityBq();
            S.hp1[i] = identityBq();
            if (i < ln && !designBq(true, rate, double(lowMid), q[i], S.hp1[i])) S.hp1[i] = identityBq();
        }
        S.apN = lowLr8 ? 2u : 1u;
        for (uint32_t i = 0; i < kMaxSections / 2; ++i) {
            S.ap1[i] = identityBq();
            if (i < S.apN && !designAllPass(rate, double(lowMid), lowLr8 ? (i == 0 ? q[0] : q[1]) : kQ, S.ap1[i])) S.ap1[i] = identityBq();
        }
    }
    S.lowN = ln;
    S.highN = hn;
    S.seenLowMid = lowMid;
    S.seenMidHigh = midHigh;
}

void designHpf(MbShared &S, double rate, uint32_t b, float hz) {
    S.hp[b] = identityBq();
    if (hz > 0.0f && !designBq(true, rate, double(hz), kQ, S.hp[b])) S.hp[b] = identityBq();
    S.seenHpf[b] = hz;
}

void clearState(MbShared &S) {
    std::memset(S.lowL, 0, sizeof S.lowL);
    std::memset(S.lowR, 0, sizeof S.lowR);
    std::memset(S.highL, 0, sizeof S.highL);
    std::memset(S.highR, 0, sizeof S.highR);
    std::memset(S.hpL, 0, sizeof S.hpL);
    std::memset(S.hpR, 0, sizeof S.hpR);
    std::memset(S.meanSq, 0, sizeof S.meanSq);
    std::memset(S.lhpL, 0, sizeof S.lhpL);
    std::memset(S.lhpR, 0, sizeof S.lhpR);
    std::memset(S.lp2L, 0, sizeof S.lp2L);
    std::memset(S.lp2R, 0, sizeof S.lp2R);
    std::memset(S.hp1L, 0, sizeof S.hp1L);
    std::memset(S.hp1R, 0, sizeof S.hp1R);
    std::memset(S.ap1L, 0, sizeof S.ap1L);
    std::memset(S.ap1R, 0, sizeof S.ap1R);
    S.splitMix = 0.0;
    if (S.ringLen != 0) std::memset(ringsOf(S), 0, size_t(6) * S.ringLen * sizeof(float));
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
    if (idx == kOn || (idx >= kAutoRelease && idx < kAutoRelease + kBands)) return isFlag(v);
    if ((idx >= kBypass && idx < kBypass + kBands) || (idx >= kSolo && idx < kSolo + kBands)) return isFlag(v);
    if (idx >= kListen && idx < kListen + kBands) return v == 0.0f || v == 1.0f || v == 2.0f;
    if (idx >= kDetector && idx < kDetector + kBands) return isFlag(v);
    if (idx == kWindow) return inR(v, 5.0, 200.0);
    if (idx == kLookahead) return inR(v, 0.0, double(kMaxLookahead)) && v == std::floor(v);
    if (idx == kLowMidHz) return inR(v, 40.0, 250.0) && double(v) < rate * 0.45;
    if (idx == kMidHighHz) return inR(v, 1000.0, 8000.0) && double(v) < rate * 0.45;
    if (idx == kLowSlope || idx == kHighSlope || idx == kBandSplit) return isFlag(v);
    if (idx >= kThreshold && idx < kThreshold + kBands) return inR(v, -60.0, 0.0);
    if (idx >= kRatio && idx < kRatio + kBands) return inR(v, 1.0, 20.0);
    if (idx >= kAttack && idx < kAttack + kBands) return inR(v, 1.0, 200.0);
    if (idx >= kRelease && idx < kRelease + kBands) return inR(v, 10.0, 1000.0);
    if (idx >= kKnee && idx < kKnee + kBands) return inR(v, 0.0, 20.0);
    if (idx >= kSidechain && idx < kSidechain + kBands) return inR(v, 0.0, 300.0) && double(v) < rate * 0.45;
    if (idx >= kMakeup && idx < kMakeup + kBands) return inR(v, -12.0, 12.0);
    return false;
}

n60_status validateMultibandStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0) || !isMultibandKind(s.kind) || s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneMask != 0 || s.laneA >= outCh || s.laneB >= outCh || s.laneA == s.laneB) return N60_STATUS_BAD_ARGUMENT;
    if (s.params == nullptr || (s.paramCount != kParams && s.paramCount != kParamsX && s.paramCount != kParamsS)) return N60_STATUS_BAD_ARGUMENT;
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!multibandParamOk(i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void multibandSizes(const n60_stage_desc &s, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(sizeof(MbShared)) + up(size_t(6) * lookaheadOf(s) * sizeof(float));
}

uint32_t multibandLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING {
    return r.paramCount >= kParamsX ? static_cast<uint32_t>(paramsOf(h, r)[kLookahead]) : 0u;
}

void multibandInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    MbShared &S = *new (sharedState(h, r)) MbShared{};
    S.bypassCoef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    S.parked = 1;
    for (uint32_t b = 0; b < kBands; ++b) S.soloG[b] = 1.0f;
    S.split = (r.paramCount >= kParamsS && p[kBandSplit] > 0.5f) ? 1u : 0u;
    if (r.paramCount >= kParamsX) {
        S.ringLen = static_cast<uint32_t>(p[kLookahead]);
        for (uint32_t b = 0; b < kBands; ++b) {
            S.listenSide[b] = p[kListen + b] == 1.0f ? 1.0f : 0.0f;
            S.listenDelta[b] = p[kListen + b] == 2.0f ? 1.0f : 0.0f;
        }
    }
    designSplit(S, rate, p[kLowMidHz], p[kMidHighHz], p[kLowSlope] > 0.5f, p[kHighSlope] > 0.5f);
    for (uint32_t b = 0; b < kBands; ++b) {
        designHpf(S, rate, b, p[kSidechain + b]);
        S.attackPole[b] = poleForMs(rate, p[kAttack + b]);
        S.seenAttack[b] = p[kAttack + b];
        const float rel = p[kRelease + b];
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
            bytes += sizeof(MbShared);
            std::memcpy(b.lowL, a.lowL, sizeof b.lowL);
            std::memcpy(b.lowR, a.lowR, sizeof b.lowR);
            std::memcpy(b.highL, a.highL, sizeof b.highL);
            std::memcpy(b.highR, a.highR, sizeof b.highR);
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
            if (a.split == b.split && b.split != 0) {  // the split mode is topology: the tree's extra state carries only within it
                std::memcpy(b.lp2L, a.lp2L, sizeof b.lp2L);
                std::memcpy(b.lp2R, a.lp2R, sizeof b.lp2R);
                std::memcpy(b.hp1L, a.hp1L, sizeof b.hp1L);
                std::memcpy(b.hp1R, a.hp1R, sizeof b.hp1R);
                std::memcpy(b.ap1L, a.ap1L, sizeof b.ap1L);
                std::memcpy(b.ap1R, a.ap1R, sizeof b.ap1R);
                b.splitMix = a.splitMix;
            }
            if (b.ringLen != 0 && a.ringLen != 0 && a.split == b.split) {  // slot 0 holds mid in split mode: carry only within one mode
                // The lookahead is topology, so a change rebuilds: carry the most recent min(old, new) frames of each ring, aligned
                // by age (oldest first, read position 0). A longer new ring starts with zeros (the extra delay is silence).
                const float *ra = ringsOf(const_cast<MbShared &>(a));
                float *rb = ringsOf(b);
                const uint32_t la = a.ringLen, lb = b.ringLen;
                for (uint32_t r6 = 0; r6 < 6; ++r6) {
                    const float *src = ra + size_t(r6) * la;
                    float *dst = rb + size_t(r6) * lb;
                    for (uint32_t k = 0; k < lb; ++k) {
                        const uint32_t age = lb - k;  // 1 is the newest sample
                        dst[k] = age <= la ? src[(a.ringPos + la - age) % la] : 0.0f;
                    }
                }
                b.ringPos = 0;
                bytes += size_t(6) * lb * sizeof(float);
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

void runMultiband(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    const float *p = paramsOf(h, r);
    MbShared &S = *reinterpret_cast<MbShared *>(sharedState(h, r));
    const double rate = h->sampleRate;
    float *L = lanes[r.laneA];
    float *R = lanes[r.laneB];
    const bool enabled = p[kOn] > 0.5f;
    if (!enabled && S.parked != 0) return;
    if (p[kLowMidHz] != S.seenLowMid || p[kMidHighHz] != S.seenMidHigh) {
        // The slopes are topology (fixed at build), so the section counts do not change here.
        designSplit(S, rate, p[kLowMidHz], p[kMidHighHz], S.lowN == 4, S.highN == 4);
    }
    for (uint32_t b = 0; b < kBands; ++b) {
        if (p[kSidechain + b] != S.seenHpf[b]) designHpf(S, rate, b, p[kSidechain + b]);
        if (p[kAttack + b] != S.seenAttack[b]) {
            S.attackPole[b] = poleForMs(rate, p[kAttack + b]);
            S.seenAttack[b] = p[kAttack + b];
        }
        if (p[kRelease + b] != S.seenRelease[b]) {
            const float rel = p[kRelease + b];
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
    float grMax[kBands] = {0.0f, 0.0f, 0.0f};
    // ABI v37 (E28 S7c). With the 29-value block every extra below is at its default and the arithmetic is the v25 one.
    const bool x = r.paramCount >= kParamsX;
    const uint32_t ringLen = x ? S.ringLen : 0;
    const bool split = S.split != 0;
    const double mixTarget = enabled ? 1.0 : 0.0;
    const double mixPole = std::exp(-1.0 / (rate * 0.005));
    float *rings = ringLen != 0 ? ringsOf(S) : nullptr;
    const float rampC = static_cast<float>(poleForMs(rate, 5.0f));
    const double rmsC = x ? std::exp(-1.0 / (rate * (double(std::min(std::max(p[kWindow], 0.05f), 5000.0f)) / 1000.0))) : 0.0;
    bool soloAny = false;
    float soloT[kBands], sideT[kBands], deltaT[kBands], mk[kBands];
    bool bypass[kBands], rms[kBands];
    bool listening = false;
    for (uint32_t b = 0; b < kBands; ++b) {
        soloAny = soloAny || (x && p[kSolo + b] > 0.5f);
        bypass[b] = x && p[kBypass + b] > 0.5f;
        rms[b] = x && p[kDetector + b] > 0.5f;
        sideT[b] = x && p[kListen + b] == 1.0f ? 1.0f : 0.0f;
        deltaT[b] = x && p[kListen + b] == 2.0f ? 1.0f : 0.0f;
        mk[b] = bypass[b] ? 0.0f : p[kMakeup + b];
        if (sideT[b] == 0.0f && S.listenSide[b] == 0.0f) {  // not listened: the sidechain filter state starts clean
            S.lhpL[b] = BqState{};
            S.lhpR[b] = BqState{};
        }
        listening = listening || sideT[b] != 0.0f || deltaT[b] != 0.0f || S.listenSide[b] != 0.0f || S.listenDelta[b] != 0.0f;
    }
    for (uint32_t b = 0; b < kBands; ++b) soloT[b] = (soloAny && p[kSolo + b] < 0.5f) ? 0.0f : 1.0f;
    bool parkedNow = false;
    for (uint32_t base = 0; base < frames && !parkedNow; base += kChunk) {
        const uint32_t cn = std::min(kChunk, frames - base);
        // Pass 1: the crossover split of the block (the IIR state is sequential, the rest is not).
        float dryLa[kChunk], dryRa[kChunk], lowLa[kChunk], lowRa[kChunk], highLa[kChunk], highRa[kChunk];
        float midLa[kChunk], midRa[kChunk];  // split mode only: the true band-pass mid (E28 G42)
        simd::f64x2 xin[kChunk], xa[kChunk], xb[kChunk];
        for (uint32_t c = 0; c < cn; ++c) {
            dryLa[c] = L[base + c];
            dryRa[c] = R[base + c];
            xin[c] = simd::toDouble(dryLa[c], dryRa[c]);
        }
        if (split) {
            // Band-pass tree: split at the high corner, then split the lower part at the low corner; the high band takes
            // the low corner's all-pass so the three bands stay phase-consistent and sum flat. Each band holds only its
            // own range.
            std::memcpy(xa, xin, sizeof(simd::f64x2) * cn);
            cascadePair(S.lp2, S.lp2L, S.lp2R, S.highN, xa, cn);
            roundToFloat(xa, cn);
            std::memcpy(xb, xa, sizeof(simd::f64x2) * cn);
            cascadePair(S.lowPass, S.lowL, S.lowR, S.lowN, xa, cn);
            storePair(xa, lowLa, lowRa, cn);
            cascadePair(S.hp1, S.hp1L, S.hp1R, S.lowN, xb, cn);
            storePair(xb, midLa, midRa, cn);
            std::memcpy(xa, xin, sizeof(simd::f64x2) * cn);
            cascadePair(S.highPass, S.highL, S.highR, S.highN, xa, cn);
            roundToFloat(xa, cn);
            cascadePair(S.ap1, S.ap1L, S.ap1R, S.apN, xa, cn);
            storePair(xa, highLa, highRa, cn);
        } else {
            std::memcpy(xa, xin, sizeof(simd::f64x2) * cn);
            cascadePair(S.lowPass, S.lowL, S.lowR, S.lowN, xa, cn);
            storePair(xa, lowLa, lowRa, cn);
            cascadePair(S.highPass, S.highL, S.highR, S.highN, xin, cn);
            storePair(xin, highLa, highRa, cn);
        }
        // Pass 2: one lookahead for the whole stage. The detectors read the undelayed bands, the audio path the delayed ones,
        // so the bands stay aligned and the crossover sum stays flat. Ring slot 0 holds the mid band in split mode, dry otherwise.
        float oDryLa[kChunk], oDryRa[kChunk], oLowLa[kChunk], oLowRa[kChunk], oHighLa[kChunk], oHighRa[kChunk];
        if (ringLen != 0) {
            const uint32_t pos = S.ringPos;
            float *rl = rings, *rr = rings + size_t(3) * ringLen;
            ringExchange(rl, ringLen, pos, split ? midLa : dryLa, oDryLa, cn);
            ringExchange(rl + ringLen, ringLen, pos, lowLa, oLowLa, cn);
            ringExchange(rl + 2 * size_t(ringLen), ringLen, pos, highLa, oHighLa, cn);
            ringExchange(rr, ringLen, pos, split ? midRa : dryRa, oDryRa, cn);
            ringExchange(rr + ringLen, ringLen, pos, lowRa, oLowRa, cn);
            S.ringPos = ringExchange(rr + 2 * size_t(ringLen), ringLen, pos, highRa, oHighRa, cn);
        }
        for (uint32_t c = 0; c < cn; ++c) {
        const uint32_t i = base + c;
        const float dryL = dryLa[c], dryR = dryRa[c], lowL = lowLa[c], lowR = lowRa[c], highL = highLa[c], highR = highRa[c];
        const float midL = split ? midLa[c] : dryL - lowL - highL, midR = split ? midRa[c] : dryR - lowR - highR;
        const float bandL[kBands] = {lowL, midL, highL};
        const float bandR[kBands] = {lowR, midR, highR};
        float dBandL[kBands] = {bandL[0], bandL[1], bandL[2]};
        float dBandR[kBands] = {bandR[0], bandR[1], bandR[2]};
        if (ringLen != 0) {
            dBandL[0] = oLowLa[c]; dBandL[1] = split ? oDryLa[c] : oDryLa[c] - oLowLa[c] - oHighLa[c]; dBandL[2] = oHighLa[c];
            dBandR[0] = oLowRa[c]; dBandR[1] = split ? oDryRa[c] : oDryRa[c] - oLowRa[c] - oHighRa[c]; dBandR[2] = oHighRa[c];
        }
        float outL = 0.0f, outR = 0.0f;
        float lsL = 0.0f, lsR = 0.0f, wSum = 0.0f;
        bool neutral = true;
        for (uint32_t b = 0; b < kBands; ++b) {
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
                    targetDb = bandTarget(linearToDb(detector), p[kThreshold + b], p[kRatio + b], p[kKnee + b]);
                    targetDb += p[kMakeup + b];
                }
            }
            double coef;
            if (!enabled) {
                coef = S.bypassCoef;
            } else if (targetDb < S.gainDb[b]) {
                coef = S.attackPole[b];
            } else if (p[kAutoRelease + b] > 0.5f) {
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
            const float gr = std::fmax(0.0f, -S.gainDb[b]);
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
    for (uint32_t b = 0; b < kBands; ++b) {
        S.grNowBits[b].store(floatToBits(std::fmax(0.0f, -S.gainDb[b])), std::memory_order_relaxed);
        atomicMaxFloat(S.grMaxBits[b], grMax[b]);
    }
}

n60_status validateMultibandParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount || !multibandParamOk(idx, value, h->sampleRate)) return N60_STATUS_BAD_ARGUMENT;
    return (idx == kLowSlope || idx == kHighSlope || idx == kLookahead || idx == kBandSplit) ? N60_STATUS_UNSUPPORTED : N60_STATUS_OK;
}

bool readMultiband(const SnapHeader *h, uint32_t stageId, n60_multiband_readback *out) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_MULTIBAND) return false;
    MbShared &S = *reinterpret_cast<MbShared *>(sharedState(const_cast<SnapHeader *>(h), *r));
    for (uint32_t b = 0; b < kBands; ++b) {
        out->grMaxDb[b] = bitsToFloat(S.grMaxBits[b].exchange(0, std::memory_order_relaxed));
        out->grNowDb[b] = bitsToFloat(S.grNowBits[b].load(std::memory_order_relaxed));
    }
    out->reserved = 0;
    return true;
}

}  // namespace n60
