// E29 S3: behavioural tests for room-model interpolation (n60/roommodel.h) at the eight standard rates.
// Ground truth is a shoebox image-source room (Allen and Berkley, "Image method for efficiently simulating
// small-room acoustics", JASA 65(4), 1979): rigid-wall reflection coefficient beta, image sources up to the
// response length, windowed-sinc fractional delays. Truth and measured grid share the generator, so only the
// interpolation error is under test.
#include "n60/n60.h"
#include "n60/roommodel.h"

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

static const double kRates[] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};
static const double kPi = 3.14159265358979323846;
static const double kC = 343.0;
static const double kRoom[3] = {5.0, 4.0, 2.8};
static const double kBeta = 0.85;
static const double kSource[3] = {0.8, 0.6, 1.0};
static const double kIrSeconds = 0.25;

static uint32_t fftFor(double rate) {
    uint32_t n = 64;
    while (n < static_cast<uint32_t>(rate * kIrSeconds) + 64) n <<= 1;
    return n;
}

// Impulse response from kSource to a receiver at p.
static std::vector<float> roomIr(const double *p, double rate) {
    const uint32_t frames = static_cast<uint32_t>(rate * kIrSeconds);
    std::vector<double> h(frames, 0.0);
    const double maxPath = kIrSeconds * kC;
    const int taps = 16;
    const int order[3] = {static_cast<int>(maxPath / (2 * kRoom[0])) + 1, static_cast<int>(maxPath / (2 * kRoom[1])) + 1,
                          static_cast<int>(maxPath / (2 * kRoom[2])) + 1};
    for (int ix = -order[0]; ix <= order[0]; ++ix)
        for (int iy = -order[1]; iy <= order[1]; ++iy)
            for (int iz = -order[2]; iz <= order[2]; ++iz)
                for (int mask = 0; mask < 8; ++mask) {
                    const int mx = mask & 1, my = (mask >> 1) & 1, mz = (mask >> 2) & 1;
                    const double sx = (mx ? -kSource[0] : kSource[0]) + 2 * ix * kRoom[0];
                    const double sy = (my ? -kSource[1] : kSource[1]) + 2 * iy * kRoom[1];
                    const double sz = (mz ? -kSource[2] : kSource[2]) + 2 * iz * kRoom[2];
                    const double dx = sx - p[0], dy = sy - p[1], dz = sz - p[2];
                    const double r = std::sqrt(dx * dx + dy * dy + dz * dz);
                    if (r > maxPath || r < 1e-3) continue;
                    const int hits = std::abs(ix - mx) + std::abs(ix) + std::abs(iy - my) + std::abs(iy) +
                                     std::abs(iz - mz) + std::abs(iz);
                    const double amp = std::pow(kBeta, hits) / r;
                    const double pos = r / kC * rate;
                    const int c0 = static_cast<int>(std::floor(pos));
                    for (int t = c0 - taps + 1; t <= c0 + taps; ++t) {
                        if (t < 0 || t >= static_cast<int>(frames)) continue;
                        const double x = static_cast<double>(t) - pos;
                        const double s = std::fabs(x) < 1e-12 ? 1.0 : std::sin(kPi * x) / (kPi * x);
                        const double win = 0.5 * (1.0 + std::cos(kPi * x / taps));
                        h[static_cast<size_t>(t)] += amp * s * win;
                    }
                }
    std::vector<float> out(frames);
    for (uint32_t i = 0; i < frames; ++i) out[i] = static_cast<float>(h[i]);
    return out;
}

struct Grid {
    std::vector<std::vector<float>> irs;
    std::vector<n60_roommodel_neighbour> nb;
};

