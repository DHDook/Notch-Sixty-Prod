#include "N60SOFABridge.h"

#include "Vendor/libmysofa/hrtf/mysofa.h"

#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#define N60_SOFA_MAX_FILE_BYTES (512ull * 1024ull * 1024ull)
#define N60_SOFA_MAX_MEASUREMENTS 131072u
#define N60_SOFA_MAX_RECEIVERS 32u
#define N60_SOFA_MAX_EMITTERS 64u
#define N60_SOFA_MAX_TAPS 65536u
#define N60_SOFA_MAX_IR_VALUES (64ull * 1024ull * 1024ull)

struct N60SOFADocument {
    struct MYSOFA_HRTF *hrtf;
    double sampleRate;
    bool emitterDependent;
};

static void N60SOFASetStatus(
    N60SOFAStatus *status,
    N60SOFAStatus value
) {
    if (status != NULL) {
        *status = value;
    }
}

static bool N60SOFASafeMultiply(
    uint64_t lhs,
    uint64_t rhs,
    uint64_t *result
) {
    if (result == NULL) return false;
    if (lhs != 0u && rhs > UINT64_MAX / lhs) return false;
    *result = lhs * rhs;
    return true;
}

static bool N60SOFACompactDimensions(
    const struct MYSOFA_ARRAY *array,
    char *result,
    size_t capacity
) {
    if (array == NULL || result == NULL || capacity < 2u) return false;
    char *source = mysofa_getAttribute(
        array->attributes,
        "DIMENSION_LIST"
    );
    if (source == NULL) return false;

    size_t count = 0u;
    for (; *source != '\0'; ++source) {
        const char value = *source;
        if (value != 'M' && value != 'R' && value != 'E'
            && value != 'N' && value != 'I' && value != 'C') {
            continue;
        }
        if (count + 1u >= capacity) return false;
        result[count++] = value;
    }
    if (count == 0u) return false;
    result[count] = '\0';
    return true;
}

static uint64_t N60SOFADimensionSize(
    const struct MYSOFA_HRTF *hrtf,
    char dimension
) {
    switch (dimension) {
    case 'M': return hrtf->M;
    case 'R': return hrtf->R;
    case 'E': return hrtf->E;
    case 'N': return hrtf->N;
    case 'C': return 3u;
    case 'I': return 1u;
    default: return 0u;
    }
}

static bool N60SOFAArrayIndex(
    const struct MYSOFA_HRTF *hrtf,
    const struct MYSOFA_ARRAY *array,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    uint32_t sample,
    uint32_t coordinate,
    uint64_t *index
) {
    if (hrtf == NULL || array == NULL || index == NULL) return false;

    char dimensions[16] = {0};
    if (!N60SOFACompactDimensions(
            array,
            dimensions,
            sizeof(dimensions))) {
        return false;
    }

    uint64_t offset = 0u;
    for (size_t position = 0u;
         dimensions[position] != '\0';
         ++position) {
        const char dimension = dimensions[position];
        const uint64_t size = N60SOFADimensionSize(hrtf, dimension);
        if (size == 0u) return false;

        uint64_t value = 0u;
        switch (dimension) {
        case 'M': value = measurement; break;
        case 'R': value = receiver; break;
        case 'E': value = emitter; break;
        case 'N': value = sample; break;
        case 'C': value = coordinate; break;
        case 'I': value = 0u; break;
        default: return false;
        }
        if (value >= size) return false;

        uint64_t multiplied = 0u;
        if (!N60SOFASafeMultiply(offset, size, &multiplied)
            || multiplied > UINT64_MAX - value) {
            return false;
        }
        offset = multiplied + value;
    }

    if (offset >= array->elements) return false;
    *index = offset;
    return true;
}

static bool N60SOFACopyCoordinate(
    const struct MYSOFA_HRTF *hrtf,
    const struct MYSOFA_ARRAY *array,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    const double fallback[3],
    double outXYZ[3]
) {
    if (hrtf == NULL || array == NULL || outXYZ == NULL) return false;
    if (array->values == NULL || array->elements == 0u) {
        if (fallback == NULL) return false;
        outXYZ[0] = fallback[0];
        outXYZ[1] = fallback[1];
        outXYZ[2] = fallback[2];
        return true;
    }

    for (uint32_t coordinate = 0u; coordinate < 3u; ++coordinate) {
        uint64_t index = 0u;
        if (!N60SOFAArrayIndex(
                hrtf,
                array,
                measurement,
                receiver,
                emitter,
                0u,
                coordinate,
                &index)) {
            return false;
        }
        const double value = array->values[index];
        if (!isfinite(value)) return false;
        outXYZ[coordinate] = value;
    }
    return true;
}

