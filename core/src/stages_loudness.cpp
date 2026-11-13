// libn60core ABI v24 loudness stage (E6 S12c): the stereo kernel's loudness match, loudness contour (simple and
// per-band) and dialogue leveler, ported from N60Dynamics.c (process_loudness_match, process_loudness_contour,
// process_dialogue_leveler) with the same float arithmetic, so the output matches the kernel to rounding. One pair stage,
// N60_STAGE_LOUDNESS, at rank 9.7: after IMAGE, before DEESS and the compressor, which is where the kernel runs them.
//
// Derivations (public specifications):
//  - Loudness match: ITU-R BS.1770-4 K-weighting (a 38.13 Hz high-pass, Q 0.5003, then a +4 dB high shelf at 1681.97 Hz,
//    Q 0.7072), mean square of both channels smoothed over 3 s, LUFS = -0.691 + 10 log10(mean square). The correction is
//    target - measured, clamped to +-max, with an attack pole when it falls and a release pole when it rises.
//  - Contour: RBJ Audio EQ Cookbook shelves (Q = 1/sqrt(2)). Simple mode blends a 120 Hz low shelf and 8 kHz high shelf
//    by a volume scale taken from the master gain; per-band mode adds gain to a 120 Hz low band and an 8 kHz high band,
//    from the phon deficit against a reference (ISO 226 trend: 0.25 dB per phon low, 0.125 dB per phon high).
//  - Dialogue leveler: a 300..3500 Hz band (2nd-order high-pass and low-pass), power gap against the whole programme,
//    a voice-confidence measure from the 2.5..7.5 Hz modulation of the band envelope, and a boost of the gap above target.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runLoudness:
//  - allocation: none. All state is in the snapshot arena (one shared record), built off the audio thread.
//  - synchronisation: none. Once published, the realtime thread owns the state; every parameter is a live plain float the
//    mailbox wrote at block start. The telemetry is relaxed atomics (floats as bits) read by the control thread.
//  - latency: 0 frames.
//  - sample rate: 20 kHz to 768 kHz (tested 44.1 to 384 kHz). Coefficients, filter state and the smoothed values are float,
//    as the kernel's (recorded in the ledger). Decayed state is flushed to zero once per block. At a block start a changed
//    parameter redesigns its coefficients (at most 4 biquads: bounded libm, no allocation).
//  - channels: a stereo pair (laneA, laneB), as the kernel.
//  - reset: a new snapshot starts parked and neutral; enabling a part from parked clears its state, as the kernel does.
//    State is not carried across a rebuild (ledger).
#include "stages_loudness.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>

#include "simd/simd.hpp"

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr size_t kAlign = 16;
constexpr float kParkEps = 1.0e-5f;
constexpr float kEpsilon = 1.0e-12f;  // the kernel's N60_DYNAMICS_EPSILON
constexpr double kQ = 0.7071067811865476;

constexpr double kLowShelfHz = 120.0;
constexpr double kHighShelfHz = 8000.0;
constexpr float kMaxBassDb = 6.0f;
constexpr float kMaxTrebleDb = 3.0f;
constexpr double kKHighPassHz = 38.13547087602444;
constexpr double kKHighPassQ = 0.5003270373238773;
constexpr double kKShelfHz = 1681.974450955533;
constexpr double kKShelfQ = 0.7071752369554196;
constexpr double kKShelfDb = 3.999843853973347;
constexpr double kMeasureSeconds = 3.0;
constexpr float kGateLufs = -60.0f;
constexpr float kFullContourDb = -30.0f;
constexpr float kFlatContourDb = -6.0f;
constexpr float kIntegratedRefLufs = -16.0f;
constexpr float kLowDbPerPhon = 0.25f;
constexpr float kHighDbPerPhon = 0.125f;
constexpr float kLowCutDbPerPhon = 0.15f;
constexpr float kHighCutDbPerPhon = 0.075f;
constexpr float kGainResponseMs = 50.0f;

enum Param : uint32_t {
    kMatchOn = 0,       // 0/1
    kMatchGate = 1,     // 0/1 dialogue gate
    kTargetLufs = 2,    // -24..-10
    kMaxCorrection = 3, // 3..20 dB
    kMatchAttack = 4,   // 0.3..5 s
    kMatchRelease = 5,  // 1..10 s
    kContourOn = 6,     // 0/1
    kStrength = 7,      // 0..1
    kPerBand = 8,       // 0/1
    kLevelSource = 9,   // 0 system volume, 1 integrated
    kRefPhons = 10,     // 60..95
    kMaxBoost = 11,     // 6..20 dB
    kMaxCut = 12,       // 0..6 dB
    kMasterGain = 13,   // linear 0..1, live
    kLevOn = 14,        // 0/1
    kVoiceGate = 15,    // 0/1
    kBandLow = 16,      // 100..8000 Hz
    kBandHigh = 17,     // 100..8000 Hz, > low, < 0.45 fs
    kTargetGap = 18,    // 3..20 dB
    kBoostRatio = 19,   // 1..6
    kLevMaxBoost = 20,  // 0..15 dB
    kDetectorMs = 21,   // 50..500
    kLevAttackMs = 22,  // 10..1000
    kLevReleaseMs = 23, // 50..3000
    kProgramGate = 24,  // -70..-30 dB
    kModLowHz = 25,     // 0.5..10
    kModHighHz = 26,    // 3..14, > low, < 0.45 fs
    kEnvelopeMs = 27,   // 5..30
    kMeasureMs = 28,    // 300..1500
    kConfFloor = 29,    // 0..1
    kConfCeil = 30,     // > floor, <= 1
    kMinConf = 31,      // 0..1
    kParams = 32
};

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isFlag(float v) { return v == 0.0f || v == 1.0f; }

