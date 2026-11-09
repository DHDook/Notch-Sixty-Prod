// libn60core ABI v23 image stages (E6 S12b): the stereo kernel's stereo mode, stereo widener, de-harsh and de-esser,
// ported from N60Dynamics.c (process_stereo_mode, process_stereo_widener, process_de_harsh, process_de_esser) with the
// same float arithmetic, so the output matches the kernel to rounding. Two pair stages share this file:
//   N60_STAGE_IMAGE (stereo mode, then widener) and N60_STAGE_DEESS (de-harsh, then de-esser).
// They sit in the core chain at ranks 9.6 and 9.8, directly before the compressor, which is where the kernel runs them
// (its "core" frame: mode, widener, [loudness, S12c], de-harsh, de-esser, [multiband, S12d], compressor, expander).
//
// Derivations (public specifications):
//  - Stereo mode: a 2x2 matrix smoothed to its target over 5 ms (one pole). Wide mono = equal-power sum, every entry
//    1/sqrt(2); true mono = every entry 1/2 (L = R = (L + R) / 2).
//  - Widener: mid/side, M = (L + R) / 2, S = (L - R) / 2. S is split by a Linkwitz-Riley 4th-order low-pass at the
//    low/mid corner and high-pass at the mid/high corner (each LR4 is two cascaded 2nd-order Butterworth biquads,
//    Q = 1/sqrt(2); Linkwitz and Riley, JAES 1976), mid = S - low - high, and each band's side is scaled by its width
//    (the low width is 0 when "mono low band" is on). L = M + S', R = M - S'.
//  - De-harsh: a high shelf (RBJ Audio EQ Cookbook, Q = 1/sqrt(2)) blended in over 5 ms.
//  - De-esser: a band-pass sidechain (2nd-order high-pass at f * 2^(-1/Q), low-pass at min(f * 2^(1/Q), 0.45 fs)),
//    detector = max(|L band|, |R band|) in dB, a soft-knee (3 dB) downward compressor law gain, floored at the range,
//    smoothed with the attack or release pole; dynamic-EQ mode subtracts only the band, wideband mode scales the signal.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runImage:
//  - allocation: none. All state is in the snapshot arena (one shared record per stage), built off the audio thread.
//  - synchronisation: none. Once published, the realtime thread owns the state; every parameter is a live plain float
//    the mailbox wrote at block start. The de-esser's gain reduction is two relaxed atomics read by the control thread.
//  - latency: 0 frames.
//  - sample rate: 8 kHz to 768 kHz (tested 44.1 to 384 kHz). Coefficients and filter state are float, as the kernel's, so
//    the output matches it bit for bit (deviation from double precision recorded in the ledger). Decayed state is
//    flushed to zero once per block. Non-finite input is the upstream stage's responsibility (PROTECTION follows). At a block start a changed parameter redesigns its coefficients (at most 5 biquads:
//    bounded libm, no allocation).
//  - channels: a stereo pair (laneA, laneB), as the kernel.
//  - reset: a new snapshot starts parked and neutral; enabling a part from parked clears its state, as the kernel does.
//    State is not carried across a rebuild (ledger).
#include "stages_image.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr size_t kAlign = 16;
constexpr float kParkEps = 1.0e-5f;
constexpr float kEpsilon = 1.0e-12f;  // the kernel's N60_DYNAMICS_EPSILON
constexpr float kKneeDb = 3.0f;       // the kernel's de-esser knee
constexpr double kQ = 0.7071067811865476;

enum ImgParam : uint32_t {
    kMode = 0,       // 0 stereo, 1 wide mono, 2 true mono
    kWideOn = 1,     // 0/1
    kMonoLow = 2,    // 0/1
    kLowMidHz = 3,   // 80..500
    kMidHighHz = 4,  // 1500..8000
    kLowWidth = 5,   // 0..1
    kMidWidth = 6,   // 1..2
    kHighWidth = 7,  // 1..2
    kImgParams = 8
};

