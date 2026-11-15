#!/usr/bin/env bash
# Build libn60core and every portable core test from core/CMakeLists.txt with clang (-Werror) and run them with
# ctest. CMake is the one source list (core/sources.cmake). Portable: Linux (pr.yml and macos-full.yml core-linux
# jobs) and macOS. E1 S7; E21 S1 moved it from a hand-kept compile list to CMake, so every registered test runs.
# Debug is built -O1 -g (no NDEBUG): unoptimised, the heaviest design tests run for more than ten minutes each.
# Usage: ci/run_core_linux.sh [Release] [Debug] (default: both).
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
clang++ --version
cmake --version | head -1
CONFIGS=("$@")
[ ${#CONFIGS[@]} -gt 0 ] || CONFIGS=(Release Debug)
JOBS="$( (nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null) || echo 4)"
for cfg in "${CONFIGS[@]}"; do
  dir="$TMP/n60core_build_$cfg"
  cmake -S core -B "$dir" -DCMAKE_BUILD_TYPE="$cfg" -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DCMAKE_C_FLAGS_DEBUG="-O1 -g" -DCMAKE_CXX_FLAGS_DEBUG="-O1 -g"
  cmake --build "$dir" --parallel "$JOBS"
  ctest --test-dir "$dir" --output-on-failure --parallel "$JOBS" --timeout 1200
done
