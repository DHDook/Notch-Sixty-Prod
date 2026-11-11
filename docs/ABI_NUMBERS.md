# ABI number reservation

A slice that bumps `N60_GRAPH_ABI_VERSION` (or `N60_HEADROOM_ABI_VERSION`) claims the next number
here in its first commit. Tests never pin literals; they compare against the header macros.
If two claims collide, the one that merges second renumbers its own claim only.

| Number | Owner | State |
|---|---|---|
| graph v35 | on main | merged |
| graph v36 | #465 E13 S4 | open |
| graph v36 | #470 E28 S7c | open; collides with #465, whichever merges second takes v37 |
| none (no bump) | #469 E20 S5 | open; claims no number (G24). Adds four functions (`n60_graph_set_workers`, `set_wake`, `worker_run`, `read_parallel`) and no layout change, so it rides whichever version is on main when it merges (v35, v36 or v37). Its test builds with `N60_GRAPH_ABI_VERSION`, never a literal, and the version macro is not touched, so it never conflicts with #465 or #470 |
