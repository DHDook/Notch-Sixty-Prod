// E21 S1: n60_core_abi (n60/n60.h). Reports each domain header's version and principal struct sizes.
#include "n60/n60.h"

#include <string.h>

extern "C" int n60_core_abi(n60_core_abi_info *info, size_t info_size) {
    if (info == nullptr || info_size < 2 * sizeof(uint32_t)) return 0;
    n60_core_abi_info out;
    memset(&out, 0, sizeof out);
    out.infoVersion = N60_CORE_ABI_INFO_VERSION;
    out.graphVersion = n60_graph_abi_version();
    out.measureVersion = n60_measure_abi_version();
    out.correctVersion = n60_correct_abi_version();
    out.xoverVersion = n60_xover_abi_version();
    out.headroomVersion = n60_headroom_abi_version();
    out.mimoVersion = n60_mimo_abi_version();
    out.foldVersion = N60_FOLD_ABI_VERSION;
    out.graphDescSize = static_cast<uint32_t>(sizeof(n60_graph_desc));
    out.stageDescSize = static_cast<uint32_t>(sizeof(n60_stage_desc));
    out.measureEssSize = static_cast<uint32_t>(sizeof(n60_measure_ess_params));
    out.correctProblemSize = static_cast<uint32_t>(sizeof(n60_correct_problem));
    out.xoverSpecSize = static_cast<uint32_t>(sizeof(n60_xover_spec));
    out.headroomPathSize = static_cast<uint32_t>(sizeof(n60_headroom_path));
    out.mimoProblemSize = static_cast<uint32_t>(sizeof(n60_mimo_problem));
    out.foldMatrixSize = static_cast<uint32_t>(sizeof(n60_fold_matrix));
    const size_t n = info_size < sizeof out ? info_size : sizeof out;
    out.structSize = static_cast<uint32_t>(n);
    memcpy(info, &out, n);
    return 1;
}
