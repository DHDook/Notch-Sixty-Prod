// libn60core snapshot build and lane stages (E6 S3). Portable C++20: standard library
// only, no Apple framework, compiled without exceptions or RTTI.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runSnapshot and applyParam:
//  - allocation: none. Everything a stage needs lives in the snapshot arena.
//  - synchronisation: none except relaxed atomics for meters; stage state is owned by
//    the realtime thread once the snapshot is published.
//  - latency: GAIN, PEQ, sanitise, meters and M/S add 0 frames; DELAY adds its target.
//  - sample rate: any rate in [8 kHz, 768 kHz]. The ramp window is 5 ms of frames,
//    clamped to 32..4096. PEQ state and coefficients are double precision.
//  - channels: 1..64 lanes; stages address lanes by index; M/S needs two distinct lanes.
//  - reset: a fresh snapshot starts with zero filter and delay memory and meters at 0.
//    There is no in-place reset; a new topology is a new snapshot.
#include "snapshot.hpp"
#include "n60/profile.h"
#include "simd/simd.hpp"

#include "stages_dsp.hpp"
#include "stages_cleanup.hpp"
#include "stages_image.hpp"
#include "stages_loudness.hpp"
#include "stages_multiband.hpp"
#include "stages_generator.hpp"
#include "stages_route.hpp"
#include "stages_mimo.hpp"
#include "stages_matrix.hpp"
#include "stages_system.hpp"

#include <algorithm>
#include <cfloat>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr size_t kMaxArenaBytes = size_t(1) << 31;
constexpr size_t kAlign = 16;

struct GainLane {
    float cur;        // value after the last rendered sample
    float step;
    float target;     // ramp destination
    uint32_t remaining;
};

struct DelayLane {
    uint32_t wp;
    uint32_t dCur;
    uint32_t dNew;
    uint32_t xfLeft;
    int32_t pending;
    uint32_t pad[3];
    // followed by float ring[capacity + 1]
};

struct PeqLane {
    double z[N60_PEQ_MAX_SECTIONS][2];
    double zn[N60_PEQ_MAX_SECTIONS][2];  // incoming section state during a coefficient crossfade
};

// Per-section control block, stored in the stage's coefficient region (shared by all lanes).
struct PeqSec {
    double cur[5];       // live coefficients (b0 b1 b2 a1 a2)
    double nxt[5];       // incoming coefficients while xfLeft != 0
    float seen[4];       // parameters the live/incoming design was made from
    uint32_t xfLeft;     // frames left in the crossfade (0 = none)
    uint32_t form;       // type 9 only: the partner's form slot (type 10 slot 3) the design was made with
};

struct MeterLane {
    std::atomic<uint32_t> peakBits;  // positive floats order like their bit patterns
    std::atomic<uint32_t> rmsBits;
    std::atomic<uint64_t> overRange;  // ABI v8: samples with |x| > 1.0 since the last read
};

size_t alignUp(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }

uint32_t floatBits(float v) {
    uint32_t b;
    std::memcpy(&b, &v, sizeof b);
    return b;
}
float bitsFloat(uint32_t b) {
    float v;
    std::memcpy(&v, &b, sizeof v);
    return v;
}

uint32_t rampFramesFor(double rate) {
    long frames = std::lround(0.005 * rate);
    return static_cast<uint32_t>(std::clamp<long>(frames, 32, 4096));
}

}  // namespace

// RBJ Audio EQ Cookbook biquads, normalised by a0, in double precision.
// Same forms and limits as the kernel's control-plane design (N60Biquad.h).
bool designBiquad(uint32_t type, double rate, double f, double gainDb, double q, double out[5]) N60_RT_NONBLOCKING {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(gainDb) || gainDb < -24.0 ||
        gainDb > 24.0 || !std::isfinite(q) || q <= 0.0) {
        return false;
    }
    const double w = 2.0 * kPi * f / rate;
    const double cw = std::cos(w);
    const double sw = std::sin(w);
    const double alpha = sw / (2.0 * q);
    double b0 = 0, b1 = 0, b2 = 0, a0 = 1, a1 = 0, a2 = 0;
    switch (type) {
        case 0: {  // peaking
            const double A = std::pow(10.0, gainDb / 40.0);
            b0 = 1 + alpha * A; b1 = -2 * cw; b2 = 1 - alpha * A;
            a0 = 1 + alpha / A; a1 = -2 * cw; a2 = 1 - alpha / A;
            break;
        }
        case 1: {  // low shelf
            const double A = std::pow(10.0, gainDb / 40.0);
            const double beta = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) - (A - 1) * cw + beta);
            b1 = 2 * A * ((A - 1) - (A + 1) * cw);
            b2 = A * ((A + 1) - (A - 1) * cw - beta);
            a0 = (A + 1) + (A - 1) * cw + beta;
            a1 = -2 * ((A - 1) + (A + 1) * cw);
            a2 = (A + 1) + (A - 1) * cw - beta;
            break;
        }
        case 2: {  // high shelf
            const double A = std::pow(10.0, gainDb / 40.0);
            const double beta = 2.0 * std::sqrt(A) * alpha;
            b0 = A * ((A + 1) + (A - 1) * cw + beta);
            b1 = -2 * A * ((A - 1) + (A + 1) * cw);
            b2 = A * ((A + 1) + (A - 1) * cw - beta);
            a0 = (A + 1) - (A - 1) * cw + beta;
            a1 = 2 * ((A - 1) - (A + 1) * cw);
            a2 = (A + 1) - (A - 1) * cw - beta;
            break;
        }
        case 3:  // low pass
            b0 = (1 - cw) * 0.5; b1 = 1 - cw; b2 = (1 - cw) * 0.5;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 4:  // high pass
            b0 = (1 + cw) * 0.5; b1 = -(1 + cw); b2 = (1 + cw) * 0.5;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 5:  // notch
            b0 = 1; b1 = -2 * cw; b2 = 1;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 6:  // all pass
            b0 = 1 - alpha; b1 = -2 * cw; b2 = 1 + alpha;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        case 7:  // band pass, constant 0 dB peak
            b0 = alpha; b1 = 0; b2 = -alpha;
            a0 = 1 + alpha; a1 = -2 * cw; a2 = 1 - alpha;
            break;
        default:
            return false;
    }
    if (!std::isfinite(a0) || std::fabs(a0) < 1e-20) return false;
    out[0] = b0 / a0; out[1] = b1 / a0; out[2] = b2 / a0; out[3] = a1 / a0; out[4] = a2 / a0;
    for (int i = 0; i < 5; ++i) {
        if (!std::isfinite(out[i])) return false;
    }
    return true;
}

