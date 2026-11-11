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
//
// Late tail (ABI v35, E13 S4). Responses longer than the early part (about 20 ms after the onset, set by the host)
// carry the rest as a tail shared by every orientation. The tail runs per source and ear through the non-uniform
// partitioned convolver (conv/nufir.hpp), at an internal rate of at most 96 kHz: above that the source is decimated
// by 2, 4 or 8 with the shared 73-tap half-band cascade (halfband.hpp) and the summed ears are interpolated back.
// The tail impulse responses are decimated the same way (zero-phase, gain x f) at init. Alignment: tail tap i
// lands at tap i of the early path, so the stage latency stays 128 + declared. Added realtime documentation:
//  - allocation: none; every ring, FIFO, convolver lane and spectrum lives in the snapshot arena.
//  - synchronisation: none. Convolver lanes reset by epoch like the program FIR (silent until cleared, input dropped).
//  - latency: unchanged (128 + declared): the tail path's own delay (256 f + 72 (f - 1) frames) is absorbed by
//    leading zeros of the tail response, which is why the early part must be at least that long minus 128.
//  - sample rate: any rate in [8 kHz, 768 kHz]; f = smallest of 1, 2, 4, 8 with rate / f <= 96 kHz.
//  - channels: as the early path. Chunks of at most 128 frames; the output does not depend on the host block size.
//  - reset: with the stage (new snapshot).
#include "stages_matrix.hpp"

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <cstring>
#include <new>
#include <utility>

#include "conv/nufir.hpp"
#include "fft.hpp"
#include "halfband.hpp"

