#ifndef N60MIMOFIRRuntime_h
#define N60MIMOFIRRuntime_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_MIMO_FIR_MAX_CHANNELS 4u
#define N60_MIMO_FIR_PARTITION_FRAMES 256u
#define N60_MIMO_FIR_FFT_SIZE (N60_MIMO_FIR_PARTITION_FRAMES * 2u)
#define N60_MIMO_FIR_MAX_TAPS 4096u
#define N60_MIMO_FIR_MAX_PARTITIONS     (N60_MIMO_FIR_MAX_TAPS / N60_MIMO_FIR_PARTITION_FRAMES)

typedef struct {
    float real;
    float imaginary;
} N60MIMOFIRComplex;

typedef struct N60MIMOFIRProgram N60MIMOFIRProgram;
typedef struct N60MIMOFIRRuntime N60MIMOFIRRuntime;

typedef struct {
    bool prepared;
    uint32_t channelCount;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t engineLatencyFrames;
    uint32_t declaredLatencyFrames;
    uint64_t kernelBytes;
    uint64_t runtimeHistoryBytes;
} N60MIMOFIRProgramInfo;

static inline size_t N60MIMOFIRTapOffset(
    uint32_t channelCount,
    uint32_t tapCount,
    uint32_t output,
    uint32_t input,
    uint32_t tap
) {
    return (((size_t)output * channelCount + input) * tapCount) + tap;
}

struct N60MIMOFIRProgram {
    uint32_t channelCount;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t declaredLatencyFrames;
    N60MIMOFIRComplex * _Nullable kernels;
};

struct N60MIMOFIRRuntime {
    const N60MIMOFIRProgram * _Nonnull program;
    uint16_t bitReverse[N60_MIMO_FIR_FFT_SIZE];
    N60MIMOFIRComplex twiddles[N60_MIMO_FIR_FFT_SIZE / 2u];
    float inputBlock[N60_MIMO_FIR_MAX_CHANNELS][N60_MIMO_FIR_PARTITION_FRAMES];
    float outputBlock[N60_MIMO_FIR_MAX_CHANNELS][N60_MIMO_FIR_PARTITION_FRAMES];
    float overlap[N60_MIMO_FIR_MAX_CHANNELS][N60_MIMO_FIR_PARTITION_FRAMES];
    uint32_t fill;
    uint32_t historyWritePartition;
    N60MIMOFIRComplex * _Nullable history;
    N60MIMOFIRComplex scratch[N60_MIMO_FIR_FFT_SIZE];
    N60MIMOFIRComplex accumulator[N60_MIMO_FIR_FFT_SIZE];
};

static inline N60MIMOFIRComplex N60MIMOFIRComplexMultiply(
    N60MIMOFIRComplex lhs,
    N60MIMOFIRComplex rhs
) {
    return (N60MIMOFIRComplex){
        .real = lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
        .imaginary = lhs.real * rhs.imaginary + lhs.imaginary * rhs.real,
    };
}

static inline void N60MIMOFIRInitializeFFTTable(
    uint16_t * _Nonnull bitReverse,
    N60MIMOFIRComplex * _Nonnull twiddles
) {
    uint32_t bitCount = 0u;
    for (uint32_t value = N60_MIMO_FIR_FFT_SIZE; value > 1u; value >>= 1u) {
        bitCount += 1u;
    }
    for (uint32_t index = 0u; index < N60_MIMO_FIR_FFT_SIZE; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0u;
        for (uint32_t bit = 0u; bit < bitCount; ++bit) {
            reversed = (reversed << 1u) | (source & 1u);
            source >>= 1u;
        }
        bitReverse[index] = (uint16_t)reversed;
    }
    for (uint32_t index = 0u; index < N60_MIMO_FIR_FFT_SIZE / 2u; ++index) {
        const double phase =
            -2.0 * 3.14159265358979323846
            * (double)index
            / (double)N60_MIMO_FIR_FFT_SIZE;
        twiddles[index] = (N60MIMOFIRComplex){
            .real = (float)cos(phase),
            .imaginary = (float)sin(phase),
        };
    }
}

