// E11 S1: offline FFT behaviour (round trip, Parseval, direct-DFT reference, speed) at
// 2^10 .. 2^24 points.
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <vector>

#include "measure/offline_fft.hpp"

using namespace n60::fft::offline;
static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); \
    std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); failures++; } } while (0)

static uint64_t rngState = 12345;
static double rnd() {
    rngState ^= rngState >> 12; rngState ^= rngState << 25; rngState ^= rngState >> 27;
    return static_cast<double>((rngState * 0x2545F4914F6CDD1Dull) >> 11) / 9007199254740992.0 * 2.0 - 1.0;
}

int main() {
    // Direct DFT reference at small sizes.
    for (uint64_t n : {2ull, 4ull, 8ull, 64ull, 256ull}) {
        std::vector<double> x(n);
        for (double &v : x) v = rnd();
        std::vector<Cplx> spec;
        CHECK(realForward(x.data(), n, spec), "forward %llu", (unsigned long long)n);
        double worst = 0;
        for (uint64_t k = 0; k <= n / 2; ++k) {
            double re = 0, im = 0;
            for (uint64_t j = 0; j < n; ++j) {
                const double a = -2.0 * M_PI * static_cast<double>(j * k % n) / static_cast<double>(n);
                re += x[j] * std::cos(a);
                im += x[j] * std::sin(a);
            }
            worst = std::fmax(worst, std::hypot(spec[k].re - re, spec[k].im - im));
        }
        CHECK(worst < 1e-11, "n=%llu direct DFT error %g", (unsigned long long)n, worst);
    }
    // Round trip and Parseval, 2^10 .. 2^24.
    for (int p = 10; p <= 24; ++p) {
        const uint64_t n = 1ull << p;
        std::vector<double> x(n);
        double energy = 0;
        for (double &v : x) { v = rnd(); energy += v * v; }
        std::vector<Cplx> spec;
        const auto t0 = std::chrono::steady_clock::now();
        CHECK(realForward(x.data(), n, spec), "forward 2^%d", p);
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
        double spectral = spec[0].re * spec[0].re + spec[n / 2].re * spec[n / 2].re;
        for (uint64_t k = 1; k < n / 2; ++k) spectral += 2.0 * (spec[k].re * spec[k].re + spec[k].im * spec[k].im);
        spectral /= static_cast<double>(n);
        CHECK(std::fabs(spectral - energy) < 1e-10 * energy, "Parseval 2^%d: %g vs %g", p, spectral, energy);
        std::vector<double> back;
        CHECK(realInverse(spec, n, back), "inverse 2^%d", p);
        double worst = 0;
        for (uint64_t j = 0; j < n; ++j) worst = std::fmax(worst, std::fabs(back[j] - x[j]));
        CHECK(worst < 1e-11, "round trip 2^%d error %g", p, worst);
        if (p == 22) {
            std::printf("offline FFT 2^22 forward: %.3f s\n", seconds);
            CHECK(seconds < 3.0, "2^22 transform took %.3f s", seconds);
        }
    }
    std::vector<Cplx> spec;
    double dummy = 0;
    CHECK(!realForward(&dummy, 3, spec), "non power of two rejected");
    CHECK(!realForward(&dummy, 1ull << 25, spec), "oversize rejected");
    if (failures) { std::fprintf(stderr, "%d failure(s)\n", failures); return 1; }
    std::puts("measure fft OK");
    return 0;
}
