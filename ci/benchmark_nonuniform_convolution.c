// Exactness and CPU harness for the non-uniform partitioned convolver.
//
// Build and run from the repository root:
//   clang -std=c11 -O2 -I NotchSixty/Audio/Realtime \
//     NotchSixty/Audio/Realtime/N60Convolution.c ci/benchmark_nonuniform_convolution.c \
//     -framework Accelerate -o /tmp/n60-conv && /tmp/n60-conv
//
// Compares every segment boundary against direct convolution, then times a
// full 262,144-tap stereo program and reports CPU share at 384 kHz and the
// worst single tick. Exit status is non-zero on any accuracy failure.
#include "N60Convolution.h"
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach_time.h>
static float frand(unsigned *s){ *s = *s*1664525u+1013904223u; return ((*s>>8)/16777216.0f)*2-1; }
static int run_random(uint32_t taps, uint32_t inputLen, int stereo) {
    unsigned seed = 12345 + taps;
    float *hL = malloc(taps*4), *hR = malloc(taps*4), *x = malloc(inputLen*4), *xr = malloc(inputLen*4);
    for (uint32_t i=0;i<taps;i++){ hL[i]=frand(&seed)*expf(-(float)i/(taps*0.3f)); hR[i]=frand(&seed)*0.5f; }
    for (uint32_t i=0;i<inputLen;i++){ x[i]=frand(&seed); xr[i]=frand(&seed); }
    N60PartitionedConvolver *c = N60PartitionedConvolverCreate();
    uint64_t gen=0;
    if (!N60PartitionedConvolverPrepareProgram(c,0,hL,stereo?hR:NULL,taps,0,&gen)) { printf("prepare failed\n"); return 1; }
    N60ConvolutionProgramInfo info = N60PartitionedConvolverProgramInfo(c,0);
    uint32_t total = inputLen + 256;
    double maxErr=0, maxRef=0;
    for (uint32_t n=0;n<total;n++){
        float inL = n<inputLen?x[n]:0, inR = n<inputLen?xr[n]:0, oL, oR;
        N60PartitionedConvolverProcessSample(c,0,gen,inL,inR,&oL,&oR);
        if (n>=256 && (n % 7 == 0 || n < 6000)) {
            int64_t m = (int64_t)n-256; double refL=0, refR=0;
            int64_t kmax = m < (int64_t)taps-1 ? m : (int64_t)taps-1;
            for (int64_t k=0;k<=kmax;k++){ if (m-k < inputLen){ refL += (double)hL[k]*x[m-k]; refR += (double)(stereo?hR[k]:hL[k])*xr[m-k]; } }
            double e = fmax(fabs(refL-oL), fabs(refR-oR)); if (e>maxErr) maxErr=e; if (fabs(refL)>maxRef) maxRef=fabs(refL);
        }
    }
    printf("taps %6u parts %3u lat %u stereo %d: max abs err %.3e (ref peak %.2f) -> rel %.2e\n", taps, info.partitionCount, info.engineLatencyFrames, stereo, maxErr, maxRef, maxErr/maxRef);
    N60PartitionedConvolverDestroy(c); free(hL); free(hR); free(x); free(xr);
    return maxErr/maxRef < 1e-4 ? 0 : 1;
}
static int run_full_length_delta(void) {
    uint32_t taps = N60_CONVOLUTION_MAX_TAPS; unsigned seed = 7;
    float *h = malloc(taps*4); for (uint32_t i=0;i<taps;i++) h[i]=frand(&seed)*expf(-(float)i/80000.0f);
    N60PartitionedConvolver *c = N60PartitionedConvolverCreate(); uint64_t gen=0;
    N60PartitionedConvolverPrepareProgram(c,0,h,NULL,taps,0,&gen);
    double maxErr=0; uint32_t total = taps + 256 + 300;
    uint64_t worst=0, sum=0; mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for (uint32_t n=0;n<total;n++){
        float in = (n==0)?1.0f:((n==100000)?-0.5f:0.0f), oL,oR;
        uint64_t t0 = mach_absolute_time();
        N60PartitionedConvolverProcessSample(c,0,gen,in,in,&oL,&oR);
        uint64_t dt = mach_absolute_time()-t0; sum += dt; if (dt>worst) worst=dt;
        if (n>=256){ int64_t m=(int64_t)n-256; double ref = (m<taps?h[m]:0) + (m>=100000 && m-100000<taps ? -0.5*h[m-100000] : 0);
            double e = fabs(ref-oL); if (e>maxErr) maxErr=e; if (fabs(ref-oR)>maxErr) maxErr=fabs(ref-oR); }
    }
    double ns = (double)tb.numer/tb.denom;
    double avgPerSample = sum*ns/total;
    printf("full %u taps (%u partitions): max err %.3e; avg %.1f ns/sample stereo, worst tick %.1f us\n", taps, N60PartitionedConvolverProgramInfo(c,0).partitionCount, maxErr, avgPerSample, worst*ns/1000.0);
    printf("  -> at 384 kHz: %.1f%% of one core per convolver (stereo)\n", avgPerSample*384000/1e9*100);
    N60PartitionedConvolverDestroy(c); free(h);
    return maxErr < 1e-5 ? 0 : 1;
}
int main(void){
    int fail=0;
    uint32_t lens[] = {1, 100, 256, 257, 1024, 1025, 3000, 5120, 5121, 9000, 40000};
    for (unsigned i=0;i<sizeof(lens)/4;i++) fail |= run_random(lens[i], lens[i]+20000, i%2);
    fail |= run_full_length_delta();
    printf(fail?"FAIL\n":"PASS\n"); return fail;
}
