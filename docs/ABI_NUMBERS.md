# ABI number reservation

A slice that bumps `N60_GRAPH_ABI_VERSION` (or `N60_HEADROOM_ABI_VERSION`) claims the next number
here in its first commit. Tests never pin literals; they compare against the header macros.
If two claims collide, the one that merges second renumbers its own claim only.

| Number | Owner | State |
|---|---|---|
| graph v35 | on main | merged |
| graph v36 | #465 E13 S4 | open |
| graph v36 | #470 E28 S7c | open; collides with #465, whichever merges second takes v37 |
| graph v35 (no bump) | #469 E20 S5 | open; adds to v35 without a bump (G24) |