namespace {

// One PEQ section (ABI v26): types 0..7 as designBiquad, 8 constant-Q peaking (cookbook Q = Q / A, so Q is the classic
// electrical Q), 9 the numerator half and 10 the denominator half of one prepared biquad (see graph.h).
// E23 S1b (E6 G31): a prepared biquad whose type 10 half carries a non-zero fourth slot (1) is in deviation form, for a
// pole pair and a zero pair near z = 1 (low corners at high rates), where float coefficients quantise the poles. With
// y = 1 - 1/z the numerator is n0 + n1 y + n2 y^2 and the denominator d0 + d1 y + (1 - d0 - d1) y^2, so
//   type 9 slots (n0, n1, n2):  b0 = n0 + n1 + n2, b1 = -n1 - 2 n2, b2 = n2
//   type 10 slots (d0, d1, 1):  a1 = d1 + 2 d0 - 2, a2 = 1 - d0 - d1
// all evaluated in double from the float slots; n0, n1, d0 and d1 are small and keep full relative precision. A zero
// fourth slot is the original form (b0, b1, b2 and a1, a2 stored directly), so existing callers are unchanged.
// `next` is the section after p (the type 10 half of a type 9), or null at the end of the stage.
bool designPeqSection(const float *p, const float *next, double rate, double out[5]) {
    const uint32_t type = static_cast<uint32_t>(p[0]);
    if (type <= 7) return designBiquad(type, rate, p[1], p[2], p[3], out);
    if (type == 8) {
        if (!std::isfinite(p[2]) || p[2] < -24.0f || p[2] > 24.0f || !(p[3] > 0.0f)) return false;
        return designBiquad(0, rate, p[1], p[2], static_cast<double>(p[3]) / std::pow(10.0, static_cast<double>(p[2]) / 40.0), out);
    }
    if (!std::isfinite(p[1]) || !std::isfinite(p[2]) || !std::isfinite(p[3])) return false;
    if (type == 9) {
        if (next != nullptr && next[3] == 1.0f) {
            const double n0 = p[1], n1 = p[2], n2 = p[3];
            out[0] = n0 + n1 + n2; out[1] = -n1 - 2.0 * n2; out[2] = n2;
        } else {
            out[0] = p[1]; out[1] = p[2]; out[2] = p[3];
        }
        out[3] = 0.0; out[4] = 0.0;
    } else {
        // The denominator must be strictly stable (inside the stability triangle), or a hostile snapshot could build a
        // runaway recursion.
        if (p[3] != 0.0f && p[3] != 1.0f) return false;  // the form slot is 0 (coefficients) or 1 (deviation form)
        double a1 = p[1], a2 = p[2];
        if (p[3] == 1.0f) {
            const double d0 = p[1], d1 = p[2];
            a2 = 1.0 - d0 - d1;
            a1 = d1 + 2.0 * d0 - 2.0;
        }
        if (!(std::fabs(a2) < 1.0 && std::fabs(a1) < 1.0 + a2)) return false;
        out[0] = 1.0; out[1] = 0.0; out[2] = 0.0; out[3] = a1; out[4] = a2;
    }
    return true;
}

bool paramsFinite(const n60_stage_desc &s) {
    for (uint32_t i = 0; i < s.paramCount; ++i) {
        if (!std::isfinite(s.params[i])) return false;
    }
    return true;
}

uint32_t laneCountFor(const n60_stage_desc &s, uint32_t outCh) {
    if (s.laneMask != 0) return static_cast<uint32_t>(std::popcount(s.laneMask));
    return s.laneA == N60_LANE_ALL ? outCh : 1u;
}

// Position of a kind in the processing order (the numeric values predate ABI v3 and are
// kept for compatibility; the new kinds slot in by rank).
uint32_t rankBase(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_SANITISE: return 1;
        case N60_STAGE_METER_IN: return 2;
        case N60_STAGE_GAIN: return 3;
        case N60_STAGE_DENOISER: return 4;
        case N60_STAGE_MS_ENCODE: return 5;
        case N60_STAGE_PEQ: return 6;
        case N60_STAGE_DYN_EQ: return 7;
        case N60_STAGE_MS_DECODE: return 8;
        case N60_STAGE_FIR: return 9;
        case N60_STAGE_COMPRESSOR: return 10;
        case N60_STAGE_EXPANDER: return 11;
        case N60_STAGE_METER_OUT: return 12;
        case N60_STAGE_BASS_MGMT: return 13;
        case N60_STAGE_STEREO_CROSSOVER: return 13;
        case N60_STAGE_ROOM_FIR: return 14;
        case N60_STAGE_ROOM_FIR_TWO_BAND: return 14;
        case N60_STAGE_SPEAKER_IR: return 15;
        case N60_STAGE_AMBIENT: return 16;
        case N60_STAGE_CORE_DYNAMICS: return 17;
        case N60_STAGE_SYMMETRY: return 18;
        case N60_STAGE_CROSSFEED: return 19;
        case N60_STAGE_CROSSTALK: return 20;
        case N60_STAGE_OUTPUT_GAIN: return 21;
        case N60_STAGE_HEADPHONE: return 22;
        case N60_STAGE_PAUSE_GATE: return 23;
        case N60_STAGE_DELAY: return 24;
        case N60_STAGE_FRAC_DELAY: return 24;
        case N60_STAGE_ANC_GUARD: return 25;
        case N60_STAGE_ANC_INJECT: return 26;
        case N60_STAGE_PROTECTION: return 27;
        case N60_STAGE_MUTE: return 28;
        case N60_STAGE_ANC_CAPTURE: return 29;
        case N60_STAGE_FINAL_SANITISE: return 30;
        case N60_STAGE_FINAL_METER: return 31;
        default: return 0;
    }
}

// Ranks are scaled by ten so a stage can sit between two older kinds (BINAURAL, 17.5: after
// CORE_DYNAMICS and before SYMMETRY).
uint32_t rankOf(uint32_t kind) {
    if (kind == N60_STAGE_BINAURAL) return 175;
    if (kind == N60_STAGE_EXTERNAL) return 125;
    if (kind == N60_STAGE_LANE_DELAY) return 126;       // ABI v28: after EXTERNAL, before BASS_MGMT (130); runs as DELAY
    if (kind == N60_STAGE_DELTA_CAPTURE) return 15;     // ABI v30: after SANITISE (10), before METER_IN (20)
    if (kind == N60_STAGE_DELTA_SUBTRACT) return 275;   // ABI v30: after PROTECTION (270), before MUTE (280)
    if (kind == N60_STAGE_GENERATOR) return 35;
    if (kind == N60_STAGE_CLEANUP) return 37;           // ABI v22: after the generator, before the denoiser (rank 40)
    if (kind == N60_STAGE_IMAGE) return 96;             // ABI v23: after the EQ tap, before the de-esser and the compressor
    if (kind == N60_STAGE_LOUDNESS) return 97;          // ABI v24: after IMAGE, before the de-esser
    if (kind == N60_STAGE_MULTIBAND) return 99;         // ABI v25: after the de-esser, before the compressor (100)
    if (kind == N60_STAGE_DEESS) return 98;             // ABI v23: after IMAGE (and the S12c loudness slot at 97), before the compressor (100)
    if (kind == N60_STAGE_ANALYSER_TAP_EQ) return 95;   // ABI v21: after FIR, before the compressor
    if (kind == N60_STAGE_ANALYSER_TAP_DYN) return 115; // ABI v21: after the expander, before METER_OUT
    if (kind == N60_STAGE_MIMO) return 135;             // ABI v33: after BASS_MGMT (130), before ROOM_FIR (140)
    if (kind == N60_STAGE_ROUTE) return 235;
    if (kind == N60_STAGE_XOVER) return 236;
    if (kind == N60_STAGE_DRIVER_FIR || kind == N60_STAGE_DRIVER_FIR_TWO_BAND) return 237;
    return rankBase(kind) * 10;
}

// Kinds that reuse another stage's implementation run as that canonical kind; only the
// rank (position in the chain) differs.
uint32_t canonKind(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_LANE_DELAY: return N60_STAGE_DELAY;
        case N60_STAGE_ROOM_FIR:
        case N60_STAGE_SPEAKER_IR:
        case N60_STAGE_DRIVER_FIR: return N60_STAGE_FIR;
        case N60_STAGE_DRIVER_FIR_TWO_BAND: return N60_STAGE_ROOM_FIR_TWO_BAND;
        case N60_STAGE_CORE_DYNAMICS: return N60_STAGE_COMPRESSOR;
        case N60_STAGE_OUTPUT_GAIN: return N60_STAGE_GAIN;
        case N60_STAGE_FINAL_SANITISE: return N60_STAGE_SANITISE;
        case N60_STAGE_FINAL_METER: return N60_STAGE_METER_OUT;
        default: return kind;
    }
}

