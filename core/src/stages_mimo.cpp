// libn60core ABI v33 MIMO room treatment stage (E19 S4). Portable C++20, standard library plus the FFT abstraction; no
// Apple framework, no exceptions, no RTTI.
//
// Derivation. Treatment adds a delta to each source feed: y_s = x_s z^-L + g * up(sum_t E_st * down(x_t)) (design note 5 of
// docs/epics/E19.md; n60/mimo.h). down is the Kaiser-sinc decimator of n60/mimo/kernel.hpp (centred, half width 5 D), up the
// same kernel zero-stuffed and scaled by D. Causally, down needs 5 D future input samples and up another 5 D, so the delta of
// program sample i is ready 10 D samples later and the direct path is delayed by L = 10 D + tauFrames (the design's modelling
// delay) to meet it. The matrix E runs at the low rate by uniform-partition overlap-save convolution (Wefers, "Partitioned
// convolution algorithms for real-time auralization", 2015, section 3.2): partition B = 64 low-rate samples, FFT size 2 B. The
// first partition (taps 0 .. B-1) is evaluated directly every low-rate sample; partitions k >= 1 contribute to output block m
// from input blocks m - k <= m - 1, which are complete when block m starts, so the convolution has zero latency of its own.
//
// Realtime documentation (docs/REALTIME_RULES.md): see "MIMO treatment" in n60/graph.h. In short, no allocation (all state,
// scratch included, is in the snapshot arena), no synchronisation (telemetry is relaxed atomics), bounded work (the tail is
// one burst of S forward FFTs, S inverse FFTs and S*S*(T/B) complex multiply-adds per 64 low-rate samples), latency L,
// native rates 44.1 to 384 kHz in four decimation families, 1..8 lanes, reset by a new snapshot only.
#include "stages_mimo.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <new>

#include "fft.hpp"
#include "mimo/kernel.hpp"
#include "n60/mimo.h"

