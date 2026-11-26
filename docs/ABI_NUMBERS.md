# ABI number reservation

A slice that bumps `N60_GRAPH_ABI_VERSION` (or `N60_HEADROOM_ABI_VERSION`) claims the next number
here in its first commit. Tests never pin literals; they compare against the header macros.
If two claims collide, the one that merges second renumbers its own claim only.

| Number | Owner | State |
|---|---|---|
| graph v37 | #470 E28 S7c | on main, merged (v36 was never merged and is skipped) |
| graph v38 | #465 E13 S4 | on main, merged |
| graph v39 | E13 S5 `e13/hrtf-interpolation` | open; adds the binaural stage extension (elevation sets, per-set per-ear delays) and `n60_binaural_delay_separate` |
| none (no bump) | #469 E20 S5 | open; claims no number (G24). Adds four functions (`n60_graph_set_workers`, `set_wake`, `worker_run`, `read_parallel`) and no layout change, so it rides whichever version is on main when it merges (v37 now, v38 if #465 lands first). Its test builds with `N60_GRAPH_ABI_VERSION`, never a literal, and it does not touch the version macro, so it cannot conflict with #465 |
| none (no bump) | E4 S30d | claims no number. Changes only AMBIENT state carry in `systemRiderCarry`; no layout or version change |
| none (no bump) | E28 G42 | claims no number. Adds multiband paramCount 44 (parameter 43 band split) inside the existing v37 layout; extras-off blocks (29 or 43 values) are unchanged |
| graph v40 | E19 S10 `e19/routed-stage-and-wiring` | open; adds `N60_STAGE_MIMO_ROUTED` (53) at position 23.55 and renumbers the internal ranks of XOVER and DRIVER_FIR (no layout change) |
| graph v41 | E33 S5a `e33/expander-lookahead` | open; expander paramCount 14 adds [13] lookahead frames (ring in lane state, latency reported); no layout change to other structs |
| graph v42 | E33 S5b `e33/multiband-bands` | open; multiband paramCount 73 (2 to 5 bands) and `n60_multiband_readback` grMaxDb[5], grNowDb[5], bandCount (struct size changes); extras blocks of 29, 43 and 44 values stay bit-identical |
| graph v43 | E32 S5 `e32/dynamics-sound-fixes` | open; expander paramCount 15 adds [14] timing swap; protection paramCount 8 and 19 add a sound-fixes word (attack cap, rate-based true-peak factor); `n60_dynamics_readback.reserved` carries the safety-clamp count (no struct size change) |
| graph v44 | E33 S10 `e33/input-overs` | open; METER_IN paramCount 2 (detect, generation) and `n60_graph_read_input_overs`; no struct layout change |
| graph v45 | E33 S13 `e33/surround-detector-and-dialogue` | open; compressor paramCount 17 ([16]) and expander paramCount 16 ([15]) detector-excluded lane; LOUDNESS paramCount 33 ([32]) centre lane; `n60_loudness_readback.reserved` carries the centre-active flag; no struct size change |
| graph v46 | E33 S14 `e33/limiter-auto-release` | open; PROTECTION sound-fixes word bit 2 (value 4) is auto release (word range 0..7); `n60_dynamics_readback.effectiveReleaseMs` (struct size grows by 4 bytes); sustain state is not carried across a rebuild |
| graph v47 | E33 S26 `e33/eq-matched-filters` | open; PEQ section types 16..20, 23, 24 are matched designs (live-settable too, plus type 8); C functions `n60_eq_design_section` and `n60_eq_section_magnitude`; no struct layout change |
| graph v48 | E19 S12c-engine `e19/probe-stimulus-feed` | open; generator (sweep type only) paramCount 13 adds live [11] solo and [12] cue; 11-value block bit-identical to v47; no struct layout change |
| graph v49 | E8 S13 `e8/per-driver-protection` | open; adds N60_STAGE_THERMAL_LIMIT (54, rank 265, paramCount 2: level dBFS, time constant ms); no existing stage or struct layout change |
| none (no bump) | E33 S20 `e33/eq-channel-groups` | claims no number; group EQ rides existing per-lane PEQ stages |
| eqfit v1 (domain, no graph bump) | E33 S21 `e33/eq-fit-to-curve` #618 | open; new `n60/eqfit.h`; `n60_core_abi_info` gains `eqfitVersion` and `eqfitProblemSize` appended after `foldMatrixSize` (append-only; earlier offsets unchanged) |
| none (no bump) | E33 S27 `e33/eq-linear-phase-resolution` | claims no number; new C function `n60_eq_linear_phase_design` and `n60_eq_linear_phase_report` in `n60/graph.h`, append-only, no struct layout change |
| correct v6 (domain, no graph bump) | E21 S7a `e21/multisub-goldens` | open; `n60/correct.h` section 8 (calibration alignment, timing, sub EQ fit); append-only functions |
| correct v7 (domain, no graph bump) | E21 S7b `e21/multisub-designer` | open; `n60/correct.h` section 9 (`n60_correct_multisub_optimise`, defaults, settings check); append-only functions |
| speaker v1 (domain, no graph bump) | E21 S9a `e21/speaker-maths` | open; new `n60/speaker.h`; `n60_core_abi_info` gains `speakerVersion` and `speakerProblemSize` appended after `eqfitProblemSize` (append-only) |
| hrtf v1 (domain, no graph bump) | E13 S11 `e13/generic-hrtf` | open; new `n60/hrtf.h`; `n60_core_abi_info` gains `hrtfVersion` and `hrtfModelSize` appended after `vdRingHeaderSize` (append-only) |
| roommodel v3 (domain, no graph bump) | E29 S5 `e29/acoustic-locate` | open; append-only: `n60_roommodel_locate` and its structs (acoustic locate). No existing struct changes |
| roommodel v2 (domain, no graph bump) | E29 S3 follow-up `e29/blend-fix` | merged; v2 changes the behaviour contract only (barycentric weights, spacing-aware default trust radius, zero-weight nodes dropped), no struct change. v1 (S3 `e29/interpolation-core`, #702): new `n60/roommodel.h`; `n60_core_abi_info` gains `roomModelVersion` and `roomModelQuerySize` appended after `hrtfModelSize` (append-only) |
| upmix v1 (domain, no graph bump) | E14 S1 `e14/upmix-core` | open; new `n60/upmix.h`; `n60_core_abi_info` gains `upmixVersion` and `upmixConfigSize` appended after `roomModelQuerySize` (append-only). The graph bump (`N60_STAGE_UPMIX`) is claimed by E14 S2 |
| headroom v4 (domain, no graph bump) | E12 S28b1 `e12/blind-system-sides-engine` | open; append-only: `n60_headroom_weighted_level` and `n60_headroom_level_result` (K-weighted pink-noise level of one output). No existing struct changes |