// Per-stage state size in bytes for one lane.
size_t stateStrideFor(const n60_stage_desc &s, double rate, uint32_t firScheme) {
    switch (s.kind) {
        case N60_STAGE_METER_IN:
        case N60_STAGE_METER_OUT: return sizeof(MeterLane);
        case N60_STAGE_GAIN: return sizeof(GainLane);
        case N60_STAGE_PEQ: return sizeof(PeqLane);
        case N60_STAGE_DELAY:
            return alignUp(sizeof(DelayLane) + (size_t(s.capacityFrames) + 1) * sizeof(float));
        default: {
            size_t lane = 0, shared = 0;
            if (isDspKind(s.kind)) dspSizes(s, firScheme, lane, shared);
            else if (isSystemKind(s.kind)) systemSizes(s, rate, lane, shared);
            else if (isMatrixKind(s.kind)) matrixSizes(s, lane, shared);
            else if (isGeneratorKind(s.kind)) generatorSizes(s, rate, lane, shared);
            else if (isCleanupKind(s.kind)) cleanupSizes(s, rate, lane, shared);
            else if (isImageKind(s.kind)) imageSizes(s, rate, lane, shared);
            else if (isLoudnessKind(s.kind)) loudnessSizes(s, rate, lane, shared);
            else if (isMultibandKind(s.kind)) multibandSizes(s, rate, lane, shared);
            else if (isRouteKind(s.kind)) routeSizes(s, lane, shared);
            else if (isMimoKind(s.kind)) mimoSizes(s, lane, shared);
            return lane;
        }
    }
}

size_t sharedBytesFor(const n60_stage_desc &s, double rate, uint32_t firScheme) {
    size_t lane = 0, shared = 0;
    if (isDspKind(s.kind)) dspSizes(s, firScheme, lane, shared);
    else if (isSystemKind(s.kind)) systemSizes(s, rate, lane, shared);
    else if (isMatrixKind(s.kind)) matrixSizes(s, lane, shared);
    else if (isGeneratorKind(s.kind)) generatorSizes(s, rate, lane, shared);
    else if (isCleanupKind(s.kind)) cleanupSizes(s, rate, lane, shared);
    else if (isImageKind(s.kind)) imageSizes(s, rate, lane, shared);
    else if (isLoudnessKind(s.kind)) loudnessSizes(s, rate, lane, shared);
    else if (isMultibandKind(s.kind)) multibandSizes(s, rate, lane, shared);
    else if (isRouteKind(s.kind)) routeSizes(s, lane, shared);
    else if (isMimoKind(s.kind)) mimoSizes(s, lane, shared);
    return shared;
}

}  // namespace

