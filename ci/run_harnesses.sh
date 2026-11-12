#!/usr/bin/env bash
# Builds and runs every behavioural C harness against the realtime sources.
# Each harness exercises engine code directly (no source-text matching); a
# non-zero exit from any harness fails the run. Used by .github/workflows/pr.yml.
#
#   ci/run_harnesses.sh            run all harnesses
#   ci/run_harnesses.sh pr69 pr70  run only harnesses whose name contains a filter
set -uo pipefail

cd "$(dirname "$0")/.."
OUT="${RUNNER_TEMP:-$(mktemp -d)}/harnesses"
mkdir -p "$OUT"

RT=NotchSixty/Audio/Realtime
# E4 S15: the render kernel links the C++20 howl guard, so every harness that links the kernel
# gets its object (and libc++, added in harness()).
mkdir -p "$OUT"
GUARD_OBJ="$OUT/n60_anc_guard_rt.o"
if ! clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"NotchSixty/Audio/Realtime" -c "NotchSixty/Audio/Realtime/n60_anc_guard.cpp" -o "$GUARD_OBJ"; then
    echo "failed to compile the howl guard" >&2
    exit 1
fi
# E6 S12h part 2b: the bridge binds the AU rack to the ANC lane feed, so every bridge harness links the feed object.
# E4 S25b: the render kernel also links the live feed-forward filter (and the FxLMS primitives it uses).
for src in n60_ff_live n60_ff_echo n60_fxlms n60_anc_lane_feed; do
    if ! clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"NotchSixty/Audio/Realtime" -c "NotchSixty/Audio/Realtime/$src.cpp" -o "$OUT/${src}_rt.o"; then
        echo "failed to compile $src" >&2
        exit 1
    fi
    GUARD_OBJ="$GUARD_OBJ
$OUT/${src}_rt.o"
done
ALL_RT=$(find "$RT" -name '*.c' -print | sort; echo "$GUARD_OBJ")
ALL_RT_NO_BRIDGE=$(find "$RT" -name '*.c' ! -name 'N60RealtimeAudioBridge.c' ! -name 'N60MeasurementMonitorProc.c' ! -name 'N60LevelSessionProc.c' -print | sort; echo "$GUARD_OBJ")
STRICT=(-std=c11 -Wall -Wextra -Werror)
FILTERS=("$@")

passed=()
failed=()

# run_timed <cmd...>: runs one harness binary, names it in the log, and kills it after HARNESS_TIMEOUT seconds
# (default 900) so a hang fails that harness and names itself instead of stalling the whole job.
HARNESS_TIMEOUT=${HARNESS_TIMEOUT:-900}
run_timed() {
    echo "[harness] running: $* (timeout ${HARNESS_TIMEOUT}s)" >&2  # stderr: some callers redirect stdout to a file they compare
    "$@" &
    local pid=$! watchdog rc
    # The watchdog reports and kills only if its sleep ran to the end (exit 0); a sleep killed by us does nothing.
    ( sleep "$HARNESS_TIMEOUT" && { echo "[harness] TIMEOUT after ${HARNESS_TIMEOUT}s, killing: $*" >&2; kill -9 "$pid" 2>/dev/null; } ) &
    watchdog=$!
    wait "$pid"
    rc=$?
    # Stop the watchdog subshell first, then its sleep, so the subshell cannot go on to the timeout branch.
    { kill "$watchdog"; pkill -P "$watchdog"; wait "$watchdog"; } 2>/dev/null  # the shell reports the killed job on stderr; hide that
    return $rc
}

selected() {
    [ ${#FILTERS[@]} -eq 0 ] && return 0
    local filter
    for filter in "${FILTERS[@]}"; do
        [[ "$1" == *"$filter"* ]] && return 0
    done
    return 1
}

# harness <name> <compile args...>: compiles to $OUT/<name> and runs it.
harness() {
    local name=$1
    shift
    selected "$name" || return 0
    echo "::group::$name"
    if clang "$@" -lc++ -o "$OUT/$name" && run_timed "$OUT/$name"; then
        passed+=("$name")
    else
        failed+=("$name")
    fi
    echo "::endgroup::"
}

# build_core_objs: compiles libn60core once into CORE_OBJS (CORE_OK=0 on failure).
# The realtime bridge calls n60_graph_*, so bridge harnesses link these objects too.
# shellcheck source=ci/core_sources.sh
source "$(dirname "${BASH_SOURCE[0]}")/core_sources.sh"
CORE_BUILT=0
CORE_OK=0
CORE_OBJS=()
build_core_objs() {
    [ "$CORE_BUILT" = 1 ] && return 0
    CORE_BUILT=1
    CORE_OK=1
    local src
    for src in "${CORE_SOURCES[@]}"; do
        local obj="$OUT/n60core_${src//\//_}.o"
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Wno-unknown-warning-option -Werror=function-effects -fno-exceptions -fno-rtti -Icore/include -Icore/src \
            -c "core/src/$src.cpp" -o "$obj"; then
            CORE_OBJS+=("$obj")
        else
            CORE_OK=0
        fi
    done
}
# Bridge harnesses: build the core only when one of them is selected.
if selected pr35_transition_ack || selected pr41_same_device_output_map || selected pr101_realtime_resource_soak || selected e6_graph_takeover || selected e6_fade_alignment || selected e6_nchannel_graph || selected e6_shutdown_fade || selected e8_routed_output || selected e4_speaker_drive || selected e25_fold || selected e20_bridge_fastpath || selected e28_route_meter || selected e28_loudness_capture; then
    build_core_objs
fi

# Per-epic harness lists live in ci/harnesses/<epic>.sh and are sourced in name order.
for harness_file in ci/harnesses/*.sh; do
    # shellcheck source=/dev/null
    source "$harness_file"
done

echo
echo "Harnesses passed: ${#passed[@]}"
if [ ${#failed[@]} -gt 0 ]; then
    echo "Harnesses FAILED (${#failed[@]}): ${failed[*]}"
    exit 1
fi
if [ ${#passed[@]} -eq 0 ]; then
    echo "No harness matched the filters."
    exit 1
fi
