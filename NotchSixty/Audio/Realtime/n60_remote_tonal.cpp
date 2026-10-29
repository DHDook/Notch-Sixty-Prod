// E4 S18a: remote adaptive tonal canceller. See N60RemoteTonal.h for the design and maths.
// Worker side only: one thread for every call, no realtime use.
#include "N60RemoteTonal.h"

#include <algorithm>
#include <cmath>
#include <complex>
#include <cstring>
#include <new>
#include <vector>

namespace {

using cd = std::complex<double>;
constexpr double kTwoPi = 6.283185307179586476925286766559;
constexpr double kDeg = 57.295779513082320876798154814105;
constexpr uint32_t kDetectorHistory = 32u;
constexpr double kCoverToleranceSeconds = 0.025;
constexpr double kWarmupSeconds = 4.0;

cd to_cd(N60AncComplex v) { return {v.re, v.im}; }
N60AncComplex from_cd(cd v) { return {static_cast<float>(v.real()), static_cast<float>(v.imag())}; }
bool finite(cd v) { return std::isfinite(v.real()) && std::isfinite(v.imag()); }
double db_to_linear(double db) { return std::pow(10.0, db / 20.0); }

struct Rec {
    uint64_t hostTime = 0;
    cd phasor[N60_FXLMS_MAX_TONES];
    cd weq[N60_FXLMS_MAX_TONES];  // W-equivalent of the gain playing
};

struct Rls {
    cd d{0, 0};
    cd s{0, 0};
    double p00 = 0, p11 = 0;
    cd p01{0, 0};  // Hermitian: p10 = conj(p01)
    uint32_t surprise = 0;
};

struct DetectorEntry {
    double seconds = 0;
    cd path[N60_FXLMS_MAX_TONES];
    cd disturbance[N60_FXLMS_MAX_TONES];
};

}  // namespace

struct N60RemoteTonal {
    N60RemoteTonalConfig cfg{};
    uint32_t tones = 0;
    double ticksPerSecond = 1e9;
    double micRate = 48000;

    std::vector<Rec> history;
    uint64_t historyCount = 0;  // total pushed
    std::vector<double> scratch;

    cd weight[N60_FXLMS_MAX_TONES];
    cd shareL[N60_FXLMS_MAX_TONES], shareR[N60_FXLMS_MAX_TONES];
    cd refPath[N60_FXLMS_MAX_TONES];
    Rls fit[N60_FXLMS_MAX_TONES];
    bool fitStarted = false;
    cd measured[N60_FXLMS_MAX_TONES];
    bool adapting[N60_FXLMS_MAX_TONES] = {};
    bool hold = false;
    bool reidentify = false;
    float attemptCap = 0.0f;

    // Dither.
    uint64_t rng = 1;
    cd dither[N60_FXLMS_MAX_TONES];
    double ditherEpochStart = -1e9;

    // Time base and counters.
    bool haveBase = false;
    uint64_t baseHost = 0;
    double lastBlockSeconds = 0;
    double firstBlockSeconds = -1;
    uint64_t blocks = 0, uncovered = 0, gaps = 0, resets = 0, nonFinite = 0, records = 0;

    // Detector.
    DetectorEntry detector[kDetectorHistory];
    uint32_t detectorCount = 0;
    double violationStart = -1;
    bool moved = false;
    uint32_t movedKind = 0;
    double movedAt = 0;

    double seconds(uint64_t host) const {
        return static_cast<double>(static_cast<int64_t>(host - baseHost)) / ticksPerSecond;
    }
};

