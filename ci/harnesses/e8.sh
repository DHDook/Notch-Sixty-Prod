# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E8.

# The multi-sub optimiser header calls n60_correct_multisub_search (E8 A6a), so these link libn60core.
if selected pr58_multichannel_calibration || selected e8_multi_sub_tools; then
    build_core_objs
fi
for name in pr58_multichannel_calibration e8_multi_sub_tools; do
    # shellcheck disable=SC2086
    harness "$name" "${STRICT[@]}" -O2 -I"$RT" -Icore/include -Ici "ci/validate_$name.c" \
        ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -lm
done

# E8 A6a: multi-sub delay, gain and polarity search on its own table.
if selected e8_multisub_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_correct_multisub.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e8_core_correct_multisub" && run_timed "$OUT/e8_core_correct_multisub"; then
            passed+=(e8_core_correct_multisub)
        else
            failed+=(e8_core_correct_multisub)
        fi
    else
        failed+=(e8_multisub_core)
    fi
fi

# E8 S1: crossover filter library at the eight standard rates.
if selected e8_xover_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_xover.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e8_core_xover" && run_timed "$OUT/e8_core_xover"; then
            passed+=(e8_core_xover)
        else
            failed+=(e8_core_xover)
        fi
    else
        failed+=(e8_xover_core)
    fi
fi

# E8 S7: linear-phase FIR crossovers and the DRIVER_FIR stages (ABI v18), at the eight standard rates.
if selected e8_xover_fir_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_xover_fir.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e8_core_xover_fir" && run_timed "$OUT/e8_core_xover_fir"; then
            passed+=(e8_core_xover_fir)
        else
            failed+=(e8_core_xover_fir)
        fi
    else
        failed+=(e8_xover_fir_core)
    fi
fi

# E8 S8: near-field driver linearisation at the eight standard rates.
if selected e8_xover_linearise_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_xover_linearise.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e8_core_xover_linearise" && run_timed "$OUT/e8_core_xover_linearise"; then
            passed+=(e8_core_xover_linearise)
        else
            failed+=(e8_core_xover_linearise)
        fi
    else
        failed+=(e8_xover_linearise_core)
    fi
fi

# E8 S2: ROUTE and XOVER graph stages (ABI v17), the BASS_MGMT filter-spec trailer, at the eight standard rates.
if selected e8_route_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_route.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e8_core_route" && run_timed "$OUT/e8_core_route"; then
            passed+=(e8_core_route)
        else
            failed+=(e8_core_route)
        fi
    else
        failed+=(e8_route_core)
    fi
fi
