// libn60core ABI v22 cleanup stage (E6 S12a): the stereo kernel's pre-EQ block as one pair stage. It runs, per
// frame, the DC offset filter, the infrasonic high-pass cascade, the mains hum detector tap and the mains notch
// bank, in that order, exactly as N60DynamicsProcessPreEQStereoFrame does, with the same float and double
// arithmetic so the output matches the kernel to rounding.
//
// Derivations (public specifications):
//  - DC offset: first-order DC blocker y[n] = x[n] - x[n-1] + p y[n-1], p = exp(-2 pi 0.5 / fs) (0.5 Hz corner;
//    Smith, "Introduction to Digital Filters", DC blocker).
//  - Infrasonic: Butterworth high-pass of order 4, 8 or 16 as 2, 4 or 8 biquad sections; section k has
//    Q = 1 / (2 cos((2k + 1) pi / (2 N))) (Butterworth pole angles); each section is the RBJ Audio EQ Cookbook
//    high-pass (Bristow-Johnson), coefficients normalised in double and rounded to float, processed in
//    transposed direct form II in float.
//  - Mains notch: RBJ peaking cut per harmonic (depth dB, Q 5..60) kept in double throughout (50/60 Hz at 384 kHz
//    is a very low normalised frequency where float coefficients lose notch depth); a retune (fundamental, Q,
//    harmonic count or any depth changed) runs the old and the new bank side by side and crossfades linearly over
//    max(32, decimation * 10) frames, about 10 ms.
//  - Detector: a bank of 25 complex oscillators 0.25 Hz apart across +-3 Hz of the search centre, correlated
//    against the mono mix decimated to about 1 kHz over a 1 s window (a sliding Goertzel/DFT bin bank); the peak
//    bin is refined by parabolic interpolation, confidence = prominence x tone energy fraction, forced to 0 below
//    -78 dBFS.
//
// Realtime documentation (docs/REALTIME_RULES.md), for runCleanup:
//  - allocation: none. All state is in the snapshot arena (one shared record), built off the audio thread.
//  - synchronisation: none. Once published, the realtime thread owns the state; every parameter is a live plain
//    float the mailbox wrote at block start. The detector result is two relaxed atomics read by the control thread.
//  - latency: 0 frames.
//  - sample rate: 8 kHz to 768 kHz. At a block start a changed parameter redesigns its coefficients (at most 8
//    biquads, 16 notches, 25 oscillator steps: bounded libm, no allocation).
//  - channels: a stereo pair (laneA, laneB), as the kernel, or one lane (laneA == laneB, ABI v29: the centre lane of an
//    N-channel layout). A single lane runs both channel states on the same input, so its output equals the pair's left.
//  - reset: a new snapshot starts parked and neutral; enabling a part from parked clears its state and starts its
//    5 ms bypass mix at 0, as the kernel does. State is not carried across a rebuild (ledger).
#include "stages_cleanup.hpp"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

