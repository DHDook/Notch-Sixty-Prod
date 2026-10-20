#include "N60Convolution.h"

#include <Accelerate/Accelerate.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_PI 3.14159265358979323846

// Ring sizes (powers of two). The input ring must hold the largest block; the
// output ring must hold the furthest write-ahead, O_2 + L, plus one block.
#define N60_CONVOLUTION_INPUT_RING 4096u
#define N60_CONVOLUTION_OUTPUT_RING 16384u
#define N60_CONVOLUTION_LOG2_MAX_FFT 13u
#define N60_CONVOLUTION_CHANNELS 2u

_Static_assert(N60_CONVOLUTION_INPUT_RING >= N60_CONVOLUTION_SEGMENT2_BLOCK,
               "input ring must hold one segment-2 block");
_Static_assert(N60_CONVOLUTION_OUTPUT_RING
                   > N60_CONVOLUTION_SEGMENT2_OFFSET + N60_CONVOLUTION_PARTITION_FRAMES
                       + N60_CONVOLUTION_SEGMENT2_BLOCK,
               "output ring must hold the furthest write-ahead");
_Static_assert(N60_CONVOLUTION_SEGMENT1_OFFSET + N60_CONVOLUTION_PARTITION_FRAMES
                   >= N60_CONVOLUTION_SEGMENT1_BLOCK,
               "segment 1 must start at offset >= B - L");
_Static_assert(N60_CONVOLUTION_SEGMENT2_OFFSET + N60_CONVOLUTION_PARTITION_FRAMES
                   >= N60_CONVOLUTION_SEGMENT2_BLOCK,
               "segment 2 must start at offset >= B - L");
_Static_assert((2u * N60_CONVOLUTION_SEGMENT2_BLOCK) == (1u << N60_CONVOLUTION_LOG2_MAX_FFT),
               "FFT setup must cover the largest segment");

typedef struct {
    float real;
    float imag;
} N60Complex;

typedef struct {
    uint32_t block;
    uint32_t offset;
    uint32_t log2FFT;
    uint32_t maximumPartitions;
} N60ConvolutionSegmentLayout;

static const N60ConvolutionSegmentLayout kSegmentLayouts[N60_CONVOLUTION_SEGMENT_COUNT] = {
    {N60_CONVOLUTION_SEGMENT0_BLOCK, 0u, 9u, N60_CONVOLUTION_SEGMENT0_PARTITIONS},
    {N60_CONVOLUTION_SEGMENT1_BLOCK, N60_CONVOLUTION_SEGMENT1_OFFSET, 11u, N60_CONVOLUTION_SEGMENT1_PARTITIONS},
    {N60_CONVOLUTION_SEGMENT2_BLOCK, N60_CONVOLUTION_SEGMENT2_OFFSET, 13u, N60_CONVOLUTION_SEGMENT2_PARTITIONS},
};

/// Packed vDSP real-FFT spectra (DC in realp[0], Nyquist in imagp[0]):
/// `maximumPartitions` consecutive blocks of `block` bins.
typedef struct {
    float *realp;
    float *imagp;
} N60ConvolutionSpectra;

typedef struct {
    uint32_t partitionCount;
    N60ConvolutionSpectra kernel[N60_CONVOLUTION_CHANNELS];
} N60ConvolutionSegmentProgram;

typedef struct {
    bool prepared;
    bool sharedKernel;
    uint64_t generation;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t declaredLatencyFrames;
    N60ConvolutionSegmentProgram segments[N60_CONVOLUTION_SEGMENT_COUNT];
} N60ConvolutionProgram;

typedef struct {
    N60ConvolutionSpectra history[N60_CONVOLUTION_CHANNELS];
    float *accumulatorReal[N60_CONVOLUTION_CHANNELS];
    float *accumulatorImag[N60_CONVOLUTION_CHANNELS];
    float *overlap[N60_CONVOLUTION_CHANNELS];
    uint32_t historyWrite;
    // Blocks written since the runtime last started from silence (capped at the partition count). Older history
    // partitions beyond this are stale and are skipped, so a restart needs no multi-MB clear.
    uint32_t validBlocks;
} N60ConvolutionSegmentRuntime;

