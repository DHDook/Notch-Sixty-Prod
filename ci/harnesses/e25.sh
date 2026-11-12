# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E25.

# E25 S2: STEREO_CROSSOVER filter-spec trailer, lane polarity (negative GAIN) and crossover + ROOM_FIR (ABI v19).
if selected e25_stereo_bass; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_stereo_bass.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e25_core_stereo_bass" && run_timed "$OUT/e25_core_stereo_bass"; then
            passed+=(e25_core_stereo_bass)
        else
            failed+=(e25_core_stereo_bass)
        fi
    else
        failed+=(e25_stereo_bass)
    fi
fi