namespace {

double uniform_signed(N60RemoteTonal &c) {
    // xorshift64* (Vigna, 2016) -> [-1, 1).
    c.rng ^= c.rng >> 12;
    c.rng ^= c.rng << 25;
    c.rng ^= c.rng >> 27;
    const uint64_t r = c.rng * 0x2545F4914F6CDD1Dull;
    return static_cast<double>(r >> 11) / 4503599627370496.0 - 1.0;
}

void reseed_fit(N60RemoteTonal &c) {
    for (uint32_t k = 0; k < c.tones; ++k) {
        c.fit[k] = Rls{};
        c.fit[k].s = to_cd(c.cfg.pathSeed[k]);
    }
    c.fitStarted = false;
}

void reset_state(N60RemoteTonal &c) {
    for (uint32_t k = 0; k < c.tones; ++k) {
        c.weight[k] = to_cd(c.cfg.weightSeed[k]);
        c.refPath[k] = to_cd(c.cfg.pathSeed[k]);
        c.measured[k] = 0;
        c.adapting[k] = false;
        c.dither[k] = 1.0;
    }
    reseed_fit(c);
    c.historyCount = 0;
    c.hold = false;
    c.reidentify = false;
    c.ditherEpochStart = -1e9;
    c.blocks = c.uncovered = c.gaps = c.resets = c.nonFinite = c.records = 0;
    c.lastBlockSeconds = 0;
    c.firstBlockSeconds = -1;
    c.haveBase = false;
    c.detectorCount = 0;
    c.violationStart = -1;
    c.moved = false;
    c.movedKind = 0;
    c.movedAt = 0;
    c.attemptCap = 0.0f;
}

// Newest-first index of the record nearest in time to `host` among the retained ones.
// Returns false when the history is empty.
bool nearest(const N60RemoteTonal &c, int64_t host, size_t &index) {
    const size_t cap = c.history.size();
    const uint64_t count = std::min<uint64_t>(c.historyCount, cap);
    if (count == 0) return false;
    const uint64_t first = c.historyCount - count;
    uint64_t lo = 0, hi = count;  // first record with time >= host
    while (lo < hi) {
        const uint64_t mid = (lo + hi) / 2;
        const int64_t t = static_cast<int64_t>(c.history[(first + mid) % cap].hostTime);
        if (t < host) lo = mid + 1; else hi = mid;
    }
    uint64_t pick = lo;
    if (lo == count) {
        pick = count - 1;
    } else if (lo > 0) {
        const int64_t a = static_cast<int64_t>(c.history[(first + lo - 1) % cap].hostTime);
        const int64_t b = static_cast<int64_t>(c.history[(first + lo) % cap].hostTime);
        if (host - a < b - host) pick = lo - 1;
    }
    index = (first + pick) % cap;
    return true;
}

// Sum of the Hann window w[i] = 0.5 - 0.5 cos(2 pi (i + 0.5) / n) over [a, b).
double window_sum(uint32_t a, uint32_t b, uint32_t n) {
    const double theta = kTwoPi / static_cast<double>(n);
    const double cosSum = (std::sin(theta * b) - std::sin(theta * a)) / (2.0 * std::sin(theta * 0.5));
    return 0.5 * static_cast<double>(b - a) - 0.5 * cosSum;
}

cd weq_of(const N60RemoteTonal &c, const N60ActiveQuietZoneTelemetryRecord &r, uint32_t k) {
    const cd gl{r.gain[k][0], r.gain[k][1]};
    const cd gr{r.gain[k][2], r.gain[k][3]};
    const double norm = std::norm(c.shareL[k]) + std::norm(c.shareR[k]);
    if (norm <= 0.0) return 0;
    return (std::conj(c.shareL[k]) * gl + std::conj(c.shareR[k]) * gr) / norm;
}

void clamp_weights(N60RemoteTonal &c) {
    const double toneCap = db_to_linear(c.cfg.toneCapDBFS);
    double aggregateCap = db_to_linear(c.cfg.aggregateCapDBFS);
    if (c.attemptCap > 0.0f && c.attemptCap < aggregateCap) aggregateCap = c.attemptCap;
    double sum = 0;
    for (uint32_t k = 0; k < c.tones; ++k) {
        const double share = std::max(std::abs(c.shareL[k]), std::abs(c.shareR[k]));
        double mag = std::abs(c.weight[k]) * share;
        if (mag > toneCap) {
            c.weight[k] *= toneCap / mag;
            mag = toneCap;
        }
        sum += mag;
    }
    if (sum > aggregateCap && sum > 0.0) {
        const double scale = aggregateCap / sum;
        for (uint32_t k = 0; k < c.tones; ++k) c.weight[k] *= scale;
    }
}

// Kalman filter over x = (D, S), each a random walk, with the measurement M = D + S Gbar.
// D drifts slowly (temperature, a moving source) and S changes abruptly or not at all, so D's
// process noise is larger than S's. A forgetting factor would let D's drift leak into S when the
// gain barely varies (Gbar is nearly constant once the tone is cancelled). An innovation test
// re-opens P when two blocks in a row are more than 6 sigma off, which is how a real path change
// (the microphone moved) gets tracked quickly.
void update_fit(N60RemoteTonal &c, uint32_t k, cd m, cd g, double dt) {
    Rls &f = c.fit[k];
    const double seedMag = std::abs(to_cd(c.cfg.pathSeed[k]));
    const double sRate = (c.reidentify ? 0.1 : 0.03 * (2.0 / c.cfg.pathMemorySeconds)) * seedMag;
    const double dRate = 0.02 * std::max(std::abs(f.d), std::abs(m)) + 2e-6;
    f.p00 += dRate * dRate * dt;
    f.p11 += sRate * sRate * dt;
    const double noise = c.cfg.measurementNoise;
    const double r = noise * noise + std::pow(5e-4 * std::abs(m), 2.0);
    const cd p10 = std::conj(f.p01);
    const cd gc = std::conj(g);
    // u = P h^H, h = [1, g]
    const cd u0 = f.p00 + f.p01 * gc;
    const cd u1 = p10 + f.p11 * gc;
    const double denom = r + (u0 + g * u1).real();
    if (!(denom > 0.0) || !std::isfinite(denom)) return;
    const cd k0 = u0 / denom, k1 = u1 / denom;
    const cd err = m - (f.d + f.s * g);
    f.d += k0 * err;
    f.s += k1 * err;
    // P <- P - K (h P), h P = [p00 + g p10, p01 + g p11]
    const cd hp0 = f.p00 + g * p10;
    const cd hp1 = f.p01 + g * f.p11;
    const cd n00 = f.p00 - k0 * hp0;
    const cd n01 = f.p01 - k0 * hp1;
    const cd n11 = f.p11 - k1 * hp1;
    f.p00 = std::max(n00.real(), 0.0);
    f.p01 = n01;
    f.p11 = std::max(n11.real(), 0.0);
    const double limit = std::pow(0.5 * seedMag, 2.0);
    if (f.p11 > limit && limit > 0.0) {
        const double scale = limit / f.p11;
        f.p00 *= scale;
        f.p01 *= scale;
        f.p11 = limit;
    }
    // Innovation test (the block's prediction error against what the filter expected).
    if (std::norm(err) > 36.0 * denom) {
        if (++f.surprise >= 2) {
            f.p11 = limit;
            f.p00 = std::pow(0.5 * std::abs(m) + noise, 2.0);
            f.p01 = 0;
            f.surprise = 0;
        }
    } else {
        f.surprise = 0;
    }
}

void detect(N60RemoteTonal &c, double now) {
    if (c.firstBlockSeconds < 0) return;
    // Remember this block's path.
    DetectorEntry &entry = c.detector[c.blocks % kDetectorHistory];
    entry.seconds = now;
    for (uint32_t k = 0; k < c.tones; ++k) { entry.path[k] = c.fit[k].s; entry.disturbance[k] = c.fit[k].d; }
    c.detectorCount = static_cast<uint32_t>(std::min<uint64_t>(c.blocks + 1, kDetectorHistory));
    if (now - c.firstBlockSeconds < kWarmupSeconds || c.moved) return;

    bool off = false;
    for (uint32_t k = 0; k < c.tones; ++k) {
        const cd ref = c.refPath[k];
        const cd s = c.fit[k].s;
        if (std::abs(ref) <= 0.0 || std::abs(s) <= 0.0) continue;
        const double phase = std::abs(std::arg(s / ref)) * kDeg;
        const double level = std::abs(20.0 * std::log10(std::abs(s) / std::abs(ref)));
        if (phase > 30.0 || level > 3.0) off = true;
    }
    if (off) {
        if (c.violationStart < 0) c.violationStart = now;
        if (now - c.violationStart >= 1.0) {
            c.moved = true;
            c.movedKind = 1;
            c.movedAt = now;
            return;
        }
    } else {
        c.violationStart = -1;
    }

    uint32_t fast = 0;
    for (uint32_t k = 0; k < c.tones; ++k) {
        double worst = 0;
        for (uint32_t i = 0; i < c.detectorCount; ++i) {
            const DetectorEntry &e = c.detector[i];
            if (e.seconds >= now || now - e.seconds > 2.0) continue;
            if (std::abs(e.path[k]) <= 0.0 || std::abs(c.fit[k].s) <= 0.0) continue;
            worst = std::max(worst, std::abs(std::arg(c.fit[k].s / e.path[k])) * kDeg);
        }
        // The whole microphone observation rotates with the path (the disturbance and the path
        // turn together, so the cancelling weight barely moves and the path alone is weakly
        // excited). A disturbance phase jump this fast on a tone is the same event.
        double dworst = 0;
        for (uint32_t i = 0; i < c.detectorCount; ++i) {
            const DetectorEntry &e = c.detector[i];
            if (e.seconds >= now || now - e.seconds > 1.0) continue;
            if (std::abs(e.disturbance[k]) <= 0.0 || std::abs(c.fit[k].d) <= 0.0) continue;
            dworst = std::max(dworst, std::abs(std::arg(c.fit[k].d / e.disturbance[k])) * kDeg);
        }
        if (worst >= 15.0 || dworst >= 25.0) ++fast;
    }
    if (fast >= 2) {
        c.moved = true;
        c.movedKind = 2;
        c.movedAt = now;
    }
}

}  // namespace

