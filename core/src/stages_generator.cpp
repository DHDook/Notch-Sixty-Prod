// libn60core ABI v14 generator stage (E11 S7, design note 8): white noise, pink noise, band-limited pink noise,
// sine tone and FFT-length periodic pink noise as a graph source. Portable C++20, standard library plus the
// offline FFT of the measurement core; no Apple framework, no exceptions, no RTTI.
//
// Derivations. Pink and band-limited pink are built once, on the control thread, as a periodic table: bin
// magnitudes |X[k]| = f^-1/2 (power density 1/f, -3 dB per octave) with a second-order 10 Hz high-pass so no
// energy sits below the range a loudspeaker can reproduce, an optional zero-phase Butterworth band (order 4 per
// edge, so each edge is -3.01 dB at the stated frequency), seeded uniform random phases, inverse real FFT, then
// scaling to unit RMS. The magnitudes are exact, so the slope is exact at every rate. Continuous pink repeats
// after at least 2 s; the periodic type repeats after exactly the requested FFT length, so an analyser of that
// length sees a leakage-free line spectrum (Muller and Massarani style periodic noise). White noise is a PCG32
// stream (O'Neill, 2014) mapped to uniform [-1, 1) and scaled by sqrt(3) to unit RMS.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runGenerator:
//  - allocation: none. The noise table lives in the snapshot arena, built by generatorInit.
//  - synchronisation: none. The realtime thread owns the state once the snapshot is published; the two live
//    parameters (level, active) are plain floats the mailbox wrote at block start.
//  - latency: 0 frames.
//  - sample rate: any rate in [8 kHz, 768 kHz]; ramps are 100 ms, the auto-stop is in seconds.
//  - channels: any lane set. Every selected lane gets its own stream (white: own seed; table: own offset), so
//    lanes are uncorrelated. Other lanes are muted when the mute-others parameter is 1.
//  - reset: a new snapshot starts silent; a rising edge of "active" from silence restarts the stream from its
//    seed, the phase from zero and the auto-stop timer. There is no in-place reset otherwise.
//  - safety: the level is clamped to the ceiling parameter (never above -6 dBFS RMS), output is clamped to
//    +-1.0, a stage never plays longer than its auto-stop (at most 600 s), and every start and stop ramps.
#include "stages_generator.hpp"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>
#include <vector>

#include "measure/offline_fft.hpp"
#include "n60/measure.h"

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr size_t kAlign = 16;
constexpr uint32_t kParams = 11;
constexpr double kCeilingMaxDb = -6.0;
constexpr float kMaxAutoStopSeconds = 600.0f;
constexpr double kRampSeconds = 0.1;
constexpr uint32_t kChunk = 256;
constexpr double kSweepFadeSeconds = 0.05;
constexpr double kSweepMinSeconds = 0.5;
constexpr double kSweepMaxSeconds = 60.0;

enum Param : uint32_t {
    kType = 0,       // N60_GENERATOR_*
    kLevel = 1,      // dBFS RMS, live
    kCeiling = 2,    // dBFS RMS, -60..-6
    kFreq = 3,       // Hz, sine
    kLow = 4,        // Hz, band-limited
    kHigh = 5,       // Hz, band-limited
    kPeriod = 6,     // frames, periodic pink (power of two)
    kSeed = 7,       // 0..16777216
    kMuteOthers = 8, // 0/1
    kActive = 9,     // 0/1, live
    kAutoStop = 10   // seconds, (0, 600]
};

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }
bool isPow2(uint32_t v) { return v != 0 && (v & (v - 1)) == 0; }

struct GenShared {
    double mix;         // 0 = program audio, 1 = generator
    double gainCur;     // linear amplitude, ramped
    double gainTarget;
    double gainStep;
    uint64_t elapsed;   // frames played since the last start
    uint64_t autoStopFrames;
    uint32_t gainRemaining;
    uint32_t rampFrames;
    uint32_t tableLen;  // 0 when the type has no table
    uint32_t wasActive;
    uint32_t expired;
    uint32_t pad;
};

struct GenLane {
    uint64_t state;     // PCG32 state
    uint64_t inc;
    double phase;       // sine phase, radians
    uint32_t pos;       // table read position
    uint32_t pad;
};