// E23 S1b: coefficients and state are double. A float transposed-direct-form-II state at a 38 Hz corner loses
// about 50 dB of accuracy at 384 kHz (measured in S1, E23); input and output stay float.
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

enum class Kind { LowPass, HighPass, LowShelf, HighShelf };

// RBJ designs, normalised in double and stored as float (the kernel's N60BiquadDesign).
bool designBq(Kind kind, double rate, double f, double gainDb, double q, Bq &out) {
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
    } else if (kind == Kind::LowShelf) {
        const double A = std::pow(10.0, gainDb / 40.0);
        const double beta = 2.0 * std::sqrt(A) * alpha;
        b0 = A * ((A + 1.0) - (A - 1.0) * cosO + beta);
        b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cosO);
        b2 = A * ((A + 1.0) - (A - 1.0) * cosO - beta);
        a0 = (A + 1.0) + (A - 1.0) * cosO + beta;
        a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cosO);
        a2 = (A + 1.0) + (A - 1.0) * cosO - beta;
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
    const Bq c{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.b2) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) return false;
    out = c;
    return true;
}

// The kernel's coefficient_for_time_ms (clamped to 0.05 .. 5000 ms).
float poleForMs(double rate, float ms) {
    const float safe = std::min(std::max(ms, 0.05f), 5000.0f);
    return static_cast<float>(std::exp(-1.0 / (rate * (double(safe) / 1000.0))));
}

float meanSquareLufs(double ms) {
    return static_cast<float>(-0.691 + 10.0 * std::log10(std::fmax(ms, static_cast<double>(kEpsilon))));
}
float dbToLinear(float db) { return std::pow(10.0f, db / 20.0f); }
float linearToDb(float x) { return 20.0f * std::log10(std::fmax(x, kEpsilon)); }
float clampf(float v, float lo, float hi) { return std::fmin(std::fmax(v, lo), hi); }

struct LdShared {
    float bypassCoef;
    float seen[kParams];  // parameter values the derived coefficients were last built from
    // match
    Bq kHp, kShelf;
    double measCoef;
    float attackPole, releasePole;
    BqState kHpL, kHpR, kShL, kShR;
    double meanSquare;
    uint32_t primed;
    float matchGainDb;
    uint32_t matchParked;
    // contour
    Bq lowShelf, highShelf, lowBand, highBand;
    float responsePole;
    BqState lowShL, lowShR, highShL, highShR, lowBandL, lowBandR, highBandL, highBandR;
    float mix, lowGainDb, highGainDb, phons;
    uint32_t contourParked;
    // leveler
    Bq bandHp, bandLp;
    float detectorPole, levAttackPole, levReleasePole, envPole, measPole, modHpPole, modLpPole;
    BqState hpL, hpR, lpL, lpR;
    float progMs, bandMs, voiceEnv, modPrev, modHpOut, modLpOut, modMs, boostDb;
    float progDbfs, bandDbfs, gapDb, confidence;
    uint32_t levParked;
    // telemetry (control thread reads)
    std::atomic<uint32_t> tel[11];
};

// Telemetry slots, in n60_loudness_readback order.
enum Tel { kTLufs, kTMatch, kTScale, kTLowComp, kTHighComp, kTPhons, kTProg, kTBand, kTGap, kTConf, kTBoost };

void clearMatchState(LdShared &S) {
    S.kHpL = S.kHpR = S.kShL = S.kShR = BqState{0.0, 0.0};
}
void clearContourSimple(LdShared &S) {
    S.lowShL = S.lowShR = S.highShL = S.highShR = BqState{0.0, 0.0};
}
void clearContourBands(LdShared &S) {
    S.lowBandL = S.lowBandR = S.highBandL = S.highBandR = BqState{0.0, 0.0};
}
void clearLevelerFilters(LdShared &S) {
    S.hpL = S.hpR = S.lpL = S.lpR = BqState{0.0, 0.0};
}

// ---- derived coefficients (control thread at init, realtime thread at a block start when a parameter moved) ----------