typedef struct {
    uint64_t position;
    uint32_t seenEpoch;
    float *inputRing[N60_CONVOLUTION_CHANNELS];
    float *outputRing[N60_CONVOLUTION_CHANNELS];
    N60ConvolutionSegmentRuntime segments[N60_CONVOLUTION_SEGMENT_COUNT];
} N60ConvolutionRuntime;

struct N60PartitionedConvolver {
    N60ConvolutionProgram programs[N60_CONVOLUTION_PROGRAM_SLOTS];
    N60ConvolutionRuntime runtimes[N60_CONVOLUTION_PROGRAM_SLOTS];
    FFTSetup fftSetup;
    // Realtime scratch: one render thread per convolver.
    float *renderTime;
    _Atomic uint32_t activeSlot;
    // Bumped (any thread) when the convolver has not been rendering and its slots hold stale audio. The render thread
    // restarts the active slot from silence lazily, in O(block) work.
    _Atomic uint32_t idleEpoch;
    uint64_t nextGeneration;
};

static N60Complex complex_multiply(N60Complex lhs, N60Complex rhs) {
    N60Complex result = {
        lhs.real * rhs.real - lhs.imag * rhs.imag,
        lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return result;
}

static uint32_t next_power_of_two(uint32_t value) {
    uint32_t result = 1u;
    while (result < value) {
        if (result > UINT32_MAX / 2u) return 0u;
        result <<= 1u;
    }
    return result;
}

static void transform_dynamic(N60Complex *values, uint32_t count, bool inverse) {
    for (uint32_t index = 1u, reversed = 0u; index < count; ++index) {
        uint32_t bit = count >> 1u;
        for (; reversed & bit; bit >>= 1u) reversed ^= bit;
        reversed ^= bit;
        if (index < reversed) {
            N60Complex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u; length <= count; length <<= 1u) {
        double angle = (inverse ? 2.0 : -2.0) * N60_PI / (double)length;
        N60Complex step = {(float)cos(angle), (float)sin(angle)};
        uint32_t half = length >> 1u;
        for (uint32_t base = 0u; base < count; base += length) {
            N60Complex twiddle = {1.0f, 0.0f};
            for (uint32_t offset = 0u; offset < half; ++offset) {
                N60Complex even = values[base + offset];
                N60Complex odd = complex_multiply(values[base + offset + half], twiddle);
                values[base + offset] = (N60Complex){even.real + odd.real, even.imag + odd.imag};
                values[base + offset + half] = (N60Complex){even.real - odd.real, even.imag - odd.imag};
                twiddle = complex_multiply(twiddle, step);
            }
        }
        if (length == count) break;
    }

    if (inverse) {
        float scale = 1.0f / (float)count;
        for (uint32_t index = 0u; index < count; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
}

bool N60FIRConvolveControlPlane(
    const float *lhs,
    uint32_t lhsCount,
    const float *rhs,
    uint32_t rhsCount,
    float *output,
    uint32_t outputCapacity
) {
    if (lhs == NULL || rhs == NULL || output == NULL || lhsCount == 0u || rhsCount == 0u) return false;
    uint64_t required64 = (uint64_t)lhsCount + (uint64_t)rhsCount - 1u;
    if (required64 == 0u || required64 > N60_CONVOLUTION_MAX_TAPS || required64 > outputCapacity) return false;
    uint32_t required = (uint32_t)required64;
    for (uint32_t index = 0u; index < lhsCount; ++index) if (!isfinite(lhs[index])) return false;
    for (uint32_t index = 0u; index < rhsCount; ++index) if (!isfinite(rhs[index])) return false;

    uint32_t fftCount = next_power_of_two(required);
    if (fftCount == 0u) return false;
    N60Complex *left = calloc(fftCount, sizeof(N60Complex));
    N60Complex *right = calloc(fftCount, sizeof(N60Complex));
    if (left == NULL || right == NULL) {
        free(left);
        free(right);
        return false;
    }

    for (uint32_t index = 0u; index < lhsCount; ++index) left[index].real = lhs[index];
    for (uint32_t index = 0u; index < rhsCount; ++index) right[index].real = rhs[index];
    transform_dynamic(left, fftCount, false);
    transform_dynamic(right, fftCount, false);
    for (uint32_t index = 0u; index < fftCount; ++index) left[index] = complex_multiply(left[index], right[index]);
    transform_dynamic(left, fftCount, true);

    bool valid = true;
    for (uint32_t index = 0u; index < required; ++index) {
        output[index] = left[index].real;
        if (!isfinite(output[index])) valid = false;
    }
    free(left);
    free(right);
    return valid;
}

static float *allocate_floats(size_t count) {
    return (float *)calloc(count, sizeof(float));
}

static bool allocate_spectra(N60ConvolutionSpectra *spectra, size_t count) {
    spectra->realp = allocate_floats(count);
    spectra->imagp = allocate_floats(count);
    return spectra->realp != NULL && spectra->imagp != NULL;
}

static void free_spectra(N60ConvolutionSpectra *spectra) {
    free(spectra->realp);
    free(spectra->imagp);
    spectra->realp = NULL;
    spectra->imagp = NULL;
}

static bool allocate_slot(N60PartitionedConvolver *convolver, uint32_t slot) {
    N60ConvolutionProgram *program = &convolver->programs[slot];
    N60ConvolutionRuntime *runtime = &convolver->runtimes[slot];
    bool ok = true;
    for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
        runtime->inputRing[channel] = allocate_floats(N60_CONVOLUTION_INPUT_RING);
        runtime->outputRing[channel] = allocate_floats(N60_CONVOLUTION_OUTPUT_RING);
        ok = ok && runtime->inputRing[channel] != NULL && runtime->outputRing[channel] != NULL;
    }
    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        const N60ConvolutionSegmentLayout layout = kSegmentLayouts[segment];
        const size_t spectraCount = (size_t)layout.maximumPartitions * layout.block;
        N60ConvolutionSegmentRuntime *segmentRuntime = &runtime->segments[segment];
        for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
            ok = ok && allocate_spectra(&program->segments[segment].kernel[channel], spectraCount);
            ok = ok && allocate_spectra(&segmentRuntime->history[channel], spectraCount);
            segmentRuntime->accumulatorReal[channel] = allocate_floats(layout.block);
            segmentRuntime->accumulatorImag[channel] = allocate_floats(layout.block);
            segmentRuntime->overlap[channel] = allocate_floats(layout.block);
            ok = ok && segmentRuntime->accumulatorReal[channel] != NULL
                && segmentRuntime->accumulatorImag[channel] != NULL
                && segmentRuntime->overlap[channel] != NULL;
        }
    }
    return ok;
}

static void free_slot(N60PartitionedConvolver *convolver, uint32_t slot) {
    N60ConvolutionProgram *program = &convolver->programs[slot];
    N60ConvolutionRuntime *runtime = &convolver->runtimes[slot];
    for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
        free(runtime->inputRing[channel]);
        free(runtime->outputRing[channel]);
    }
    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        N60ConvolutionSegmentRuntime *segmentRuntime = &runtime->segments[segment];
        for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
            free_spectra(&program->segments[segment].kernel[channel]);
            free_spectra(&segmentRuntime->history[channel]);
            free(segmentRuntime->accumulatorReal[channel]);
            free(segmentRuntime->accumulatorImag[channel]);
            free(segmentRuntime->overlap[channel]);
        }
    }
}

