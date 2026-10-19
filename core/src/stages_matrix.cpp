// libn60core ABI v6 matrix stage (E6 S7): binaural renderer. Portable C++20, standard library plus the
// FFT abstraction; no Apple framework, no exceptions, no RTTI. Written from the public description of
// uniformly partitioned frequency-domain convolution; behaviour matches the shipping renderer
// (N60BinauralRenderer.h: 128-frame partitions, 256-point FFT, one response pair per source, shared input
// spectra), which the parity harness checks sample by sample.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runMatrix:
//  - allocation: none. Kernels, FFT plan, history and work buffers live in the snapshot arena, built
//    on the control thread by matrixInit (the response spectra are computed there, never on the callback).
//  - synchronisation: none. The realtime thread owns the state once the snapshot is published. The
//    head-pose parameters are plain floats the mailbox wrote at block start.
//  - latency: 128 frames (one partition) plus the declared latency of the responses; the host reads it
//    through n60_graph_latency_frames.
//  - sample rate: any rate in [8 kHz, 768 kHz]. Partition and FFT sizes are frame counts; only the head
//    yaw smoothing (10 ms) depends on the rate. The responses must be made for the graph rate.
//  - channels: 1..64 source lanes in, exactly two ear lanes out (any lane, distinct). Source lanes that
//    are not an ear lane are cleared. Non-finite inputs are replaced by zero.
//  - reset: a new snapshot starts with an empty history and a silent output block; the head position
//    starts at the yaw parameter of the descriptor with no glide. There is no in-place reset.
// Results do not depend on the host block size.
#include "stages_matrix.hpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstring>

#include "fft.hpp"