N60RemoteTonalConfig N60RemoteTonalConfigDefault(double micSampleRate, double hostTicksPerSecond) {
    N60RemoteTonalConfig c{};
    c.micSampleRate = micSampleRate;
    c.hostTicksPerSecond = hostTicksPerSecond;
    c.toneCount = 0;
    for (uint32_t k = 0; k < N60_FXLMS_MAX_TONES; ++k) {
        c.leftShare[k] = {0.5f, 0.0f};
        c.rightShare[k] = {0.5f, 0.0f};
        c.pathSeed[k] = {1.0f, 0.0f};
    }
    c.convergenceSeconds = 1.0;
    c.leakagePerSecond = 0.002;
    c.pathFloor = 1e-3f;
    c.toneCapDBFS = -24.0f;
    c.aggregateCapDBFS = -18.0f;
    c.loopDelaySeconds = 0.0;
    c.ditherSeed = 0x9E3779B97F4A7C15ull;
    c.ditherDB = 0.5f;
    c.ditherDegrees = 3.0f;
    c.ditherPeriodSeconds = 0.5;
    c.pathMemorySeconds = 2.0;
    c.measurementNoise = 1e-5;
    c.slewDB = 1.5f;
    c.slewDegrees = 10.0f;
    return c;
}

bool N60RemoteTonalConfigIsValid(const N60RemoteTonalConfig *config) {
    if (config == nullptr) return false;
    const N60RemoteTonalConfig &c = *config;
    if (!(c.micSampleRate >= 8000.0 && c.micSampleRate <= 768000.0)) return false;
    if (!(c.hostTicksPerSecond >= 1e3 && c.hostTicksPerSecond <= 1e12)) return false;
    if (c.toneCount < 1 || c.toneCount > N60_FXLMS_MAX_TONES) return false;
    if (!(c.convergenceSeconds >= N60_FXLMS_MIN_CONVERGENCE_SECONDS && c.convergenceSeconds <= 60.0)) return false;
    if (!(c.leakagePerSecond >= 0.0 && c.leakagePerSecond <= 10.0)) return false;
    if (!(c.pathFloor > 0.0f) || !(c.toneCapDBFS <= 0.0f) || !(c.aggregateCapDBFS <= 0.0f)) return false;
    if (!(c.loopDelaySeconds >= 0.0 && c.loopDelaySeconds <= 1.0)) return false;
    if (!(c.ditherDB >= 0.0f && c.ditherDB <= 3.0f) || !(c.ditherDegrees >= 0.0f && c.ditherDegrees <= 20.0f)) return false;
    if (!(c.ditherPeriodSeconds >= 0.1 && c.ditherPeriodSeconds <= 10.0)) return false;
    if (!(c.pathMemorySeconds >= 0.5 && c.pathMemorySeconds <= 60.0)) return false;
    if (!(c.measurementNoise > 0.0 && c.measurementNoise < 1.0)) return false;
    if (!(c.slewDB >= 0.0f && c.slewDegrees >= 0.0f)) return false;
    for (uint32_t k = 0; k < c.toneCount; ++k) {
        if (!(c.toneHz[k] >= 20.0f && c.toneHz[k] <= 150.0f)) return false;
        if (!(c.toneHz[k] < 0.5 * c.micSampleRate)) return false;
        const cd seed = to_cd(c.pathSeed[k]);
        if (!finite(seed) || !(std::abs(seed) >= c.pathFloor)) return false;
        if (!finite(to_cd(c.weightSeed[k])) || !finite(to_cd(c.leftShare[k])) || !finite(to_cd(c.rightShare[k]))) {
            return false;
        }
        if (std::norm(to_cd(c.leftShare[k])) + std::norm(to_cd(c.rightShare[k])) <= 0.0) return false;
    }
    return true;
}