/// Clears only the state a prepared program can read, so reset cost follows
/// the prepared tap count rather than the maximum capacity.
static void reset_runtime(
    const N60ConvolutionProgram *program,
    N60ConvolutionRuntime *runtime,
    uint32_t epoch
) {
    runtime->seenEpoch = epoch;
    runtime->position = 0u;
    for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
        memset(runtime->inputRing[channel], 0, N60_CONVOLUTION_INPUT_RING * sizeof(float));
        memset(runtime->outputRing[channel], 0, N60_CONVOLUTION_OUTPUT_RING * sizeof(float));
    }
    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        const N60ConvolutionSegmentLayout layout = kSegmentLayouts[segment];
        N60ConvolutionSegmentRuntime *segmentRuntime = &runtime->segments[segment];
        const size_t used = (size_t)program->segments[segment].partitionCount * layout.block;
        for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
            memset(segmentRuntime->history[channel].realp, 0, used * sizeof(float));
            memset(segmentRuntime->history[channel].imagp, 0, used * sizeof(float));
            memset(segmentRuntime->accumulatorReal[channel], 0, layout.block * sizeof(float));
            memset(segmentRuntime->accumulatorImag[channel], 0, layout.block * sizeof(float));
            memset(segmentRuntime->overlap[channel], 0, layout.block * sizeof(float));
        }
        segmentRuntime->historyWrite = 0u;
        segmentRuntime->validBlocks = 0u;
    }
}

