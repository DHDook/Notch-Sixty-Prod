/* E21 S1: n60/n60.h compiles as C and n60_core_abi reports every domain version and struct size from the same
 * header macros (never literals). */
#include <stdio.h>
#include <string.h>

#include "n60/n60.h"

static int fails = 0;
#define CHECK(c, m) do { if (!(c)) { printf("FAIL: %s\n", m); ++fails; } } while (0)

int main(void) {
    n60_core_abi_info info;
    memset(&info, 0xAB, sizeof info);
    CHECK(n60_core_abi(&info, sizeof info) == 1, "call");
    CHECK(info.structSize == sizeof info, "structSize");
    CHECK(info.infoVersion == N60_CORE_ABI_INFO_VERSION, "info version");
    CHECK(info.graphVersion == N60_GRAPH_ABI_VERSION, "graph");
    CHECK(info.measureVersion == N60_MEASURE_ABI_VERSION, "measure");
    CHECK(info.correctVersion == N60_CORRECT_ABI_VERSION, "correct");
    CHECK(info.xoverVersion == N60_XOVER_ABI_VERSION, "xover");
    CHECK(info.headroomVersion == N60_HEADROOM_ABI_VERSION, "headroom");
    CHECK(info.mimoVersion == N60_MIMO_ABI_VERSION, "mimo");
    CHECK(info.foldVersion == N60_FOLD_ABI_VERSION, "fold");
    CHECK(info.graphDescSize == sizeof(n60_graph_desc), "graph desc size");
    CHECK(info.stageDescSize == sizeof(n60_stage_desc), "stage desc size");
    CHECK(info.measureEssSize == sizeof(n60_measure_ess_params), "ess size");
    CHECK(info.correctProblemSize == sizeof(n60_correct_problem), "correct size");
    CHECK(info.xoverSpecSize == sizeof(n60_xover_spec), "xover size");
    CHECK(info.headroomPathSize == sizeof(n60_headroom_path), "headroom size");
    CHECK(info.mimoProblemSize == sizeof(n60_mimo_problem), "mimo size");
    CHECK(info.foldMatrixSize == sizeof(n60_fold_matrix), "fold size");
    CHECK(info.eqfitVersion == N60_EQFIT_ABI_VERSION, "eqfit");
    CHECK(info.eqfitProblemSize == sizeof(n60_eqfit_problem), "eqfit size");
    CHECK(n60_core_abi(NULL, sizeof info) == 0, "null");
    CHECK(n60_core_abi(&info, 4) == 0, "truncated");
    memset(&info, 0xAB, sizeof info);
    CHECK(n60_core_abi(&info, 12) == 1 && info.structSize == 12 && info.graphVersion == N60_GRAPH_ABI_VERSION, "short struct");
    CHECK(info.measureVersion == 0xABABABABu, "short struct leaves the tail alone");
    CHECK(N60_MIMO_MAX_SOURCES == 32, "one MIMO source limit");
    if (fails == 0) printf("core abi ok\n");
    return fails ? 1 : 0;
}