N60RemoteTonal *N60RemoteTonalCreate(const N60RemoteTonalConfig *config) {
    if (!N60RemoteTonalConfigIsValid(config)) return nullptr;
    N60RemoteTonal *c = new (std::nothrow) N60RemoteTonal();
    if (c == nullptr) return nullptr;
    try {
        c->cfg = *config;
        c->tones = config->toneCount;
        c->ticksPerSecond = config->hostTicksPerSecond;
        c->micRate = config->micSampleRate;
        c->history.resize(N60_REMOTE_TONAL_HISTORY);
        c->scratch.resize(static_cast<size_t>(2.0 * config->micSampleRate) + 16);
    } catch (...) {
        delete c;
        return nullptr;
    }
    for (uint32_t k = 0; k < c->tones; ++k) {
        c->shareL[k] = to_cd(config->leftShare[k]);
        c->shareR[k] = to_cd(config->rightShare[k]);
    }
    c->rng = config->ditherSeed != 0 ? config->ditherSeed : 1;
    reset_state(*c);
    return c;
}

void N60RemoteTonalDestroy(N60RemoteTonal *core) { delete core; }

void N60RemoteTonalPushTelemetry(N60RemoteTonal *c, const N60ActiveQuietZoneTelemetryRecord *record) {
    if (c == nullptr || record == nullptr || record->hostTime == 0 || record->toneCount < c->tones) return;
    for (uint32_t k = 0; k < c->tones; ++k) {
        if (std::fabs(record->frequencyHz[k] - c->cfg.toneHz[k]) > 0.01) return;
    }
    if (c->historyCount > 0) {
        const Rec &newest = c->history[(c->historyCount - 1) % c->history.size()];
        if (record->hostTime <= newest.hostTime) return;
    }
    if (!c->haveBase) {
        c->haveBase = true;
        c->baseHost = record->hostTime;
    }
    Rec &slot = c->history[c->historyCount % c->history.size()];
    slot.hostTime = record->hostTime;
    for (uint32_t k = 0; k < c->tones; ++k) {
        const cd p{record->phasorCosine[k], record->phasorSine[k]};
        const double mag = std::abs(p);
        slot.phasor[k] = mag > 0.0 && std::isfinite(mag) ? p / mag : cd{1, 0};
        const cd w = weq_of(*c, *record, k);
        slot.weq[k] = finite(w) ? w : cd{0, 0};
    }
    ++c->historyCount;
}

