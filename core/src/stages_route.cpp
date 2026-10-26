// libn60core ABI v17 speaker-routing stages (E8 S2): ROUTE and XOVER. Portable C++20, standard library plus the
// crossover library (n60/xover.h); no Apple framework, no exceptions, no RTTI.
//
// Derivations. ROUTE computes, for every destination lane d, y_d[n] = sum_e g_de[n] x_{s_de}[n] from the lane
// contents on entry to the stage, so a matrix with swapped or split sources is exact; a gain edit moves g_de
// linearly over the ramp window. XOVER runs, per lane, the cascade HP -> LP -> Linkwitz -> EQ in double precision
// (transposed direct form II biquads, the same arithmetic as the BASS_MGMT split) followed by the trim and
// polarity gain. The crossover cascades are produced by n60_xover_realise from a prototype stored at build, so
// the rendered coefficients equal the offline prediction (n60_xover_design) bit for bit. The Linkwitz transform is
// n60_xover_linkwitz (Linkwitz, "Active crossover networks for noncoincident drivers" / closed-box transform).
// A live edit crossfades the filter block over the ramp window: the incoming cascade starts from the live one's
// state (as PEQ), both run on the same input and the outputs are mixed with a linear weight.
//
// Realtime documentation (docs/REALTIME_RULES.md): see "Speaker routing" in n60/graph.h. In short, no allocation
// (every byte, scratch included, is in the snapshot arena), no synchronisation, latency 0, any sample rate, any
// lane set, and reset by a new snapshot only.
#include "stages_route.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>

#include "n60/xover.h"

