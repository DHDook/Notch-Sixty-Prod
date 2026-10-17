#ifndef N60Convolution_h
#define N60Convolution_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Non-uniformly partitioned stereo convolver.
//
// The filter is split into three segments of increasing block size. Segment s
// with block B_s starts at tap offset O_s >= B_s - L (L = base block), so every
// segment's contribution is complete before it must be emitted and the engine
// latency stays L = 256 frames regardless of filter length:
//
//   segment 0: B = 256,  taps [0, 1024)       4 partitions
//   segment 1: B = 1024, taps [1024, 5120)    4 partitions
//   segment 2: B = 4096, taps [5120, 262144)  up to 63 partitions
//
// Cost grows with the number of partitions, not taps, so a 262144-tap filter
// (0.68 s at 384 kHz, matching 32768 taps at 48 kHz) costs a few hundred
// MFLOP/s per channel. Older-partition multiply-accumulates of the larger
// segments are spread across the block period; a boundary tick performs only
// one FFT, one partition MAC and one inverse FFT per segment.
//
// Realtime contract: ProcessSample performs no allocation, locking, logging,
// I/O or trigonometry. All buffers and vDSP FFT setups are preallocated at
// Create (lazily mapped, so physical memory follows the prepared tap count).
// Prepare/Reset are control-plane only. Sample-rate independent; stereo
// (right channel may share the left kernel).
#define N60_CONVOLUTION_PARTITION_FRAMES 256u
#define N60_CONVOLUTION_FFT_SIZE (N60_CONVOLUTION_PARTITION_FRAMES * 2u)
#define N60_CONVOLUTION_MAX_TAPS 262144u
#define N60_CONVOLUTION_SEGMENT_COUNT 3u
#define N60_CONVOLUTION_SEGMENT0_BLOCK 256u
#define N60_CONVOLUTION_SEGMENT0_PARTITIONS 4u
#define N60_CONVOLUTION_SEGMENT1_BLOCK 1024u
#define N60_CONVOLUTION_SEGMENT1_PARTITIONS 4u
#define N60_CONVOLUTION_SEGMENT2_BLOCK 4096u
#define N60_CONVOLUTION_SEGMENT1_OFFSET \
    (N60_CONVOLUTION_SEGMENT0_BLOCK * N60_CONVOLUTION_SEGMENT0_PARTITIONS)
#define N60_CONVOLUTION_SEGMENT2_OFFSET \
    (N60_CONVOLUTION_SEGMENT1_OFFSET + N60_CONVOLUTION_SEGMENT1_BLOCK * N60_CONVOLUTION_SEGMENT1_PARTITIONS)
#define N60_CONVOLUTION_SEGMENT2_PARTITIONS \
    ((N60_CONVOLUTION_MAX_TAPS - N60_CONVOLUTION_SEGMENT2_OFFSET + N60_CONVOLUTION_SEGMENT2_BLOCK - 1u) \
        / N60_CONVOLUTION_SEGMENT2_BLOCK)
#define N60_CONVOLUTION_MAX_PARTITIONS \
    (N60_CONVOLUTION_SEGMENT0_PARTITIONS + N60_CONVOLUTION_SEGMENT1_PARTITIONS \
        + N60_CONVOLUTION_SEGMENT2_PARTITIONS)

static inline uint32_t N60ConvolutionCeilDivide(uint32_t value, uint32_t divisor) {
    return (value + divisor - 1u) / divisor;
}

/// Partitions used by each segment for `tapCount` taps (0 if unused).
static inline uint32_t N60ConvolutionSegmentPartitionCount(uint32_t tapCount, uint32_t segment) {
    switch (segment) {
    case 0u: {
        uint32_t taps = tapCount < N60_CONVOLUTION_SEGMENT1_OFFSET ? tapCount : N60_CONVOLUTION_SEGMENT1_OFFSET;
        return N60ConvolutionCeilDivide(taps, N60_CONVOLUTION_SEGMENT0_BLOCK);
    }
    case 1u: {
        if (tapCount <= N60_CONVOLUTION_SEGMENT1_OFFSET) return 0u;
        uint32_t end = tapCount < N60_CONVOLUTION_SEGMENT2_OFFSET ? tapCount : N60_CONVOLUTION_SEGMENT2_OFFSET;
        return N60ConvolutionCeilDivide(end - N60_CONVOLUTION_SEGMENT1_OFFSET, N60_CONVOLUTION_SEGMENT1_BLOCK);
    }
    case 2u:
        if (tapCount <= N60_CONVOLUTION_SEGMENT2_OFFSET) return 0u;
        return N60ConvolutionCeilDivide(tapCount - N60_CONVOLUTION_SEGMENT2_OFFSET, N60_CONVOLUTION_SEGMENT2_BLOCK);
    default:
        return 0u;
    }
}

/// Total partitions across segments; this is ProgramInfo.partitionCount.
static inline uint32_t N60ConvolutionPartitionCountForTapCount(uint32_t tapCount) {
    if (tapCount == 0u || tapCount > N60_CONVOLUTION_MAX_TAPS) return 0u;
    return N60ConvolutionSegmentPartitionCount(tapCount, 0u)
        + N60ConvolutionSegmentPartitionCount(tapCount, 1u)
        + N60ConvolutionSegmentPartitionCount(tapCount, 2u);
}
// Three program slots for two immutable graph snapshot slots guarantees a
// spare control-plane preparation target while up to two graph generations
// may still be referenced by the render path.
#define N60_CONVOLUTION_PROGRAM_SLOTS 3u
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

// Control-plane only. Cascades two FIR kernels using an allocation-backed FFT.
// The result length is lhsCount + rhsCount - 1 and must not exceed the realtime
// convolver's fixed maximum tap budget.
bool N60FIRConvolveControlPlane(
    const float * _Nonnull lhs,
    uint32_t lhsCount,
    const float * _Nonnull rhs,
    uint32_t rhsCount,
    float * _Nonnull output,
    uint32_t outputCapacity
);

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
