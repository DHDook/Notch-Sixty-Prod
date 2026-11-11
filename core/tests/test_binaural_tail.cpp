/* E13 S4: the shared late tail of a long BRIR. A 1.0 s (and a 0.5 s) response, split 20 ms after the onset into
 * the per-orientation early part and the multirate tail, renders within -60 dB (band-limited to 20 kHz) of an
 * offline FFT convolution of the whole response at the eight standard rates; the host block size does not change
 * the output; the stage latency stays at 128 frames. */
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
static uint32_t rs = 11;
static float frand() { rs = rs * 1664525u + 1013904223u; return static_cast<float>((rs >> 8) / 8388608.0 - 1.0); }

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

struct Render {
    std::vector<float> out[2];
    uint32_t latency = 0;
    bool ok = false;
};

static Render render(double rate, uint32_t E, uint32_t T, const std::vector<float> &early, const std::vector<float> &tail,
                     const std::vector<float> &in0, const std::vector<float> &in1, uint32_t B) {
    Render R;
    n60_layout lay;
    n60_layout_standard(N60_LAYOUT_STEREO, &lay);
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = E;
    p.orientations = 1;
    p.equalEarChannel = -1;
    p.responses = early.data();
    p.tailTaps = T;
    p.tailResponses = tail.data();
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = 512;
    o.graphChannels = 2;
    o.layout = &lay;
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    n60_layout_graph *lg = nullptr;
    n60_graph *g = nullptr;
    if (n60_layout_graph_build(&o, &lg) != N60_STATUS_OK) return R;
    if (n60_graph_build(n60_layout_graph_desc(lg), &g) != N60_STATUS_OK) { n60_layout_graph_free(lg); return R; }
    R.latency = n60_graph_latency_frames(g);
    const size_t M = in0.size();
    R.out[0].assign(M, 0);
    R.out[1].assign(M, 0);
    std::vector<float> a(B), b(B), oa(B), ob(B);
    for (size_t pos = 0; pos < M; pos += B) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(B, M - pos));
        for (uint32_t i = 0; i < n; i++) { a[i] = in0[pos + i]; b[i] = in1[pos + i]; }
        const float *ip[2] = {a.data(), b.data()};
        float *op[2] = {oa.data(), ob.data()};
        n60_graph_process(g, ip, op, n);
        for (uint32_t i = 0; i < n; i++) { R.out[0][pos + i] = oa[i]; R.out[1][pos + i] = ob[i]; }
    }
    n60_graph_retire(g);
    n60_layout_graph_free(lg);
    R.ok = true;
    return R;
}

// Brick-wall low-pass at 20 kHz through the FFT, in place (x.size() is a power of two).
static void lowpass20k(std::vector<cd> &x, double rate) {
    const size_t S = x.size(), cut = static_cast<size_t>(20000.0 / rate * static_cast<double>(S));
    fft(x, false);
    for (size_t k = cut + 1; k + cut + 1 <= S; k++) x[k] = 0;
    fft(x, true);
}

