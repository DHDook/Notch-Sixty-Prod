#ifndef N60ChannelRouter_h
#define N60ChannelRouter_h

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#include "N60ProgramLayout.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CHANNEL_ROUTER_MAX_ROUTES (N60_MAX_PROGRAM_CHANNELS * N60_MAX_PROGRAM_CHANNELS)

typedef struct {
    uint32_t sourceChannelIndex;
    uint32_t destinationChannelIndex;
    float gainLinear;
} N60ChannelRoute;

/// Fixed-size N×M matrix. Matrix storage is destination-major:
/// matrix[destination * N60_MAX_PROGRAM_CHANNELS + source].
typedef struct {
    uint32_t sourceChannelCount;
    uint32_t destinationChannelCount;
    float matrix[N60_CHANNEL_ROUTER_MAX_ROUTES];
} N60ChannelRoutingMatrix;

static inline size_t N60ChannelRoutingMatrixOffset(uint32_t source, uint32_t destination) {
    return ((size_t)destination * (size_t)N60_MAX_PROGRAM_CHANNELS) + (size_t)source;
}

static inline N60ChannelRoutingMatrix N60ChannelRoutingMatrixMakeZero(
    uint32_t sourceChannelCount,
    uint32_t destinationChannelCount
) {
    N60ChannelRoutingMatrix result = {0};
    if (sourceChannelCount == 0u
        || sourceChannelCount > N60_MAX_PROGRAM_CHANNELS
        || destinationChannelCount == 0u
        || destinationChannelCount > N60_MAX_PROGRAM_CHANNELS) {
        return result;
    }
    result.sourceChannelCount = sourceChannelCount;
    result.destinationChannelCount = destinationChannelCount;
    return result;
}

static inline bool N60ChannelRoutingMatrixIsStructurallyValid(
    const N60ChannelRoutingMatrix * _Nullable matrix
) {
    if (matrix == NULL
        || matrix->sourceChannelCount == 0u
        || matrix->sourceChannelCount > N60_MAX_PROGRAM_CHANNELS
        || matrix->destinationChannelCount == 0u
        || matrix->destinationChannelCount > N60_MAX_PROGRAM_CHANNELS) {
        return false;
    }

    for (uint32_t destination = 0; destination < matrix->destinationChannelCount; ++destination) {
        for (uint32_t source = 0; source < matrix->sourceChannelCount; ++source) {
            if (!isfinite(matrix->matrix[N60ChannelRoutingMatrixOffset(source, destination)])) {
                return false;
            }
        }
    }
    return true;
}

/// Compile an explicit matrix from control-plane routes. Duplicate source→
/// destination edges are rejected rather than silently summed. Multiple sources
/// may feed one destination and one source may feed multiple destinations.
static inline bool N60ChannelRoutingMatrixCompile(
    uint32_t sourceChannelCount,
    uint32_t destinationChannelCount,
    const N60ChannelRoute * _Nullable routes,
    uint32_t routeCount,
    N60ChannelRoutingMatrix * _Nonnull matrixOut
) {
    if (matrixOut == NULL
        || routes == NULL
        || routeCount == 0u
        || routeCount > N60_CHANNEL_ROUTER_MAX_ROUTES) {
        return false;
    }

    N60ChannelRoutingMatrix result = N60ChannelRoutingMatrixMakeZero(
        sourceChannelCount,
        destinationChannelCount
    );
    if (result.sourceChannelCount == 0u || result.destinationChannelCount == 0u) {
        return false;
    }

    bool assigned[N60_CHANNEL_ROUTER_MAX_ROUTES] = {false};
    for (uint32_t routeIndex = 0; routeIndex < routeCount; ++routeIndex) {
        const N60ChannelRoute route = routes[routeIndex];
        if (route.sourceChannelIndex >= sourceChannelCount
            || route.destinationChannelIndex >= destinationChannelCount
            || !isfinite(route.gainLinear)) {
            return false;
        }
        const size_t offset = N60ChannelRoutingMatrixOffset(
            route.sourceChannelIndex,
            route.destinationChannelIndex
        );
        if (assigned[offset]) {
            return false;
        }
        assigned[offset] = true;
        result.matrix[offset] = route.gainLinear;
    }

    *matrixOut = result;
    return true;
}

