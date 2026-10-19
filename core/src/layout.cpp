// libn60core ABI v6 layouts and graph builder (E6 S7). Control thread only; nothing here runs in an
// audio callback. Portable C++20; no Apple framework, no exceptions. The role numbering matches the app's
// N60ProgramChannelRole so the shell converts by value. The builder turns a layout and a render mode into
// an ordinary n60_graph_desc: stereo is the 2-channel layout, and the binaural renderer is one graph stage,
// so changing mode is publishing another description (the rebuild fade makes it click-free).
#include <cmath>
#include <cstring>
#include <new>

#include "n60/graph.h"
#include "snapshot.hpp"

namespace {

constexpr uint32_t kRoleMax = N60_ROLE_CUSTOM_1 + 15;  // 32

struct Canonical {
    uint32_t count;
    uint32_t roles[16];
};

const Canonical kStandard[] = {
    {0, {}},
    {2, {1, 2}},
    {6, {1, 2, 3, 4, 5, 6}},
    {8, {1, 2, 3, 4, 5, 6, 7, 8}},
    {8, {1, 2, 3, 4, 5, 6, 13, 14}},
    {10, {1, 2, 3, 4, 5, 6, 11, 12, 15, 16}},
    {12, {1, 2, 3, 4, 5, 6, 7, 8, 11, 12, 15, 16}},
    {16, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}},
};
constexpr uint32_t kStandardCount = sizeof(kStandard) / sizeof(kStandard[0]);

// First role of each left/right pair: FL/FR, SL/SR, RL/RR, WL/WR, TFL/TFR, TML/TMR, TRL/TRR, then customs.
bool isPairLeft(uint32_t role) {
    if (role >= 1 && role <= 16) return role != 3 && role != 4 && (role & 1u) == 1u;
    return role >= 17 && role <= 31 && ((role - 17) & 1u) == 0;
}

}  // namespace

struct n60_layout_graph {
    n60_graph_desc desc;
    n60_stage_desc *stages;
    float *pool;
    size_t poolSize, poolUsed;
    uint32_t stageCount;
};

extern "C" {

n60_status n60_layout_standard(uint32_t identifier, n60_layout *out) {
    if (out == nullptr || identifier == 0 || identifier >= kStandardCount) return N60_STATUS_BAD_ARGUMENT;
    std::memset(out, 0, sizeof(*out));
    out->structSize = sizeof(*out);
    out->identifier = identifier;
    out->channelCount = kStandard[identifier].count;
    for (uint32_t i = 0; i < out->channelCount; ++i) out->roles[i] = kStandard[identifier].roles[i];
    return N60_STATUS_OK;
}

n60_status n60_layout_validate(const n60_layout *l) {
    if (l == nullptr || l->structSize != sizeof(n60_layout)) return N60_STATUS_BAD_ARGUMENT;
    if (l->channelCount < 1 || l->channelCount > N60_LAYOUT_MAX_CHANNELS || l->identifier >= kStandardCount) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    uint64_t seen = 0;
    for (uint32_t i = 0; i < l->channelCount; ++i) {
        const uint32_t r = l->roles[i];
        if (r < 1 || r > kRoleMax || ((seen >> r) & 1u) != 0) return N60_STATUS_BAD_ARGUMENT;
        seen |= uint64_t(1) << r;
    }
    if (l->identifier != N60_LAYOUT_CUSTOM) {
        const Canonical &c = kStandard[l->identifier];
        if (l->channelCount != c.count) return N60_STATUS_BAD_ARGUMENT;
        for (uint32_t i = 0; i < c.count; ++i) {
            if (l->roles[i] != c.roles[i]) return N60_STATUS_BAD_ARGUMENT;
        }
    }
    return N60_STATUS_OK;
}

n60_status n60_layout_describe(const n60_layout *l, n60_layout_info *out) {
    if (out == nullptr || out->structSize != sizeof(n60_layout_info)) return N60_STATUS_BAD_ARGUMENT;
    const n60_status v = n60_layout_validate(l);
    if (v != N60_STATUS_OK) return v;
    int32_t laneOfRole[kRoleMax + 1];
    for (auto &x : laneOfRole) x = -1;
    for (uint32_t i = 0; i < l->channelCount; ++i) laneOfRole[l->roles[i]] = static_cast<int32_t>(i);
    std::memset(out, 0, sizeof(*out));
    out->structSize = sizeof(*out);
    out->centerLane = laneOfRole[N60_ROLE_FRONT_CENTER];
    out->lfeLane = laneOfRole[N60_ROLE_LFE];
    out->frontLeftLane = laneOfRole[N60_ROLE_FRONT_LEFT];
    out->frontRightLane = laneOfRole[N60_ROLE_FRONT_RIGHT];
    for (uint32_t r = 1; r + 1 <= kRoleMax; ++r) {
        if (!isPairLeft(r) || laneOfRole[r] < 0 || laneOfRole[r + 1] < 0) continue;
        const uint32_t k = out->pairCount++;
        out->pairLaneA[k] = static_cast<uint32_t>(laneOfRole[r]);
        out->pairLaneB[k] = static_cast<uint32_t>(laneOfRole[r + 1]);
        out->pairedMask |= (uint64_t(1) << out->pairLaneA[k]) | (uint64_t(1) << out->pairLaneB[k]);
    }
    for (uint32_t i = 0; i < l->channelCount; ++i) {
        if (static_cast<int32_t>(i) != out->lfeLane && ((out->pairedMask >> i) & 1u) == 0) {
            out->singleMask |= uint64_t(1) << i;
        }
    }
    return N60_STATUS_OK;
}

}  // extern "C"

