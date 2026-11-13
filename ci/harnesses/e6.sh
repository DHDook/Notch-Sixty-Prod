# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E6.

# E6 S12f2: state carry across a swap, non-finite reset, corner precision against a double reference.
if selected e6_state_carry; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_state_carry.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_state_carry" && run_timed "$OUT/e6_core_state_carry"; then
            passed+=(e6_core_state_carry)
        else
            failed+=(e6_core_state_carry)
        fi
    else
        failed+=(e6_state_carry)
    fi
fi

# E6 S12h: loudness and multiband carry, carry bytes charged to the budget, deferred-swap re-carry (G16, G21, G38).
if selected e6_stage_carry2; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_stage_carry2.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_stage_carry2" && run_timed "$OUT/e6_core_stage_carry2"; then
            passed+=(e6_core_stage_carry2)
        else
            failed+=(e6_core_stage_carry2)
        fi
    else
        failed+=(e6_stage_carry2)
    fi
fi

# E6 S12h (G36): float image and de-ess stages against a double reference (widener corner, 1000 ms release).
if selected e6_image_precision; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_image_precision.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_image_precision" && run_timed "$OUT/e6_core_image_precision"; then
            passed+=(e6_core_image_precision)
        else
            failed+=(e6_core_image_precision)
        fi
    else
        failed+=(e6_image_precision)
    fi
fi

# E6 S12a: the cleanup stage (DC, infrasonic, mains notch, hum detector): behaviour at the eight standard rates.
if selected e6_cleanup; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_cleanup.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_cleanup" && run_timed "$OUT/e6_core_cleanup"; then
            passed+=(e6_core_cleanup)
        else
            failed+=(e6_core_cleanup)
        fi
    else
        failed+=(e6_cleanup)
    fi
fi

# E6 S12b: the image and de-ess stages (stereo mode, widener, de-harsh, de-esser): behaviour at the eight standard rates.
if selected e6_image; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_image.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_image" && run_timed "$OUT/e6_core_image"; then
            passed+=(e6_core_image)
        else
            failed+=(e6_core_image)
        fi
    else
        failed+=(e6_image)
    fi
fi

# E6 S12d: the multiband compressor stage: behaviour at the eight standard rates.
if selected e6_multiband; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_multiband.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_multiband" && run_timed "$OUT/e6_core_multiband"; then
            passed+=(e6_core_multiband)
        else
            failed+=(e6_core_multiband)
        fi
    else
        failed+=(e6_multiband)
    fi
fi

# E6 S12e: the PEQ kernel types and wide chains: behaviour at the eight standard rates.
if selected e6_peq_wide; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_peq_wide.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_peq_wide" && run_timed "$OUT/e6_core_peq_wide"; then
            passed+=(e6_core_peq_wide)
        else
            failed+=(e6_core_peq_wide)
        fi
    else
        failed+=(e6_peq_wide)
    fi
fi

# E6 S12g2: the lane delay ahead of bass management: exact shift, order and live change at the eight standard rates.
if selected e6_lane_delay; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_lane_delay.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_lane_delay" && run_timed "$OUT/e6_core_lane_delay"; then
            passed+=(e6_core_lane_delay)
        else
            failed+=(e6_core_lane_delay)
        fi
    else
        failed+=(e6_lane_delay)
    fi
fi

# E6 S12h parts 2b and 3: delta audition capture and subtract (ABI v31, mask form, fractional alignment): exact alignment per lane, protection latency, validation
# and ring carry at the eight standard rates.
if selected e6_delta_audition; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_delta_audition.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_delta_audition" && run_timed "$OUT/e6_core_delta_audition"; then
            passed+=(e6_core_delta_audition)
        else
            failed+=(e6_core_delta_audition)
        fi
    else
        failed+=(e6_delta_audition)
    fi
fi

# E6 S12c: the loudness stage (match, contour, dialogue leveler): behaviour at the eight standard rates.
if selected e6_loudness; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_loudness.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_loudness" && run_timed "$OUT/e6_core_loudness"; then
            passed+=(e6_core_loudness)
        else
            failed+=(e6_core_loudness)
        fi
    else
        failed+=(e6_loudness)
    fi