n60_status validateDesc(const n60_graph_desc &d) {
    if (d.abiVersion != N60_GRAPH_ABI_VERSION || d.structSize != sizeof(n60_graph_desc)) {
        return N60_STATUS_ABI_MISMATCH;
    }
    if (!std::isfinite(d.sampleRate) || d.sampleRate < N60_GRAPH_MIN_SAMPLE_RATE ||
        d.sampleRate > N60_GRAPH_MAX_SAMPLE_RATE) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    auto validChannels = [](uint32_t n) { return n >= 1 && n <= N60_GRAPH_MAX_CHANNELS; };
    if (d.maxBlockFrames < 1 || d.maxBlockFrames > N60_GRAPH_MAX_BLOCK_FRAMES || !validChannels(d.inputChannels) ||
        !validChannels(d.outputChannels) || d.reserved != 0 || d.reserved2 != 0 || d.reserved3 != 0 || d.firScheme > 1) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if ((d.parkFftSize != 0 && d.parkFftSize != 1024 && d.parkFftSize != 2048 && d.parkFftSize != 4096) ||
        d.parkCommand > 2 || d.parkRevision > 16777216u) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (d.stageCount > N60_GRAPH_MAX_STAGES || (d.stageCount > 0 && d.stages == nullptr)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    uint32_t lastRank = 0;
    size_t total = 0;
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        if (s.structSize != sizeof(n60_stage_desc)) return N60_STATUS_ABI_MISMATCH;
        const uint32_t rank = rankOf(s.kind);
        s.kind = canonKind(s.kind);
        if (rank == 0 || rank < lastRank || s.reserved != 0) return N60_STATUS_BAD_ARGUMENT;
        lastRank = rank;
        for (uint32_t j = 0; j < i; ++j) {
            if (d.stages[j].stageId == s.stageId) return N60_STATUS_BAD_ARGUMENT;
        }
        if (s.paramCount > 0 && s.params == nullptr) return N60_STATUS_BAD_ARGUMENT;
        if (!paramsFinite(s)) return N60_STATUS_BAD_ARGUMENT;
        if (s.kind == N60_STAGE_EXTERNAL) {  // ABI v13: one host callback per graph
            for (uint32_t j = 0; j < i; ++j) {
                if (d.stages[j].kind == N60_STAGE_EXTERNAL) return N60_STATUS_BAD_ARGUMENT;
            }
        }
        const bool isMS = s.kind == N60_STAGE_MS_ENCODE || s.kind == N60_STAGE_MS_DECODE;
        if (isSystemKind(s.kind)) {
            const n60_status v = validateSystemStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isDspKind(s.kind)) {
            const n60_status v = validateDspStage(s, d.sampleRate, d.outputChannels, d.firScheme);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isMatrixKind(s.kind)) {
            const n60_status v = validateMatrixStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isGeneratorKind(s.kind)) {
            const n60_status v = validateGeneratorStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isCleanupKind(s.kind)) {
            const n60_status v = validateCleanupStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isImageKind(s.kind)) {
            const n60_status v = validateImageStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isLoudnessKind(s.kind)) {
            const n60_status v = validateLoudnessStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isMultibandKind(s.kind)) {
            const n60_status v = validateMultibandStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isMimoKind(s.kind)) {
            const n60_status v = validateMimoStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (isRouteKind(s.kind)) {
            const n60_status v = validateRouteStage(s, d.sampleRate, d.outputChannels);
            if (v != N60_STATUS_OK) return v;
            total += (stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels)) + sharedBytesFor(s, d.sampleRate, d.firScheme) +
                     size_t(s.paramCount) * sizeof(float);
            if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
            continue;
        }
        if (s.laneMask != 0) return N60_STATUS_BAD_ARGUMENT;
        if (isMS) {
            if (s.laneA >= d.outputChannels || s.laneB >= d.outputChannels || s.laneA == s.laneB) {
                return N60_STATUS_BAD_ARGUMENT;
            }
        } else if (s.laneA != N60_LANE_ALL && s.laneA >= d.outputChannels) {
            return N60_STATUS_BAD_ARGUMENT;
        }
        if (s.kind != N60_STAGE_DELAY && s.capacityFrames != 0) return N60_STATUS_BAD_ARGUMENT;
        switch (s.kind) {
            case N60_STAGE_GAIN:
                if (s.paramCount != 1 || !(s.params[0] >= -10000.0f) || s.params[0] > 10000.0f) return N60_STATUS_BAD_ARGUMENT;  // ABI v19: a negative gain inverts polarity
                break;
            case N60_STAGE_DELAY:
                if (s.paramCount != 1 || s.capacityFrames > N60_GRAPH_MAX_DELAY_FRAMES || s.params[0] < 0.0f ||
                    s.params[0] > static_cast<float>(s.capacityFrames)) {
                    return N60_STATUS_BAD_ARGUMENT;
                }
                break;
            case N60_STAGE_PEQ: {
                if (s.paramCount == 0 || s.paramCount % 4 != 0 || s.paramCount / 4 > N60_PEQ_MAX_SECTIONS) {
                    return N60_STATUS_BAD_ARGUMENT;
                }
                for (uint32_t k = 0; k < s.paramCount / 4; ++k) {
                    const float *p = s.params + 4 * k;
                    double c[5];
                    if (!(p[0] >= 0.0f && p[0] <= 10.0f) || p[0] != std::floor(p[0]) ||
                        !designPeqSection(p, k + 1 < s.paramCount / 4 ? p + 4 : nullptr, d.sampleRate, c)) {
                        return N60_STATUS_BAD_ARGUMENT;
                    }
                    // A type 9 numerator is followed by its type 10 denominator, and a type 10 follows a type 9.
                    const bool numerator = p[0] == 9.0f;
                    const bool followed = k + 1 < s.paramCount / 4 && p[4] == 10.0f;
                    const bool preceded = k > 0 && p[-4] == 9.0f;
                    if (numerator != followed || (p[0] == 10.0f) != preceded) return N60_STATUS_BAD_ARGUMENT;
                }
                break;
            }
            default:
                if (s.paramCount != 0) return N60_STATUS_BAD_ARGUMENT;
                break;
        }
        total += stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels);
        if (total > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
    }
    // ABI v30: a delta audition is a capture and a subtract on the same pair, in that order, one pair per graph.
    {
        uint32_t captures = 0, subtracts = 0, capIdx = 0, subIdx = 0;
        for (uint32_t i = 0; i < d.stageCount; ++i) {
            if (d.stages[i].kind == N60_STAGE_DELTA_CAPTURE) { ++captures; capIdx = i; }
            if (d.stages[i].kind == N60_STAGE_DELTA_SUBTRACT) { ++subtracts; subIdx = i; }
        }
        if (captures != subtracts || captures > 1) return N60_STATUS_BAD_ARGUMENT;
        if (captures == 1 && (d.stages[capIdx].laneA != d.stages[subIdx].laneA || d.stages[capIdx].laneB != d.stages[subIdx].laneB ||
                              d.stages[capIdx].laneMask != d.stages[subIdx].laneMask || capIdx > subIdx)) {
            return N60_STATUS_BAD_ARGUMENT;
        }
    }
    // Every M/S decode must undo exactly one earlier encode on the same lane pair.
    bool used[N60_GRAPH_MAX_STAGES] = {};
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        if (d.stages[i].kind != N60_STAGE_MS_DECODE) continue;
        bool matched = false;
        for (uint32_t j = 0; j < i && !matched; ++j) {
            const n60_stage_desc &e = d.stages[j];
            if (e.kind == N60_STAGE_MS_ENCODE && !used[j] && e.laneA == d.stages[i].laneA &&
                e.laneB == d.stages[i].laneB) {
                used[j] = true;
                matched = true;
            }
        }
        if (!matched) return N60_STATUS_BAD_ARGUMENT;
    }
    for (uint32_t j = 0; j < d.stageCount; ++j) {
        if (d.stages[j].kind == N60_STAGE_MS_ENCODE && !used[j]) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

n60_status buildSnapshot(const n60_graph_desc &d, uint32_t epoch, SnapHeader **out) {
    *out = nullptr;
    const n60_status valid = validateDesc(d);
    if (valid != N60_STATUS_OK) return valid;

    // Pass 1: lay out the arena.
    size_t off = alignUp(sizeof(SnapHeader));
    const size_t tableOff = off;
    off += alignUp(sizeof(StageRec) * d.stageCount);
    struct Plan { size_t params, state, coef, shared; };
    Plan plan[N60_GRAPH_MAX_STAGES];
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        s.kind = canonKind(s.kind);
        plan[i].params = off;
        off += alignUp(sizeof(float) * s.paramCount);
        plan[i].state = off;
        off += alignUp(stateStrideFor(s, d.sampleRate, d.firScheme) * laneCountFor(s, d.outputChannels));
        plan[i].coef = off;
        if (s.kind == N60_STAGE_PEQ) off += alignUp(sizeof(PeqSec) * (s.paramCount / kPeqParamsPerSection));
        plan[i].shared = off;
        off += alignUp(sharedBytesFor(s, d.sampleRate, d.firScheme));
        if (off > kMaxArenaBytes) return N60_STATUS_OUT_OF_MEMORY;
    }

    // One allocation, aligned to 64 bytes by hand (no aligned-new on the build path).
    uint8_t *raw = new (std::nothrow) uint8_t[off + 64];
    if (raw == nullptr) return N60_STATUS_OUT_OF_MEMORY;
    uint8_t *base = raw + ((64 - (reinterpret_cast<uintptr_t>(raw) & 63)) & 63);
    std::memset(base, 0, off);
    SnapHeader *h = reinterpret_cast<SnapHeader *>(base);
    h->abiVersion = N60_GRAPH_ABI_VERSION;
    h->epoch = epoch;
    h->sampleRate = d.sampleRate;
    h->maxBlockFrames = d.maxBlockFrames;
    h->inputChannels = d.inputChannels;
    h->outputChannels = d.outputChannels;
    h->stageCount = d.stageCount;
    h->stageTableOff = static_cast<uint32_t>(tableOff);
    h->rampFrames = rampFramesFor(d.sampleRate);
    h->rawPad = static_cast<uint32_t>(base - raw);
    h->parkFftSize = d.parkFftSize;
    h->parkRevision = d.parkRevision;
    h->parkCommand = d.parkCommand;
    h->firScheme = d.firScheme;

    // Pass 2: fill the stage table, parameters and initial state.
    for (uint32_t i = 0; i < d.stageCount; ++i) {
        n60_stage_desc s = d.stages[i];
        s.kind = canonKind(s.kind);
        StageRec &r = stages(h)[i];
        r.laneMask = s.laneMask;
        r.kind = s.kind;
        r.id = s.stageId;
        r.laneA = s.laneA;
        r.laneB = s.laneB;
        r.laneFirst = s.laneMask != 0 ? static_cast<uint32_t>(std::countr_zero(s.laneMask))
                                     : (s.laneA == N60_LANE_ALL ? 0u : s.laneA);
        r.laneCount = laneCountFor(s, d.outputChannels);
        r.paramCount = s.paramCount;
        r.paramsOff = static_cast<uint32_t>(plan[i].params);
        r.stateOff = static_cast<uint32_t>(plan[i].state);
        r.stateStride = static_cast<uint32_t>(stateStrideFor(s, d.sampleRate, d.firScheme));
        r.capacity = s.capacityFrames;
        r.coefOff = static_cast<uint32_t>(plan[i].coef);
        r.sharedOff = static_cast<uint32_t>(plan[i].shared);
        float *params = paramsOf(h, r);
        for (uint32_t k = 0; k < s.paramCount; ++k) params[k] = s.params[k];
        if (s.kind == N60_STAGE_DELAY) params[0] = std::floor(params[0] + 0.5f);
        r.applied = s.paramCount > 0 ? params[0] : 0.0f;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            uint8_t *st = laneState(h, r, l);
            switch (s.kind) {
                case N60_STAGE_METER_IN:
                case N60_STAGE_METER_OUT: {
                    MeterLane *m = new (st) MeterLane;
                    m->peakBits.store(0, std::memory_order_relaxed);
                    m->rmsBits.store(0, std::memory_order_relaxed);
                    m->overRange.store(0, std::memory_order_relaxed);
                    break;
                }
                case N60_STAGE_GAIN: {
                    GainLane *g = reinterpret_cast<GainLane *>(st);
                    g->cur = g->target = params[0];
                    break;
                }
                case N60_STAGE_DELAY: {
                    DelayLane *dl = reinterpret_cast<DelayLane *>(st);
                    dl->dCur = dl->dNew = static_cast<uint32_t>(params[0]);
                    dl->pending = -1;
                    break;
                }
                default: break;
            }
        }
        if (isDspKind(s.kind)) dspInit(h, r);
        if (isSystemKind(s.kind)) systemInit(h, r);
        if (isMatrixKind(s.kind)) matrixInit(h, r);
        if (isGeneratorKind(s.kind)) generatorInit(h, r);
        if (isCleanupKind(s.kind)) cleanupInit(h, r);
        if (isImageKind(s.kind)) imageInit(h, r);
        if (isLoudnessKind(s.kind)) loudnessInit(h, r);
        if (isMultibandKind(s.kind)) multibandInit(h, r);
        if (isRouteKind(s.kind)) routeInit(h, r);
        if (isMimoKind(s.kind)) mimoInit(h, r);
        if (s.kind == N60_STAGE_PEQ) {
            PeqSec *sec = reinterpret_cast<PeqSec *>(bytes(h) + r.coefOff);
            for (uint32_t k = 0; k < s.paramCount / 4; ++k) {
                const float *p = s.params + 4 * k;
                designPeqSection(p, k + 1 < s.paramCount / 4 ? p + 4 : nullptr, d.sampleRate, sec[k].cur);
                for (int j = 0; j < 4; ++j) sec[k].seen[j] = p[j];
                sec[k].form = (p[0] == 9.0f && k + 1 < s.paramCount / 4 && p[7] != 0.0f) ? 1u : 0u;
            }
        }
    }
    if (!deltaFinalize(h)) {  // ABI v30: the delta ring must hold each lane's latency plus a block
        freeSnapshot(h);
        return N60_STATUS_BAD_ARGUMENT;
    }
    *out = h;
    return N60_STATUS_OK;
}

