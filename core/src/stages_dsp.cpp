// libn60core ABI v3 stages (E6 S4): compressor, expander, dynamic EQ, spectral denoiser
// and program FIR. Portable C++20, standard library plus the FFT abstraction in fft.hpp;
// no Apple framework, no exceptions, no RTTI. These are ports of the stereo kernel's
// tuning (N60Dynamics.c, N60DynamicEQ.c, N60SpectralDenoiser.c, N60ProgramFIRRuntime.h)
// to any lane count, written from the public descriptions of the algorithms.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runDsp:
//  - allocation: none. All state, FFT plans, windows and work buffers live in the
//    snapshot arena, built on the control thread by dspInit.
//  - synchronisation: none. The realtime thread owns the state once the snapshot is
//    published; parameters are read as plain floats the mailbox wrote at block start.
//  - latency: compressor, expander and dynamic EQ add 0 frames; the denoiser adds its
//    FFT size (1024, 2048 or 4096); the FIR adds 256 frames plus its declared latency.
//    The host reports the per-lane sum through n60_graph_latency_frames.
//  - sample rate: any rate in [8 kHz, 768 kHz]. Time constants are in milliseconds and
//    converted per block; the FIR partition size (256 frames) and the denoiser FFT sizes
//    are frame counts, independent of rate.
//  - channels: 1..64 lanes per stage. Linked groups (compressor, expander, dynamic EQ
//    with linked = 1, denoiser always) share one detector and one gain across the
//    selected lanes; everything else is per lane.
//  - reset: a new snapshot starts all state at zero (gains at unity, filters empty,
//    denoiser with no noise profile, FIR history silent). There is no in-place reset.
// Blocks may be any length from 1 to maxBlockFrames; results do not depend on block
// size (the spectral stages buffer internally).
#include "stages_dsp.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "fft.hpp"