namespace {

struct Builder {
    n60_layout_graph *g;
    n60_status status = N60_STATUS_OK;

    float *params(uint32_t n) {
        if (g->poolUsed + n > g->poolSize) {
            status = N60_STATUS_OUT_OF_MEMORY;
            return nullptr;
        }
        float *p = g->pool + g->poolUsed;
        g->poolUsed += n;
        return p;
    }
    // Appends a stage; the parameters are copied into the pool.
    n60_stage_desc *add(uint32_t kind, uint32_t id, uint32_t laneA, uint32_t laneB, uint64_t mask, const float *src,
                        uint32_t n) {
        if (status != N60_STATUS_OK) return nullptr;
        if (g->stageCount >= N60_GRAPH_MAX_STAGES) {
            status = N60_STATUS_BAD_ARGUMENT;
            return nullptr;
        }
        n60_stage_desc &s = g->stages[g->stageCount++];
        std::memset(&s, 0, sizeof(s));
        s.structSize = sizeof(s);
        s.kind = kind;
        s.stageId = id;
        s.laneA = laneA;
        s.laneB = laneB;
        s.laneMask = mask;
        s.paramCount = n;
        if (n > 0) {
            float *p = params(n);
            if (p == nullptr) return nullptr;
            if (src != nullptr) std::memcpy(p, src, sizeof(float) * n);
            s.params = p;
        }
        return &s;
    }
    void gain(uint32_t kind, uint32_t id, uint32_t lane, float v) { add(kind, id, lane, 0, 0, &v, 1); }
};

}  // namespace