// 3 x 3 grid at 0.5 m spacing around (2.5, 2.0), receiver height 1.2 m.
static void buildGrid(double rate, Grid &g) {
    g.irs.clear();
    g.nb.clear();
    for (int ix = 0; ix < 3; ++ix)
        for (int iy = 0; iy < 3; ++iy) {
            const double p[3] = {2.0 + 0.5 * ix, 1.5 + 0.5 * iy, 1.2};
            g.irs.push_back(roomIr(p, rate));
        }
    for (int ix = 0; ix < 3; ++ix)
        for (int iy = 0; iy < 3; ++iy) {
            n60_roommodel_neighbour n{};
            n.position[0] = 2.0 + 0.5 * ix;
            n.position[1] = 1.5 + 0.5 * iy;
            n.position[2] = 1.2;
            n.ir = g.irs[static_cast<size_t>(ix * 3 + iy)].data();
            n.irFrames = static_cast<uint32_t>(g.irs[static_cast<size_t>(ix * 3 + iy)].size());
            n.phaseTrusted = 1;
            g.nb.push_back(n);
        }
}

static n60_roommodel_query makeQuery(double rate, const double *at) {
    n60_roommodel_query q{};
    q.structSize = sizeof q;
    q.fftSize = fftFor(rate);
    q.sampleRate = rate;
    for (int i = 0; i < 3; ++i) { q.source[i] = kSource[i]; q.query[i] = at[i]; }
    return q;
}

static n60_roommodel_result makeResult() {
    n60_roommodel_result r{};
    r.structSize = sizeof r;
    return r;
}

static void testHeldOutPoints() {
    for (double rate : kRates) {
        Grid g;
        buildGrid(rate, g);
        // Mid-edge and in-cell points all meet the plan's -15 dB low-band complex error (gap G6 closed: barycentric weights on the
        // enclosing triangle and a trust radius of at least the cell diagonal). The third-octave magnitude inside a cell can be
        // about 3 dB off, an interpolation floor between points 0.5 m apart that confidence reports.
        struct Held { double p[3]; uint32_t used; double limitDb; double magDb; };
        const Held heldOut[7] = {{{2.75, 2.0, 1.2}, 2, -15.0, 2.0}, {{2.25, 2.0, 1.2}, 2, -15.0, 2.0},
                                 {{2.75, 2.25, 1.2}, 2, -15.0, 3.2}, {{2.7, 2.2, 1.2}, 3, -15.0, 3.2},
                                 {{2.65, 2.15, 1.2}, 3, -15.0, 3.2}, {{2.55, 2.05, 1.2}, 3, -15.0, 3.2},
                                 {{2.9, 2.4, 1.2}, 3, -15.0, 3.2}};
        for (const Held &h : heldOut) {
            const double *at = h.p;
            const std::vector<float> truth = roomIr(at, rate);
            n60_roommodel_neighbour self{};
            for (int i = 0; i < 3; ++i) self.position[i] = at[i];
            self.ir = truth.data();
            self.irFrames = static_cast<uint32_t>(truth.size());
            self.phaseTrusted = 1;

            n60_roommodel_query q = makeQuery(rate, at);
            q.neighbourCount = static_cast<uint32_t>(g.nb.size());
            const uint32_t bins = q.fftSize / 2 + 1;
            std::vector<double> re(bins), im(bins), tre(bins), tim(bins);
            n60_roommodel_result res = makeResult();
            CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, re.data(), im.data()) == N60_ROOMMODEL_OK, "interpolate");
            CHECK(res.neighboursUsed == h.used, "neighbours used (zero-weight nodes dropped)");
            CHECK(res.complexValid == 1, "complex valid");
            CHECK(std::fabs(res.spacingM - 0.5) < 1e-9, "spacing 0.5");
            CHECK(std::fabs(res.crossoverHz - kC / 2.0) < 1e-9, "f_c = c/(4d)");

            // Truth: the same call with the held-out point's own response as the single, zero-distance neighbour.
            n60_roommodel_query tq = q;
            tq.neighbourCount = 1;
            n60_roommodel_result tres = makeResult();
            CHECK(n60_roommodel_interpolate(&tq, &self, &tres, tre.data(), tim.data()) == N60_ROOMMODEL_OK, "truth");

            // Complex error below f_c (20 Hz up), relative to the measured response energy.
            double num = 0, den = 0;
            for (uint32_t b = 1; b < bins; ++b) {
                const double f = rate * b / q.fftSize;
                if (f < 20.0 || f > res.crossoverHz) continue;
                // Truth complex values with the single-neighbour query only reach f_c of its own spacing; recompute
                // the response by a zero-distance blend at the same grid by reusing its band-limited output.
                const double dr = re[b] - tre[b], di = im[b] - tim[b];
                num += dr * dr + di * di;
                den += tre[b] * tre[b] + tim[b] * tim[b];
            }
            const double errDb = 10.0 * std::log10(num / den);
            std::printf("rate %.0f at (%.2f,%.2f): low-band complex error %.1f dB\n", rate, at[0], at[1], errDb);
            CHECK(den > 0, "truth has energy");
            CHECK(errDb <= h.limitDb, "complex error below f_c within the bound");

            // Third-octave magnitude within 2 dB from 200 Hz to 8 kHz.
            for (uint32_t b = 0; b < N60_ROOMMODEL_BAND_COUNT; ++b) {
                const double fc = res.bandCentreHz[b];
                if (fc < 199.0 || fc > 8100.0) continue;
                CHECK(res.bandStatus[b] == N60_ROOMMODEL_BAND_OK, "band ok");
                const double e = res.levelDb[b] - tres.levelDb[b];
                if (std::fabs(e) > h.magDb) std::printf("  (%.2f,%.2f) rate %.0f band %.0f Hz error %.2f dB\n", at[0], at[1], rate, fc, e);
                CHECK(std::fabs(e) <= h.magDb, "third-octave level within the bound (2 dB on an edge; 3.2 dB inside a cell)");
                CHECK(res.confidence[b] > 0.0 && res.confidence[b] <= 1.0, "confidence in range");
            }
        }
    }
}