namespace n60 {
namespace {

constexpr size_t kAlign = 16;
constexpr uint32_t kChunk = 256;
constexpr uint32_t kEntries = N60_ROUTE_MAX_ENTRIES;
constexpr uint32_t kPerDest = N60_ROUTE_PARAMS_PER_DEST;
constexpr uint32_t kFixed = N60_XOVER_FIXED_PARAMS;
constexpr uint32_t kMaxEq = N60_PEQ_MAX_SECTIONS;
constexpr uint32_t kMaxBlocks = 3 + kMaxEq;
constexpr uint32_t kMaxSec = N60_XOVER_MAX_SECTIONS;

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }

struct Ramp {
    float cur, target, step;
    uint32_t remaining;
};
void rampInit(Ramp &r, float v) {
    r.cur = r.target = v;
    r.step = 0.0f;
    r.remaining = 0;
}
void rampSet(Ramp &r, float t, uint32_t frames) {
    r.target = t;
    r.remaining = frames;
    r.step = (t - r.cur) / static_cast<float>(frames);
}
// Same formula as the GAIN stage: computed from the destination so the last sample is exact.
inline float rampNext(Ramp &r) {
    if (r.remaining != 0) {
        --r.remaining;
        r.cur = r.target - r.step * static_cast<float>(r.remaining);
    }
    return r.cur;
}

struct Bq {
    double z1, z2;
};
inline double bqRun(const double *c, Bq &s, double x) {  // transposed direct form II
    const double y = c[0] * x + s.z1;
    s.z1 = c[1] * x - c[3] * y + s.z2;
    s.z2 = c[2] * x - c[4] * y;
    return y;
}
inline void bqFlush(Bq &s) {
    if (!(std::fabs(s.z1) >= 1e-30) || !std::isfinite(s.z1)) s.z1 = 0.0;
    if (!(std::fabs(s.z2) >= 1e-30) || !std::isfinite(s.z2)) s.z2 = 0.0;
}

// ---- ROUTE ---------------------------------------------------------------------------

struct RouteShared {
    uint64_t clearMask;   // source-only lanes, cleared after the sums
    uint32_t rampFrames;
    uint32_t pad;
};
struct RouteLane {
    Ramp g[kEntries];
};

uint32_t destCount(const n60_stage_desc &s) { return static_cast<uint32_t>(std::popcount(s.laneMask)); }

// ---- XOVER ---------------------------------------------------------------------------

enum BlockType : uint32_t { kHp = 0, kLp = 1, kLinkwitz = 2, kEq = 3 };

struct XBlock {
    uint32_t type;
    uint32_t nsec;
    uint32_t fading;
    uint32_t paramIdx;      // first live parameter of the block
    float seen[4];          // the parameter values the incoming (or live) coefficients were designed for
    double cur[kMaxSec][5];
    double nxt[kMaxSec][5];
    n60_xover_prototype proto;  // HP and LP
};
struct XShared {
    uint32_t nBlocks;
    uint32_t xfLeft;        // frames of coefficient crossfade left (0 = none)
    uint32_t rampFrames;
    uint32_t pad;
    Ramp gain;              // trim x polarity, linear
    XBlock blocks[kMaxBlocks];
};
struct XLane {
    Bq z[kMaxBlocks][kMaxSec];
    Bq zn[kMaxBlocks][kMaxSec];
};

double db2lin(double db) { return std::pow(10.0, db / 20.0); }
float gainTarget(const float *p) {
    return static_cast<float>(db2lin(p[6])) * (p[7] != 0.0f ? -1.0f : 1.0f);
}

bool filterSpecOk(float fam, float ord, bool allowOff) {
    if (!isInt(fam) || !isInt(ord) || fam < 0.0f || fam > (allowOff ? 3.0f : 2.0f)) return false;
    if (fam == 3.0f) return ord == 0.0f;
    n60_xover_prototype pr;
    return ord >= 1.0f && n60_xover_prototype_design(static_cast<uint32_t>(fam), static_cast<uint32_t>(ord), &pr) == N60_XOVER_OK;
}

// Designs the coefficients of one block for the parameters in p. Realtime-safe after the prototype is stored.
bool designBlock(const XBlock &b, const float *p, double fs, double out[kMaxSec][5]) {
    switch (b.type) {
        case kHp:
        case kLp: {
            n60_xover_cascade c;
            if (n60_xover_realise(&b.proto, b.type == kHp ? 1 : 0, p[b.paramIdx], fs, &c) != N60_XOVER_OK) return false;
            for (uint32_t s = 0; s < c.count; ++s) std::memcpy(out[s], &c.sections[s], sizeof(double) * 5);
            return true;
        }
        case kLinkwitz: {
            n60_xover_cascade c;
            if (n60_xover_linkwitz(p[b.paramIdx], p[b.paramIdx + 1], p[b.paramIdx + 2], p[b.paramIdx + 3], fs, &c) != N60_XOVER_OK) return false;
            std::memcpy(out[0], &c.sections[0], sizeof(double) * 5);
            return true;
        }
        default:
            return designBiquad(static_cast<uint32_t>(p[b.paramIdx - 1]), fs, p[b.paramIdx], p[b.paramIdx + 1], p[b.paramIdx + 2], out[0]);
    }
}

void readSeen(const XBlock &b, const float *p, float seen[4]) {
    seen[0] = seen[1] = seen[2] = seen[3] = 0.0f;
    const uint32_t n = b.type == kLinkwitz ? 4u : b.type == kEq ? 3u : 1u;
    for (uint32_t i = 0; i < n; ++i) seen[i] = p[b.paramIdx + i];
}

}  // namespace

bool isRouteKind(uint32_t kind) { return kind == N60_STAGE_ROUTE || kind == N60_STAGE_XOVER; }

