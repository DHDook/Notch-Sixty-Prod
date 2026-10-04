#ifndef N60BinauralRenderer_h
#define N60BinauralRenderer_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "N60BinauralProfile.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_BINAURAL_PARTITION_FRAMES 128u
#define N60_BINAURAL_FFT_SIZE (N60_BINAURAL_PARTITION_FRAMES * 2u)
#define N60_BINAURAL_MAX_TAPS 8192u
#define N60_BINAURAL_MAX_PARTITIONS (N60_BINAURAL_MAX_TAPS / N60_BINAURAL_PARTITION_FRAMES)
#define N60_BINAURAL_EAR_COUNT 2u

typedef struct {
    float real;
    float imag;
} N60BinauralComplex;

typedef struct N60BinauralRenderer {
    N60BinauralProfileDescriptor descriptor;
    bool prepared;
    uint32_t partitionCount;

    /// Channel-major, then ear, partition and FFT bin.
    N60BinauralComplex * _Nullable kernels;
    /// Channel-major input FFT history. The same input spectrum is shared by
    /// both ear filters, avoiding duplicated input transforms.
    N60BinauralComplex * _Nullable history;

    float inputBlock[N60_MAX_PROGRAM_CHANNELS][N60_BINAURAL_PARTITION_FRAMES];
    float outputBlock[N60_BINAURAL_EAR_COUNT][N60_BINAURAL_PARTITION_FRAMES];
    float overlap[N60_BINAURAL_EAR_COUNT][N60_BINAURAL_PARTITION_FRAMES];
    uint32_t fill;
    uint32_t historyWritePartition;

    N60BinauralComplex scratch[N60_BINAURAL_FFT_SIZE];
    N60BinauralComplex accumulatorLeft[N60_BINAURAL_FFT_SIZE];
    N60BinauralComplex accumulatorRight[N60_BINAURAL_FFT_SIZE];
    uint16_t bitReverse[N60_BINAURAL_FFT_SIZE];
    N60BinauralComplex twiddles[N60_BINAURAL_FFT_SIZE / 2u];
} N60BinauralRenderer;

static inline size_t N60BinauralKernelComplexCount(void) {
    return (size_t)N60_MAX_PROGRAM_CHANNELS
        * (size_t)N60_BINAURAL_EAR_COUNT
        * (size_t)N60_BINAURAL_MAX_PARTITIONS
        * (size_t)N60_BINAURAL_FFT_SIZE;
}

static inline size_t N60BinauralHistoryComplexCount(void) {
    return (size_t)N60_MAX_PROGRAM_CHANNELS
        * (size_t)N60_BINAURAL_MAX_PARTITIONS
        * (size_t)N60_BINAURAL_FFT_SIZE;
}

static inline size_t N60BinauralKernelIndex(
    uint32_t channel,
    uint32_t ear,
    uint32_t partition,
    uint32_t bin
) {
    return (((size_t)channel * N60_BINAURAL_EAR_COUNT + ear) * N60_BINAURAL_MAX_PARTITIONS + partition)
        * N60_BINAURAL_FFT_SIZE + bin;
}

static inline size_t N60BinauralHistoryIndex(
    uint32_t channel,
    uint32_t partition,
    uint32_t bin
) {
    return ((size_t)channel * N60_BINAURAL_MAX_PARTITIONS + partition)
        * N60_BINAURAL_FFT_SIZE + bin;
}

static inline N60BinauralComplex N60BinauralComplexMultiply(
    N60BinauralComplex lhs,
    N60BinauralComplex rhs
) {
    N60BinauralComplex result = {
        lhs.real * rhs.real - lhs.imag * rhs.imag,
        lhs.real * rhs.imag + lhs.imag * rhs.real,
    };
    return result;
}

