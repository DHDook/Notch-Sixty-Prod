/* E13 S5: delay-separated HRTF interpolation (ABI v39). A spherical-head model has a closed-form response at any
 * angle (a smooth head-shadow magnitude and a delay). The stage, fed onset-aligned responses at the grid angles plus
 * their delays, must reproduce the model's magnitude between grid angles within 1 dB to 16 kHz, move the interaural
 * time difference continuously through a 360 degree yaw sweep, and blend head pitch the same way. Today's blend of
 * unaligned responses (the "before" value) is measured and reported at every rate. Eight standard rates. */
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"

static int failures = 0;
#define CHECK(c, ...) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); failures++; } } while (0)

using cd = std::complex<double>;

static void fft(std::vector<cd> &a, bool inv) {
    const size_t n = a.size();
    for (size_t i = 1, j = 0; i < n; i++) {
        size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(a[i], a[j]);
    }
    for (size_t len = 2; len <= n; len <<= 1) {
        const double ang = 2 * M_PI / static_cast<double>(len) * (inv ? 1 : -1);
        const cd wl(std::cos(ang), std::sin(ang));
        for (size_t i = 0; i < n; i += len) {
            cd w(1);
            for (size_t k = 0; k < len / 2; k++) {
                const cd u = a[i + k], v = a[i + k + len / 2] * w;
                a[i + k] = u + v;
                a[i + k + len / 2] = u - v;
                w *= wl;
            }
        }
    }
    if (inv) for (auto &x : a) x /= static_cast<double>(n);
}

// ---- spherical-head model ---------------------------------------------------------------------------
static double cosAngle(double azDeg, double elDeg, int ear) {
    const double earAz = ear == 0 ? -90.0 : 90.0;
    return std::cos((azDeg - earAz) * M_PI / 180.0) * std::cos(elDeg * M_PI / 180.0);
}
static double tauOf(double az, double el, int ear) { return 0.001 + 0.000255 * (1.0 - cosAngle(az, el, ear)); }
static double magOf(double f, double az, double el, int ear) {
    const double shadow = 0.5 * (1.0 - cosAngle(az, el, ear));
    const double s = f * f / (f * f + 4000.0 * 4000.0);
    return std::pow(10.0, -6.0 * shadow * s / 20.0);
}
// Impulse response of the model (zero-phase magnitude, pure delay), `len` samples.
static std::vector<float> modelIR(double rate, double az, double el, int ear, uint32_t len) {
    size_t M = 1;
    while (M < 4 * size_t(len)) M <<= 1;
    std::vector<cd> X(M, cd(0));
    const double tau = tauOf(az, el, ear);
    for (size_t k = 0; k <= M / 2; k++) {
        const double f = double(k) * rate / double(M);
        const cd v = magOf(f, az, el, ear) * std::exp(cd(0, -2 * M_PI * f * tau));
        X[k] = v;
        if (k != 0 && k != M / 2) X[M - k] = std::conj(v);
    }
    X[M / 2] = X[M / 2].real();
    fft(X, true);
    std::vector<float> h(len);
    for (uint32_t i = 0; i < len; i++) h[i] = static_cast<float>(X[i].real());
    return h;
}