static bool N60SOFAReadScalar(
    const struct MYSOFA_HRTF *hrtf,
    const struct MYSOFA_ARRAY *array,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    double *value
) {
    if (hrtf == NULL || array == NULL || value == NULL
        || array->values == NULL || array->elements == 0u) {
        return false;
    }
    uint64_t index = 0u;
    if (!N60SOFAArrayIndex(
            hrtf,
            array,
            measurement,
            receiver,
            emitter,
            0u,
            0u,
            &index)) {
        return false;
    }
    const double result = array->values[index];
    if (!isfinite(result)) return false;
    *value = result;
    return true;
}

static bool N60SOFAValidateIRShape(
    const struct MYSOFA_HRTF *hrtf,
    bool emitterDependent
) {
    if (hrtf == NULL || hrtf->DataIR.values == NULL) return false;
    uint64_t expected = hrtf->M;
    if (!N60SOFASafeMultiply(expected, hrtf->R, &expected)) {
        return false;
    }
    if (emitterDependent
        && !N60SOFASafeMultiply(expected, hrtf->E, &expected)) {
        return false;
    }
    if (!N60SOFASafeMultiply(expected, hrtf->N, &expected)) {
        return false;
    }
    return expected == hrtf->DataIR.elements
        && expected <= N60_SOFA_MAX_IR_VALUES;
}

static N60SOFAStatus N60SOFAValidate(
    N60SOFADocument *document
) {
    if (document == NULL || document->hrtf == NULL) {
        return N60SOFAStatusInvalidArgument;
    }

    struct MYSOFA_HRTF *hrtf = document->hrtf;
    char *dataType = mysofa_getAttribute(
        hrtf->attributes,
        "DataType"
    );
    if (dataType == NULL) {
        return N60SOFAStatusUnsupportedDataType;
    }
    if (strcmp(dataType, "FIR") == 0) {
        document->emitterDependent = false;
    } else if (strcmp(dataType, "FIR-E") == 0) {
        document->emitterDependent = true;
    } else {
        return N60SOFAStatusUnsupportedDataType;
    }

    if (hrtf->I != 1u || hrtf->C != 3u
        || hrtf->M == 0u || hrtf->R == 0u
        || hrtf->E == 0u || hrtf->N == 0u) {
        return N60SOFAStatusInvalidDimensions;
    }
    if (hrtf->M > N60_SOFA_MAX_MEASUREMENTS
        || hrtf->R > N60_SOFA_MAX_RECEIVERS
        || hrtf->E > N60_SOFA_MAX_EMITTERS
        || hrtf->N > N60_SOFA_MAX_TAPS) {
        return N60SOFAStatusResourceLimit;
    }
    if (!N60SOFAValidateIRShape(
            hrtf,
            document->emitterDependent)) {
        return N60SOFAStatusInvalidArrayShape;
    }

    double sampleRate = 0.0;
    if (!N60SOFAReadScalar(
            hrtf,
            &hrtf->DataSamplingRate,
            0u,
            0u,
            0u,
            &sampleRate)
        || !isfinite(sampleRate)
        || sampleRate <= 0.0) {
        return N60SOFAStatusInvalidSamplingRate;
    }
    for (uint32_t measurement = 1u;
         measurement < hrtf->M;
         ++measurement) {
        double current = sampleRate;
        if (hrtf->DataSamplingRate.elements > 1u) {
            if (!N60SOFAReadScalar(
                    hrtf,
                    &hrtf->DataSamplingRate,
                    measurement,
                    0u,
                    0u,
                    &current)) {
                return N60SOFAStatusInvalidSamplingRate;
            }
        }
        const double tolerance =
            1.0e-9 * fmax(1.0, fabs(sampleRate));
        if (!isfinite(current)
            || fabs(current - sampleRate) > tolerance) {
            return N60SOFAStatusInconsistentSamplingRate;
        }
    }
    document->sampleRate = sampleRate;

    for (uint64_t index = 0u;
         index < hrtf->DataIR.elements;
         ++index) {
        if (!isfinite(hrtf->DataIR.values[index])) {
            return N60SOFAStatusNonFiniteData;
        }
    }
    for (uint64_t index = 0u;
         index < hrtf->DataDelay.elements;
         ++index) {
        if (!isfinite(hrtf->DataDelay.values[index])) {
            return N60SOFAStatusNonFiniteData;
        }
    }

    // Product code consumes a single canonical coordinate space.
    mysofa_tocartesian(hrtf);
    return N60SOFAStatusOK;
}

