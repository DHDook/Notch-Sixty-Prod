#ifndef N60SOFABridge_h
#define N60SOFABridge_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    N60SOFAStatusOK = 0,
    N60SOFAStatusInvalidArgument = 1,
    N60SOFAStatusFileTooLarge = 2,
    N60SOFAStatusParseFailed = 3,
    N60SOFAStatusUnsupportedDataType = 4,
    N60SOFAStatusInvalidDimensions = 5,
    N60SOFAStatusResourceLimit = 6,
    N60SOFAStatusInvalidSamplingRate = 7,
    N60SOFAStatusInconsistentSamplingRate = 8,
    N60SOFAStatusInvalidArrayShape = 9,
    N60SOFAStatusNonFiniteData = 10,
} N60SOFAStatus;

typedef struct N60SOFADocument N60SOFADocument;

typedef struct {
    uint32_t measurementCount;
    uint32_t receiverCount;
    uint32_t emitterCount;
    uint32_t tapCount;
    double sampleRate;
    bool emitterDependent;
} N60SOFAMetadata;

N60SOFADocument * _Nullable N60SOFADocumentOpen(
    const char * _Nonnull path,
    N60SOFAStatus * _Nullable status
);

void N60SOFADocumentDestroy(
    N60SOFADocument * _Nullable document
);

bool N60SOFADocumentGetMetadata(
    const N60SOFADocument * _Nonnull document,
    N60SOFAMetadata * _Nonnull metadata
);

const char * _Nullable N60SOFADocumentGetAttribute(
    const N60SOFADocument * _Nonnull document,
    const char * _Nonnull name
);

bool N60SOFADocumentCopyListenerPosition(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentCopyListenerView(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentCopyListenerUp(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentCopySourcePosition(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentCopyReceiverPosition(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    uint32_t receiver,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentCopyEmitterPosition(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    uint32_t emitter,
    double * _Nonnull outXYZ
);

bool N60SOFADocumentGetDelaySamples(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    double * _Nonnull delaySamples
);

bool N60SOFADocumentCopyImpulseResponse(
    const N60SOFADocument * _Nonnull document,
    uint32_t measurement,
    uint32_t receiver,
    uint32_t emitter,
    float * _Nonnull destination,
    uint32_t capacity
);

const char * _Nonnull N60SOFAStatusDescription(
    N60SOFAStatus status
);

#ifdef __cplusplus
}
#endif

#endif
