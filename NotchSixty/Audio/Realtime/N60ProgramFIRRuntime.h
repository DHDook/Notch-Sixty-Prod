#ifndef N60ProgramFIRRuntime_h
#define N60ProgramFIRRuntime_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60Convolution.h"
#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_PROGRAM_FIR_INACTIVE_ORDINAL UINT32_MAX
// The semantic program FIR is a separate uniformly partitioned runtime that
// preallocates per program channel, so it keeps its own smaller tap budget,
// independent of the stereo non-uniform convolver's maximum.
#define N60_PROGRAM_FIR_MAX_TAPS 32768u
#define N60_PROGRAM_FIR_MAX_PARTITIONS (N60_PROGRAM_FIR_MAX_TAPS / N60_CONVOLUTION_PARTITION_FRAMES)

typedef struct {
    float real;
    float imaginary;
} N60ProgramFIRComplex;

typedef struct N60ProgramFIRProgram N60ProgramFIRProgram;
typedef struct N60ProgramFIRRuntime N60ProgramFIRRuntime;

typedef struct {
    bool prepared;
    uint32_t channelCount;
    uint32_t activeChannelMask;
    uint32_t activeChannelCount;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t engineLatencyFrames;
    uint32_t declaredLatencyFrames;
    uint64_t kernelBytes;
    uint64_t runtimeHistoryBytes;
} N60ProgramFIRProgramInfo;

struct N60ProgramFIRProgram {
    uint32_t channelCount;
    uint32_t activeChannelMask;
    uint32_t activeChannelCount;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t declaredLatencyFrames;
    uint32_t activeOrdinalForChannel[N60_MAX_PROGRAM_CHANNELS];
    N60ProgramFIRComplex * _Nullable kernels;
};

struct N60ProgramFIRRuntime {
    const N60ProgramFIRProgram * _Nonnull program;
    uint16_t bitReverse[N60_CONVOLUTION_FFT_SIZE];
    N60ProgramFIRComplex twiddles[N60_CONVOLUTION_FFT_SIZE / 2u];
    float inputBlock[N60_MAX_PROGRAM_CHANNELS][N60_CONVOLUTION_PARTITION_FRAMES];
    float outputBlock[N60_MAX_PROGRAM_CHANNELS][N60_CONVOLUTION_PARTITION_FRAMES];
    float overlap[N60_MAX_PROGRAM_CHANNELS][N60_CONVOLUTION_PARTITION_FRAMES];
    uint32_t fill;
    uint32_t historyWritePartition;
    N60ProgramFIRComplex * _Nullable history;
    N60ProgramFIRComplex scratch[N60_CONVOLUTION_FFT_SIZE];
    N60ProgramFIRComplex accumulator[N60_CONVOLUTION_FFT_SIZE];
};

static inline uint32_t N60ProgramFIRPopCount(uint32_t value) {
    uint32_t count = 0u;
    while (value != 0u) {
        count += value & 1u;
        value >>= 1u;
    }
    return count;
}

static inline uint32_t N60ProgramFIRValidChannelMask(uint32_t channelCount) {
    if (channelCount == 0u || channelCount > N60_MAX_PROGRAM_CHANNELS) return 0u;
    if (channelCount >= 32u) return UINT32_MAX;
    return (1u << channelCount) - 1u;
}

static inline bool N60ProgramFIRProgramInfoIsValid(
    N60ProgramFIRProgramInfo info
) {
    const uint32_t validMask =
        N60ProgramFIRValidChannelMask(info.channelCount);
    if (!info.prepared
        || validMask == 0u
        || info.activeChannelMask == 0u
        || (info.activeChannelMask & ~validMask) != 0u
        || info.activeChannelCount
            != N60ProgramFIRPopCount(info.activeChannelMask)
        || info.activeChannelCount > info.channelCount
        || info.tapCount == 0u
        || info.tapCount > N60_PROGRAM_FIR_MAX_TAPS
        || info.partitionCount == 0u
        || info.partitionCount
            > N60_PROGRAM_FIR_MAX_PARTITIONS
        || info.partitionCount
            != (info.tapCount
                + N60_CONVOLUTION_PARTITION_FRAMES - 1u)
                / N60_CONVOLUTION_PARTITION_FRAMES
        || info.engineLatencyFrames
            != N60_CONVOLUTION_PARTITION_FRAMES
        || info.declaredLatencyFrames >= info.tapCount) {
        return false;
    }
    return true;
}