namespace n60 {
namespace {

constexpr size_t kAlign = 16;
constexpr uint32_t kHeader = 8;            // fixed parameters before the per-source bounds
constexpr uint32_t kB = 64;                // partition size in low-rate samples
constexpr uint32_t kF = 2 * kB;            // FFT size
constexpr uint32_t kBins = kB + 1;         // distinct bins of a real 2 B transform
constexpr uint32_t kMaxS = N60_MIMO_MAX_SOURCES;
constexpr double kRiseSeconds = 3.0;       // arm fade-in (E4 owner condition of 2 Nov 2026)
constexpr double kFallSeconds = 0.010;     // trip fade-out
constexpr double kFaultSeconds = 0.050;    // continuous over-bound before a fault
constexpr double kEnvSeconds = 0.010;      // fast envelope
constexpr double kHoldSeconds = 1.0;       // peak-hold release
constexpr float kOverPower = 3.98107171f;  // 10^(6/10): 6 dB in amplitude
constexpr double kThermalSeconds = 10.0;   // thermal integration window (D5)
constexpr double kThermalPower = 0.25118864315095801;  // 10^(-6/10): delta power at most -6 dB re the in-band program power
constexpr double kThermalQuiet = 1e-12;    // program power below this (-120 dB) is not judged
constexpr float kQuiet = 1e-12f;           // below this delta power (-120 dB) nothing is over bound

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
uint32_t nextPow2(uint32_t v) { return std::bit_ceil(std::max<uint32_t>(v, 2)); }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }

struct MimoShared {
    // Configuration (written at init).
    uint32_t D, T, S, tau, P, K, L, half, kernelLen, ringN, lowN;
    float riseStep, fallStep, envA, holdR;
    uint32_t faultFrames;
    float bound2[kMaxS];  // G_s squared
    // Byte offsets from the start of this structure.
    uint32_t offKernel, offHist, offXbuf, offLow, offTail, offHf, offFdl, offCx, offAcc, offPlan, total;
    // Running state (realtime thread).
    uint64_t n;           // frames processed
    uint64_t lowCount;    // low-rate samples produced
    uint32_t decCount;    // frames until the next decimation point
    uint32_t blockPos;    // low-rate position in the 64-sample block
    uint32_t fdlHead;     // slot of the newest input spectrum
    uint32_t held, fault, faultSource, tripCount, lastTrip;
    float u;              // arm fade phase 0..1 (gain = smoothstep(u))
    uint64_t overFrames;
    uint64_t thermalWindow, thermalCount;  // window length and position in low-rate samples (counted while g > 0)
    double thermalProg[kMaxS], thermalDelta[kMaxS];
    uint32_t faultReason;                  // 0 none, 1 monitor bound, 2 thermal budget
    float msx;            // envelope of the summed input power
    float pkx;
    float msd[kMaxS], pkd[kMaxS];
    // Telemetry (relaxed atomics, control thread reads).
    std::atomic<uint32_t> outState, outGainBits, outHeld, outFault, outFaultSource, outTrips, outFaultReason;
    std::atomic<uint32_t> boundMaxBits[kMaxS], peakBits[kMaxS];
};

struct Dims {
    uint32_t D, T, S, tau;
};

Dims dimsOf(const float *p) {
    return {static_cast<uint32_t>(p[0]), static_cast<uint32_t>(p[1]), static_cast<uint32_t>(p[2]), static_cast<uint32_t>(p[3])};
}

void layoutOf(const Dims &d, uint32_t &ringN, uint32_t &lowN, uint32_t off[10], uint32_t &K, size_t &total) {
    const uint32_t P = (d.T + kB - 1) / kB;
    K = P - 1;
    const uint32_t L = 10 * d.D + d.tau;
    ringN = nextPow2(L + 1);
    lowN = nextPow2(d.tau / d.D + 13);
    size_t o = up(sizeof(MimoShared));
    auto place = [&](uint32_t slot, size_t bytes) {
        off[slot] = static_cast<uint32_t>(o);
        o += up(bytes);
    };
    place(0, sizeof(float) * mimo::kernelTaps(d.D));
    place(1, sizeof(float) * size_t(d.S) * ringN);
    place(2, sizeof(float) * size_t(d.S) * kF);
    place(3, sizeof(float) * size_t(d.S) * lowN);
    place(4, sizeof(float) * size_t(d.S) * kB);
    place(5, sizeof(fft::Complex) * size_t(d.S) * d.S * K * kBins);
    place(6, sizeof(fft::Complex) * size_t(d.S) * K * kBins);
    place(7, sizeof(fft::Complex) * kF);
    place(8, sizeof(fft::Complex) * kBins);
    place(9, fft::planBytes(kF));
    total = o;
}

inline MimoShared &shared(SnapHeader *h, const StageRec &r) { return *reinterpret_cast<MimoShared *>(sharedState(h, r)); }
inline const MimoShared &shared(const SnapHeader *h, const StageRec &r) {
    return *reinterpret_cast<const MimoShared *>(bytes(h) + r.sharedOff);
}
template <class T>
inline T *at(MimoShared &M, uint32_t off) { return reinterpret_cast<T *>(reinterpret_cast<uint8_t *>(&M) + off); }

// ---- one low-rate step ------------------------------------------------------------------------------------------

// Builds the tail of the next block from the input spectra (called when a block of input has just completed).
void completeBlock(MimoShared &M) N60_RT_NONBLOCKING {
    const uint32_t S = M.S, K = M.K;
    float *xbuf = at<float>(M, M.offXbuf);
    fft::Complex *cx = at<fft::Complex>(M, M.offCx);
    const void *plan = at<uint8_t>(M, M.offPlan);
    if (K != 0) {
        fft::Complex *fdl = at<fft::Complex>(M, M.offFdl);
        M.fdlHead = (M.fdlHead + 1) % K;
        for (uint32_t t = 0; t < S; ++t) {
            const float *xb = xbuf + size_t(t) * kF;
            for (uint32_t i = 0; i < kF; ++i) cx[i] = {xb[i], 0.0f};
            fft::forward(plan, cx);
            std::memcpy(fdl + (size_t(t) * K + M.fdlHead) * kBins, cx, sizeof(fft::Complex) * kBins);
        }
        const fft::Complex *hf = at<fft::Complex>(M, M.offHf);
        fft::Complex *acc = at<fft::Complex>(M, M.offAcc);
        float *tail = at<float>(M, M.offTail);
        for (uint32_t s = 0; s < S; ++s) {
            for (uint32_t b = 0; b < kBins; ++b) acc[b] = {0.0f, 0.0f};
            for (uint32_t t = 0; t < S; ++t) {
                for (uint32_t k = 1; k <= K; ++k) {
                    const uint32_t slot = (M.fdlHead + K - (k - 1)) % K;
                    const fft::Complex *X = fdl + (size_t(t) * K + slot) * kBins;
                    const fft::Complex *H = hf + ((size_t(s) * S + t) * K + (k - 1)) * kBins;
                    for (uint32_t b = 0; b < kBins; ++b) {
                        acc[b].re += X[b].re * H[b].re - X[b].im * H[b].im;
                        acc[b].im += X[b].re * H[b].im + X[b].im * H[b].re;
                    }
                }
            }
            for (uint32_t b = 0; b < kBins; ++b) cx[b] = acc[b];
            for (uint32_t b = kBins; b < kF; ++b) cx[b] = {acc[kF - b].re, -acc[kF - b].im};
            cx[0].im = 0.0f;
            cx[kB].im = 0.0f;
            fft::inverse(plan, cx);
            for (uint32_t q = 0; q < kB; ++q) tail[size_t(s) * kB + q] = cx[kB + q].re;
        }
    }
    for (uint32_t t = 0; t < S; ++t) {
        float *xb = xbuf + size_t(t) * kF;
        std::memcpy(xb, xb + kB, sizeof(float) * kB);
    }
    M.blockPos = 0;
}

// One low-rate sample: the matrix convolution, the monitor, and storing the delta (scaled by D) for the interpolator.
void lowStep(SnapHeader *h, const StageRec &r, MimoShared &M, const float *xl) N60_RT_NONBLOCKING {
    const uint32_t S = M.S, T = M.T, p = M.blockPos;
    const float *taps = paramsOf(h, r) + kHeader + S;
    float *xbuf = at<float>(M, M.offXbuf);
    const float *tail = at<float>(M, M.offTail);
    float *low = at<float>(M, M.offLow);
    for (uint32_t t = 0; t < S; ++t) xbuf[size_t(t) * kF + kB + p] = xl[t];
    const uint32_t head = std::min(T, kB);
    float yl[kMaxS];
    for (uint32_t s = 0; s < S; ++s) {
        float acc = M.K != 0 ? tail[size_t(s) * kB + p] : 0.0f;
        for (uint32_t t = 0; t < S; ++t) {
            const float *ht = taps + (size_t(s) * S + t) * T;
            const float *xt = xbuf + size_t(t) * kF + kB + p;
            float a = 0.0f;
            for (uint32_t j = 0; j < head; ++j) a += ht[j] * xt[-static_cast<int32_t>(j)];
            acc += a;
        }
        yl[s] = acc;
    }
    // Monitor: fast mean-square envelopes, peak-held; the reference is the summed input power.
    float rx = 0.0f;
    for (uint32_t t = 0; t < S; ++t) rx += xl[t] * xl[t];
    M.msx += M.envA * (rx - M.msx);
    M.pkx = std::max(M.msx, M.pkx * M.holdR);
    bool over = false;
    uint32_t overSource = 0;
    for (uint32_t s = 0; s < S; ++s) {
        M.msd[s] += M.envA * (yl[s] * yl[s] - M.msd[s]);
        M.pkd[s] = std::max(M.msd[s], M.pkd[s] * M.holdR);
        const float ref = M.bound2[s] * M.pkx;
        if (ref > 0.0f) atomicMaxFloat(M.boundMaxBits[s], M.pkd[s] / ref);
        atomicMaxFloat(M.peakBits[s], std::fabs(yl[s]));
        if (M.u > 0.0f && M.pkd[s] > kQuiet && M.pkd[s] > kOverPower * ref) {
            over = true;
            overSource = s + 1;
        }
    }
    // Thermal budget (D5): tumbling 10 s windows of armed time; delta power (before g, like the monitor above) against the
    // in-band program power (the decimated source feed). Over -6 dB at the end of a window latches a fault.
    if (M.u > 0.0f) {
        for (uint32_t s = 0; s < S; ++s) {
            M.thermalProg[s] += static_cast<double>(xl[s]) * xl[s];
            M.thermalDelta[s] += static_cast<double>(yl[s]) * yl[s];
        }
        if (++M.thermalCount >= M.thermalWindow) {
            for (uint32_t s = 0; s < S; ++s) {
                if (M.thermalProg[s] > kThermalQuiet * static_cast<double>(M.thermalCount) &&
                    M.thermalDelta[s] > kThermalPower * M.thermalProg[s] && M.fault == 0) {
                    M.fault = 1;
                    M.held = 1;
                    M.faultSource = s + 1;
                    M.faultReason = 2;
                }
                M.thermalProg[s] = M.thermalDelta[s] = 0.0;
            }
            M.thermalCount = 0;
        }
    } else if (M.thermalCount != 0) {
        M.thermalCount = 0;
        for (uint32_t s = 0; s < S; ++s) M.thermalProg[s] = M.thermalDelta[s] = 0.0;
    }
    if (over) {
        M.overFrames += M.D;
        if (M.overFrames >= M.faultFrames && M.fault == 0) {
            M.fault = 1;
            M.held = 1;
            M.faultSource = overSource;
            M.faultReason = 1;
        }
    } else {
        M.overFrames = 0;
    }
    const float D = static_cast<float>(M.D);
    for (uint32_t s = 0; s < S; ++s) low[size_t(s) * M.lowN + (M.lowCount & (M.lowN - 1))] = yl[s] * D;
    ++M.lowCount;
    if (++M.blockPos == kB) completeBlock(M);
}

inline float smooth(float u) { return u * u * (3.0f - 2.0f * u); }

}  // namespace