enum DeParam : uint32_t {
    kHarshOn = 0,     // 0/1
    kHarshHz = 1,     // 1500..10000
    kHarshDb = 2,     // -6..0
    kEssOn = 3,       // 0/1
    kEssHz = 4,       // 2000..10000
    kEssThr = 5,      // -60..0 dB
    kEssRatio = 6,    // 1..20
    kEssRange = 7,    // -24..0 dB
    kEssQ = 8,        // 0.5..8
    kEssAttack = 9,   // 0.1..100 ms
    kEssRelease = 10, // 10..1000 ms
    kEssDynEq = 11,   // 0/1
    kDeParams = 12
};

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }
bool isFlag(float v) { return v == 0.0f || v == 1.0f; }

struct Bq {
    float b0, b1, b2, a1, a2;
};
struct BqState {
    float z1, z2;
};
// G36: the widener's 80 Hz corner at 384 kHz needs more than float (poles within 1e-3 of the unit circle), so its
// crossover biquads keep double coefficients and state; everything else in the stages stays float.
struct BqD {
    double b0, b1, b2, a1, a2;
};
struct BqStateD {
    double z1, z2;
};

float smoothToward(float current, float target, float coef) { return target + coef * (current - target); }
bool nearZero(float v) { return std::fabs(v) <= kParkEps; }
bool nearOne(float v) { return std::fabs(v - 1.0f) <= kParkEps; }
Bq identityBq() { return Bq{1.0f, 0.0f, 0.0f, 0.0f, 0.0f}; }

double runBqD(const BqD &c, BqStateD &s, double in) {
    const double out = c.b0 * in + s.z1;
    s.z1 = c.b1 * in - c.a1 * out + s.z2;
    s.z2 = c.b2 * in - c.a2 * out;
    return out;
}

float runBq(const Bq &c, BqState &s, float in) {
    const float out = c.b0 * in + s.z1;
    s.z1 = c.b1 * in - c.a1 * out + s.z2;
    s.z2 = c.b2 * in - c.a2 * out;
    return out;
}

// RBJ low-pass, high-pass and high shelf, normalised in double and stored as float (the kernel's N60BiquadDesign).
enum class Kind { LowPass, HighPass, HighShelf };

bool designBqD(Kind kind, double rate, double f, double gainDb, double q, BqD &out) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(q) || q <= 0.0 || !std::isfinite(gainDb)) return false;
    const double omega = 2.0 * kPi * f / rate;
    const double cosO = std::cos(omega);
    const double sinO = std::sin(omega);
    const double alpha = sinO / (2.0 * q);
    double b0, b1, b2, a0, a1, a2;
    if (kind == Kind::LowPass) {
        b0 = (1.0 - cosO) * 0.5; b1 = 1.0 - cosO; b2 = (1.0 - cosO) * 0.5;
        a0 = 1.0 + alpha; a1 = -2.0 * cosO; a2 = 1.0 - alpha;
    } else if (kind == Kind::HighPass) {
        b0 = (1.0 + cosO) * 0.5; b1 = -(1.0 + cosO); b2 = (1.0 + cosO) * 0.5;
        a0 = 1.0 + alpha; a1 = -2.0 * cosO; a2 = 1.0 - alpha;
    } else {
        const double A = std::pow(10.0, gainDb / 40.0);
        const double beta = 2.0 * std::sqrt(A) * alpha;
        b0 = A * ((A + 1.0) + (A - 1.0) * cosO + beta);
        b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cosO);
        b2 = A * ((A + 1.0) + (A - 1.0) * cosO - beta);
        a0 = (A + 1.0) - (A - 1.0) * cosO + beta;
        a1 = 2.0 * ((A - 1.0) - (A + 1.0) * cosO);
        a2 = (A + 1.0) - (A - 1.0) * cosO - beta;
    }
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const BqD c{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.b2) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) return false;
    out = c;
    return true;
}

bool designBq(Kind kind, double rate, double f, double gainDb, double q, Bq &out) {
    BqD d;
    if (!designBqD(kind, rate, f, gainDb, q, d)) return false;
    const Bq c{static_cast<float>(d.b0), static_cast<float>(d.b1), static_cast<float>(d.b2), static_cast<float>(d.a1),
               static_cast<float>(d.a2)};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.b2) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) return false;
    out = c;
    return true;
}