static inline bool N60ProgramFIRProgramInfoEqual(
    N60ProgramFIRProgramInfo lhs,
    N60ProgramFIRProgramInfo rhs
) {
    return lhs.prepared == rhs.prepared
        && lhs.channelCount == rhs.channelCount
        && lhs.activeChannelMask == rhs.activeChannelMask
        && lhs.activeChannelCount == rhs.activeChannelCount
        && lhs.tapCount == rhs.tapCount
        && lhs.partitionCount == rhs.partitionCount
        && lhs.engineLatencyFrames == rhs.engineLatencyFrames
        && lhs.declaredLatencyFrames == rhs.declaredLatencyFrames;
}


static inline N60ProgramFIRComplex N60ProgramFIRComplexMultiply(
    N60ProgramFIRComplex lhs,
    N60ProgramFIRComplex rhs
) {
    return (N60ProgramFIRComplex){
        .real = lhs.real * rhs.real - lhs.imaginary * rhs.imaginary,
        .imaginary = lhs.real * rhs.imaginary + lhs.imaginary * rhs.real,
    };
}

static inline void N60ProgramFIRInitializeFFTTable(
    uint16_t * _Nonnull bitReverse,
    N60ProgramFIRComplex * _Nonnull twiddles
) {
    uint32_t bitCount = 0u;
    for (uint32_t value = N60_CONVOLUTION_FFT_SIZE; value > 1u; value >>= 1u) {
        bitCount += 1u;
    }
    for (uint32_t index = 0u; index < N60_CONVOLUTION_FFT_SIZE; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0u;
        for (uint32_t bit = 0u; bit < bitCount; ++bit) {
            reversed = (reversed << 1u) | (source & 1u);
            source >>= 1u;
        }
        bitReverse[index] = (uint16_t)reversed;
    }
    for (uint32_t index = 0u; index < N60_CONVOLUTION_FFT_SIZE / 2u; ++index) {
        const double phase =
            -2.0 * 3.14159265358979323846
            * (double)index
            / (double)N60_CONVOLUTION_FFT_SIZE;
        twiddles[index] = (N60ProgramFIRComplex){
            .real = (float)cos(phase),
            .imaginary = (float)sin(phase),
        };
    }
}