n60_status validateRouteStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= N60_GRAPH_MIN_SAMPLE_RATE && rate <= N60_GRAPH_MAX_SAMPLE_RATE) || s.capacityFrames != 0 || s.laneB != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const bool maskInRange = outCh >= 64 || (s.laneMask >> outCh) == 0;
    if (s.params == nullptr) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    if (s.kind == N60_STAGE_ROUTE) {
        if (s.laneMask == 0 || s.laneA != 0 || !maskInRange) return N60_STATUS_BAD_ARGUMENT;
        if (s.paramCount != kPerDest * destCount(s)) return N60_STATUS_BAD_ARGUMENT;
        for (uint32_t d = 0; d < destCount(s); ++d) {
            for (uint32_t e = 0; e < kEntries; ++e) {
                const float src = p[kPerDest * d + 2 * e], g = p[kPerDest * d + 2 * e + 1];
                if (src == -1.0f) {
                    if (g != 0.0f) return N60_STATUS_BAD_ARGUMENT;
                } else if (!(isInt(src) && src >= 0.0f && src < static_cast<float>(outCh) && inR(g, -100.0, 100.0))) {
                    return N60_STATUS_BAD_ARGUMENT;
                }
            }
        }
        return N60_STATUS_OK;
    }
    // XOVER
    if (s.laneMask != 0) {
        if (s.laneA != 0 || !maskInRange) return N60_STATUS_BAD_ARGUMENT;
    } else if (s.laneA != N60_LANE_ALL && s.laneA >= outCh) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.paramCount < kFixed || !isInt(p[13]) || p[13] < 0.0f || p[13] > static_cast<float>(kMaxEq) ||
        s.paramCount != kFixed + 4 * static_cast<uint32_t>(p[13])) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const double top = 0.49 * rate;
    if (!filterSpecOk(p[0], p[1], true) || !filterSpecOk(p[3], p[4], true)) return N60_STATUS_BAD_ARGUMENT;
    if (p[0] != 3.0f && !inR(p[2], 1.0, top)) return N60_STATUS_BAD_ARGUMENT;
    if (p[3] != 3.0f && !inR(p[5], 1.0, top)) return N60_STATUS_BAD_ARGUMENT;
    if (!inR(p[6], -60.0, 24.0) || (p[7] != 0.0f && p[7] != 1.0f) || (p[8] != 0.0f && p[8] != 1.0f)) return N60_STATUS_BAD_ARGUMENT;
    if (p[8] != 0.0f && !(inR(p[9], 1.0, top) && inR(p[11], 1.0, top) && inR(p[10], 0.1, 20.0) && inR(p[12], 0.1, 20.0))) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    for (uint32_t k = 0; k < static_cast<uint32_t>(p[13]); ++k) {
        const float *q = p + kFixed + 4 * k;
        double c[5];
        if (!isInt(q[0]) || q[0] < 0.0f || q[0] > 7.0f || !(inR(q[1], 0.0, rate * 0.5) && q[1] > 0.0f) || !inR(q[2], -24.0, 24.0) ||
            !inR(q[3], 0.01, 1000.0) || !designBiquad(static_cast<uint32_t>(q[0]), rate, q[1], q[2], q[3], c)) {
            return N60_STATUS_BAD_ARGUMENT;
        }
    }
    return N60_STATUS_OK;
}

void routeSizes(const n60_stage_desc &s, size_t &perLane, size_t &shared) {
    if (s.kind == N60_STAGE_ROUTE) {
        perLane = up(sizeof(RouteLane));
        shared = up(sizeof(RouteShared)) + up(sizeof(float) * size_t(kChunk) * destCount(s));
    } else {
        perLane = up(sizeof(XLane));
        shared = up(sizeof(XShared));
    }
}

void routeInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    if (r.kind == N60_STAGE_ROUTE) {
        RouteShared &S = *reinterpret_cast<RouteShared *>(sharedState(h, r));
        S.rampFrames = h->rampFrames;
        S.clearMask = 0;
        uint64_t dest = r.laneMask, srcs = 0;
        for (uint32_t d = 0; d < r.laneCount; ++d) {
            RouteLane &L = *reinterpret_cast<RouteLane *>(laneState(h, r, d));
            for (uint32_t e = 0; e < kEntries; ++e) {
                const float src = p[kPerDest * d + 2 * e];
                rampInit(L.g[e], p[kPerDest * d + 2 * e + 1]);
                if (src >= 0.0f) srcs |= uint64_t(1) << static_cast<uint32_t>(src);
            }
        }
        S.clearMask = srcs & ~dest;
        return;
    }
    XShared &S = *reinterpret_cast<XShared *>(sharedState(h, r));
    S.rampFrames = h->rampFrames;
    S.xfLeft = 0;
    rampInit(S.gain, gainTarget(p));
    S.nBlocks = 0;
    auto add = [&](uint32_t type, uint32_t paramIdx, uint32_t family, uint32_t order) {
        XBlock &b = S.blocks[S.nBlocks++];
        b.type = type;
        b.paramIdx = paramIdx;
        b.fading = 0;
        if (type == kHp || type == kLp) n60_xover_prototype_design(family, order, &b.proto);
        b.nsec = type == kHp || type == kLp ? b.proto.count * b.proto.copies : 1u;
        readSeen(b, p, b.seen);
        designBlock(b, p, h->sampleRate, b.cur);
        std::memcpy(b.nxt, b.cur, sizeof b.nxt);
    };
    if (p[0] != 3.0f) add(kHp, 2, static_cast<uint32_t>(p[0]), static_cast<uint32_t>(p[1]));
    if (p[3] != 3.0f) add(kLp, 5, static_cast<uint32_t>(p[3]), static_cast<uint32_t>(p[4]));
    if (p[8] != 0.0f) add(kLinkwitz, 9, 0, 0);
    for (uint32_t k = 0; k < static_cast<uint32_t>(p[13]); ++k) add(kEq, kFixed + 4 * k + 1, 0, 0);
}