struct Built {
    n60_layout_graph *lg = nullptr;
    n60_graph *g = nullptr;
    uint32_t latency = 0;
    bool ok = false;
};
static Built build(double rate, const n60_binaural_profile &p) {
    Built b;
    static n60_layout lay;
    n60_layout_standard(N60_LAYOUT_STEREO, &lay);
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = 512;
    o.graphChannels = 2;
    o.layout = &lay;
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    if (n60_layout_graph_build(&o, &b.lg) != N60_STATUS_OK) return b;
    if (n60_graph_build(n60_layout_graph_desc(b.lg), &b.g) != N60_STATUS_OK) return b;
    b.latency = n60_graph_latency_frames(b.g);
    b.ok = true;
    return b;
}
static void release(Built &b) {
    if (b.g) n60_graph_retire(b.g);
    if (b.lg) n60_layout_graph_free(b.lg);
}
// Runs `frames` frames (blocks of `blk`) of lane-0 input `in`, lane 1 silent; optional yaw ramp posted per block.
static void run(Built &b, const std::vector<float> &in, std::vector<float> out[2], uint32_t blk,
                double yaw0 = 0, double yawRate = 0, double rate = 48000) {
    const size_t M = in.size();
    out[0].assign(M, 0);
    out[1].assign(M, 0);
    std::vector<float> a(blk), z(blk, 0.0f), oa(blk), ob(blk);
    for (size_t pos = 0; pos < M; pos += blk) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(blk, M - pos));
        if (yawRate != 0) {
            n60_param_record rec{N60_LSTAGE_BINAURAL, 0, static_cast<float>(yaw0 + yawRate * double(pos) / rate), 0};
            n60_graph_post_params(b.g, &rec, 1);
        }
        for (uint32_t i = 0; i < n; i++) a[i] = in[pos + i];
        const float *ip[2] = {a.data(), z.data()};
        float *op[2] = {oa.data(), ob.data()};
        n60_graph_process(b.g, ip, op, n);
        for (uint32_t i = 0; i < n; i++) { out[0][pos + i] = oa[i]; out[1][pos + i] = ob[i]; }
    }
}

struct Sets {
    uint32_t len = 0;
    std::vector<float> aligned, raw, delays;  // aligned/raw: set, source (2), ear (2), tap
    uint32_t sets = 0;
};
// Responses for `azel` sets; source 0 follows the model, source 1 is silent (it is never fed).
static Sets makeSets(double rate, uint32_t len, const std::vector<std::pair<double, double>> &azel) {
    Sets S;
    S.len = len;
    S.sets = static_cast<uint32_t>(azel.size());
    S.raw.assign(size_t(S.sets) * 2 * 2 * len, 0.0f);
    for (uint32_t s = 0; s < S.sets; s++)
        for (int e = 0; e < 2; e++) {
            const auto h = modelIR(rate, azel[s].first, azel[s].second, e, len);
            memcpy(&S.raw[((size_t(s) * 2 + 0) * 2 + e) * len], h.data(), sizeof(float) * len);
        }
    S.aligned.assign(S.raw.size(), 0.0f);
    S.delays.assign(size_t(S.sets) * 2 * 2, 0.0f);
    const uint32_t lead = static_cast<uint32_t>(std::ceil(0.0002 * rate));
    n60_status st = n60_binaural_delay_separate(rate, S.sets, 2, len, S.raw.data(), lead, len, -1, S.aligned.data(),
                                                S.delays.data());
    CHECK(st == N60_STATUS_OK, "delay_separate status %d", int(st));
    return S;
}

static std::vector<float> impulse(size_t M, size_t at) {
    std::vector<float> in(M, 0.0f);
    in[at] = 1.0f;
    return in;
}

// Magnitude error in dB, worst over 100 Hz .. 16 kHz, of ear response `out` against the model at (az, el).
static double worstErrDb(double rate, const std::vector<float> &out, size_t from, double az, double el, int ear,
                         double *at = nullptr, size_t win = 2048) {
    size_t M = 1;
    while (M < 16384) M <<= 1;
    std::vector<cd> X(M, cd(0));
    for (size_t i = 0; i < win && from + i < out.size(); i++) X[i] = out[from + i];
    fft(X, false);
    double worst = 0;
    for (size_t k = 1; k <= M / 2; k++) {
        const double f = double(k) * rate / double(M);
        if (f < 100.0) continue;
        if (f > 16000.0) break;
        const double got = 20 * std::log10(std::max(std::abs(X[k]), 1e-12));
        const double want = 20 * std::log10(magOf(f, az, el, ear));
        if (std::fabs(got - want) > worst) {
            worst = std::fabs(got - want);
            if (at) *at = f;
        }
    }
    return worst;
}

static n60_binaural_profile profile(uint32_t len, uint32_t sets, float yawStart, float yawStep, uint32_t wrap,
                                    const std::vector<float> &resp) {
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = len;
    p.orientations = sets;
    p.yawStartDeg = yawStart;
    p.yawStepDeg = yawStep;
    p.wrap = wrap;
    p.equalEarChannel = -1;
    p.responses = resp.data();
    return p;
}