namespace n60 {
namespace {

using fft::Complex;

constexpr float kDbToLin = 0.16609640474436813f;  // log2(10) / 20
constexpr float kLinToDb = 6.020599913279624f;    // 20 / log2(10)
constexpr size_t kAlign = 16;
constexpr uint32_t kMaxLanes = N60_GRAPH_MAX_CHANNELS;

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
float db2lin(float db) { return std::exp2(db * kDbToLin); }
float lin2db(float x, float eps) { return kLinToDb * std::log2(std::max(x, eps)); }

// One-pole smoothing coefficient for a time constant in milliseconds (as the kernel:
// exp(-1 / samples), time clamped to 0.05 .. 5000 ms).
float pole(double rate, float ms) {
    const double t = std::clamp<double>(ms, 0.05, 5000.0);
    return static_cast<float>(std::exp(-1.0 / (rate * t / 1000.0)));
}

// Transposed direct form II, double state, float in and out. A non-finite result resets
// the section rather than latching NaN into the state.
float biquad(const double c[5], double z[2], float in) {
    const double x = in;
    const double y = c[0] * x + z[0];
    const double n1 = c[1] * x - c[3] * y + z[1];
    const double n2 = c[2] * x - c[4] * y;
    if (!std::isfinite(y) || !std::isfinite(n1) || !std::isfinite(n2)) {
        z[0] = z[1] = 0.0;
        return 0.0f;
    }
    z[0] = n1;
    z[1] = n2;
    return static_cast<float>(y);
}

// Zero tiny or non-finite float state so quiet tails never sit in denormals.
void fz(float &v) {
    if (!(std::fabs(v) >= 1e-20f) || !std::isfinite(v)) v = 0.0f;
}

void flush(double z[2]) {
    if (std::fabs(z[0]) < 1e-30) z[0] = 0.0;
    if (std::fabs(z[1]) < 1e-30) z[1] = 0.0;
}

// ---- parameter tables --------------------------------------------------------------

struct Range {
    float lo, hi;
    bool integer;
};

constexpr Range kComp[10] = {{-96, 0, false}, {1, 100, false}, {0, 24, false}, {0.05f, 1000, false}, {1, 5000, false},
                             {-24, 24, false}, {0, 1, true},   {0, 1, true},   {0, 300, false},      {0, 1, true}};
constexpr Range kExp[6] = {{-120, 0, false}, {1, 20, false}, {-96, 0, false}, {0.05f, 1000, false}, {1, 5000, false},
                           {0, 1, true}};
constexpr Range kBand[N60_DYN_EQ_BAND_PARAMS] = {
    {0, 5, true},       {20, 20000, false}, {0.4f, 8, false}, {-18, 6, false}, {-60, 0, false},
    {1, 10, false},     {-24, 0, false},    {1, 100, false},  {10, 1000, false}, {0, 2, true},
    {-60, 0, false},    {1, 10, false},     {0, 12, false},   {0, 1, true},    {5, 200, false}};
constexpr Range kDenoise[9] = {{0, 4, true},       {0, 2, true},       {0, 1, false},      {-96, -30, false}, {0, 1, true},
                               {0, 20000, false}, {0, 20000, false},  {0, 2, true},       {0, 16777216.0f, true}};

bool inRange(const Range &r, float v) {
    return std::isfinite(v) && v >= r.lo && v <= r.hi && (!r.integer || v == std::floor(v));
}

uint32_t bandCountOf(uint32_t paramCount) { return paramCount >= 1 ? (paramCount - 1) / N60_DYN_EQ_BAND_PARAMS : 0; }

bool paramOk(uint32_t kind, uint32_t idx, float v, double rate) {
    switch (kind) {
        case N60_STAGE_COMPRESSOR: return idx < 10 && inRange(kComp[idx], v);
        case N60_STAGE_EXPANDER: return idx < 6 && inRange(kExp[idx], v);
        case N60_STAGE_DYN_EQ: {
            if (idx == 0) return v == 0.0f || v == 1.0f;
            const uint32_t f = (idx - 1) % N60_DYN_EQ_BAND_PARAMS;
            if (!inRange(kBand[f], v)) return false;
            return f != 1 || v < static_cast<float>(rate * 0.5);
        }
        case N60_STAGE_DENOISER:
            if (idx >= 9 || !inRange(kDenoise[idx], v)) return false;
            return idx != 6 || v < static_cast<float>(rate * 0.5);
        case N60_STAGE_FIR: return std::isfinite(v);
        default: return false;
    }
}

// Which parameters may change on a published snapshot (the rest need a new topology).
bool paramLive(uint32_t kind, uint32_t idx) {
    switch (kind) {
        case N60_STAGE_COMPRESSOR: return idx <= 8;
        case N60_STAGE_EXPANDER: return idx <= 4;
        case N60_STAGE_DYN_EQ: {
            if (idx == 0) return false;
            const uint32_t f = (idx - 1) % N60_DYN_EQ_BAND_PARAMS;
            return f != 0 && f != 9;
        }
        case N60_STAGE_DENOISER: return idx >= 2;
        default: return false;
    }
}

uint32_t denoiseFft(float quality) { return 1024u << static_cast<uint32_t>(quality); }

// ---- compressor and expander -------------------------------------------------------

struct CompLane {
    double z[2];     // sidechain high-pass state
    float gainDB;    // smoothed gain; the shared gain of a linked group lives in the group's first lane
    std::atomic<uint32_t> grMaxBits;  // ABI v8: deepest reduction (dB, >= 0) since the last read, on every lane of the group
    std::atomic<uint32_t> grNowBits;  // reduction at the end of the last block
};

struct CompShared {
    double hp[5];
    float usedHz;
    uint32_t hasHp;
};

struct ExpLane {
    float gainDB;
    std::atomic<uint32_t> grMaxBits;  // as CompLane
    std::atomic<uint32_t> grNowBits;
    float pad;
};

// Publishes the per-group gain reduction of one block to every lane of the group (control-thread readback).
// The caller has already flushed denormals in the gain; st[g * per] holds the group's gain.
template <typename Lane>
void publishReduction(Lane *const *st, uint32_t per, uint32_t groups, const float *grMax) {
    for (uint32_t g = 0; g < groups; ++g) {
        const float now = std::max(0.0f, -st[g * per]->gainDB);
        const float peak = std::max(0.0f, grMax[g]);
        for (uint32_t k = 0; k < per; ++k) {
            Lane &ln = *st[g * per + k];
            atomicMaxFloat(ln.grMaxBits, peak);
            ln.grNowBits.store(floatToBits(now), std::memory_order_relaxed);
        }
    }
}

float compTargetDb(float detDb, float thr, float slope, float knee, float makeup) {
    const float over = detDb - thr;
    float c = 0.0f;
    if (knee <= 0.0f) {
        if (over > 0.0f) c = slope * over;
    } else {
        const float half = knee * 0.5f;
        if (over >= half) {
            c = slope * over;
        } else if (over > -half) {
            const float k = over + half;
            c = slope * k * k / (2.0f * knee);
        }
    }
    return c + makeup;
}

void runCompressor(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    const float thr = p[0], ratio = p[1], knee = p[2], makeup = p[5], hpHz = p[8];
    const bool feedback = p[6] >= 0.5f, pdr = p[7] >= 0.5f, linked = p[9] >= 0.5f;
    const float slope = 1.0f / ratio - 1.0f;
    const float atk = pole(rate, p[3]), rel = pole(rate, p[4]);
    const float fast = pole(rate, std::max(p[4] * 0.5f, 1.0f)), slow = pole(rate, std::min(p[4] * 2.0f, 5000.0f));
    CompShared &sh = *reinterpret_cast<CompShared *>(sharedState(h, r));
    if (hpHz != sh.usedHz) {
        sh.usedHz = hpHz;
        sh.hasHp = 0;
        if (hpHz > 0.0f && designBiquad(4, rate, hpHz, 0.0, 0.7071067811865476, sh.hp)) sh.hasHp = 1;
    }
    const uint32_t n = r.laneCount;
    float *lp[kMaxLanes];
    CompLane *st[kMaxLanes];
    for (uint32_t l = 0; l < n; ++l) {
        lp[l] = lanes[laneOf(r, l)];
        st[l] = reinterpret_cast<CompLane *>(laneState(h, r, l));
    }
    const uint32_t per = linked ? n : 1, groups = linked ? 1 : n;
    float grMax[kMaxLanes] = {};
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t g = 0; g < groups; ++g) {
            CompLane &gs = *st[g * per];
            const float feed = feedback ? db2lin(gs.gainDB) : 1.0f;
            float det = 0.0f;
            for (uint32_t k = 0; k < per; ++k) {
                const uint32_t l = g * per + k;
                const float xin = lp[l][i] * feed;
                const float y = sh.hasHp ? biquad(sh.hp, st[l]->z, xin) : xin;
                det = std::max(det, std::fabs(y));
            }
            det = std::min(det, 1e6f);  // keeps an Inf input from poisoning the gain
            const float target = compTargetDb(lin2db(det, 1e-12f), thr, slope, knee, makeup);
            float c;
            if (target < gs.gainDB) {
                c = atk;
            } else if (pdr) {
                const float depth = std::clamp(-gs.gainDB / 12.0f, 0.0f, 1.0f);
                c = fast + depth * (slow - fast);
            } else {
                c = rel;
            }
            gs.gainDB = target + c * (gs.gainDB - target);
            grMax[g] = std::max(grMax[g], -gs.gainDB);
            const float gain = db2lin(gs.gainDB);
            for (uint32_t k = 0; k < per; ++k) lp[g * per + k][i] *= gain;
        }
    }
    for (uint32_t l = 0; l < n; ++l) {
        flush(st[l]->z);
        fz(st[l]->gainDB);
    }
    publishReduction(st, per, groups, grMax);
}

