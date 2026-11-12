# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E10.

# E10 S1: room-correction design core (minimum-phase parity maths, FDW, excess phase, synthesis, pre-ringing audit).
if selected e10_correct_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_correct.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e10_core_correct" && run_timed "$OUT/e10_core_correct"; then
            passed+=(e10_core_correct)
        else
            failed+=(e10_core_correct)
        fi
    else
        failed+=(e10_correct_core)
    fi
fi

# E10 S6: joint mains-and-subwoofer bass optimiser at the eight standard rates.
if selected e10_bass_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_correct_bass.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e10_core_correct_bass" && run_timed "$OUT/e10_core_correct_bass"; then
            passed+=(e10_core_correct_bass)
        else
            failed+=(e10_core_correct_bass)
        fi
    else
        failed+=(e10_bass_core)
    fi
fi