namespace n60 {
namespace {

constexpr double kPi = 3.14159265358979323846264338327950288;
constexpr size_t kAlign = 16;
constexpr uint32_t kMaxInfra = 8;
constexpr uint32_t kMaxHarm = 16;
constexpr uint32_t kBins = 25;
constexpr uint32_t kParams = 10 + kMaxHarm;
constexpr double kDcCutoffHz = 0.5;
constexpr double kDetTargetRate = 1000.0;
constexpr double kDetWindowSeconds = 1.0;
constexpr double kDetSpanHz = 3.0;
constexpr double kDetBinSpacingHz = 0.25;
constexpr double kDetMinLevelDbfs = -78.0;
constexpr double kRetuneSeconds = 0.010;
constexpr float kParkEps = 1.0e-5f;

enum Param : uint32_t {
    kDc = 0,          // 0/1
    kInfraOn = 1,     // 0/1
    kInfraHz = 2,     // 10..30
    kInfraSlope = 3,  // 0 = 24, 1 = 48, 2 = 96 dB/oct
    kMainsOn = 4,     // 0/1
    kMainsHz = 5,     // 40..70
    kMainsCount = 6,  // 1..16
    kMainsQ = 7,      // 5..60
    kDetOn = 8,       // 0/1
    kDetCenter = 9,   // 47..63
    kDepth0 = 10      // kMaxHarm depths, -40..0 dB
};

size_t up(size_t v) { return (v + (kAlign - 1)) & ~(kAlign - 1); }
bool inR(double v, double lo, double hi) { return std::isfinite(v) && v >= lo && v <= hi; }
bool isInt(float v) { return std::isfinite(v) && v == std::floor(v); }
bool isFlag(float v) { return v == 0.0f || v == 1.0f; }

struct Nc {
    double b0, b1, b2, a1, a2;
};
struct NState {
    double z1, z2;
};

struct NotchBank {
    double fundamental;
    float q;
    uint32_t count;
    float depths[kMaxHarm];
    Nc coef[kMaxHarm];
};

struct CleanShared {
    // fixed per snapshot
    float bypassCoef;
    double dcPole;
    uint32_t decimation;
    uint32_t windowSamples;
    uint32_t retuneFrames;
    double detRate;
    // dc
    float dcMix;
    double dcPrevInL, dcPrevInR, dcPrevOutL, dcPrevOutR;  // double state: the pole sits near 1 at high rates (G9)
    // infrasonic
    float infraMix;
    float infraSeenHz;
    float infraSeenSlope;
    uint32_t infraSections;
    Nc infra[kMaxInfra];  // double coefficients and state: a 10 Hz corner at 384 kHz puts the poles within 1e-4 of 1 (G9)
    NState infraL[kMaxInfra];
    NState infraR[kMaxInfra];
    // mains notch
    float mainsMix;
    uint32_t transTotal, transRemaining;
    uint32_t notchInit;
    NotchBank want;      // designed from the live parameters
    NotchBank cur, pend;
    NState curL[kMaxHarm], curR[kMaxHarm], pendL[kMaxHarm], pendR[kMaxHarm];
    // detector
    float detSeenCenter;
    uint32_t detCounter, detCount;
    double detCos[kBins], detSin[kBins], detRe[kBins], detIm[kBins];
    double detEnergy;
    float stepCos[kBins], stepSin[kBins];
    double searchStart;
    // parking
    uint32_t dcParked, infraParked, mainsParked, detParked, preParked;
    // telemetry (control thread reads)
    std::atomic<uint32_t> detFreqBits;
    std::atomic<uint32_t> detConfBits;
};

float smoothToward(float current, float target, float coef) { return target + coef * (current - target); }
bool nearZero(float v) { return std::fabs(v) <= kParkEps; }

Nc identityNc() { return Nc{1.0, 0.0, 0.0, 0.0, 0.0}; }

// RBJ high-pass, normalised in double, stored as double (the kernel's N60BiquadDesign with N60BiquadFilterTypeHighPass).
bool designHighPass(double rate, double f, double q, Nc &out) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !std::isfinite(q) || q <= 0.0) return false;
    const double omega = 2.0 * kPi * f / rate;
    const double cosOmega = std::cos(omega);
    const double alpha = std::sin(omega) / (2.0 * q);
    const double b0 = (1.0 + cosOmega) * 0.5;
    const double b1 = -(1.0 + cosOmega);
    const double b2 = (1.0 + cosOmega) * 0.5;
    const double a0 = 1.0 + alpha;
    const double a1 = -2.0 * cosOmega;
    const double a2 = 1.0 - alpha;
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const Nc c{b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0};
    if (!std::isfinite(c.b0) || !std::isfinite(c.b1) || !std::isfinite(c.b2) || !std::isfinite(c.a1) || !std::isfinite(c.a2)) {
        return false;
    }
    out = c;
    return true;
}

void designInfra(CleanShared &S, double rate, float hz, float slope) {
    const uint32_t sections = slope < 0.5f ? 2u : (slope < 1.5f ? 4u : 8u);
    const uint32_t order = sections * 2;
    for (uint32_t i = 0; i < kMaxInfra; ++i) S.infra[i] = identityNc();
    for (uint32_t i = 0; i < sections; ++i) {
        const double angle = ((2.0 * double(i) + 1.0) * kPi) / (2.0 * double(order));
        const double q = 1.0 / (2.0 * std::cos(angle));
        if (!designHighPass(rate, double(hz), q, S.infra[i])) S.infra[i] = identityNc();
    }
    S.infraSections = sections;
    S.infraSeenHz = hz;
    S.infraSeenSlope = slope;
}