bool isMimoKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_MIMO; }

n60_status validateMimoStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 44100.0 && rate <= 384000.5) || s.capacityFrames != 0 || s.laneA != 0 || s.laneB != 0 || s.laneMask == 0 ||
        s.params == nullptr || (outCh < 64 && (s.laneMask >> outCh) != 0)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const uint32_t S = static_cast<uint32_t>(std::popcount(s.laneMask));
    if (S < 1 || S > kMaxS || s.paramCount < kHeader + S) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    uint32_t D = 0;
    double low = 0;
    if (n60_mimo_low_rate(rate, &D, &low) != N60_MIMO_OK) return N60_STATUS_BAD_ARGUMENT;
    if (!isInt(p[0]) || static_cast<uint32_t>(p[0]) != D || !isInt(p[1]) || p[1] < 1.0f || p[1] > static_cast<float>(N60_MIMO_MAX_TAPS) ||
        !isInt(p[2]) || static_cast<uint32_t>(p[2]) != S || !isInt(p[3]) || p[3] < 0.0f ||
        p[3] > static_cast<float>(std::ceil(N60_MIMO_MAX_TAU_SECONDS * rate)) || (p[4] != 0.0f && p[4] != 1.0f) ||
        (p[5] != 0.0f && p[5] != 1.0f) || p[6] != 0.0f || p[7] != 0.0f) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const uint32_t T = static_cast<uint32_t>(p[1]);
    if (s.paramCount != kHeader + S + S * S * T) return N60_STATUS_BAD_ARGUMENT;
    for (size_t i = kHeader + S; i < s.paramCount; ++i) {
        if (!(std::fabs(p[i]) <= 1.0e4f)) return N60_STATUS_BAD_ARGUMENT;  // also rejects NaN
    }
    for (uint32_t i = 0; i < S; ++i) {
        if (!(p[kHeader + i] > 0.0f && p[kHeader + i] <= 1.0e4f)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void mimoSizes(const n60_stage_desc &s, size_t &perLane, size_t &sharedBytes) {
    perLane = 0;
    Dims d = dimsOf(s.params);
    uint32_t ringN, lowN, off[10], K;
    size_t total;
    layoutOf(d, ringN, lowN, off, K, total);
    sharedBytes = total;
}

void mimoInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    const Dims d = dimsOf(p);
    MimoShared &M = *new (sharedState(h, r)) MimoShared{};
    uint32_t off[10];
    size_t total;
    M.D = d.D;
    M.T = d.T;
    M.S = d.S;
    M.tau = d.tau;
    M.P = (d.T + kB - 1) / kB;
    layoutOf(d, M.ringN, M.lowN, off, M.K, total);
    M.L = 10 * d.D + d.tau;
    M.half = mimo::kernelHalf(d.D);
    M.kernelLen = mimo::kernelTaps(d.D);
    M.offKernel = off[0];
    M.offHist = off[1];
    M.offXbuf = off[2];
    M.offLow = off[3];
    M.offTail = off[4];
    M.offHf = off[5];
    M.offFdl = off[6];
    M.offCx = off[7];
    M.offAcc = off[8];
    M.offPlan = off[9];
    M.total = static_cast<uint32_t>(total);
    const double fs = h->sampleRate, fsLow = fs / d.D;
    M.riseStep = static_cast<float>(1.0 / (kRiseSeconds * fs));
    M.fallStep = static_cast<float>(1.0 / (kFallSeconds * fs));
    M.envA = static_cast<float>(1.0 - std::exp(-1.0 / (kEnvSeconds * fsLow)));
    M.holdR = static_cast<float>(std::exp(-1.0 / (kHoldSeconds * fsLow)));
    M.thermalWindow = static_cast<uint64_t>(std::llround(kThermalSeconds * fsLow));
    M.faultFrames = static_cast<uint32_t>(std::ceil(kFaultSeconds * fs));
    for (uint32_t s = 0; s < d.S; ++s) M.bound2[s] = p[kHeader + s] * p[kHeader + s];
    M.decCount = M.half;
    M.held = 0;

    double kern[mimo::kMaxDecimation * 10 + 1];
    mimo::designKernel(d.D, kern);
    float *kf = at<float>(M, M.offKernel);
    for (uint32_t i = 0; i < M.kernelLen; ++i) kf[i] = static_cast<float>(kern[i]);

    fft::planInit(at<uint8_t>(M, M.offPlan), kF);
    if (M.K != 0) {
        const float *taps = p + kHeader + d.S;
        fft::Complex *hf = at<fft::Complex>(M, M.offHf);
        fft::Complex cx[kF];
        for (uint32_t s = 0; s < d.S; ++s) {
            for (uint32_t t = 0; t < d.S; ++t) {
                const float *ht = taps + (size_t(s) * d.S + t) * d.T;
                for (uint32_t k = 1; k <= M.K; ++k) {
                    for (uint32_t i = 0; i < kF; ++i) {
                        const uint32_t idx = k * kB + i;
                        cx[i] = {(i < kB && idx < d.T) ? ht[idx] : 0.0f, 0.0f};
                    }
                    fft::forward(at<uint8_t>(M, M.offPlan), cx);
                    std::memcpy(hf + ((size_t(s) * d.S + t) * M.K + (k - 1)) * kBins, cx, sizeof(fft::Complex) * kBins);
                }
            }
        }
    }
}

void runMimo(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    MimoShared &M = shared(h, r);
    const float *p = paramsOf(h, r);
    const uint32_t S = M.S, D = M.D;
    const bool arm = p[4] >= 0.5f, trip = p[5] >= 0.5f;
    if (trip && M.lastTrip == 0) {
        M.held = 1;
        ++M.tripCount;
    }
    M.lastTrip = trip ? 1u : 0u;
    if (!arm && !trip) {  // the host has disarmed: a latched trip, fault or rebuild hold clears here, and only here
        M.held = 0;
        M.fault = 0;
        M.faultSource = 0;
        M.faultReason = 0;
    }
    const float *kernel = at<float>(M, M.offKernel);
    float *hist = at<float>(M, M.offHist);
    const float *low = at<float>(M, M.offLow);
    const uint32_t ringMask = M.ringN - 1, lowMask = M.lowN - 1, half = M.half, L = M.L;
    float *ch[kMaxS];
    for (uint32_t s = 0; s < S; ++s) ch[s] = lanes[laneOf(r, s)];

    for (uint32_t f = 0; f < frames; ++f) {
        const bool on = arm && !trip && M.held == 0;
        if (on) M.u = std::min(1.0f, M.u + M.riseStep);
        else M.u = std::max(0.0f, M.u - M.fallStep);
        const uint64_t n = M.n;
        for (uint32_t s = 0; s < S; ++s) hist[size_t(s) * M.ringN + (n & ringMask)] = ch[s][f];
        if (M.decCount == 0) {
            float xl[kMaxS];
            for (uint32_t s = 0; s < S; ++s) {
                const float *hs = hist + size_t(s) * M.ringN;
                double acc = 0.0;
                for (uint32_t k = 0; k < M.kernelLen; ++k) acc += static_cast<double>(kernel[k]) * hs[(n + k - 2 * half) & ringMask];
                xl[s] = static_cast<float>(acc);
            }
            lowStep(h, r, M, xl);
            M.decCount = D - 1;
        } else {
            --M.decCount;
        }
        const float g = M.u > 0.0f ? smooth(M.u) : 0.0f;
        // Direct path: program sample n - L. Delta: the resampler chain's own delay is 10 D = 2 * half, so the delta of program
        // sample n - 2 * half is complete now; the direct path is tau frames later, which is the design's relative delay
        // (n60/mimo.h: row gain |E_st + [t==s] e^(-j w tau)|, the phase on the direct path). E19 S5 fixed this: S4 delayed the delta by L as well.
        const uint64_t q = n - half;  // wraps for n < 2 * half; guarded below
        for (uint32_t s = 0; s < S; ++s) {
            float out = hist[size_t(s) * M.ringN + ((n - L) & ringMask)];
            if (g > 0.0f && n >= 2 * half) {
                const uint64_t jhi = q / D;
                const uint32_t rem = static_cast<uint32_t>(q - jhi * D);
                const float *ls = low + size_t(s) * M.lowN;
                float delta = 0.0f;
                for (uint32_t m = 0; rem + m * D <= 2 * half && m <= jhi; ++m) delta += ls[(jhi - m) & lowMask] * kernel[rem + m * D];
                out += g * delta;
            }
            ch[s][f] = out;
        }
        ++M.n;
    }
    const float gNow = M.u > 0.0f ? smooth(M.u) : 0.0f;
    const bool onNow = arm && !trip && M.held == 0;
    M.outGainBits.store(floatToBits(gNow), std::memory_order_relaxed);
    M.outState.store(M.u <= 0.0f ? 0u : (onNow ? (M.u >= 1.0f ? 2u : 1u) : 3u), std::memory_order_relaxed);
    M.outHeld.store(M.held, std::memory_order_relaxed);
    M.outFault.store(M.fault, std::memory_order_relaxed);
    M.outFaultSource.store(M.faultSource, std::memory_order_relaxed);
    M.outTrips.store(M.tripCount, std::memory_order_relaxed);
    M.outFaultReason.store(M.faultReason, std::memory_order_relaxed);
}

n60_status validateMimoParam(const SnapHeader *, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    if (idx == 4 || idx == 5) return (value == 0.0f || value == 1.0f) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
    return N60_STATUS_UNSUPPORTED;  // dimensions, bounds and taps are topology
}

uint32_t mimoLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING { return shared(h, r).L; }

uint32_t mimoRebuildMute(SnapHeader *h, bool silentNow) N60_RT_NONBLOCKING {
    uint32_t n = 0;
    StageRec *table = stages(h);
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        if (table[i].kind != N60_STAGE_MIMO) continue;
        MimoShared &M = shared(h, table[i]);
        M.held = 1;
        if (silentNow) M.u = 0.0f;
        ++n;
    }
    return n;
}

bool readMimo(SnapHeader *h, uint32_t stageId, n60_mimo_readback *out) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_MIMO) return false;
    MimoShared &M = shared(h, *r);
    out->state = M.outState.load(std::memory_order_relaxed);
    out->armGain = bitsToFloat(M.outGainBits.load(std::memory_order_relaxed));
    out->held = M.outHeld.load(std::memory_order_relaxed);
    out->faultLatched = M.outFault.load(std::memory_order_relaxed);
    out->faultSource = M.outFaultSource.load(std::memory_order_relaxed);
    out->tripCount = M.outTrips.load(std::memory_order_relaxed);
    out->sourceCount = M.S;
    out->latencyFrames = M.L;
    for (uint32_t s = 0; s < 8; ++s) {
        out->boundRatioMax[s] = s < M.S ? bitsToFloat(M.boundMaxBits[s].exchange(0, std::memory_order_relaxed)) : 0.0f;
        out->deltaPeak[s] = s < M.S ? bitsToFloat(M.peakBits[s].exchange(0, std::memory_order_relaxed)) : 0.0f;
    }
    out->faultReason = M.outFaultReason.load(std::memory_order_relaxed);
    return true;
}

}  // namespace n60
