# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E19.

# E19 S4: MIMO treatment graph stage (ABI v33): delay, arm ramp, trip, monitor, rebuild mute at the standard rates.
if selected e19_mimo_stage; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_mimo_stage.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e19_core_mimo_stage" && run_timed "$OUT/e19_core_mimo_stage"; then
            passed+=(e19_core_mimo_stage)
        else
            failed+=(e19_core_mimo_stage)
        fi
    else
        failed+=(e19_mimo_stage)
    fi
fi

# E19 S5: MIMO headroom term, per-source budget, excursion cap and rendered peak check at the standard rates.
if selected e19_mimo_safety; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_mimo_safety.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e19_core_mimo_safety" && run_timed "$OUT/e19_core_mimo_safety"; then
            passed+=(e19_core_mimo_safety)
        else
            failed+=(e19_core_mimo_safety)
        fi
    else
        failed+=(e19_mimo_safety)
    fi
fi