namespace n60 {
namespace {

using fft::Complex;

constexpr uint32_t kPart = N60_GRAPH_BINAURAL_PARTITION_FRAMES;  // 128
constexpr uint32_t kFft = 2 * kPart;                            // 256
constexpr uint32_t kBins = kPart + 1;                           // 129
constexpr uint32_t kFixed = 12;
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
    uint32_t tailTaps;     // 0 = no tail
    uint32_t tailShOff;    // byte offset (in the shared block) of the tail state; then one convolver block per source and ear
    uint32_t tailShStride; // bytes of one convolver's shared block
    uint32_t tailLaneOff;  // byte offset, in a source lane's state, of the decimator rings
    uint32_t tailNufOff;   // ... of the first convolver lane (ear 0; ear 1 follows at tailNufStride)
    uint32_t tailNufStride;
    uint32_t laneStride;   // bytes of one source lane's state
    uint32_t pad2;
};

// ---- late tail ------------------------------------------------------------------------------------

constexpr uint32_t kHbOdd = 2 * kHalfbandK;  // 36 odd taps
constexpr uint32_t kHbRing = 128;            // power of two, > 73 history
constexpr uint32_t kChunk = kPart;           // frames per tail pass
constexpr uint32_t kFifo = 256;
constexpr uint32_t kMaxStages = 3;
constexpr uint32_t kTailMaxRate = static_cast<uint32_t>(N60_GRAPH_BINAURAL_TAIL_MAX_RATE);

struct HbRing {
    float x[kHbRing];
    uint32_t pos;
    uint32_t pad[3];
};

struct TailShared {
    uint32_t f, stages, lead, r, n;
    uint32_t epoch; // history epoch the rings were last cleared for
    uint32_t cnt;   // frames processed (mod 2^32; f divides it): the decimation phase
    uint32_t dlyPos[2];
    uint32_t fifoHead[2], fifoCount[2];
    float hodd[kHbOdd];
    float in[kChunk];
    float dsrc[kChunk + 8];
    float dbuf[kChunk + 8];
    float acc[2][kChunk + 8];
    float out[2][kChunk];
    float fifo[2][kFifo];
    float dly[2][8];
    HbRing interp[2][kMaxStages];
};

struct TailGeom {
    bool ok = false;
    uint32_t f = 1, stages = 0, lead = 0, r = 0, n = 0;
};

// Pure. Internal rate, alignment and tap count of a tail for `taps` early taps and `T` tail taps at `rate`.
// Path delay at full rate: the convolver's 256 internal frames plus 36 frames at each half-band stage in and out.
TailGeom tailGeometry(double rate, uint32_t taps, uint32_t T) {
    TailGeom g;
    while (rate / g.f > static_cast<double>(kTailMaxRate) && g.stages < kMaxStages) {
        g.f *= 2;
        ++g.stages;
    }
    if (rate / g.f > static_cast<double>(kTailMaxRate)) return g;
    const uint64_t delay = uint64_t(g.f) * 256 + 72ull * (g.f - 1);
    const uint64_t need = uint64_t(taps) + kPart;
    if (T == 0 || need < delay) return g;
    const uint64_t total = need - delay;
    g.r = static_cast<uint32_t>(total % g.f);
    g.lead = static_cast<uint32_t>(total - g.r);
    uint64_t len = uint64_t(g.lead) + T;
    for (uint32_t i = 0; i < g.stages; ++i) len = (len + 35) / 2 + 1;
    if (len < 1 || len > conv::kMaxTaps) return g;
    g.n = static_cast<uint32_t>(len);
    g.ok = true;
    return g;
}

// Control thread. Zero-phase half-band decimation by two: out[m] = (h * in)[2m], out.size = outLen.
void decimateStage(const float *in, size_t len, float *out, size_t outLen, const float *hodd) {
    for (size_t m = 0; m < outLen; ++m) {
        const int64_t c = static_cast<int64_t>(2 * m);
        double acc = (c < static_cast<int64_t>(len)) ? 0.5 * in[c] : 0.0;
        for (uint32_t i = 0; i < kHbOdd; ++i) {
            const int64_t d = static_cast<int64_t>(2 * i + 1) - static_cast<int64_t>(2 * kHalfbandK);
            const int64_t a = c + d;  // the 36 odd taps sit at offsets -35, -33 .. 35 from the centre
            const double v = (a >= 0 && a < static_cast<int64_t>(len)) ? in[a] : 0.0;
            acc += static_cast<double>(hodd[i]) * v;
        }
        out[m] = static_cast<float>(acc);
    }
}

// Realtime. One half-band decimator step: push x, return the filtered sample (used on every second push).
inline void hbPush(HbRing &R, float x) N60_RT_NONBLOCKING {
    R.pos = (R.pos + 1) & (kHbRing - 1);
    R.x[R.pos] = x;
}
inline float hbDecimate(const HbRing &R, const float *hodd) N60_RT_NONBLOCKING {
    const uint32_t p = R.pos;
    float acc = 0.5f * R.x[(p - 2 * kHalfbandK) & (kHbRing - 1)];
    for (uint32_t i = 0; i < kHbOdd / 2; ++i) {  // taps at lag 2i+1 and 71-2i are equal
        acc += hodd[i] * (R.x[(p - (2 * i + 1)) & (kHbRing - 1)] + R.x[(p - (4 * kHalfbandK - 1 - 2 * i)) & (kHbRing - 1)]);
    }
    return acc;
}

inline void fifoPush(TailShared &T, uint32_t ear, float v) N60_RT_NONBLOCKING {
    T.fifo[ear][(T.fifoHead[ear] + T.fifoCount[ear]) & (kFifo - 1)] = v;
    ++T.fifoCount[ear];
}
// Interpolate by two through stage `s` and below (stage 0 is at the full rate): zero-stuffed half-band with gain 2.
void interpPush(TailShared &T, uint32_t ear, int s, float v) N60_RT_NONBLOCKING {
    if (s < 0) {
        fifoPush(T, ear, v);
        return;
    }
    HbRing &R = T.interp[ear][s];
    hbPush(R, v);
    const uint32_t p = R.pos;
    const float even = R.x[(p - kHalfbandK) & (kHbRing - 1)];
    float odd = 0.0f;
    for (uint32_t i = 0; i < kHbOdd / 2; ++i) {
        odd += T.hodd[i] * (R.x[(p - i) & (kHbRing - 1)] + R.x[(p - (kHbOdd - 1 - i)) & (kHbRing - 1)]);
    }
    interpPush(T, ear, s - 1, even);
    interpPush(T, ear, s - 1, 2.0f * odd);
}


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
// Per source lane: float in[128], Complex fdl[parts * 129]; with a tail then the decimator rings and two convolver lanes.
size_t earlyLaneBytes(uint32_t parts) { return up(sizeof(float) * kPart + sizeof(Complex) * kBins * parts); }
const float kProbe = 0.5f;  // not a unit impulse: the convolver sizes itself for general taps
size_t laneBytes(uint32_t parts, const TailGeom &g) {
    size_t b = earlyLaneBytes(parts);
    if (g.ok) b += up(sizeof(HbRing) * kMaxStages) + 2 * up(conv::laneBytes(&kProbe, g.n));
    return b;
}

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

bool isMatrixKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_BINAURAL; }

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
    if (!isInt(p[10]) || p[10] < 0.0f || p[10] > std::ceil(static_cast<float>(rate))) return N60_STATUS_BAD_ARGUMENT;
    if (p[11] != 0.0f) return N60_STATUS_BAD_ARGUMENT;
    const uint32_t tailT = static_cast<uint32_t>(p[10]);
    if (tailT != 0 && !tailGeometry(rate, taps, tailT).ok) return N60_STATUS_BAD_ARGUMENT;
    const uint64_t expect = kFixed + uint64_t(orient) * n * 2 * taps + uint64_t(n) * 2 * tailT;
    if (expect != s.paramCount) return N60_STATUS_BAD_ARGUMENT;
    for (uint64_t i = kFixed; i < expect; i++) {
        if (!(std::fabs(p[i]) <= 1.0e6f)) return N60_STATUS_BAD_ARGUMENT;  /* rejects NaN, Inf and absurd taps */
    }
    return N60_STATUS_OK;
}