static inline void N60MIMOFIRTransform(
    N60MIMOFIRComplex * _Nonnull values,
    bool inverse,
    const uint16_t * _Nonnull bitReverse,
    const N60MIMOFIRComplex * _Nonnull twiddles
) {
    for (uint32_t index = 0u; index < N60_MIMO_FIR_FFT_SIZE; ++index) {
        const uint32_t reversed = bitReverse[index];
        if (reversed > index) {
            const N60MIMOFIRComplex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u;
         length <= N60_MIMO_FIR_FFT_SIZE;
         length <<= 1u) {
        const uint32_t half = length >> 1u;
        const uint32_t twiddleStep = N60_MIMO_FIR_FFT_SIZE / length;
        for (uint32_t base = 0u;
             base < N60_MIMO_FIR_FFT_SIZE;
             base += length) {
            for (uint32_t offset = 0u; offset < half; ++offset) {
                N60MIMOFIRComplex twiddle =
                    twiddles[offset * twiddleStep];
                if (inverse) twiddle.imaginary = -twiddle.imaginary;
                const N60MIMOFIRComplex even = values[base + offset];
                const N60MIMOFIRComplex odd = N60MIMOFIRComplexMultiply(
                    values[base + offset + half],
                    twiddle
                );
                values[base + offset] = (N60MIMOFIRComplex){
                    .real = even.real + odd.real,
                    .imaginary = even.imaginary + odd.imaginary,
                };
                values[base + offset + half] = (N60MIMOFIRComplex){
                    .real = even.real - odd.real,
                    .imaginary = even.imaginary - odd.imaginary,
                };
            }
        }
    }

    if (inverse) {
        const float scale = 1.0f / (float)N60_MIMO_FIR_FFT_SIZE;
        for (uint32_t index = 0u; index < N60_MIMO_FIR_FFT_SIZE; ++index) {
            values[index].real *= scale;
            values[index].imaginary *= scale;
        }
    }
}

static inline size_t N60MIMOFIRKernelOffset(
    const N60MIMOFIRProgram * _Nonnull program,
    uint32_t output,
    uint32_t input,
    uint32_t partition,
    uint32_t bin
) {
    return (
        (((size_t)output * program->channelCount + input)
            * program->partitionCount + partition)
        * N60_MIMO_FIR_FFT_SIZE
    ) + bin;
}

static inline size_t N60MIMOFIRHistoryOffset(
    const N60MIMOFIRProgram * _Nonnull program,
    uint32_t input,
    uint32_t partition,
    uint32_t bin
) {
    return (
        ((size_t)input * program->partitionCount + partition)
        * N60_MIMO_FIR_FFT_SIZE
    ) + bin;
}

/// Control-plane only. Taps are flattened [output][input][tap]. The returned
/// object is immutable and may be shared with exactly one prepared runtime at a
/// time. Creation performs allocation, trigonometry and FFT preparation.
static inline N60MIMOFIRProgram * _Nullable N60MIMOFIRProgramCreate(
    uint32_t channelCount,
    const float * _Nonnull taps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames
) {
    if (taps == NULL
        || channelCount == 0u
        || channelCount > N60_MIMO_FIR_MAX_CHANNELS
        || tapCount == 0u
        || tapCount > N60_MIMO_FIR_MAX_TAPS
        || declaredLatencyFrames >= tapCount) {
        return NULL;
    }

    const size_t tapSampleCount =
        (size_t)channelCount * channelCount * tapCount;
    for (size_t index = 0u; index < tapSampleCount; ++index) {
        if (!isfinite(taps[index])) return NULL;
    }

    N60MIMOFIRProgram *program =
        (N60MIMOFIRProgram *)calloc(1u, sizeof(N60MIMOFIRProgram));
    if (program == NULL) return NULL;
    program->channelCount = channelCount;
    program->tapCount = tapCount;
    program->partitionCount =
        (tapCount + N60_MIMO_FIR_PARTITION_FRAMES - 1u)
        / N60_MIMO_FIR_PARTITION_FRAMES;
    program->declaredLatencyFrames = declaredLatencyFrames;

    const size_t kernelCount =
        (size_t)channelCount
        * channelCount
        * program->partitionCount
        * N60_MIMO_FIR_FFT_SIZE;
    program->kernels = (N60MIMOFIRComplex *)calloc(
        kernelCount,
        sizeof(N60MIMOFIRComplex)
    );
    if (program->kernels == NULL) {
        free(program);
        return NULL;
    }

    uint16_t bitReverse[N60_MIMO_FIR_FFT_SIZE] = {0};
    N60MIMOFIRComplex twiddles[N60_MIMO_FIR_FFT_SIZE / 2u] = {0};
    N60MIMOFIRInitializeFFTTable(bitReverse, twiddles);

    N60MIMOFIRComplex scratch[N60_MIMO_FIR_FFT_SIZE];
    for (uint32_t output = 0u; output < channelCount; ++output) {
        for (uint32_t input = 0u; input < channelCount; ++input) {
            for (uint32_t partition = 0u;
                 partition < program->partitionCount;
                 ++partition) {
                memset(scratch, 0, sizeof(scratch));
                for (uint32_t index = 0u;
                     index < N60_MIMO_FIR_PARTITION_FRAMES;
                     ++index) {
                    const uint32_t tap =
                        partition * N60_MIMO_FIR_PARTITION_FRAMES + index;
                    if (tap >= tapCount) break;
                    scratch[index].real = taps[
                        N60MIMOFIRTapOffset(
                            channelCount,
                            tapCount,
                            output,
                            input,
                            tap
                        )
                    ];
                }
                N60MIMOFIRTransform(
                    scratch,
                    false,
                    bitReverse,
                    twiddles
                );
                memcpy(
                    program->kernels + N60MIMOFIRKernelOffset(
                        program,
                        output,
                        input,
                        partition,
                        0u
                    ),
                    scratch,
                    sizeof(scratch)
                );
            }
        }
    }
    return program;
}

static inline void N60MIMOFIRProgramDestroy(
    N60MIMOFIRProgram * _Nullable program
) {
    if (program == NULL) return;
    free(program->kernels);
    program->kernels = NULL;
    free(program);
}

static inline N60MIMOFIRProgramInfo N60MIMOFIRProgramGetInfo(
    const N60MIMOFIRProgram * _Nullable program
) {
    if (program == NULL || program->kernels == NULL) {
        return (N60MIMOFIRProgramInfo){0};
    }
    return (N60MIMOFIRProgramInfo){
        .prepared = true,
        .channelCount = program->channelCount,
        .tapCount = program->tapCount,
        .partitionCount = program->partitionCount,
        .engineLatencyFrames = N60_MIMO_FIR_PARTITION_FRAMES,
        .declaredLatencyFrames = program->declaredLatencyFrames,
        .kernelBytes =
            (uint64_t)program->channelCount
            * program->channelCount
            * program->partitionCount
            * N60_MIMO_FIR_FFT_SIZE
            * sizeof(N60MIMOFIRComplex),
        .runtimeHistoryBytes =
            (uint64_t)program->channelCount
            * program->partitionCount
            * N60_MIMO_FIR_FFT_SIZE
            * sizeof(N60MIMOFIRComplex),
    };
}

/// Control-plane only.
static inline N60MIMOFIRRuntime * _Nullable N60MIMOFIRRuntimeCreate(
    const N60MIMOFIRProgram * _Nonnull program
) {
    if (program == NULL
        || program->kernels == NULL
        || program->channelCount == 0u
        || program->channelCount > N60_MIMO_FIR_MAX_CHANNELS
        || program->partitionCount == 0u
        || program->partitionCount > N60_MIMO_FIR_MAX_PARTITIONS) {
        return NULL;
    }
    N60MIMOFIRRuntime *runtime =
        (N60MIMOFIRRuntime *)calloc(1u, sizeof(N60MIMOFIRRuntime));
    if (runtime == NULL) return NULL;
    runtime->program = program;
    const size_t historyCount =
        (size_t)program->channelCount
        * program->partitionCount
        * N60_MIMO_FIR_FFT_SIZE;
    runtime->history = (N60MIMOFIRComplex *)calloc(
        historyCount,
        sizeof(N60MIMOFIRComplex)
    );
    if (runtime->history == NULL) {
        free(runtime);
        return NULL;
    }
    N60MIMOFIRInitializeFFTTable(runtime->bitReverse, runtime->twiddles);
    return runtime;
}

static inline void N60MIMOFIRRuntimeDestroy(
    N60MIMOFIRRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    free(runtime->history);
    runtime->history = NULL;
    runtime->program = NULL;
    free(runtime);
}

static inline void N60MIMOFIRRuntimeReset(
    N60MIMOFIRRuntime * _Nullable runtime
) {
    if (runtime == NULL || runtime->program == NULL) return;
    memset(runtime->inputBlock, 0, sizeof(runtime->inputBlock));
    memset(runtime->outputBlock, 0, sizeof(runtime->outputBlock));
    memset(runtime->overlap, 0, sizeof(runtime->overlap));
    memset(runtime->scratch, 0, sizeof(runtime->scratch));
    memset(runtime->accumulator, 0, sizeof(runtime->accumulator));
    const size_t historyCount =
        (size_t)runtime->program->channelCount
        * runtime->program->partitionCount
        * N60_MIMO_FIR_FFT_SIZE;
    memset(
        runtime->history,
        0,
        historyCount * sizeof(N60MIMOFIRComplex)
    );
    runtime->fill = 0u;
    runtime->historyWritePartition = 0u;
}

static inline bool N60MIMOFIRProcessBlock(
    N60MIMOFIRRuntime * _Nonnull runtime
) {
    if (runtime == NULL
        || runtime->program == NULL
        || runtime->history == NULL) {
        return false;
    }
    const N60MIMOFIRProgram *program = runtime->program;
    const uint32_t channels = program->channelCount;
    const uint32_t historyWrite = runtime->historyWritePartition;

    for (uint32_t input = 0u; input < channels; ++input) {
        memset(runtime->scratch, 0, sizeof(runtime->scratch));
        for (uint32_t frame = 0u;
             frame < N60_MIMO_FIR_PARTITION_FRAMES;
             ++frame) {
            runtime->scratch[frame].real =
                runtime->inputBlock[input][frame];
        }
        N60MIMOFIRTransform(
            runtime->scratch,
            false,
            runtime->bitReverse,
            runtime->twiddles
        );
        memcpy(
            runtime->history + N60MIMOFIRHistoryOffset(
                program,
                input,
                historyWrite,
                0u
            ),
            runtime->scratch,
            sizeof(runtime->scratch)
        );
    }

    for (uint32_t output = 0u; output < channels; ++output) {
        memset(runtime->accumulator, 0, sizeof(runtime->accumulator));
        for (uint32_t input = 0u; input < channels; ++input) {
            for (uint32_t partition = 0u;
                 partition < program->partitionCount;
                 ++partition) {
                const uint32_t historyIndex =
                    (historyWrite + program->partitionCount - partition)
                    % program->partitionCount;
                const N60MIMOFIRComplex *history =
                    runtime->history + N60MIMOFIRHistoryOffset(
                        program,
                        input,
                        historyIndex,
                        0u
                    );
                const N60MIMOFIRComplex *kernel =
                    program->kernels + N60MIMOFIRKernelOffset(
                        program,
                        output,
                        input,
                        partition,
                        0u
                    );
                for (uint32_t bin = 0u;
                     bin < N60_MIMO_FIR_FFT_SIZE;
                     ++bin) {
                    const N60MIMOFIRComplex product =
                        N60MIMOFIRComplexMultiply(
                            history[bin],
                            kernel[bin]
                        );
                    runtime->accumulator[bin].real += product.real;
                    runtime->accumulator[bin].imaginary += product.imaginary;
                }
            }
        }

        N60MIMOFIRTransform(
            runtime->accumulator,
            true,
            runtime->bitReverse,
            runtime->twiddles
        );
        for (uint32_t frame = 0u;
             frame < N60_MIMO_FIR_PARTITION_FRAMES;
             ++frame) {
            runtime->outputBlock[output][frame] =
                runtime->accumulator[frame].real
                + runtime->overlap[output][frame];
            runtime->overlap[output][frame] =
                runtime->accumulator[
                    frame + N60_MIMO_FIR_PARTITION_FRAMES
                ].real;
        }
    }

    runtime->historyWritePartition =
        (historyWrite + 1u) % program->partitionCount;
    return true;
}

/// Realtime-safe standalone reference runtime. No allocation, free, blocking
/// lock, logging, file/network I/O, trigonometry or filter construction.
static inline bool N60MIMOFIRRuntimeProcessFrame(
    N60MIMOFIRRuntime * _Nonnull runtime,
    const float * _Nonnull input,
    float * _Nonnull output
) {
    if (runtime == NULL
        || runtime->program == NULL
        || input == NULL
        || output == NULL) {
        return false;
    }

    const uint32_t channels = runtime->program->channelCount;
    const uint32_t index = runtime->fill;
    for (uint32_t channel = 0u; channel < channels; ++channel) {
        output[channel] = runtime->outputBlock[channel][index];
        runtime->inputBlock[channel][index] =
            isfinite(input[channel]) ? input[channel] : 0.0f;
    }

    uint32_t next = index + 1u;
    if (next == N60_MIMO_FIR_PARTITION_FRAMES) {
        if (!N60MIMOFIRProcessBlock(runtime)) return false;
        next = 0u;
    }
    runtime->fill = next;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