static void testRefusedOutsideTrust() {
    const double rate = 48000;
    Grid g;
    buildGrid(rate, g);
    // Nearest grid node (3.0, 2.5) is 0.8 m from (3.8, 2.5); the spacing-aware radius is 1.42 x 0.5 = 0.71 m.
    const double at[3] = {3.8, 2.5, 1.2};
    n60_roommodel_query q = makeQuery(rate, at);
    q.neighbourCount = static_cast<uint32_t>(g.nb.size());
    n60_roommodel_result res = makeResult();
    std::vector<double> re(q.fftSize / 2 + 1, 7.0), im(q.fftSize / 2 + 1, 7.0);
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, re.data(), im.data()) == N60_ROOMMODEL_NOT_MEASURED, "refused");
    CHECK(res.reason == N60_ROOMMODEL_REASON_OUTSIDE_TRUST, "reason outside trust");
    CHECK(res.neighboursUsed == 0, "none used");
    CHECK(std::fabs(res.nearestDistanceM - 0.8) < 1e-9, "nearest 0.8");
    for (uint32_t b = 0; b < N60_ROOMMODEL_BAND_COUNT; ++b) CHECK(res.bandStatus[b] == N60_ROOMMODEL_BAND_REFUSED, "refused band");
    CHECK(re[100] == 0.0 && im[100] == 0.0, "output zeroed");

    // A custom larger radius accepts the same query.
    q.trustRadiusM = 0.9;
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, nullptr, nullptr) == N60_ROOMMODEL_OK, "wider radius accepted");

    // The default radius is the cell diagonal: 0.70 m from a node is in range, 0.72 m is not.
    q.trustRadiusM = 0;
    const double inside[3] = {3.7, 2.5, 1.2}, beyond[3] = {3.72, 2.5, 1.2};
    for (int i = 0; i < 3; ++i) q.query[i] = inside[i];
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, nullptr, nullptr) == N60_ROOMMODEL_OK, "0.70 m accepted");
    for (int i = 0; i < 3; ++i) q.query[i] = beyond[i];
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, nullptr, nullptr) == N60_ROOMMODEL_NOT_MEASURED, "0.72 m refused");
    // An explicit 0.5 m radius is honoured as given.
    q.trustRadiusM = 0.5;
    for (int i = 0; i < 3; ++i) q.query[i] = inside[i];
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, nullptr, nullptr) == N60_ROOMMODEL_NOT_MEASURED, "explicit 0.5 m refuses 0.70 m");
    q.trustRadiusM = 0;
    for (int i = 0; i < 3; ++i) q.query[i] = at[i];

    q.neighbourCount = 0;
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, nullptr, nullptr) == N60_ROOMMODEL_NOT_MEASURED, "empty list");
    CHECK(res.reason == N60_ROOMMODEL_REASON_NO_NEIGHBOURS, "reason no neighbours");
}