// The kernel's coefficient_for_time_ms (clamped to 0.05 .. 5000 ms).
float poleForMs(double rate, float ms) {
    const float safe = std::min(std::max(ms, 0.05f), 5000.0f);
    return static_cast<float>(std::exp(-1.0 / (rate * (double(safe) / 1000.0))));
}

float dbToLinear(float db) { return std::pow(10.0f, db / 20.0f); }
float linearToDb(float x) { return 20.0f * std::log10(std::fmax(x, kEpsilon)); }

// ---- IMAGE ---------------------------------------------------------------------------------------------------------

struct ImgShared {
    float bypassCoef;
    // stereo mode
    float mLL, mLR, mRL, mRR;
    uint32_t modeParked;
    // widener
    float lowW, midW, highW;
    uint32_t wideParked;
    float seenLowMid, seenMidHigh;
    BqD lowPass[2], highPass[2];
    BqStateD lowSt[2], highSt[2];
};

void designWidener(ImgShared &S, double rate, float lowMid, float midHigh) {
    for (int i = 0; i < 2; ++i) {
        if (!designBqD(Kind::LowPass, rate, double(lowMid), 0.0, kQ, S.lowPass[i])) S.lowPass[i] = BqD{1.0, 0.0, 0.0, 0.0, 0.0};
        if (!designBqD(Kind::HighPass, rate, double(midHigh), 0.0, kQ, S.highPass[i])) S.highPass[i] = BqD{1.0, 0.0, 0.0, 0.0, 0.0};
    }
    S.seenLowMid = lowMid;
    S.seenMidHigh = midHigh;
}

void runMode(ImgShared &S, const float *p, float *L, float *R, uint32_t frames) {
    const int mode = static_cast<int>(p[kMode]);
    const bool enabled = mode != 0;
    if (!enabled && S.modeParked != 0) return;
    if (enabled) S.modeParked = 0;
    float tLL = 1.0f, tLR = 0.0f, tRL = 0.0f, tRR = 1.0f;
    if (mode == 1) {
        tLL = tLR = tRL = tRR = 0.7071067811865476f;
    } else if (mode == 2) {
        tLL = tLR = tRL = tRR = 0.5f;
    }
    const float c = S.bypassCoef;
    for (uint32_t i = 0; i < frames; ++i) {
        S.mLL = smoothToward(S.mLL, tLL, c);
        S.mLR = smoothToward(S.mLR, tLR, c);
        S.mRL = smoothToward(S.mRL, tRL, c);
        S.mRR = smoothToward(S.mRR, tRR, c);
        if (!enabled && nearOne(S.mLL) && nearZero(S.mLR) && nearZero(S.mRL) && nearOne(S.mRR)) {
            S.mLL = 1.0f; S.mLR = 0.0f; S.mRL = 0.0f; S.mRR = 1.0f;
            S.modeParked = 1;
            return;
        }
        const float inL = L[i];
        const float inR = R[i];
        L[i] = inL * S.mLL + inR * S.mLR;
        R[i] = inL * S.mRL + inR * S.mRR;
    }
}