void designMatch(LdShared &S, double rate, const float *p) {
    S.measCoef = std::exp(-1.0 / (rate * kMeasureSeconds));
    S.attackPole = poleForMs(rate, p[kMatchAttack] * 1000.0f);
    S.releasePole = poleForMs(rate, p[kMatchRelease] * 1000.0f);
    S.seen[kMatchAttack] = p[kMatchAttack];
    S.seen[kMatchRelease] = p[kMatchRelease];
}

void designContour(LdShared &S, double rate, const float *p) {
    const double bass = double(kMaxBassDb) * double(p[kStrength]);
    const double treble = double(kMaxTrebleDb) * double(p[kStrength]);
    if (!designBq(Kind::LowShelf, rate, kLowShelfHz, bass, kQ, S.lowShelf)) S.lowShelf = identityBq();
    if (!designBq(Kind::HighShelf, rate, kHighShelfHz, treble, kQ, S.highShelf)) S.highShelf = identityBq();
    S.seen[kStrength] = p[kStrength];
}

void designLeveler(LdShared &S, double rate, const float *p) {
    if (!designBq(Kind::HighPass, rate, double(p[kBandLow]), 0.0, kQ, S.bandHp)) S.bandHp = identityBq();
    if (!designBq(Kind::LowPass, rate, double(p[kBandHigh]), 0.0, kQ, S.bandLp)) S.bandLp = identityBq();
    S.detectorPole = poleForMs(rate, p[kDetectorMs]);
    S.levAttackPole = poleForMs(rate, p[kLevAttackMs]);
    S.levReleasePole = poleForMs(rate, p[kLevReleaseMs]);
    S.envPole = poleForMs(rate, p[kEnvelopeMs]);
    S.measPole = poleForMs(rate, p[kMeasureMs]);
    S.modHpPole = static_cast<float>(std::exp(-2.0 * kPi * double(p[kModLowHz]) / rate));
    S.modLpPole = static_cast<float>(std::exp(-2.0 * kPi * double(p[kModHighHz]) / rate));
    for (uint32_t i = kBandLow; i <= kMeasureMs; ++i) S.seen[i] = p[i];
}

bool levelerMoved(const LdShared &S, const float *p) {
    for (uint32_t i = kBandLow; i <= kMeasureMs; ++i) {
        if (i == kTargetGap || i == kBoostRatio || i == kLevMaxBoost || i == kProgramGate) continue;
        if (p[i] != S.seen[i]) return true;
    }
    return false;
}

// ---- the three sections, one sample (the kernel's order: match, contour, leveler) ---------------------------------

void clearMatchAll(LdShared &S) {
    clearMatchState(S);
    S.meanSquare = 0.0;
    S.primed = 0;
}

// E20 S10 (G14): the filters of all three parts run a chunk at a time with the left and right channels in one f64x2
// (simd::biquadPair), ahead of the per-sample gain, smoothing and telemetry code, which is unchanged. This is valid because the
// filters read only the audio at their own point in the chain and never the gain feedback, and a part's park state cannot change
// inside a block while it is enabled (parking needs the part disabled, and every parameter is constant for the block).
constexpr uint32_t kLdChunk = 256;
static_assert(sizeof(Bq) == 5 * sizeof(double), "biquadPair reads the five coefficients as an array");
using simd::f64x2;
void bqPair(const Bq &c, BqState &l, BqState &r, f64x2 *x, uint32_t n) {
    simd::biquadPair(&c.b0, l.z1, l.z2, &r.z1, &r.z2, x, n);
}
// The float rounding runBq applies to each section's output (the state keeps the double).
void roundToFloat(f64x2 *x, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) x[i] = simd::toDouble(static_cast<float>(simd::lane(x[i], 0)), static_cast<float>(simd::lane(x[i], 1)));
}
void loadPair(f64x2 *x, const float *l, const float *r, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) x[i] = simd::toDouble(l[i], r[i]);
}
void storePair(float *l, float *r, const f64x2 *x, uint32_t n) {
    for (uint32_t i = 0; i < n; ++i) {
        l[i] = static_cast<float>(simd::lane(x[i], 0));
        r[i] = static_cast<float>(simd::lane(x[i], 1));
    }
}
// Filter outputs one chunk ahead of contourSample (simple: a0, a1 = wet left, right; per-band: low L, R, high L, R).
struct ContourPre {
    const float *a0, *a1, *a2, *a3;
};

void unparkContour(LdShared &S) {
    clearContourSimple(S);
    clearContourBands(S);
    S.mix = 0.0f;
    S.lowGainDb = 0.0f;
    S.highGainDb = 0.0f;
    S.contourParked = 0;
}
void unparkLeveler(LdShared &S) {
    clearLevelerFilters(S);
    S.progMs = S.bandMs = S.voiceEnv = S.modPrev = S.modHpOut = S.modLpOut = S.modMs = 0.0f;
    S.boostDb = 0.0f;
    S.levParked = 0;
}