// RBJ peaking cut in double (the kernel's design_mains_notch).
bool designNotch(double rate, double f, double depthDb, double q, Nc &out) {
    if (!std::isfinite(f) || f <= 0.0 || f >= rate * 0.5 || !inR(depthDb, -40.0, 0.0) || !inR(q, 5.0, 60.0)) return false;
    const double omega = 2.0 * kPi * f / rate;
    const double alpha = std::sin(omega) / (2.0 * q);
    const double A = std::pow(10.0, depthDb / 40.0);
    const double cosOmega = std::cos(omega);
    const double a0 = 1.0 + alpha / A;
    if (!std::isfinite(a0) || std::fabs(a0) < 1.0e-20) return false;
    const Nc d{(1.0 + alpha * A) / a0, (-2.0 * cosOmega) / a0, (1.0 - alpha * A) / a0, (-2.0 * cosOmega) / a0,
               (1.0 - alpha / A) / a0};
    if (!std::isfinite(d.b0) || !std::isfinite(d.b1) || !std::isfinite(d.b2) || !std::isfinite(d.a1) || !std::isfinite(d.a2)) {
        return false;
    }
    out = d;
    return true;
}

bool sameBankParams(const NotchBank &b, const float *p) {
    if (b.fundamental != double(p[kMainsHz]) || b.q != p[kMainsQ] || b.count != static_cast<uint32_t>(p[kMainsCount])) return false;
    for (uint32_t i = 0; i < kMaxHarm; ++i) {
        if (b.depths[i] != (i < b.count ? p[kDepth0 + i] : 0.0f)) return false;
    }
    return true;
}

void designBank(NotchBank &b, double rate, const float *p) {
    b.fundamental = double(p[kMainsHz]);
    b.q = p[kMainsQ];
    b.count = static_cast<uint32_t>(p[kMainsCount]);
    for (uint32_t i = 0; i < kMaxHarm; ++i) {
        b.depths[i] = 0.0f;
        b.coef[i] = identityNc();
    }
    for (uint32_t i = 0; i < b.count; ++i) {
        const float depth = p[kDepth0 + i];
        b.depths[i] = depth;
        const double harmonicHz = b.fundamental * double(i + 1u);
        if (harmonicHz >= rate * 0.45 || std::fabs(depth) < 1.0e-6f) continue;
        if (!designNotch(rate, harmonicHz, depth, double(b.q), b.coef[i])) b.coef[i] = identityNc();
    }
}

float runNotches(const Nc *c, NState *st, uint32_t n, float x) {
    double out = double(x);
    for (uint32_t i = 0; i < n; ++i) {
        const Nc k = c[i];
        const double next = k.b0 * out + st[i].z1;
        st[i].z1 = k.b1 * out - k.a1 * next + st[i].z2;
        st[i].z2 = k.b2 * out - k.a2 * next;
        out = next;
    }
    return static_cast<float>(out);
}

void resetDetectorWindow(CleanShared &S) {
    S.detCount = 0;
    S.detEnergy = 0.0;
    for (uint32_t i = 0; i < kBins; ++i) {
        S.detCos[i] = 1.0;
        S.detSin[i] = 0.0;
        S.detRe[i] = 0.0;
        S.detIm[i] = 0.0;
    }
}

void designDetector(CleanShared &S, double rate, float center) {
    S.searchStart = double(center) - kDetSpanHz;
    for (uint32_t i = 0; i < kBins; ++i) {
        const double f = S.searchStart + double(i) * kDetBinSpacingHz;
        const double step = 2.0 * kPi * f / S.detRate;
        S.stepCos[i] = static_cast<float>(std::cos(step));
        S.stepSin[i] = static_cast<float>(std::sin(step));
    }
    S.detSeenCenter = center;
    (void)rate;
}