void runWidener(ImgShared &S, const float *p, double rate, float *L, float *R, uint32_t frames) {
    const bool enabled = p[kWideOn] > 0.5f;
    if (!enabled && S.wideParked != 0) return;
    if (p[kLowMidHz] != S.seenLowMid || p[kMidHighHz] != S.seenMidHigh) designWidener(S, rate, p[kLowMidHz], p[kMidHighHz]);
    if (enabled && S.wideParked != 0) {
        std::memset(S.lowSt, 0, sizeof S.lowSt);
        std::memset(S.highSt, 0, sizeof S.highSt);
        S.lowW = S.midW = S.highW = 1.0f;
        S.wideParked = 0;
    }
    const float lowTarget = enabled ? (p[kMonoLow] > 0.5f ? 0.0f : p[kLowWidth]) : 1.0f;
    const float midTarget = enabled ? p[kMidWidth] : 1.0f;
    const float highTarget = enabled ? p[kHighWidth] : 1.0f;
    const float c = S.bypassCoef;
    for (uint32_t i = 0; i < frames; ++i) {
        const float dryL = L[i];
        const float dryR = R[i];
        if (!std::isfinite(dryL) || !std::isfinite(dryR)) {  // G14: never let a non-finite sample into the recursions
            std::memset(S.lowSt, 0, sizeof S.lowSt);
            std::memset(S.highSt, 0, sizeof S.highSt);
            L[i] = R[i] = 0.0f;
            continue;
        }
        const float mid = 0.5f * (dryL + dryR);
        const float side = 0.5f * (dryL - dryR);
        double lowSide = side;
        double highSide = side;
        for (int k = 0; k < 2; ++k) {
            lowSide = runBqD(S.lowPass[k], S.lowSt[k], lowSide);
            highSide = runBqD(S.highPass[k], S.highSt[k], highSide);
        }
        const double midSide = double(side) - lowSide - highSide;
        S.lowW = smoothToward(S.lowW, lowTarget, c);
        S.midW = smoothToward(S.midW, midTarget, c);
        S.highW = smoothToward(S.highW, highTarget, c);
        if (!enabled && nearOne(S.lowW) && nearOne(S.midW) && nearOne(S.highW)) {
            S.lowW = S.midW = S.highW = 1.0f;
            std::memset(S.lowSt, 0, sizeof S.lowSt);
            std::memset(S.highSt, 0, sizeof S.highSt);
            S.wideParked = 1;
            return;
        }
        const float processed = static_cast<float>(lowSide * S.lowW + midSide * S.midW + highSide * S.highW);
        L[i] = mid + processed;
        R[i] = mid - processed;
    }
}

// ---- DEESS ---------------------------------------------------------------------------------------------------------

struct DeShared {
    float bypassCoef;
    // de-harsh
    float seenHarshHz, seenHarshDb;
    Bq shelf;
    BqState shelfL, shelfR;
    float harshMix;
    uint32_t harshParked;
    // de-esser
    float seenEssHz, seenEssQ, seenAttack, seenRelease;
    Bq hp, lp;
    float attackPole, releasePole;
    BqState hpL, hpR, lpL, lpR;
    float essGainDb;
    uint32_t essParked;
    float lastDetector, lastDetectorDb, lastGainDb, lastGainLin;  // pure caches of linearToDb / dbToLinear
    // telemetry (control thread reads)
    std::atomic<uint32_t> grMaxBits;
    std::atomic<uint32_t> grNowBits;
};

void designHarsh(DeShared &S, double rate, float hz, float db) {
    if (!designBq(Kind::HighShelf, rate, double(hz), double(db), kQ, S.shelf)) S.shelf = identityBq();
    S.seenHarshHz = hz;
    S.seenHarshDb = db;
}

void designEss(DeShared &S, double rate, float hz, float q) {
    const double half = 1.0 / double(q);
    const double lower = double(hz) * std::pow(2.0, -half);
    double upper = double(hz) * std::pow(2.0, half);
    upper = std::fmin(upper, rate * 0.45);
    if (!designBq(Kind::HighPass, rate, lower, 0.0, kQ, S.hp)) S.hp = identityBq();
    if (!designBq(Kind::LowPass, rate, upper, 0.0, kQ, S.lp)) S.lp = identityBq();
    S.seenEssHz = hz;
    S.seenEssQ = q;
}

void clearEssState(DeShared &S) {
    S.hpL = S.hpR = S.lpL = S.lpR = BqState{0.0f, 0.0f};
}

void runHarsh(DeShared &S, const float *p, double rate, float *L, float *R, uint32_t frames) {
    const bool enabled = p[kHarshOn] > 0.5f;
    if (!enabled && S.harshParked != 0) return;
    if (p[kHarshHz] != S.seenHarshHz || p[kHarshDb] != S.seenHarshDb) designHarsh(S, rate, p[kHarshHz], p[kHarshDb]);
    if (enabled && S.harshParked != 0) {
        S.shelfL = S.shelfR = BqState{0.0f, 0.0f};
        S.harshMix = 0.0f;
        S.harshParked = 0;
    }
    const float target = enabled ? 1.0f : 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        const float dryL = L[i];
        const float dryR = R[i];
        if (!std::isfinite(dryL) || !std::isfinite(dryR)) {
            S.shelfL = S.shelfR = BqState{0.0f, 0.0f};
            L[i] = R[i] = 0.0f;
            continue;
        }
        const float wetL = runBq(S.shelf, S.shelfL, dryL);
        const float wetR = runBq(S.shelf, S.shelfR, dryR);
        S.harshMix = smoothToward(S.harshMix, target, S.bypassCoef);
        if (!enabled && nearZero(S.harshMix)) {
            S.harshMix = 0.0f;
            S.shelfL = S.shelfR = BqState{0.0f, 0.0f};
            S.harshParked = 1;
            return;
        }
        L[i] = dryL + (wetL - dryL) * S.harshMix;
        R[i] = dryR + (wetR - dryR) * S.harshMix;
    }
}