fi

# E6 S2/S3: libn60core (portable C++ core behind its versioned C ABI): graph skeleton,
# snapshot swap, lane stages, allocation hook, and parity with the kernel biquad.
if selected e6_core_graph; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        harness e6_core_graph "${STRICT[@]}" -O2 -Icore/include core/tests/test_graph.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_stages "${STRICT[@]}" -O2 -Icore/include core/tests/test_stages.c \
            "${CORE_OBJS[@]}" -lc++ -lm -lpthread
        harness e6_core_parity "${STRICT[@]}" -O2 -Icore/include core/tests/test_parity.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_dsp "${STRICT[@]}" -O2 -Icore/include core/tests/test_dsp.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_protection_parity "${STRICT[@]}" -O2 -Icore/include core/tests/test_protection_parity.c \
            "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_xover_clipper_parity "${STRICT[@]}" -O2 -Icore/include core/tests/test_xover_clipper_parity.c \
            "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_cleanup_parity "${STRICT[@]}" -O2 -include stddef.h -Icore/include -I"$RT" core/tests/test_cleanup_parity.c \
            "$RT/N60Dynamics.c" "$RT/N60DynamicEQ.c" "$RT/N60SpectralDenoiser.c" "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_image_parity "${STRICT[@]}" -O2 -include stddef.h -Icore/include -I"$RT" core/tests/test_image_parity.c \
            "$RT/N60Dynamics.c" "$RT/N60DynamicEQ.c" "$RT/N60SpectralDenoiser.c" "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_loudness_parity "${STRICT[@]}" -O2 -include stddef.h -Icore/include -I"$RT" core/tests/test_loudness_parity.c \
            "$RT/N60Dynamics.c" "$RT/N60DynamicEQ.c" "$RT/N60SpectralDenoiser.c" "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_multiband_parity "${STRICT[@]}" -O2 -include stddef.h -Icore/include -I"$RT" core/tests/test_multiband_parity.c \
            "$RT/N60Dynamics.c" "$RT/N60DynamicEQ.c" "$RT/N60SpectralDenoiser.c" "$RT/N60Protection.c" "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_fracdelay_parity "${STRICT[@]}" -O2 -Icore/include core/tests/test_fracdelay_parity.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_external "${STRICT[@]}" -O2 -Icore/include core/tests/test_external.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_system "${STRICT[@]}" -O2 -Icore/include core/tests/test_system.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e4_core_ambient_sections "${STRICT[@]}" -O2 -Icore/include core/tests/test_ambient_sections.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_rebuild "${STRICT[@]}" -O2 -Icore/include core/tests/test_rebuild.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_denoiser_carry "${STRICT[@]}" -O2 -Icore/include core/tests/test_denoiser_carry.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_multisub "${STRICT[@]}" -O2 -Icore/include core/tests/test_multisub.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_layout "${STRICT[@]}" -O2 -Icore/include core/tests/test_layout.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_readbacks "${STRICT[@]}" -O2 -Icore/include core/tests/test_readbacks.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_binaural_parity "${STRICT[@]}" -O2 -Icore/include -I"$RT" core/tests/test_binaural_parity.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        # E13 S4: shared multirate BRIR tail against an offline FFT convolution at the eight rates.
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_binaural_tail.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e13_binaural_tail" && "$OUT/e13_binaural_tail" >"$OUT/e13_binaural_tail.log" 2>&1; then :; else tail -20 "$OUT/e13_binaural_tail.log"; failed+=(e13_binaural_tail); fi
        # E6 S10: whole-graph parity suite (short corpus; N60_PARITY_FULL=1 runs the full corpus and timings).
        harness e6_core_parity_suite "${STRICT[@]}" -O2 -Icore/include core/tests/test_parity_suite.c \
            "${CORE_OBJS[@]}" -lc++ -lm -framework Accelerate
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_alloc.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_alloc" \
            && run_timed "$OUT/e6_core_alloc"; then :; else failed+=(e6_core_alloc); fi
        # E20 S2: the realtime annotations only check anything where the compiler supports clang function effects.
        # -Wno-unknown-warning-option would hide a toolchain without it, so fail loudly instead.
        if printf '#if !(defined(__has_cpp_attribute) && __has_cpp_attribute(clang::nonblocking))\n#error no function effects\n#endif\nint main(){return 0;}\n' \
            | clang++ -std=c++20 -x c++ -fsyntax-only - 2>/dev/null; then :; else failed+=(e20_function_effects_unsupported); fi
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_fpenv.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e20_core_fpenv" \
            && run_timed "$OUT/e20_core_fpenv"; then :; else failed+=(e20_core_fpenv); fi
        # E20 S5: parallel render core, bit-identical output at 0 to 3 workers, delayed and absent workers, no allocation.
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_parallel.cpp \
            "${CORE_OBJS[@]}" -pthread -o "$OUT/e20_core_parallel" && run_timed "$OUT/e20_core_parallel"; then :; else failed+=(e20_core_parallel); fi
        # E20 S10b: lane-parallel PROTECTION, bit-identical to the serial stage at 1 to 3 workers, eight rates.
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_protection_parallel.cpp \
            "${CORE_OBJS[@]}" -pthread -o "$OUT/e20_protection_parallel" && run_timed "$OUT/e20_protection_parallel"; then :; else failed+=(e20_protection_parallel); fi
        # E20 S3: SIMD primitives and lane independence, then the SIMD build against the scalar build (N60_SIMD=0):
        # a chain through every SIMD stage must hash identically at every rate, lane count and block size.
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_simd_parity.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e20_simd_parity" && run_timed "$OUT/e20_simd_parity" check; then :; else failed+=(e20_simd_parity); fi
        simd_scalar_ok=1
        simd_scalar_objs=()
        for src in "${CORE_SOURCES[@]}"; do
            obj="$OUT/n60scalar_${src//\//_}.o"
            if clang++ -std=c++20 -O2 -DN60_SIMD=0 -Wno-unknown-warning-option -fno-exceptions -fno-rtti -Icore/include -Icore/src \
                -c "core/src/$src.cpp" -o "$obj"; then simd_scalar_objs+=("$obj"); else simd_scalar_ok=0; fi
        done
        if [ "$simd_scalar_ok" = 1 ] \
            && clang++ -std=c++20 -O2 -DN60_SIMD=0 -Icore/include -Icore/src core/tests/test_simd_parity.cpp \
                "${simd_scalar_objs[@]}" -o "$OUT/e20_simd_parity_scalar" \
            && run_timed "$OUT/e20_simd_parity_scalar" check \
            && run_timed "$OUT/e20_simd_parity" dump > "$OUT/e20_simd_dump_vector.txt" \
            && run_timed "$OUT/e20_simd_parity_scalar" dump > "$OUT/e20_simd_dump_scalar.txt" \
            && cmp "$OUT/e20_simd_dump_vector.txt" "$OUT/e20_simd_dump_scalar.txt"; then :; else failed+=(e20_simd_scalar_parity); fi
        # E20 S4: FFT (SIMD butterflies, real-input packing) and convolution against a double reference, then SIMD against scalar.
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_fft_conv.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e20_fft_conv" && run_timed "$OUT/e20_fft_conv" check; then :; else failed+=(e20_fft_conv); fi
        if [ "$simd_scalar_ok" = 1 ] \
            && clang++ -std=c++20 -O2 -DN60_SIMD=0 -Icore/include -Icore/src core/tests/test_fft_conv.cpp \
                "${simd_scalar_objs[@]}" -o "$OUT/e20_fft_conv_scalar" \
            && run_timed "$OUT/e20_fft_conv" dump > "$OUT/e20_fft_dump_vector.txt" \
            && run_timed "$OUT/e20_fft_conv_scalar" dump > "$OUT/e20_fft_dump_scalar.txt" \
            && cmp "$OUT/e20_fft_dump_vector.txt" "$OUT/e20_fft_dump_scalar.txt"; then :; else failed+=(e20_fft_scalar_parity); fi
    else
        failed+=(e6_core_graph)
    fi
fi