namespace n60 {
namespace {

using fft::Complex;

constexpr uint32_t kPart = N60_GRAPH_BINAURAL_PARTITION_FRAMES;  // 128
constexpr uint32_t kFft = 2 * kPart;                            // 256
constexpr uint32_t kBins = kPart + 1;                           // 129
constexpr uint32_t kFixed = 10;
constexpr size_t kAlign = 16;
constexpr double kYawTauSeconds = 0.010;

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }

struct MxShared {
    double cell;       // smoothed fractional orientation position
    float yawStart, yawStep;
    uint32_t parts, taps, orient, srcs;
    uint32_t outA, outB;
    uint32_t fill, head;
    uint32_t wrap;
    int32_t equalEar;
    uint32_t pad[2];
};

struct MxLayout {
    size_t plan, work, acc, kernels, outBlk, overlap, total;
};
MxLayout mxLayout(uint32_t parts, uint32_t orient, uint32_t srcs) {
    MxLayout L;
    size_t off = up(sizeof(MxShared));
    L.plan = off;
    off += up(fft::planBytes(kFft));
    L.work = off;
    off += up(sizeof(Complex) * kFft);
    L.acc = off;  // six work spectra: new, previous and second-set blends, left and right
    off += 6 * up(sizeof(Complex) * kFft);
    L.kernels = off;
    off += up(sizeof(Complex) * kBins * size_t(parts) * 2 * srcs * orient);
    L.outBlk = off;
    off += up(sizeof(float) * 2 * kPart);
    L.overlap = off;
    off += up(sizeof(float) * 2 * kPart);
    L.total = off;
    return L;
}
// Per source lane: float in[128], Complex fdl[parts * 129].
size_t laneBytes(uint32_t parts) { return up(sizeof(float) * kPart + sizeof(Complex) * kBins * parts); }

uint32_t srcCount(const n60_stage_desc &s) { return static_cast<uint32_t>(__builtin_popcountll(s.laneMask)); }

// Pure: target cell position for a yaw, in [0, O) when wrapped, else [0, O-1].
double cellFor(double yaw, double start, double step, uint32_t orient, bool wrap) {
    if (orient <= 1 || step <= 0.0) return 0.0;
    double c = (yaw - start) / step;
    if (wrap) {
        c = std::fmod(c, static_cast<double>(orient));
        if (c < 0.0) c += orient;
        return c;
    }
    return std::clamp(c, 0.0, static_cast<double>(orient - 1));
}

inline float clean(float x) { return std::fabs(x) <= FLT_MAX ? x : 0.0f; }  // false for NaN and Inf

void runBlock(SnapHeader *h, StageRec &r, MxShared &S, uint8_t *sh, const MxLayout &L) {
    const void *plan = sh + L.plan;
    Complex *work = reinterpret_cast<Complex *>(sh + L.work);
    Complex *accBase = reinterpret_cast<Complex *>(sh + L.acc);
    const size_t accStride = up(sizeof(Complex) * kFft) / sizeof(Complex);
    Complex *nL = accBase, *nR = accBase + accStride;          // blend at the new head position
    Complex *pL = accBase + 2 * accStride, *pR = accBase + 3 * accStride;  // blend at the previous position
    Complex *tL = accBase + 4 * accStride, *tR = accBase + 5 * accStride;  // second set of a blend
    const Complex *kernels = reinterpret_cast<const Complex *>(sh + L.kernels);
    float *outBlk = reinterpret_cast<float *>(sh + L.outBlk);
    float *overlap = reinterpret_cast<float *>(sh + L.overlap);
    const uint32_t P = S.parts;
    const float *prm = paramsOf(h, r);

    // Head position: slew-smoothed fractional orientation index (about 10 ms, once per block).
    const double prevCell = S.cell;
    if (S.orient > 1) {
        const double target = cellFor(prm[0], S.yawStart, S.yawStep, S.orient, S.wrap != 0);
        const double a = 1.0 - std::exp(-static_cast<double>(kPart) / (h->sampleRate * kYawTauSeconds));
        double d = target - S.cell;
        if (S.wrap) d -= S.orient * std::floor(d / S.orient + 0.5);
        if (std::fabs(d) < 1e-4) {
            S.cell = target;
        } else {
            S.cell += a * d;
            if (S.wrap) {
                S.cell = std::fmod(S.cell, static_cast<double>(S.orient));
                if (S.cell < 0.0) S.cell += S.orient;
            } else {
                S.cell = std::clamp(S.cell, 0.0, static_cast<double>(S.orient - 1));
            }
        }
    }

    // History: one forward transform per source, shared by both ears and every set.
    const uint32_t head = S.head;
    for (uint32_t k = 0; k < S.srcs; ++k) {
        uint8_t *lb = laneState(h, r, k);
        const float *in = reinterpret_cast<const float *>(lb);
        Complex *fdl = reinterpret_cast<Complex *>(lb + sizeof(float) * kPart);
        for (uint32_t j = 0; j < kPart; ++j) work[j] = {in[j], 0.0f};
        for (uint32_t j = kPart; j < kFft; ++j) work[j] = {0.0f, 0.0f};
        fft::forward(plan, work);
        std::memcpy(fdl + size_t(head) * kBins, work, sizeof(Complex) * kBins);
    }

    auto accumulate = [&](uint32_t set, Complex *accL, Complex *accR) {
        for (uint32_t k = 0; k < kBins; ++k) accL[k] = accR[k] = {0.0f, 0.0f};
        for (uint32_t k = 0; k < S.srcs; ++k) {
            const uint8_t *lb = laneState(h, r, k);
            const Complex *fdl = reinterpret_cast<const Complex *>(lb + sizeof(float) * kPart);
            const Complex *kl = kernels + (((size_t(set) * S.srcs + k) * 2 + 0) * P) * kBins;
            const Complex *kr = kernels + (((size_t(set) * S.srcs + k) * 2 + 1) * P) * kBins;
            uint32_t slot = head;
            for (uint32_t q = 0; q < P; ++q) {
                const Complex *x = fdl + size_t(slot) * kBins;
                const Complex *hl = kl + size_t(q) * kBins;
                const Complex *hr = kr + size_t(q) * kBins;
                for (uint32_t b = 0; b < kBins; ++b) {
                    accL[b].re += hl[b].re * x[b].re - hl[b].im * x[b].im;
                    accL[b].im += hl[b].re * x[b].im + hl[b].im * x[b].re;
                    accR[b].re += hr[b].re * x[b].re - hr[b].im * x[b].im;
                    accR[b].im += hr[b].re * x[b].im + hr[b].im * x[b].re;
                }
                slot = slot == 0 ? P - 1 : slot - 1;
            }
        }
    };
    // The two bracketing sets of a fractional position, blended in the frequency domain, then to time.
    auto blendTime = [&](double cell, Complex *dL, Complex *dR) {
        const uint32_t i0 = std::min(static_cast<uint32_t>(cell), S.orient - 1);
        double w = cell - static_cast<double>(i0);
        const uint32_t i1 = S.wrap ? (i0 + 1 == S.orient ? 0 : i0 + 1) : std::min(i0 + 1, S.orient - 1);
        if (i1 == i0 || w < 1e-5) w = 0.0;
        accumulate(i0, dL, dR);
        if (w > 0.0) {
            accumulate(i1, tL, tR);
            const float w1 = static_cast<float>(w), w0 = 1.0f - w1;
            for (uint32_t b = 0; b < kBins; ++b) {
                dL[b] = {w0 * dL[b].re + w1 * tL[b].re, w0 * dL[b].im + w1 * tL[b].im};
                dR[b] = {w0 * dR[b].re + w1 * tR[b].re, w0 * dR[b].im + w1 * tR[b].im};
            }
        }
        Complex *ears[2] = {dL, dR};
        for (uint32_t e = 0; e < 2; ++e) {
            Complex *x = ears[e];
            for (uint32_t b = 1; b < kPart; ++b) x[kFft - b] = {x[b].re, -x[b].im};
            x[0].im = 0.0f;
            x[kPart].im = 0.0f;
            fft::inverse(plan, x);
        }
    };
    blendTime(S.cell, nL, nR);
    // While the head moves, the block fades linearly from the previous position's output to the new
    // one, so a change of orientation weights never steps at a block boundary.
    const bool moving = S.cell != prevCell;
    if (moving) blendTime(prevCell, pL, pR);
    Complex *newer[2] = {nL, nR};
    Complex *older[2] = {pL, pR};
    for (uint32_t e = 0; e < 2; ++e) {
        float *ob = outBlk + size_t(e) * kPart;
        float *ov = overlap + size_t(e) * kPart;
        for (uint32_t j = 0; j < kPart; ++j) {
            float y = newer[e][j].re;
            if (moving) {
                const float t = static_cast<float>(j + 1) / static_cast<float>(kPart);
                y = (1.0f - t) * older[e][j].re + t * y;
            }
            ob[j] = y + ov[j];
            ov[j] = newer[e][kPart + j].re;
        }
    }
    S.head = head + 1 == P ? 0 : head + 1;
}

}  // namespace