static inline void N60BinauralTransform(
    N60BinauralRenderer * _Nonnull renderer,
    N60BinauralComplex * _Nonnull values,
    bool inverse
) {
    for (uint32_t index = 0; index < N60_BINAURAL_FFT_SIZE; ++index) {
        const uint32_t reversed = renderer->bitReverse[index];
        if (reversed > index) {
            const N60BinauralComplex temporary = values[index];
            values[index] = values[reversed];
            values[reversed] = temporary;
        }
    }

    for (uint32_t length = 2u; length <= N60_BINAURAL_FFT_SIZE; length <<= 1u) {
        const uint32_t halfLength = length >> 1u;
        const uint32_t twiddleStep = N60_BINAURAL_FFT_SIZE / length;
        for (uint32_t base = 0; base < N60_BINAURAL_FFT_SIZE; base += length) {
            for (uint32_t offset = 0; offset < halfLength; ++offset) {
                N60BinauralComplex twiddle = renderer->twiddles[offset * twiddleStep];
                if (inverse) twiddle.imag = -twiddle.imag;
                const N60BinauralComplex even = values[base + offset];
                const N60BinauralComplex odd = N60BinauralComplexMultiply(
                    values[base + offset + halfLength],
                    twiddle
                );
                values[base + offset] = (N60BinauralComplex){
                    even.real + odd.real,
                    even.imag + odd.imag,
                };
                values[base + offset + halfLength] = (N60BinauralComplex){
                    even.real - odd.real,
                    even.imag - odd.imag,
                };
            }
        }
        if (length == N60_BINAURAL_FFT_SIZE) break;
    }

    if (inverse) {
        const float scale = 1.0f / (float)N60_BINAURAL_FFT_SIZE;
        for (uint32_t index = 0; index < N60_BINAURAL_FFT_SIZE; ++index) {
            values[index].real *= scale;
            values[index].imag *= scale;
        }
    }
}

static inline void N60BinauralInitializeFFT(N60BinauralRenderer * _Nonnull renderer) {
    uint32_t bits = 0u;
    for (uint32_t value = N60_BINAURAL_FFT_SIZE; value > 1u; value >>= 1u) bits += 1u;
    for (uint32_t index = 0; index < N60_BINAURAL_FFT_SIZE; ++index) {
        uint32_t source = index;
        uint32_t reversed = 0u;
        for (uint32_t bit = 0; bit < bits; ++bit) {
            reversed = (reversed << 1u) | (source & 1u);
            source >>= 1u;
        }
        renderer->bitReverse[index] = (uint16_t)reversed;
    }
    for (uint32_t index = 0; index < N60_BINAURAL_FFT_SIZE / 2u; ++index) {
        const double angle = -2.0 * 3.14159265358979323846 * (double)index / (double)N60_BINAURAL_FFT_SIZE;
        renderer->twiddles[index].real = (float)cos(angle);
        renderer->twiddles[index].imag = (float)sin(angle);
    }
}

static inline N60BinauralRenderer * _Nullable N60BinauralRendererCreate(void) {
    N60BinauralRenderer * _Nullable renderer =
        (N60BinauralRenderer *)calloc(1u, sizeof(N60BinauralRenderer));
    if (renderer == NULL) return NULL;
    renderer->kernels = (N60BinauralComplex *)calloc(
        N60BinauralKernelComplexCount(),
        sizeof(N60BinauralComplex)
    );
    renderer->history = (N60BinauralComplex *)calloc(
        N60BinauralHistoryComplexCount(),
        sizeof(N60BinauralComplex)
    );
    if (renderer->kernels == NULL || renderer->history == NULL) {
        free(renderer->history);
        free(renderer->kernels);
        free(renderer);
        return NULL;
    }
    N60BinauralInitializeFFT(renderer);
    return renderer;
}

static inline void N60BinauralRendererDestroy(N60BinauralRenderer * _Nullable renderer) {
    if (renderer == NULL) return;
    free(renderer->history);
    free(renderer->kernels);
    renderer->history = NULL;
    renderer->kernels = NULL;
    free(renderer);
}

static inline void N60BinauralRendererResetRuntime(N60BinauralRenderer * _Nullable renderer) {
    if (renderer == NULL) return;
    memset(renderer->history, 0, N60BinauralHistoryComplexCount() * sizeof(N60BinauralComplex));
    memset(renderer->inputBlock, 0, sizeof(renderer->inputBlock));
    memset(renderer->outputBlock, 0, sizeof(renderer->outputBlock));
    memset(renderer->overlap, 0, sizeof(renderer->overlap));
    memset(renderer->scratch, 0, sizeof(renderer->scratch));
    memset(renderer->accumulatorLeft, 0, sizeof(renderer->accumulatorLeft));
    memset(renderer->accumulatorRight, 0, sizeof(renderer->accumulatorRight));
    renderer->fill = 0u;
    renderer->historyWritePartition = 0u;
}