static void one(double rate, double seconds) {
    const uint32_t L = static_cast<uint32_t>(rate * seconds), E = static_cast<uint32_t>(rate * 0.02), T = L - E;
    // h[src][ear]: decaying noise (about -60 dB at the end), so the tail matters.
    std::vector<float> h[2][2], early(2 * 2 * size_t(E)), tail(2 * 2 * size_t(T));
    for (int k = 0; k < 2; k++)
        for (int e = 0; e < 2; e++) {
            h[k][e].resize(L);
            for (uint32_t t = 0; t < L; t++)
                h[k][e][t] = 0.2f * frand() * std::exp(-6.9f * static_cast<float>(t) / static_cast<float>(L) * 1.0f) *
                             (t < 64 ? 1.0f : 0.3f);
            memcpy(&early[(size_t(k) * 2 + e) * E], h[k][e].data(), sizeof(float) * E);
            memcpy(&tail[(size_t(k) * 2 + e) * T], h[k][e].data() + E, sizeof(float) * T);
        }
    const size_t M = static_cast<size_t>(rate * (seconds + 0.25));
    std::vector<float> in0(M), in1(M);
    {   // program material is band-limited to 20 kHz
        size_t P = 1;
        while (P < M) P <<= 1;
        for (auto *in : {&in0, &in1}) {
            std::vector<cd> x(P, cd(0));
            for (size_t i = 0; i < M; i++) x[i] = frand();
            lowpass20k(x, rate);
            for (size_t i = 0; i < M; i++) (*in)[i] = 0.3f * static_cast<float>(x[i].real());
        }
    }
    Render r = render(rate, E, T, early, tail, in0, in1, 512);
    CHECK(r.ok, "rate %.0f build", rate);
    if (!r.ok) return;
    CHECK(r.latency == 128, "rate %.0f latency %u", rate, r.latency);
    Render r2 = render(rate, E, T, early, tail, in0, in1, 97);
    double blk = 0;
    for (int e = 0; e < 2; e++)
        for (size_t i = 0; i < M; i++) blk = std::fmax(blk, std::fabs(r.out[e][i] - r2.out[e][i]));
    CHECK(r2.ok && blk < 2e-5, "rate %.0f block-size difference %g", rate, blk);

    size_t S = 1;
    while (S < M + L + 128) S <<= 1;
    auto lowpass = [&](std::vector<cd> &x) { lowpass20k(x, rate); };
    double errE = 0, refE = 0;
    for (int e = 0; e < 2; e++) {
        std::vector<cd> acc(S, cd(0));
        for (int k = 0; k < 2; k++) {
            std::vector<cd> X(S, cd(0)), H(S, cd(0));
            const std::vector<float> &in = k == 0 ? in0 : in1;
            for (size_t i = 0; i < M; i++) X[i] = in[i];
            for (uint32_t t = 0; t < L; t++) H[t] = h[k][e][t];
            fft(X, false);
            fft(H, false);
            for (size_t i = 0; i < S; i++) acc[i] += X[i] * H[i];
        }
        fft(acc, true);
        std::vector<cd> ref(S, cd(0)), got(S, cd(0));
        for (size_t i = 0; i + 128 < M; i++) ref[i + 128] = acc[i];
        for (size_t i = 0; i < M; i++) got[i] = r.out[e][i];
        for (size_t i = M; i < S; i++) ref[i] = 0;
        lowpass(ref);
        lowpass(got);
        for (size_t i = 0; i < M; i++) {
            refE += std::norm(ref[i]);
            errE += std::norm(got[i] - ref[i]);
        }
    }
    const double db = 10 * std::log10(errE / refE + 1e-30);
    CHECK(db < -60.0, "rate %.0f %.1f s: error %.1f dB", rate, seconds, db);
    printf("rate %.0f %.1f s: %.1f dB\n", rate, seconds, db);
}

// A history reset (stream restart) must leave no stale audio ringing out of the tail.
static void epochReset() {
    const double rate = 48000;
    const uint32_t E = 960, T = 47040;
    std::vector<float> early(size_t(2) * E, 0.0f), tail(size_t(2) * T);
    early[0] = 1.0f;
    early[E] = 1.0f;
    for (auto &v : tail) v = 0.2f * frand();
    n60_layout lay;
    n60_layout_standard(N60_LAYOUT_STEREO, &lay);
    n60_binaural_profile p;
    memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = E;
    p.orientations = 1;
    p.equalEarChannel = -1;
    p.responses = early.data();
    p.tailTaps = T;
    p.tailResponses = tail.data();
    n60_layout_options o;
    memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = 512;
    o.graphChannels = 2;
    o.layout = &lay;
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    n60_layout_graph *lg = nullptr;
    n60_graph *g = nullptr;
    if (n60_layout_graph_build(&o, &lg) != N60_STATUS_OK || n60_graph_build(n60_layout_graph_desc(lg), &g) != N60_STATUS_OK) {
        puts("epoch test: build failed");
        failures++;
        return;
    }
    std::vector<float> a(256), b(256), oa(256), ob(256);
    auto run = [&](bool noise) {
        for (auto &v : a) v = noise ? 0.5f * frand() : 0.0f;
        for (auto &v : b) v = noise ? 0.5f * frand() : 0.0f;
        const float *ip[2] = {a.data(), b.data()};
        float *op[2] = {oa.data(), ob.data()};
        n60_graph_process(g, ip, op, 256);
    };
    for (int i = 0; i < 200; i++) run(true);
    n60_graph_invalidate_history(g);
    float peak = 0.0f;
    for (int i = 0; i < 400; i++) {
        run(false);
        if (i >= 250) for (int j = 0; j < 256; j++) peak = std::max(peak, std::max(std::fabs(oa[j]), std::fabs(ob[j])));
    }
    if (!(peak < 1.0e-4f)) {
        printf("epoch test: stale audio after a history reset, peak %g\n", peak);
        failures++;
    }
    n60_graph_retire(g);
    n60_layout_graph_free(lg);
}

int main() {
    static const double rates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
    for (double r : rates) one(r, 1.0);
    one(352800, 0.5);
    one(384000, 0.5);
    epochReset();
    if (failures) return 1;
    puts("binaural long tail matches the offline reference");
    return 0;
}
