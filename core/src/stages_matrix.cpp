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
// Delay-separated responses and elevation sets (ABI v39, E13 S5). With [11] = E >= 1 the responses are onset-aligned and
// each (set, source, ear) carries a delay in frames. A source is delayed for each ear by the blended delay of the sets
// around the head position, through a 16-tap windowed-sinc fractional-delay line (binaural_fd.hpp) read from a ring
// per source; the two ears therefore have their own delayed input, their own history spectra, and the aligned set
// spectra are blended bilinearly over yaw and head pitch. Added realtime documentation:
//  - allocation: none; the rings, the second history, the delay state and the coefficient table are in the arena.
//  - synchronisation: none. The pose parameters are plain floats written at block start.
//  - latency: 128 + declared + N60_GRAPH_BINAURAL_FD_LATENCY (the delay line's centre tap).
//  - sample rate: any rate the stage accepts (as the early path); delays are frame counts, at most 0.03 s.
//  - channels: as the early path.
//  - reset: with the stage. The delay follows the head position one block late and ramps across the block. A history
//    reset (stream restart) clears the early histories, the delay rings and the tail; up to about 256 frames of output already computed
//    (the pending block and its overlap) still play out.
//  - memory: per source lane two ear histories and a ring of the next power of two above the largest delay + 18 frames
//    (at most 16384 floats at 384 kHz).
//  - cost per 128-frame block: the history transform doubles (per ear) and a blend runs up to four set accumulations
//    (eight while the head moves); the per-frame delay line is a 16-tap FIR per source and ear. The E20 R3 row for it
//    at 384 kHz is a scoped gap (E13 G13).
//
// Late tail (ABI v38, E13 S4). Responses longer than the early part (about 20 ms after the onset, set by the host)
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

