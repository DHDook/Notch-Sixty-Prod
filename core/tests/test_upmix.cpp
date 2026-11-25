// E14 S1: behavioural tests for the stereo upmixer (n60/upmix.h) at the eight standard rates 44.1 to 384 kHz.
// Signals are seeded multisines (a mono or hard-panned programme) and seeded white noise (an uncorrelated one);
// everything is deterministic. Levels are measured after the statistics and the strength fade-in have settled.
#include "n60/n60.h"
#include "n60/upmix.h"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>

static int failures = 0;
#define CHECK(cond, msg)                                                       \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); \
            ++failures;                                                        \
        }                                                                      \
    } while (0)
#define CHECKF(cond, ...)                                                      \
    do {                                                                       \
        if (!(cond)) {                                                         \
            std::fprintf(stderr, "FAIL %s:%d ", __FILE__, __LINE__);           \
            std::fprintf(stderr, __VA_ARGS__);                                 \
            std::fprintf(stderr, "\n");                                        \
            ++failures;                                                        \
        }                                                                      \
    } while (0)

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
typedef std::vector<float> Buf;

static uint32_t rngState = 1;
static uint32_t rnd() {
    rngState ^= rngState << 13;
    rngState ^= rngState >> 17;
    rngState ^= rngState << 5;
    return rngState;
}
static double uni() { return (rnd() >> 8) / 16777216.0; }

// Roughly Gaussian white noise of the given RMS.
static Buf noise(uint32_t seed, uint32_t n, double rms) {
    rngState = seed * 2654435761u + 7u;
    Buf b(n);
    for (uint32_t i = 0; i < n; ++i) {
        const double g = (uni() + uni() + uni() + uni() - 2.0) * std::sqrt(3.0);  // unit variance
        b[i] = static_cast<float>(g * rms);
    }
    return b;
}

// Twelve sines between 200 Hz and 12 kHz with seeded phases, RMS about `rms`.
static Buf multisine(uint32_t seed, double rate, uint32_t n, double rms) {
    rngState = seed * 2654435761u + 3u;
    double f[12], ph[12];
    for (int k = 0; k < 12; ++k) {
        f[k] = 200.0 * std::pow(60.0, (k + uni() * 0.6) / 12.0);
        ph[k] = 2.0 * kPi * uni();
    }
    Buf b(n);
    const double amp = rms * std::sqrt(2.0 / 12.0);
    for (uint32_t i = 0; i < n; ++i) {
        double v = 0;
        for (int k = 0; k < 12; ++k) v += std::sin(2.0 * kPi * f[k] * i / rate + ph[k]);
        b[i] = static_cast<float>(amp * v);
    }
    return b;
}

static double power(const Buf &b, uint32_t from, uint32_t to) {
    double s = 0;
    for (uint32_t i = from; i < to; ++i) s += static_cast<double>(b[i]) * b[i];
    return s / (to - from);
}
static double db(double p) { return 10.0 * std::log10(p + 1e-30); }

struct Layout {
    const char *name;
    uint32_t id;
};
static const Layout kLayouts[] = {{"5.1", N60_LAYOUT_5_1}, {"7.1", N60_LAYOUT_7_1}, {"7.1.4", N60_LAYOUT_7_1_4},
                                  {"5.1.4", N60_LAYOUT_5_1_4}, {"9.1.6", N60_LAYOUT_9_1_6}};

static n60_upmix_config makeConfig(uint32_t layoutId, double rate, float strength) {
    n60_layout layout;
    std::memset(&layout, 0, sizeof layout);
    n60_layout_standard(layoutId, &layout);
    n60_upmix_config cfg;
    std::memset(&cfg, 0, sizeof cfg);
    cfg.structSize = sizeof cfg;
    cfg.channelCount = layout.channelCount;
    for (uint32_t c = 0; c < layout.channelCount; ++c) cfg.roles[c] = layout.roles[c];
    cfg.sampleRate = rate;
    cfg.strength = strength;
    cfg.seed = 12345;
    return cfg;
}

static std::vector<Buf> run(const n60_upmix_config &cfg, const Buf &l, const Buf &r, uint32_t block = 0) {
    std::vector<Buf> lanes(cfg.channelCount, Buf(l.size(), 0.0f));
    float *ptrs[N60_LAYOUT_MAX_CHANNELS];
    for (uint32_t c = 0; c < cfg.channelCount; ++c) ptrs[c] = lanes[c].data();
    const int32_t st = n60_upmix_process_offline(&cfg, l.data(), r.data(), static_cast<uint32_t>(l.size()), ptrs, block);
    CHECK(st == N60_UPMIX_OK, "process_offline status");
    return lanes;
}