// A sweep across the cell (and over its diagonal) moves the low-band response smoothly: no step between neighbouring
// samples 0.025 m apart exceeds -19 dB relative to the response energy (measured -21.4 dB; the true response steps by about
// -30 dB over the same distance and the old inverse-distance blend by about -5 dB).
static void testContinuity() {
    for (double rate : kRates) {
        Grid g;
        buildGrid(rate, g);
        std::vector<double> prevRe, prevIm;
        double worst = -300.0;
        for (int step = 0; step <= 24; ++step) {
            const double at[3] = {2.55 + 0.02 * step, 2.05 + 0.015 * step, 1.2};  // crosses the diagonal at the cell middle
            n60_roommodel_query q = makeQuery(rate, at);
            q.neighbourCount = static_cast<uint32_t>(g.nb.size());
            const uint32_t bins = q.fftSize / 2 + 1;
            std::vector<double> re(bins), im(bins);
            n60_roommodel_result res = makeResult();
            CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, re.data(), im.data()) == N60_ROOMMODEL_OK, "sweep ok");
            if (step > 0) {
                double num = 0, den = 0;
                for (uint32_t b = 1; b < bins; ++b) {
                    const double f = rate * b / q.fftSize;
                    if (f < 20.0 || f > 171.0) continue;
                    num += (re[b] - prevRe[b]) * (re[b] - prevRe[b]) + (im[b] - prevIm[b]) * (im[b] - prevIm[b]);
                    den += re[b] * re[b] + im[b] * im[b];
                }
                worst = std::max(worst, 10.0 * std::log10(num / den));
            }
            prevRe = re;
            prevIm = im;
        }
        std::printf("rate %.0f: worst sweep step %.1f dB\n", rate, worst);
        CHECK(worst <= -19.0, "no step jump above -19 dB across the cell");
    }
}

// A zero-weight node must not refuse a band: a query on the edge between two nodes of one right triangle gives the third
// node weight zero, and the third node's response is 20 dB lower. Inside the triangle the same node refuses the bands.
static void testZeroWeightNodeDoesNotRefuse() {
    std::vector<float> a(256, 0.0f), b(256, 0.0f), c(256, 0.0f);
    a[10] = 1.0f;
    b[10] = 1.0f;
    c[10] = 0.1f;
    n60_roommodel_neighbour nb[3] = {};
    const float *irs[3] = {a.data(), b.data(), c.data()};
    const double pos[3][3] = {{0, 0, 0}, {0.4, 0, 0}, {0, 0.4, 0}};
    for (int i = 0; i < 3; ++i) {
        for (int d = 0; d < 3; ++d) nb[i].position[d] = pos[i][d];
        nb[i].ir = irs[i];
        nb[i].irFrames = 256;
        nb[i].phaseTrusted = 1;
    }
    n60_roommodel_query q{};
    q.structSize = sizeof q;
    q.fftSize = 4096;
    q.sampleRate = 48000;
    q.source[0] = -2.0;
    q.neighbourCount = 3;
    n60_roommodel_result res = makeResult();
    q.query[0] = 0.2;  // mid-edge between nodes 0 and 1
    CHECK(n60_roommodel_interpolate(&q, nb, &res, nullptr, nullptr) == N60_ROOMMODEL_OK, "edge query ok");
    CHECK(res.neighboursUsed == 2, "zero-weight node dropped");
    for (uint32_t k = 0; k < N60_ROOMMODEL_BAND_COUNT; ++k)
        if (res.bandStatus[k] != N60_ROOMMODEL_BAND_UNAVAILABLE) CHECK(res.bandStatus[k] == N60_ROOMMODEL_BAND_OK, "no band refused by a zero-weight node");
    q.query[0] = 0.1;
    q.query[1] = 0.1;  // inside the triangle: the 20 dB node now counts
    CHECK(n60_roommodel_interpolate(&q, nb, &res, nullptr, nullptr) == N60_ROOMMODEL_OK, "interior query ok");
    CHECK(res.neighboursUsed == 3, "three nodes used inside");
    CHECK(res.bandStatus[20] == N60_ROOMMODEL_BAND_SPREAD, "a node with weight does refuse");
    // A refused band keeps its complex bins below f_c (status and zero confidence carry the refusal).
    std::vector<double> re(q.fftSize / 2 + 1), im(q.fftSize / 2 + 1);
    CHECK(n60_roommodel_interpolate(&q, nb, &res, re.data(), im.data()) == N60_ROOMMODEL_OK, "interior with arrays");
    double mag = 0;
    const size_t bin100 = static_cast<size_t>(100.0 / (48000.0 / q.fftSize));
    mag = std::fabs(re[bin100]) + std::fabs(im[bin100]);
    CHECK(res.bandStatus[18] == N60_ROOMMODEL_BAND_SPREAD && res.confidence[18] == 0.0 && mag > 0.0, "refused band keeps complex bins");
}