void detectorFrame(CleanShared &S, bool enabled, float left, float right) {
    if (!enabled) {
        if (!S.detParked) {
            resetDetectorWindow(S);
            S.detFreqBits.store(0, std::memory_order_relaxed);
            S.detConfBits.store(0, std::memory_order_relaxed);
            S.detCounter = 0;
            S.detParked = 1;
        }
        return;
    }
    if (S.detParked) {
        resetDetectorWindow(S);
        S.detCounter = 0;
        S.detParked = 0;
    }
    S.detCounter += 1;
    if (S.detCounter < S.decimation) return;
    S.detCounter = 0;

    const double mono = 0.5 * (double(left) + double(right));
    S.detEnergy += mono * mono;
    for (uint32_t i = 0; i < kBins; ++i) {
        const double oc = S.detCos[i];
        const double os = S.detSin[i];
        S.detRe[i] += mono * oc;
        S.detIm[i] += mono * os;
        const double sc = double(S.stepCos[i]);
        const double ss = double(S.stepSin[i]);
        S.detCos[i] = oc * sc - os * ss;
        S.detSin[i] = os * sc + oc * ss;
    }
    S.detCount += 1;
    if (S.detCount < S.windowSamples) return;

    double powers[kBins];
    uint32_t best = 0;
    double bestPower = 0.0;
    for (uint32_t i = 0; i < kBins; ++i) {
        powers[i] = S.detRe[i] * S.detRe[i] + S.detIm[i] * S.detIm[i];
        if (powers[i] > bestPower) {
            bestPower = powers[i];
            best = i;
        }
    }
    double background = 0.0;
    uint32_t backgroundCount = 0;
    for (uint32_t i = 0; i < kBins; ++i) {
        const int distance = int(i) - int(best);
        if (distance >= -2 && distance <= 2) continue;
        background += powers[i];
        backgroundCount += 1;
    }
    const double backgroundMean = backgroundCount > 0 ? background / double(backgroundCount) : 0.0;
    const double n = double(S.detCount);
    const double candidateMeanSquare = 2.0 * bestPower / std::fmax(n * n, 1.0);
    const double totalMeanSquare = S.detEnergy / std::fmax(n, 1.0);
    const double levelDbfs = 10.0 * std::log10(std::fmax(candidateMeanSquare, 1.0e-20));
    double prominence = bestPower > 1.0e-20 ? 1.0 - backgroundMean / bestPower : 0.0;
    prominence = std::fmin(std::fmax(prominence, 0.0), 1.0);
    double tone = candidateMeanSquare / std::fmax(totalMeanSquare, 1.0e-20);
    tone = std::fmin(std::fmax(tone, 0.0), 1.0);
    double confidence = prominence * tone;
    if (levelDbfs < kDetMinLevelDbfs) confidence = 0.0;

    double fractional = 0.0;
    if (best > 0 && best + 1 < kBins) {
        const double lp = powers[best - 1];
        const double cp = powers[best];
        const double rp = powers[best + 1];
        const double denominator = lp - 2.0 * cp + rp;
        if (std::fabs(denominator) > 1.0e-20) {
            fractional = 0.5 * (lp - rp) / denominator;
            fractional = std::fmin(std::fmax(fractional, -0.5), 0.5);
        }
    }
    const float freq = static_cast<float>(S.searchStart + (double(best) + fractional) * kDetBinSpacingHz);
    S.detFreqBits.store(floatToBits(freq), std::memory_order_relaxed);
    S.detConfBits.store(floatToBits(static_cast<float>(confidence)), std::memory_order_relaxed);
    resetDetectorWindow(S);
}

void promotePending(CleanShared &S) {
    S.cur = S.pend;
    std::memcpy(S.curL, S.pendL, sizeof S.curL);
    std::memcpy(S.curR, S.pendR, sizeof S.curR);
    S.transTotal = 0;
    S.transRemaining = 0;
}

void scheduleRetune(CleanShared &S) {
    if (!S.notchInit) {
        S.cur = S.want;
        std::memset(S.curL, 0, sizeof S.curL);
        std::memset(S.curR, 0, sizeof S.curR);
        S.notchInit = 1;
        return;
    }
    if (S.transRemaining > 0) promotePending(S);
    const NotchBank &w = S.want;
    bool same = S.cur.fundamental == w.fundamental && S.cur.q == w.q && S.cur.count == w.count;
    for (uint32_t i = 0; same && i < kMaxHarm; ++i) same = S.cur.depths[i] == w.depths[i];
    if (same) return;
    S.pend = w;
    std::memcpy(S.pendL, S.curL, sizeof S.pendL);
    std::memcpy(S.pendR, S.curR, sizeof S.pendR);
    S.transTotal = S.retuneFrames > 0 ? S.retuneFrames : 1u;
    S.transRemaining = S.transTotal;
}