N60SOFADocument *N60SOFADocumentOpen(
    const char *path,
    N60SOFAStatus *status
) {
    N60SOFASetStatus(status, N60SOFAStatusInvalidArgument);
    if (path == NULL || path[0] == '\0') return NULL;

    struct stat fileInfo;
    if (stat(path, &fileInfo) != 0
        || fileInfo.st_size <= 0) {
        N60SOFASetStatus(status, N60SOFAStatusParseFailed);
        return NULL;
    }
    if ((uint64_t)fileInfo.st_size > N60_SOFA_MAX_FILE_BYTES) {
        N60SOFASetStatus(status, N60SOFAStatusFileTooLarge);
        return NULL;
    }

    int parserStatus = 0;
    struct MYSOFA_HRTF *hrtf = mysofa_load(
        path,
        &parserStatus
    );
    if (hrtf == NULL || parserStatus != MYSOFA_OK) {
        mysofa_free(hrtf);
        N60SOFASetStatus(status, N60SOFAStatusParseFailed);
        return NULL;
    }

    N60SOFADocument *document =
        (N60SOFADocument *)calloc(1u, sizeof(*document));
    if (document == NULL) {
        mysofa_free(hrtf);
        N60SOFASetStatus(status, N60SOFAStatusResourceLimit);
        return NULL;
    }
    document->hrtf = hrtf;

    const N60SOFAStatus validation =
        N60SOFAValidate(document);
    if (validation != N60SOFAStatusOK) {
        N60SOFADocumentDestroy(document);
        N60SOFASetStatus(status, validation);
        return NULL;
    }

    N60SOFASetStatus(status, N60SOFAStatusOK);
    return document;
}

void N60SOFADocumentDestroy(
    N60SOFADocument *document
) {
    if (document == NULL) return;
    mysofa_free(document->hrtf);
    free(document);
}

bool N60SOFADocumentGetMetadata(
    const N60SOFADocument *document,
    N60SOFAMetadata *metadata
) {
    if (document == NULL || document->hrtf == NULL
        || metadata == NULL) {
        return false;
    }
    metadata->measurementCount = document->hrtf->M;
    metadata->receiverCount = document->hrtf->R;
    metadata->emitterCount = document->hrtf->E;
    metadata->tapCount = document->hrtf->N;
    metadata->sampleRate = document->sampleRate;
    metadata->emitterDependent = document->emitterDependent;
    return true;
}

const char *N60SOFADocumentGetAttribute(
    const N60SOFADocument *document,
    const char *name
) {
    if (document == NULL || document->hrtf == NULL
        || name == NULL) {
        return NULL;
    }
    return mysofa_getAttribute(
        document->hrtf->attributes,
        (char *)name
    );
}

bool N60SOFADocumentCopyListenerPosition(
    const N60SOFADocument *document,
    uint32_t measurement,
    double outXYZ[3]
) {
    static const double fallback[3] = {0.0, 0.0, 0.0};
    if (document == NULL || measurement >= document->hrtf->M) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->ListenerPosition,
        measurement,
        0u,
        0u,
        fallback,
        outXYZ
    );
}

bool N60SOFADocumentCopyListenerView(
    const N60SOFADocument *document,
    uint32_t measurement,
    double outXYZ[3]
) {
    static const double fallback[3] = {1.0, 0.0, 0.0};
    if (document == NULL || measurement >= document->hrtf->M) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->ListenerView,
        measurement,
        0u,
        0u,
        fallback,
        outXYZ
    );
}

bool N60SOFADocumentCopyListenerUp(
    const N60SOFADocument *document,
    uint32_t measurement,
    double outXYZ[3]
) {
    static const double fallback[3] = {0.0, 0.0, 1.0};
    if (document == NULL || measurement >= document->hrtf->M) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->ListenerUp,
        measurement,
        0u,
        0u,
        fallback,
        outXYZ
    );
}