void matrixSizes(const n60_stage_desc &s, double rate, size_t &perLane, size_t &shared) {
    const uint32_t taps = static_cast<uint32_t>(s.params[3]);
    const uint32_t parts = (taps + kPart - 1) / kPart;
    const TailGeom g = tailGeometry(rate, taps, static_cast<uint32_t>(s.params[10]));
    perLane = laneBytes(parts, g);
    shared = mxLayout(parts, static_cast<uint32_t>(s.params[4]), srcCount(s)).total;
    if (g.ok) shared += up(sizeof(TailShared)) + size_t(srcCount(s)) * 2 * up(conv::sharedBytes(&kProbe, g.n));
}

// Control thread. Builds the tail state: geometry, half-band taps and one convolver per source and ear.
bool tailInit(const SnapHeader *h, uint8_t *sh, const MxLayout &L, MxShared &S, const TailGeom &G, const float *tailIr) {
    const size_t earlyLane = earlyLaneBytes(S.parts);
    S.tailLaneOff = static_cast<uint32_t>(earlyLane);
    S.tailNufOff = static_cast<uint32_t>(earlyLane + up(sizeof(HbRing) * kMaxStages));
    S.tailNufStride = static_cast<uint32_t>(up(conv::laneBytes(&kProbe, G.n)));
    S.tailShOff = static_cast<uint32_t>(L.total);
    S.tailShStride = static_cast<uint32_t>(up(conv::sharedBytes(&kProbe, G.n)));
    TailShared &T = *reinterpret_cast<TailShared *>(sh + S.tailShOff);
    T.epoch = h->historyEpoch;
    T.f = G.f;
    T.stages = G.stages;
    T.lead = G.lead;
    T.r = G.r;
    T.n = G.n;
    halfbandOddTaps(T.hodd);
    const size_t len0 = size_t(G.lead) + S.tailTaps;
    float *bufA = new (std::nothrow) float[len0];
    float *bufB = new (std::nothrow) float[len0];
    if (bufA == nullptr || bufB == nullptr) {  // out of memory on the control thread: the build fails (OUT_OF_MEMORY)
        delete[] bufA;
        delete[] bufB;
        return false;
    }
    uint8_t *shBase = sh + S.tailShOff + up(sizeof(TailShared));
    for (uint32_t k = 0; k < S.srcs; ++k) {
        for (uint32_t ear = 0; ear < 2; ++ear) {
            const float *a = tailIr + (size_t(k) * 2) * S.tailTaps;
            const float *b = a + S.tailTaps;
            std::memset(bufA, 0, sizeof(float) * G.lead);
            for (uint32_t t = 0; t < S.tailTaps; ++t) {
                bufA[G.lead + t] = S.equalEar == static_cast<int32_t>(k) ? 0.5f * (a[t] + b[t]) : (ear == 0 ? a[t] : b[t]);
            }
            float *cur = bufA, *nxt = bufB;
            size_t len = len0;
            for (uint32_t st = 0; st < G.stages; ++st) {
                const size_t outLen = (len + 35) / 2 + 1;
                decimateStage(cur, len, nxt, outLen, T.hodd);
                std::swap(cur, nxt);
                len = outLen;
            }
            const float gain = static_cast<float>(G.f);
            uint32_t nonzero = 0;
            size_t at = 0;
            for (size_t i = 0; i < len; ++i) {
                cur[i] *= gain;
                if (cur[i] != 0.0f) {
                    ++nonzero;
                    at = i;
                }
            }
            // A lone 1.0 would make the convolver pick its (smaller) delay mode: keep it in the general mode it was sized for.
            if (nonzero == 1 && cur[at] == 1.0f && len > 1) cur[at == 0 ? len - 1 : 0] = 1.0e-30f;
            uint8_t *dst = shBase + (size_t(k) * 2 + ear) * S.tailShStride;
            conv::init(dst, cur, static_cast<uint32_t>(len));
        }
    }
    delete[] bufA;
    delete[] bufB;
    return true;
}