/// Realtime-safe restart of the active slot: clears the rings and per-block scratch only (small and bounded) and
/// invalidates the spectral history by count instead of clearing it.
static void invalidate_runtime(N60ConvolutionRuntime *runtime, uint32_t epoch) {
    runtime->seenEpoch = epoch;
    runtime->position = 0u;
    for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
        memset(runtime->inputRing[channel], 0, N60_CONVOLUTION_INPUT_RING * sizeof(float));
        memset(runtime->outputRing[channel], 0, N60_CONVOLUTION_OUTPUT_RING * sizeof(float));
    }
    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        const N60ConvolutionSegmentLayout layout = kSegmentLayouts[segment];
        N60ConvolutionSegmentRuntime *segmentRuntime = &runtime->segments[segment];
        for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
            memset(segmentRuntime->accumulatorReal[channel], 0, layout.block * sizeof(float));
            memset(segmentRuntime->accumulatorImag[channel], 0, layout.block * sizeof(float));
            memset(segmentRuntime->overlap[channel], 0, layout.block * sizeof(float));
        }
        segmentRuntime->historyWrite = 0u;
        segmentRuntime->validBlocks = 0u;
    }
}

N60PartitionedConvolver *N60PartitionedConvolverCreate(void) {
    N60PartitionedConvolver *convolver = calloc(1, sizeof(N60PartitionedConvolver));
    if (convolver == NULL) return NULL;
    convolver->fftSetup = vDSP_create_fftsetup(N60_CONVOLUTION_LOG2_MAX_FFT, kFFTRadix2);
    convolver->renderTime = allocate_floats(2u * N60_CONVOLUTION_SEGMENT2_BLOCK);
    bool ok = convolver->fftSetup != NULL && convolver->renderTime != NULL;
    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        ok = allocate_slot(convolver, slot) && ok;
    }
    if (!ok) {
        N60PartitionedConvolverDestroy(convolver);
        return NULL;
    }
    atomic_store_explicit(&convolver->activeSlot, N60_CONVOLUTION_NO_PROGRAM, memory_order_relaxed);
    return convolver;
}

void N60PartitionedConvolverDestroy(N60PartitionedConvolver *convolver) {
    if (convolver == NULL) return;
    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        free_slot(convolver, slot);
    }
    if (convolver->fftSetup != NULL) vDSP_destroy_fftsetup(convolver->fftSetup);
    free(convolver->renderTime);
    free(convolver);
}

void N60PartitionedConvolverReset(N60PartitionedConvolver *convolver) {
    if (convolver == NULL) return;
    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        reset_runtime(&convolver->programs[slot], &convolver->runtimes[slot],
                      atomic_load_explicit(&convolver->idleEpoch, memory_order_relaxed));
    }
    atomic_store_explicit(&convolver->activeSlot, N60_CONVOLUTION_NO_PROGRAM, memory_order_release);
}

static bool taps_are_finite(const float *taps, uint32_t tapCount) {
    if (taps == NULL) return false;
    for (uint32_t index = 0; index < tapCount; ++index) {
        if (!isfinite(taps[index])) return false;
    }
    return true;
}