void freeSnapshot(SnapHeader *snap) {
    if (snap == nullptr) return;
    uint8_t *raw = bytes(snap) - snap->rawPad;
    delete[] raw;
}

const StageRec *findStage(const SnapHeader *snap, uint32_t stageId) {
    const StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount; ++i) {
        if (table[i].id == stageId) return &table[i];
    }
    return nullptr;
}

n60_status validateParam(const SnapHeader *snap, const StageRec &r, uint32_t paramIndex, float value) {
    if (!std::isfinite(value)) return N60_STATUS_BAD_ARGUMENT;
    switch (r.kind) {
        case N60_STAGE_GAIN:
            return (paramIndex != 0 || value < -10000.0f || value > 10000.0f) ? N60_STATUS_BAD_ARGUMENT : N60_STATUS_OK;  // ABI v19: negative inverts polarity
        case N60_STAGE_DELAY:
            // A delta audition fixes each lane's alignment ring delay at build time, so a live delay edit would
            // misalign the subtraction: the change rebuilds the graph instead.
            for (uint32_t i = 0; i < snap->stageCount; ++i) {
                if (stages(snap)[i].kind == N60_STAGE_DELTA_CAPTURE) return N60_STATUS_UNSUPPORTED;
            }
            return (paramIndex != 0 || value < 0.0f || value > static_cast<float>(r.capacity))
                       ? N60_STATUS_BAD_ARGUMENT
                       : N60_STATUS_OK;
        case N60_STAGE_PEQ: {
            // Every section parameter is live. Ranges are chosen so that any combination of valid
            // values designs successfully (the realtime thread designs; it cannot report failure).
            if (paramIndex >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
            const double v = value;
            switch (paramIndex % 4) {
                case 0: return (v >= 0.0 && v <= 7.0 && v == std::floor(v)) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                case 1: return (v > 0.0 && v < snap->sampleRate * 0.5) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                case 2: return (v >= -24.0 && v <= 24.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
                default: return (v >= 0.01 && v <= 1000.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
            }
        }
        default:
            if (isSystemKind(r.kind)) return validateSystemParam(snap, r, paramIndex, value);
            if (isMatrixKind(r.kind)) return validateMatrixParam(snap, r, paramIndex, value);
            if (isGeneratorKind(r.kind)) return validateGeneratorParam(snap, r, paramIndex, value);
            if (isCleanupKind(r.kind)) return validateCleanupParam(snap, r, paramIndex, value);
            if (isImageKind(r.kind)) return validateImageParam(snap, r, paramIndex, value);
            if (isLoudnessKind(r.kind)) return validateLoudnessParam(snap, r, paramIndex, value);
            if (isMultibandKind(r.kind)) return validateMultibandParam(snap, r, paramIndex, value);
            if (isRouteKind(r.kind)) return validateRouteParam(snap, r, paramIndex, value);
            if (isMimoKind(r.kind)) return validateMimoParam(snap, r, paramIndex, value);
            return isDspKind(r.kind) ? validateDspParam(snap, r, paramIndex, value) : N60_STATUS_UNSUPPORTED;
    }
}

bool applyParam(SnapHeader *snap, uint32_t stageId, uint32_t paramIndex, float value, bool *latencyMayChange) N60_RT_NONBLOCKING {
    StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount; ++i) {
        StageRec &r = table[i];
        if (r.id != stageId) continue;
        if (validateParam(snap, r, paramIndex, value) != N60_STATUS_OK) return false;
        float *params = paramsOf(snap, r);
        params[paramIndex] = r.kind == N60_STAGE_DELAY ? std::floor(value + 0.5f) : value;
        // Only DELAY targets and protection look-ahead/oversampling feed the reported latency
        // (protection's latency inputs are not live, so DELAY is the only kind that changes it).
        if (latencyMayChange != nullptr && r.kind == N60_STAGE_DELAY) *latencyMayChange = true;
        return true;
    }
    return false;
}

// Frames of latency each lane has accumulated through the stages before `upTo` (stage count for the whole chain).
void snapshotLaneLatency(const SnapHeader *snap, uint32_t upTo, uint32_t *perLane) {
    for (uint32_t l = 0; l < N60_GRAPH_MAX_CHANNELS; ++l) perLane[l] = 0;
    const StageRec *table = stages(snap);
    for (uint32_t i = 0; i < snap->stageCount && i < upTo; ++i) {
        const StageRec &r = table[i];
        uint32_t frames = 0;
        if (r.kind == N60_STAGE_DELAY) {
            frames = static_cast<uint32_t>(reinterpret_cast<const float *>(bytes(snap) + r.paramsOff)[0]);
        } else if (isDspKind(r.kind)) {
            frames = dspLatency(snap, r);
        } else if (isSystemKind(r.kind)) {
            frames = systemLatency(snap, r);
        } else if (isMimoKind(r.kind)) {
            frames = mimoLatency(snap, r);
        } else if (isMatrixKind(r.kind)) {
            // N source lanes collapse onto two ear lanes: the ears carry the worst source latency.
            uint32_t worstSrc = 0;
            for (uint32_t l = 0; l < r.laneCount; ++l) worstSrc = std::max(worstSrc, perLane[laneOf(r, l)]);
            for (uint32_t l = 0; l < r.laneCount; ++l) perLane[laneOf(r, l)] = 0;
            perLane[r.laneA] = perLane[r.laneB] = worstSrc + matrixLatency(snap, r);
            continue;
        }
        if (frames == 0) continue;
        for (uint32_t l = 0; l < r.laneCount; ++l) perLane[laneOf(r, l)] += frames;
    }
}

uint32_t snapshotLatency(const SnapHeader *snap) N60_RT_NONBLOCKING {
    uint32_t perLane[N60_GRAPH_MAX_CHANNELS];
    snapshotLaneLatency(snap, snap->stageCount, perLane);
    uint32_t worst = 0;
    for (uint32_t l = 0; l < snap->outputChannels; ++l) worst = std::max(worst, perLane[l]);
    return worst;
}

bool readOverRange(SnapHeader *snap, uint32_t stageId, uint32_t lane, uint64_t *count) {
    const StageRec *r = findStage(snap, stageId);
    if (r == nullptr || (r->kind != N60_STAGE_METER_IN && r->kind != N60_STAGE_METER_OUT) ||
        lane < r->laneFirst || lane >= r->laneFirst + r->laneCount) {
        return false;
    }
    MeterLane *m = reinterpret_cast<MeterLane *>(laneState(snap, *r, lane - r->laneFirst));
    *count = m->overRange.exchange(0, std::memory_order_relaxed);
    return true;
}

bool readDynamics(SnapHeader *snap, uint32_t stageId, uint32_t lane, n60_dynamics_readback *out) {
    const StageRec *r = findStage(snap, stageId);
    if (r == nullptr) return false;
    if (r->kind == N60_STAGE_PROTECTION) return readProtectionDynamics(snap, *r, lane, out);
    if (r->kind == N60_STAGE_DEESS) return readDeEss(snap, *r, lane, out);
    return readDspDynamics(snap, *r, lane, out);
}

bool readMeter(SnapHeader *snap, uint32_t stageId, uint32_t lane, float *peak, float *rms) {
    const StageRec *r = findStage(snap, stageId);
    if (r == nullptr || (r->kind != N60_STAGE_METER_IN && r->kind != N60_STAGE_METER_OUT) ||
        lane < r->laneFirst || lane >= r->laneFirst + r->laneCount) {
        return false;
    }
    MeterLane *m = reinterpret_cast<MeterLane *>(laneState(snap, *r, lane - r->laneFirst));
    *peak = bitsFloat(m->peakBits.exchange(0, std::memory_order_relaxed));
    *rms = bitsFloat(m->rmsBits.load(std::memory_order_relaxed));
    return true;
}

namespace {

void runSanitise(float *buf, uint32_t frames, uint64_t &bad) {
    for (uint32_t i = 0; i < frames; ++i) {
        if (!(std::fabs(buf[i]) <= FLT_MAX)) {  // false for NaN and Inf
            buf[i] = 0.0f;
            ++bad;
        }
    }
}

void runMeter(MeterLane &m, const float *buf, uint32_t frames) {
    // E20 S3: peak, over-range count and the double-precision energy sum run four samples at a time. Peak and count are
    // exact whatever the order; the energy sum has a fixed grouping (two f64x2 accumulators, then the tail), the same in
    // the SIMD and scalar builds.
    using namespace simd;
    f32x4 pk = splat4(0.0f), cnt = splat4(0.0f);
    const f32x4 one = splat4(1.0f), zero = splat4(0.0f);
    f64x2 s0 = splat2(0.0), s1 = splat2(0.0);
    uint32_t i = 0;
    for (; i + 4 <= frames; i += 4) {
        const f32x4 v = load4(buf + i);
        const f32x4 a = abs(v);
        pk = maxGt(a, pk);
        cnt = add(cnt, selectGt(a, one, one, zero));  // false for NaN
        const f64x2 d0 = toDouble(lane(v, 0), lane(v, 1)), d1 = toDouble(lane(v, 2), lane(v, 3));
        s0 = fma(d0, d0, s0);
        s1 = fma(d1, d1, s1);
    }
    float peak = hmax(pk);
    uint64_t over = static_cast<uint64_t>(hsum(cnt));
    double sum = hsum(add(s0, s1));
    for (; i < frames; ++i) {
        const float a = std::fabs(buf[i]);
        peak = a > peak ? a : peak;
        over += a > 1.0f ? 1u : 0u;
        sum = std::fma(double(buf[i]), double(buf[i]), sum);
    }
    if (over != 0) m.overRange.fetch_add(over, std::memory_order_relaxed);
    const uint32_t pb = floatBits(peak);
    uint32_t seen = m.peakBits.load(std::memory_order_relaxed);
    while (pb > seen && !m.peakBits.compare_exchange_weak(seen, pb, std::memory_order_relaxed)) {
    }
    m.rmsBits.store(floatBits(static_cast<float>(std::sqrt(sum / frames))), std::memory_order_relaxed);
}

void runGain(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float target = paramsOf(h, r)[0];
    const bool retarget = target != r.applied;
    r.applied = target;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        GainLane &g = *reinterpret_cast<GainLane *>(laneState(h, r, l));
        if (retarget) {
            g.remaining = h->rampFrames;
            g.target = target;
            g.step = (target - g.cur) / static_cast<float>(h->rampFrames);
        }
        float *buf = lanes[r.laneFirst + l];
        uint32_t i = 0;
        const uint32_t n = std::min(g.remaining, frames);
        // Computed from the destination so the last ramp sample is exactly the target
        // and the ramp is monotone in float.
        for (; i < n; ++i) {
            --g.remaining;
            g.cur = g.target - g.step * static_cast<float>(g.remaining);
            buf[i] *= g.cur;
        }
        simd::scale(buf + i, frames - i, g.cur);
    }
}

void runMSEncode(float *a, float *b, uint32_t frames) {
    const simd::f32x4 half = simd::splat4(0.5f);
    uint32_t i = 0;
    for (; i + 4 <= frames; i += 4) {
        const simd::f32x4 l = simd::load4(a + i), r = simd::load4(b + i);
        simd::store4(a + i, simd::mul(half, simd::add(l, r)));
        simd::store4(b + i, simd::mul(half, simd::sub(l, r)));
    }
    for (; i < frames; ++i) {
        const float l = a[i], r = b[i];
        a[i] = 0.5f * (l + r);
        b[i] = 0.5f * (l - r);
    }
}

void runMSDecode(float *a, float *b, uint32_t frames) {
    uint32_t i = 0;
    for (; i + 4 <= frames; i += 4) {
        const simd::f32x4 m = simd::load4(a + i), s = simd::load4(b + i);
        simd::store4(a + i, simd::add(m, s));
        simd::store4(b + i, simd::sub(m, s));
    }
    for (; i < frames; ++i) {
        const float m = a[i], s = b[i];
        a[i] = m + s;
        b[i] = m - s;
    }
}

void runPeq(SnapHeader *h, const StageRec &r, float *const *lanes, uint32_t frames) {
    const uint32_t sections = r.paramCount / 4;
    PeqSec *sec = reinterpret_cast<PeqSec *>(bytes(h) + r.coefOff);
    const float *params = paramsOf(h, r);
    const uint32_t ramp = h->rampFrames;
    // A changed section is rendered twice: old coefficients, and new coefficients with state
    // continued from the old section. The two outputs are crossfaded over the ramp window and the
    // old one is dropped. An edit that lands during a crossfade starts the next one afterwards.
    for (uint32_t s = 0; s < sections; ++s) {
        const float *p = params + 4 * s;
        PeqSec &q = sec[s];
        const uint32_t form = (p[0] == 9.0f && s + 1 < sections && p[7] != 0.0f) ? 1u : 0u;  // a flip redesigns the numerator
        if (q.xfLeft != 0 || (form == q.form && p[0] == q.seen[0] && p[1] == q.seen[1] && p[2] == q.seen[2] && p[3] == q.seen[3])) continue;
        if (!designPeqSection(p, s + 1 < sections ? p + 4 : nullptr, h->sampleRate, q.nxt)) {
            for (int j = 0; j < 4; ++j) q.seen[j] = p[j];  // unreachable for validated values; keep the old design
            q.form = form;
            continue;
        }
        for (int j = 0; j < 4; ++j) q.seen[j] = p[j];
        q.form = form;
        q.xfLeft = ramp;
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            PeqLane &st = *reinterpret_cast<PeqLane *>(laneState(h, r, l));
            st.zn[s][0] = st.z[s][0];
            st.zn[s][1] = st.z[s][1];
        }
    }
    // E20 S3: lanes run two at a time in one f64x2 per state variable (lanes are independent, so each lane's arithmetic is
    // exactly what a single-lane run does). An odd last lane pairs with a copy of itself and only its own state is stored.
    // Every multiply-add is a fused fma in both the SIMD and scalar builds, so the two builds agree bit for bit.
    using simd::f64x2;
    for (uint32_t l = 0; l < r.laneCount; l += 2) {
        const bool two = l + 1 < r.laneCount;
        PeqLane &sa = *reinterpret_cast<PeqLane *>(laneState(h, r, l));
        PeqLane &sb = two ? *reinterpret_cast<PeqLane *>(laneState(h, r, l + 1)) : sa;
        float *bufA = lanes[r.laneFirst + l];
        float *bufB = two ? lanes[r.laneFirst + l + 1] : bufA;
        f64x2 z0[N60_PEQ_MAX_SECTIONS], z1[N60_PEQ_MAX_SECTIONS], n0[N60_PEQ_MAX_SECTIONS], n1[N60_PEQ_MAX_SECTIONS];
        uint32_t xf[N60_PEQ_MAX_SECTIONS];
        const double *live[N60_PEQ_MAX_SECTIONS];
        for (uint32_t s = 0; s < sections; ++s) {
            z0[s] = simd::pair(sa.z[s][0], sb.z[s][0]);
            z1[s] = simd::pair(sa.z[s][1], sb.z[s][1]);
            n0[s] = simd::pair(sa.zn[s][0], sb.zn[s][0]);
            n1[s] = simd::pair(sa.zn[s][1], sb.zn[s][1]);
            xf[s] = sec[s].xfLeft;
            live[s] = sec[s].cur;
        }
        for (uint32_t i = 0; i < frames; ++i) {
            f64x2 x = simd::toDouble(bufA[i], bufB[i]);
            for (uint32_t s = 0; s < sections; ++s) {  // transposed direct form II
                const double *c = live[s];
                const f64x2 b0 = simd::splat2(c[0]), b1 = simd::splat2(c[1]), b2 = simd::splat2(c[2]);
                const f64x2 na1 = simd::splat2(-c[3]), na2 = simd::splat2(-c[4]);
                f64x2 y = simd::fma(b0, x, z0[s]);
                z0[s] = simd::fma(na1, y, simd::fma(b1, x, z1[s]));
                z1[s] = simd::fma(na2, y, simd::mul(b2, x));
                if (xf[s] != 0) {
                    const double *n = sec[s].nxt;
                    const f64x2 yn = simd::fma(simd::splat2(n[0]), x, n0[s]);
                    n0[s] = simd::fma(simd::splat2(-n[3]), yn, simd::fma(simd::splat2(n[1]), x, n1[s]));
                    n1[s] = simd::fma(simd::splat2(-n[4]), yn, simd::mul(simd::splat2(n[2]), x));
                    const double w = static_cast<double>(ramp - xf[s] + 1) / static_cast<double>(ramp);
                    y = simd::fma(simd::splat2(w), simd::sub(yn, y), y);
                    if (--xf[s] == 0) {  // the incoming section takes over, state and all
                        z0[s] = n0[s];
                        z1[s] = n1[s];
                        live[s] = sec[s].nxt;
                    }
                }
                x = y;
            }
            bufA[i] = static_cast<float>(simd::lane(x, 0));
            if (two) bufB[i] = static_cast<float>(simd::lane(x, 1));
        }
        // Quiet tails: the caller runs under the flush-to-zero guard (platform/fpenv.hpp), no manual flush.
        for (uint32_t s = 0; s < sections; ++s) {
            sa.z[s][0] = simd::lane(z0[s], 0);
            sa.z[s][1] = simd::lane(z1[s], 0);
            sa.zn[s][0] = simd::lane(n0[s], 0);
            sa.zn[s][1] = simd::lane(n1[s], 0);
            if (two) {
                sb.z[s][0] = simd::lane(z0[s], 1);
                sb.z[s][1] = simd::lane(z1[s], 1);
                sb.zn[s][0] = simd::lane(n0[s], 1);
                sb.zn[s][1] = simd::lane(n1[s], 1);
            }
        }
    }
    for (uint32_t s = 0; s < sections; ++s) {
        PeqSec &q = sec[s];
        if (q.xfLeft == 0) continue;
        if (q.xfLeft <= frames) {
            std::memcpy(q.cur, q.nxt, sizeof q.cur);
            q.xfLeft = 0;
        } else {
            q.xfLeft -= frames;
        }
    }
}

void runDelay(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const uint32_t target = static_cast<uint32_t>(paramsOf(h, r)[0]);
    const uint32_t ramp = h->rampFrames;
    const uint32_t ringSize = r.capacity + 1;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        DelayLane &d = *reinterpret_cast<DelayLane *>(laneState(h, r, l));
        float *ring = reinterpret_cast<float *>(&d + 1);
        if (d.xfLeft == 0) {
            if (target != d.dCur) {
                d.dNew = target;
                d.xfLeft = ramp;
            }
        } else if (target == d.dNew) {
            d.pending = -1;
        } else {
            d.pending = static_cast<int32_t>(target);
        }
        float *buf = lanes[r.laneFirst + l];
        uint32_t wp = d.wp;
        for (uint32_t i = 0; i < frames; ++i) {
            ring[wp] = buf[i];
            int64_t oi = int64_t(wp) - d.dCur;
            if (oi < 0) oi += ringSize;
            float y = ring[oi];
            if (d.xfLeft != 0) {
                int64_t ni = int64_t(wp) - d.dNew;
                if (ni < 0) ni += ringSize;
                const float t = static_cast<float>(ramp - d.xfLeft + 1) / static_cast<float>(ramp);
                y += t * (ring[ni] - y);
                if (--d.xfLeft == 0) {
                    d.dCur = d.dNew;
                    if (d.pending >= 0 && static_cast<uint32_t>(d.pending) != d.dCur) {
                        d.dNew = static_cast<uint32_t>(d.pending);
                        d.xfLeft = ramp;
                    }
                    d.pending = -1;
                }
            }
            buf[i] = y;
            if (++wp == ringSize) wp = 0;
        }
        d.wp = wp;
    }
    r.applied = static_cast<float>(target);
}

}  // namespace