bool matrixInit(SnapHeader *h, const StageRec &r) {
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
    const TailGeom G = tailGeometry(h->sampleRate, S.taps, static_cast<uint32_t>(p[10]));
    // matrixSizes (called by validation) already rejected a tail the geometry cannot carry, so G.ok holds whenever p[10] != 0.
    S.tailTaps = G.ok ? static_cast<uint32_t>(p[10]) : 0;
    S.laneStride = static_cast<uint32_t>(laneBytes(S.parts, G));
    fft::planInit(sh + L.plan, kFft);
    Complex *work = reinterpret_cast<Complex *>(sh + L.work);
    Complex *kernels = reinterpret_cast<Complex *>(sh + L.kernels);
    const float *ir = p + kFixed;
    const float *tailIr = ir + size_t(S.orient) * S.srcs * 2 * S.taps;
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
    return !G.ok || tailInit(h, sh, L, S, G, tailIr);
}

// Realtime. One tail pass over `m` (<= 128) frames starting at frame `i0`: decimate each source, run the per-ear convolvers,
// sum the sources, interpolate back; the aligned result is left in T.out. Reads the source lanes before the early path
// overwrites the ear lanes.
void tailChunk(SnapHeader *h, StageRec &r, const MxShared &S, uint8_t *sh, float *const *lanes, uint32_t i0,
               uint32_t m) N60_RT_NONBLOCKING {
    TailShared &T = *reinterpret_cast<TailShared *>(sh + S.tailShOff);
    uint8_t *shBase = sh + S.tailShOff + up(sizeof(TailShared));
    uint8_t *laneBase = laneState(h, r, 0);
    if (T.epoch != h->historyEpoch) {
        // History reset (stream restart, seek): clear every audio history of the tail so no stale audio rings out. The
        // positions and counts are kept, so the alignment is unchanged; the convolver resets itself below.
        T.epoch = h->historyEpoch;
        for (uint32_t k = 0; k < S.srcs; ++k) {
            HbRing *dec = reinterpret_cast<HbRing *>(laneBase + size_t(k) * S.laneStride + S.tailLaneOff);
            for (uint32_t st = 0; st < T.stages; ++st) std::memset(dec[st].x, 0, sizeof(dec[st].x));
        }
        for (uint32_t ear = 0; ear < 2; ++ear) {
            std::memset(T.fifo[ear], 0, sizeof(T.fifo[ear]));
            std::memset(T.dly[ear], 0, sizeof(T.dly[ear]));
            for (uint32_t st = 0; st < T.stages; ++st) std::memset(T.interp[ear][st].x, 0, sizeof(T.interp[ear][st].x));
        }
    }
    const uint32_t cnt0 = T.cnt;
    const uint32_t mask = T.f - 1;
    uint32_t md = 0;
    for (uint32_t j = 0; j < m; ++j) md += ((cnt0 + j) & mask) == 0 ? 1u : 0u;
    for (uint32_t ear = 0; ear < 2; ++ear) std::memset(T.acc[ear], 0, sizeof(float) * md);
    for (uint32_t k = 0; k < S.srcs; ++k) {
        uint8_t *lb = laneBase + size_t(k) * S.laneStride;
        HbRing *dec = reinterpret_cast<HbRing *>(lb + S.tailLaneOff);
        const float *in = lanes[laneOf(r, k)] + i0;
        uint32_t out = 0;
        for (uint32_t j = 0; j < m; ++j) {
            float x = clean(in[j]);
            const uint32_t c = cnt0 + j;
            bool emit = true;
            for (uint32_t st = 0; st < T.stages; ++st) {
                hbPush(dec[st], x);
                if (((c >> st) & 1u) != 0) {
                    emit = false;
                    break;
                }
                x = hbDecimate(dec[st], T.hodd);
            }
            if (emit) T.dsrc[out++] = x;
        }
        if (md == 0) continue;
        for (uint32_t ear = 0; ear < 2; ++ear) {
            uint8_t *nl = lb + S.tailNufOff + size_t(ear) * S.tailNufStride;
            uint8_t *nsh = shBase + (size_t(k) * 2 + ear) * S.tailShStride;
            // The convolver resets itself over several blocks; the rings were cleared above on the same epoch change.
            if (conv::laneEpoch(nl) != h->historyEpoch && !conv::resetStep(nsh, nl, h->historyEpoch, h->rtBudget)) continue;
            std::memcpy(T.dbuf, T.dsrc, sizeof(float) * md);
            conv::process(nsh, nl, T.dbuf, md, nullptr);
            for (uint32_t j = 0; j < md; ++j) T.acc[ear][j] += T.dbuf[j];
        }
    }
    for (uint32_t ear = 0; ear < 2; ++ear) {
        for (uint32_t j = 0; j < md; ++j) interpPush(T, ear, static_cast<int>(T.stages) - 1, T.acc[ear][j]);
        for (uint32_t j = 0; j < m; ++j) {
            const float v = T.fifo[ear][T.fifoHead[ear] & (kFifo - 1)];
            T.fifoHead[ear] = (T.fifoHead[ear] + 1) & (kFifo - 1);
            --T.fifoCount[ear];
            // Alignment delay of 0..f-1 frames (the lead is a multiple of f).
            T.dly[ear][T.dlyPos[ear] & 7] = v;
            T.out[ear][j] = T.dly[ear][(T.dlyPos[ear] - T.r) & 7];
            T.dlyPos[ear] = (T.dlyPos[ear] + 1) & 7;
        }
    }
    T.cnt = cnt0 + m;
}