// The kernel's compressor law (soft knee, no make-up) at a fixed 3 dB knee, as dynamics_compression_target.
float essTarget(float detectorDb, bool enabled, float thr, float ratio) {
    if (!enabled) return 0.0f;
    const float over = detectorDb - thr;
    const float slope = (1.0f / ratio) - 1.0f;
    float comp = 0.0f;
    const float half = kKneeDb * 0.5f;
    if (over >= half) {
        comp = slope * over;
    } else if (over > -half) {
        const float pos = over + half;
        comp = slope * pos * pos / (2.0f * kKneeDb);
    }
    return comp;
}

void runEss(DeShared &S, const float *p, double rate, float *L, float *R, uint32_t frames) {
    const bool enabled = p[kEssOn] > 0.5f;
    if (!enabled && S.essParked != 0) return;
    if (p[kEssHz] != S.seenEssHz || p[kEssQ] != S.seenEssQ) designEss(S, rate, p[kEssHz], p[kEssQ]);
    if (p[kEssAttack] != S.seenAttack) {
        S.attackPole = poleForMs(rate, p[kEssAttack]);
        S.seenAttack = p[kEssAttack];
    }
    if (p[kEssRelease] != S.seenRelease) {
        S.releasePole = poleForMs(rate, p[kEssRelease]);
        S.seenRelease = p[kEssRelease];
    }
    if (enabled && S.essParked != 0) {
        clearEssState(S);
        S.essGainDb = 0.0f;
        S.essParked = 0;
    }
    const float thr = p[kEssThr];
    const float ratio = p[kEssRatio];
    const float range = p[kEssRange];
    const bool dynEq = p[kEssDynEq] > 0.5f;
    float grMax = 0.0f;
    for (uint32_t i = 0; i < frames; ++i) {
        const float dryL = L[i];
        const float dryR = R[i];
        if (!std::isfinite(dryL) || !std::isfinite(dryR)) {
            clearEssState(S);
            L[i] = R[i] = 0.0f;
            continue;
        }
        float bandL = runBq(S.hp, S.hpL, dryL);
        bandL = runBq(S.lp, S.lpL, bandL);
        float bandR = runBq(S.hp, S.hpR, dryR);
        bandR = runBq(S.lp, S.lpR, bandR);
        const float detector = std::fmax(std::fabs(bandL), std::fabs(bandR));
        if (detector != S.lastDetector) {  // G13: the log is recomputed only when the detector moved (same value as before)
            S.lastDetector = detector;
            S.lastDetectorDb = linearToDb(detector);
        }
        float targetDb = essTarget(S.lastDetectorDb, enabled, thr, ratio);
        targetDb = std::fmax(targetDb, range);
        const float coef = !enabled ? S.bypassCoef : (targetDb < S.essGainDb ? S.attackPole : S.releasePole);
        S.essGainDb = smoothToward(S.essGainDb, targetDb, coef);
        if (!enabled && nearZero(S.essGainDb)) {
            S.essGainDb = 0.0f;
            clearEssState(S);
            S.essParked = 1;
            break;
        }
        if (S.essGainDb != S.lastGainDb) {  // the pow is recomputed only when the smoothed gain moved
            S.lastGainDb = S.essGainDb;
            S.lastGainLin = dbToLinear(S.essGainDb);
        }
        const float gain = S.lastGainLin;
        if (dynEq) {
            L[i] = dryL + (gain - 1.0f) * bandL;
            R[i] = dryR + (gain - 1.0f) * bandR;
        } else {
            L[i] = dryL * gain;
            R[i] = dryR * gain;
        }
        const float gr = std::fmax(0.0f, -S.essGainDb);
        grMax = gr > grMax ? gr : grMax;
    }
    S.grNowBits.store(floatToBits(std::fmax(0.0f, -S.essGainDb)), std::memory_order_relaxed);
    atomicMaxFloat(S.grMaxBits, grMax);
}

}  // namespace