// The synchronised sweep of the generator (ABI v16): the E11 ESS at 0 dBFS peak, so it is bit-identical to a direct call.
bool sweepParams(const float *p, double rate, n60_measure_ess_params &e) {
    e = n60_measure_ess_params{};
    e.sample_rate = rate;
    e.start_hz = p[kLow];
    e.end_hz = p[kHigh];
    e.duration_seconds = double(p[kPeriod]) / rate;
    e.level_dbfs = 0.0;
    e.fade_seconds = kSweepFadeSeconds;
    e.synchronised = 1;
    return p[kPeriod] <= 16777216.0f && e.duration_seconds >= kSweepMinSeconds && e.duration_seconds <= kSweepMaxSeconds;
}

uint32_t tableLengthFor(uint32_t type, const float *p, double rate) {
    if (type == N60_GENERATOR_SWEEP) {
        n60_measure_ess_params e;
        n60_measure_ess_info info{};
        if (!sweepParams(p, rate, e) || n60_measure_ess_describe(&e, &info) != N60_MEASURE_OK) return 0;
        return static_cast<uint32_t>(info.frame_count);
    }
    if (type == N60_GENERATOR_PERIODIC_PINK) return static_cast<uint32_t>(p[kPeriod]);
    if (type == N60_GENERATOR_PINK || type == N60_GENERATOR_BAND_PINK) {
        uint32_t n = 1u << 10;
        while (n < 2.0 * rate) n <<= 1;
        return n;
    }
    return 0;
}

uint32_t pcgNext(GenLane &g) {
    const uint64_t old = g.state;
    g.state = old * 6364136223846793005ULL + g.inc;
    const uint32_t xs = static_cast<uint32_t>(((old >> 18u) ^ old) >> 27u);
    const uint32_t rot = static_cast<uint32_t>(old >> 59u);
    return (xs >> rot) | (xs << ((-rot) & 31u));
}

void pcgSeed(GenLane &g, uint64_t seed, uint64_t stream) {
    g.state = 0;
    g.inc = (stream << 1u) | 1u;
    pcgNext(g);
    g.state += seed;
    pcgNext(g);
}

double targetAmp(const float *p) {
    const double db = std::min<double>(p[kLevel], std::min<double>(p[kCeiling], kCeilingMaxDb));
    const double rms = std::pow(10.0, db / 20.0);
    const uint32_t type = static_cast<uint32_t>(p[kType]);
    return (type == N60_GENERATOR_SINE || type == N60_GENERATOR_SWEEP) ? rms * std::sqrt(2.0) : rms;
}

void startStreams(SnapHeader *h, const StageRec &r, GenShared &S) {
    const float *p = paramsOf(h, r);
    const bool sweep = static_cast<uint32_t>(p[kType]) == N60_GENERATOR_SWEEP;
    for (uint32_t l = 0; l < r.laneCount; ++l) {
        GenLane &g = *reinterpret_cast<GenLane *>(laneState(h, r, l));
        pcgSeed(g, static_cast<uint64_t>(p[kSeed]), l);
        g.phase = 0.0;
        g.pos = S.tableLen != 0 && sweep ?  0u : S.tableLen != 0 ? static_cast<uint32_t>((uint64_t(l) * 0x9E3779B1u) & (S.tableLen - 1)) : 0u;
    }
    S.elapsed = 0;
    S.expired = 0;
}

}  // namespace

bool isGeneratorKind(uint32_t kind) { return kind == N60_STAGE_GENERATOR; }

