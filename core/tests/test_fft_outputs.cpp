// E21 S3: engine outputs under the two FFT backends. The same source is built against libn60core with vDSP and against
// libn60core with the portable FFT (CMake targets n60core_fft_outputs_vdsp_test and n60core_fft_outputs_portable_test).
//   test_fft_outputs write <file>      render a program FIR graph, a binaural graph (early part plus multirate tail) and a
//                                      measurement deconvolution at the eight standard rates; write the samples to <file>.
//   test_fft_outputs compare <a> <b>   require every section of the two files to agree within -120 dBFS peak.
// ctest runs the two writes, then the compare (fixture n60_fft_outputs).
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <vector>

#include "n60/graph.h"
#include "n60/measure.h"

namespace {

struct Rng {
    uint64_t s;
    float next() {
        s = s * 6364136223846793005ull + 1442695040888963407ull;
        return static_cast<float>(static_cast<int32_t>(s >> 33)) / 1073741824.0f - 1.0f;
    }
};

constexpr double kRates[8] = {44100, 48000, 88200, 96000, 176400, 192000, 352800, 384000};

bool programFir(double rate, std::vector<float> &out) {
    const uint32_t taps = 6000, block = 512, total = 24000;
    std::vector<float> t(taps);
    Rng rng{taps};
    for (uint32_t i = 0; i < taps; ++i) t[i] = 0.08f * rng.next() * std::exp(-5.0f * static_cast<float>(i) / static_cast<float>(taps));
    n60_stage_desc s;
    std::memset(&s, 0, sizeof s);
    s.structSize = sizeof s;
    s.kind = N60_STAGE_FIR;
    s.stageId = 1;
    s.laneA = N60_LANE_ALL;
    s.params = t.data();
    s.paramCount = taps;
    n60_graph_desc d{};
    d.structSize = sizeof d;
    d.abiVersion = N60_GRAPH_ABI_VERSION;
    d.sampleRate = rate;
    d.maxBlockFrames = block;
    d.inputChannels = d.outputChannels = 2;
    d.stages = &s;
    d.stageCount = 1;
    n60_graph *g = nullptr;
    if (n60_graph_build(&d, &g) != N60_STATUS_OK) return false;
    std::vector<float> in0(block), in1(block), o0(block), o1(block);
    const float *in[2] = {in0.data(), in1.data()};
    float *op[2] = {o0.data(), o1.data()};
    Rng sig{7};
    for (uint32_t pos = 0; pos < total; pos += block) {
        for (uint32_t i = 0; i < block; ++i) { in0[i] = 0.5f * sig.next(); in1[i] = 0.5f * sig.next(); }
        if (n60_graph_process(g, in, op, block) != N60_STATUS_OK) { n60_graph_retire(g); return false; }
        for (uint32_t i = 0; i < block; ++i) { out.push_back(o0[i]); out.push_back(o1[i]); }
    }
    n60_graph_retire(g);
    return true;
}

bool binaural(double rate, std::vector<float> &out) {
    const uint32_t L = static_cast<uint32_t>(rate * 0.3), E = static_cast<uint32_t>(rate * 0.02), T = L - E;
    Rng rng{99};
    std::vector<float> early(2 * 2 * size_t(E)), tail(2 * 2 * size_t(T));
    for (int k = 0; k < 2; ++k)
        for (int e = 0; e < 2; ++e)
            for (uint32_t t = 0; t < L; ++t) {
                const float h = 0.2f * rng.next() * std::exp(-6.9f * static_cast<float>(t) / static_cast<float>(L)) * (t < 64 ? 1.0f : 0.3f);
                if (t < E) early[(size_t(k) * 2 + e) * E + t] = h;
                else tail[(size_t(k) * 2 + e) * T + (t - E)] = h;
            }
    n60_layout lay;
    n60_layout_standard(N60_LAYOUT_STEREO, &lay);
    n60_binaural_profile p;
    std::memset(&p, 0, sizeof p);
    p.structSize = sizeof p;
    p.taps = E;
    p.orientations = 1;
    p.equalEarChannel = -1;
    p.responses = early.data();
    p.tailTaps = T;
    p.tailResponses = tail.data();
    n60_layout_options o;
    std::memset(&o, 0, sizeof o);
    o.structSize = sizeof o;
    o.sampleRate = rate;
    o.maxBlockFrames = 512;
    o.graphChannels = 2;
    o.layout = &lay;
    o.mode = N60_MODE_BINAURAL;
    o.binaural = &p;
    n60_layout_graph *lg = nullptr;
    n60_graph *g = nullptr;
    if (n60_layout_graph_build(&o, &lg) != N60_STATUS_OK) return false;
    if (n60_graph_build(n60_layout_graph_desc(lg), &g) != N60_STATUS_OK) { n60_layout_graph_free(lg); return false; }
    const uint32_t B = 512;
    const size_t M = static_cast<size_t>(rate * 0.4);
    Rng sig{5};
    std::vector<float> a(B), b(B), oa(B), ob(B);
    for (size_t pos = 0; pos < M; pos += B) {
        for (uint32_t i = 0; i < B; ++i) { a[i] = 0.3f * sig.next(); b[i] = 0.3f * sig.next(); }
        const float *ip[2] = {a.data(), b.data()};
        float *op[2] = {oa.data(), ob.data()};
        n60_graph_process(g, ip, op, B);
        for (uint32_t i = 0; i < B; ++i) { out.push_back(oa[i]); out.push_back(ob[i]); }
    }
    n60_graph_retire(g);
    n60_layout_graph_free(lg);
    return true;
}

bool measurement(double rate, std::vector<float> &out) {
    n60_measure_ess_params ep{};
    ep.sample_rate = rate;
    ep.start_hz = 20.0;
    ep.end_hz = 20000.0;
    ep.duration_seconds = 0.5;
    ep.level_dbfs = -6.0;
    ep.fade_seconds = 0.02;
    ep.synchronised = 1;
    n60_measure_ess_info info{};
    if (n60_measure_ess_describe(&ep, &info) != 0) return false;
    std::vector<float> sweep(info.frame_count);
    if (n60_measure_ess_generate(&ep, sweep.data(), sweep.size(), &info) != 0) return false;
    // A delayed, attenuated copy with a short reflection: a response the deconvolution recovers.
    const size_t delay = static_cast<size_t>(rate * 0.004), echo = static_cast<size_t>(rate * 0.011);
    std::vector<float> observed(sweep.size() + echo, 0.0f);
    for (size_t i = 0; i < sweep.size(); ++i) {
        observed[i + delay] += 0.7f * sweep[i];
        observed[i + echo] += 0.2f * sweep[i];
    }
    uint64_t tsize = 0;
    if (n60_measure_transform_size(observed.size(), &tsize) != 0) return false;
    out.assign(tsize, 0.0f);
    uint64_t count = 0;
    if (n60_measure_deconvolve(sweep.data(), sweep.size(), observed.data(), observed.size(), 1e-6, out.data(), out.size(), &count) != 0) return false;
    out.resize(count);
    return true;
}

int writeAll(const char *path) {
    FILE *f = std::fopen(path, "wb");
    if (f == nullptr) return 1;
    for (double rate : kRates) {
        for (int kind = 0; kind < 3; ++kind) {
            std::vector<float> v;
            const bool ok = kind == 0 ? programFir(rate, v) : kind == 1 ? binaural(rate, v) : measurement(rate, v);
            if (!ok) { std::fprintf(stderr, "render failed kind %d rate %g\n", kind, rate); std::fclose(f); return 1; }
            const uint64_t n = v.size();
            std::fwrite(&n, sizeof n, 1, f);
            std::fwrite(v.data(), sizeof(float), v.size(), f);
        }
    }
    std::fclose(f);
    return 0;
}

bool readSection(FILE *f, std::vector<float> &v) {
    uint64_t n = 0;
    if (std::fread(&n, sizeof n, 1, f) != 1) return false;
    v.resize(n);
    return std::fread(v.data(), sizeof(float), n, f) == n;
}

int compareAll(const char *pa, const char *pb) {
    FILE *fa = std::fopen(pa, "rb");
    FILE *fb = std::fopen(pb, "rb");
    if (fa == nullptr || fb == nullptr) { std::fprintf(stderr, "cannot open inputs\n"); return 1; }
    static const char *const names[3] = {"program FIR", "binaural", "measurement deconvolution"};
    int failures = 0;
    for (double rate : kRates) {
        for (int kind = 0; kind < 3; ++kind) {
            std::vector<float> a, b;
            if (!readSection(fa, a) || !readSection(fb, b) || a.size() != b.size() || a.empty()) {
                std::fprintf(stderr, "FAIL section %s at %g Hz: missing or sizes differ\n", names[kind], rate);
                ++failures;
                continue;
            }
            double peak = 0.0, diff = 0.0;
            for (size_t i = 0; i < a.size(); ++i) {
                peak = std::fmax(peak, std::fabs(a[i]));
                diff = std::fmax(diff, std::fabs(static_cast<double>(a[i]) - static_cast<double>(b[i])));
            }
            // -120 dBFS peak: the difference against full scale, or against the section peak when that is above full scale.
            const double db = diff > 0.0 ? 20.0 * std::log10(diff / std::fmax(peak, 1.0)) : -300.0;
            std::printf("%-26s %7.0f Hz  peak %.3f  worst difference %7.1f dB re peak (min full scale)\n", names[kind], rate, peak, db);
            // Full scale is 1.0; the deconvolution is a response, not a program, so it is held to the same bound.
            if (!(peak > 1e-3) || !(db < -120.0)) {
                std::fprintf(stderr, "FAIL %s at %g Hz: peak %g, difference %g dBFS\n", names[kind], rate, peak, db);
                ++failures;
            }
        }
    }
    std::fclose(fa);
    std::fclose(fb);
    if (failures == 0) std::printf("fft_outputs ok\n");
    return failures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc == 3 && std::strcmp(argv[1], "write") == 0) return writeAll(argv[2]);
    if (argc == 4 && std::strcmp(argv[1], "compare") == 0) return compareAll(argv[2], argv[3]);
    std::fprintf(stderr, "usage: test_fft_outputs write <file> | compare <a> <b>\n");
    return 2;
}