// `instant` is the K-weighted mean square of this frame, valid when a measurement is needed (computed by the chunk pre-pass).
void matchSample(LdShared &S, const float *p, float *left, float *right, double instant) {
    const bool enabled = p[kMatchOn] > 0.5f;
    const bool integrated = p[kContourOn] > 0.5f && p[kPerBand] > 0.5f && p[kLevelSource] > 0.5f;
    const bool measurementNeeded = enabled || integrated;
    if (!measurementNeeded && !enabled && S.matchParked != 0) return;
    if (measurementNeeded && S.matchParked != 0) {
        clearMatchAll(S);
        S.matchParked = 0;
    }
    float measuredLufs = -120.0f;
    if (measurementNeeded) {
        if (S.primed == 0 && instant > static_cast<double>(kEpsilon)) {
            S.meanSquare = instant;
            S.primed = 1;
        } else {
            S.meanSquare = instant + S.measCoef * (S.meanSquare - instant);
        }
        measuredLufs = meanSquareLufs(S.meanSquare);
    }
    if (!enabled) {
        if (!nearZero(S.matchGainDb)) {
            S.matchGainDb = smoothToward(S.matchGainDb, 0.0f, S.bypassCoef);
            if (!nearZero(S.matchGainDb)) {
                const float gain = dbToLinear(S.matchGainDb);
                *left *= gain;
                *right *= gain;
            } else {
                S.matchGainDb = 0.0f;
            }
        }
        if (!measurementNeeded && nearZero(S.matchGainDb)) {
            S.matchGainDb = 0.0f;
            clearMatchAll(S);
            S.matchParked = 1;
        }
        return;
    }
    S.matchParked = 0;
    float targetGainDb = 0.0f;
    if (!(p[kMatchGate] > 0.5f && measuredLufs < kGateLufs)) {
        targetGainDb = clampf(p[kTargetLufs] - measuredLufs, -p[kMaxCorrection], p[kMaxCorrection]);
    }
    const float coef = targetGainDb < S.matchGainDb ? S.attackPole : S.releasePole;
    S.matchGainDb = smoothToward(S.matchGainDb, targetGainDb, coef);
    const float gain = dbToLinear(S.matchGainDb);
    *left *= gain;
    *right *= gain;
}