bool N60RemoteTonalProcessMic(N60RemoteTonal *c, const float *samples, uint32_t frames, uint64_t hostTime) {
    if (c == nullptr || samples == nullptr) return false;
    if (hostTime == 0 || frames < 64 || frames > c->scratch.size() || c->historyCount == 0) {
        ++c->uncovered;
        return false;
    }
    const size_t cap = c->history.size();
    const uint64_t count = std::min<uint64_t>(c->historyCount, cap);
    const Rec &newest = c->history[(c->historyCount - 1) % cap];
    const Rec &oldest = c->history[(c->historyCount - count) % cap];
    const double blockSeconds = static_cast<double>(frames) / c->micRate;
    const int64_t tolerance = static_cast<int64_t>(kCoverToleranceSeconds * c->ticksPerSecond);
    const int64_t endHost = static_cast<int64_t>(hostTime) + static_cast<int64_t>(blockSeconds * c->ticksPerSecond);
    const int64_t delayTicks = static_cast<int64_t>(c->cfg.loopDelaySeconds * c->ticksPerSecond);
    if (static_cast<int64_t>(newest.hostTime) + tolerance < endHost
        || static_cast<int64_t>(oldest.hostTime) - tolerance > static_cast<int64_t>(hostTime) - delayTicks) {
        ++c->uncovered;
        return false;
    }

    // Windowed samples.
    const double theta = kTwoPi / static_cast<double>(frames);
    uint32_t nonFinite = 0;
    for (uint32_t i = 0; i < frames; ++i) {
        double x = samples[i];
        if (!std::isfinite(x)) {
            x = 0.0;
            ++nonFinite;
        }
        x = std::clamp(x, -8.0, 8.0);
        c->scratch[i] = x * (0.5 - 0.5 * std::cos(theta * (i + 0.5)));
    }
    c->nonFinite += nonFinite;
    const double wTotal = window_sum(0, frames, frames);

    // Demodulate against the phasor the kernel played, segment by segment.
    cd acc[N60_FXLMS_MAX_TONES] = {};
    uint32_t i = 0;
    while (i < frames) {
        const int64_t t = static_cast<int64_t>(hostTime) + static_cast<int64_t>(i / c->micRate * c->ticksPerSecond);
        size_t idx = 0;
        nearest(*c, t, idx);
        const Rec &r = c->history[idx];
        // Last sample for which this record is still the nearest.
        uint32_t end = frames;
        const uint64_t recNumber = c->historyCount - count;  // oldest retained record number
        (void)recNumber;
        const size_t nextIdx = (idx + 1) % cap;
        const bool hasNext = &r != &newest && count > 1;
        if (hasNext) {
            const int64_t boundary = (static_cast<int64_t>(r.hostTime) + static_cast<int64_t>(c->history[nextIdx].hostTime)) / 2;
            const double sample = static_cast<double>(boundary - static_cast<int64_t>(hostTime)) / c->ticksPerSecond * c->micRate;
            end = static_cast<uint32_t>(std::clamp(std::ceil(sample), static_cast<double>(i + 1), static_cast<double>(frames)));
        }
        const double base = static_cast<double>(static_cast<int64_t>(hostTime) - static_cast<int64_t>(r.hostTime)) / c->ticksPerSecond;
        for (uint32_t k = 0; k < c->tones; ++k) {
            const double omega = kTwoPi * c->cfg.toneHz[k];
            cd p = r.phasor[k] * std::polar(1.0, omega * (base + static_cast<double>(i) / c->micRate));
            const cd q = std::polar(1.0, omega / c->micRate);
            double re = 0, im = 0;
            double pr = p.real(), pi = p.imag();
            const double qr = q.real(), qi = q.imag();
            for (uint32_t n = i; n < end; ++n) {
                const double x = c->scratch[n];
                re += x * pr;
                im -= x * pi;  // x * conj(p)
                const double nr = pr * qr - pi * qi;
                pi = pr * qi + pi * qr;
                pr = nr;
            }
            acc[k] += cd{re, im};
        }
        i = end;
    }

    // Window-mean gain playing (looked up one loop delay earlier).
    cd gbar[N60_FXLMS_MAX_TONES] = {};
    i = 0;
    while (i < frames) {
        const int64_t t = static_cast<int64_t>(hostTime) - delayTicks
            + static_cast<int64_t>(i / c->micRate * c->ticksPerSecond);
        size_t idx = 0;
        nearest(*c, t, idx);
        const Rec &r = c->history[idx];
        uint32_t end = frames;
        if (&r != &newest && count > 1) {
            const size_t nextIdx = (idx + 1) % cap;
            const int64_t boundary = (static_cast<int64_t>(r.hostTime) + static_cast<int64_t>(c->history[nextIdx].hostTime)) / 2;
            const double sample = static_cast<double>(boundary - static_cast<int64_t>(hostTime) + delayTicks) / c->ticksPerSecond * c->micRate;
            end = static_cast<uint32_t>(std::clamp(std::ceil(sample), static_cast<double>(i + 1), static_cast<double>(frames)));
        }
        const double ws = window_sum(i, end, frames);
        for (uint32_t k = 0; k < c->tones; ++k) gbar[k] += ws * r.weq[k];
        i = end;
    }

    const double now = c->seconds(hostTime) + blockSeconds;
    const double dt = blockSeconds;
    if (c->firstBlockSeconds < 0) c->firstBlockSeconds = now;
    const double alpha = 1.0 - std::exp(-dt / c->cfg.convergenceSeconds);
    bool fault = false;
    cd m[N60_FXLMS_MAX_TONES];
    for (uint32_t k = 0; k < c->tones; ++k) {
        m[k] = 2.0 * acc[k] / wTotal;
        gbar[k] /= wTotal;
        if (!finite(m[k]) || !finite(gbar[k])) fault = true;
    }
    if (fault) {
        ++c->uncovered;
        return false;
    }

    // Path fit (always), then the weight update.
    for (uint32_t k = 0; k < c->tones; ++k) {
        c->measured[k] = m[k];
        if (!c->fitStarted) {
            Rls &f = c->fit[k];
            f.d = m[k] - f.s * gbar[k];
            const double sp = std::abs(f.s);
            f.p00 = std::pow(0.5 * std::abs(m[k]) + c->cfg.measurementNoise, 2.0);
            f.p11 = std::pow(0.5 * sp, 2.0);
            f.p01 = 0;
        }
        update_fit(*c, k, m[k], gbar[k], dt);
    }
    c->fitStarted = true;

    bool reset = false;
    for (uint32_t k = 0; k < c->tones; ++k) {
        const cd s = c->fit[k].s;
        c->adapting[k] = false;
        if (!finite(s) || !finite(c->fit[k].d) || !finite(c->weight[k])) {
            reset = true;
            continue;
        }
        if (c->hold || std::abs(s) < c->cfg.pathFloor) continue;
        const cd ev = m[k] - s * (gbar[k] - c->weight[k]);
        c->weight[k] = (1.0 - c->cfg.leakagePerSecond * dt) * c->weight[k] - alpha * ev / s;
        c->adapting[k] = true;
    }
    if (reset) {
        ++c->resets;
        for (uint32_t k = 0; k < c->tones; ++k) c->weight[k] = to_cd(c->cfg.weightSeed[k]);
        reseed_fit(*c);
    } else {
        clamp_weights(*c);
    }

    c->lastBlockSeconds = now;
    if (!reset) detect(*c, now);
    ++c->blocks;
    return true;
}

