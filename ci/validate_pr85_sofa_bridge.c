#include "N60SOFABridge.h"

#include <stdio.h>
#include <string.h>

int main(void) {
    N60SOFAMetadata metadata = {0};
    if (metadata.measurementCount != 0u) {
        return 1;
    }

    const char *description =
        N60SOFAStatusDescription(N60SOFAStatusUnsupportedDataType);
    if (description == NULL
        || strstr(description, "FIR") == NULL) {
        fprintf(stderr, "unexpected SOFA status description\n");
        return 2;
    }

    puts("PR85 native SOFA bridge linkage passed");
    return 0;
}