static inline bool N60BinauralRendererPrepareProfile(
    N60BinauralRenderer * _Nonnull renderer,
    N60BinauralProfileDescriptor descriptor,
    const float * _Nonnull leftIRs,
    const float * _Nonnull rightIRs
) {
    if (renderer == NULL
        || leftIRs == NULL
        || rightIRs == NULL
        || renderer->kernels == NULL
        || renderer->history == NULL
        || !N60BinauralProfileDescriptorIsValid(&descriptor, N60_BINAURAL_MAX_TAPS)) {
        return false;
    }
    const uint32_t partitions = (
        descriptor.tapCount + N60_BINAURAL_PARTITION_FRAMES - 1u
    ) / N60_BINAURAL_PARTITION_FRAMES;
    if (partitions == 0u || partitions > N60_BINAURAL_MAX_PARTITIONS) return false;

    const size_t totalTapCount = (size_t)descriptor.programLayout.channelCount * descriptor.tapCount;
    for (size_t index = 0; index < totalTapCount; ++index) {
        if (!isfinite(leftIRs[index]) || !isfinite(rightIRs[index])) return false;
    }

    memset(renderer->kernels, 0, N60BinauralKernelComplexCount() * sizeof(N60BinauralComplex));
    for (uint32_t channel = 0; channel < descriptor.programLayout.channelCount; ++channel) {
        const bool equalEarLFE = descriptor.lfeMode == N60BinauralLFEModeEqualEar
            && descriptor.programLayout.channels[channel] == N60ProgramChannelRoleLowFrequencyEffects;
        for (uint32_t ear = 0; ear < N60_BINAURAL_EAR_COUNT; ++ear) {
            for (uint32_t partition = 0; partition < partitions; ++partition) {
                memset(renderer->scratch, 0, sizeof(renderer->scratch));
                for (uint32_t sample = 0; sample < N60_BINAURAL_PARTITION_FRAMES; ++sample) {
                    const uint32_t tap = partition * N60_BINAURAL_PARTITION_FRAMES + sample;
                    if (tap >= descriptor.tapCount) break;
                    const size_t sourceIndex = (size_t)channel * descriptor.tapCount + tap;
                    float value = ear == 0u ? leftIRs[sourceIndex] : rightIRs[sourceIndex];
                    if (equalEarLFE) {
                        value = 0.5f * (leftIRs[sourceIndex] + rightIRs[sourceIndex]);
                    }
                    renderer->scratch[sample].real = value;
                }
                N60BinauralTransform(renderer, renderer->scratch, false);
                for (uint32_t bin = 0; bin < N60_BINAURAL_FFT_SIZE; ++bin) {
                    renderer->kernels[N60BinauralKernelIndex(channel, ear, partition, bin)] =
                        renderer->scratch[bin];
                }
            }
        }
    }

    renderer->descriptor = descriptor;
    renderer->partitionCount = partitions;
    renderer->prepared = true;
    N60BinauralRendererResetRuntime(renderer);
    return true;
}

static inline bool N60BinauralRendererPrepareFromSOFAView(
    N60BinauralRenderer * _Nonnull renderer,
    N60BinauralProfileDescriptor descriptor,
    const N60SOFAHRTFNormalizedView * _Nonnull view
) {
    if (renderer == NULL
        || view == NULL
        || !N60BinauralProfileDescriptorIsValid(&descriptor, N60_BINAURAL_MAX_TAPS)
        || !N60SOFAHRTFNormalizedViewIsValid(view, N60_BINAURAL_MAX_TAPS)
        || descriptor.sampleRate != view->sampleRate
        || descriptor.tapCount != view->tapCount) {
        return false;
    }

    const size_t totalTapCount = (size_t)descriptor.programLayout.channelCount * descriptor.tapCount;
    float * _Nullable left = (float *)calloc(totalTapCount, sizeof(float));
    float * _Nullable right = (float *)calloc(totalTapCount, sizeof(float));
    if (left == NULL || right == NULL) {
        free(right);
        free(left);
        return false;
    }

    bool valid = true;
    for (uint32_t channel = 0; channel < descriptor.programLayout.channelCount && valid; ++channel) {
        const int32_t measurement = N60SOFAFindNearestMeasurement(view, descriptor.sources[channel]);
        if (measurement < 0) {
            valid = false;
            break;
        }
        const size_t inputBase = (size_t)(uint32_t)measurement * view->tapCount;
        const size_t outputBase = (size_t)channel * descriptor.tapCount;
        for (uint32_t tap = 0; tap < descriptor.tapCount; ++tap) {
            left[outputBase + tap] = view->leftIR[inputBase + tap];
            right[outputBase + tap] = view->rightIR[inputBase + tap];
        }
    }

    const bool prepared = valid && N60BinauralRendererPrepareProfile(renderer, descriptor, left, right);
    free(right);
    free(left);
    return prepared;
}

static inline uint64_t N60BinauralRendererLatencyFrames(
    const N60BinauralRenderer * _Nullable renderer
) {
    if (renderer == NULL || !renderer->prepared) return 0u;
    return (uint64_t)N60_BINAURAL_PARTITION_FRAMES
        + (uint64_t)renderer->descriptor.declaredLatencyFrames;
}