// `meanSquare` is the match part's smoothed mean square after this frame; `pre` is null on the scalar path (a part that is
// fading out) and otherwise holds the filter outputs for frame j of the chunk.
void contourSample(LdShared &S, const float *p, float *left, float *right, double meanSquare, const ContourPre *pre, uint32_t j) {
    const float dryL = *left;
    const float dryR = *right;
    const bool enabled = p[kContourOn] > 0.5f;
    const bool perBand = p[kPerBand] > 0.5f;
    const float strength = p[kStrength];
    float master = p[kMasterGain];
    if (!std::isfinite(master) || master < 0.0f) master = 1.0f;
    if (!enabled && S.contourParked != 0) return;
    if (enabled && S.contourParked != 0) unparkContour(S);
    if (!perBand) {
        float wetL, wetR;
        if (pre != nullptr) {
            wetL = pre->a0[j];
            wetR = pre->a1[j];
        } else {
            wetL = runBq(S.lowShelf, S.lowShL, dryL);
            wetL = runBq(S.highShelf, S.highShL, wetL);
            wetR = runBq(S.lowShelf, S.lowShR, dryR);
            wetR = runBq(S.highShelf, S.highShR, wetR);
        }
        float volumeScale = 0.0f;
        const float fullLin = dbToLinear(kFullContourDb);
        const float flatLin = dbToLinear(kFlatContourDb);
        if (master <= fullLin) {
            volumeScale = 1.0f;
        } else if (master < flatLin) {
            const float masterDb = linearToDb(master);
            volumeScale = (kFlatContourDb - masterDb) / (kFlatContourDb - kFullContourDb);
            volumeScale = clampf(volumeScale, 0.0f, 1.0f);
        }
        const float target = enabled ? volumeScale : 0.0f;
        S.mix = smoothToward(S.mix, target, S.bypassCoef);
        S.lowGainDb = kMaxBassDb * strength * S.mix;
        S.highGainDb = kMaxTrebleDb * strength * S.mix;
        S.phons = 0.0f;  // the kernel's simple contour has no reference phons (telemetry 0)
        if (!enabled && nearZero(S.mix)) {
            S.mix = 0.0f;
            S.lowGainDb = 0.0f;
            S.highGainDb = 0.0f;
            S.phons = 0.0f;
            clearContourSimple(S);
            S.contourParked = 1;
            return;
        }
        *left = dryL + (wetL - dryL) * S.mix;
        *right = dryR + (wetR - dryR) * S.mix;
        return;
    }
    const float lowL = pre != nullptr ? pre->a0[j] : runBq(S.lowBand, S.lowBandL, dryL);
    const float lowR = pre != nullptr ? pre->a1[j] : runBq(S.lowBand, S.lowBandR, dryR);
    const float highL = pre != nullptr ? pre->a2[j] : runBq(S.highBand, S.highBandL, dryL);
    const float highR = pre != nullptr ? pre->a3[j] : runBq(S.highBand, S.highBandR, dryR);
    const float measuredLufs = meanSquareLufs(meanSquare);
    float estimated;
    if (p[kLevelSource] > 0.5f) {
        estimated = p[kRefPhons] + (measuredLufs - kIntegratedRefLufs);
    } else {
        const float masterDb = linearToDb(std::fmax(master, kEpsilon));
        estimated = p[kRefPhons] + (masterDb - kFlatContourDb);
    }
    S.phons = estimated;
    const float phonDelta = p[kRefPhons] - estimated;
    float lowTarget = 0.0f, highTarget = 0.0f;
    if (enabled && phonDelta >= 0.0f) {
        lowTarget = std::fmin(p[kMaxBoost], phonDelta * kLowDbPerPhon) * strength;
        highTarget = std::fmin(p[kMaxBoost], phonDelta * kHighDbPerPhon) * strength;
    } else if (enabled) {
        const float surplus = -phonDelta;
        lowTarget = -std::fmin(p[kMaxCut], surplus * kLowCutDbPerPhon) * strength;
        highTarget = -std::fmin(p[kMaxCut], surplus * kHighCutDbPerPhon) * strength;
    }
    const float coef = enabled ? S.responsePole : S.bypassCoef;
    S.lowGainDb = smoothToward(S.lowGainDb, lowTarget, coef);
    S.highGainDb = smoothToward(S.highGainDb, highTarget, coef);
    if (!enabled && nearZero(S.lowGainDb) && nearZero(S.highGainDb)) {
        S.lowGainDb = 0.0f;
        S.highGainDb = 0.0f;
        S.mix = 0.0f;
        S.phons = 0.0f;
        clearContourBands(S);
        S.contourParked = 1;
        return;
    }
    const float lowGain = dbToLinear(S.lowGainDb);
    const float highGain = dbToLinear(S.highGainDb);
    *left = dryL + lowL * (lowGain - 1.0f) + highL * (highGain - 1.0f);
    *right = dryR + lowR * (lowGain - 1.0f) + highR * (highGain - 1.0f);
    const float normalization = std::fmax(p[kMaxBoost], std::fmax(p[kMaxCut], 1.0f));
    S.mix = clampf(std::fmax(std::fabs(S.lowGainDb), std::fabs(S.highGainDb)) / normalization, 0.0f, 1.0f);
}

// `dialL`/`dialR` are the band-pass outputs of the chunk pre-pass for frame j (null arrays on the scalar fade-out path).
void levelerSample(LdShared &S, const float *p, float *left, float *right, const float *dialLs, const float *dialRs, uint32_t j) {
    const bool enabled = p[kLevOn] > 0.5f;
    if (!enabled && S.levParked != 0) return;
    if (enabled && S.levParked != 0) unparkLeveler(S);
    const float dryL = *left, dryR = *right;
    float dialL, dialR;
    if (dialLs != nullptr) {
        dialL = dialLs[j];
        dialR = dialRs[j];
    } else {
        dialL = runBq(S.bandHp, S.hpL, dryL);
        dialL = runBq(S.bandLp, S.lpL, dialL);
        dialR = runBq(S.bandHp, S.hpR, dryR);
        dialR = runBq(S.bandLp, S.lpR, dialR);
    }
    const float programPower = 0.5f * (dryL * dryL + dryR * dryR);
    const float dialoguePower = 0.5f * (dialL * dialL + dialR * dialR);
    S.progMs = smoothToward(S.progMs, programPower, S.detectorPole);
    S.bandMs = smoothToward(S.bandMs, dialoguePower, S.detectorPole);
    S.progDbfs = 10.0f * std::log10(std::fmax(S.progMs, kEpsilon));
    S.bandDbfs = 10.0f * std::log10(std::fmax(S.bandMs, kEpsilon));
    S.gapDb = S.progDbfs - S.bandDbfs;
    const float envInput = std::sqrt(std::fmax(dialoguePower, 0.0f));
    S.voiceEnv = smoothToward(S.voiceEnv, envInput, S.envPole);
    const float modHp = S.voiceEnv - S.modPrev + S.modHpPole * S.modHpOut;
    S.modPrev = S.voiceEnv;
    S.modHpOut = modHp;
    const float modLp = (1.0f - S.modLpPole) * modHp + S.modLpPole * S.modLpOut;
    S.modLpOut = modLp;
    const float modPower = modLp * modLp;
    S.modMs = smoothToward(S.modMs, modPower, S.measPole);
    const float modIndex = std::sqrt(std::fmax(S.modMs, 0.0f)) / std::fmax(S.voiceEnv, 1.0e-6f);
    float mapped = (modIndex - p[kConfFloor]) / std::fmax(p[kConfCeil] - p[kConfFloor], 1.0e-6f);
    mapped = clampf(mapped, 0.0f, 1.0f);
    S.confidence = p[kVoiceGate] > 0.5f ? p[kMinConf] + (1.0f - p[kMinConf]) * mapped : 1.0f;
    float targetBoost = 0.0f;
    if (enabled && S.progDbfs >= p[kProgramGate]) {
        const float excess = std::fmax(0.0f, S.gapDb - p[kTargetGap]);
        const float fraction = p[kBoostRatio] > 1.0f ? (1.0f - 1.0f / p[kBoostRatio]) : 0.0f;
        targetBoost = std::fmin(p[kLevMaxBoost], excess * fraction) * S.confidence;
    }
    const float coef = !enabled ? S.bypassCoef : (targetBoost > S.boostDb ? S.levAttackPole : S.levReleasePole);
    S.boostDb = smoothToward(S.boostDb, targetBoost, coef);
    if (!enabled && nearZero(S.boostDb)) {
        S.boostDb = 0.0f;
        S.progMs = S.bandMs = S.voiceEnv = S.modPrev = S.modHpOut = S.modLpOut = S.modMs = 0.0f;
        S.progDbfs = S.bandDbfs = S.gapDb = S.confidence = 0.0f;
        clearLevelerFilters(S);
        S.levParked = 1;
        return;
    }
    const float bandGain = dbToLinear(S.boostDb);
    *left = dryL + dialL * (bandGain - 1.0f);
    *right = dryR + dialR * (bandGain - 1.0f);
}

