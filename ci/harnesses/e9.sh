# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E9.

# E9 S6: per-output headroom maths at the eight standard rates.
if selected e9_headroom_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_headroom.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e9_core_headroom" && run_timed "$OUT/e9_core_headroom"; then
            passed+=(e9_core_headroom)
        else
            failed+=(e9_core_headroom)
        fi
    else
        failed+=(e9_headroom_core)
    fi
fi

# E9 S1: non-uniform partitioned FIR engine (accuracy, latency, block-size independence, tick cost, delay mode).
if selected e9_conv; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_conv.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e9_core_conv" && run_timed "$OUT/e9_core_conv"; then
            passed+=(e9_core_conv)
        else
            failed+=(e9_core_conv)
        fi
    else
        failed+=(e9_conv)
    fi
fi

# E9 S2 / S2b: long FIR across rebuilds (lazy carry, budgeted reset, small blocks, fade-less adoption, upstream posts).
if selected e9_conv_rebuild; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_conv_rebuild.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e9_core_conv_rebuild" && run_timed "$OUT/e9_core_conv_rebuild"; then
            passed+=(e9_core_conv_rebuild)
        else
            failed+=(e9_core_conv_rebuild)
        fi
    else
        failed+=(e9_conv_rebuild)
    fi
fi