n60_status validateGeneratorStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0) || s.kind != N60_STAGE_GENERATOR || s.capacityFrames != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.laneMask != 0) {
        if (outCh < 64 && (s.laneMask >> outCh) != 0) return N60_STATUS_BAD_ARGUMENT;
    } else if (s.laneA != N60_LANE_ALL && s.laneA >= outCh) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.params == nullptr || s.paramCount != kParams) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    if (!isInt(p[kType]) || p[kType] < 0.0f || p[kType] > static_cast<float>(N60_GENERATOR_SWEEP)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    const uint32_t type = static_cast<uint32_t>(p[kType]);
    if (!inR(p[kLevel], -120.0, 0.0) || !inR(p[kCeiling], -60.0, kCeilingMaxDb)) return N60_STATUS_BAD_ARGUMENT;
    if (type == N60_GENERATOR_SINE && !inR(p[kFreq], 1.0, 0.45 * rate)) return N60_STATUS_BAD_ARGUMENT;
    if (type == N60_GENERATOR_BAND_PINK &&
        !(inR(p[kLow], 10.0, 0.45 * rate) && inR(p[kHigh], 10.0, 0.45 * rate) && p[kHigh] >= 1.05f * p[kLow])) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (type == N60_GENERATOR_PERIODIC_PINK &&
        !(isInt(p[kPeriod]) && p[kPeriod] >= 256.0f && p[kPeriod] <= 1048576.0f && isPow2(static_cast<uint32_t>(p[kPeriod])))) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (type == N60_GENERATOR_SWEEP) {
        n60_measure_ess_params e;
        n60_measure_ess_info info{};
        if (!isInt(p[kPeriod]) || !inR(p[kLow], 1.0, 0.45 * rate) || !inR(p[kHigh], 1.0, 0.45 * rate) ||
            !(p[kHigh] > p[kLow]) || !sweepParams(p, rate, e) || n60_measure_ess_describe(&e, &info) != N60_MEASURE_OK) {
            return N60_STATUS_BAD_ARGUMENT;
        }
    }
    if (!isInt(p[kSeed]) || !inR(p[kSeed], 0.0, 16777216.0)) return N60_STATUS_BAD_ARGUMENT;
    if (p[kMuteOthers] != 0.0f && p[kMuteOthers] != 1.0f) return N60_STATUS_BAD_ARGUMENT;
    if (p[kActive] != 0.0f && p[kActive] != 1.0f) return N60_STATUS_BAD_ARGUMENT;
    if (!inR(p[kAutoStop], 0.001, kMaxAutoStopSeconds)) return N60_STATUS_BAD_ARGUMENT;
    return N60_STATUS_OK;
}

void generatorSizes(const n60_stage_desc &s, double rate, size_t &perLane, size_t &shared) {
    perLane = up(sizeof(GenLane));
    shared = up(sizeof(GenShared)) + up(sizeof(float) * size_t(tableLengthFor(static_cast<uint32_t>(s.params[kType]), s.params, rate)));
}

void generatorInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    uint8_t *sh = sharedState(h, r);
    GenShared &S = *reinterpret_cast<GenShared *>(sh);
    const uint32_t type = static_cast<uint32_t>(p[kType]);
    S.rampFrames = std::max<uint32_t>(1, static_cast<uint32_t>(std::lround(kRampSeconds * h->sampleRate)));
    S.autoStopFrames = static_cast<uint64_t>(std::llround(double(p[kAutoStop]) * h->sampleRate));
    S.gainCur = S.gainTarget = targetAmp(p);
    S.mix = 0.0;
    S.wasActive = 0;
    S.tableLen = tableLengthFor(type, p, h->sampleRate);

    if (type == N60_GENERATOR_SWEEP) {
        n60_measure_ess_params e;
        n60_measure_ess_info info{};
        float *table = reinterpret_cast<float *>(sh + up(sizeof(GenShared)));
        if (sweepParams(p, h->sampleRate, e)) n60_measure_ess_generate(&e, table, S.tableLen, &info);
    } else if (S.tableLen != 0) {
        const uint32_t n = S.tableLen;
        const double rate = h->sampleRate;
        const bool banded = type == N60_GENERATOR_BAND_PINK;
        std::vector<fft::offline::Cplx> spec(n / 2 + 1);
        GenLane rng;
        pcgSeed(rng, static_cast<uint64_t>(p[kSeed]), 0x7F4A7C15u);
        spec[0] = {0.0, 0.0};
        for (uint32_t k = 1; k <= n / 2; ++k) {
            const double f = rate * double(k) / double(n);
            double mag = 1.0 / std::sqrt(f);
            const double hp = 10.0 / f;
            mag /= std::sqrt(1.0 + hp * hp * hp * hp);  // second-order 10 Hz high-pass
            if (banded) {
                const double a = std::pow(p[kLow] / f, 8.0);   // order 4 per edge
                const double b = std::pow(f / p[kHigh], 8.0);
                mag /= std::sqrt((1.0 + a) * (1.0 + b));
            }
            if (k == n / 2) {
                spec[k] = {mag * ((pcgNext(rng) & 1u) ? 1.0 : -1.0), 0.0};  // Nyquist bin is real
            } else {
                const double ph = 2.0 * kPi * (double(pcgNext(rng)) / 4294967296.0);
                spec[k] = {mag * std::cos(ph), mag * std::sin(ph)};
            }
        }
        std::vector<double> x;
        float *table = reinterpret_cast<float *>(sh + up(sizeof(GenShared)));
        if (fft::offline::realInverse(spec, n, x)) {
            double e = 0.0;
            for (double v : x) e += v * v;
            const double scale = e > 0.0 ? 1.0 / std::sqrt(e / double(n)) : 0.0;
            for (uint32_t i = 0; i < n; ++i) table[i] = static_cast<float>(x[i] * scale);
        }
    }
    startStreams(h, r, S);
}

