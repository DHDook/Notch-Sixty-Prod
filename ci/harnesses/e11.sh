# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E11.

# E11 S1-S4: measurement core (offline FFT, ESS, deconvolution, reference room, timing and averaging, distortion, decay, waterfall, spectrogram).
if selected e11_measure_core; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        for t in measure_fft measure measure_timing measure_analysis measure_waterfall measure_monitor generator; do
            if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src "core/tests/test_$t.cpp" \
                "${CORE_OBJS[@]}" -o "$OUT/e11_core_$t" && "$OUT/e11_core_$t"; then
                passed+=("e11_core_$t")
            else
                failed+=("e11_core_$t")
            fi
        done
    else
        failed+=(e11_measure_core)
    fi
fi

# E11 S2: targeted measurement bridge second-program playback and allocation-free process call.
if selected e11_targeted_bridge; then
    harness e11_targeted_bridge "${STRICT[@]}" -O2 -I"$RT" core/tests/test_targeted_bridge.c
fi