namespace {

enum class UpstreamKind { Stateless, Carry, Fir, Refuse };

// How a stage ahead of a lazily carried FIR is treated (E9 S2d, G9). Carry: plain-data state in the lanes, the
// coefficient block (PEQ) and the shared block, copied whole. Stateless: no audible state (the meters and taps are
// read-only observers). Fir: an upstream convolver, exact only if it was itself copied whole. Refuse: any other
// stateful kind (the denoiser's spectral state is too large to copy within a callback budget, the rest are not yet
// proven copyable); the FIR behind it is not carried in lockstep and warms in full.
UpstreamKind upstreamKindOf(uint32_t kind) {
    switch (kind) {
        case N60_STAGE_SANITISE:
        case N60_STAGE_METER_IN:
        case N60_STAGE_METER_OUT:
        case N60_STAGE_MS_ENCODE:
        case N60_STAGE_MS_DECODE:
        case N60_STAGE_ANALYSER_TAP_EQ:
        case N60_STAGE_ANALYSER_TAP_DYN: return UpstreamKind::Stateless;
        case N60_STAGE_GAIN:
        case N60_STAGE_PEQ:
        case N60_STAGE_COMPRESSOR:
        case N60_STAGE_EXPANDER:
        case N60_STAGE_DYN_EQ:
        case N60_STAGE_BASS_MGMT:
        case N60_STAGE_STEREO_CROSSOVER:
        case N60_STAGE_AMBIENT:
        case N60_STAGE_CLEANUP: return UpstreamKind::Carry;
        case N60_STAGE_FIR: return UpstreamKind::Fir;
        // Named as refused (E9 S5, G10): each keeps running state that is not proven copyable in lockstep (all-pass and
        // crossover histories, the gate and routing ramps, the generator and external processor, the image, loudness,
        // de-ess and multiband detectors), so a lazily carried FIR behind one warms in full. test_conv_rebuild covers
        // every kind below at the eight standard rates. Any new stateful kind must be added here deliberately.
        case N60_STAGE_SYMMETRY:
        case N60_STAGE_CROSSFEED:
        case N60_STAGE_CROSSTALK:
        case N60_STAGE_HEADPHONE:
        case N60_STAGE_PAUSE_GATE:
        case N60_STAGE_FRAC_DELAY:
        case N60_STAGE_ROUTE:
        case N60_STAGE_XOVER:
        case N60_STAGE_GENERATOR:
        case N60_STAGE_EXTERNAL:
        case N60_STAGE_IMAGE:
        case N60_STAGE_LOUDNESS:
        case N60_STAGE_DEESS:
        case N60_STAGE_MULTIBAND:
        case N60_STAGE_MIMO:
        default: return UpstreamKind::Refuse;
    }
}

// Bytes a carried stage copies: lanes, PEQ coefficients, and the shared block (its extent is the gap to the next
// stage's parameters, which is the aligned shared size the arena was planned with). 0 when the stages differ.
bool upstreamBytes(const SnapHeader *from, const SnapHeader *to, uint32_t j, size_t &lanes, size_t &coef, size_t &shared) {
    const StageRec &x = stages(const_cast<SnapHeader *>(from))[j];
    const StageRec &y = stages(const_cast<SnapHeader *>(to))[j];
    // The shared block holds coefficients designed for one rate, so a rate change refuses the carry.
    if (from->sampleRate != to->sampleRate || x.kind != y.kind || x.id != y.id || x.laneCount != y.laneCount || x.stateStride != y.stateStride ||
        x.paramCount != y.paramCount) {
        return false;
    }
    lanes = static_cast<size_t>(y.stateStride) * y.laneCount;
    coef = y.kind == N60_STAGE_PEQ ? sizeof(PeqSec) * (y.paramCount / kPeqParamsPerSection) : 0;
    shared = 0;
    // Fail closed: the shared extent is bounded by the next stage, which always exists for an upstream stage.
    if (j + 1 >= to->stageCount || j + 1 >= from->stageCount) return false;
    {
        const StageRec &ny = stages(const_cast<SnapHeader *>(to))[j + 1];
        const StageRec &nx = stages(const_cast<SnapHeader *>(from))[j + 1];
        if (ny.paramsOff < y.sharedOff || nx.paramsOff < x.sharedOff) return false;
        shared = ny.paramsOff - y.sharedOff;
        if (shared != nx.paramsOff - x.sharedOff) return false;
    }
    return true;
}

}  // namespace

