# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Behavioural harnesses owned by epic E23.

# E23 K1c: the unified graph's Audio Unit rack adapter: no heap traffic on the realtime path over 10,000 blocks.
if selected e23_graph_rack_alloc; then
    build_core_objs
    # shellcheck disable=SC2086
    harness e23_graph_rack_alloc "${STRICT[@]}" -O2 -include stddef.h -I"$RT" -INotchSixty/Audio -Icore/include ci/harness_e23_graph_rack_alloc.c \
        NotchSixty/Audio/UnifiedGraph/N60GraphAudioUnitRack.c $(find "$RT" -name 'N60AudioUnitLiveRackBridge.c' -print) \
        ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate
fi
