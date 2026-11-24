/*
 * libn60core umbrella header (E21 S1). Includes every domain header of the portable core and declares the one
 * call that reports their versions. Each domain keeps its own version (an analysis change never bumps the realtime
 * graph ABI); n60_core_abi lets a host check all of them, and the struct sizes, once at launch.
 * Pure C: no platform header, no Apple framework.
 */
#ifndef N60_N60_H
#define N60_N60_H

#include <stddef.h>
#include <stdint.h>

#include "n60/anc.h"
#include "n60/anc_design.h"
#include "n60/vd_ring.h"
#include "n60/correct.h"
#include "n60/eqfit.h"
#include "n60/fold.h"
#include "n60/graph.h"
#include "n60/headroom.h"
#include "n60/hrtf.h"
#include "n60/measure.h"
#include "n60/mimo.h"
#include "n60/resample.h"
#include "n60/speaker.h"
#include "n60/xover.h"

#ifdef __cplusplus
extern "C" {
#endif

#define N60_CORE_ABI_INFO_VERSION 1u

/* What the loaded library reports. Fill structSize with sizeof(n60_core_abi_info) before the call; the library
 * writes at most that many bytes and sets structSize to the size it wrote (a smaller, older struct is fine).
 * Each *_version is the library's macro value; each *_struct is sizeof of that domain's principal struct as the
 * library was compiled, so a host compares both against its own headers. A domain without a version macro
 * reports 0. */
typedef struct n60_core_abi_info {
    uint32_t structSize;
    uint32_t infoVersion; /* N60_CORE_ABI_INFO_VERSION */
    uint32_t graphVersion;
    uint32_t measureVersion;
    uint32_t correctVersion;
    uint32_t xoverVersion;
    uint32_t headroomVersion;
    uint32_t mimoVersion;
    uint32_t foldVersion;
    uint32_t graphDescSize;     /* sizeof(n60_graph_desc) */
    uint32_t stageDescSize;     /* sizeof(n60_stage_desc) */
    uint32_t measureEssSize;    /* sizeof(n60_measure_ess_params) */
    uint32_t correctProblemSize;/* sizeof(n60_correct_problem) */
    uint32_t xoverSpecSize;     /* sizeof(n60_xover_spec) */
    uint32_t headroomPathSize;  /* sizeof(n60_headroom_path) */
    uint32_t mimoProblemSize;   /* sizeof(n60_mimo_problem) */
    uint32_t foldMatrixSize;    /* sizeof(n60_fold_matrix) */
    uint32_t eqfitVersion;      /* E33 S21, appended so earlier offsets keep their place */
    uint32_t eqfitProblemSize;  /* sizeof(n60_eqfit_problem) */
    uint32_t speakerVersion;    /* E21 S9a, appended */
    uint32_t speakerProblemSize;/* sizeof(n60_speaker_candidate_problem) */
    uint32_t ancVersion;        /* E21 S4, appended */
    uint32_t ancLaneFeedConfigSize; /* sizeof(N60AncLaneFeedConfig) */
    uint32_t ancDesignVersion;      /* E21 S10a, appended */
    uint32_t ancDesignOptionsSize;  /* sizeof(n60_anc_seat_options) */
    uint32_t vdRingVersion;         /* E36 S3, appended */
    uint32_t vdRingHeaderSize;      /* sizeof(n60_vd_ring_header) */
    uint32_t hrtfVersion;           /* E13 S11, appended */
    uint32_t hrtfModelSize;         /* sizeof(n60_hrtf_generic_model) */
} n60_core_abi_info;

/* Returns 1 and fills info, or 0 for a null pointer or a structSize smaller than the first two fields. */
int n60_core_abi(n60_core_abi_info *info, size_t info_size);

#ifdef __cplusplus
}
#endif

#endif