bool upstreamStateCarriable(const SnapHeader *from, const SnapHeader *to, uint32_t i, uint64_t budget, bool unbudgeted,
                            uint32_t first, const uint8_t *firExact) N60_RT_NONBLOCKING {
    if (i > from->stageCount || i > to->stageCount) return false;
    uint64_t total = 0;
    for (uint32_t j = first; j < i; ++j) {
        const StageRec &y = stages(const_cast<SnapHeader *>(to))[j];
        switch (upstreamKindOf(y.kind)) {
            case UpstreamKind::Stateless: break;
            case UpstreamKind::Refuse: return false;
            case UpstreamKind::Fir:
                if (firExact == nullptr || firExact[j] == 0) return false;
                break;
            case UpstreamKind::Carry: {
                size_t lanes = 0, coef = 0, shared = 0;
                if (!upstreamBytes(from, to, j, lanes, coef, shared)) return false;
                total += lanes + coef + shared;
                break;
            }
        }
    }
    return unbudgeted || total <= budget;
}

uint32_t carryUpstreamState(SnapHeader *from, SnapHeader *to, uint32_t i, uint64_t *budget, uint32_t first) N60_RT_NONBLOCKING {
    if (i > from->stageCount || i > to->stageCount) return 0;
    const StageRec *a = stages(from);
    StageRec *b = stages(to);
    uint32_t copied = 0;
    uint64_t spent = 0;
    for (uint32_t j = first; j < i; ++j) {
        if (upstreamKindOf(b[j].kind) != UpstreamKind::Carry) continue;
        size_t lanes = 0, coef = 0, shared = 0;
        if (!upstreamBytes(from, to, j, lanes, coef, shared)) continue;
        const StageRec &x = a[j];
        StageRec &y = b[j];
        // Callers run upstreamStateCarriable with the same budget first; the parameters are identical (lockstep).
        // The gain-reduction atomics of dynamics lanes and the cleanup detector telemetry atomics are copied too (the pending maximum carries over, wanted); the
        // source is the realtime thread's own and a concurrent control-thread reset can at worst drop one reading.
        std::memcpy(bytes(to) + y.stateOff, bytes(from) + x.stateOff, lanes);
        spent += lanes;
        if (coef != 0) {
            std::memcpy(bytes(to) + y.coefOff, bytes(from) + x.coefOff, coef);
            spent += coef;
        }
        if (shared != 0) {
            std::memcpy(bytes(to) + y.sharedOff, bytes(from) + x.sharedOff, shared);
            spent += shared;
        }
        y.applied = x.applied;
        ++copied;
    }
    if (budget != nullptr) *budget -= std::min(*budget, spent);
    return copied;
}

