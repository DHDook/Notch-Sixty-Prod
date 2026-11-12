# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E20.

# E20 S1: benchmark harness self-test (scenarios build and stay finite at all eight rates, gate logic) and the per-stage
# profile hooks (absent from product objects, present and correct in a -DN60_GRAPH_PROFILE build).
if selected e20_bench || selected e20_profile; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        PROFILE_OBJS=()
        for obj in "${CORE_OBJS[@]}"; do
            if [ "$obj" = "$OUT/n60core_snapshot.o" ]; then PROFILE_OBJS+=("$OUT/n60core_snapshot_profile.o"); else PROFILE_OBJS+=("$obj"); fi
        done
        if selected e20_profile; then
            if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -DN60_GRAPH_PROFILE -Icore/include -Icore/src \
                    -c core/src/snapshot.cpp -o "$OUT/n60core_snapshot_profile.o" \
                && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_profile.cpp "${CORE_OBJS[@]}" \
                    -Wl,-U,_n60_profile_read -Wl,-U,_n60_profile_reset -o "$OUT/e20_profile_absent" && run_timed "$OUT/e20_profile_absent" absent \
                && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_profile.cpp "${PROFILE_OBJS[@]}" \
                    -o "$OUT/e20_profile_present" && run_timed "$OUT/e20_profile_present" present; then
                passed+=(e20_profile)
            else
                failed+=(e20_profile)
            fi
        fi
        if selected e20_bench; then
            if [ ! -f "$OUT/n60core_snapshot_profile.o" ]; then
                clang++ -std=c++20 -O2 -fno-exceptions -fno-rtti -DN60_GRAPH_PROFILE -Icore/include -Icore/src -c core/src/snapshot.cpp \
                    -o "$OUT/n60core_snapshot_profile.o"
            fi
            if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/bench/n60_bench.cpp "${CORE_OBJS[@]}" \
                    -framework Accelerate -o "$OUT/e20_bench_product" && run_timed "$OUT/e20_bench_product" --self-test \
                && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -DN60_BENCH_PROFILE -Icore/include -Icore/src core/bench/n60_bench.cpp \
                    "${PROFILE_OBJS[@]}" -framework Accelerate -o "$OUT/e20_bench_profile" && run_timed "$OUT/e20_bench_profile" --self-test; then
                passed+=(e20_bench)
            else
                failed+=(e20_bench)
            fi
        fi
    else
        failed+=(e20_bench)
    fi
fi