void runExpander(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    const double rate = h->sampleRate;
    const float thr = p[0], ratio = p[1], range = p[2];
    const bool linked = p[5] >= 0.5f;
    const float atk = pole(rate, p[3]), rel = pole(rate, p[4]);
    const uint32_t n = r.laneCount;
    float *lp[kMaxLanes];
    ExpLane *st[kMaxLanes];
    for (uint32_t l = 0; l < n; ++l) {
        lp[l] = lanes[laneOf(r, l)];
        st[l] = reinterpret_cast<ExpLane *>(laneState(h, r, l));
    }
    const uint32_t per = linked ? n : 1, groups = linked ? 1 : n;
    float grMax[kMaxLanes] = {};
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t g = 0; g < groups; ++g) {
            ExpLane &gs = *st[g * per];
            float det = 0.0f;
            for (uint32_t k = 0; k < per; ++k) det = std::max(det, std::fabs(lp[g * per + k][i]));
            const float detDb = lin2db(std::min(det, 1e6f), 1e-12f);
            const float target = detDb >= thr ? 0.0f : std::max((ratio - 1.0f) * (detDb - thr), range);
            const float c = target < gs.gainDB ? atk : rel;
            gs.gainDB = target + c * (gs.gainDB - target);
            grMax[g] = std::max(grMax[g], -gs.gainDB);
            const float gain = db2lin(gs.gainDB);
            for (uint32_t k = 0; k < per; ++k) lp[g * per + k][i] *= gain;
        }
    }
    for (uint32_t l = 0; l < n; ++l) {
        fz(st[l]->gainDB);
    }
    publishReduction(st, per, groups, grMax);
}

// ---- dynamic EQ --------------------------------------------------------------------

struct DqBand {
    double an[5], pr[5], sc[5];  // analysis, primary and secondary basis filters
    float atkC, relC, rmsC, usedShape;
    float usedFreq, usedQ, pad0, pad1;
};

struct DqShared {
    float bypassC;  // 5 ms pole for the static-gain and wet fades
    float pad[3];
    // DqBand bands[] follow
};

struct DqLaneBand {
    double aZ[2], pZ[2], sZ[2];
    float rms, dyn, stat, wet;
};

DqBand *dqBands(DqShared *s) { return reinterpret_cast<DqBand *>(s + 1); }

void dqDesign(uint32_t shape, double rate, double f, double q, DqBand &b) {
    const double w = 2.0 * 3.14159265358979323846 * f / rate;
    const double cw = std::cos(w), sw = std::sin(w);
    const double alpha = sw / (2.0 * q);
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * cw / a0, a2 = (1.0 - alpha) / a0;
    const double bp[5] = {alpha / a0, 0.0, -alpha / a0, a1, a2};
    const double omc = 2.0 * std::sin(w * 0.5) * std::sin(w * 0.5);  // 1 - cos, without cancellation
    const double opc = 2.0 * std::cos(w * 0.5) * std::cos(w * 0.5);  // 1 + cos
    const double lp[5] = {omc * 0.5 / a0, omc / a0, omc * 0.5 / a0, a1, a2};
    const double hp[5] = {opc * 0.5 / a0, -opc / a0, opc * 0.5 / a0, a1, a2};
    const double id[5] = {1.0, 0.0, 0.0, 0.0, 0.0};
    const double *an = bp, *pr = bp, *sc = id;
    if (shape == 1) {
        an = pr = lp;
    } else if (shape == 2) {
        an = pr = hp;
    } else if (shape == 5) {
        an = bp;
        pr = lp;
        sc = hp;
    }
    std::memcpy(b.an, an, sizeof b.an);
    std::memcpy(b.pr, pr, sizeof b.pr);
    std::memcpy(b.sc, sc, sizeof b.sc);
}

void dqRefresh(const SnapHeader *h, const StageRec &r, DqShared *sh, const float *p) {
    const uint32_t nb = bandCountOf(r.paramCount);
    DqBand *bands = dqBands(sh);
    for (uint32_t b = 0; b < nb; ++b) {
        const float *prm = p + 1 + N60_DYN_EQ_BAND_PARAMS * b;
        DqBand &bc = bands[b];
        if (bc.usedShape != prm[0] || bc.usedFreq != prm[1] || bc.usedQ != prm[2]) {
            bc.usedShape = prm[0];
            bc.usedFreq = prm[1];
            bc.usedQ = prm[2];
            dqDesign(static_cast<uint32_t>(prm[0]), h->sampleRate, prm[1], prm[2], bc);
        }
        bc.atkC = pole(h->sampleRate, prm[7]);
        bc.relC = pole(h->sampleRate, prm[8]);
        bc.rmsC = pole(h->sampleRate, prm[14]);
    }
}

float dqTargetDb(float detDb, const float *prm) {
    const uint32_t dir = static_cast<uint32_t>(prm[9]);
    float cut = 0.0f, boost = 0.0f;
    if ((dir == 0 || dir == 2) && detDb > prm[4] && prm[5] > 1.0f) {
        cut = std::max(-(detDb - prm[4]) * (1.0f - 1.0f / prm[5]), prm[6]);
    }
    if ((dir == 1 || dir == 2) && detDb < prm[10] && prm[11] > 1.0f) {
        boost = std::min((prm[10] - detDb) * (1.0f - 1.0f / prm[11]), prm[12]);
    }
    return cut + boost;
}

