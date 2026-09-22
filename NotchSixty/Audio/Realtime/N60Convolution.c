#include "N60Convolution.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define N60_PI 3.14159265358979323846

typedef struct {
    float real;
    float imag;
} N60Complex;

typedef struct {
    bool prepared;
    uint64_t generation;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t declaredLatencyFrames;
    N60Complex *kernelLeft;
    N60Complex *kernelRight;
} N60ConvolutionProgram;

typedef struct {
    float inputLeft[N60_CONVOLUTION_PARTITION_FRAMES];
    float inputRight[N60_CONVOLUTION_PARTITION_FRAMES];
    float outputLeft[N60_CONVOLUTION_PARTITION_FRAMES];
    float outputRight[N60_CONVOLUTION_PARTITION_FRAMES];
    float overlapLeft[N60_CONVOLUTION_PARTITION_FRAMES];
    float overlapRight[N60_CONVOLUTION_PARTITION_FRAMES];
    uint32_t fill;
    uint32_t historyWritePartition;
    N60Complex *historyLeft;
    N60Complex *historyRight;
    N60Complex fftLeft[N60_CONVOLUTION_FFT_SIZE];
    N60Complex fftRight[N60_CONVOLUTION_FFT_SIZE];
} N60ConvolutionRuntime;

struct N60PartitionedConvolver {
    N60ConvolutionProgram programs[N60_CONVOLUTION_PROGRAM_SLOTS];
    N60ConvolutionRuntime runtimes[N60_CONVOLUTION_PROGRAM_SLOTS];
    uint16_t bitReverse[N60_CONVOLUTION_FFT_SIZE];
    N60Complex twiddles[N60_CONVOLUTION_FFT_SIZE / 2u];
    _Atomic uint32_t activeSlot;
    uint64_t nextGeneration;
};