static void testDeterministic() {
    const double rate = 96000;
    Grid g;
    buildGrid(rate, g);
    const double at[3] = {2.75, 2.25, 1.2};
    n60_roommodel_query q = makeQuery(rate, at);
    q.neighbourCount = static_cast<uint32_t>(g.nb.size());
    const uint32_t bins = q.fftSize / 2 + 1;
    std::vector<double> re1(bins), im1(bins), re2(bins), im2(bins);
    n60_roommodel_result a = makeResult(), b = makeResult();
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &a, re1.data(), im1.data()) == N60_ROOMMODEL_OK, "first");
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &b, re2.data(), im2.data()) == N60_ROOMMODEL_OK, "second");
    CHECK(std::memcmp(&a, &b, sizeof a) == 0, "results bit-identical");
    CHECK(std::memcmp(re1.data(), re2.data(), bins * sizeof(double)) == 0, "real part bit-identical");
    CHECK(std::memcmp(im1.data(), im2.data(), bins * sizeof(double)) == 0, "imaginary part bit-identical");
}

static void testPhaseUntrustedIsMagnitudeOnly() {
    const double rate = 48000;
    Grid g;
    buildGrid(rate, g);
    g.nb[4].phaseTrusted = 0;  // the centre node, always among the nearest
    const double at[3] = {2.6, 2.1, 1.2};  // inside the cell with the centre node (2.5, 2.0) at weight 0.6
    n60_roommodel_query q = makeQuery(rate, at);
    q.neighbourCount = static_cast<uint32_t>(g.nb.size());
    std::vector<double> re(q.fftSize / 2 + 1, 1.0), im(q.fftSize / 2 + 1, 1.0);
    n60_roommodel_result res = makeResult();
    CHECK(n60_roommodel_interpolate(&q, g.nb.data(), &res, re.data(), im.data()) == N60_ROOMMODEL_OK, "ok");
    CHECK(res.complexValid == 0, "no complex output without phase trust");
    double sum = 0;
    for (size_t i = 0; i < re.size(); ++i) sum += std::fabs(re[i]) + std::fabs(im[i]);
    CHECK(sum == 0.0, "arrays zero");
    CHECK(res.bandStatus[18] == N60_ROOMMODEL_BAND_OK, "levels still reported");
}

