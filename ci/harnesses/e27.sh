# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E27.

# E27 S2c: the analyser taps (ABI v21): placement, demand switch, +12 dB EQ visible at both taps and the gain after them not, no allocation.
if selected e27_analyser_tap; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_analyser_tap.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e27_core_analyser_tap" && run_timed "$OUT/e27_core_analyser_tap"; then
            passed+=(e27_core_analyser_tap)
        else
            failed+=(e27_core_analyser_tap)
        fi
    else
        failed+=(e27_analyser_tap)
    fi
fi
