# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E7.

# E7 S1: capacities in time at the eight standard rates (20 ms delay, 500 ms split fractional delay, 20 ms look-ahead).
if selected e7_rate_capacity; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_rate_capacity.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e7_core_rate_capacity" && run_timed "$OUT/e7_core_rate_capacity"; then
            passed+=(e7_core_rate_capacity)
        else
            failed+=(e7_core_rate_capacity)
        fi
    else
        failed+=(e7_rate_capacity)
    fi
fi