void runDynEq(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    DqShared *sh = reinterpret_cast<DqShared *>(sharedState(h, r));
    dqRefresh(h, r, sh, p);
    const DqBand *bands = dqBands(sh);
    const uint32_t nb = bandCountOf(r.paramCount);
    const bool linked = p[0] >= 0.5f;
    const uint32_t n = r.laneCount;
    float *lp[kMaxLanes];
    DqLaneBand *lb[kMaxLanes];
    for (uint32_t l = 0; l < n; ++l) {
        lp[l] = lanes[laneOf(r, l)];
        lb[l] = reinterpret_cast<DqLaneBand *>(laneState(h, r, l));
    }
    const uint32_t per = linked ? n : 1, groups = linked ? 1 : n;
    const float bypassC = sh->bypassC;
    float xin[kMaxLanes];
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t g = 0; g < groups; ++g) {
            for (uint32_t b = 0; b < nb; ++b) {
                const float *prm = p + 1 + N60_DYN_EQ_BAND_PARAMS * b;
                const DqBand &bc = bands[b];
                DqLaneBand &hold = lb[g * per][b];
                float peak = 0.0f, power = 0.0f;
                for (uint32_t k = 0; k < per; ++k) {
                    const uint32_t l = g * per + k;
                    xin[k] = lp[l][i];
                    const float a = std::clamp(biquad(bc.an, lb[l][b].aZ, xin[k]), -1e6f, 1e6f);
                    peak = std::max(peak, std::fabs(a));
                    power += a * a;
                }
                float det;
                if (prm[13] >= 0.5f) {
                    const float inst = power / static_cast<float>(per);
                    hold.rms = inst + bc.rmsC * (hold.rms - inst);
                    det = std::sqrt(std::max(hold.rms, 0.0f));
                } else {
                    det = peak;
                    hold.rms = det * det;
                }
                const float target = dqTargetDb(lin2db(det, 1e-20f), prm);
                const float c = std::fabs(target) > std::fabs(hold.dyn) ? bc.atkC : bc.relC;
                hold.dyn = target + c * (hold.dyn - target);
                hold.stat = prm[3] + bypassC * (hold.stat - prm[3]);
                hold.wet = 1.0f + bypassC * (hold.wet - 1.0f);
                const float total = std::clamp(hold.stat + hold.dyn, -42.0f, 18.0f);
                const bool tilt = prm[0] == 5.0f;
                const float half = 0.5f * total;
                const float lowScale = tilt ? (db2lin(-half) - 1.0f) * hold.wet : 0.0f;
                const float highScale = tilt ? (db2lin(half) - 1.0f) * hold.wet : 0.0f;
                const float flat = (db2lin(total) - 1.0f) * hold.wet;
                for (uint32_t k = 0; k < per; ++k) {
                    const uint32_t l = g * per + k;
                    DqLaneBand &s = lb[l][b];
                    const float prim = biquad(bc.pr, s.pZ, xin[k]);
                    if (tilt) {
                        const float sec = biquad(bc.sc, s.sZ, xin[k]);
                        lp[l][i] = xin[k] + lowScale * prim + highScale * sec;
                    } else {
                        lp[l][i] = xin[k] + flat * prim;
                    }
                }
            }
        }
    }
    for (uint32_t l = 0; l < n; ++l) {
        for (uint32_t b = 0; b < nb; ++b) {
            flush(lb[l][b].aZ);
            flush(lb[l][b].pZ);
            flush(lb[l][b].sZ);
            fz(lb[l][b].dyn);
            fz(lb[l][b].rms);
            fz(lb[l][b].stat);
        }
    }
}

// ---- spectral denoiser -------------------------------------------------------------

struct DnShared {
    uint32_t n, bins, hop, quality;
    uint32_t filled, sinceFrame, w, o;  // stream position, common to every lane
    uint32_t adaptiveFrames, adaptiveTarget, adaptiveBlocks, lastRevision;
    uint32_t captureCollected, captureTarget;
    float windowSum;
    bool adaptiveFresh, profileReady, captured, captureActive;
    bool history, pad[3];
};

struct DnLayout {
    size_t plan, window, noise, aMin, capSum, prevEnh, linked, target, smooth, total;
};

DnLayout dnLayout(uint32_t n) {
    DnLayout L;
    const size_t bins = n / 2 + 1;
    size_t off = up(sizeof(DnShared));
    L.plan = off;
    off += up(fft::planBytes(n));
    L.window = off;
    off += up(sizeof(float) * n);
    auto bin = [&](size_t &slot) {
        slot = off;
        off += up(sizeof(float) * bins);
    };
    bin(L.noise);
    bin(L.aMin);
    bin(L.capSum);
    bin(L.prevEnh);
    bin(L.linked);
    bin(L.target);
    bin(L.smooth);
    L.total = off;
    return L;
}

// Per-lane layout: float in[n]; float acc[2n]; Complex spec[n].
size_t dnLaneBytes(uint32_t n) { return up(sizeof(float) * 3 * n + sizeof(Complex) * n); }

struct DnTuning {
    float minGain, alpha, attack, release;
    uint32_t radius;
    float dehiss;
};

DnTuning dnTuning(uint32_t id) {
    switch (id) {
        case 0: return {0.35f, 0.97f, 0.82f, 0.45f, 2, 0.0f};
        case 2: return {0.08f, 0.94f, 0.68f, 0.30f, 1, 0.0f};
        case 3: return {0.18f, 0.96f, 0.78f, 0.35f, 2, 1.0f};
        default: return {0.20f, 0.96f, 0.75f, 0.35f, 1, 0.0f};  // standard and custom
    }
}

struct DnView {
    DnShared *s;
    const void *plan;
    float *window, *noise, *aMin, *capSum, *prevEnh, *linked, *target, *smooth;
};