static void runRouteStage(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    RouteShared &S = *reinterpret_cast<RouteShared *>(sharedState(h, r));
    float *scratch = reinterpret_cast<float *>(sharedState(h, r) + up(sizeof(RouteShared)));
    // Live gain edits start a ramp from the current value.
    for (uint32_t d = 0; d < r.laneCount; ++d) {
        RouteLane &L = *reinterpret_cast<RouteLane *>(laneState(h, r, d));
        for (uint32_t e = 0; e < kEntries; ++e) {
            const float g = p[kPerDest * d + 2 * e + 1];
            if (p[kPerDest * d + 2 * e] >= 0.0f && g != L.g[e].target) rampSet(L.g[e], g, S.rampFrames);
        }
    }
    float gv[kChunk];
    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = std::min(kChunk, frames - done);
        for (uint32_t d = 0; d < r.laneCount; ++d) {
            RouteLane &L = *reinterpret_cast<RouteLane *>(laneState(h, r, d));
            float *acc = scratch + size_t(d) * kChunk;
            bool first = true;
            for (uint32_t e = 0; e < kEntries; ++e) {
                const float srcf = p[kPerDest * d + 2 * e];
                if (srcf < 0.0f) continue;
                const float *x = lanes[static_cast<uint32_t>(srcf)] + done;
                Ramp &g = L.g[e];
                if (g.remaining == 0) {
                    const float c = g.cur;
                    if (first) for (uint32_t i = 0; i < n; ++i) acc[i] = c * x[i];
                    else for (uint32_t i = 0; i < n; ++i) acc[i] += c * x[i];
                } else {
                    for (uint32_t i = 0; i < n; ++i) gv[i] = rampNext(g);
                    if (first) for (uint32_t i = 0; i < n; ++i) acc[i] = gv[i] * x[i];
                    else for (uint32_t i = 0; i < n; ++i) acc[i] += gv[i] * x[i];
                }
                first = false;
            }
            if (first) for (uint32_t i = 0; i < n; ++i) acc[i] = 0.0f;
        }
        for (uint32_t d = 0; d < r.laneCount; ++d) {
            std::memcpy(lanes[laneOf(r, d)] + done, scratch + size_t(d) * kChunk, sizeof(float) * n);
        }
        uint64_t m = S.clearMask;
        while (m != 0) {
            const uint32_t l = static_cast<uint32_t>(std::countr_zero(m));
            m &= m - 1;
            std::memset(lanes[l] + done, 0, sizeof(float) * n);
        }
        done += n;
    }
}

