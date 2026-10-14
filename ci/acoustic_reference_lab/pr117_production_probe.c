/*
 * PR117 acoustic reference laboratory: production DSP probe.
 *
 * This C program emits deterministic numerical observations from the
 * production headers. The independent Python verifier MUST NOT call these
 * headers to generate its expected values. No audio device is opened.
 */
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include "N60Biquad.h"
#include "N60Crossover.h"
#include "N60HeadphoneDSP.h"
#include "N60BinauralRenderer.h"

static void require(bool condition) {
    if (!condition) {
        fprintf(stderr, "PR117 production probe failed\n");
        exit(2);
    }
}

static void print_coeff(const char *kind, double rate, int section,
                        N60BiquadCoefficients c) {
    printf("%s %.0f %d %.9g %.9g %.9g %.9g %.9g\n",
           kind, rate, section, (double)c.b0, (double)c.b1,
           (double)c.b2, (double)c.a1, (double)c.a2);
}

static void probe_peaking(double rate) {
    N60BiquadCoefficients c;
    require(N60BiquadDesign(N60BiquadFilterTypePeaking,
                            rate, 1000.0, 6.0, 1.0, &c));
    print_coeff("PEQ", rate, 0, c);
    N60BiquadState state = {0};
    for (int n = 0; n < 512; ++n) {
        float y = N60BiquadProcessSample(c, &state, n == 0 ? 1.0f : 0.0f);
        require(isfinite(y));
        printf("IMP %.0f %d %.9g\n", rate, n, (double)y);
    }
}

static void probe_crossover(double rate, N60CrossoverTopology topology,
                            int label) {
    N60CrossoverSnapshot s;
    require(N60CrossoverSnapshotMake(rate, 80.0, topology,
        N60CrossoverMonitorModeRecombined, 1.0f, false, true, &s));
    require(s.sectionCount == (label == 24 ? 2u : 4u));
    printf("XO %.0f %d %u\n", rate, label, s.sectionCount);
    for (uint32_t i = 0; i < s.sectionCount; ++i) {
        print_coeff(label == 24 ? "HP24" : "HP48",
                    rate, (int)i, s.mainsHighPass[i]);
        print_coeff(label == 24 ? "LP24" : "LP48",
                    rate, (int)i, s.subLowPass[i]);
    }
}

static void probe_headphone(double rate) {
    N60HeadphoneDSPSnapshot s = N60HeadphoneDSPSnapshotMakeUnity(rate);
    require(N60HeadphoneDSPSetChannelGain(&s, 0u, 0.5f));
    require(N60HeadphoneDSPSetHeadroomAttenuationDB(
        &s, 6.020599913279624));
    require(N60HeadphoneDSPSetChannelDelayFrames(&s, 1u, 3u));
    N60HeadphoneDSPRuntime *runtime = N60HeadphoneDSPRuntimeCreate();
    require(runtime != NULL && N60HeadphoneDSPRuntimePrepare(runtime, &s));
    for (int n = 0; n < 8; ++n) {
        float l = 0.0f, r = 0.0f;
        require(N60HeadphoneDSPProcessStereoFrame(runtime, &s,
                   n == 0 ? 1.0f : 0.0f, n == 0 ? 1.0f : 0.0f,
                   &l, &r));
        printf("HPIMP %.0f %d %.9g %.9g\n",
               rate, n, (double)l, (double)r);
    }
    N60HeadphoneDSPRuntimeDestroy(runtime);
}

static void probe_crossfeed(double rate, double freq) {
    N60HeadphoneDSPSnapshot s = N60HeadphoneDSPSnapshotMakeUnity(rate);
    require(N60HeadphoneDSPSetCrossfeed(
        &s, 1.0f, 30.0, 0.0875, 700.0, true));
    N60HeadphoneDSPRuntime *runtime = N60HeadphoneDSPRuntimeCreate();
    require(runtime != NULL && N60HeadphoneDSPRuntimePrepare(runtime, &s));
    double in2 = 0.0, right2 = 0.0;
    for (int n = 0; n < 12288; ++n) {
        float source = (float)sin(2.0 * 3.14159265358979323846
                                  * freq * n / rate);
        float l = 0.0f, r = 0.0f;
        require(N60HeadphoneDSPProcessStereoFrame(runtime, &s,
                    source, 0.0f, &l, &r));
        require(isfinite(l) && isfinite(r));
        if (n >= 4096) {
            in2 += (double)source * (double)source;
            right2 += (double)r * (double)r;
        }
    }
    require(in2 > 0);
    printf("XFEED %.0f %.0f %.12g\n", rate, freq, sqrt(right2 / in2));
    N60HeadphoneDSPRuntimeDestroy(runtime);
}

static void probe_binaural(void) {
    N60ProgramChannelLayout stereo =
        N60ProgramChannelLayoutMakeStandard(N60ProgramLayoutStereo);
    N60BinauralProfileDescriptor profile =
        N60BinauralProfileDescriptorMake(
            48000.0, stereo, N60BinauralProfileKindHRTF, 1u);
    float leftIR[2] = {0.8f, 0.2f};
    float rightIR[2] = {0.2f, 0.7f};
    N60BinauralRenderer *renderer = N60BinauralRendererCreate();
    require(renderer != NULL);
    require(N60BinauralRendererPrepareProfile(
        renderer, profile, leftIR, rightIR));
    printf("BRLAT %u\n", N60BinauralRendererLatencyFrames(renderer));
    for (int n = 0; n <= 129; ++n) {
        float in[2] = {n == 0 ? 1.0f : 0.0f, 0.0f};
        float l = 0.0f, r = 0.0f;
        require(N60BinauralRendererProcessFrame(
            renderer, in, 2u, &l, &r));
        if (n == 0 || n == 127 || n == 128 || n == 129) {
            printf("BRIMP %d %.9g %.9g\n",
                   n, (double)l, (double)r);
        }
    }
    N60BinauralRendererDestroy(renderer);
}

int main(void) {
    const double rates[] = {44100.0, 48000.0, 96000.0};
    for (size_t i = 0; i < sizeof(rates) / sizeof(rates[0]); ++i) {
        probe_peaking(rates[i]);
        probe_crossover(rates[i], N60CrossoverTopologyLinkwitzRiley24, 24);
        probe_crossover(rates[i], N60CrossoverTopologyLinkwitzRiley48, 48);
        probe_headphone(rates[i]);
        probe_crossfeed(rates[i], 80.0);
        probe_crossfeed(rates[i], 10000.0);
    }
    probe_binaural();
    puts("END");
    return 0;
}