#include "binaural_fd.hpp"
#include "conv/nufir.hpp"
#include "fft.hpp"
#include "halfband.hpp"
#include "simd/simd.hpp"

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
    double cell;       // smoothed fractional orientation position (yaw)
    double cellE;      // smoothed fractional elevation position (head pitch); 0 without elevation sets
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
    uint32_t dm;           // 1: delay-separated responses (ABI v39)
    uint32_t elev;         // elevation sets E (1 when dm == 0 for the arithmetic below)
    uint32_t yawSets;      // orient / elev
    uint32_t ring;         // delay ring length per source (power of two), 0 when dm == 0
    uint32_t ringPos;
    uint32_t histEpoch;    // the history epoch the early histories belong to
    uint32_t dlyBase;      // index in the parameters of the first delay
    float pitchStart, pitchStep;
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
TailGeom tailGeometry(double rate, uint32_t taps, uint32_t T, uint32_t extra = 0) {
    TailGeom g;
    while (rate / g.f > static_cast<double>(kTailMaxRate) && g.stages < kMaxStages) {
        g.f *= 2;
        ++g.stages;
    }
    if (rate / g.f > static_cast<double>(kTailMaxRate)) return g;
    const uint64_t delay = uint64_t(g.f) * 256 + 72ull * (g.f - 1);
    const uint64_t need = uint64_t(taps) + kPart + extra;
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
    size_t plan, work, acc, kernels, outBlk, overlap, dly, total;
};
// Delay-mode state: per (source, ear) the delay at the previous and the current block end, its integer part, the
// interpolated taps and a flag for a pure integer delay, then the fractional-delay table.
constexpr size_t kDlyFloats(uint32_t srcs) { return size_t(srcs) * 2 * (4 + kFdTaps) + size_t(kFdPhases + 1) * kFdTaps; }
MxLayout mxLayout(uint32_t parts, uint32_t orient, uint32_t srcs, bool dm = false) {
    MxLayout L;
    size_t off = up(sizeof(MxShared));
    L.plan = off;
    off += up(fft::realPlanBytes(kFft));
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
    L.dly = off;
    if (dm) off += up(sizeof(float) * kDlyFloats(srcs));
    L.total = off;
    return L;
}
// Per source lane: float in[128], Complex fdl[parts * 129]; with a tail then the decimator rings and two convolver lanes.
size_t earBlockBytes(uint32_t parts) { return up(sizeof(float) * kPart + sizeof(Complex) * kBins * parts); }
// Delay mode: a second ear block (delayed input and history) and the delay ring follow the first.
size_t earlyLaneBytes(uint32_t parts, uint32_t ring = 0) {
    return ring == 0 ? earBlockBytes(parts) : 2 * earBlockBytes(parts) + up(sizeof(float) * ring);
}
const float kProbe = 0.5f;  // not a unit impulse: the convolver sizes itself for general taps
size_t laneBytes(uint32_t parts, const TailGeom &g, uint32_t ring = 0) {
    size_t b = earlyLaneBytes(parts, ring);
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

// Pure: elevation cell for a head pitch, in [0, E-1].
double cellForPitch(double pitch, double start, double step, uint32_t elev) {
    if (elev <= 1 || step <= 0.0) return 0.0;
    return std::clamp((pitch - start) / step, 0.0, static_cast<double>(elev - 1));
}

inline float clean(float x) { return std::fabs(x) <= FLT_MAX ? x : 0.0f; }  // false for NaN and Inf

// The sets around a head position and their weights (at most four: two elevations by two yaws).
struct SetWeights {
    uint32_t idx[4];
    float w[4];
    uint32_t n;
};
SetWeights weightsFor(double cellY, double cellE, const MxShared &S) {
    SetWeights sw;
    sw.n = 0;
    const uint32_t Y = S.yawSets;
    const uint32_t y0 = std::min(static_cast<uint32_t>(cellY), Y - 1);
    double wy = cellY - static_cast<double>(y0);
    const uint32_t y1 = S.wrap ? (y0 + 1 == Y ? 0 : y0 + 1) : std::min(y0 + 1, Y - 1);
    if (y1 == y0 || wy < 1e-5) wy = 0.0;
    const uint32_t e0 = std::min(static_cast<uint32_t>(cellE), S.elev - 1);
    double we = cellE - static_cast<double>(e0);
    const uint32_t e1 = std::min(e0 + 1, S.elev - 1);
    if (e1 == e0 || we < 1e-5) we = 0.0;
    const float fy1 = static_cast<float>(wy), fy0 = 1.0f - fy1;
    const float fe1 = static_cast<float>(we), fe0 = 1.0f - fe1;
    auto add = [&](uint32_t e, uint32_t y, float w) {
        if (w <= 0.0f) return;
        sw.idx[sw.n] = e * Y + y;
        sw.w[sw.n] = w;
        ++sw.n;
    };
    add(e0, y0, fe0 * fy0);
    if (wy > 0.0) add(e0, y1, fe0 * fy1);
    if (we > 0.0) {
        add(e1, y0, fe1 * fy0);
        if (wy > 0.0) add(e1, y1, fe1 * fy1);
    }
    return sw;
}

// Delay-mode state (see mxLayout).
struct DlyState {
    float *dPrev, *dCur, *ival, *exact, *cof, *tab;
};
DlyState dlyOf(uint8_t *sh, const MxLayout &L, uint32_t srcs) {
    float *b = reinterpret_cast<float *>(sh + L.dly);
    const size_t n2 = size_t(srcs) * 2;
    return DlyState{b, b + n2, b + 2 * n2, b + 3 * n2, b + 4 * n2, b + 4 * n2 + n2 * kFdTaps};
}

// Integer part, whether the delay is a whole number of frames, and the 16 interpolated taps of delay `d` (>= 0).
inline void fdSetup(const float *tab, float d, float &ipart, float &exact, float *cof) {
    const float fl = std::floor(d);
    const float a = d - fl;
    ipart = fl;
    const float p = a * static_cast<float>(kFdPhases);
    uint32_t p0 = static_cast<uint32_t>(p);
    if (p0 >= kFdPhases) p0 = kFdPhases - 1;
    const float fr = p - static_cast<float>(p0);
    exact = (p0 == 0 && fr == 0.0f) ? 1.0f : 0.0f;
    const float *t0 = tab + size_t(p0) * kFdTaps, *t1 = t0 + kFdTaps;
    for (uint32_t t = 0; t < kFdTaps; ++t) cof[t] = t0[t] * (1.0f - fr) + t1[t] * fr;
}

// Delay ring length for a stage whose parameters are `p`: 0 without delays, else a power of two above the largest delay.
uint32_t ringLenFor(const float *p, uint32_t srcs, double rate) {
    if (p[11] == 0.0f) return 0;
    const uint64_t O = static_cast<uint64_t>(p[4]), T = static_cast<uint64_t>(p[10]);
    const uint64_t base = kFixed + O * srcs * 2 * static_cast<uint64_t>(p[3]) + uint64_t(srcs) * 2 * T + 2;
    float mx = 0.0f;
    for (uint64_t i = 0; i < O * srcs * 2; ++i) mx = std::max(mx, p[base + i]);
    (void)rate;
    uint32_t need = static_cast<uint32_t>(std::ceil(mx)) + kFdTaps + 2;
    uint32_t r = 32;
    while (r < need) r <<= 1;
    return r;
}

void updateDelays(const float *prm, MxShared &S, const DlyState &D) {
    const SetWeights sw = weightsFor(S.cell, S.cellE, S);
    const float *dly = prm + S.dlyBase;
    for (uint32_t k = 0; k < S.srcs; ++k) {
        for (uint32_t e = 0; e < 2; ++e) {
            float v = 0.0f;
            for (uint32_t i = 0; i < sw.n; ++i) v += sw.w[i] * dly[(size_t(sw.idx[i]) * S.srcs + k) * 2 + e];
            const size_t at = size_t(k) * 2 + e;
            D.dPrev[at] = D.dCur[at];
            D.dCur[at] = v;
            fdSetup(D.tab, v, D.ival[at], D.exact[at], D.cof + at * kFdTaps);
        }
    }
}

void runBlock(SnapHeader *h, StageRec &r, MxShared &S, uint8_t *sh, const MxLayout &L) {
    const void *plan = sh + L.plan;
    Complex *work = reinterpret_cast<Complex *>(sh + L.work);
    Complex *accBase = reinterpret_cast<Complex *>(sh + L.acc);
    const size_t accStride = up(sizeof(Complex) * kFft) / sizeof(Complex);
    Complex *nL = accBase, *nR = accBase + accStride;          // blend at the new head position
    Complex *pL = accBase + 2 * accStride, *pR = accBase + 3 * accStride;  // blend at the previous position
    Complex *tL = accBase + 4 * accStride, *tR = accBase + 5 * accStride;  // another set of a blend
    const Complex *kernels = reinterpret_cast<const Complex *>(sh + L.kernels);
    float *outBlk = reinterpret_cast<float *>(sh + L.outBlk);
    float *overlap = reinterpret_cast<float *>(sh + L.overlap);
    const uint32_t P = S.parts;
    const float *prm = paramsOf(h, r);
    const bool dm = S.dm != 0;
    const size_t blk = earBlockBytes(P);

    // Head position: slew-smoothed fractional orientation index (about 10 ms, once per block).
    const double prevCell = S.cell, prevCellE = S.cellE;
    const double a = 1.0 - std::exp(-static_cast<double>(kPart) / (h->sampleRate * kYawTauSeconds));
    if (S.yawSets > 1) {
        const double target = cellFor(prm[0], S.yawStart, S.yawStep, S.yawSets, S.wrap != 0);
        double d = target - S.cell;
        if (S.wrap) d -= S.yawSets * std::floor(d / S.yawSets + 0.5);
        if (std::fabs(d) < 1e-4) {
            S.cell = target;
        } else {
            S.cell += a * d;
            if (S.wrap) {
                S.cell = std::fmod(S.cell, static_cast<double>(S.yawSets));
                if (S.cell < 0.0) S.cell += S.yawSets;
            } else {
                S.cell = std::clamp(S.cell, 0.0, static_cast<double>(S.yawSets - 1));
            }
        }
    }
    if (S.elev > 1) {
        const double target = cellForPitch(prm[1], S.pitchStart, S.pitchStep, S.elev);
        const double d = target - S.cellE;
        S.cellE = std::fabs(d) < 1e-4 ? target : std::clamp(S.cellE + a * d, 0.0, static_cast<double>(S.elev - 1));
    }

    // History: one forward transform per source (per ear in delay mode, where the ears hear different delays).
    const uint32_t head = S.head;
    for (uint32_t k = 0; k < S.srcs; ++k) {
        uint8_t *lb = laneState(h, r, k);
        for (uint32_t ear = 0; ear < (dm ? 2u : 1u); ++ear) {
            uint8_t *eb = lb + ear * blk;
            const float *in = reinterpret_cast<const float *>(eb);
            Complex *fdl = reinterpret_cast<Complex *>(eb + sizeof(float) * kPart);
            float *wf = reinterpret_cast<float *>(work);
            for (uint32_t j = 0; j < kPart; ++j) wf[j] = in[j];
            for (uint32_t j = kPart; j < kFft; ++j) wf[j] = 0.0f;
            fft::forwardReal(plan, wf);  // E20 S4: real-input transform, bins 0..kPart
            std::memcpy(fdl + size_t(head) * kBins, work, sizeof(Complex) * kBins);
        }
    }

    auto accumulate = [&](uint32_t set, Complex *accL, Complex *accR) {
        for (uint32_t k = 0; k < kBins; ++k) accL[k] = accR[k] = {0.0f, 0.0f};
        for (uint32_t k = 0; k < S.srcs; ++k) {
            const uint8_t *lb = laneState(h, r, k);
            const Complex *fdl0 = reinterpret_cast<const Complex *>(lb + sizeof(float) * kPart);
            const Complex *fdl1 = dm ? reinterpret_cast<const Complex *>(lb + blk + sizeof(float) * kPart) : fdl0;
            const Complex *kl = kernels + (((size_t(set) * S.srcs + k) * 2 + 0) * P) * kBins;
            const Complex *kr = kernels + (((size_t(set) * S.srcs + k) * 2 + 1) * P) * kBins;
            uint32_t slot = head;
            for (uint32_t q = 0; q < P; ++q) {
                const Complex *x0 = fdl0 + size_t(slot) * kBins;
                const Complex *x1 = fdl1 + size_t(slot) * kBins;
                const Complex *hl = kl + size_t(q) * kBins;
                const Complex *hr = kr + size_t(q) * kBins;
                float *al = reinterpret_cast<float *>(accL), *ar = reinterpret_cast<float *>(accR);
                simd::cmacSpan(al, al, reinterpret_cast<const float *>(hl), reinterpret_cast<const float *>(x0), kBins);
                simd::cmacSpan(ar, ar, reinterpret_cast<const float *>(hr), reinterpret_cast<const float *>(x1), kBins);
                slot = slot == 0 ? P - 1 : slot - 1;
            }
        }
    };
    // The sets around a fractional position (two yaws, two elevations), blended in the frequency domain, then to time.
    auto blendTime = [&](double cell, double cellE, Complex *dL, Complex *dR) {
        const SetWeights sw = weightsFor(cell, cellE, S);
        accumulate(sw.idx[0], dL, dR);
        if (sw.n > 1) {
            for (uint32_t b = 0; b < kBins; ++b) {
                dL[b] = {sw.w[0] * dL[b].re, sw.w[0] * dL[b].im};
                dR[b] = {sw.w[0] * dR[b].re, sw.w[0] * dR[b].im};
            }
            for (uint32_t i = 1; i < sw.n; ++i) {
                accumulate(sw.idx[i], tL, tR);
                const float wi = sw.w[i];
                for (uint32_t b = 0; b < kBins; ++b) {
                    dL[b] = {dL[b].re + wi * tL[b].re, dL[b].im + wi * tL[b].im};
                    dR[b] = {dR[b].re + wi * tR[b].re, dR[b].im + wi * tR[b].im};
                }
            }
        }
        Complex *ears[2] = {dL, dR};
        for (uint32_t e = 0; e < 2; ++e) {
            Complex *x = ears[e];
            x[0].im = 0.0f;
            x[kPart].im = 0.0f;
            fft::inverseReal(plan, reinterpret_cast<float *>(x));
        }
    };
    blendTime(S.cell, S.cellE, nL, nR);
    // While the head moves, the block fades linearly from the previous position's output to the new
    // one, so a change of orientation weights never steps at a block boundary.
    const bool moving = S.cell != prevCell || S.cellE != prevCellE;
    if (moving) blendTime(prevCell, prevCellE, pL, pR);
    const float *newer[2] = {reinterpret_cast<const float *>(nL), reinterpret_cast<const float *>(nR)};
    const float *older[2] = {reinterpret_cast<const float *>(pL), reinterpret_cast<const float *>(pR)};
    for (uint32_t e = 0; e < 2; ++e) {
        float *ob = outBlk + size_t(e) * kPart;
        float *ov = overlap + size_t(e) * kPart;
        for (uint32_t j = 0; j < kPart; ++j) {
            float y = newer[e][j];
            if (moving) {
                const float t = static_cast<float>(j + 1) / static_cast<float>(kPart);
                y = (1.0f - t) * older[e][j] + t * y;
            }
            ob[j] = y + ov[j];
            ov[j] = newer[e][kPart + j];
        }
    }
    S.head = head + 1 == P ? 0 : head + 1;
    if (dm) updateDelays(prm, S, dlyOf(sh, L, S.srcs));  // the next block's input is delayed to this position
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
    if (!isInt(p[11]) || p[11] < 0.0f || p[11] > static_cast<float>(N60_GRAPH_BINAURAL_MAX_ELEVATIONS)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const uint32_t elev = static_cast<uint32_t>(p[11]);
    const uint32_t tailT = static_cast<uint32_t>(p[10]);
    if (elev != 0 && orient % elev != 0) return N60_STATUS_BAD_ARGUMENT;
    if (tailT != 0 && !tailGeometry(rate, taps, tailT, elev != 0 ? kFdHalf : 0).ok) return N60_STATUS_BAD_ARGUMENT;
    const uint64_t body = kFixed + uint64_t(orient) * n * 2 * taps + uint64_t(n) * 2 * tailT;
    const uint64_t expect = body + (elev != 0 ? 2 + uint64_t(orient) * n * 2 : 0);
    if (expect != s.paramCount) return N60_STATUS_BAD_ARGUMENT;
    for (uint64_t i = kFixed; i < body; i++) {
        if (!(std::fabs(p[i]) <= 1.0e6f)) return N60_STATUS_BAD_ARGUMENT;  /* rejects NaN, Inf and absurd taps */
    }
    if (elev != 0) {
        if (!inR(p[body], -180.0, 180.0)) return N60_STATUS_BAD_ARGUMENT;
        if (elev > 1 ? !(p[body + 1] > 0.0f && p[body + 1] <= 180.0f) : !inR(p[body + 1], 0.0, 180.0)) {
            return N60_STATUS_BAD_ARGUMENT;
        }
        const double maxDelay = N60_GRAPH_BINAURAL_MAX_DELAY_SECONDS * rate;
        for (uint64_t i = body + 2; i < expect; i++) {
            if (!inR(p[i], 0.0, maxDelay)) return N60_STATUS_BAD_ARGUMENT;
        }
    }
    return N60_STATUS_OK;
}

void matrixSizes(const n60_stage_desc &s, double rate, size_t &perLane, size_t &shared) {
    const uint32_t taps = static_cast<uint32_t>(s.params[3]);
    const uint32_t parts = (taps + kPart - 1) / kPart;
    const bool dm = s.params[11] != 0.0f;
    const TailGeom g = tailGeometry(rate, taps, static_cast<uint32_t>(s.params[10]), dm ? kFdHalf : 0);
    perLane = laneBytes(parts, g, ringLenFor(s.params, srcCount(s), rate));
    shared = mxLayout(parts, static_cast<uint32_t>(s.params[4]), srcCount(s), dm).total;
    if (g.ok) shared += up(sizeof(TailShared)) + size_t(srcCount(s)) * 2 * up(conv::sharedBytes(&kProbe, g.n));
}

// Control thread. Builds the tail state: geometry, half-band taps and one convolver per source and ear.
bool tailInit(const SnapHeader *h, uint8_t *sh, const MxLayout &L, MxShared &S, const TailGeom &G, const float *tailIr) {
    const size_t earlyLane = earlyLaneBytes(S.parts, S.ring);
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
    S.dm = p[11] != 0.0f ? 1u : 0u;
    S.elev = S.dm != 0 ? static_cast<uint32_t>(p[11]) : 1u;
    S.yawSets = S.orient / S.elev;
    S.ring = ringLenFor(p, S.srcs, h->sampleRate);
    S.ringPos = 0;
    S.histEpoch = h->historyEpoch;
    S.cell = cellFor(p[0], S.yawStart, S.yawStep, S.yawSets, S.wrap != 0);
    S.cellE = 0.0;
    const MxLayout L = mxLayout(S.parts, S.orient, S.srcs, S.dm != 0);
    const TailGeom G = tailGeometry(h->sampleRate, S.taps, static_cast<uint32_t>(p[10]), S.dm != 0 ? kFdHalf : 0);
    // matrixSizes (called by validation) already rejected a tail the geometry cannot carry, so G.ok holds whenever p[10] != 0.
    S.tailTaps = G.ok ? static_cast<uint32_t>(p[10]) : 0;
    S.laneStride = static_cast<uint32_t>(laneBytes(S.parts, G, S.ring));
    fft::realPlanInit(sh + L.plan, kFft);
    Complex *work = reinterpret_cast<Complex *>(sh + L.work);
    Complex *kernels = reinterpret_cast<Complex *>(sh + L.kernels);
    const float *ir = p + kFixed;
    const float *tailIr = ir + size_t(S.orient) * S.srcs * 2 * S.taps;
    for (uint32_t o = 0; o < S.orient; ++o) {
        for (uint32_t k = 0; k < S.srcs; ++k) {
            const float *base = ir + ((size_t(o) * S.srcs + k) * 2) * S.taps;
            for (uint32_t ear = 0; ear < 2; ++ear) {
                for (uint32_t q = 0; q < S.parts; ++q) {
                    float *wf = reinterpret_cast<float *>(work);
                    for (uint32_t j = 0; j < kFft; ++j) {
                        const size_t t = size_t(q) * kPart + j;
                        float v = 0.0f;
                        if (j < kPart && t < S.taps) {
                            v = (S.equalEar == static_cast<int32_t>(k)) ? 0.5f * (base[t] + base[S.taps + t])
                                                                       : base[size_t(ear) * S.taps + t];
                        }
                        wf[j] = v;
                    }
                    fft::forwardReal(sh + L.plan, wf);
                    std::memcpy(kernels + (((size_t(o) * S.srcs + k) * 2 + ear) * S.parts + q) * kBins, work,
                                sizeof(Complex) * kBins);
                }
            }
        }
    }
    std::memset(work, 0, sizeof(Complex) * kFft);
    if (S.dm != 0) {
        const size_t tailCount = size_t(S.srcs) * 2 * static_cast<size_t>(p[10]);
        const float *ext = tailIr + tailCount;
        S.pitchStart = ext[0];
        S.pitchStep = ext[1];
        S.dlyBase = static_cast<uint32_t>(ext + 2 - p);
        S.cellE = cellForPitch(p[1], S.pitchStart, S.pitchStep, S.elev);
        const DlyState D = dlyOf(sh, L, S.srcs);
        fdTable(D.tab);
        updateDelays(p, S, D);
        std::memcpy(D.dPrev, D.dCur, sizeof(float) * S.srcs * 2);  // no ramp at the start
    }
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
    const bool dm = S.dm != 0;
    const MxLayout L = mxLayout(S.parts, S.orient, S.srcs, dm);
    float *outBlk = reinterpret_cast<float *>(sh + L.outBlk);
    const DlyState D = dm ? dlyOf(sh, L, S.srcs) : DlyState{};
    const size_t blk = earBlockBytes(S.parts);
    const uint32_t ringMask = S.ring - 1;
    float *earL = lanes[S.outA];
    float *earR = lanes[S.outB];
    const size_t stride = S.laneStride;
    uint8_t *laneBase = laneState(h, r, 0);
    const bool tail = S.tailTaps != 0;
    const TailShared *T = tail ? reinterpret_cast<const TailShared *>(sh + S.tailShOff) : nullptr;
    if (S.histEpoch != h->historyEpoch) {
        // History reset (stream restart, seek): clear the early histories (both ear blocks and the delay ring) so no stale
        // audio rings out; the delays restart without a ramp. Once per reset, bounded by the lane size.
        S.histEpoch = h->historyEpoch;
        const size_t laneLen = earlyLaneBytes(S.parts, S.ring);
        for (uint32_t k = 0; k < S.srcs; ++k) std::memset(laneBase + k * stride, 0, laneLen);
        if (dm) std::memcpy(D.dPrev, D.dCur, sizeof(float) * S.srcs * 2);
    }
    uint32_t i = 0;
    while (i < frames) {
        const uint32_t m = tail ? std::min(frames - i, kChunk) : frames;
        if (tail) tailChunk(h, r, S, sh, lanes, i, m);
        for (uint32_t j = 0; j < m; ++j, ++i) {
            const float yl = outBlk[S.fill];
            const float yr = outBlk[kPart + S.fill];
            if (!dm) {
                for (uint32_t k = 0; k < S.srcs; ++k) {
                    reinterpret_cast<float *>(laneBase + k * stride)[S.fill] = clean(lanes[laneOf(r, k)][i]);
                }
            } else {
                const float ramp = static_cast<float>(S.fill + 1) * (1.0f / static_cast<float>(kPart));
                const uint32_t pos = S.ringPos;
                for (uint32_t k = 0; k < S.srcs; ++k) {
                    uint8_t *lb = laneBase + k * stride;
                    float *ring = reinterpret_cast<float *>(lb + 2 * blk);
                    ring[pos] = clean(lanes[laneOf(r, k)][i]);
                    for (uint32_t e = 0; e < 2; ++e) {
                        const size_t at = size_t(k) * 2 + e;
                        float ip = D.ival[at], exact = D.exact[at];
                        float local[kFdTaps];
                        const float *cof = D.cof + at * kFdTaps;
                        if (D.dPrev[at] != D.dCur[at]) {  // gliding: this frame's delay on the ramp
                            fdSetup(D.tab, D.dPrev[at] + (D.dCur[at] - D.dPrev[at]) * ramp, ip, exact, local);
                            cof = local;
                        }
                        const uint32_t base = pos - static_cast<uint32_t>(ip);
                        float y;
                        if (exact != 0.0f) {
                            y = ring[(base - kFdHalf) & ringMask];
                        } else {
                            y = 0.0f;
                            for (uint32_t t = 0; t < kFdTaps; ++t) y += cof[t] * ring[(base - 1 - t) & ringMask];
                        }
                        reinterpret_cast<float *>(lb + e * blk)[S.fill] = y;
                    }
                }
                S.ringPos = (pos + 1) & ringMask;
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
    const float *p = paramsOf(h, r);
    return kPart + static_cast<uint32_t>(p[9]) + (p[11] != 0.0f ? N60_GRAPH_BINAURAL_FD_LATENCY : 0u);
}

}  // namespace n60