bool N60RemoteTonalNextRecord(N60RemoteTonal *c, uint64_t armGeneration, float attemptCapLinear,
                              N60ActiveQuietZoneGainRecord *record) {
    if (c == nullptr || record == nullptr || c->historyCount == 0) return false;
    c->attemptCap = attemptCapLinear > 0.0f ? attemptCapLinear : 0.0f;
    const Rec &playing = c->history[(c->historyCount - 1) % c->history.size()];
    const double now = c->lastBlockSeconds > 0.0 ? c->lastBlockSeconds : c->seconds(playing.hostTime);
    if (now - c->ditherEpochStart >= c->cfg.ditherPeriodSeconds) {
        c->ditherEpochStart = now;
        const double scale = c->reidentify ? 3.0 : 1.0;
        for (uint32_t k = 0; k < c->tones; ++k) {
            const double gain = uniform_signed(*c) * c->cfg.ditherDB * scale;
            const double phase = uniform_signed(*c) * c->cfg.ditherDegrees * scale / kDeg;
            c->dither[k] = std::polar(db_to_linear(gain), phase);
        }
    }
    std::memset(record, 0, sizeof(*record));
    record->armGeneration = armGeneration;
    record->toneCount = c->tones;
    record->attemptCapLinear = c->attemptCap;
    for (uint32_t k = 0; k < c->tones; ++k) {
        if (!finite(c->weight[k])) return false;
        cd target = c->weight[k] * c->dither[k];
        const cd ref = playing.weq[k];
        if (std::abs(ref) > 1e-7 && std::abs(target) > 0.0) {
            const cd ratio = target / ref;
            double mag = 20.0 * std::log10(std::abs(ratio));
            double phase = std::arg(ratio) * kDeg;
            if (c->cfg.slewDB > 0.0f) mag = std::clamp(mag, -double(c->cfg.slewDB), double(c->cfg.slewDB));
            if (c->cfg.slewDegrees > 0.0f) phase = std::clamp(phase, -double(c->cfg.slewDegrees), double(c->cfg.slewDegrees));
            target = ref * std::polar(db_to_linear(mag), phase / kDeg);
        }
        const cd gl = target * c->shareL[k];
        const cd gr = target * c->shareR[k];
        record->frequencyHz[k] = c->cfg.toneHz[k];
        record->gain[k][0] = static_cast<float>(gl.real());
        record->gain[k][1] = static_cast<float>(gl.imag());
        record->gain[k][2] = static_cast<float>(gr.real());
        record->gain[k][3] = static_cast<float>(gr.imag());
    }
    ++c->records;
    return true;
}