static int laneOf(const n60_upmix_config &cfg, uint32_t role) {
    for (uint32_t c = 0; c < cfg.channelCount; ++c)
        if (cfg.roles[c] == role) return static_cast<int>(c);
    return -1;
}
static bool leftSide(uint32_t r) { return r == 5 || r == 7 || r == 9 || r == 11 || r == 13 || r == 15; }
static bool rightSide(uint32_t r) { return r == 6 || r == 8 || r == 10 || r == 12 || r == 14 || r == 16; }

static void testAbiAndRates() {
    CHECK(n60_upmix_abi_version() == N60_UPMIX_ABI_VERSION, "abi version");
    const uint32_t frame[] = {1024, 1024, 2048, 2048, 4096, 4096, 8192, 8192};
    for (int i = 0; i < 8; ++i) {
        CHECKF(n60_upmix_frame_length(kRates[i]) == frame[i], "frame length at %.0f", kRates[i]);
        CHECK(n60_upmix_latency_frames(kRates[i]) == frame[i], "latency is one frame");
        const double ms = 1000.0 * n60_upmix_latency_frames(kRates[i]) / kRates[i];
        CHECKF(ms > 20.0 && ms < 24.0, "latency %.2f ms at %.0f", ms, kRates[i]);
    }
    CHECK(n60_upmix_frame_length(1000.0) == 0, "rate too low");
    CHECK(n60_upmix_frame_length(1e6) == 0, "rate too high");
}

