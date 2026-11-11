// libn60core ABI v25 multiband compressor stage (E6 S12d): the stereo kernel's three-band compressor, ported from
// N60Dynamics.c (process_multiband_compressor) with the same float arithmetic, so the output matches the kernel to
// rounding. One pair stage, N60_STAGE_MULTIBAND, at rank 9.9: after the de-esser, directly before the compressor, which
// is where the kernel runs it.
//
// Derivations (public specifications):
//  - Band split: Linkwitz-Riley low-pass at the low/mid corner and high-pass at the mid/high corner, each LR4 (two
//    cascaded 2nd-order Butterworth biquads, Q = 1/sqrt(2)) or LR8 (two cascaded 4th-order Butterworth filters, section
//    Qs 0.5412 and 1.3066; Linkwitz and Riley, JAES 1976). The mid band is the residual: dry - low - high.
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
//  - sample rate: 8 kHz to 768 kHz (tested 44.1 to 384 kHz). Coefficients and filter state are float, as the kernel's, so
//    the output matches it bit for bit (recorded in the ledger). Decayed state is flushed to zero once per block. At a
//    block start a changed parameter redesigns its coefficients (at most 11 biquads: bounded libm, no allocation).
//    Per-sample log10/pow are kernel-identical (hoisting them is deferred, as for the loudness stage).
//  - channels: a stereo pair (laneA, laneB), as the kernel.
//  - reset: a new snapshot starts parked and neutral; enabling from parked clears the state, as the kernel does. State is
//    not carried across a rebuild (ledger).
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
    kParams = 29
};

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

float smoothToward(float current, float target, float coef) { return target + coef * (current - target); }
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
float poleForMs(double rate, float ms) {
    const float safe = std::min(std::max(ms, 0.05f), 5000.0f);
    return static_cast<float>(std::exp(-1.0 / (rate * (double(safe) / 1000.0))));
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
    float attackPole[kBands], releasePole[kBands], fastPole[kBands], slowPole[kBands];
    float gainDb[kBands];
    std::atomic<uint32_t> grMaxBits[kBands];
    std::atomic<uint32_t> grNowBits[kBands];
};

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
}

float cascade(const Bq *c, BqState *st, uint32_t n, float in) {
    double out = static_cast<double>(in);
    for (uint32_t i = 0; i < n; ++i) out = runBqD(c[i], st[i], out);
    return static_cast<float>(out);
}

}  // namespace

bool isMultibandKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_MULTIBAND; }

bool multibandParamOk(uint32_t idx, float v, double rate) {
    if (idx == kOn || (idx >= kAutoRelease && idx < kAutoRelease + kBands)) return isFlag(v);
    if (idx == kLowMidHz) return inR(v, 40.0, 250.0) && double(v) < rate * 0.45;
    if (idx == kMidHighHz) return inR(v, 1000.0, 8000.0) && double(v) < rate * 0.45;
    if (idx == kLowSlope || idx == kHighSlope) return isFlag(v);
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
    if (s.params == nullptr || s.paramCount != kParams) return N60_STATUS_BAD_ARGUMENT;
    for (uint32_t i = 0; i < kParams; ++i) {
        if (!multibandParamOk(i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void multibandSizes(const n60_stage_desc &, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(sizeof(MbShared));
}

void multibandInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    MbShared &S = *new (sharedState(h, r)) MbShared{};
    S.bypassCoef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    S.parked = 1;
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
    for (uint32_t i = 0; i < frames; ++i) {
        const float dryL = L[i];
        const float dryR = R[i];
        const float lowL = cascade(S.lowPass, S.lowL, S.lowN, dryL);
        const float lowR = cascade(S.lowPass, S.lowR, S.lowN, dryR);
        const float highL = cascade(S.highPass, S.highL, S.highN, dryL);
        const float highR = cascade(S.highPass, S.highR, S.highN, dryR);
        const float bandL[kBands] = {lowL, dryL - lowL - highL, highL};
        const float bandR[kBands] = {lowR, dryR - lowR - highR, highR};
        float outL = 0.0f, outR = 0.0f;
        bool neutral = true;
        for (uint32_t b = 0; b < kBands; ++b) {
            float targetDb = 0.0f;
            if (enabled) {
                const float detL = runBq(S.hp[b], S.hpL[b], bandL[b]);
                const float detR = runBq(S.hp[b], S.hpR[b], bandR[b]);
                const float detector = std::fmax(std::fabs(detL), std::fabs(detR));
                targetDb = bandTarget(linearToDb(detector), p[kThreshold + b], p[kRatio + b], p[kKnee + b]);
                targetDb += p[kMakeup + b];
            }
            float coef;
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
            outL += bandL[b] * gain;
            outR += bandR[b] * gain;
            const float gr = std::fmax(0.0f, -S.gainDb[b]);
            grMax[b] = gr > grMax[b] ? gr : grMax[b];
        }
        if (!enabled && neutral) {
            clearState(S);
            S.parked = 1;
            break;
        }
        L[i] = outL;
        R[i] = outR;
    }
    for (uint32_t b = 0; b < kBands; ++b) {
        S.grNowBits[b].store(floatToBits(std::fmax(0.0f, -S.gainDb[b])), std::memory_order_relaxed);
        atomicMaxFloat(S.grMaxBits[b], grMax[b]);
    }
}

n60_status validateMultibandParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount || !multibandParamOk(idx, value, h->sampleRate)) return N60_STATUS_BAD_ARGUMENT;
    return (idx == kLowSlope || idx == kHighSlope) ? N60_STATUS_UNSUPPORTED : N60_STATUS_OK;
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