/// Packed real FFT of 2B time samples into B split bins.
static void forward_packed(
    FFTSetup setup,
    uint32_t log2FFT,
    const float *time,
    DSPSplitComplex *spectrum
) {
    const vDSP_Length bins = (vDSP_Length)1u << (log2FFT - 1u);
    vDSP_ctoz((const DSPComplex *)time, 2, spectrum, 1, bins);
    vDSP_fft_zrip(setup, spectrum, 1, log2FFT, kFFTDirection_Forward);
}

/// accumulator += x * h on packed spectra (bin 0 holds two real products).
static void multiply_accumulate_packed(
    const DSPSplitComplex *x,
    const DSPSplitComplex *h,
    DSPSplitComplex *accumulator,
    uint32_t bins
) {
    const float dc = accumulator->realp[0] + x->realp[0] * h->realp[0];
    const float nyquist = accumulator->imagp[0] + x->imagp[0] * h->imagp[0];
    if (bins > 1u) {
        DSPSplitComplex x1 = {x->realp + 1, x->imagp + 1};
        DSPSplitComplex h1 = {h->realp + 1, h->imagp + 1};
        DSPSplitComplex a1 = {accumulator->realp + 1, accumulator->imagp + 1};
        vDSP_zvma(&x1, 1, &h1, 1, &a1, 1, &a1, 1, bins - 1u);
    }
    accumulator->realp[0] = dc;
    accumulator->imagp[0] = nyquist;
}

bool N60PartitionedConvolverPrepareProgram(
    N60PartitionedConvolver *convolver,
    uint32_t slot,
    const float *leftTaps,
    const float *rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    uint64_t *generationOut
) {
    if (convolver == NULL
        || slot >= N60_CONVOLUTION_PROGRAM_SLOTS
        || tapCount == 0
        || tapCount > N60_CONVOLUTION_MAX_TAPS
        || !taps_are_finite(leftTaps, tapCount)
        || (rightTaps != NULL && !taps_are_finite(rightTaps, tapCount))) {
        return false;
    }
    if (atomic_load_explicit(&convolver->activeSlot, memory_order_acquire) == slot) return false;

    // Control-plane scratch: never shared with the render thread.
    float *time = allocate_floats(2u * N60_CONVOLUTION_SEGMENT2_BLOCK);
    if (time == NULL) return false;

    N60ConvolutionProgram *program = &convolver->programs[slot];
    program->prepared = false;
    program->sharedKernel = rightTaps == NULL;
    const uint32_t kernelChannels = program->sharedKernel ? 1u : 2u;

    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        const N60ConvolutionSegmentLayout layout = kSegmentLayouts[segment];
        const uint32_t partitions = N60ConvolutionSegmentPartitionCount(tapCount, segment);
        const uint32_t fftLength = 2u * layout.block;
        // vDSP real FFT: forward scales by 2 (twice: input and kernel) and the
        // inverse by the FFT length; fold the 1 / (4 N) into the kernel.
        const float scale = 1.0f / (4.0f * (float)fftLength);
        program->segments[segment].partitionCount = partitions;
        for (uint32_t partition = 0; partition < partitions; ++partition) {
            for (uint32_t channel = 0; channel < kernelChannels; ++channel) {
                const float *taps = channel == 0u ? leftTaps : rightTaps;
                memset(time, 0, fftLength * sizeof(float));
                const uint32_t first = layout.offset + partition * layout.block;
                for (uint32_t index = 0; index < layout.block; ++index) {
                    const uint32_t tap = first + index;
                    if (tap < tapCount) time[index] = taps[tap];
                }
                N60ConvolutionSpectra *kernel = &program->segments[segment].kernel[channel];
                DSPSplitComplex spectrum = {
                    kernel->realp + (size_t)partition * layout.block,
                    kernel->imagp + (size_t)partition * layout.block,
                };
                forward_packed(convolver->fftSetup, layout.log2FFT, time, &spectrum);
                vDSP_vsmul(spectrum.realp, 1, &scale, spectrum.realp, 1, layout.block);
                vDSP_vsmul(spectrum.imagp, 1, &scale, spectrum.imagp, 1, layout.block);
            }
        }
    }
    free(time);

    program->tapCount = tapCount;
    program->partitionCount = N60ConvolutionPartitionCountForTapCount(tapCount);
    program->declaredLatencyFrames = declaredLatencyFrames;
    program->generation = ++convolver->nextGeneration;
    reset_runtime(program, &convolver->runtimes[slot],
                  atomic_load_explicit(&convolver->idleEpoch, memory_order_relaxed));
    program->prepared = true;
    if (generationOut != NULL) *generationOut = program->generation;
    return true;
}

