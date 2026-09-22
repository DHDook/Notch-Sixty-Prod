#ifndef N60Convolution_h
#define N60Convolution_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CONVOLUTION_PARTITION_FRAMES 256u
#define N60_CONVOLUTION_FFT_SIZE (N60_CONVOLUTION_PARTITION_FRAMES * 2u)
#define N60_CONVOLUTION_MAX_TAPS 32768u
#define N60_CONVOLUTION_MAX_PARTITIONS (N60_CONVOLUTION_MAX_TAPS / N60_CONVOLUTION_PARTITION_FRAMES)
#define N60_CONVOLUTION_PROGRAM_SLOTS 2u
#define N60_CONVOLUTION_NO_PROGRAM UINT32_MAX

typedef struct N60PartitionedConvolver N60PartitionedConvolver;

typedef struct {
    bool prepared;
    uint64_t generation;
    uint32_t tapCount;
    uint32_t partitionCount;
    uint32_t engineLatencyFrames;
    uint32_t declaredLatencyFrames;
} N60ConvolutionProgramInfo;

N60PartitionedConvolver * _Nullable N60PartitionedConvolverCreate(void);
void N60PartitionedConvolverDestroy(N60PartitionedConvolver * _Nonnull convolver);
void N60PartitionedConvolverReset(N60PartitionedConvolver * _Nonnull convolver);

// Control-plane only. FFT preparation, allocation-independent kernel conversion,
// and runtime reset happen before publication. The slot must not be the slot
// currently consumed by the realtime render path.
bool N60PartitionedConvolverPrepareProgram(
    N60PartitionedConvolver * _Nonnull convolver,
    uint32_t slot,
    const float * _Nonnull leftTaps,
    const float * _Nullable rightTaps,
    uint32_t tapCount,
    uint32_t declaredLatencyFrames,
    uint64_t * _Nullable generationOut
);

N60ConvolutionProgramInfo N60PartitionedConvolverProgramInfo(
    const N60PartitionedConvolver * _Nonnull convolver,
    uint32_t slot
);

bool N60PartitionedConvolverProgramMatches(
    const N60PartitionedConvolver * _Nonnull convolver,
    uint32_t slot,
    uint64_t generation
);

// Realtime-safe. No allocation, locks, trigonometry, logging, or I/O.
bool N60PartitionedConvolverProcessSample(
    N60PartitionedConvolver * _Nonnull convolver,
    uint32_t slot,
    uint64_t generation,
    float inputLeft,
    float inputRight,
    float * _Nonnull outputLeft,
    float * _Nonnull outputRight
);

#ifdef __cplusplus
}
#endif

#endif