float getParam(const float *params, uint32_t idx, uint32_t changed, float value) { return idx == changed ? value : params[idx]; }

void store(LdShared &S, Tel slot, float v) { S.tel[slot].store(floatToBits(v), std::memory_order_relaxed); }

}  // namespace

bool isLoudnessKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_LOUDNESS; }

bool loudnessParamOk(const float *params, uint32_t idx, float v, double rate) {
    auto g = [&](uint32_t i) { return getParam(params, i, idx, v); };
    switch (idx) {
        case kMatchOn: case kMatchGate: case kContourOn: case kPerBand: case kLevelSource: case kLevOn: case kVoiceGate:
            return isFlag(v);
        case kTargetLufs: return inR(v, -24.0, -10.0);
        case kMaxCorrection: return inR(v, 3.0, 20.0);
        case kMatchAttack: return inR(v, 0.3, 5.0);
        case kMatchRelease: return inR(v, 1.0, 10.0);
        case kStrength: return inR(v, 0.0, 1.0);
        case kRefPhons: return inR(v, 60.0, 95.0);
        case kMaxBoost: return inR(v, 6.0, 20.0);
        case kMaxCut: return inR(v, 0.0, 6.0);
        case kMasterGain: return inR(v, 0.0, 1.0);
        case kBandLow: return inR(v, 100.0, 8000.0) && v < g(kBandHigh);
        case kBandHigh: return inR(v, 100.0, 8000.0) && v > g(kBandLow) && double(v) < rate * 0.45;
        case kTargetGap: return inR(v, 3.0, 20.0);
        case kBoostRatio: return inR(v, 1.0, 6.0);
        case kLevMaxBoost: return inR(v, 0.0, 15.0);
        case kDetectorMs: return inR(v, 50.0, 500.0);
        case kLevAttackMs: return inR(v, 10.0, 1000.0);
        case kLevReleaseMs: return inR(v, 50.0, 3000.0);
        case kProgramGate: return inR(v, -70.0, -30.0);
        case kModLowHz: return inR(v, 0.5, 10.0) && v < g(kModHighHz);
        case kModHighHz: return inR(v, 3.0, 14.0) && v > g(kModLowHz) && double(v) < rate * 0.45;
        case kEnvelopeMs: return inR(v, 5.0, 30.0);
        case kMeasureMs: return inR(v, 300.0, 1500.0);
        case kConfFloor: return inR(v, 0.0, 1.0) && v < g(kConfCeil);
        case kConfCeil: return inR(v, 0.0, 1.0) && v > g(kConfFloor);
        case kMinConf: return inR(v, 0.0, 1.0);
        default: return false;
    }
}