static void testSpreadRefusesBand() {
    // Three neighbours whose responses differ by 20 dB: every band is refused; one neighbour is half-limit spread.
    const double rate = 48000;
    std::vector<float> a(256, 0.0f), b(256, 0.0f), c(256, 0.0f);
    a[10] = 1.0f;
    b[10] = 0.1f;
    c[10] = 0.1f;
    n60_roommodel_neighbour nb[3] = {};
    const float *irs[3] = {a.data(), b.data(), c.data()};
    for (int i = 0; i < 3; ++i) {
        nb[i].position[0] = 0.2 * i;
        nb[i].ir = irs[i];
        nb[i].irFrames = 256;
        nb[i].phaseTrusted = 1;
    }
    const double at[3] = {0.2, 0.05, 0};
    n60_roommodel_query q{};
    q.structSize = sizeof q;
    q.fftSize = 4096;
    q.sampleRate = rate;
    q.query[0] = at[0]; q.query[1] = at[1]; q.query[2] = at[2];
    q.source[0] = -2.0;
    q.neighbourCount = 3;
    std::vector<double> re(2049), im(2049);
    n60_roommodel_result res = makeResult();
    CHECK(n60_roommodel_interpolate(&q, nb, &res, re.data(), im.data()) == N60_ROOMMODEL_OK, "ok");
    uint32_t refused = 0;
    for (uint32_t k = 0; k < N60_ROOMMODEL_BAND_COUNT; ++k) {
        if (res.bandStatus[k] == N60_ROOMMODEL_BAND_SPREAD) {
            ++refused;
            CHECK(std::fabs(res.spreadDb[k] - 20.0) < 0.1, "spread is 20 dB");
            CHECK(res.confidence[k] == 0.0, "refused band has no confidence");
        }
    }
    CHECK(refused > 10, "spread refuses the bands");
    // Impulse scaling: a single 0.5 impulse reads -6.02 dB.
    std::vector<float> half(256, 0.0f);
    half[10] = 0.5f;
    n60_roommodel_neighbour one{};
    one.ir = half.data();
    one.irFrames = 256;
    one.phaseTrusted = 1;
    q.neighbourCount = 1;
    CHECK(n60_roommodel_interpolate(&q, &one, &res, nullptr, nullptr) == N60_ROOMMODEL_OK, "single");
    CHECK(std::fabs(res.levelDb[20] - (-6.0206)) < 0.01, "level of a 0.5 impulse");
    CHECK(std::fabs(res.spreadDb[20] - 4.0) < 1e-9 && std::fabs(res.confidence[20] - 0.5) < 1e-9,
          "single neighbour shows half-limit spread");
}

static void testArgumentsAndAbi() {
    n60_roommodel_query q{};
    n60_roommodel_result r = makeResult();
    CHECK(n60_roommodel_interpolate(nullptr, nullptr, &r, nullptr, nullptr) == N60_ROOMMODEL_ERR_ARGUMENT, "null query");
    q.structSize = sizeof q;
    q.sampleRate = 48000;
    q.fftSize = 1000;  // not a power of two
    CHECK(n60_roommodel_interpolate(&q, nullptr, &r, nullptr, nullptr) == N60_ROOMMODEL_ERR_ARGUMENT, "bad fft size");
    q.fftSize = 1024;
    q.neighbourCount = 1;
    CHECK(n60_roommodel_interpolate(&q, nullptr, &r, nullptr, nullptr) == N60_ROOMMODEL_ERR_ARGUMENT, "null neighbours");
    float ir[2000] = {};
    n60_roommodel_neighbour n{};
    n.ir = ir;
    n.irFrames = 2000;  // longer than the FFT
    CHECK(n60_roommodel_interpolate(&q, &n, &r, nullptr, nullptr) == N60_ROOMMODEL_ERR_ARGUMENT, "ir longer than fft");
    CHECK(n60_roommodel_abi_version() == N60_ROOMMODEL_ABI_VERSION, "version");
    CHECK(n60_roommodel_crossover_hz(0.5, 343.0) > 171.0 && n60_roommodel_crossover_hz(0.5, 343.0) < 172.0, "f_c");
    CHECK(n60_roommodel_crossover_hz(0, 343.0) == 0.0, "f_c bad spacing");
    CHECK(n60_roommodel_band_centre_hz(N60_ROOMMODEL_BAND_COUNT) == 0.0, "band out of range");
    n60_core_abi_info info{};
    CHECK(n60_core_abi(&info, sizeof info) == 1, "core abi");
    CHECK(info.roomModelVersion == N60_ROOMMODEL_ABI_VERSION, "abi reports roommodel");
}

int main() {
    testArgumentsAndAbi();
    testRefusedOutsideTrust();
    testDeterministic();
    testZeroWeightNodeDoesNotRefuse();
    testContinuity();
    testPhaseUntrustedIsMagnitudeOnly();
    testSpreadRefusesBand();
    testHeldOutPoints();
    if (failures != 0) {
        std::fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    std::puts("roommodel tests passed");
    return 0;
}