void N60RemoteTonalSetHold(N60RemoteTonal *c, bool hold) {
    if (c != nullptr) c->hold = hold;
}

void N60RemoteTonalBeginReidentify(N60RemoteTonal *c) {
    if (c != nullptr) {
        c->reidentify = true;
        c->ditherEpochStart = -1e9;  // draw the larger dither at the next record
    }
}

void N60RemoteTonalEndReidentify(N60RemoteTonal *c) {
    if (c != nullptr) c->reidentify = false;
}

void N60RemoteTonalCaptureReference(N60RemoteTonal *c) {
    if (c == nullptr) return;
    for (uint32_t k = 0; k < c->tones; ++k) c->refPath[k] = c->fit[k].s;
    c->violationStart = -1;
}

void N60RemoteTonalAcknowledgeMove(N60RemoteTonal *c) {
    if (c == nullptr) return;
    c->moved = false;
    c->movedKind = 0;
    c->violationStart = -1;
    c->detectorCount = 0;
}

bool N60RemoteTonalSetWeights(N60RemoteTonal *c, const N60AncComplex *weights, uint32_t count) {
    if (c == nullptr || weights == nullptr || count != c->tones) return false;
    for (uint32_t k = 0; k < count; ++k) {
        if (!finite(to_cd(weights[k]))) return false;
    }
    for (uint32_t k = 0; k < count; ++k) c->weight[k] = to_cd(weights[k]);
    clamp_weights(*c);
    return true;
}