static inline void N60ProgramFIRTransform(
    N60ProgramFIRComplex * _Nonnull values,
    bool inverse,
    const uint16_t * _Nonnull bitReverse,
    const N60ProgramFIRComplex * _Nonnull twiddles
) {
    for (uint32_t index = 0u; index < N60_CONVOLUTION_FFT_SIZE; ++index) {
        const uint32_t reversed = bitReverse[index];
        if (reversed > index) {
            const N60ProgramFIRComplex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u;
         length <= N60_CONVOLUTION_FFT_SIZE;
         length <<= 1u) {
        const uint32_t half = length >> 1u;
        const uint32_t twiddleStep = N60_CONVOLUTION_FFT_SIZE / length;
        for (uint32_t base = 0u;
             base < N60_CONVOLUTION_FFT_SIZE;
             base += length) {
            for (uint32_t offset = 0u; offset < half; ++offset) {
                N60ProgramFIRComplex twiddle =
                    twiddles[offset * twiddleStep];
                if (inverse) twiddle.imaginary = -twiddle.imaginary;
                const N60ProgramFIRComplex even = values[base + offset];
                const N60ProgramFIRComplex odd =
                    N60ProgramFIRComplexMultiply(
                        values[base + offset + half],
                        twiddle
                    );
                values[base + offset] = (N60ProgramFIRComplex){
                    .real = even.real + odd.real,
                    .imaginary = even.imaginary + odd.imaginary,
                };
                values[base + offset + half] =
                    (N60ProgramFIRComplex){
                        .real = even.real - odd.real,
                        .imaginary =
                            even.imaginary - odd.imaginary,
                    };
            }
        }
    }

    if (inverse) {
        const float scale =
            1.0f / (float)N60_CONVOLUTION_FFT_SIZE;
        for (uint32_t index = 0u;
             index < N60_CONVOLUTION_FFT_SIZE;
             ++index) {
            values[index].real *= scale;
            values[index].imaginary *= scale;
        }
    }
}

static inline size_t N60ProgramFIRKernelOffset(
    const N60ProgramFIRProgram * _Nonnull program,
    uint32_t activeOrdinal,
    uint32_t partition,
    uint32_t bin
) {
    return (
        ((size_t)activeOrdinal * program->partitionCount + partition)
        * N60_CONVOLUTION_FFT_SIZE
    ) + bin;
}

static inline size_t N60ProgramFIRHistoryOffset(
    const N60ProgramFIRProgram * _Nonnull program,
    uint32_t activeOrdinal,
    uint32_t partition,
    uint32_t bin
) {
    return N60ProgramFIRKernelOffset(
        program, activeOrdinal, partition, bin
    );
}

/// Control-plane only.
///
/// Taps are flattened [active channel in ascending program-channel order][tap].
/// Only channels selected by activeChannelMask allocate a kernel/history path.
/// Inactive program channels remain unfiltered in this runtime; the existing
/// N60ProgramLaneGraph upstream-latency contract is responsible for delaying
/// those faster lanes to the maximum active FIR latency.
static inline N60ProgramFIRProgram * _Nullable
N60ProgramFIRProgramCreate(
    uint32_t channelCount,
    uint32_t activeChannelMask,
    const float * _Nonnull taps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames
) {
    const uint32_t validMask =
        N60ProgramFIRValidChannelMask(channelCount);
    if (taps == NULL
        || validMask == 0u
        || activeChannelMask == 0u
        || (activeChannelMask & ~validMask) != 0u
        || tapCount == 0u
        || tapCount > N60_PROGRAM_FIR_MAX_TAPS
        || declaredLatencyFrames >= tapCount) {
        return NULL;
    }

    const uint32_t activeCount =
        N60ProgramFIRPopCount(activeChannelMask);
    if (activeCount == 0u
        || activeCount > channelCount) {
        return NULL;
    }

    const size_t tapSampleCount =
        (size_t)activeCount * tapCount;
    for (size_t index = 0u;
         index < tapSampleCount;
         ++index) {
        if (!isfinite(taps[index])) return NULL;
    }

    N60ProgramFIRProgram *program =
        (N60ProgramFIRProgram *)calloc(
            1u, sizeof(N60ProgramFIRProgram)
        );
    if (program == NULL) return NULL;

    program->channelCount = channelCount;
    program->activeChannelMask = activeChannelMask;
    program->activeChannelCount = activeCount;
    program->tapCount = tapCount;
    program->partitionCount =
        (tapCount + N60_CONVOLUTION_PARTITION_FRAMES - 1u)
        / N60_CONVOLUTION_PARTITION_FRAMES;
    program->declaredLatencyFrames =
        declaredLatencyFrames;

    uint32_t ordinal = 0u;
    for (uint32_t channel = 0u;
         channel < N60_MAX_PROGRAM_CHANNELS;
         ++channel) {
        program->activeOrdinalForChannel[channel] =
            N60_PROGRAM_FIR_INACTIVE_ORDINAL;
        if (channel < channelCount
            && (activeChannelMask & (1u << channel)) != 0u) {
            program->activeOrdinalForChannel[channel] =
                ordinal++;
        }
    }

    const size_t kernelCount =
        (size_t)activeCount
        * program->partitionCount
        * N60_CONVOLUTION_FFT_SIZE;
    program->kernels =
        (N60ProgramFIRComplex *)calloc(
            kernelCount,
            sizeof(N60ProgramFIRComplex)
        );
    if (program->kernels == NULL) {
        free(program);
        return NULL;
    }

    uint16_t bitReverse[N60_CONVOLUTION_FFT_SIZE] = {0};
    N60ProgramFIRComplex
        twiddles[N60_CONVOLUTION_FFT_SIZE / 2u] = {0};
    N60ProgramFIRInitializeFFTTable(
        bitReverse, twiddles
    );

    N60ProgramFIRComplex
        scratch[N60_CONVOLUTION_FFT_SIZE];
    for (uint32_t active = 0u;
         active < activeCount;
         ++active) {
        for (uint32_t partition = 0u;
             partition < program->partitionCount;
             ++partition) {
            memset(scratch, 0, sizeof(scratch));
            for (uint32_t index = 0u;
                 index < N60_CONVOLUTION_PARTITION_FRAMES;
                 ++index) {
                const uint32_t tap =
                    partition
                        * N60_CONVOLUTION_PARTITION_FRAMES
                    + index;
                if (tap >= tapCount) break;
                scratch[index].real =
                    taps[(size_t)active * tapCount + tap];
            }
            N60ProgramFIRTransform(
                scratch,
                false,
                bitReverse,
                twiddles
            );
            memcpy(
                program->kernels
                    + N60ProgramFIRKernelOffset(
                        program,
                        active,
                        partition,
                        0u
                    ),
                scratch,
                sizeof(scratch)
            );
        }
    }
    return program;
}

static inline void N60ProgramFIRProgramDestroy(
    N60ProgramFIRProgram * _Nullable program
) {
    if (program == NULL) return;
    free(program->kernels);
    program->kernels = NULL;
    free(program);
}

static inline N60ProgramFIRProgramInfo
N60ProgramFIRProgramGetInfo(
    const N60ProgramFIRProgram * _Nullable program
) {
    if (program == NULL || program->kernels == NULL) {
        return (N60ProgramFIRProgramInfo){0};
    }
    return (N60ProgramFIRProgramInfo){
        .prepared = true,
        .channelCount = program->channelCount,
        .activeChannelMask = program->activeChannelMask,
        .activeChannelCount = program->activeChannelCount,
        .tapCount = program->tapCount,
        .partitionCount = program->partitionCount,
        .engineLatencyFrames =
            N60_CONVOLUTION_PARTITION_FRAMES,
        .declaredLatencyFrames =
            program->declaredLatencyFrames,
        .kernelBytes =
            (uint64_t)program->activeChannelCount
            * program->partitionCount
            * N60_CONVOLUTION_FFT_SIZE
            * sizeof(N60ProgramFIRComplex),
        .runtimeHistoryBytes =
            (uint64_t)program->activeChannelCount
            * program->partitionCount
            * N60_CONVOLUTION_FFT_SIZE
            * sizeof(N60ProgramFIRComplex),
    };
}

/// Control-plane only.
static inline N60ProgramFIRRuntime * _Nullable
N60ProgramFIRRuntimeCreate(
    const N60ProgramFIRProgram * _Nonnull program
) {
    if (program == NULL
        || program->kernels == NULL
        || program->channelCount == 0u
        || program->channelCount
            > N60_MAX_PROGRAM_CHANNELS
        || program->activeChannelCount == 0u
        || program->partitionCount == 0u
        || program->partitionCount
            > N60_PROGRAM_FIR_MAX_PARTITIONS) {
        return NULL;
    }

    N60ProgramFIRRuntime *runtime =
        (N60ProgramFIRRuntime *)calloc(
            1u, sizeof(N60ProgramFIRRuntime)
        );
    if (runtime == NULL) return NULL;
    runtime->program = program;

    const size_t historyCount =
        (size_t)program->activeChannelCount
        * program->partitionCount
        * N60_CONVOLUTION_FFT_SIZE;
    runtime->history =
        (N60ProgramFIRComplex *)calloc(
            historyCount,
            sizeof(N60ProgramFIRComplex)
        );
    if (runtime->history == NULL) {
        free(runtime);
        return NULL;
    }
    N60ProgramFIRInitializeFFTTable(
        runtime->bitReverse,
        runtime->twiddles
    );
    return runtime;
}

static inline void N60ProgramFIRRuntimeDestroy(
    N60ProgramFIRRuntime * _Nullable runtime
) {
    if (runtime == NULL) return;
    free(runtime->history);
    runtime->history = NULL;
    runtime->program = NULL;
    free(runtime);
}

static inline void N60ProgramFIRRuntimeReset(
    N60ProgramFIRRuntime * _Nullable runtime
) {
    if (runtime == NULL || runtime->program == NULL) return;
    memset(runtime->inputBlock, 0, sizeof(runtime->inputBlock));
    memset(runtime->outputBlock, 0, sizeof(runtime->outputBlock));
    memset(runtime->overlap, 0, sizeof(runtime->overlap));
    memset(runtime->scratch, 0, sizeof(runtime->scratch));
    memset(runtime->accumulator, 0, sizeof(runtime->accumulator));

    const size_t historyCount =
        (size_t)runtime->program->activeChannelCount
        * runtime->program->partitionCount
        * N60_CONVOLUTION_FFT_SIZE;
    memset(
        runtime->history,
        0,
        historyCount
            * sizeof(N60ProgramFIRComplex)
    );
    runtime->fill = 0u;
    runtime->historyWritePartition = 0u;
}

static inline bool N60ProgramFIRProcessBlock(
    N60ProgramFIRRuntime * _Nonnull runtime
) {
    if (runtime == NULL
        || runtime->program == NULL
        || runtime->history == NULL) {
        return false;
    }

    const N60ProgramFIRProgram *program =
        runtime->program;
    const uint32_t historyWrite =
        runtime->historyWritePartition;

    for (uint32_t channel = 0u;
         channel < program->channelCount;
         ++channel) {
        const uint32_t active =
            program->activeOrdinalForChannel[channel];
        if (active == N60_PROGRAM_FIR_INACTIVE_ORDINAL) {
            continue;
        }

        memset(
            runtime->scratch,
            0,
            sizeof(runtime->scratch)
        );
        for (uint32_t frame = 0u;
             frame < N60_CONVOLUTION_PARTITION_FRAMES;
             ++frame) {
            runtime->scratch[frame].real =
                runtime->inputBlock[channel][frame];
        }
        N60ProgramFIRTransform(
            runtime->scratch,
            false,
            runtime->bitReverse,
            runtime->twiddles
        );
        memcpy(
            runtime->history
                + N60ProgramFIRHistoryOffset(
                    program,
                    active,
                    historyWrite,
                    0u
                ),
            runtime->scratch,
            sizeof(runtime->scratch)
        );

        memset(
            runtime->accumulator,
            0,
            sizeof(runtime->accumulator)
        );
        for (uint32_t partition = 0u;
             partition < program->partitionCount;
             ++partition) {
            const uint32_t historyIndex =
                (
                    historyWrite
                    + program->partitionCount
                    - partition
                ) % program->partitionCount;
            const N60ProgramFIRComplex *history =
                runtime->history
                + N60ProgramFIRHistoryOffset(
                    program,
                    active,
                    historyIndex,
                    0u
                );
            const N60ProgramFIRComplex *kernel =
                program->kernels
                + N60ProgramFIRKernelOffset(
                    program,
                    active,
                    partition,
                    0u
                );
            for (uint32_t bin = 0u;
                 bin < N60_CONVOLUTION_FFT_SIZE;
                 ++bin) {
                const N60ProgramFIRComplex product =
                    N60ProgramFIRComplexMultiply(
                        history[bin],
                        kernel[bin]
                    );
                runtime->accumulator[bin].real
                    += product.real;
                runtime->accumulator[bin].imaginary
                    += product.imaginary;
            }
        }

        N60ProgramFIRTransform(
            runtime->accumulator,
            true,
            runtime->bitReverse,
            runtime->twiddles
        );
        for (uint32_t frame = 0u;
             frame < N60_CONVOLUTION_PARTITION_FRAMES;
             ++frame) {
            runtime->outputBlock[channel][frame] =
                runtime->accumulator[frame].real
                + runtime->overlap[channel][frame];
            runtime->overlap[channel][frame] =
                runtime->accumulator[
                    frame
                    + N60_CONVOLUTION_PARTITION_FRAMES
                ].real;
        }
    }

    runtime->historyWritePartition =
        (historyWrite + 1u)
        % program->partitionCount;
    return true;
}

/// Realtime-safe standalone sparse diagonal FIR stage.
///
/// Active channels execute their prepared FIR. Inactive channels pass through
/// immediately. A later live-graph integration MUST configure the existing
/// program-lane upstream-processing latency for active channels so inactive
/// channels receive matching coherence delay downstream.
///
/// No allocation/free, locks, logging, trigonometry, filter design, file or
/// network I/O occurs here. Non-finite input is sanitized to zero.
static inline bool N60ProgramFIRRuntimeProcessFrame(
    N60ProgramFIRRuntime * _Nonnull runtime,
    const float * _Nonnull input,
    float * _Nonnull output
) {
    if (runtime == NULL
        || runtime->program == NULL
        || input == NULL
        || output == NULL) {
        return false;
    }

    const N60ProgramFIRProgram *program =
        runtime->program;
    const uint32_t index = runtime->fill;

    for (uint32_t channel = 0u;
         channel < program->channelCount;
         ++channel) {
        const float finiteInput =
            isfinite(input[channel])
                ? input[channel]
                : 0.0f;
        const uint32_t active =
            program->activeOrdinalForChannel[channel];
        if (active == N60_PROGRAM_FIR_INACTIVE_ORDINAL) {
            output[channel] = finiteInput;
        } else {
            output[channel] =
                runtime->outputBlock[channel][index];
            runtime->inputBlock[channel][index] =
                finiteInput;
        }
    }

    uint32_t next = index + 1u;
    if (next == N60_CONVOLUTION_PARTITION_FRAMES) {
        if (!N60ProgramFIRProcessBlock(runtime)) {
            return false;
        }
        next = 0u;
    }
    runtime->fill = next;
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