bool preNeutral(const CleanShared &S) {
    return nearZero(S.dcMix) && nearZero(S.infraMix) && nearZero(S.mainsMix) && S.transRemaining == 0u;
}

void parkPre(CleanShared &S) {
    S.dcMix = 0.0f;
    S.infraMix = 0.0f;
    S.mainsMix = 0.0f;
    S.transTotal = 0;
    S.transRemaining = 0;
    S.dcParked = S.infraParked = S.mainsParked = S.preParked = 1;
}

void activatePre(CleanShared &S) {
    if (!S.preParked) return;
    S.dcPrevInL = S.dcPrevInR = S.dcPrevOutL = S.dcPrevOutR = 0.0;
    std::memset(S.infraL, 0, sizeof S.infraL);
    std::memset(S.infraR, 0, sizeof S.infraR);
    std::memset(S.curL, 0, sizeof S.curL);
    std::memset(S.curR, 0, sizeof S.curR);
    std::memset(S.pendL, 0, sizeof S.pendL);
    std::memset(S.pendR, 0, sizeof S.pendR);
    S.notchInit = 0;
    S.preParked = 0;
}

}  // namespace

bool isCleanupKind(uint32_t kind) N60_RT_NONBLOCKING { return kind == N60_STAGE_CLEANUP; }

n60_status validateCleanupStage(const n60_stage_desc &s, double rate, uint32_t outCh) {
    if (!(rate >= 8000.0 && rate <= 768000.0) || s.kind != N60_STAGE_CLEANUP || s.capacityFrames != 0) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    if (s.laneMask != 0 || s.laneA >= outCh || s.laneB >= outCh) return N60_STATUS_BAD_ARGUMENT;
    if (s.params == nullptr || s.paramCount != kParams) return N60_STATUS_BAD_ARGUMENT;
    const float *p = s.params;
    if (!isFlag(p[kDc]) || !isFlag(p[kInfraOn]) || !isFlag(p[kMainsOn]) || !isFlag(p[kDetOn])) return N60_STATUS_BAD_ARGUMENT;
    if (!inR(p[kInfraHz], 10.0, 30.0) || double(p[kInfraHz]) >= rate * 0.45) return N60_STATUS_BAD_ARGUMENT;
    if (!isInt(p[kInfraSlope]) || p[kInfraSlope] < 0.0f || p[kInfraSlope] > 2.0f) return N60_STATUS_BAD_ARGUMENT;
    if (!inR(p[kMainsHz], 40.0, 70.0) || !isInt(p[kMainsCount]) || p[kMainsCount] < 1.0f || p[kMainsCount] > float(kMaxHarm) ||
        !inR(p[kMainsQ], 5.0, 60.0) || !inR(p[kDetCenter], 47.0, 63.0)) {
        return N60_STATUS_BAD_ARGUMENT;
    }
    for (uint32_t i = 0; i < kMaxHarm; ++i) {
        if (!inR(p[kDepth0 + i], -40.0, 0.0)) return N60_STATUS_BAD_ARGUMENT;
    }
    return N60_STATUS_OK;
}

void cleanupSizes(const n60_stage_desc &, double, size_t &perLane, size_t &shared) {
    perLane = 0;
    shared = up(sizeof(CleanShared));
}

void cleanupInit(SnapHeader *h, const StageRec &r) {
    const float *p = paramsOf(h, r);
    CleanShared &S = *new (sharedState(h, r)) CleanShared{};
    const double rate = h->sampleRate;
    S.bypassCoef = static_cast<float>(std::exp(-1.0 / (rate * (5.0 / 1000.0))));
    S.dcPole = std::exp(-2.0 * kPi * kDcCutoffHz / rate);
    long dec = std::llround(rate / kDetTargetRate);
    if (dec < 1) dec = 1;
    S.decimation = static_cast<uint32_t>(dec);
    S.detRate = rate / double(S.decimation);
    long win = std::llround(S.detRate * kDetWindowSeconds);
    if (win < 128) win = 128;
    S.windowSamples = static_cast<uint32_t>(win);
    S.retuneFrames = static_cast<uint32_t>(std::fmax(32.0, double(S.decimation) * kDetTargetRate * kRetuneSeconds));
    designInfra(S, rate, p[kInfraHz], p[kInfraSlope]);
    designBank(S.want, rate, p);
    designDetector(S, rate, p[kDetCenter]);
    resetDetectorWindow(S);
    S.dcParked = S.infraParked = S.mainsParked = S.detParked = S.preParked = 1;
    S.detFreqBits.store(0, std::memory_order_relaxed);
    S.detConfBits.store(0, std::memory_order_relaxed);
}