void runGenerator(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) {
    const float *p = paramsOf(h, r);
    uint8_t *sh = sharedState(h, r);
    GenShared &S = *reinterpret_cast<GenShared *>(sh);
    const float *table = reinterpret_cast<const float *>(sh + up(sizeof(GenShared)));
    const uint32_t type = static_cast<uint32_t>(p[kType]);
    const bool wantActive = p[kActive] != 0.0f;

    // Rising edge from silence: restart streams and the auto-stop timer.
    // A toggle inside the fade still re-arms the auto-stop timer; the streams reseed only once silent.
    if (wantActive && !S.wasActive) {
        if (S.mix <= 0.0) {
            startStreams(h, r, S);
        } else {
            S.expired = 0;
            S.elapsed = 0;
        }
    }
    S.wasActive = wantActive ? 1u : 0u;

    const double tgt = targetAmp(p);
    if (tgt != S.gainTarget) {
        S.gainTarget = tgt;
        S.gainRemaining = S.rampFrames;
        S.gainStep = (tgt - S.gainCur) / double(S.rampFrames);
    }
    if ((!wantActive || S.expired) && S.mix <= 0.0) return;  // silent: program audio passes, nothing to mute

    const bool muteOthers = p[kMuteOthers] != 0.0f;
    const double mixStep = 1.0 / double(S.rampFrames);
    const double w = 2.0 * kPi * double(p[kFreq]) / h->sampleRate;
    const float whiteScale = static_cast<float>(std::sqrt(3.0) / 2147483648.0);
    float mixv[kChunk];
    float gainv[kChunk];

    for (uint32_t done = 0; done < frames;) {
        const uint32_t n = std::min(kChunk, frames - done);
        for (uint32_t i = 0; i < n; ++i) {
            const bool on = wantActive && !S.expired;
            if (on) {
                if (S.elapsed >= S.autoStopFrames) {
                    S.expired = 1;
                } else {
                    ++S.elapsed;
                }
            }
            const bool up_ = wantActive && !S.expired;
            S.mix = up_ ? std::min(1.0, S.mix + mixStep) : std::max(0.0, S.mix - mixStep);
            if (S.gainRemaining != 0) {
                --S.gainRemaining;
                S.gainCur = S.gainTarget - S.gainStep * double(S.gainRemaining);
            }
            mixv[i] = static_cast<float>(S.mix);
            gainv[i] = static_cast<float>(S.gainCur);
        }
        for (uint32_t l = 0; l < r.laneCount; ++l) {
            GenLane &g = *reinterpret_cast<GenLane *>(laneState(h, r, l));
            float *buf = lanes[laneOf(r, l)] + done;
            for (uint32_t i = 0; i < n; ++i) {
                float s;
                switch (type) {
                    case N60_GENERATOR_WHITE:
                        s = static_cast<float>(static_cast<int32_t>(pcgNext(g))) * whiteScale;
                        break;
                    case N60_GENERATOR_SINE:
                        s = static_cast<float>(std::sin(g.phase));
                        g.phase += w;
                        if (g.phase >= 2.0 * kPi) g.phase -= 2.0 * kPi;
                        break;
                    case N60_GENERATOR_SWEEP:
                        s = g.pos < S.tableLen ? table[g.pos++] : 0.0f;
                        break;
                    default:
                        s = table[g.pos];
                        g.pos = (g.pos + 1) & (S.tableLen - 1);
                        break;
                }
                const float y = std::clamp(s * gainv[i], -1.0f, 1.0f);
                buf[i] = buf[i] * (1.0f - mixv[i]) + y * mixv[i];
            }
        }
        if (muteOthers) {
            for (uint32_t c = 0; c < h->outputChannels; ++c) {
                bool selected = false;
                for (uint32_t l = 0; l < r.laneCount && !selected; ++l) selected = laneOf(r, l) == c;
                if (selected) continue;
                float *buf = lanes[c] + done;
                for (uint32_t i = 0; i < n; ++i) buf[i] *= 1.0f - mixv[i];
            }
        }
        done += n;
    }
}

n60_status validateGeneratorParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) {
    (void)h;
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    switch (idx) {
        case kLevel: return inR(value, -120.0, 0.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kActive: return (value == 0.0f || value == 1.0f) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        default: return N60_STATUS_UNSUPPORTED;
    }
}

}  // namespace n60
