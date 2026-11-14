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