static void runXoverStage(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    XShared &S = *reinterpret_cast<XShared *>(sharedState(h, r));

    // Block start: pick up live edits. Coefficients only when no crossfade is running (an edit during one waits).
    if (S.xfLeft == 0) {
        bool any = false;
        for (uint32_t b = 0; b < S.nBlocks; ++b) {
            XBlock &B = S.blocks[b];
            float now[4];
            readSeen(B, p, now);
            if (std::memcmp(now, B.seen, sizeof now) == 0) continue;
            std::memcpy(B.seen, now, sizeof now);
            if (!designBlock(B, p, h->sampleRate, B.nxt)) continue;
            B.fading = 1;
            any = true;
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                XLane &L = *reinterpret_cast<XLane *>(laneState(h, r, l));
                std::memcpy(L.zn[b], L.z[b], sizeof L.z[b]);
            }
        }
        if (any) S.xfLeft = S.rampFrames;
    }
    const float gt = gainTarget(p);
    if (gt != S.gain.target) rampSet(S.gain, gt, S.rampFrames);

    double x[kChunk], y[kChunk];
    float gv[kChunk];
    double tv[kChunk];
    for (uint32_t done = 0; done < frames;) {
        uint32_t n = std::min(kChunk, frames - done);
        const bool fading = S.xfLeft != 0;
        if (fading) {
            n = std::min(n, S.xfLeft);
            for (uint32_t i = 0; i < n; ++i) tv[i] = double(S.rampFrames - S.xfLeft + i + 1) / double(S.rampFrames);
        }
        for (uint32_t i = 0; i < n; ++i) gv[i] = rampNext(S.gain);
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            XLane &L = *reinterpret_cast<XLane *>(laneState(h, r, l));
            float *buf = lanes[laneOf(r, l)] + done;
            for (uint32_t i = 0; i < n; ++i) x[i] = buf[i];
            for (uint32_t b = 0; b < S.nBlocks; ++b) {
                XBlock &B = S.blocks[b];
                if (B.fading) {
                    std::memcpy(y, x, sizeof(double) * n);
                    for (uint32_t s = 0; s < B.nsec; ++s) {
                        for (uint32_t i = 0; i < n; ++i) x[i] = bqRun(B.cur[s], L.z[b][s], x[i]);
                        for (uint32_t i = 0; i < n; ++i) y[i] = bqRun(B.nxt[s], L.zn[b][s], y[i]);
                    }
                    for (uint32_t i = 0; i < n; ++i) x[i] += tv[i] * (y[i] - x[i]);
                } else {
                    for (uint32_t s = 0; s < B.nsec; ++s) {
                        for (uint32_t i = 0; i < n; ++i) x[i] = bqRun(B.cur[s], L.z[b][s], x[i]);
                    }
                }
                for (uint32_t s = 0; s < B.nsec; ++s) {
                    bqFlush(L.z[b][s]);
                    if (B.fading) bqFlush(L.zn[b][s]);
                }
            }
            for (uint32_t i = 0; i < n; ++i) buf[i] = static_cast<float>(x[i] * double(gv[i]));
        }
        if (fading) {
            S.xfLeft -= n;
            if (S.xfLeft == 0) {
                for (uint32_t b = 0; b < S.nBlocks; ++b) {
                    XBlock &B = S.blocks[b];
                    if (!B.fading) continue;
                    std::memcpy(B.cur, B.nxt, sizeof B.cur);
                    B.fading = 0;
                    for (uint32_t l = 0; l < r.laneCount; ++l) {
                        XLane &L = *reinterpret_cast<XLane *>(laneState(h, r, l));
                        std::memcpy(L.z[b], L.zn[b], sizeof L.z[b]);
                    }
                }
            }
        }
        done += n;
    }
}

void runRoute(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    if (r.kind == N60_STAGE_ROUTE) runRouteStage(h, r, lanes, frames);
    else runXoverStage(h, r, lanes, frames);
}

n60_status validateRouteParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    if (r.kind == N60_STAGE_ROUTE) {
        if (idx % 2 == 0) return N60_STATUS_UNSUPPORTED;               // source lane: topology
        if (paramsOf(h, r)[idx - 1] < 0.0f) return N60_STATUS_UNSUPPORTED;  // unused entry
        return inR(value, -100.0, 100.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
    }
    const double top = 0.49 * h->sampleRate;
    if (idx >= kFixed) {
        switch ((idx - kFixed) % 4) {
            case 0: return N60_STATUS_UNSUPPORTED;
            case 1: return (value > 0.0f && inR(value, 0.0, h->sampleRate * 0.5)) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
            case 2: return inR(value, -24.0, 24.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
            default: return inR(value, 0.01, 1000.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        }
    }
    switch (idx) {
        case 2: case 5: case 9: case 11: return inR(value, 1.0, top) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case 6: return inR(value, -60.0, 24.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case 7: return (value == 0.0f || value == 1.0f) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case 10: case 12: return inR(value, 0.1, 20.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        default: return N60_STATUS_UNSUPPORTED;  // family, order, enable, count: topology
    }
}

}  // namespace n60