void runMatrix(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    uint8_t *sh = sharedState(h, r);
    MxShared &S = *reinterpret_cast<MxShared *>(sh);
    const MxLayout L = mxLayout(S.parts, S.orient, S.srcs);
    float *outBlk = reinterpret_cast<float *>(sh + L.outBlk);
    float *earL = lanes[S.outA];
    float *earR = lanes[S.outB];
    const size_t stride = S.laneStride;
    uint8_t *laneBase = laneState(h, r, 0);
    const bool tail = S.tailTaps != 0;
    const TailShared *T = tail ? reinterpret_cast<const TailShared *>(sh + S.tailShOff) : nullptr;
    uint32_t i = 0;
    while (i < frames) {
        const uint32_t m = tail ? std::min(frames - i, kChunk) : frames;
        if (tail) tailChunk(h, r, S, sh, lanes, i, m);
        for (uint32_t j = 0; j < m; ++j, ++i) {
            const float yl = outBlk[S.fill];
            const float yr = outBlk[kPart + S.fill];
            for (uint32_t k = 0; k < S.srcs; ++k) {
                reinterpret_cast<float *>(laneBase + k * stride)[S.fill] = clean(lanes[laneOf(r, k)][i]);
            }
            earL[i] = tail ? yl + T->out[0][j] : yl;
            earR[i] = tail ? yr + T->out[1][j] : yr;
            if (++S.fill == kPart) {
                S.fill = 0;
                runBlock(h, r, S, sh, L);
            }
        }
    }
    for (uint32_t k = 0; k < S.srcs; ++k) {
        const uint32_t lane = laneOf(r, k);
        if (lane != S.outA && lane != S.outB) std::memset(lanes[lane], 0, sizeof(float) * frames);
    }
}

n60_status validateMatrixParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    (void)h;
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    switch (idx) {
        case 0: return inR(value, -720.0, 720.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case 1:
        case 2: return inR(value, -180.0, 180.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        default: return N60_STATUS_UNSUPPORTED;
    }
}

uint32_t matrixLatency(const SnapHeader *h, const StageRec &r) N60_RT_NONBLOCKING {
    return kPart + static_cast<uint32_t>(paramsOf(h, r)[9]);
}

}  // namespace n60