namespace {

void runStage(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames, std::atomic<uint64_t> &sanitisedSamples) {
    switch (r.kind) {
        case N60_STAGE_SANITISE: {
            uint64_t bad = 0;
            for (uint32_t l = 0; l < r.laneCount; ++l) runSanitise(lanes[r.laneFirst + l], frames, bad);
            if (bad != 0) sanitisedSamples.fetch_add(bad, std::memory_order_relaxed);
            break;
        }
        case N60_STAGE_METER_IN:
        case N60_STAGE_METER_OUT:
            for (uint32_t l = 0; l < r.laneCount; ++l) {
                runMeter(*reinterpret_cast<MeterLane *>(laneState(h, r, l)), lanes[r.laneFirst + l], frames);
            }
            break;
        case N60_STAGE_GAIN: runGain(h, r, lanes, frames); break;
        case N60_STAGE_MS_ENCODE: runMSEncode(lanes[r.laneA], lanes[r.laneB], frames); break;
        case N60_STAGE_PEQ: runPeq(h, r, lanes, frames); break;
        case N60_STAGE_MS_DECODE: runMSDecode(lanes[r.laneA], lanes[r.laneB], frames); break;
        case N60_STAGE_DELAY: runDelay(h, r, lanes, frames); break;
        default:
            if (isSystemKind(r.kind)) {
                runSystem(h, r, lanes, frames);
            } else if (isMatrixKind(r.kind)) {
                runMatrix(h, r, lanes, frames);
            } else if (isGeneratorKind(r.kind)) {
                runGenerator(h, r, lanes, frames);
            } else if (isCleanupKind(r.kind)) {
                runCleanup(h, r, lanes, frames);
            } else if (isImageKind(r.kind)) {
                runImage(h, r, lanes, frames);
            } else if (isLoudnessKind(r.kind)) {
                runLoudness(h, r, lanes, frames);
            } else if (isMultibandKind(r.kind)) {
                runMultiband(h, r, lanes, frames);
            } else if (isRouteKind(r.kind)) {
                runRoute(h, r, lanes, frames);
            } else if (isMimoKind(r.kind)) {
                runMimo(h, r, lanes, frames);
            } else {
                runDsp(h, r, lanes, frames);
            }
            break;
    }
}

}  // namespace

#ifdef N60_GRAPH_PROFILE
// E20 S1: per-stage-kind timing for the benchmark harness. Compiled out of product builds (the symbols below do not
// exist there). Single audio thread only; the harness reads between runs.
namespace {
constexpr uint32_t kProfileKinds = 64;
n60_profile_entry gProfile[kProfileKinds];
}  // namespace
extern "C" void n60_profile_reset(void) { std::memset(gProfile, 0, sizeof gProfile); }
extern "C" uint32_t n60_profile_read(n60_profile_entry *out, uint32_t capacity) {
    uint32_t n = 0;
    for (uint32_t k = 0; k < kProfileKinds && n < capacity; ++k) {
        if (gProfile[k].calls == 0) continue;
        out[n] = gProfile[k];
        out[n].kind = k;
        ++n;
    }
    return n;
}
#endif

void runSnapshot(SnapHeader *h, float *const *lanes, uint32_t frames, std::atomic<uint64_t> &sanitisedSamples,
                 bool follower) N60_RT_NONBLOCKING {
    h->follower = follower ? 1u : 0u;
    StageRec *table = stages(h);
    for (uint32_t i = 0; i < h->stageCount; ++i) {
        StageRec &r = table[i];
#ifdef N60_GRAPH_PROFILE
        const auto t0 = n60::rtNow();
        runStage(h, r, lanes, frames, sanitisedSamples);
        const auto t1 = n60::rtNow();
        if (r.kind < kProfileKinds) {
            n60_profile_entry &e = gProfile[r.kind];
            e.ns += static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::nanoseconds>(t1 - t0).count());
            e.calls += 1;
            e.frames += frames;
            e.laneFrames += static_cast<uint64_t>(frames) * (r.laneCount != 0 ? r.laneCount : 1u);
        }
#else
        runStage(h, r, lanes, frames, sanitisedSamples);
#endif
    }
}

}  // namespace n60
