# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E33.

# E33 S21: fit EQ bands to a curve (n60/eqfit.h): known peaks fitted, determinism, boost cap, refusals at the eight rates.
if selected e33_eqfit; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_eqfit.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e33_core_eqfit" && run_timed "$OUT/e33_core_eqfit"; then
            passed+=(e33_core_eqfit)
        else
            failed+=(e33_core_eqfit)
        fi
    else
        failed+=(e33_eqfit)
    fi
fi

# E33 S5a: expander lookahead (ABI v41): latency, first-period pass, ring carry and bit-identity at the eight standard rates.
if selected e33_exp_lookahead; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_exp_lookahead.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e33_core_exp_lookahead" && run_timed "$OUT/e33_core_exp_lookahead"; then
            passed+=(e33_core_exp_lookahead)
        else
            failed+=(e33_core_exp_lookahead)
        fi
    else
        failed+=(e33_exp_lookahead)
    fi
fi