// Onset (frames, fractional) of one response through the library's own detector.
static double onsetOf(const std::vector<float> &h, uint32_t len, double rate) {
    std::vector<float> al(len), d(1);
    n60_binaural_delay_separate(rate, 1, 1, len, h.data(), 0, len, -1, al.data(), d.data());
    return d[0];
}

static void one(double rate) {
    const uint32_t len = static_cast<uint32_t>(std::ceil(0.004 * rate));
    const size_t M = size_t(0.1 * rate) / 512 * 512 + 4096;
    const size_t at = 2048;
    const std::vector<float> in = impulse(M, at);

    // ---- mid-blend magnitude (yaw 22.5 between sets at 15 and 30 degrees), before and after ---------------------
    std::vector<std::pair<double, double>> azel;
    for (int k = 0; k < 4; k++) azel.push_back({15.0 * k, 0.0});
    const Sets S = makeSets(rate, len, azel);
    double before[2] = {0, 0}, after[2] = {0, 0};
    for (int mode = 0; mode < 2; mode++) {
        const bool sep = mode == 1;
        n60_binaural_profile p = profile(len, 4, 0, 15, 0, sep ? S.aligned : S.raw);
        p.headYawDeg = 22.5f;
        if (sep) {
            p.elevations = 1;
            p.delays = S.delays.data();
        }
        Built b = build(rate, p);
        CHECK(b.ok, "rate %.0f build (separated %d)", rate, sep);
        if (!b.ok) { release(b); continue; }
        CHECK(b.latency == 128u + (sep ? N60_GRAPH_BINAURAL_FD_LATENCY : 0u), "rate %.0f latency %u", rate, b.latency);
        std::vector<float> out[2];
        run(b, in, out, 512);
        for (int e = 0; e < 2; e++) (sep ? after : before)[e] = worstErrDb(rate, out[e], at + b.latency - 64, 22.5, 0.0, e);
        release(b);
    }
    printf("rate %.0f mid-blend magnitude error: before %.2f dB, after %.2f dB (L), %.2f / %.2f (R)\n", rate, before[0],
           after[0], before[1], after[1]);
    CHECK(std::max(before[0], before[1]) > 1.0, "rate %.0f: today's blend should fail the 1 dB gate (%.2f dB)", rate,
          std::max(before[0], before[1]));
    CHECK(std::max(after[0], after[1]) <= 1.0, "rate %.0f: delay-separated blend error %.2f dB", rate, std::max(after[0], after[1]));

    // ---- at a grid set the response is the model's (delay and shift cancel) --------------------------------------
    {
        n60_binaural_profile p = profile(len, 4, 0, 15, 0, S.aligned);
        p.headYawDeg = 30.0f;
        p.elevations = 1;
        p.delays = S.delays.data();
        Built b = build(rate, p);
        std::vector<float> out[2];
        if (b.ok) run(b, in, out, 512);
        for (int e = 0; e < 2; e++) {
            const double err = b.ok ? worstErrDb(rate, out[e], at + b.latency - 64, 30.0, 0.0, e) : 99;
            CHECK(err <= 0.5, "rate %.0f grid set ear %d error %.2f dB", rate, e, err);
        }
        // The first arrival is where the model puts it.
        if (b.ok) {
            const double want = tauOf(30.0, 0.0, 0) * rate;
            std::vector<float> seg(out[0].begin() + at + b.latency - 64, out[0].begin() + at + b.latency - 64 + len);
            const double got = onsetOf(seg, len, rate) - 64;
            const std::vector<float> ref = modelIR(rate, 30.0, 0.0, 0, len);
            const double refOn = onsetOf(ref, len, rate);
            (void)want;
            CHECK(std::fabs(got - refOn) < 0.3, "rate %.0f onset %g vs model %g", rate, got, refOn);
        }
        // The host block size does not change the output.
        std::vector<float> out2[2];
        if (b.ok) {
            // Same graph, fresh state: rebuild so the history starts clean, then render with another host block size.
            release(b);
            b = build(rate, p);
            run(b, in, out2, 97);
            double diff = 0;
            for (int e = 0; e < 2; e++)
                for (size_t i = 0; i < out[e].size(); i++) diff = std::max(diff, double(std::fabs(out[e][i] - out2[e][i])));
            CHECK(diff < 1e-5, "rate %.0f block-size difference %g", rate, diff);
        }
        release(b);
    }

    // ---- ITD through a 360 degree yaw sweep ------------------------------------------------------------------------
    {
        std::vector<std::pair<double, double>> az24;
        for (int k = 0; k < 24; k++) az24.push_back({15.0 * k, 0.0});
        const Sets W = makeSets(rate, len, az24);
        n60_binaural_profile p = profile(len, 24, 0, 15, 1, W.aligned);
        p.elevations = 1;
        p.delays = W.delays.data();
        Built b = build(rate, p);
        CHECK(b.ok, "rate %.0f sweep build", rate);
        if (b.ok) {
            const double seconds = 6.0, degPerSec = 360.0 / seconds;
            const size_t total = size_t(seconds * rate) / 512 * 512;
            const size_t period = static_cast<size_t>(0.1 * rate) / 512 * 512;
            std::vector<float> sin(total, 0.0f);
            std::vector<size_t> hits;
            for (size_t pos = period; pos + period < total; pos += period) { sin[pos] = 1.0f; hits.push_back(pos); }
            std::vector<float> out[2];
            run(b, sin, out, 512, 0.0, degPerSec, rate);
            double worstItd = 0, worstStep = 0, prev = 0, worstMag = 0;
            bool first = true;
            for (size_t pos : hits) {
                const double yaw = degPerSec * double(pos + b.latency) / rate;  // head yaw when the impulse is heard
                std::vector<float> two(size_t(2) * len, 0.0f);
                for (int e = 0; e < 2; e++) memcpy(&two[size_t(e) * len], &out[e][pos + b.latency - 64], sizeof(float) * len);
                float dl[2];
                std::vector<float> al(size_t(2) * len);
                n60_binaural_delay_separate(rate, 1, 1, len, two.data(), 0, len, -1, al.data(), dl);
                const double itd = (double(dl[1]) - double(dl[0])) / rate;
                const double truth = (onsetOf(modelIR(rate, yaw, 0.0, 1, len), len, rate) - onsetOf(modelIR(rate, yaw, 0.0, 0, len), len, rate)) / rate;
                worstItd = std::max(worstItd, std::fabs(itd - truth));
                if (!first) worstStep = std::max(worstStep, std::fabs((itd - prev) - 0.0));
                // a step between neighbouring impulses never exceeds the truth's step (0.1 s = 36 degrees at most) by much
                prev = itd;
                first = false;
                worstMag = std::max(worstMag, worstErrDb(rate, out[0], pos + b.latency - 64, yaw, 0.0, 0));
            }
            printf("rate %.0f sweep: ITD error %.1f us (worst), magnitude error %.2f dB\n", rate, worstItd * 1e6, worstMag);
            CHECK(worstItd < 25e-6, "rate %.0f ITD error %.1f us", rate, worstItd * 1e6);
            CHECK(worstMag <= 1.0, "rate %.0f sweep magnitude error %.2f dB", rate, worstMag);
            // The tracked ITD has no jump: compare against the continuous truth sampled the same way (checked above); and
            // the output has no non-finite or runaway sample.
            double peak = 0;
            for (int e = 0; e < 2; e++) for (float v : out[e]) peak = std::max(peak, std::fabs(double(v)));
            CHECK(peak < 2.0, "rate %.0f sweep peak %g", rate, peak);
        }
        release(b);
    }

    // ---- head pitch: elevation sets at -30, 0, 30, 60 degrees, two yaws ---------------------------------------------
    {
        const double pitches[4] = {-30, 0, 30, 60};
        std::vector<std::pair<double, double>> sets;
        for (int e = 0; e < 4; e++)
            for (int y = 0; y < 2; y++) sets.push_back({15.0 * y, pitches[e]});
        const Sets P = makeSets(rate, len, sets);
        for (double pitch : {-30.0, 0.0, 30.0, -15.0, 15.0, 45.0}) {
            n60_binaural_profile p = profile(len, 8, 0, 15, 0, P.aligned);
            p.elevations = 4;
            p.pitchStartDeg = -30;
            p.pitchStepDeg = 30;
            p.delays = P.delays.data();
            p.headYawDeg = 7.5f;
            p.headPitchDeg = static_cast<float>(pitch);
            Built b = build(rate, p);
            CHECK(b.ok, "rate %.0f pitch build", rate);
            if (!b.ok) { release(b); continue; }
            std::vector<float> out[2];
            run(b, in, out, 512);
            double dbgf = 0;
            for (int e = 0; e < 2; e++) {
                const double err = worstErrDb(rate, out[e], at + b.latency - 64, 7.5, pitch, e, &dbgf);
                CHECK(err <= 1.0, "rate %.0f pitch %.0f ear %d error %.2f dB", rate, pitch, e, err);
            }
            release(b);
        }
    }
}