DnView dnView(uint8_t *base) {
    DnShared *s = reinterpret_cast<DnShared *>(base);
    const DnLayout L = dnLayout(s->n);
    return {s, base + L.plan, reinterpret_cast<float *>(base + L.window), reinterpret_cast<float *>(base + L.noise),
            reinterpret_cast<float *>(base + L.aMin), reinterpret_cast<float *>(base + L.capSum),
            reinterpret_cast<float *>(base + L.prevEnh), reinterpret_cast<float *>(base + L.linked),
            reinterpret_cast<float *>(base + L.target), reinterpret_cast<float *>(base + L.smooth)};
}

// Learns, or captures, the per-bin noise power from the linked power spectrum.
void dnUpdateProfile(DnView &V, double rate, float ceilingPower) {
    DnShared &S = *V.s;
    const uint32_t bins = S.bins;
    if (S.adaptiveTarget == 0) {
        S.adaptiveTarget = std::max<uint32_t>(4, static_cast<uint32_t>(std::ceil(rate * 1.0 / S.hop)));
    }
    if (S.captureActive) {
        const bool first = S.captureCollected == 0;
        for (uint32_t b = 0; b < bins; ++b) V.capSum[b] = first ? V.linked[b] : V.capSum[b] + V.linked[b];
        if (++S.captureCollected >= S.captureTarget) {
            const float scale = 1.0f / static_cast<float>(S.captureCollected);
            for (uint32_t b = 0; b < bins; ++b) V.noise[b] = std::max(V.capSum[b] * scale, 1e-20f);
            S.profileReady = S.captured = true;
            S.captureActive = false;
            S.history = false;
            S.adaptiveFrames = 0;
            S.adaptiveFresh = true;
        }
        return;
    }
    if (S.captured) return;
    // Adaptive learning is conservative: bins above the threshold are treated as program
    // content and never promoted into the noise model.
    const bool first = S.adaptiveFresh;
    for (uint32_t b = 0; b < bins; ++b) {
        if (V.linked[b] <= ceilingPower) {
            V.aMin[b] = first ? V.linked[b] : std::min(V.aMin[b], V.linked[b]);
        } else if (first) {
            V.aMin[b] = 3.4028235e38f;
        }
    }
    S.adaptiveFresh = false;
    if (++S.adaptiveFrames < S.adaptiveTarget) return;
    bool learned = false;
    for (uint32_t b = 0; b < bins; ++b) {
        if (V.aMin[b] == 3.4028235e38f) {
            if (S.adaptiveBlocks == 0) V.noise[b] = 0.0f;
            continue;
        }
        learned = true;
        float cand = std::max(V.aMin[b], 1e-20f);
        if (S.adaptiveBlocks == 0 || V.noise[b] <= 0.0f) {
            V.noise[b] = cand;
        } else {
            const float prev = V.noise[b];
            if (cand > prev) cand = std::min(cand, prev * 1.2589254f);  // at most +1 dB per block
            const float c = cand < prev ? 0.55f : 0.90f;
            V.noise[b] = c * prev + (1.0f - c) * cand;
        }
    }
    if (learned) {
        const bool was = S.profileReady;
        ++S.adaptiveBlocks;
        if (S.adaptiveBlocks >= 2) S.profileReady = true;
        if (!was && S.profileReady) S.history = false;
    }
    S.adaptiveFrames = 0;
    S.adaptiveFresh = true;
}

