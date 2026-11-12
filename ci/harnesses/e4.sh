# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E4.

# E4 S4: speaker-ANC howl guard, the first C++20 engine core. Compiled once,
# then linked into its C harness.
if selected e4_anc_guard; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_anc_guard.cpp" -o "$OUT/n60_anc_guard.o"; then
        harness e4_anc_guard "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_anc_guard.c "$OUT/n60_anc_guard.o" -lc++ -lm
    else
        failed+=(e4_anc_guard)
    fi
fi
# E4 S14: dead-man lease on the anti-noise in the render kernel.
# shellcheck disable=SC2086
harness e4_engine_lease "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_engine_lease.c $ALL_RT_NO_BRIDGE -framework Accelerate -lc++
# E4 S15: live howl guard in the render kernel.
# shellcheck disable=SC2086
harness e4_howl_guard_live "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_howl_guard_live.c $ALL_RT_NO_BRIDGE -framework Accelerate
# E4 S18a: adaptive gain mailbox, phase-anchor telemetry ring and ambient host-time anchors.
# shellcheck disable=SC2086
harness e4_gain_mailbox "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_gain_mailbox.c \
    "$RT/N60ActiveQuietZone.c" "$RT/N60AmbientMonitorBridge.c" -framework CoreAudio -framework AudioToolbox
# E4 S20: earned-cap ceiling and the attempt-cap fix in the Quiet Zone runtime.
harness e4_earned_cap "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_earned_cap.c "$RT/N60ActiveQuietZone.c"

# E4 S21: per-tone excursion caps in the Quiet Zone runtime.
harness e4_excursion_cap "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_excursion_cap.c "$RT/N60ActiveQuietZone.c"
# E4 S13: acoustic twin (closed-loop room simulator) with the tonal canceller and
# howl guard in the loop. SOAK=1 adds the long drift and fault soak and the 8-hour overnight run (E4 S29).
if selected e4_acoustic_twin; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_anc_guard.cpp" -o "$OUT/n60_anc_guard_twin.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms_twin.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -Ici ci/harness_e4_acoustic_twin.cpp \
            "$OUT/n60_anc_guard_twin.o" "$OUT/n60_fxlms_twin.o" -o "$OUT/e4_acoustic_twin"; then
        echo "::group::e4_acoustic_twin"
        if run_timed "$OUT/e4_acoustic_twin" && { [ "${SOAK:-0}" != 1 ] || run_timed "$OUT/e4_acoustic_twin" --soak; } \
            && { [ "${SOAK:-0}" != 1 ] || run_timed "$OUT/e4_acoustic_twin" --overnight; }; then
            passed+=(e4_acoustic_twin)
        else
            failed+=(e4_acoustic_twin)
        fi
        echo "::endgroup::"
    else
        failed+=(e4_acoustic_twin)
    fi
fi
# E4 S18a: remote tonal worker core (microphone blocks on host time) on the acoustic twin.
# SOAK=1 adds the one-hour drift soak.
if selected e4_remote_tonal; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -include stddef.h -I"$RT" -Ici ci/harness_e4_remote_tonal.cpp \
            "$RT/n60_remote_tonal.cpp" -o "$OUT/e4_remote_tonal"; then
        echo "::group::e4_remote_tonal"
        if run_timed "$OUT/e4_remote_tonal" && { [ "${SOAK:-0}" != 1 ] || run_timed "$OUT/e4_remote_tonal" --soak; }; then
            passed+=(e4_remote_tonal)
        else
            failed+=(e4_remote_tonal)
        fi
        echo "::endgroup::"
    else
        failed+=(e4_remote_tonal)
    fi
fi
# E4 S22: programme removal (kernel demodulation of the music at each tone, and the remote tonal
# core taking it out of the error signal) at the eight standard rates.
if selected e4_programme_removal; then
    if clang -std=c11 -O2 -Wall -Wextra -Werror -include stddef.h -I"$RT" -c "$RT/N60ActiveQuietZone.c" -o "$OUT/n60_aqz_programme.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -include stddef.h -I"$RT" ci/harness_e4_programme_removal.cpp \
            "$RT/n60_remote_tonal.cpp" "$OUT/n60_aqz_programme.o" -o "$OUT/e4_programme_removal"; then
        echo "::group::e4_programme_removal"
        if run_timed "$OUT/e4_programme_removal"; then
            passed+=(e4_programme_removal)
        else
            failed+=(e4_programme_removal)
        fi
        echo "::endgroup::"
    else
        failed+=(e4_programme_removal)
    fi
fi
# E4 S5: adaptive ANC core (FxLMS) on a simulated plant.
if selected e4_fxlms; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms.o"; then
        harness e4_fxlms "${STRICT[@]}" -O2 -I"$RT" -Ici ci/harness_e4_fxlms.c "$OUT/n60_fxlms.o" -lc++ -lm
    else
        failed+=(e4_fxlms)
    fi
fi
# E4 S9a: feed-forward shadow canceller (1 x 2 x 1 block FxLMS) on a simulated plant.
if selected e4_ff_shadow; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms_ff.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_shadow.cpp" -o "$OUT/n60_ff_shadow.o"; then
        harness e4_ff_shadow "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_ff_shadow.c \
            "$OUT/n60_ff_shadow.o" "$OUT/n60_fxlms_ff.o" -lc++ -lm
    else
        failed+=(e4_ff_shadow)
    fi
fi
# E4 S22b1: feed-forward echo stage (leakage removal, offset search, gap, drift) on a simulated plant.
if selected e4_ff_echo; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms_echo.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_shadow.cpp" -o "$OUT/n60_ff_shadow_echo.o"; then
        harness e4_ff_echo "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_ff_echo.c \
            "$OUT/n60_ff_shadow_echo.o" "$OUT/n60_fxlms_echo.o" -lc++ -lm
    else
        failed+=(e4_ff_echo)
    fi
fi
# E4 S25a: live feed-forward filter (native head plus decimated tail) on a simulated plant.
if selected e4_ff_live; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms_live.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_live.cpp" -o "$OUT/n60_ff_live.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_echo.cpp" -o "$OUT/n60_ff_echo.o"; then
        harness e4_ff_live "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_ff_live.c \
            "$OUT/n60_ff_live.o" "$OUT/n60_ff_echo.o" "$OUT/n60_fxlms_live.o" -lc++ -lm
        # E4 S22b3: the echo stage on a simulated 128 ms leakage at the eight rates.
        harness e4_ff_live_echo "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_ff_live_echo.c \
            "$OUT/n60_ff_live.o" "$OUT/n60_ff_echo.o" "$OUT/n60_fxlms_live.o" -lc++ -lm
    else
        failed+=(e4_ff_live)
    fi
fi
# E4 S25b: live feed-forward wiring in the render kernel (reference ring, gate, loss trip, lease, drive).
# shellcheck disable=SC2086
harness e4_ff_live_wiring "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_ff_live_wiring.c $ALL_RT_NO_BRIDGE -framework Accelerate
# E4 S9b1: feed-forward survey (Welch H1 transfer and coherence) on a simulated plant.
if selected e4_ff_survey; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_fxlms.cpp" -o "$OUT/n60_fxlms_survey.o" \
        && clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_ff_survey.cpp" -o "$OUT/n60_ff_survey.o"; then
        harness e4_ff_survey "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_ff_survey.c \
            "$OUT/n60_ff_survey.o" "$OUT/n60_fxlms_survey.o" -lc++ -lm
    else
        failed+=(e4_ff_survey)
    fi
fi