/// Compile a lossless semantic reorder. This helper intentionally refuses to
/// drop, duplicate, invent, or mix channels: source and destination must contain
/// exactly the same unique semantic roles. Downmix/upmix policies are separate
/// product decisions and must use an explicit matrix.
static inline bool N60ChannelRoutingMatrixCompileSemanticReorder(
    const N60ProgramChannelLayout * _Nonnull sourceLayout,
    const N60ProgramChannelLayout * _Nonnull destinationLayout,
    N60ChannelRoutingMatrix * _Nonnull matrixOut
) {
    if (sourceLayout == NULL
        || destinationLayout == NULL
        || matrixOut == NULL
        || !N60ProgramChannelLayoutIsValid(sourceLayout)
        || !N60ProgramChannelLayoutIsValid(destinationLayout)
        || sourceLayout->channelCount != destinationLayout->channelCount) {
        return false;
    }

    N60ChannelRoutingMatrix result = N60ChannelRoutingMatrixMakeZero(
        sourceLayout->channelCount,
        destinationLayout->channelCount
    );

    for (uint32_t destination = 0; destination < destinationLayout->channelCount; ++destination) {
        const N60ProgramChannelRole role = destinationLayout->channels[destination];
        const int32_t source = N60ProgramChannelLayoutIndexOfRole(sourceLayout, role);
        if (source < 0) {
            return false;
        }
        result.matrix[N60ChannelRoutingMatrixOffset((uint32_t)source, destination)] = 1.0f;
    }

    for (uint32_t source = 0; source < sourceLayout->channelCount; ++source) {
        if (N60ProgramChannelLayoutIndexOfRole(destinationLayout, sourceLayout->channels[source]) < 0) {
            return false;
        }
    }

    *matrixOut = result;
    return true;
}

static inline bool N60ChannelRoutingMatrixIsIdentity(
    const N60ChannelRoutingMatrix * _Nullable matrix
) {
    if (!N60ChannelRoutingMatrixIsStructurallyValid(matrix)
        || matrix->sourceChannelCount != matrix->destinationChannelCount) {
        return false;
    }
    for (uint32_t destination = 0; destination < matrix->destinationChannelCount; ++destination) {
        for (uint32_t source = 0; source < matrix->sourceChannelCount; ++source) {
            const float expected = source == destination ? 1.0f : 0.0f;
            if (matrix->matrix[N60ChannelRoutingMatrixOffset(source, destination)] != expected) {
                return false;
            }
        }
    }
    return true;
}

/// Allocation-free, stateless single-frame application primitive. The caller
/// owns fixed input/output storage. It is suitable for a future realtime path,
/// but PR53 does not wire it into the shipping stereo callback.
static inline bool N60ChannelRoutingMatrixProcessFrame(
    const N60ChannelRoutingMatrix * _Nonnull matrix,
    const float * _Nonnull input,
    float * _Nonnull output
) {
    if (!N60ChannelRoutingMatrixIsStructurallyValid(matrix)
        || input == NULL
        || output == NULL) {
        return false;
    }

    for (uint32_t destination = 0; destination < matrix->destinationChannelCount; ++destination) {
        float sum = 0.0f;
        for (uint32_t source = 0; source < matrix->sourceChannelCount; ++source) {
            const float gain = matrix->matrix[N60ChannelRoutingMatrixOffset(source, destination)];
            sum += input[source] * gain;
        }
        output[destination] = sum;
    }
    return true;
}

#ifdef __cplusplus
}
#endif

#endif