static inline void N60BinauralRendererProcessBlock(N60BinauralRenderer * _Nonnull renderer) {
    const uint32_t channelCount = renderer->descriptor.programLayout.channelCount;
    const uint32_t writePartition = renderer->historyWritePartition;

    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        memset(renderer->scratch, 0, sizeof(renderer->scratch));
        for (uint32_t sample = 0; sample < N60_BINAURAL_PARTITION_FRAMES; ++sample) {
            renderer->scratch[sample].real = renderer->inputBlock[channel][sample];
        }
        N60BinauralTransform(renderer, renderer->scratch, false);
        for (uint32_t bin = 0; bin < N60_BINAURAL_FFT_SIZE; ++bin) {
            renderer->history[N60BinauralHistoryIndex(channel, writePartition, bin)] =
                renderer->scratch[bin];
        }
    }

    memset(renderer->accumulatorLeft, 0, sizeof(renderer->accumulatorLeft));
    memset(renderer->accumulatorRight, 0, sizeof(renderer->accumulatorRight));

    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        for (uint32_t partition = 0; partition < renderer->partitionCount; ++partition) {
            const uint32_t historyPartition = (
                writePartition + N60_BINAURAL_MAX_PARTITIONS - partition
            ) % N60_BINAURAL_MAX_PARTITIONS;
            for (uint32_t bin = 0; bin < N60_BINAURAL_FFT_SIZE; ++bin) {
                const N60BinauralComplex input =
                    renderer->history[N60BinauralHistoryIndex(channel, historyPartition, bin)];
                const N60BinauralComplex kernelLeft =
                    renderer->kernels[N60BinauralKernelIndex(channel, 0u, partition, bin)];
                const N60BinauralComplex kernelRight =
                    renderer->kernels[N60BinauralKernelIndex(channel, 1u, partition, bin)];
                const N60BinauralComplex productLeft = N60BinauralComplexMultiply(input, kernelLeft);
                const N60BinauralComplex productRight = N60BinauralComplexMultiply(input, kernelRight);
                renderer->accumulatorLeft[bin].real += productLeft.real;
                renderer->accumulatorLeft[bin].imag += productLeft.imag;
                renderer->accumulatorRight[bin].real += productRight.real;
                renderer->accumulatorRight[bin].imag += productRight.imag;
            }
        }
    }

    N60BinauralTransform(renderer, renderer->accumulatorLeft, true);
    N60BinauralTransform(renderer, renderer->accumulatorRight, true);
    for (uint32_t sample = 0; sample < N60_BINAURAL_PARTITION_FRAMES; ++sample) {
        renderer->outputBlock[0][sample] =
            renderer->accumulatorLeft[sample].real + renderer->overlap[0][sample];
        renderer->outputBlock[1][sample] =
            renderer->accumulatorRight[sample].real + renderer->overlap[1][sample];
        renderer->overlap[0][sample] = renderer->accumulatorLeft[sample + N60_BINAURAL_PARTITION_FRAMES].real;
        renderer->overlap[1][sample] = renderer->accumulatorRight[sample + N60_BINAURAL_PARTITION_FRAMES].real;
    }

    renderer->historyWritePartition =
        (writePartition + 1u) % N60_BINAURAL_MAX_PARTITIONS;
}

/// Realtime-safe multichannel-to-binaural frame processor. IR preparation,
/// SOFA normalization, direction selection, allocation and FFT-kernel creation
/// are all control-plane responsibilities.
static inline bool N60BinauralRendererProcessFrame(
    N60BinauralRenderer * _Nonnull renderer,
    const float * _Nonnull programInput,
    uint32_t channelCount,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
) {
    if (renderer == NULL
        || programInput == NULL
        || outputLeft == NULL
        || outputRight == NULL
        || !renderer->prepared
        || channelCount != renderer->descriptor.programLayout.channelCount) {
        return false;
    }

    const uint32_t index = renderer->fill;
    float left = renderer->outputBlock[0][index];
    float right = renderer->outputBlock[1][index];
    if (!isfinite(left)) left = 0.0f;
    if (!isfinite(right)) right = 0.0f;
    *outputLeft = left;
    *outputRight = right;

    for (uint32_t channel = 0; channel < channelCount; ++channel) {
        const float sample = isfinite(programInput[channel]) ? programInput[channel] : 0.0f;
        renderer->inputBlock[channel][index] = sample;
    }

    renderer->fill += 1u;
    if (renderer->fill == N60_BINAURAL_PARTITION_FRAMES) {
        N60BinauralRendererProcessBlock(renderer);
        renderer->fill = 0u;
    }
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