bool isMatrixKind(uint32_t kind) { return kind == N60_STAGE_BINAURAL; }

n60_status validateMatrixStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0)) return N60_STATUS_BAD_ARGUMENT;
    if (s.kind != N60_STAGE_BINAURAL) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneMask == 0 || (outCh < 64 && (s.laneMask >> outCh) != 0)) return N60_STATUS_BAD_ARGUMENT;
    if (s.laneA >= outCh || s.laneB >= outCh || s.laneA == s.laneB || s.capacityFrames != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.params == nullptr || s.paramCount < kFixed) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    const uint32_t n = srcCount(s);
    if (!inR(p[0], -720.0, 720.0) || !inR(p[1], -180.0, 180.0) || !inR(p[2], -180.0, 180.0)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (!isInt(p[3]) || p[3] < 1.0f || p[3] > static_cast<float>(N60_GRAPH_BINAURAL_MAX_TAPS)) return N60_STATUS_BAD_ARGUMENT;
    if (!isInt(p[4]) || p[4] < 1.0f || p[4] > static_cast<float>(N60_GRAPH_BINAURAL_MAX_SETS)) return N60_STATUS_BAD_ARGUMENT;
    const uint32_t taps = static_cast<uint32_t>(p[3]);
    const uint32_t orient = static_cast<uint32_t>(p[4]);
    if (!inR(p[5], -360.0, 360.0)) return N60_STATUS_BAD_ARGUMENT;
    if (orient > 1 ? !(p[6] > 0.0f && p[6] <= 360.0f) : !inR(p[6], 0.0, 360.0)) return N60_STATUS_BAD_ARGUMENT;
    if (p[7] != 0.0f && p[7] != 1.0f) return N60_STATUS_BAD_ARGUMENT;
    if (!isInt(p[8]) || p[8] < -1.0f || p[8] >= static_cast<float>(n)) return N60_STATUS_BAD_ARGUMENT;
    if (!isInt(p[9]) || p[9] < 0.0f || p[9] > static_cast<float>(N60_GRAPH_MAX_DELAY_FRAMES)) return N60_STATUS_BAD_ARGUMENT;
    const uint64_t expect = kFixed + uint64_t(orient) * n * 2 * taps;
    if (expect != s.paramCount) return N60_STATUS_BAD_ARGUMENT;
    for (uint64_t i = kFixed; i < expect; i++) {
        if (!(std::fabs(p[i]) <= 1.0e6f)) return N60_STATUS_BAD_ARGUMENT;  /* rejects NaN, Inf and absurd taps */
    }
    return N60_STATUS_OK;
}

void matrixSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared) {
    const uint32_t taps = static_cast<uint32_t>(s.params[3]);
    const uint32_t parts = (taps + kPart - 1) / kPart;
    perLane = laneBytes(parts);
    shared = mxLayout(parts, static_cast<uint32_t>(s.params[4]), srcCount(s)).total;
}

void matrixInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    uint8_t *sh = sharedState(h, r);
    MxShared &S = *reinterpret_cast<MxShared *>(sh);
    S.taps = static_cast<uint32_t>(p[3]);
    S.orient = static_cast<uint32_t>(p[4]);
    S.parts = (S.taps + kPart - 1) / kPart;
    S.srcs = r.laneCount;
    S.outA = r.laneA;
    S.outB = r.laneB;
    S.yawStart = p[5];
    S.yawStep = p[6];
    S.wrap = p[7] != 0.0f ? 1u : 0u;
    S.equalEar = static_cast<int32_t>(p[8]);
    S.cell = cellFor(p[0], S.yawStart, S.yawStep, S.orient, S.wrap != 0);
    const MxLayout L = mxLayout(S.parts, S.orient, S.srcs);
    fft::planInit(sh + L.plan, kFft);
    Complex *work = reinterpret_cast<Complex *>(sh + L.work);
    Complex *kernels = reinterpret_cast<Complex *>(sh + L.kernels);
    const float *ir = p + kFixed;
    for (uint32_t o = 0; o < S.orient; ++o) {
        for (uint32_t k = 0; k < S.srcs; ++k) {
            const float *base = ir + ((size_t(o) * S.srcs + k) * 2) * S.taps;
            for (uint32_t ear = 0; ear < 2; ++ear) {
                for (uint32_t q = 0; q < S.parts; ++q) {
                    for (uint32_t j = 0; j < kFft; ++j) {
                        const size_t t = size_t(q) * kPart + j;
                        float v = 0.0f;
                        if (j < kPart && t < S.taps) {
                            v = (S.equalEar == static_cast<int32_t>(k)) ? 0.5f * (base[t] + base[S.taps + t])
                                                                       : base[size_t(ear) * S.taps + t];
                        }
                        work[j] = {v, 0.0f};
                    }
                    fft::forward(sh + L.plan, work);
                    std::memcpy(kernels + (((size_t(o) * S.srcs + k) * 2 + ear) * S.parts + q) * kBins, work,
                                sizeof(Complex) * kBins);
                }
            }
        }
    }
    std::memset(work, 0, sizeof(Complex) * kFft);
}

void runMatrix(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    uint8_t *sh = sharedState(h, r);
    MxShared &S = *reinterpret_cast<MxShared *>(sh);
    const MxLayout L = mxLayout(S.parts, S.orient, S.srcs);
    float *outBlk = reinterpret_cast<float *>(sh + L.outBlk);
    float *earL = lanes[S.outA];
    float *earR = lanes[S.outB];
    const size_t stride = laneBytes(S.parts);
    uint8_t *laneBase = laneState(h, r, 0);
    for (uint32_t i = 0; i < frames; ++i) {
        const float yl = outBlk[S.fill];
        const float yr = outBlk[kPart + S.fill];
        for (uint32_t k = 0; k < S.srcs; ++k) {
            reinterpret_cast<float *>(laneBase + k * stride)[S.fill] = clean(lanes[laneOf(r, k)][i]);
        }
        earL[i] = yl;
        earR[i] = yr;
        if (++S.fill == kPart) {
            S.fill = 0;
            runBlock(h, r, S, sh, L);
        }
    }
    for (uint32_t k = 0; k < S.srcs; ++k) {
        const uint32_t lane = laneOf(r, k);
        if (lane != S.outA && lane != S.outB) std::memset(lanes[lane], 0, sizeof(float) * frames);
    }
}

n60_status validateMatrixParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    (void)h;
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    switch (idx) {
        case 0: return inR(value, -720.0, 720.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case 1:
        case 2: return inR(value, -180.0, 180.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        default: return N60_STATUS_UNSUPPORTED;
    }
}

uint32_t matrixLatency(const SnapHeader *h, const StageRec &r) {
    return kPart + static_cast<uint32_t>(paramsOf(h, r)[9]);
}

}  // namespace n60