uint64_t cleanupCarry(SnapHeader *from, SnapHeader *to) N60_RT_NONBLOCKING {
    uint64_t bytes = 0;
    if (from == nullptr || to == nullptr) return bytes;
    const StageRec *src = stages(from);
    StageRec *dst = stages(to);
    for (uint32_t i = 0; i < to->stageCount; ++i) {
        if (dst[i].kind != N60_STAGE_CLEANUP) continue;
        for (uint32_t j = 0; j < from->stageCount; ++j) {
            if (src[j].kind != N60_STAGE_CLEANUP || src[j].id != dst[i].id) continue;
            if (from->sampleRate != to->sampleRate) break;
            const CleanShared &a = *reinterpret_cast<const CleanShared *>(sharedState(from, src[j]));
            CleanShared &b = *reinterpret_cast<CleanShared *>(sharedState(to, dst[i]));
            bytes += sizeof(CleanShared);  // G38: the caller charges the copy to the callback budget
            b.dcMix = a.dcMix;
            b.dcPrevInL = a.dcPrevInL; b.dcPrevInR = a.dcPrevInR;
            b.dcPrevOutL = a.dcPrevOutL; b.dcPrevOutR = a.dcPrevOutR;
            b.dcParked = a.dcParked;
            b.infraMix = a.infraMix;
            b.infraParked = a.infraParked;
            // Section states carry for the sections both designs have; extra sections start silent.
            const uint32_t sections = std::min(a.infraSections, b.infraSections);
            for (uint32_t k = 0; k < sections; ++k) {
                b.infraL[k] = a.infraL[k];
                b.infraR[k] = a.infraR[k];
            }
            b.mainsMix = a.mainsMix;
            b.transTotal = a.transTotal;
            b.transRemaining = a.transRemaining;
            b.notchInit = a.notchInit;
            b.cur = a.cur;
            b.pend = a.pend;
            std::memcpy(b.curL, a.curL, sizeof b.curL);
            std::memcpy(b.curR, a.curR, sizeof b.curR);
            std::memcpy(b.pendL, a.pendL, sizeof b.pendL);
            std::memcpy(b.pendR, a.pendR, sizeof b.pendR);
            b.mainsParked = a.mainsParked;
            b.preParked = a.preParked;
            // The detector window is only meaningful for the same search grid.
            if (a.detSeenCenter == b.detSeenCenter) {
                b.detCounter = a.detCounter;
                b.detCount = a.detCount;
                std::memcpy(b.detCos, a.detCos, sizeof b.detCos);
                std::memcpy(b.detSin, a.detSin, sizeof b.detSin);
                std::memcpy(b.detRe, a.detRe, sizeof b.detRe);
                std::memcpy(b.detIm, a.detIm, sizeof b.detIm);
                b.detEnergy = a.detEnergy;
                b.detParked = a.detParked;
                b.detFreqBits.store(a.detFreqBits.load(std::memory_order_relaxed), std::memory_order_relaxed);
                b.detConfBits.store(a.detConfBits.load(std::memory_order_relaxed), std::memory_order_relaxed);
            }
            break;
        }
    }
    return bytes;
}