bool N60SOFADocumentCopySourcePosition(
    const N60SOFADocument *document,
    uint32_t measurement,
    double outXYZ[3]
) {
    if (document == NULL || measurement >= document->hrtf->M) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->SourcePosition,
        measurement,
        0u,
        0u,
        NULL,
        outXYZ
    );
}

bool N60SOFADocumentCopyReceiverPosition(
    const N60SOFADocument *document,
    uint32_t measurement,
    uint32_t receiver,
    double outXYZ[3]
) {
    if (document == NULL || measurement >= document->hrtf->M
        || receiver >= document->hrtf->R) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->ReceiverPosition,
        measurement,
        receiver,
        0u,
        NULL,
        outXYZ
    );
}

bool N60SOFADocumentCopyEmitterPosition(
    const N60SOFADocument *document,
    uint32_t measurement,
    uint32_t emitter,
    double outXYZ[3]
) {
    static const double fallback[3] = {0.0, 0.0, 0.0};
    if (document == NULL || measurement >= document->hrtf->M
        || emitter >= document->hrtf->E) {
        return false;
    }
    return N60SOFACopyCoordinate(
        document->hrtf,
        &document->hrtf->EmitterPosition,
        measurement,
        0u,
        emitter,
        fallback,
        outXYZ
    );
}

bool N60SOFADocumentGetDelaySamples(
    const N60SOFADocument *document,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    double *delaySamples
) {
    if (document == NULL || delaySamples == NULL
        || measurement >= document->hrtf->M
        || receiver >= document->hrtf->R
        || emitter >= document->hrtf->E) {
        return false;
    }
    if (document->hrtf->DataDelay.values == NULL
        || document->hrtf->DataDelay.elements == 0u) {
        *delaySamples = 0.0;
        return true;
    }
    return N60SOFAReadScalar(
        document->hrtf,
        &document->hrtf->DataDelay,
        measurement,
        receiver,
        emitter,
        delaySamples
    );
}

bool N60SOFADocumentCopyImpulseResponse(
    const N60SOFADocument *document,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    float *destination,
    uint32_t capacity
) {
    if (document == NULL || destination == NULL
        || measurement >= document->hrtf->M
        || receiver >= document->hrtf->R
        || emitter >= document->hrtf->E
        || capacity < document->hrtf->N) {
        return false;
    }
    if (!document->emitterDependent && emitter != 0u) {
        return false;
    }

    for (uint32_t sample = 0u;
         sample < document->hrtf->N;
         ++sample) {
        uint64_t index = 0u;
        if (!N60SOFAArrayIndex(
                document->hrtf,
                &document->hrtf->DataIR,
                measurement,
                receiver,
                emitter,
                sample,
                0u,
                &index)) {
            return false;
        }
        const float value = document->hrtf->DataIR.values[index];
        if (!isfinite(value)) return false;
        destination[sample] = value;
    }
    return true;
}

const char *N60SOFAStatusDescription(
    N60SOFAStatus status
) {
    switch (status) {
    case N60SOFAStatusOK:
        return "SOFA file loaded successfully.";
    case N60SOFAStatusInvalidArgument:
        return "SOFA importer received an invalid argument.";
    case N60SOFAStatusFileTooLarge:
        return "SOFA file exceeds the importer file-size limit.";
    case N60SOFAStatusParseFailed:
        return "SOFA/HDF file could not be decoded.";
    case N60SOFAStatusUnsupportedDataType:
        return "SOFA data type is not a supported FIR representation.";
    case N60SOFAStatusInvalidDimensions:
        return "SOFA dimensions are missing or invalid.";
    case N60SOFAStatusResourceLimit:
        return "SOFA dimensions exceed importer resource limits.";
    case N60SOFAStatusInvalidSamplingRate:
        return "SOFA sampling rate is invalid.";
    case N60SOFAStatusInconsistentSamplingRate:
        return "SOFA measurements do not use one consistent sampling rate.";
    case N60SOFAStatusInvalidArrayShape:
        return "SOFA array dimensions do not match the declared FIR dimensions.";
    case N60SOFAStatusNonFiniteData:
        return "SOFA file contains non-finite FIR or delay data.";
    default:
        return "SOFA import failed.";
    }
}