void N60RemoteTonalMarkDiscontinuity(N60RemoteTonal *c) {
    if (c == nullptr) return;
    ++c->gaps;
    c->historyCount = 0;
    c->violationStart = -1;
    c->detectorCount = 0;
}

void N60RemoteTonalReset(N60RemoteTonal *c) {
    if (c != nullptr) reset_state(*c);
}

N60RemoteTonalStatus N60RemoteTonalReadStatus(const N60RemoteTonal *c) {
    N60RemoteTonalStatus s{};
    if (c == nullptr) return s;
    s.blocks = c->blocks;
    s.uncoveredBlocks = c->uncovered;
    s.gaps = c->gaps;
    s.modelResets = c->resets;
    s.nonFiniteSamples = c->nonFinite;
    s.records = c->records;
    s.lastBlockSeconds = c->lastBlockSeconds;
    for (uint32_t k = 0; k < c->tones; ++k) {
        s.weight[k] = from_cd(c->weight[k]);
        s.path[k] = from_cd(c->fit[k].s);
        s.referencePath[k] = from_cd(c->refPath[k]);
        s.disturbance[k] = from_cd(c->fit[k].d);
        s.measuredTone[k] = from_cd(c->measured[k]);
        const cd ref = c->refPath[k];
        const cd path = c->fit[k].s;
        if (std::abs(ref) > 0.0 && std::abs(path) > 0.0) {
            s.pathPhaseDegrees[k] = static_cast<float>(std::arg(path / ref) * kDeg);
            s.pathLevelDB[k] = static_cast<float>(20.0 * std::log10(std::abs(path) / std::abs(ref)));
        }
        s.adapting[k] = c->adapting[k];
    }
    s.micMoved = c->moved;
    s.micMovedKind = c->movedKind;
    s.micMovedAtSeconds = c->movedAt;
    s.reidentifying = c->reidentify;
    return s;
}
