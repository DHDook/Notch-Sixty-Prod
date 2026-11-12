# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E28.

# E28 S7a: compressor mix, link amount, detector and lookahead (ABI v33): behaviour at the eight standard rates.
if selected e28_comp_extras; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_comp_extras.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e28_core_comp_extras" && run_timed "$OUT/e28_core_comp_extras"; then
            passed+=(e28_core_comp_extras)
        else
            failed+=(e28_core_comp_extras)
        fi
    else
        failed+=(e28_comp_extras)
    fi
fi

# E28 S7b: expander hold, knee, detector, sidechain filter, link and sidechain / delta listen (ABI v35).
if selected e28_exp_extras; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_exp_extras.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e28_core_exp_extras" && run_timed "$OUT/e28_core_exp_extras"; then
            passed+=(e28_core_exp_extras)
        else
            failed+=(e28_core_exp_extras)
        fi
    else
        failed+=(e28_exp_extras)
    fi
fi

# E28 S7c: multiband bypass, solo, listen, detector and shared lookahead (ABI v37).
if selected e28_mb_extras; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_mb_extras.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e28_core_mb_extras" && "$OUT/e28_core_mb_extras"; then
            passed+=(e28_core_mb_extras)
        else
            failed+=(e28_core_mb_extras)
        fi
    else
        failed+=(e28_mb_extras)
    fi
fi

# E28 G42: the multiband band-pass tree at the eight standard rates.
if selected e28_mb_split; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_mb_split.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e28_core_mb_split" && "$OUT/e28_core_mb_split"; then
            passed+=(e28_core_mb_split)
        else
            failed+=(e28_core_mb_split)
        fi
    else
        failed+=(e28_mb_split)
    fi
fi
