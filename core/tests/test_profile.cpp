// E20 S1: the per-stage profile hooks (n60/profile.h) exist only in a profile build of libn60core.
//   test_profile absent   linked with product objects: n60_profile_read / n60_profile_reset must not exist.
//   test_profile present  linked with the -DN60_GRAPH_PROFILE snapshot object: a render fills the counters
//                         per stage kind, reset clears them, and the long FIR costs more per sample than a meter.
// The absence check uses a weak reference (the link adds -Wl,-U for the two symbols on macOS).
#include <cstdio>
#include <cstring>

#include "n60/graph.h"
#include "n60/profile.h"

extern "C" {
__attribute__((weak)) void n60_profile_reset(void);
__attribute__((weak)) uint32_t n60_profile_read(n60_profile_entry *out, uint32_t capacity);
}

static int failures = 0;
#define CHECK(cond, ...) do { if (!(cond)) { std::fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); std::fprintf(stderr, __VA_ARGS__); std::fputc('\n', stderr); ++failures; } } while (0)

int main(int argc, char **argv) {
    const bool expectPresent = argc > 1 && std::strcmp(argv[1], "present") == 0;
    CHECK((n60_profile_read != nullptr) == expectPresent, "n60_profile_read %s in this build", n60_profile_read ? "exists" : "is absent");
    CHECK((n60_profile_reset != nullptr) == expectPresent, "n60_profile_reset %s in this build", n60_profile_reset ? "exists" : "is absent");
    if (expectPresent && n60_profile_read && n60_profile_reset) {
        static float taps[16384];
        for (int i = 0; i < 16384; ++i) taps[i] = 0.0001f * static_cast<float>((i * 37) % 11 - 5);
        n60_stage_desc st[3];
        std::memset(st, 0, sizeof st);
        for (int i = 0; i < 3; ++i) { st[i].structSize = sizeof st[i]; st[i].laneA = N60_LANE_ALL; st[i].stageId = 1 + i; }
        st[0].kind = N60_STAGE_METER_IN;
        st[1].kind = N60_STAGE_FIR; st[1].params = taps; st[1].paramCount = 16384;
        st[2].kind = N60_STAGE_FINAL_METER;
        n60_graph_desc d;
        std::memset(&d, 0, sizeof d);
        d.structSize = sizeof d; d.abiVersion = N60_GRAPH_ABI_VERSION; d.sampleRate = 48000; d.maxBlockFrames = 256;
        d.inputChannels = d.outputChannels = 2; d.stages = st; d.stageCount = 3;
        n60_graph *g = nullptr;
        CHECK(n60_graph_build(&d, &g) == N60_STATUS_OK && g, "build");
        static float in[2][256], out[2][256];
        for (int i = 0; i < 256; ++i) in[0][i] = in[1][i] = (i & 1) ? 0.1f : -0.1f;
        const float *ip[2] = {in[0], in[1]};
        float *op[2] = {out[0], out[1]};
        n60_profile_reset();
        for (int b = 0; b < 40; ++b) n60_graph_process(g, ip, op, 256);
        n60_profile_entry e[64];
        const uint32_t n = n60_profile_read(e, 64);
        CHECK(n == 3, "three stage kinds recorded, got %u", n);
        double firNs = 0, meterNs = 1e30;
        for (uint32_t i = 0; i < n; ++i) {
            CHECK(e[i].calls == 40 && e[i].frames == 40u * 256 && e[i].laneFrames == 40u * 256 * 2, "kind %u counters %llu/%llu/%llu", e[i].kind,
                  (unsigned long long)e[i].calls, (unsigned long long)e[i].frames, (unsigned long long)e[i].laneFrames);
            const double per = static_cast<double>(e[i].ns) / static_cast<double>(e[i].laneFrames);
            if (e[i].kind == N60_STAGE_FIR) firNs = per;
            if (e[i].kind == N60_STAGE_METER_IN) meterNs = per;
        }
        CHECK(firNs > meterNs, "FIR %.2f ns/sample must exceed a meter %.2f", firNs, meterNs);
        n60_profile_reset();
        CHECK(n60_profile_read(e, 64) == 0, "reset clears the counters");
        n60_graph_retire(g);
    }
    if (failures) return 1;
    std::puts(expectPresent ? "profile hooks present and correct" : "profile hooks absent from the product build");
    return 0;
}