static void testBadArguments() {
    Buf l(4096, 0.0f), r(4096, 0.0f);
    float *ptrs[2] = {l.data(), r.data()};
    n60_upmix_config cfg = makeConfig(N60_LAYOUT_5_1, 48000, 0.5f);
    float *lanes[N60_LAYOUT_MAX_CHANNELS];
    std::vector<Buf> store(cfg.channelCount, Buf(4096));
    for (uint32_t c = 0; c < cfg.channelCount; ++c) lanes[c] = store[c].data();
    CHECK(n60_upmix_process_offline(nullptr, l.data(), r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "null config");
    CHECK(n60_upmix_process_offline(&cfg, nullptr, r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "null left");
    CHECK(n60_upmix_process_offline(&cfg, l.data(), r.data(), 4096, lanes, 0) == N60_UPMIX_OK, "good call");
    n60_upmix_config bad = cfg;
    bad.sampleRate = 1000;
    CHECK(n60_upmix_process_offline(&bad, l.data(), r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "bad rate");
    bad = cfg;
    bad.strength = 1.5f;
    CHECK(n60_upmix_process_offline(&bad, l.data(), r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "bad strength");
    bad = cfg;
    bad.roles[1] = bad.roles[0];  // duplicate role, and no front right
    CHECK(n60_upmix_process_offline(&bad, l.data(), r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "duplicate role");
    bad = cfg;
    bad.structSize = 4;
    CHECK(n60_upmix_process_offline(&bad, l.data(), r.data(), 4096, lanes, 0) != N60_UPMIX_OK, "bad struct size");
    (void)ptrs;
}

// Strength 0: the front pair is the input delayed by the latency (to -120 dB), every other lane is silent.
static void testStrengthZeroIsDelayedInput() {
    for (double rate : kRates) {
        const uint32_t n = static_cast<uint32_t>(rate * 1.2);
        const Buf l = multisine(1, rate, n, 0.1), r = multisine(2, rate, n, 0.1);
        const n60_upmix_config cfg = makeConfig(N60_LAYOUT_7_1_4, rate, 0.0f);
        const std::vector<Buf> out = run(cfg, l, r);
        const uint32_t lat = n60_upmix_latency_frames(rate);
        double err = 0, ref = 0;
        for (uint32_t i = lat; i < n; ++i) {
            const double dl = out[laneOf(cfg, N60_ROLE_FRONT_LEFT)][i] - l[i - lat];
            const double dr = out[laneOf(cfg, N60_ROLE_FRONT_RIGHT)][i] - r[i - lat];
            err += dl * dl + dr * dr;
            ref += static_cast<double>(l[i - lat]) * l[i - lat] + static_cast<double>(r[i - lat]) * r[i - lat];
        }
        CHECKF(db(err / ref) < -120.0, "strength 0 error %.1f dB at %.0f", db(err / ref), rate);
        for (uint32_t c = 0; c < cfg.channelCount; ++c) {
            if (cfg.roles[c] == N60_ROLE_FRONT_LEFT || cfg.roles[c] == N60_ROLE_FRONT_RIGHT) continue;
            double peak = 0;
            for (float v : out[c]) peak = std::fmax(peak, std::fabs(v));
            CHECKF(peak == 0.0, "strength 0: lane %u silent (peak %g) at %.0f", c, peak, rate);
        }
    }
}

// The measured delay equals the reported latency.
static void testLatencyMatches() {
    for (double rate : kRates) {
        const uint32_t n = static_cast<uint32_t>(rate * 0.6);
        Buf l(n, 0.0f), r(n, 0.0f);
        const uint32_t at = 3001;
        l[at] = 1.0f;
        const n60_upmix_config cfg = makeConfig(N60_LAYOUT_5_1, rate, 0.0f);
        const std::vector<Buf> out = run(cfg, l, r);
        uint32_t peak = 0;
        const Buf &fl = out[laneOf(cfg, N60_ROLE_FRONT_LEFT)];
        for (uint32_t i = 0; i < n; ++i)
            if (std::fabs(fl[i]) > std::fabs(fl[peak])) peak = i;
        CHECKF(peak == at + n60_upmix_latency_frames(rate), "measured delay %u at %.0f", peak - at, rate);
        CHECKF(std::fabs(fl[peak] - 1.0f) < 1e-4f, "impulse level %g at %.0f", fl[peak], rate);
    }
}

// Mono at 100%: the centre carries the programme; the front pair and every ambient lane are far below it.
static void testMonoGoesToCentre() {
    for (const Layout &lay : kLayouts) {
        for (double rate : kRates) {
            if (lay.id != N60_LAYOUT_7_1_4 && rate != 48000 && rate != 384000) continue;
            const uint32_t n = static_cast<uint32_t>(rate * 3.0);
            const Buf m = multisine(5, rate, n, 0.1);
            const n60_upmix_config cfg = makeConfig(lay.id, rate, 1.0f);
            const std::vector<Buf> out = run(cfg, m, m);
            const uint32_t from = static_cast<uint32_t>(rate * 2.0);
            const double pin = power(m, from, n);
            const double pc = power(out[laneOf(cfg, N60_ROLE_FRONT_CENTER)], from, n);
            const double pl = power(out[laneOf(cfg, N60_ROLE_FRONT_LEFT)], from, n);
            const double pr = power(out[laneOf(cfg, N60_ROLE_FRONT_RIGHT)], from, n);
            CHECKF(db(pc) - db(pl) >= 20.0 && db(pc) - db(pr) >= 20.0, "%s mono: C %.1f dB, L %.1f, R %.1f at %.0f", lay.name,
                   db(pc), db(pl), db(pr), rate);
            CHECKF(std::fabs(db(pc) - db(2.0 * pin)) < 0.5, "%s mono: C power %.2f dB vs input %.2f at %.0f", lay.name,
                   db(pc), db(2.0 * pin), rate);
            for (uint32_t c = 0; c < cfg.channelCount; ++c) {
                const uint32_t role = cfg.roles[c];
                if (role == N60_ROLE_FRONT_LEFT || role == N60_ROLE_FRONT_RIGHT || role == N60_ROLE_FRONT_CENTER) continue;
                CHECKF(db(power(out[c], from, n)) - db(pin) < -40.0, "%s mono: lane %u (role %u) %.1f dB at %.0f", lay.name, c,
                       role, db(power(out[c], from, n)) - db(pin), rate);
            }
        }
    }
}

// Uncorrelated noise: ambience reaches the surrounds and heights at the design level, the centre stays quiet.
static void testAmbienceDesignLevel() {
    const double kA = N60_UPMIX_AMBIENCE_FRACTION;
    for (const Layout &lay : kLayouts) {
        for (double rate : kRates) {
            if (lay.id != N60_LAYOUT_7_1_4 && rate != 48000 && rate != 384000) continue;
            const uint32_t n = static_cast<uint32_t>(rate * 4.0);
            const double sigma = 0.1;
            const Buf l = noise(11, n, sigma), r = noise(12, n, sigma);
            const n60_upmix_config cfg = makeConfig(lay.id, rate, 1.0f);
            const std::vector<Buf> out = run(cfg, l, r);
            const uint32_t from = static_cast<uint32_t>(rate * 2.5);
            uint32_t nl = 0, nr = 0;
            for (uint32_t c = 0; c < cfg.channelCount; ++c) {
                if (leftSide(cfg.roles[c])) ++nl;
                if (rightSide(cfg.roles[c])) ++nr;
            }
            const double band = std::fmin(1.0, N60_UPMIX_MAX_HZ / (rate / 2.0));
            const double pin = sigma * sigma;
            for (uint32_t c = 0; c < cfg.channelCount; ++c) {
                const uint32_t role = cfg.roles[c];
                if (!leftSide(role) && !rightSide(role)) continue;
                const double expect = pin * band * kA / (leftSide(role) ? nl : nr);
                const double got = power(out[c], from, n);
                CHECKF(std::fabs(db(got) - db(expect)) < 1.0, "%s noise: lane %u (role %u) %.2f dB vs design %.2f at %.0f", lay.name,
                       c, role, db(got), db(expect), rate);
            }
            const double pc = power(out[laneOf(cfg, N60_ROLE_FRONT_CENTER)], from, n);
            CHECKF(db(pc) - db(pin) < -20.0, "%s noise: C %.1f dB below input at %.0f", lay.name, db(pc) - db(pin), rate);
            CHECK(power(out[laneOf(cfg, N60_ROLE_LFE)], 0, n) == 0.0, "LFE silent");
        }
    }
}

// A hard-left tone stays in the left speaker.
static void testHardLeftStaysLeft() {
    for (double rate : kRates) {
        const uint32_t n = static_cast<uint32_t>(rate * 3.0);
        Buf l(n), r(n, 0.0f);
        for (uint32_t i = 0; i < n; ++i) l[i] = static_cast<float>(0.2 * std::sin(2.0 * kPi * 1000.0 * i / rate));
        const n60_upmix_config cfg = makeConfig(N60_LAYOUT_7_1_4, rate, 1.0f);
        const std::vector<Buf> out = run(cfg, l, r);
        const uint32_t from = static_cast<uint32_t>(rate * 2.0);
        const double pl = power(out[laneOf(cfg, N60_ROLE_FRONT_LEFT)], from, n);
        for (uint32_t c = 0; c < cfg.channelCount; ++c) {
            if (cfg.roles[c] == N60_ROLE_FRONT_LEFT) continue;
            CHECKF(db(power(out[c], from, n)) - db(pl) < -40.0, "hard left: lane %u (role %u) %.1f dB at %.0f", c, cfg.roles[c],
                   db(power(out[c], from, n)) - db(pl), rate);
        }
        CHECKF(std::fabs(db(pl) - db(power(l, from, n))) < 0.5, "hard left: L level at %.0f", rate);
    }
}

// Total output power equals input power at 0, 50 and 100 %, for a mono and for an uncorrelated programme.
static void testPowerPreserved() {
    const float strengths[] = {0.0f, 0.5f, 1.0f};
    for (double rate : kRates) {
        for (int kind = 0; kind < 2; ++kind) {
            const uint32_t n = static_cast<uint32_t>(rate * 4.0);
            const Buf l = kind == 0 ? multisine(7, rate, n, 0.1) : noise(21, n, 0.1);
            const Buf r = kind == 0 ? l : noise(22, n, 0.1);
            const uint32_t from = static_cast<uint32_t>(rate * 2.5);
            for (float s : strengths) {
                const n60_upmix_config cfg = makeConfig(N60_LAYOUT_7_1_4, rate, s);
                const std::vector<Buf> out = run(cfg, l, r);
                double pout = 0;
                for (uint32_t c = 0; c < cfg.channelCount; ++c) pout += power(out[c], from, n);
                const double pin = power(l, from - 0, n) + power(r, from, n);
                CHECKF(std::fabs(db(pout) - db(pin)) < 0.5, "power %s s=%.1f: %.2f dB vs %.2f at %.0f", kind ? "noise" : "mono",
                       s, db(pout), db(pin), rate);
            }
        }
    }
}

// The centre share grows with strength.
static void testStrengthIsMonotonic() {
    const double rate = 48000;
    const uint32_t n = static_cast<uint32_t>(rate * 3.0);
    const Buf m = multisine(5, rate, n, 0.1);
    double last = -1;
    for (float s : {0.0f, 0.25f, 0.5f, 0.75f, 1.0f}) {
        const n60_upmix_config cfg = makeConfig(N60_LAYOUT_5_1, rate, s);
        const std::vector<Buf> out = run(cfg, m, m);
        const double pc = power(out[laneOf(cfg, N60_ROLE_FRONT_CENTER)], static_cast<uint32_t>(rate * 2.0), n);
        CHECKF(pc > last, "centre power rises with strength (s=%.2f)", s);
        last = pc;
    }
}

// Non-finite input is sanitised; two runs are bit-identical; the block size does not change the result.
static void testRobustAndDeterministic() {
    for (double rate : kRates) {
        const uint32_t n = static_cast<uint32_t>(rate * 0.8);
        Buf l = noise(31, n, 0.1), r = noise(32, n, 0.1);
        l[1000] = NAN;
        r[2000] = INFINITY;
        l[3000] = -INFINITY;
        r[4000] = 3e30f;
        const n60_upmix_config cfg = makeConfig(N60_LAYOUT_7_1_4, rate, 0.8f);
        const std::vector<Buf> a = run(cfg, l, r), b = run(cfg, l, r);
        bool finite = true, same = true;
        for (uint32_t c = 0; c < cfg.channelCount; ++c) {
            for (float v : a[c]) finite = finite && std::isfinite(v);
            same = same && std::memcmp(a[c].data(), b[c].data(), n * sizeof(float)) == 0;
        }
        CHECKF(finite, "non-finite input sanitised at %.0f", rate);
        CHECKF(same, "two runs bit-identical at %.0f", rate);
        for (uint32_t block : {1u, 7u, 256u, 1000u, 4096u}) {
            const std::vector<Buf> c2 = run(cfg, l, r, block);
            bool eq = true;
            for (uint32_t c = 0; c < cfg.channelCount; ++c) eq = eq && std::memcmp(a[c].data(), c2[c].data(), n * sizeof(float)) == 0;
            CHECKF(eq, "block size %u gives the same output at %.0f", block, rate);
        }
        // A different seed changes the decorrelated lanes.
        n60_upmix_config other = cfg;
        other.seed = 999;
        const std::vector<Buf> d = run(other, l, r);
        const int sl = laneOf(cfg, N60_ROLE_SIDE_LEFT);
        CHECK(std::memcmp(a[sl].data(), d[sl].data(), n * sizeof(float)) != 0, "seed changes the decorrelators");
    }
}

// Speakers of one side carry decorrelated copies: no two ambient lanes are alike.
static void testDecorrelation() {
    const double rate = 48000;
    const uint32_t n = static_cast<uint32_t>(rate * 4.0);
    const Buf l = noise(41, n, 0.1), r = noise(42, n, 0.1);
    const n60_upmix_config cfg = makeConfig(N60_LAYOUT_7_1_4, rate, 1.0f);
    const std::vector<Buf> out = run(cfg, l, r);
    std::vector<uint32_t> amb;
    for (uint32_t c = 0; c < cfg.channelCount; ++c)
        if (leftSide(cfg.roles[c]) || rightSide(cfg.roles[c])) amb.push_back(c);
    const uint32_t from = static_cast<uint32_t>(rate * 2.5);
    for (size_t i = 0; i < amb.size(); ++i)
        for (size_t j = i + 1; j < amb.size(); ++j) {
            double xy = 0, xx = 0, yy = 0;
            for (uint32_t k = from; k < n; ++k) {
                const double x = out[amb[i]][k], y = out[amb[j]][k];
                xy += x * y;
                xx += x * x;
                yy += y * y;
            }
            const double rho = xy / std::sqrt(xx * yy + 1e-30);
            CHECKF(std::fabs(rho) < 0.5, "ambient lanes %u and %u correlation %.2f", amb[i], amb[j], rho);
        }
}

int main() {
    testAbiAndRates();
    testBadArguments();
    testStrengthZeroIsDelayedInput();
    testLatencyMatches();
    testMonoGoesToCentre();
    testAmbienceDesignLevel();
    testHardLeftStaysLeft();
    testPowerPreserved();
    testStrengthIsMonotonic();
    testRobustAndDeterministic();
    testDecorrelation();
    if (failures == 0) std::printf("n60core_upmix: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
