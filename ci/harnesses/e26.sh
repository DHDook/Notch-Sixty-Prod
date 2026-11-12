# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E26.

# E26 S1: tonal anti-noise bypasses the stereo crossover on the legacy kernel (class C is not a sub for Quiet Zone).
# shellcheck disable=SC2086
harness e26_anc_bypass "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e26_anc_bypass.c $ALL_RT_NO_BRIDGE -framework Accelerate -lc++
# E26 S1: the twin's downstream-sub and app-splitter bass-path models.
if selected e26_bass_path; then
    echo "::group::e26_bass_path"
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Ici ci/harness_e26_bass_path.cpp -o "$OUT/e26_bass_path" && run_timed "$OUT/e26_bass_path"; then
        passed+=(e26_bass_path)
    else
        failed+=(e26_bass_path)
    fi
    echo "::endgroup::"
fi
# E26 S6a: the ANC stages with the sub lane as an actuator (placement, lane rules, three-actuator cancellation).
if selected e26_anc_actuators; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include -Icore/src core/tests/test_anc_actuators.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e26_core_anc_actuators" && run_timed "$OUT/e26_core_anc_actuators"; then
            passed+=(e26_core_anc_actuators)
        else
            failed+=(e26_core_anc_actuators)
        fi
    else
        failed+=(e26_anc_actuators)
    fi
fi

# E26 S7b1 (G1): the host feed for the anti-noise lanes (lanes equal the offline splitter render, lease and fade, no allocation).
if selected e26_anc_lane_feed; then
    if clang -std=c11 -O2 -Wall -Wextra -Werror -include stddef.h -I"$RT" -c "$RT/N60ActiveQuietZone.c" -o "$OUT/e26_alf_aqz.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/e26_alf_fxlms.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_live.cpp" -o "$OUT/e26_alf_ff_live.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_echo.cpp" -o "$OUT/e26_alf_ff_echo.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_anc_lane_feed.cpp" -o "$OUT/e26_alf_feed.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" core/tests/test_anc_lane_feed.cpp \
            "$OUT/e26_alf_feed.o" "$OUT/e26_alf_aqz.o" "$OUT/e26_alf_ff_live.o" "$OUT/e26_alf_ff_echo.o" \
            "$OUT/e26_alf_fxlms.o" -o "$OUT/e26_anc_lane_feed" && run_timed "$OUT/e26_anc_lane_feed"; then
        passed+=(e26_anc_lane_feed)
    else
        failed+=(e26_anc_lane_feed)
    fi
fi

# E26 S6a: further output programs (splitter-rendered mains and the sub lane) in the same pass.
harness e26_bridge_lanes "${STRICT[@]}" -O2 -I"$RT" core/tests/test_targeted_bridge_lanes.c -lm
