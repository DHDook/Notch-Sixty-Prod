#!/usr/bin/env bash
# Compile and link every render/bridge benchmark into $1 (default: $RUNNER_TEMP/benchmarks). Link only:
# nothing is run. Used by pr.yml (so a link failure shows on the PR) and by macos-full.yml (which then
# runs the binaries). Needs macOS (Accelerate, CoreAudio). E1 S7.
set -euo pipefail
cd "$(dirname "$0")/.."
RT=NotchSixty/Audio/Realtime
OUT="${1:-${RUNNER_TEMP:-/tmp}/benchmarks}"
mkdir -p "$OUT"
# E4 S15: the render kernel links the C++20 howl guard.
clang++ -std=c++20 -O3 -Wall -Wextra -I"$RT" -c "$RT/n60_anc_guard.cpp" -o "$OUT/n60_anc_guard.o"
# E4 S25b: and the live feed-forward filter.
clang++ -std=c++20 -O3 -Wall -Wextra -I"$RT" -c "$RT/n60_ff_live.cpp" -o "$OUT/n60_ff_live.o"
clang++ -std=c++20 -O3 -Wall -Wextra -I"$RT" -c "$RT/n60_ff_echo.cpp" -o "$OUT/n60_ff_echo.o"
clang++ -std=c++20 -O3 -Wall -Wextra -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms.o"
# E26: the bridge feeds the ANC lane (N60AncLaneFeed).
clang++ -std=c++20 -O3 -Wall -Wextra -I"$RT" -c "$RT/n60_anc_lane_feed.cpp" -o "$OUT/n60_anc_lane_feed.o"
NO_BRIDGE="$(find "$RT" -name '*.c' ! -name 'N60RealtimeAudioBridge.c' ! -name 'N60MeasurementMonitorProc.c' -print) $OUT/n60_anc_guard.o $OUT/n60_ff_live.o $OUT/n60_ff_echo.o $OUT/n60_fxlms.o $OUT/n60_anc_lane_feed.o"
ALL="$(find "$RT" -name '*.c' -print) $OUT/n60_anc_guard.o $OUT/n60_ff_live.o $OUT/n60_ff_echo.o $OUT/n60_fxlms.o $OUT/n60_anc_lane_feed.o"
# libn60core objects, from the shared list (ci/core_sources.sh). The render kernel and
# the realtime bridge both link them (N60LevelSessionProc, n60_graph_*).
source ci/core_sources.sh
CORE_OBJS=()
for f in "${CORE_SOURCES[@]}"; do
  obj="$OUT/n60core_${f//\//_}.o"
  clang++ -std=c++20 -O3 -Wall -Wextra -Wno-unknown-warning-option -Werror=function-effects -fno-exceptions -fno-rtti -Icore/include -Icore/src -c "core/src/$f.cpp" -o "$obj"
  CORE_OBJS+=("$obj")
done
# shellcheck disable=SC2086
for opt in O0 O3; do
  clang -std=c11 -"$opt" -Wall -Wextra -include stddef.h -I"$RT" -Icore/include \
    ci/benchmark_pr35_render_kernel.c $NO_BRIDGE "${CORE_OBJS[@]}" -lc++ -framework Accelerate -o "$OUT/render-$opt"
done
clang -std=c11 -O3 -Wall -Wextra -include stddef.h -I"$RT" -Icore/include \
  ci/benchmark_pr35_realtime_bridge.c $ALL "${CORE_OBJS[@]}" -lc++ \
  -framework Accelerate -framework CoreAudio -o "$OUT/bridge-O3"
# E8 A6a: design time of the multi-sub search (8 subs x 8 seats x 128 bins, Release build of the core unit).
clang++ -std=c++20 -O3 -Wall -Wextra -fno-exceptions -fno-rtti -Icore/include -c core/src/correct/multisub_search.cpp \
  -o "$OUT/multisub_search.o"
clang -std=c11 -O3 -Wall -Wextra -I"$RT" -Icore/include -Ici ci/validate_e8_multi_sub_tools.c "$OUT/multisub_search.o" \
  -lc++ -lm -o "$OUT/multisub"
clang -std=c11 -O2 -Wall -Wextra -I"$RT" "$RT/N60Convolution.c" ci/benchmark_nonuniform_convolution.c \
  -framework Accelerate -o "$OUT/convolution"
# E20 S1: graph render benchmark (core/bench/n60_bench.cpp). The timing binary links product objects (no profile
# hooks) and the ANC lane feed (R7); a second binary links a -DN60_GRAPH_PROFILE snapshot object for the
# per-stage ns/sample rows.
clang -std=c11 -O3 -Wall -Wextra -include stddef.h -I"$RT" -c "$RT/N60ActiveQuietZone.c" -o "$OUT/n60_aqz.o"
clang++ -std=c++20 -O3 -Wall -Wextra -fno-exceptions -fno-rtti -DN60_GRAPH_PROFILE -Icore/include -Icore/src \
  -c core/src/snapshot.cpp -o "$OUT/n60core_snapshot_profile.o"
PROFILE_OBJS=()
for obj in "${CORE_OBJS[@]}"; do
  if [ "$obj" = "$OUT/n60core_snapshot.o" ]; then PROFILE_OBJS+=("$OUT/n60core_snapshot_profile.o"); else PROFILE_OBJS+=("$obj"); fi
done
ANC_OBJS="$OUT/n60_aqz.o $OUT/n60_anc_lane_feed.o $OUT/n60_ff_live.o $OUT/n60_ff_echo.o $OUT/n60_fxlms.o"
# shellcheck disable=SC2086
clang++ -std=c++20 -O3 -Wall -Wextra -DN60_BENCH_ANC -I"$RT" -Icore/include -Icore/src core/bench/n60_bench.cpp \
  "${CORE_OBJS[@]}" $ANC_OBJS -framework Accelerate -o "$OUT/n60_bench"
clang++ -std=c++20 -O3 -Wall -Wextra -DN60_BENCH_PROFILE -Icore/include -Icore/src core/bench/n60_bench.cpp \
  "${PROFILE_OBJS[@]}" -framework Accelerate -o "$OUT/n60_bench_profile"
echo "benchmarks linked in $OUT"