void dnFrame(SnapHeader *h, const StageRec &r, DnView &V, const float *p, const DnTuning &T,
             uint8_t *const *laneBase, uint32_t nLanes) {
    DnShared &S = *V.s;
    const uint32_t n = S.n, bins = S.bins, nyq = n / 2;
    const double rate = h->sampleRate;
    (void)r;
    Complex *spec[kMaxLanes];
    float *in[kMaxLanes], *acc[kMaxLanes];
    for (uint32_t l = 0; l < nLanes; ++l) {
        in[l] = reinterpret_cast<float *>(laneBase[l]);
        acc[l] = in[l] + n;
        spec[l] = reinterpret_cast<Complex *>(laneBase[l] + sizeof(float) * 3 * size_t(n));
        for (uint32_t idx = 0; idx < n; ++idx) {
            spec[l][idx] = {in[l][(S.w + idx) & (n - 1)] * V.window[idx], 0.0f};
        }
        fft::forward(V.plan, spec[l]);
    }
    const float ws = S.windowSum;
    for (uint32_t b = 0; b < bins; ++b) {
        const float sc = (b == 0 || b == nyq) ? 1.0f / ws : 2.0f / ws;
        float pw = 0.0f;
        for (uint32_t l = 0; l < nLanes; ++l) {
            const Complex c = spec[l][b];
            pw = std::max(pw, (c.re * c.re + c.im * c.im) * sc * sc);
        }
        V.linked[b] = pw;
    }
    const float reduction = p[2];
    const float thresholdPower = std::pow(10.0f, p[3] / 10.0f);
    dnUpdateProfile(V, rate, thresholdPower);

    const bool protectOn = p[4] >= 0.5f;
    const double protLo = p[5], protHi = p[6];
    auto isProtected = [&](uint32_t b) {
        if (!protectOn) return false;
        const double f = static_cast<double>(b) * rate / n;
        return f >= protLo && f <= protHi;
    };
    const bool history = S.history && S.profileReady;
    for (uint32_t b = 0; b < bins; ++b) {
        float target = 1.0f;
        if (S.profileReady && reduction > 0.0f && !isProtected(b)) {
            float noise = std::min(std::max(V.noise[b], 1e-20f), thresholdPower);
            if (T.dehiss > 0.0f) {
                const double f = static_cast<double>(b) * rate / n;
                const double nyqHz = rate * 0.5;
                const float hw = nyqHz > 3000.0 ? std::clamp(static_cast<float>((f - 3000.0) / (nyqHz - 3000.0)), 0.0f, 1.0f) : 0.0f;
                noise *= 1.0f + 1.5f * T.dehiss * hw;
            }
            const float power = std::max(V.linked[b], 1e-20f);
            const float posterior = power / std::max(noise, 1e-20f);
            const float inst = std::max(posterior - 1.0f, 0.0f);
            const float prev = history ? V.prevEnh[b] / std::max(noise, 1e-20f) : 0.0f;
            const float prior = T.alpha * prev + (1.0f - T.alpha) * inst;
            const float wiener = prior / (1.0f + prior);
            target = std::pow(std::max(wiener, T.minGain), reduction);
        }
        V.target[b] = std::clamp(target, T.minGain, 1.0f);
    }
    const int radius = static_cast<int>(T.radius);
    for (uint32_t b = 0; b < bins; ++b) {
        float target = V.target[b];
        if (radius > 0 && !isProtected(b)) {
            double sum = 0.0, wsum = 0.0;
            for (int nb = static_cast<int>(b) - radius; nb <= static_cast<int>(b) + radius; ++nb) {
                if (nb < 0 || nb >= static_cast<int>(bins)) continue;
                const int d = nb > static_cast<int>(b) ? nb - static_cast<int>(b) : static_cast<int>(b) - nb;
                const double wgt = static_cast<double>(radius + 1 - d);
                sum += static_cast<double>(V.target[nb]) * wgt;
                wsum += wgt;
            }
            if (wsum > 0.0) target = static_cast<float>(sum / wsum);
        }
        if (isProtected(b)) target = 1.0f;
        const float prev = history ? V.smooth[b] : 1.0f;
        const float c = target < prev ? T.attack : T.release;
        const float gain = std::clamp(target + c * (prev - target), T.minGain, 1.0f);
        V.smooth[b] = gain;
        V.prevEnh[b] = V.linked[b] * gain * gain;
        for (uint32_t l = 0; l < nLanes; ++l) {
            spec[l][b].re *= gain;
            spec[l][b].im *= gain;
            if (b > 0 && b < nyq) {
                spec[l][n - b].re *= gain;
                spec[l][n - b].im *= gain;
            }
        }
    }
    S.history = S.profileReady;
    for (uint32_t l = 0; l < nLanes; ++l) {
        fft::inverse(V.plan, spec[l]);
        for (uint32_t idx = 0; idx < n; ++idx) {
            acc[l][(S.o + 1 + idx) & (2 * n - 1)] += spec[l][idx].re * V.window[idx];
        }
    }
}

void runDenoiser(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    DnView V = dnView(sharedState(h, r));
    DnShared &S = *V.s;
    const DnTuning T = dnTuning(static_cast<uint32_t>(p[0]));
    const uint32_t n = S.n;
    // Profile commands run once when the revision changes (checked at block start).
    const uint32_t revision = static_cast<uint32_t>(p[8]);
    if (revision != S.lastRevision) {
        S.lastRevision = revision;
        const uint32_t cmd = static_cast<uint32_t>(p[7]);
        if (cmd == 2) {
            S.profileReady = S.captured = S.captureActive = false;
            S.history = false;
            S.adaptiveBlocks = 0;
            S.captureCollected = S.captureTarget = 0;
            S.adaptiveFrames = 0;
            S.adaptiveFresh = true;
        } else if (cmd == 1) {
            S.captureCollected = 0;
            S.captureTarget = std::max<uint32_t>(4, static_cast<uint32_t>(std::ceil(h->sampleRate * 1.0 / S.hop)));
            S.captureActive = true;
        }
    }
    const uint32_t nl = r.laneCount;
    uint8_t *laneBase[kMaxLanes];
    float *lp[kMaxLanes], *in[kMaxLanes], *acc[kMaxLanes];
    for (uint32_t l = 0; l < nl; ++l) {
        laneBase[l] = laneState(h, r, l);
        lp[l] = lanes[laneOf(r, l)];
        in[l] = reinterpret_cast<float *>(laneBase[l]);
        acc[l] = in[l] + n;
    }
    for (uint32_t i = 0; i < frames; ++i) {
        for (uint32_t l = 0; l < nl; ++l) in[l][S.w] = lp[l][i];
        S.w = (S.w + 1) & (n - 1);
        if (S.filled < n) ++S.filled;
        ++S.sinceFrame;
        if (S.filled == n && S.sinceFrame >= S.hop) {
            S.sinceFrame = 0;
            dnFrame(h, r, V, p, T, laneBase, nl);
        }
        for (uint32_t l = 0; l < nl; ++l) {
            lp[l][i] = acc[l][S.o];
            acc[l][S.o] = 0.0f;
        }
        S.o = (S.o + 1) & (2 * n - 1);
    }
}

// ---- program FIR -------------------------------------------------------------------

constexpr uint32_t kPart = N60_FIR_PARTITION_FRAMES;  // 256
constexpr uint32_t kFft = 2 * kPart;                  // 512
constexpr uint32_t kFirBins = kPart + 1;              // 257

struct FirShared {
    uint32_t parts, taps, pad[2];
};
struct FirLane {
    uint32_t fill, head, pad[2];
};

