#include "N60AudioUnitRackExchange.h"

#include <stdio.h>

int main(void) {
    N60AudioUnitStageFaultGate *gate =
        N60AudioUnitStageFaultGateCreate();
    if (gate == NULL) {
        fprintf(stderr, "stage fault gate is not lock-free or allocation failed\n");
        return 1;
    }

    if (N60AudioUnitStageFaultGateIsTripped(gate)) {
        fprintf(stderr, "new stage fault gate started tripped\n");
        N60AudioUnitStageFaultGateDestroy(gate);
        return 2;
    }

    N60AudioUnitStageFaultGateTrip(gate);
    if (!N60AudioUnitStageFaultGateIsTripped(gate)) {
        fprintf(stderr, "stage fault gate did not publish trip\n");
        N60AudioUnitStageFaultGateDestroy(gate);
        return 3;
    }

    // Idempotence matters because render and control-plane failure detection
    // may race to trip the same stage.
    N60AudioUnitStageFaultGateTrip(gate);
    if (!N60AudioUnitStageFaultGateIsTripped(gate)) {
        fprintf(stderr, "stage fault gate lost a repeated trip\n");
        N60AudioUnitStageFaultGateDestroy(gate);
        return 4;
    }

    N60AudioUnitStageFaultGateDestroy(gate);
    puts("PR84A lock-free stage fault gate validation passed");
    return 0;
}