static N60Complex complex_multiply(N60Complex lhs, N60Complex rhs) {
    N60Complex result = {
        lhs.real * rhs.real - lhs.imag * rhs.imag,
        lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return result;
}

static void transform(N60PartitionedConvolver *convolver, N60Complex *values, bool inverse) {
    for (uint32_t index = 0; index < N60_CONVOLUTION_FFT_SIZE; ++index) {
        uint32_t reversed = convolver->bitReverse[index];
        if (reversed > index) {
            N60Complex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2; length <= N60_CONVOLUTION_FFT_SIZE; length <<= 1) {
        uint32_t halfLength = length >> 1;
        uint32_t twiddleStep = N60_CONVOLUTION_FFT_SIZE / length;
        for (uint32_t base = 0; base < N60_CONVOLUTION_FFT_SIZE; base += length) {
            for (uint32_t offset = 0; offset < halfLength; ++offset) {
                N60Complex twiddle = convolver->twiddles[offset * twiddleStep];
                if (inverse) twiddle.imag = -twiddle.imag;
                N60Complex even = values[base + offset];
                N60Complex odd = complex_multiply(values[base + offset + halfLength], twiddle);
                values[base + offset] = (N60Complex){even.real + odd.real, even.imag + odd.imag};
                values[base + offset + halfLength] = (N60Complex){even.real - odd.real, even.imag - odd.imag};
            }
        }
    }

    if (inverse) {
        float scale = 1.0f / (float)N60_CONVOLUTION_FFT_SIZE;
        for (uint32_t index = 0; index < N60_CONVOLUTION_FFT_SIZE; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
}

static size_t spectrum_storage_count(void) {
    return (size_t)N60_CONVOLUTION_MAX_PARTITIONS * (size_t)N60_CONVOLUTION_FFT_SIZE;
}

static void reset_runtime(N60ConvolutionRuntime *runtime) {
    memset(runtime->inputLeft, 0, sizeof(runtime->inputLeft));
    memset(runtime->inputRight, 0, sizeof(runtime->inputRight));
    memset(runtime->outputLeft, 0, sizeof(runtime->outputLeft));
    memset(runtime->outputRight, 0, sizeof(runtime->outputRight));
    memset(runtime->overlapLeft, 0, sizeof(runtime->overlapLeft));
    memset(runtime->overlapRight, 0, sizeof(runtime->overlapRight));
    memset(runtime->fftLeft, 0, sizeof(runtime->fftLeft));
    memset(runtime->fftRight, 0, sizeof(runtime->fftRight));
    runtime->fill = 0;
    runtime->historyWritePartition = 0;
    if (runtime->historyLeft != NULL) {
        memset(runtime->historyLeft, 0, spectrum_storage_count() * sizeof(N60Complex));
    }
    if (runtime->historyRight != NULL) {
        memset(runtime->historyRight, 0, spectrum_storage_count() * sizeof(N60Complex));
    }
}

static bool allocate_slot(N60PartitionedConvolver *convolver, uint32_t slot) {
    size_t count = spectrum_storage_count();
    convolver->programs[slot].kernelLeft = calloc(count, sizeof(N60Complex));
    convolver->programs[slot].kernelRight = calloc(count, sizeof(N60Complex));
    convolver->runtimes[slot].historyLeft = calloc(count, sizeof(N60Complex));
    convolver->runtimes[slot].historyRight = calloc(count, sizeof(N60Complex));
    return convolver->programs[slot].kernelLeft != NULL
        && convolver->programs[slot].kernelRight != NULL
        && convolver->runtimes[slot].historyLeft != NULL
        && convolver->runtimes[slot].historyRight != NULL;
}

N60PartitionedConvolver *N60PartitionedConvolverCreate(void) {
    N60PartitionedConvolver *convolver = calloc(1, sizeof(N60PartitionedConvolver));
    if (convolver == NULL) return NULL;

    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        if (!allocate_slot(convolver, slot)) {
            N60PartitionedConvolverDestroy(convolver);
            return NULL;
        }
    }

    uint32_t bitCount = 0;
    for (uint32_t value = N60_CONVOLUTION_FFT_SIZE; value > 1; value >>= 1) bitCount += 1;
    for (uint32_t index = 0; index < N60_CONVOLUTION_FFT_SIZE; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0;
        for (uint32_t bit = 0; bit < bitCount; ++bit) {
            reversed = (reversed << 1) | (source & 1u);
            source >>= 1;
        }
        convolver->bitReverse[index] = (uint16_t)reversed;
    }
    for (uint32_t index = 0; index < N60_CONVOLUTION_FFT_SIZE / 2u; ++index) {
        double phase = -2.0 * N60_PI * (double)index / (double)N60_CONVOLUTION_FFT_SIZE;
        convolver->twiddles[index] = (N60Complex){(float)cos(phase), (float)sin(phase)};
    }

    atomic_store_explicit(&convolver->activeSlot, N60_CONVOLUTION_NO_PROGRAM, memory_order_relaxed);
    return convolver;
}

void N60PartitionedConvolverDestroy(N60PartitionedConvolver *convolver) {
    if (convolver == NULL) return;
    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        free(convolver->programs[slot].kernelLeft);
        free(convolver->programs[slot].kernelRight);
        free(convolver->runtimes[slot].historyLeft);
        free(convolver->runtimes[slot].historyRight);
    }
    free(convolver);
}

void N60PartitionedConvolverReset(N60PartitionedConvolver *convolver) {
    if (convolver == NULL) return;
    for (uint32_t slot = 0; slot < N60_CONVOLUTION_PROGRAM_SLOTS; ++slot) {
        reset_runtime(&convolver->runtimes[slot]);
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

    N60ConvolutionProgram *program = &convolver->programs[slot];
    size_t totalCount = spectrum_storage_count();
    memset(program->kernelLeft, 0, totalCount * sizeof(N60Complex));
    memset(program->kernelRight, 0, totalCount * sizeof(N60Complex));

    uint32_t partitionCount = (tapCount + N60_CONVOLUTION_PARTITION_FRAMES - 1u)
        / N60_CONVOLUTION_PARTITION_FRAMES;
    N60Complex scratch[N60_CONVOLUTION_FFT_SIZE];
    const float *effectiveRightTaps = rightTaps != NULL ? rightTaps : leftTaps;

    for (uint32_t partition = 0; partition < partitionCount; ++partition) {
        memset(scratch, 0, sizeof(scratch));
        for (uint32_t index = 0; index < N60_CONVOLUTION_PARTITION_FRAMES; ++index) {
            uint32_t tapIndex = partition * N60_CONVOLUTION_PARTITION_FRAMES + index;
            if (tapIndex < tapCount) scratch[index].real = leftTaps[tapIndex];
        }
        transform(convolver, scratch, false);
        memcpy(
            &program->kernelLeft[(size_t)partition * N60_CONVOLUTION_FFT_SIZE],
            scratch,
            sizeof(scratch)
        );

        memset(scratch, 0, sizeof(scratch));
        for (uint32_t index = 0; index < N60_CONVOLUTION_PARTITION_FRAMES; ++index) {
            uint32_t tapIndex = partition * N60_CONVOLUTION_PARTITION_FRAMES + index;
            if (tapIndex < tapCount) scratch[index].real = effectiveRightTaps[tapIndex];
        }
        transform(convolver, scratch, false);
        memcpy(
            &program->kernelRight[(size_t)partition * N60_CONVOLUTION_FFT_SIZE],
            scratch,
            sizeof(scratch)
        );
    }

    program->prepared = true;
    program->tapCount = tapCount;
    program->partitionCount = partitionCount;
    program->declaredLatencyFrames = declaredLatencyFrames;
    program->generation = ++convolver->nextGeneration;
    reset_runtime(&convolver->runtimes[slot]);
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

static void process_block(N60PartitionedConvolver *convolver, uint32_t slot) {
    N60ConvolutionProgram *program = &convolver->programs[slot];
    N60ConvolutionRuntime *runtime = &convolver->runtimes[slot];
    uint32_t historyWrite = runtime->historyWritePartition;

    memset(runtime->fftLeft, 0, sizeof(runtime->fftLeft));
    memset(runtime->fftRight, 0, sizeof(runtime->fftRight));
    for (uint32_t index = 0; index < N60_CONVOLUTION_PARTITION_FRAMES; ++index) {
        runtime->fftLeft[index].real = runtime->inputLeft[index];
        runtime->fftRight[index].real = runtime->inputRight[index];
    }
    transform(convolver, runtime->fftLeft, false);
    transform(convolver, runtime->fftRight, false);

    memcpy(
        &runtime->historyLeft[(size_t)historyWrite * N60_CONVOLUTION_FFT_SIZE],
        runtime->fftLeft,
        sizeof(runtime->fftLeft)
    );
    memcpy(
        &runtime->historyRight[(size_t)historyWrite * N60_CONVOLUTION_FFT_SIZE],
        runtime->fftRight,
        sizeof(runtime->fftRight)
    );

    memset(runtime->fftLeft, 0, sizeof(runtime->fftLeft));
    memset(runtime->fftRight, 0, sizeof(runtime->fftRight));
    for (uint32_t partition = 0; partition < program->partitionCount; ++partition) {
        uint32_t historyIndex = (historyWrite + N60_CONVOLUTION_MAX_PARTITIONS - partition)
            % N60_CONVOLUTION_MAX_PARTITIONS;
        N60Complex *inputLeft = &runtime->historyLeft[(size_t)historyIndex * N60_CONVOLUTION_FFT_SIZE];
        N60Complex *inputRight = &runtime->historyRight[(size_t)historyIndex * N60_CONVOLUTION_FFT_SIZE];
        N60Complex *kernelLeft = &program->kernelLeft[(size_t)partition * N60_CONVOLUTION_FFT_SIZE];
        N60Complex *kernelRight = &program->kernelRight[(size_t)partition * N60_CONVOLUTION_FFT_SIZE];
        for (uint32_t bin = 0; bin < N60_CONVOLUTION_FFT_SIZE; ++bin) {
            N60Complex leftProduct = complex_multiply(inputLeft[bin], kernelLeft[bin]);
            N60Complex rightProduct = complex_multiply(inputRight[bin], kernelRight[bin]);
            runtime->fftLeft[bin].real += leftProduct.real;
            runtime->fftLeft[bin].imag += leftProduct.imag;
            runtime->fftRight[bin].real += rightProduct.real;
            runtime->fftRight[bin].imag += rightProduct.imag;
        }
    }

    transform(convolver, runtime->fftLeft, true);
    transform(convolver, runtime->fftRight, true);
    for (uint32_t index = 0; index < N60_CONVOLUTION_PARTITION_FRAMES; ++index) {
        runtime->outputLeft[index] = runtime->fftLeft[index].real + runtime->overlapLeft[index];
        runtime->outputRight[index] = runtime->fftRight[index].real + runtime->overlapRight[index];
        runtime->overlapLeft[index] = runtime->fftLeft[index + N60_CONVOLUTION_PARTITION_FRAMES].real;
        runtime->overlapRight[index] = runtime->fftRight[index + N60_CONVOLUTION_PARTITION_FRAMES].real;
    }
    runtime->historyWritePartition = (historyWrite + 1u) % N60_CONVOLUTION_MAX_PARTITIONS;
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
    uint32_t index = runtime->fill;
    *outputLeft = runtime->outputLeft[index];
    *outputRight = runtime->outputRight[index];
    runtime->inputLeft[index] = inputLeft;
    runtime->inputRight[index] = inputRight;

    index += 1;
    if (index == N60_CONVOLUTION_PARTITION_FRAMES) {
        process_block(convolver, slot);
        index = 0;
    }
    runtime->fill = index;
    return true;
}