extern "C" {

n60_status n60_layout_graph_build(const n60_layout_options *o, n60_layout_graph **out) {
    if (out == nullptr) return N60_STATUS_BAD_ARGUMENT;
    *out = nullptr;
    if (o == nullptr || o->structSize != sizeof(n60_layout_options) || o->reserved != 0 || o->layout == nullptr) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    n60_status st = n60_layout_validate(o->layout);
    if (st != N60_STATUS_OK) return st;
    const n60_layout &L = *o->layout;
    const uint32_t N = L.channelCount;
    const bool binaural = o->mode == N60_MODE_BINAURAL;
    if (o->mode != N60_MODE_SPEAKERS && !binaural) return N60_STATUS_BAD_ARGUMENT;
    const uint32_t minChannels = binaural && N < 2 ? 2u : N;
    const uint32_t chans = o->graphChannels == 0 ? minChannels : o->graphChannels;
    if (chans < minChannels || chans > N60_GRAPH_MAX_CHANNELS) return N60_STATUS_BAD_ARGUMENT;
    const float inGain = o->inputGain == 0.0f ? 1.0f : o->inputGain;
    const float outGain = o->outputGain == 0.0f ? 1.0f : o->outputGain;
    if (!(inGain > 0.0f && inGain <= 10000.0f) || !(outGain > 0.0f && outGain <= 10000.0f)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if ((o->peqParamCount > 0 && o->peq == nullptr) || o->peqParamCount % 4 != 0 || o->midSide > 1 ||
        o->linkedDynamics > 1 || o->protection > 1 || !std::isfinite(o->headphoneCrossfeed) ||
        o->headphoneCrossfeed < 0.0f || o->headphoneCrossfeed > 1.0f) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    uint64_t respCount = 0;
    const n60_binaural_profile *bp = o->binaural;
    if (binaural) {
        if (bp == nullptr || bp->structSize != sizeof(n60_binaural_profile) || bp->responses == nullptr ||
            bp->taps < 1 || bp->taps > N60_GRAPH_BINAURAL_MAX_TAPS || bp->orientations < 1 ||
            bp->orientations > N60_GRAPH_BINAURAL_MAX_SETS || bp->equalEarChannel < -1 ||
            bp->equalEarChannel >= static_cast<int32_t>(N) || bp->wrap > 1) {
            return N60_STATUS_BAD_ARGUMENT;
        }
        respCount = uint64_t(bp->orientations) * N * 2 * bp->taps;
    }
    n60_layout_info info;
    info.structSize = sizeof(info);
    st = n60_layout_describe(o->layout, &info);
    if (st != N60_STATUS_OK) return st;

    n60_layout_graph *g = new (std::nothrow) n60_layout_graph();
    if (g == nullptr) return N60_STATUS_OUT_OF_MEMORY;
    std::memset(g, 0, sizeof(*g));
    g->stages = new (std::nothrow) n60_stage_desc[N60_GRAPH_MAX_STAGES];
    g->poolSize = size_t(2048) + o->peqParamCount + (binaural ? size_t(10) + respCount : 0);
    g->pool = new (std::nothrow) float[g->poolSize];
    if (g->stages == nullptr || g->pool == nullptr) {
        n60_layout_graph_free(g);
        return N60_STATUS_OUT_OF_MEMORY;
    }

    Builder b{g};
    const uint64_t layoutMask = N >= 64 ? ~uint64_t(0) : (uint64_t(1) << N) - 1;
    b.add(N60_STAGE_SANITISE, N60_LSTAGE_SANITISE, N60_LANE_ALL, 0, 0, nullptr, 0);
    b.add(N60_STAGE_METER_IN, N60_LSTAGE_METER_IN, N60_LANE_ALL, 0, 0, nullptr, 0);
    b.gain(N60_STAGE_GAIN, N60_LSTAGE_INPUT_GAIN, N60_LANE_ALL, inGain);
    for (uint32_t lane = N; lane < chans; ++lane) b.gain(N60_STAGE_GAIN, N60_LSTAGE_SILENCE + lane, lane, 0.0f);
    if (o->midSide != 0) {
        for (uint32_t p = 0; p < info.pairCount; ++p) {
            b.add(N60_STAGE_MS_ENCODE, N60_LSTAGE_MS_ENCODE + p, info.pairLaneA[p], info.pairLaneB[p], 0, nullptr, 0);
        }
    }
    if (o->peqParamCount > 0) {
        b.add(N60_STAGE_PEQ, N60_LSTAGE_PEQ, N60_LANE_ALL, 0, 0, o->peq, o->peqParamCount);
    }
    if (o->midSide != 0) {
        for (uint32_t p = 0; p < info.pairCount; ++p) {
            b.add(N60_STAGE_MS_DECODE, N60_LSTAGE_MS_DECODE + p, info.pairLaneA[p], info.pairLaneB[p], 0, nullptr, 0);
        }
    }
    if (o->linkedDynamics != 0) {
        static const float kDefaultComp[10] = {-18.0f, 2.0f, 6.0f, 10.0f, 100.0f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f};
        const float *base = o->compressor != nullptr ? o->compressor : kDefaultComp;
        float c[10];
        std::memcpy(c, base, sizeof(c));
        for (uint32_t p = 0; p < info.pairCount; ++p) {
            c[9] = 1.0f;
            b.add(N60_STAGE_COMPRESSOR, N60_LSTAGE_PAIR_DYNAMICS + p, 0,0,
                  (uint64_t(1) << info.pairLaneA[p]) | (uint64_t(1) << info.pairLaneB[p]), c, 10);
        }
        for (uint32_t lane = 0; lane < N; ++lane) {
            if (((info.singleMask >> lane) & 1u) == 0) continue;
            c[9] = 0.0f;
            b.add(N60_STAGE_COMPRESSOR, N60_LSTAGE_LANE_DYNAMICS + lane, 0, 0, uint64_t(1) << lane, c, 10);
        }
    }
    b.add(N60_STAGE_METER_OUT, N60_LSTAGE_METER_OUT, N60_LANE_ALL, 0, 0, nullptr, 0);
    uint64_t outMask = layoutMask;
    if (binaural) {
        n60_stage_desc *s = b.add(N60_STAGE_BINAURAL, N60_LSTAGE_BINAURAL, 0, 1, layoutMask, nullptr,
                                  static_cast<uint32_t>(10 + respCount));
        if (s != nullptr) {
            float *p = const_cast<float *>(s->params);
            p[0] = bp->headYawDeg;
            p[1] = bp->headPitchDeg;
            p[2] = bp->headRollDeg;
            p[3] = static_cast<float>(bp->taps);
            p[4] = static_cast<float>(bp->orientations);
            p[5] = bp->yawStartDeg;
            p[6] = bp->yawStepDeg;
            p[7] = bp->wrap != 0 ? 1.0f : 0.0f;
            p[8] = static_cast<float>(bp->equalEarChannel);
            p[9] = static_cast<float>(bp->declaredLatency);
            std::memcpy(p + 10, bp->responses, sizeof(float) * static_cast<size_t>(respCount));
        }
        outMask = 3;
        b.gain(N60_STAGE_OUTPUT_GAIN, N60_LSTAGE_OUTPUT_GAIN + 0, 0, outGain);
        b.gain(N60_STAGE_OUTPUT_GAIN, N60_LSTAGE_OUTPUT_GAIN + 1, 1, outGain);
    } else {
        for (uint32_t lane = 0; lane < N; ++lane) b.gain(N60_STAGE_OUTPUT_GAIN, N60_LSTAGE_OUTPUT_GAIN + lane, lane, outGain);
    }
    if (o->headphoneCrossfeed > 0.0f) {
        const float hp[11] = {0.0f, o->headphoneCrossfeed, 30.0f, 0.0875f, 700.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f, 0.0f};
        b.add(N60_STAGE_HEADPHONE, N60_LSTAGE_HEADPHONE, 0, 1, 0, hp, 11);
    }
    if (o->protection != 0) {
        static const float kProt[7] = {1.0f, -1.0f, 1.0f, 100.0f, 0.0f, 0.0f, 1.0f};
        b.add(N60_STAGE_PROTECTION, N60_LSTAGE_PROTECTION, 0, 0, outMask, kProt, 7);
    }
    b.add(N60_STAGE_FINAL_SANITISE, N60_LSTAGE_FINAL_SANITISE, N60_LANE_ALL, 0, 0, nullptr, 0);
    b.add(N60_STAGE_FINAL_METER, N60_LSTAGE_FINAL_METER, N60_LANE_ALL, 0, 0, nullptr, 0);
    if (b.status != N60_STATUS_OK) {
        n60_layout_graph_free(g);
        return b.status;
    }
    g->desc.structSize = sizeof(n60_graph_desc);
    g->desc.abiVersion = N60_GRAPH_ABI_VERSION;
    g->desc.sampleRate = o->sampleRate;
    g->desc.maxBlockFrames = o->maxBlockFrames;
    g->desc.inputChannels = chans;
    g->desc.outputChannels = chans;
    g->desc.stages = g->stages;
    g->desc.stageCount = g->stageCount;
    st = n60::validateDesc(g->desc);
    if (st != N60_STATUS_OK) {
        n60_layout_graph_free(g);
        return st;
    }
    *out = g;
    return N60_STATUS_OK;
}

const n60_graph_desc *n60_layout_graph_desc(const n60_layout_graph *g) { return g != nullptr ? &g->desc : nullptr; }

void n60_layout_graph_free(n60_layout_graph *g) {
    if (g == nullptr) return;
    delete[] g->stages;
    delete[] g->pool;
    delete g;
}

}  // extern "C"