n60_status validateLoudnessStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    // 8 kHz shelf and the K-weighting shelf must sit below 0.45 fs, as the kernel's setters require.
    if (!(rate >= 20000.0 && rate <= 768000.0) || !isLoudnessKind(s.kind) || s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneMask != 0 || s.laneA >= outCh || s.laneB >= outCh || s.laneA == s.laneB) return N60_STATUS_BAD_ARGUMENT;
    if (s.params == nullptr || s.paramCount != kParams) return N60_STATUS_BAD_ARGUMENT;
    for (uint32_t i = 0; i < kParams; ++i) {
        if (!loudnessParamOk(s.params, i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void loudnessSizes(const n60_stage_desc &, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(sizeof(LdShared));
}

void loudnessInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    LdShared &S = *new (sharedState(h, r)) LdShared{};
    S.bypassCoef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    std::memcpy(S.seen, p, sizeof S.seen);
    designMatch(S, rate, p);
    if (!designBq(Kind::HighPass, rate, kKHighPassHz, 0.0, kKHighPassQ, S.kHp)) S.kHp = identityBq();
    if (!designBq(Kind::HighShelf, rate, kKShelfHz, kKShelfDb, kKShelfQ, S.kShelf)) S.kShelf = identityBq();
    designContour(S, rate, p);
    if (!designBq(Kind::LowPass, rate, kLowShelfHz, 0.0, kQ, S.lowBand)) S.lowBand = identityBq();
    if (!designBq(Kind::HighPass, rate, kHighShelfHz, 0.0, kQ, S.highBand)) S.highBand = identityBq();
    S.responsePole = poleForMs(rate, kGainResponseMs);
    designLeveler(S, rate, p);
    S.matchParked = 1;
    S.contourParked = 1;
    S.levParked = 1;
    for (auto &t : S.tel) t.store(0, std::memory_order_relaxed);
}

// E20 S3: denormals are flushed in hardware (platform/fpenv.hpp, the guard in n60_graph_process), so no per-block flush.
static_assert(std::atomic<uint32_t>::is_always_lock_free, "telemetry atomics must be lock free");
// Telemetry fields are separate relaxed stores, so a reader may see a mix of two blocks; a NaN input persists in the
// filter state until the next rebuild, as in the kernel.

void runLoudness(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    const float *p = paramsOf(h, r);
    LdShared &S = *reinterpret_cast<LdShared *>(sharedState(h, r));
    const double rate = h->sampleRate;
    float *L = lanes[r.laneA];
    float *R = lanes[r.laneB];
    if (p[kMatchAttack] != S.seen[kMatchAttack] || p[kMatchRelease] != S.seen[kMatchRelease]) designMatch(S, rate, p);
    if (p[kStrength] != S.seen[kStrength]) designContour(S, rate, p);
    if (levelerMoved(S, p)) designLeveler(S, rate, p);
    const bool matchOn = p[kMatchOn] > 0.5f;
    const bool contourOn = p[kContourOn] > 0.5f;
    const bool perBand = p[kPerBand] > 0.5f;
    const bool levOn = p[kLevOn] > 0.5f;
    const bool measure = matchOn || (contourOn && perBand && p[kLevelSource] > 0.5f);
    static_assert(2 * sizeof(f64x2) * kLdChunk + 2 * sizeof(double) * kLdChunk + 4 * sizeof(float) * kLdChunk <= 16384, "stack scratch");
    f64x2 xv[kLdChunk], yv[kLdChunk];
    double inst[kLdChunk], msv[kLdChunk];
    float cw[4][kLdChunk];
    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = std::min(kLdChunk, frames - done);
        float *l = L + done, *rr = R + done;
        // Match: the K-weighting filters need only the stage input.
        if (measure) {
            if (S.matchParked != 0) {
                clearMatchAll(S);
                S.matchParked = 0;
            }
            loadPair(xv, l, rr, n);
            bqPair(S.kHp, S.kHpL, S.kHpR, xv, n);
            bqPair(S.kShelf, S.kShL, S.kShR, xv, n);
            for (uint32_t i = 0; i < n; ++i) {
                const double wl = simd::lane(xv[i], 0), wr = simd::lane(xv[i], 1);
                inst[i] = 0.5 * (wl * wl + wr * wr);
            }
        }
        for (uint32_t i = 0; i < n; ++i) {
            matchSample(S, p, &l[i], &rr[i], measure ? inst[i] : 0.0);
            msv[i] = S.meanSquare;
        }
        // Contour: filters run ahead while it is enabled (it cannot park inside the block); a fade-out stays per sample.
        ContourPre pre{cw[0], cw[1], cw[2], cw[3]};
        if (contourOn) {
            if (S.contourParked != 0) unparkContour(S);
            loadPair(xv, l, rr, n);
            if (!perBand) {
                bqPair(S.lowShelf, S.lowShL, S.lowShR, xv, n);
                roundToFloat(xv, n);
                bqPair(S.highShelf, S.highShL, S.highShR, xv, n);
                roundToFloat(xv, n);
                storePair(cw[0], cw[1], xv, n);
            } else {
                std::memcpy(yv, xv, sizeof(f64x2) * n);
                bqPair(S.lowBand, S.lowBandL, S.lowBandR, xv, n);
                roundToFloat(xv, n);
                storePair(cw[0], cw[1], xv, n);
                bqPair(S.highBand, S.highBandL, S.highBandR, yv, n);
                roundToFloat(yv, n);
                storePair(cw[2], cw[3], yv, n);
            }
        }
        for (uint32_t i = 0; i < n; ++i) contourSample(S, p, &l[i], &rr[i], msv[i], contourOn ? &pre : nullptr, i);
        // Leveler: the dialogue band filters run ahead while it is enabled.
        if (levOn) {
            if (S.levParked != 0) unparkLeveler(S);
            loadPair(xv, l, rr, n);
            bqPair(S.bandHp, S.hpL, S.hpR, xv, n);
            roundToFloat(xv, n);
            bqPair(S.bandLp, S.lpL, S.lpR, xv, n);
            roundToFloat(xv, n);
            storePair(cw[0], cw[1], xv, n);
        }
        for (uint32_t i = 0; i < n; ++i) levelerSample(S, p, &l[i], &rr[i], levOn ? cw[0] : nullptr, levOn ? cw[1] : nullptr, i);
        done += n;
    }
    store(S, kTLufs, meanSquareLufs(S.meanSquare));
    store(S, kTMatch, S.matchGainDb);
    store(S, kTScale, S.mix);
    store(S, kTLowComp, S.lowGainDb);
    store(S, kTHighComp, S.highGainDb);
    store(S, kTPhons, S.phons);
    store(S, kTProg, S.progDbfs);
    store(S, kTBand, S.bandDbfs);
    store(S, kTGap, S.gapDb);
    store(S, kTConf, S.confidence);
    store(S, kTBoost, S.boostDb);
}

n60_status validateLoudnessParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    return loudnessParamOk(paramsOf(h, r), idx, value, h->sampleRate) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
}

