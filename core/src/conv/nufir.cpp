// libn60core non-uniform partitioned FIR engine (E9 S1). See nufir.hpp for the design and realtime notes.
#include "nufir.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "../fft.hpp"

namespace n60::conv {
namespace {

using fft::Complex;

constexpr uint32_t kSegs = 3;
constexpr uint32_t kL[kSegs] = {256, 1024, 4096};          // partition (block) length
constexpr uint32_t kOff[kSegs] = {0, 1024, 5120};          // first tap of the segment
constexpr uint32_t kMaxParts[kSegs] = {4, 4, 63};
constexpr uint32_t kRing = 16384;                           // input ring when segment 2 is present

constexpr size_t up(size_t v) { return (v + 15) & ~size_t(15); }
constexpr uint32_t fftN(uint32_t s) { return 2 * kL[s]; }
constexpr uint32_t binsOf(uint32_t s) { return kL[s] + 1; }

uint32_t log2u(uint32_t n) {
    uint32_t r = 0;
    while ((1u << r) < n) ++r;
    return r;
}

void partsFor(uint32_t taps, uint32_t out[kSegs]) {
    for (uint32_t s = 0; s < kSegs; ++s) {
        const uint32_t cover = s + 1 < kSegs ? kOff[s + 1] - kOff[s] : 0xFFFFFFFFu;
        const uint32_t have = taps > kOff[s] ? taps - kOff[s] : 0;
        const uint32_t n = std::min(have, cover);
        out[s] = std::min((n + kL[s] - 1) / kL[s], kMaxParts[s]);
    }
}

// Index of a single 1.0 with every other tap exactly zero, or -1.
int64_t impulseIndex(const float *taps, uint32_t n) {
    int64_t at = -1;
    for (uint32_t i = 0; i < n; ++i) {
        if (taps[i] == 0.0f) continue;
        if (taps[i] != 1.0f || at >= 0) return -1;
        at = i;
    }
    return at;
}

// ---- layouts ------------------------------------------------------------------------

struct SLayout {
    size_t plan[kSegs], scratch, h[kSegs], total;
};
SLayout sLayout(const uint32_t parts[kSegs]) {
    SLayout L{};
    size_t off = up(sizeof(Shared));
    uint32_t maxN = 0;
    for (uint32_t s = 0; s < kSegs; ++s) {
        if (parts[s] == 0) continue;
        L.plan[s] = off;
        off += up(fft::planBytes(fftN(s)));
        maxN = fftN(s);
    }
    L.scratch = off;
    off += up(sizeof(Complex) * maxN);
    for (uint32_t s = 0; s < kSegs; ++s) {
        if (parts[s] == 0) continue;
        L.h[s] = off;
        off += up(sizeof(Complex) * binsOf(s) * parts[s]);
    }
    L.total = off;
    return L;
}

struct LaneHdr {
    uint32_t epoch, fill, tick, wp;
    uint32_t cnt[kSegs], head[kSegs];
    uint32_t outCur, pad;
};
struct DelayHdr {
    uint32_t epoch, pos;
};

struct LLayout {
    size_t outBuf, ring, ringLen, acc1, acc2, out1, out2, clearEnd, fdl[kSegs], total;
};
LLayout lLayout(const uint32_t parts[kSegs]) {
    LLayout L{};
    size_t off = up(sizeof(LaneHdr));
    L.outBuf = off;
    off += up(sizeof(float) * kBlock);
    L.ringLen = parts[2] > 0 ? kRing : (parts[1] > 0 ? 2048 : 512);
    L.ring = off;
    off += up(sizeof(float) * L.ringLen);
    if (parts[1] > 0) {
        L.acc1 = off;
        off += up(sizeof(Complex) * binsOf(1));
        L.out1 = off;
        off += up(sizeof(float) * kL[1]);
    }
    if (parts[2] > 0) {
        L.acc2 = off;
        off += up(sizeof(Complex) * binsOf(2));
        L.out2 = off;
        off += up(sizeof(float) * 2 * kL[2]);
    }
    L.clearEnd = off;
    for (uint32_t s = 0; s < kSegs; ++s) {
        if (parts[s] == 0) continue;
        L.fdl[s] = off;
        off += up(sizeof(Complex) * binsOf(s) * parts[s]);
    }
    L.total = off;
    return L;
}

// ---- kernels -------------------------------------------------------------------------

inline void macAdd(Complex *acc, const Complex *h, const Complex *x, uint32_t bins) {
    for (uint32_t k = 0; k < bins; ++k) {
        acc[k].re += h[k].re * x[k].re - h[k].im * x[k].im;
        acc[k].im += h[k].re * x[k].im + h[k].im * x[k].re;
    }
}

// Forward FFT of the 2L-sample window of the ring ending (exclusive) at `end`, into `sc`.
void fwdWindow(const void *plan, uint32_t s, const float *ring, uint32_t mask, uint32_t end, Complex *sc) {
    const uint32_t N = fftN(s);
    const uint32_t start = end - N;
    for (uint32_t k = 0; k < N; ++k) sc[k] = {ring[(start + k) & mask], 0.0f};
    fft::forward(plan, sc);
}

// Mirrors bins L+1..N-1 from bins 1..L-1 (real signal), inverse transforms, leaves the valid half at sc[L..N).
void invertHalf(const void *plan, uint32_t s, Complex *sc) {
    const uint32_t L = kL[s], N = fftN(s);
    for (uint32_t k = 1; k < L; ++k) sc[N - k] = {sc[k].re, -sc[k].im};
    fft::inverse(plan, sc);
}

uint64_t fftOps(uint32_t s) { return 5ull * fftN(s) * log2u(fftN(s)); }

struct Ctx {
    Shared *S;
    uint8_t *sh;
    SLayout SL;
    uint8_t *lane;
    LLayout LL;
    LaneHdr *hdr;
    float *outBuf, *ring;
    uint32_t mask;
    Complex *scratch;
    const void *plan(uint32_t s) const { return sh + SL.plan[s]; }
    const Complex *H(uint32_t s, uint32_t q) const {
        return reinterpret_cast<const Complex *>(sh + SL.h[s]) + size_t(q) * binsOf(s);
    }
    Complex *fdl(uint32_t s, uint32_t slot) const {
        return reinterpret_cast<Complex *>(lane + LL.fdl[s]) + size_t(slot) * binsOf(s);
    }
    Complex *acc(uint32_t s) const { return reinterpret_cast<Complex *>(lane + (s == 1 ? LL.acc1 : LL.acc2)); }
    float *out1() const { return reinterpret_cast<float *>(lane + LL.out1); }
    float *out2(uint32_t which) const { return reinterpret_cast<float *>(lane + LL.out2) + size_t(which) * kL[2]; }
};

// Slot of the spectrum `back` steps older than the newest of segment s.
inline uint32_t slotBack(const Ctx &c, uint32_t s, uint32_t back) {
    const uint32_t P = c.S->parts[s];
    const uint32_t h = c.hdr->head[s];
    return h >= back ? h - back : h + P - back;
}

// Inserts the spectrum in scratch (bins 0..L) as the newest of segment s.
void pushSpectrum(Ctx &c, uint32_t s) {
    const uint32_t P = c.S->parts[s];
    c.hdr->head[s] = c.hdr->head[s] + 1 == P ? 0 : c.hdr->head[s] + 1;
    if (c.hdr->cnt[s] < P) ++c.hdr->cnt[s];
    std::memcpy(c.fdl(s, c.hdr->head[s]), c.scratch, sizeof(Complex) * binsOf(s));
}

// acc += H[q] * (spectrum q-1 steps back from the newest), for q >= 1 while enough history exists.
void macOlder(Ctx &c, uint32_t s, Complex *acc, uint32_t qLo, uint32_t qHi, uint64_t &ops) {
    for (uint32_t q = qLo; q < qHi; ++q) {
        if (q - 1 >= c.hdr->cnt[s]) break;
        macAdd(acc, c.H(s, q), c.fdl(s, slotBack(c, s, q - 1)), binsOf(s));
        ops += 8ull * binsOf(s);
    }
}

void tick(Ctx &c, uint64_t &ops) {
    LaneHdr &h = *c.hdr;
    const uint32_t T = h.tick;
    const uint32_t wp = h.wp;  // = 256 (T + 1) (mod 2^32)
    const Shared &S = *c.S;
    const uint32_t ph4 = T & 3, ph16 = T & 15;
    if (S.parts[2] > 0 && ph16 == 4) h.outCur ^= 1;

    // Segment 0: a whole overlap-save step. The product is built in the scratch after the spectrum is saved.
    {
        fwdWindow(c.plan(0), 0, c.ring, c.mask, wp, c.scratch);
        pushSpectrum(c, 0);
        const uint32_t n = std::min(h.cnt[0], S.parts[0]);
        const uint32_t bins = binsOf(0);
        for (uint32_t k = 0; k < bins; ++k) c.scratch[k] = {0.0f, 0.0f};
        for (uint32_t q = 0; q < n; ++q) macAdd(c.scratch, c.H(0, q), c.fdl(0, slotBack(c, 0, q)), bins);
        invertHalf(c.plan(0), 0, c.scratch);
        for (uint32_t j = 0; j < kBlock; ++j) c.outBuf[j] = c.scratch[kL[0] + j].re;
        ops += fftOps(0) * 2 + 8ull * bins * n + 2 * fftN(0);
    }
    // Slices of the longer segments that are due this tick.
    if (S.parts[1] > 0) {
        const float *o = c.out1() + size_t(ph4) * kBlock;
        for (uint32_t j = 0; j < kBlock; ++j) c.outBuf[j] += o[j];
    }
    if (S.parts[2] > 0) {
        const float *o = c.out2(h.outCur) + size_t((ph16 + 12) & 15) * kBlock;
        for (uint32_t j = 0; j < kBlock; ++j) c.outBuf[j] += o[j];
    }
    // Segment 1 work.
    if (S.parts[1] > 0) {
        Complex *acc = c.acc(1);
        if (ph4 < 3) {
            if (ph4 + 1 < S.parts[1]) macOlder(c, 1, acc, ph4 + 1, ph4 + 2, ops);
        } else {
            fwdWindow(c.plan(1), 1, c.ring, c.mask, wp, c.scratch);
            pushSpectrum(c, 1);
            const uint32_t bins = binsOf(1);
            const Complex *h0 = c.H(1, 0);
            for (uint32_t k = 0; k < bins; ++k) {
                Complex x = c.scratch[k];
                c.scratch[k] = {acc[k].re + h0[k].re * x.re - h0[k].im * x.im, acc[k].im + h0[k].re * x.im + h0[k].im * x.re};
            }
            std::memset(acc, 0, sizeof(Complex) * bins);
            invertHalf(c.plan(1), 1, c.scratch);
            float *o = c.out1();
            for (uint32_t j = 0; j < kL[1]; ++j) o[j] = c.scratch[kL[1] + j].re;
            ops += fftOps(1) * 2 + 8ull * bins + 3 * fftN(1);
        }
    }
    // Segment 2 work.
    if (S.parts[2] > 0) {
        Complex *acc = c.acc(2);
        const uint32_t bins = binsOf(2);
        if (ph16 == 0) {
            fwdWindow(c.plan(2), 2, c.ring, c.mask, wp - kBlock, c.scratch);
            pushSpectrum(c, 2);
            ops += fftOps(2) + fftN(2);
        } else if (ph16 == 1) {
            if (h.cnt[2] > 0) {
                macAdd(acc, c.H(2, 0), c.fdl(2, h.head[2]), bins);
                ops += 8ull * bins;
            }
        } else if (ph16 == 2) {
            std::memcpy(c.scratch, acc, sizeof(Complex) * bins);
            std::memset(acc, 0, sizeof(Complex) * bins);
            invertHalf(c.plan(2), 2, c.scratch);
            float *o = c.out2(h.outCur ^ 1);
            for (uint32_t j = 0; j < kL[2]; ++j) o[j] = c.scratch[kL[2] + j].re;
            ops += fftOps(2) + 3 * fftN(2);
        } else if (S.parts[2] > 1) {
            const uint32_t nq = S.parts[2] - 1, j = ph16 - 3;
            macOlder(c, 2, acc, 1 + j * nq / 13, 1 + (j + 1) * nq / 13, ops);
        }
    }
}

Ctx make(Shared *S, uint8_t *sh, uint8_t *lane) {
    Ctx c{};
    c.S = S;
    c.sh = sh;
    c.SL = sLayout(S->parts);
    c.lane = lane;
    c.LL = lLayout(S->parts);
    c.hdr = reinterpret_cast<LaneHdr *>(lane);
    c.outBuf = reinterpret_cast<float *>(lane + c.LL.outBuf);
    c.ring = reinterpret_cast<float *>(lane + c.LL.ring);
    c.mask = static_cast<uint32_t>(c.LL.ringLen - 1);
    c.scratch = reinterpret_cast<Complex *>(sh + c.SL.scratch);
    return c;
}

}  // namespace

size_t sharedBytes(const float *taps, uint32_t n) {
    if (impulseIndex(taps, n) >= 0) return up(sizeof(Shared));
    uint32_t parts[kSegs];
    partsFor(n, parts);
    return sLayout(parts).total;
}

size_t laneBytes(const float *taps, uint32_t n) {
    const int64_t d = impulseIndex(taps, n);
    if (d >= 0) return up(sizeof(DelayHdr) + sizeof(float) * (size_t(d) + kBlock));
    uint32_t parts[kSegs];
    partsFor(n, parts);
    return lLayout(parts).total;
}

void init(void *shared, const float *taps, uint32_t n) {
    uint8_t *sh = static_cast<uint8_t *>(shared);
    Shared &S = *reinterpret_cast<Shared *>(sh);
    S.taps = n;
    const int64_t d = impulseIndex(taps, n);
    if (d >= 0) {
        S.mode = 1;
        S.delay = static_cast<uint32_t>(d);
        return;
    }
    S.mode = 0;
    partsFor(n, S.parts);
    const SLayout L = sLayout(S.parts);
    Complex *sc = reinterpret_cast<Complex *>(sh + L.scratch);
    for (uint32_t s = 0; s < kSegs; ++s) {
        if (S.parts[s] == 0) continue;
        fft::planInit(sh + L.plan[s], fftN(s));
        Complex *H = reinterpret_cast<Complex *>(sh + L.h[s]);
        for (uint32_t q = 0; q < S.parts[s]; ++q) {
            const size_t t0 = size_t(kOff[s]) + size_t(q) * kL[s];
            for (uint32_t k = 0; k < fftN(s); ++k) {
                const size_t t = t0 + k;
                sc[k] = {k < kL[s] && t < n ? taps[t] : 0.0f, 0.0f};
            }
            fft::forward(sh + L.plan[s], sc);
            std::memcpy(H + size_t(q) * binsOf(s), sc, sizeof(Complex) * binsOf(s));
        }
    }
    // The scratch is dead after init; the realtime thread overwrites it before every use.
}

uint32_t laneEpoch(const void *lane) { return *static_cast<const uint32_t *>(lane); }

void resetLane(const void *shared, void *lane, uint32_t epoch) {
    const Shared &S = *static_cast<const Shared *>(shared);
    uint8_t *lb = static_cast<uint8_t *>(lane);
    if (S.mode == 1) {
        DelayHdr &h = *reinterpret_cast<DelayHdr *>(lb);
        h.epoch = epoch;
        h.pos = 0;
        std::memset(lb + sizeof(DelayHdr), 0, sizeof(float) * (size_t(S.delay) + kBlock));
        return;
    }
    const LLayout LL = lLayout(S.parts);
    std::memset(lb, 0, LL.clearEnd);
    LaneHdr &h = *reinterpret_cast<LaneHdr *>(lb);
    h.epoch = epoch;
    for (uint32_t s = 0; s < kSegs; ++s) h.head[s] = S.parts[s] > 0 ? S.parts[s] - 1 : 0;
}

void process(void *shared, void *lane, float *buf, uint32_t frames, Counter *counter) {
    uint8_t *sh = static_cast<uint8_t *>(shared);
    Shared &S = *reinterpret_cast<Shared *>(sh);
    uint8_t *lb = static_cast<uint8_t *>(lane);
    if (S.mode == 1) {
        DelayHdr &h = *reinterpret_cast<DelayHdr *>(lb);
        float *ring = reinterpret_cast<float *>(lb + sizeof(DelayHdr));
        const uint32_t D = S.delay + kBlock;
        uint32_t pos = h.pos;
        for (uint32_t i = 0; i < frames; ++i) {
            const float y = ring[pos];
            ring[pos] = buf[i];
            buf[i] = y;
            pos = pos + 1 == D ? 0 : pos + 1;
        }
        h.pos = pos;
        return;
    }
    Ctx c = make(&S, sh, lb);
    LaneHdr &h = *c.hdr;
    while (frames > 0) {
        const uint32_t n = std::min(frames, kBlock - h.fill);
        const float *out = c.outBuf + h.fill;
        for (uint32_t i = 0; i < n; ++i) {
            const float y = out[i];
            c.ring[(h.wp + i) & c.mask] = buf[i];
            buf[i] = y;
        }
        h.fill += n;
        h.wp += n;
        buf += n;
        frames -= n;
        if (h.fill == kBlock) {
            h.fill = 0;
            uint64_t ops = 0;
            tick(c, ops);
            ++h.tick;
            if (counter != nullptr) {
                counter->lastTick = ops;
                counter->worstTick = std::max(counter->worstTick, ops);
                counter->totalOps += ops;
                ++counter->ticks;
            }
        }
    }
}

}  // namespace n60::conv