bool isImageKind(uint32_t kind) { return kind == N60_STAGE_IMAGE || kind == N60_STAGE_DEESS; }

n60_status validateImageStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0) || !isImageKind(s.kind) || s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneMask != 0 || s.laneA >= outCh || s.laneB >= outCh || s.laneA == s.laneB) return N60_STATUS_BAD_ARGUMENT;
    const uint32_t want = s.kind == N60_STAGE_IMAGE ? uint32_t(kImgParams) : uint32_t(kDeParams);
    if (s.params == nullptr || s.paramCount != want) return N60_STATUS_BAD_ARGUMENT;
    // Each parameter must pass the same check a live edit does.
    for (uint32_t i = 0; i < want; ++i) {
        if (!imageParamOk(s.kind, i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

bool imageParamOk(uint32_t kind, uint32_t idx, float v, double rate) {
    if (kind == N60_STAGE_IMAGE) {
        switch (idx) {
            case kMode: return isInt(v) && v >= 0.0f && v <= 2.0f;
            case kWideOn:
            case kMonoLow: return isFlag(v);
            case kLowMidHz: return inR(v, 80.0, 500.0) && double(v) < rate * 0.45;
            case kMidHighHz: return inR(v, 1500.0, 8000.0) && double(v) < rate * 0.45;
            case kLowWidth: return inR(v, 0.0, 1.0);
            case kMidWidth:
            case kHighWidth: return inR(v, 1.0, 2.0);
            default: return false;
        }
    }
    switch (idx) {
        case kHarshOn:
        case kEssOn:
        case kEssDynEq: return isFlag(v);
        case kHarshHz: return inR(v, 1500.0, 10000.0) && double(v) < rate * 0.45;
        case kHarshDb: return inR(v, -6.0, 0.0);
        case kEssHz: return inR(v, 2000.0, 10000.0) && double(v) < rate * 0.45;
        case kEssThr: return inR(v, -60.0, 0.0);
        case kEssRatio: return inR(v, 1.0, 20.0);
        case kEssRange: return inR(v, -24.0, 0.0);
        case kEssQ: return inR(v, 0.5, 8.0);
        case kEssAttack: return inR(v, 0.1, 100.0);
        case kEssRelease: return inR(v, 10.0, 1000.0);
        default: return false;
    }
}

void imageSizes(const n60_stage_desc &s, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(s.kind == N60_STAGE_IMAGE ? sizeof(ImgShared) : sizeof(DeShared));
}

void imageInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    const float bypass = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    if (r.kind == N60_STAGE_IMAGE) {
        ImgShared &S = *new (sharedState(h, r)) ImgShared{};
        S.bypassCoef = bypass;
        S.mLL = 1.0f; S.mRR = 1.0f;
        S.modeParked = 1;
        S.lowW = S.midW = S.highW = 1.0f;
        S.wideParked = 1;
        designWidener(S, rate, p[kLowMidHz], p[kMidHighHz]);
    } else {
        DeShared &S = *new (sharedState(h, r)) DeShared{};
        S.bypassCoef = bypass;
        designHarsh(S, rate, p[kHarshHz], p[kHarshDb]);
        designEss(S, rate, p[kEssHz], p[kEssQ]);
        S.attackPole = poleForMs(rate, p[kEssAttack]);
        S.seenAttack = p[kEssAttack];
        S.releasePole = poleForMs(rate, p[kEssRelease]);
        S.seenRelease = p[kEssRelease];
        S.harshParked = 1;
        S.essParked = 1;
        S.lastDetector = 0.0f;
        S.lastDetectorDb = linearToDb(0.0f);
        S.lastGainDb = 0.0f;
        S.lastGainLin = dbToLinear(0.0f);
    }
}

// Denormal guard, once per block: decayed filter state below 1e-30 (-600 dBFS) is flushed to zero.
static inline void flush(float &v) { if (std::fabs(v) < 1.0e-30f) v = 0.0f; }
static inline void flush(double &v) { if (std::fabs(v) < 1.0e-30) v = 0.0; }

void runImage(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    float *L = lanes[r.laneA];
    float *R = lanes[r.laneB];
    const double rate = h->sampleRate;
    if (r.kind == N60_STAGE_IMAGE) {
        ImgShared &S = *reinterpret_cast<ImgShared *>(sharedState(h, r));
        runMode(S, p, L, R, frames);
        runWidener(S, p, rate, L, R, frames);
        for (int i = 0; i < 2; ++i) {
            flush(S.lowSt[i].z1); flush(S.lowSt[i].z2); flush(S.highSt[i].z1); flush(S.highSt[i].z2);
        }
    } else {
        DeShared &S = *reinterpret_cast<DeShared *>(sharedState(h, r));
        runHarsh(S, p, rate, L, R, frames);
        runEss(S, p, rate, L, R, frames);
        flush(S.shelfL.z1); flush(S.shelfL.z2); flush(S.shelfR.z1); flush(S.shelfR.z2);
        flush(S.hpL.z1); flush(S.hpL.z2); flush(S.hpR.z1); flush(S.hpR.z2);
        flush(S.lpL.z1); flush(S.lpL.z2); flush(S.lpR.z1); flush(S.lpR.z2);
    }
}

uint64_t imageCarry(SnapHeader *from, SnapHeader *to) {
    uint64_t bytes = 0;
    if (from == nullptr || to == nullptr || from->sampleRate != to->sampleRate) return bytes;
    const StageRec *src = stages(from);
    StageRec *dst = stages(to);
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (!isImageKind(dst[i].kind)) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != dst[i].kind || src[j].id != dst[i].id) continue;
            if (dst[i].kind == N60_STAGE_IMAGE) {
                const ImgShared &a = *reinterpret_cast<const ImgShared *>(sharedState(from, src[j]));
                ImgShared &b = *reinterpret_cast<ImgShared *>(sharedState(to, dst[i]));
                bytes += sizeof(ImgShared);
                b.mLL = a.mLL; b.mLR = a.mLR; b.mRL = a.mRL; b.mRR = a.mRR;
                b.modeParked = a.modeParked;
                b.lowW = a.lowW; b.midW = a.midW; b.highW = a.highW;
                b.wideParked = a.wideParked;
                std::memcpy(b.lowSt, a.lowSt, sizeof b.lowSt);
                std::memcpy(b.highSt, a.highSt, sizeof b.highSt);
            } else {
                const DeShared &a = *reinterpret_cast<const DeShared *>(sharedState(from, src[j]));
                DeShared &b = *reinterpret_cast<DeShared *>(sharedState(to, dst[i]));
                bytes += sizeof(DeShared);
                b.shelfL = a.shelfL; b.shelfR = a.shelfR;
                b.harshMix = a.harshMix;
                b.harshParked = a.harshParked;
                b.hpL = a.hpL; b.hpR = a.hpR; b.lpL = a.lpL; b.lpR = a.lpR;
                b.essGainDb = a.essGainDb;
                b.essParked = a.essParked;
                b.grNowBits.store(a.grNowBits.load(std::memory_order_relaxed), std::memory_order_relaxed);
            }
            break;
        }
    }
    return bytes;
}

n60_status validateImageParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    return imageParamOk(r.kind, idx, value, h->sampleRate) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

bool readDeEss(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out) {
    if (r.kind != N60_STAGE_DEESS || (lane != r.laneA && lane != r.laneB)) return false;
    DeShared &S = *reinterpret_cast<DeShared *>(sharedState(h, r));
    out->kind = r.kind;
    out->grMaxDb = bitsToFloat(S.grMaxBits.exchange(0, std::memory_order_relaxed));
    out->grNowDb = bitsToFloat(S.grNowBits.load(std::memory_order_relaxed));
    out->inTruePeak = 0.0f;
    out->outTruePeak = 0.0f;
    out->guardActive = 0;
    out->reserved = 0;
    return true;
}

}  // namespace n60