N60ConvolutionProgramInfo N60PartitionedConvolverProgramInfo(
    const N60PartitionedConvolver *convolver,
    uint32_t slot
) {
    N60ConvolutionProgramInfo info = {0};
    if (convolver == NULL || slot >= N60_CONVOLUTION_PROGRAM_SLOTS) return info;
    const N60ConvolutionProgram *program = &convolver->programs[slot];
    info.prepared = program->prepared;
    info.generation = program->generation;
    info.tapCount = program->tapCount;
    info.partitionCount = program->partitionCount;
    info.engineLatencyFrames = N60_CONVOLUTION_PARTITION_FRAMES;
    info.declaredLatencyFrames = program->declaredLatencyFrames;
    return info;
}

bool N60PartitionedConvolverProgramMatches(
    const N60PartitionedConvolver *convolver,
    uint32_t slot,
    uint64_t generation
) {
    return convolver != NULL
        && slot < N60_CONVOLUTION_PROGRAM_SLOTS
        && convolver->programs[slot].prepared
        && convolver->programs[slot].generation == generation;
}

/// Runs once per base block (L input samples). For each active segment it
/// accumulates its share of the older partitions and, on the segment's own
/// block boundary, transforms the newest block, adds partition 0, inverse
/// transforms and overlap-adds into the output ring at emission time.
static void process_tick(
    N60PartitionedConvolver *convolver,
    const N60ConvolutionProgram *program,
    N60ConvolutionRuntime *runtime
) {
    const uint64_t position = runtime->position;
    const uint64_t tick = position / N60_CONVOLUTION_PARTITION_FRAMES;
    float *time = convolver->renderTime;

    for (uint32_t segment = 0; segment < N60_CONVOLUTION_SEGMENT_COUNT; ++segment) {
        const N60ConvolutionSegmentProgram *segmentProgram = &program->segments[segment];
        const uint32_t partitions = segmentProgram->partitionCount;
        if (partitions == 0u) continue;
        const N60ConvolutionSegmentLayout layout = kSegmentLayouts[segment];
        const uint32_t block = layout.block;
        const uint32_t ticksPerBlock = block / N60_CONVOLUTION_PARTITION_FRAMES;
        const uint32_t phase = (uint32_t)((tick - 1u) % ticksPerBlock);
        N60ConvolutionSegmentRuntime *segmentRuntime = &runtime->segments[segment];

        if (partitions > 1u) {
            const uint32_t older = partitions - 1u;
            const uint32_t begin = 1u + (phase * older) / ticksPerBlock;
            const uint32_t end = 1u + ((phase + 1u) * older) / ticksPerBlock;
            for (uint32_t partition = begin; partition < end; ++partition) {
                if (partition > segmentRuntime->validBlocks) break;
                const uint32_t historyIndex =
                    (segmentRuntime->historyWrite + partitions - partition) % partitions;
                for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
                    const N60ConvolutionSpectra *kernel =
                        &segmentProgram->kernel[program->sharedKernel ? 0u : channel];
                    const DSPSplitComplex x = {
                        segmentRuntime->history[channel].realp + (size_t)historyIndex * block,
                        segmentRuntime->history[channel].imagp + (size_t)historyIndex * block,
                    };
                    const DSPSplitComplex h = {
                        kernel->realp + (size_t)partition * block,
                        kernel->imagp + (size_t)partition * block,
                    };
                    DSPSplitComplex accumulator = {
                        segmentRuntime->accumulatorReal[channel],
                        segmentRuntime->accumulatorImag[channel],
                    };
                    multiply_accumulate_packed(&x, &h, &accumulator, block);
                }
            }
        }

        if (phase + 1u != ticksPerBlock) continue;

        const uint64_t blockStart = position - block;
        const uint64_t emission = blockStart + layout.offset + N60_CONVOLUTION_PARTITION_FRAMES;
        const uint32_t historyIndex = segmentRuntime->historyWrite;
        for (uint32_t channel = 0; channel < N60_CONVOLUTION_CHANNELS; ++channel) {
            const float *input = runtime->inputRing[channel];
            for (uint32_t index = 0; index < block; ++index) {
                time[index] = input[(uint32_t)(blockStart + index) & (N60_CONVOLUTION_INPUT_RING - 1u)];
            }
            memset(time + block, 0, block * sizeof(float));
            DSPSplitComplex x = {
                segmentRuntime->history[channel].realp + (size_t)historyIndex * block,
                segmentRuntime->history[channel].imagp + (size_t)historyIndex * block,
            };
            forward_packed(convolver->fftSetup, layout.log2FFT, time, &x);

            const N60ConvolutionSpectra *kernel =
                &segmentProgram->kernel[program->sharedKernel ? 0u : channel];
            const DSPSplitComplex h = {kernel->realp, kernel->imagp};
            DSPSplitComplex accumulator = {
                segmentRuntime->accumulatorReal[channel],
                segmentRuntime->accumulatorImag[channel],
            };
            multiply_accumulate_packed(&x, &h, &accumulator, block);

            vDSP_fft_zrip(convolver->fftSetup, &accumulator, 1, layout.log2FFT, kFFTDirection_Inverse);
            vDSP_ztoc(&accumulator, 1, (DSPComplex *)time, 2, block);

            float *output = runtime->outputRing[channel];
            float *overlap = segmentRuntime->overlap[channel];
            for (uint32_t index = 0; index < block; ++index) {
                const uint32_t ring = (uint32_t)(emission + index) & (N60_CONVOLUTION_OUTPUT_RING - 1u);
                output[ring] += time[index] + overlap[index];
                overlap[index] = time[block + index];
            }
            memset(accumulator.realp, 0, block * sizeof(float));
            memset(accumulator.imagp, 0, block * sizeof(float));
        }
        segmentRuntime->historyWrite = (historyIndex + 1u) % partitions;
        if (segmentRuntime->validBlocks < partitions) ++segmentRuntime->validBlocks;
    }
}