void runCleanup(SnapHeader *h, StageRec &r, float *const *lanes, uint32_t frames) N60_RT_NONBLOCKING {
    const float *p = paramsOf(h, r);
    CleanShared &S = *reinterpret_cast<CleanShared *>(sharedState(h, r));
    const double rate = h->sampleRate;
    const bool dcOn = p[kDc] > 0.5f;
    const bool infraOn = p[kInfraOn] > 0.5f;
    const bool mainsOn = p[kMainsOn] > 0.5f;
    const bool detOn = p[kDetOn] > 0.5f;

    if (p[kInfraHz] != S.infraSeenHz || p[kInfraSlope] != S.infraSeenSlope) designInfra(S, rate, p[kInfraHz], p[kInfraSlope]);
    if (p[kDetCenter] != S.detSeenCenter) designDetector(S, rate, p[kDetCenter]);
    if (!sameBankParams(S.want, p)) designBank(S.want, rate, p);

    float *L = lanes[r.laneA];
    float *R = lanes[r.laneB];
    const float bypass = S.bypassCoef;
    for (uint32_t i = 0; i < frames; ++i) {
        float left = L[i];
        float right = R[i];

        // G14: a non-finite sample would poison every recursive state (and the next snapshot's carry), so it clears
        // them and outputs silence for that sample.
        if (!std::isfinite(left) || !std::isfinite(right)) {
            S.dcPrevInL = S.dcPrevInR = S.dcPrevOutL = S.dcPrevOutR = 0.0;
            for (uint32_t k = 0; k < kMaxInfra; ++k) { S.infraL[k] = NState{}; S.infraR[k] = NState{}; }
            for (uint32_t k = 0; k < kMaxHarm; ++k) {
                S.curL[k] = NState{}; S.curR[k] = NState{}; S.pendL[k] = NState{}; S.pendR[k] = NState{};
            }
            resetDetectorWindow(S);
            L[i] = 0.0f;
            R[i] = 0.0f;
            continue;
        }

        if (!dcOn && !infraOn && !mainsOn) {
            if (!S.preParked && preNeutral(S)) parkPre(S);
            if (S.preParked) {
                detectorFrame(S, detOn, left, right);
                continue;
            }
        } else {
            activatePre(S);
        }

        if (dcOn && S.dcParked) {
            S.dcPrevInL = S.dcPrevInR = S.dcPrevOutL = S.dcPrevOutR = 0.0;
            S.dcMix = 0.0f;
            S.dcParked = 0;
        }
        if (!S.dcParked) {
            const float dryL = left;
            const float dryR = right;
            const double dcL = double(dryL) - S.dcPrevInL + S.dcPole * S.dcPrevOutL;
            const double dcR = double(dryR) - S.dcPrevInR + S.dcPole * S.dcPrevOutR;
            S.dcPrevInL = double(dryL);
            S.dcPrevInR = double(dryR);
            S.dcPrevOutL = dcL;
            S.dcPrevOutR = dcR;
            S.dcMix = smoothToward(S.dcMix, dcOn ? 1.0f : 0.0f, bypass);
            if (!dcOn && nearZero(S.dcMix)) {
                S.dcMix = 0.0f;
                S.dcPrevInL = S.dcPrevInR = S.dcPrevOutL = S.dcPrevOutR = 0.0;
                S.dcParked = 1;
            } else {
                left = dryL + static_cast<float>((dcL - double(dryL)) * double(S.dcMix));
                right = dryR + static_cast<float>((dcR - double(dryR)) * double(S.dcMix));
            }
        }

        if (infraOn && S.infraParked) {
            std::memset(S.infraL, 0, sizeof S.infraL);
            std::memset(S.infraR, 0, sizeof S.infraR);
            S.infraMix = 0.0f;
            S.infraParked = 0;
        }
        if (!S.infraParked) {
            const float dryL = left;
            const float dryR = right;
            const float hpL = runNotches(S.infra, S.infraL, S.infraSections, dryL);
            const float hpR = runNotches(S.infra, S.infraR, S.infraSections, dryR);
            S.infraMix = smoothToward(S.infraMix, infraOn ? 1.0f : 0.0f, bypass);
            if (!infraOn && nearZero(S.infraMix)) {
                S.infraMix = 0.0f;
                std::memset(S.infraL, 0, sizeof S.infraL);
                std::memset(S.infraR, 0, sizeof S.infraR);
                S.infraParked = 1;
            } else {
                left = dryL + (hpL - dryL) * S.infraMix;
                right = dryR + (hpR - dryR) * S.infraMix;
            }
        }

        detectorFrame(S, detOn, left, right);

        if (mainsOn && S.mainsParked) {
            std::memset(S.curL, 0, sizeof S.curL);
            std::memset(S.curR, 0, sizeof S.curR);
            std::memset(S.pendL, 0, sizeof S.pendL);
            std::memset(S.pendR, 0, sizeof S.pendR);
            S.notchInit = 0;
            S.mainsMix = 0.0f;
            S.transTotal = 0;
            S.transRemaining = 0;
            S.mainsParked = 0;
        }
        if (!S.mainsParked) {
            const float dryL = left;
            const float dryR = right;
            if (mainsOn) scheduleRetune(S);
            float nL = runNotches(S.cur.coef, S.curL, S.cur.count, dryL);
            float nR = runNotches(S.cur.coef, S.curR, S.cur.count, dryR);
            if (S.transRemaining > 0) {
                const float pL = runNotches(S.pend.coef, S.pendL, S.pend.count, dryL);
                const float pR = runNotches(S.pend.coef, S.pendR, S.pend.count, dryR);
                const uint32_t completed = S.transTotal - S.transRemaining + 1;
                const float mix = float(completed) / float(S.transTotal);
                nL += (pL - nL) * mix;
                nR += (pR - nR) * mix;
                S.transRemaining -= 1;
                if (S.transRemaining == 0) promotePending(S);
            }
            S.mainsMix = smoothToward(S.mainsMix, mainsOn ? 1.0f : 0.0f, bypass);
            if (!mainsOn && nearZero(S.mainsMix) && S.transRemaining == 0u) {
                S.mainsMix = 0.0f;
                S.notchInit = 0;
                std::memset(S.curL, 0, sizeof S.curL);
                std::memset(S.curR, 0, sizeof S.curR);
                std::memset(S.pendL, 0, sizeof S.pendL);
                std::memset(S.pendR, 0, sizeof S.pendR);
                S.mainsParked = 1;
            } else {
                left = dryL + (nL - dryL) * S.mainsMix;
                right = dryR + (nR - dryR) * S.mainsMix;
            }
        }
        L[i] = left;
        R[i] = right;
    }
    // Denormal guard, once per block: decayed filter state below 1e-30 (-600 dBFS) is flushed to zero so a long tail
    // after loud input never runs the float units in denormal mode. Bounded work, no allocation.
    auto flushD = [](double &v) { if (std::fabs(v) < 1.0e-30) v = 0.0; };
    flushD(S.dcPrevInL); flushD(S.dcPrevInR); flushD(S.dcPrevOutL); flushD(S.dcPrevOutR);
    for (uint32_t k = 0; k < kMaxInfra; ++k) {
        flushD(S.infraL[k].z1); flushD(S.infraL[k].z2); flushD(S.infraR[k].z1); flushD(S.infraR[k].z2);
    }
    for (uint32_t k = 0; k < kMaxHarm; ++k) {
        flushD(S.curL[k].z1); flushD(S.curL[k].z2); flushD(S.curR[k].z1); flushD(S.curR[k].z2);
        flushD(S.pendL[k].z1); flushD(S.pendL[k].z2); flushD(S.pendR[k].z1); flushD(S.pendR[k].z2);
    }
}