uint64_t loudnessCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING {
    uint64_t bytes = 0;
    if (from == nullptr || to == nullptr || from->sampleRate != to->sampleRate) return bytes;
    const StageRec *src = stages(from);
    StageRec *dst = stages(to);
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (dst[i].kind != N60_STAGE_LOUDNESS) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != N60_STAGE_LOUDNESS || src[j].id != dst[i].id) continue;
            const LdShared &a = *reinterpret_cast<const LdShared *>(sharedState(from, src[j]));
            LdShared &b = *reinterpret_cast<LdShared *>(sharedState(to, dst[i]));
            bytes += sizeof(LdShared);
            // match
            b.kHpL = a.kHpL; b.kHpR = a.kHpR; b.kShL = a.kShL; b.kShR = a.kShR;
            b.meanSquare = a.meanSquare; b.primed = a.primed;
            b.matchGainDb = a.matchGainDb; b.matchParked = a.matchParked;
            // contour
            b.lowShL = a.lowShL; b.lowShR = a.lowShR; b.highShL = a.highShL; b.highShR = a.highShR;
            b.lowBandL = a.lowBandL; b.lowBandR = a.lowBandR; b.highBandL = a.highBandL; b.highBandR = a.highBandR;
            b.mix = a.mix; b.lowGainDb = a.lowGainDb; b.highGainDb = a.highGainDb; b.phons = a.phons;
            b.contourParked = a.contourParked;
            // leveler
            b.hpL = a.hpL; b.hpR = a.hpR; b.lpL = a.lpL; b.lpR = a.lpR;
            b.progMs = a.progMs; b.bandMs = a.bandMs; b.voiceEnv = a.voiceEnv; b.modPrev = a.modPrev;
            b.modHpOut = a.modHpOut; b.modLpOut = a.modLpOut; b.modMs = a.modMs; b.boostDb = a.boostDb;
            b.progDbfs = a.progDbfs; b.bandDbfs = a.bandDbfs; b.gapDb = a.gapDb; b.confidence = a.confidence;
            b.levParked = a.levParked;
            break;
        }
    }
    return bytes;
}

bool readLoudness(const SnapHeader *h, uint32_t stageId, n60_loudness_readback *out) {
    const StageRec *r = findStage(const_cast<SnapHeader *>(h), stageId);
    if (r == nullptr || r->kind != N60_STAGE_LOUDNESS) return false;
    LdShared &S = *reinterpret_cast<LdShared *>(sharedState(const_cast<SnapHeader *>(h), *r));
    auto ld = [&](Tel t) { return bitsToFloat(S.tel[t].load(std::memory_order_relaxed)); };
    out->shortTermLufs = ld(kTLufs);
    out->matchGainDb = ld(kTMatch);
    out->contourScale = ld(kTScale);
    out->lowCompensationDb = ld(kTLowComp);
    out->highCompensationDb = ld(kTHighComp);
    out->estimatedPhons = ld(kTPhons);
    out->dialogueProgramDbfs = ld(kTProg);
    out->dialogueBandDbfs = ld(kTBand);
    out->dialogueGapDb = ld(kTGap);
    out->dialogueVoiceConfidence = ld(kTConf);
    out->dialogueBoostDb = ld(kTBoost);
    out->reserved = 0;
    return true;
}

}  // namespace n60