bool N60PartitionedConvolverProcessSample(
    N60PartitionedConvolver *convolver,
    uint32_t slot,
    uint64_t generation,
    float inputLeft,
    float inputRight,
    float *outputLeft,
    float *outputRight
) {
    if (convolver == NULL
        || outputLeft == NULL
        || outputRight == NULL
        || !N60PartitionedConvolverProgramMatches(convolver, slot, generation)) {
        return false;
    }

    N60ConvolutionRuntime *runtime = &convolver->runtimes[slot];
    atomic_store_explicit(&convolver->activeSlot, slot, memory_order_release);
    const uint32_t epoch = atomic_load_explicit(&convolver->idleEpoch, memory_order_acquire);
    if (runtime->seenEpoch != epoch) invalidate_runtime(runtime, epoch);
    const uint64_t position = runtime->position;
    const uint32_t outputIndex = (uint32_t)position & (N60_CONVOLUTION_OUTPUT_RING - 1u);
    *outputLeft = runtime->outputRing[0][outputIndex];
    *outputRight = runtime->outputRing[1][outputIndex];
    runtime->outputRing[0][outputIndex] = 0.0f;
    runtime->outputRing[1][outputIndex] = 0.0f;
    const uint32_t inputIndex = (uint32_t)position & (N60_CONVOLUTION_INPUT_RING - 1u);
    runtime->inputRing[0][inputIndex] = inputLeft;
    runtime->inputRing[1][inputIndex] = inputRight;
    runtime->position = position + 1u;

    if ((runtime->position & (N60_CONVOLUTION_PARTITION_FRAMES - 1u)) == 0u) {
        process_tick(convolver, &convolver->programs[slot], runtime);
    }
    return true;
}

void N60PartitionedConvolverMarkIdle(N60PartitionedConvolver *convolver) {
    if (convolver == NULL) return;
    atomic_fetch_add_explicit(&convolver->idleEpoch, 1u, memory_order_release);
}
