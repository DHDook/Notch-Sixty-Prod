# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E24.

# E24 S1: the Level step's render path (generator-only core graph + monitor ring) at every standard rate.
if selected e24_level_session; then
    build_core_objs
    if [ "$CORE_OK" = 1 ]; then
        harness e24_level_session "${STRICT[@]}" -O2 -I"$RT" -Icore/include ci/harness_e24_level_session.c \
            "$RT/N60LevelSessionProc.c" "${CORE_OBJS[@]}" -lc++ -lm -framework CoreAudio
    fi
fi