n60_status validateCleanupParam(const SnapHeader *h, const StageRec &r, uint32_t idx, float value) N60_RT_NONBLOCKING {
    if (idx >= r.paramCount) return N60_STATUS_BAD_ARGUMENT;
    switch (idx) {
        case kDc:
        case kInfraOn:
        case kMainsOn:
        case kDetOn: return isFlag(value) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kInfraHz: return (inR(value, 10.0, 30.0) && double(value) < h->sampleRate * 0.45) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kInfraSlope: return (isInt(value) && value >= 0.0f && value <= 2.0f) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kMainsHz: return inR(value, 40.0, 70.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kMainsCount: return (isInt(value) && value >= 1.0f && value <= float(kMaxHarm)) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kMainsQ: return inR(value, 5.0, 60.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        case kDetCenter: return inR(value, 47.0, 63.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
        default: return inR(value, -40.0, 0.0) ? N60_STATUS_OK : N60_STATUS_BAD_ARGUMENT;
    }
}

bool readMains(const SnapHeader *h, uint32_t stageId, n60_mains_readback *out) {
    const StageRec *r = findStage(h, stageId);
    if (r == nullptr || r->kind != N60_STAGE_CLEANUP) return false;
    const CleanShared &S = *reinterpret_cast<const CleanShared *>(bytes(h) + r->sharedOff);
    out->frequencyHz = bitsToFloat(S.detFreqBits.load(std::memory_order_relaxed));
    out->confidence = bitsToFloat(S.detConfBits.load(std::memory_order_relaxed));
    out->reserved = 0;
    return true;
}

}  // namespace n60