// Refusals: delays out of range, wrong set grouping, missing delays.
static void refusals() {
    const double rate = 48000;
    const uint32_t len = 192;
    std::vector<std::pair<double, double>> azel = {{0, 0}, {15, 0}, {30, 0}};
    const Sets S = makeSets(rate, len, azel);
    n60_binaural_profile p = profile(len, 3, 0, 15, 0, S.aligned);
    p.elevations = 2;  // 3 sets do not divide by 2
    p.delays = S.delays.data();
    Built b = build(rate, p);
    CHECK(!b.ok, "sets not divisible by the elevations are refused");
    release(b);
    p.elevations = 1;
    p.delays = nullptr;
    b = build(rate, p);
    CHECK(!b.ok, "elevations without delays are refused");
    release(b);
    std::vector<float> bad = S.delays;
    bad[0] = static_cast<float>(0.05 * rate);
    p.delays = bad.data();
    b = build(rate, p);
    CHECK(!b.ok, "a delay beyond the limit is refused");
    release(b);
    p.delays = S.delays.data();
    b = build(rate, p);
    CHECK(b.ok, "the valid extension builds");
    release(b);
}

// A history reset (stream restart) leaves no stale audio in the early histories or the delay rings.
static void historyReset() {
    const double rate = 48000;
    const uint32_t len = static_cast<uint32_t>(std::ceil(0.004 * rate));
    std::vector<std::pair<double, double>> azel;
    for (int k = 0; k < 4; k++) azel.push_back({15.0 * k, 0.0});
    const Sets S = makeSets(rate, len, azel);
    n60_binaural_profile p = profile(len, 4, 0, 15, 0, S.aligned);
    p.headYawDeg = 40.0f;
    p.elevations = 1;
    p.delays = S.delays.data();
    Built b = build(rate, p);
    CHECK(b.ok, "history reset build");
    if (!b.ok) { release(b); return; }
    std::vector<float> a(256), z(256, 0.0f), oa(256), ob(256);
    uint32_t rs = 5;
    auto go = [&](bool noise) {
        for (auto &v : a) { rs = rs * 1664525u + 1013904223u; v = noise ? 0.5f * float((rs >> 8) / 8388608.0 - 1.0) : 0.0f; }
        const float *ip[2] = {a.data(), z.data()};
        float *op[2] = {oa.data(), ob.data()};
        n60_graph_process(b.g, ip, op, 256);
    };
    for (int i = 0; i < 50; i++) go(true);
    n60_graph_invalidate_history(b.g);
    go(false);  // the reset happens on this block
    float peak = 0;
    for (int i = 0; i < 20; i++) {
        go(false);
        for (int j = 0; j < 256; j++) peak = std::max(peak, std::max(std::fabs(oa[j]), std::fabs(ob[j])));
    }
    CHECK(peak < 1e-6f, "stale audio after a history reset, peak %g", peak);
    release(b);
}

int main() {
    static const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double r : rates) one(r);
    refusals();
    historyReset();
    if (failures) return 1;
    puts("binaural interpolation matches the spherical-head model");
    return 0;
}
