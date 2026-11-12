#!/usr/bin/env bash
# Build libn60core with clang (-Werror) and run its unit tests. Portable: runs on Linux (pr.yml and
# macos-full.yml core-linux jobs) and on macOS. E1 S7; moved out of macos-full.yml so both share it.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
clang++ --version
# Keep this list in step with build_core_objs in ci/run_harnesses.sh.
source ci/core_sources.sh
LIB=()
for f in "${CORE_SOURCES[@]}"; do
  obj="$TMP/n60core_${f//\//_}.o"
  clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unknown-warning-option -Werror=function-effects \
    -fno-exceptions -fno-rtti -Icore/include -Icore/src -c core/src/$f.cpp -o "$obj"
  LIB+=("$obj")
done
for t in test_graph test_stages test_dsp test_system test_rebuild test_denoiser_carry test_layout test_multisub test_readbacks; do
  clang -std=c11 -O2 -Wall -Wextra -Werror -Icore/include -c core/tests/$t.c -o "$TMP/$t.o"
  clang++ "$TMP/$t.o" "${LIB[@]}" -lm -pthread -o "$TMP/$t"
  "$TMP/$t"
done
clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_alloc.cpp \
  "${LIB[@]}" -o "$TMP/test_alloc"
"$TMP/test_alloc"
clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_fpenv.cpp \
  "${LIB[@]}" -o "$TMP/test_fpenv"
"$TMP/test_fpenv"
clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_parallel.cpp \
  "${LIB[@]}" -pthread -o "$TMP/test_parallel"
"$TMP/test_parallel"
# E20 S6b (G26): the same test pinned to two cores, three workers plus the render thread contending for them.
N60_PARALLEL_TEST_CPUS=2 N60_PARALLEL_TEST_LITE=1 "$TMP/test_parallel"
clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_conv.cpp \
  "${LIB[@]}" -o "$TMP/test_conv"
"$TMP/test_conv"
"$TMP/test_graph"