struct FirLayout {
    size_t plan, spectra, work, acc, total;
};
FirLayout firLayout(uint32_t parts) {
    FirLayout L;
    size_t off = up(sizeof(FirShared));
    L.plan = off;
    off += up(fft::planBytes(kFft));
    L.spectra = off;
    off += up(sizeof(Complex) * kFirBins * parts);
    L.work = off;
    off += up(sizeof(Complex) * kFft);
    L.acc = off;
    off += up(sizeof(Complex) * kFft);
    L.total = off;
    return L;
}
// Per-lane: header, float in[512], float out[256], Complex fdl[parts * 257].
size_t firLaneBytes(uint32_t parts) {
    return up(sizeof(FirLane) + sizeof(float) * (kFft + kPart) + sizeof(Complex) * kFirBins * parts);
}
uint32_t firParts(uint32_t taps) { return (taps + kPart - 1) / kPart; }

void runFir(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    uint8_t *shBase = sharedState(h, r);
    const FirShared &S = *reinterpret_cast<FirShared *>(shBase);
    const FirLayout L = firLayout(S.parts);
    const void *plan = shBase + L.plan;
    const Complex *H = reinterpret_cast<const Complex *>(shBase + L.spectra);
    Complex *work = reinterpret_cast<Complex *>(shBase + L.work);
    Complex *acc = reinterpret_cast<Complex *>(shBase + L.acc);
    const uint32_t P = S.parts;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        uint8_t *lb = laneState(h, r, l);
        FirLane &st = *reinterpret_cast<FirLane *>(lb);
        float *in = reinterpret_cast<float *>(lb + sizeof(FirLane));
        float *out = in + kFft;
        Complex *fdl = reinterpret_cast<Complex *>(out + kPart);
        float *buf = lanes[laneOf(r, l)];
        for (uint32_t i = 0; i < frames; ++i) {
            const float y = out[st.fill];
            in[kPart + st.fill] = buf[i];
            buf[i] = y;
            if (++st.fill < kPart) continue;
            st.fill = 0;
            for (uint32_t k = 0; k < kFft; ++k) work[k] = {in[k], 0.0f};
            fft::forward(plan, work);
            std::memcpy(fdl + size_t(st.head) * kFirBins, work, sizeof(Complex) * kFirBins);
            for (uint32_t k = 0; k < kFirBins; ++k) acc[k] = {0.0f, 0.0f};
            uint32_t slot = st.head;
            for (uint32_t q = 0; q < P; ++q) {
                const Complex *x = fdl + size_t(slot) * kFirBins;
                const Complex *hq = H + size_t(q) * kFirBins;
                for (uint32_t k = 0; k < kFirBins; ++k) {
                    acc[k].re += hq[k].re * x[k].re - hq[k].im * x[k].im;
                    acc[k].im += hq[k].re * x[k].im + hq[k].im * x[k].re;
                }
                slot = slot == 0 ? P - 1 : slot - 1;
            }
            for (uint32_t k = 1; k < kPart; ++k) acc[kFft - k] = {acc[k].re, -acc[k].im};
            fft::inverse(plan, acc);
            for (uint32_t j = 0; j < kPart; ++j) out[j] = acc[kPart + j].re;
            std::memcpy(in, in + kPart, sizeof(float) * kPart);
            st.head = st.head + 1 == P ? 0 : st.head + 1;
        }
    }
}

}  // namespace

// ---- public entry points -----------------------------------------------------------

bool readDspDynamics(SnapHeader *h, const StageRec &r, uint32_t lane, n60_dynamics_readback *out) {
    if (r.kind != N60_STAGE_COMPRESSOR && r.kind != N60_STAGE_EXPANDER) return false;
    uint32_t k = 0;
    for (; k < r.laneCount; ++k) {
        if (laneOf(r, k) == lane) break;
    }
    if (k == r.laneCount) return false;
    uint8_t *st = laneState(h, r, k);
    std::atomic<uint32_t> *maxBits;
    std::atomic<uint32_t> *nowBits;
    if (r.kind == N60_STAGE_COMPRESSOR) {
        maxBits = &reinterpret_cast<CompLane *>(st)->grMaxBits;
        nowBits = &reinterpret_cast<CompLane *>(st)->grNowBits;
    } else {
        maxBits = &reinterpret_cast<ExpLane *>(st)->grMaxBits;
        nowBits = &reinterpret_cast<ExpLane *>(st)->grNowBits;
    }
    out->kind = r.kind;
    out->grMaxDb = bitsToFloat(maxBits->exchange(0, std::memory_order_relaxed));
    out->grNowDb = bitsToFloat(nowBits->load(std::memory_order_relaxed));
    out->inTruePeak = 0.0f;
    out->outTruePeak = 0.0f;
    out->guardActive = 0;
    out->reserved = 0;
    return true;
}

bool isDspKind(uint32_t kind) {
    return kind == N60_STAGE_COMPRESSOR || kind == N60_STAGE_EXPANDER || kind == N60_STAGE_DYN_EQ ||
           kind == N60_STAGE_DENOISER || kind == N60_STAGE_FIR;
}

n60_status validateDspStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (s.laneMask != 0) {
        if (s.laneA != 0 || s.laneB != 0) return N60_STATUS_BAD_ARGUMENT;
        if (outCh < 64 && (s.laneMask >> outCh) != 0) return N60_STATUS_BAD_ARGUMENT;
    } else {
        if (s.laneB != 0 || (s.laneA != N60_LANE_ALL && s.laneA >= outCh)) return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.kind == N60_STAGE_FIR) {
        if (s.paramCount < 1 || s.paramCount > N60_FIR_MAX_TAPS || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES) {
            return N60_STATUS_BAD_ARGUMENT;
        }
        return N60_STATUS_OK;
    }
    if (s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
    uint32_t expected = 0;
    switch (s.kind) {
        case N60_STAGE_COMPRESSOR: expected = 10; break;
        case N60_STAGE_EXPANDER: expected = 6; break;
        case N60_STAGE_DENOISER: expected = 9; break;
        case N60_STAGE_DYN_EQ: {
            const uint32_t nb = bandCountOf(s.paramCount);
            if (nb < 1 || nb > N60_DYN_EQ_MAX_BANDS || s.paramCount != 1 + nb * N60_DYN_EQ_BAND_PARAMS) {
                return N60_STATUS_BAD_ARGUMENT;
            }
            expected = s.paramCount;
            break;
        }
        default: return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.paramCount != expected) return N60_STATUS_BAD_ARGUMENT;
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!paramOk(s.kind, i, s.params[i], rate)) return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.kind == N60_STAGE_DENOISER && s.params[5] > s.params[6]) return N60_STATUS_BAD_ARGUMENT;
    if (s.kind == N60_STAGE_DYN_EQ) {
        for (uint32_t b = 0; b < bandCountOf(s.paramCount); ++b) {
            const float *prm = s.params + 1 + N60_DYN_EQ_BAND_PARAMS * b;
            if (prm[0] == 3.0f && prm[9] != 0.0f) return N60_STATUS_BAD_ARGUMENT;  // a notch only cuts
        }
    }
    return N60_STATUS_OK;
}

void dspSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared) {
    perLane = shared = 0;
    switch (s.kind) {
        case N60_STAGE_COMPRESSOR: perLane = up(sizeof(CompLane)); shared = up(sizeof(CompShared)); break;
        case N60_STAGE_EXPANDER: perLane = up(sizeof(ExpLane)); break;
        case N60_STAGE_DYN_EQ: {
            const uint32_t nb = bandCountOf(s.paramCount);
            perLane = up(sizeof(DqLaneBand) * nb);
            shared = up(sizeof(DqShared) + sizeof(DqBand) * nb);
            break;
        }
        case N60_STAGE_DENOISER: {
            const uint32_t n = denoiseFft(s.params[1]);
            perLane = dnLaneBytes(n);
            shared = dnLayout(n).total;
            break;
        }
        case N60_STAGE_FIR: {
            const uint32_t parts = firParts(s.paramCount);
            perLane = firLaneBytes(parts);
            shared = firLayout(parts).total;
            break;
        }
        default: break;
    }
}

void dspInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    uint8_t *sh = sharedState(h, r);
    switch (r.kind) {
        case N60_STAGE_COMPRESSOR: reinterpret_cast<CompShared *>(sh)->usedHz = -1.0f; break;
        case N60_STAGE_DYN_EQ: {
            DqShared *s = reinterpret_cast<DqShared *>(sh);
            s->bypassC = pole(h->sampleRate, 5.0f);
            for (uint32_t b = 0; b < bandCountOf(r.paramCount); ++b) dqBands(s)[b].usedShape = -1.0f;
            break;
        }
        case N60_STAGE_DENOISER: {
            DnShared *s = reinterpret_cast<DnShared *>(sh);
            const uint32_t n = denoiseFft(p[1]);
            s->quality = static_cast<uint32_t>(p[1]);
            s->n = n;
            s->bins = n / 2 + 1;
            s->hop = n / 2;
            s->adaptiveFresh = true;
            const DnLayout L = dnLayout(n);
            fft::planInit(sh + L.plan, n);
            float *window = reinterpret_cast<float *>(sh + L.window);
            double sum = 0.0;
            for (uint32_t i = 0; i < n; ++i) {
                const double hann = 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * i / n);
                window[i] = static_cast<float>(std::sqrt(std::max(hann, 0.0)));
                sum += window[i];
            }
            s->windowSum = static_cast<float>(sum);
            break;
        }
        case N60_STAGE_FIR: {
            FirShared *s = reinterpret_cast<FirShared *>(sh);
            s->parts = firParts(r.paramCount);
            s->taps = r.paramCount;
            const FirLayout L = firLayout(s->parts);
            fft::planInit(sh + L.plan, kFft);
            Complex *H = reinterpret_cast<Complex *>(sh + L.spectra);
            Complex *work = reinterpret_cast<Complex *>(sh + L.work);
            for (uint32_t q = 0; q < s->parts; ++q) {
                for (uint32_t k = 0; k < kFft; ++k) {
                    const size_t t = size_t(q) * kPart + k;
                    work[k] = {k < kPart && t < r.paramCount ? p[t] : 0.0f, 0.0f};
                }
                fft::forward(sh + L.plan, work);
                std::memcpy(H + size_t(q) * kFirBins, work, sizeof(Complex) * kFirBins);
            }
            std::memset(work, 0, sizeof(Complex) * kFft);
            break;
        }
        default: break;
    }
}

void runDsp(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    switch (r.kind) {
        case N60_STAGE_COMPRESSOR: runCompressor(h, r, lanes, frames); break;
        case N60_STAGE_EXPANDER: runExpander(h, r, lanes, frames); break;
        case N60_STAGE_DYN_EQ: runDynEq(h, r, lanes, frames); break;
        case N60_STAGE_DENOISER: runDenoiser(h, r, lanes, frames); break;
        case N60_STAGE_FIR: runFir(h, r, lanes, frames); break;
        default: break;
    }
}

n60_status validateDspParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    if (r.kind == N60_STAGE_FIR) return idx < r.paramCount ? N60_STATUS_UNSUPPORTED : N60_STATUS_BAD_ARGUMENT;
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    if (!paramOk(r.kind, idx, value, h->sampleRate)) return N60_STATUS_BAD_ARGUMENT;
    return paramLive(r.kind, idx) ? N60_STATUS_OK : N60_STATUS_UNSUPPORTED;
}

uint32_t dspLatency(const SnapHeader *h, const StageRec &r) {
    if (r.kind == N60_STAGE_FIR) return kPart + r.capacity;
    if (r.kind == N60_STAGE_DENOISER) return denoiseFft(paramsOf(h, r)[1]);
    return 0;
}

}  // namespace n60
