# Sourced by ci/run_harnesses.sh (shares its helpers: harness, selected, run_timed, build_core_objs, CORE_OBJS, STRICT, RT, OUT, passed, failed).
# Harnesses from before the epic plan (PR34 to PR117 era names).

# Standalone DSP maths (PR34 parity set).
for name in bandpass compiled_eq constantq linkwitz midside; do
    harness "pr34_$name" "${STRICT[@]}" "ci/validate_pr34_$name.c"
done
for name in crosstalk_cancellation mixed_phase speaker_crossfeed symmetry_balance; do
    harness "pr34_$name" "${STRICT[@]}" "ci/validate_pr34_$name.c" -lm
done
harness pr34_dynamic_domains "${STRICT[@]}" -I"$RT" ci/validate_pr34_dynamic_domains.c "$RT/N60DynamicEQ.c" -lm

harness pr34_mid_side "${STRICT[@]}" ci/validate_pr34_mid_side.c -lm
harness pr43_driver_runtime "${STRICT[@]}" -include stddef.h -I"$RT" ci/validate_pr43_driver_runtime.c $ALL_RT_NO_BRIDGE -framework Accelerate

# Semantic N-channel engine (PR53-60, PR66): router, lanes, bass management,
# headphone and binaural DSP, calibration, spatial, transport, head tracking.
harness pr53_channel_router "${STRICT[@]}" -I"$RT" ci/validate_pr53_channel_router.c -lm
for name in pr54_nchannel_lanes pr55_multichannel_bass_management pr55_subwoofer_tuning pr56_headphone_dsp \
    pr57_binaural_renderer pr59_advanced_spatial pr60_nchannel_transport \
    pr60_coreaudio_transport pr66_head_tracking; do
    harness "$name" "${STRICT[@]}" -O2 -I"$RT" "ci/validate_$name.c" -lm
done
# Stereo realtime kernel and bridge contracts (PR35, PR38, PR41).
harness pr35_denoiser_bounded_reset "${STRICT[@]}" -I"$RT" ci/validate_pr35_denoiser_bounded_reset.c "$RT/N60SpectralDenoiser.c"
harness pr35_denoiser_validated_fastpath "${STRICT[@]}" -I"$RT" ci/validate_pr35_denoiser_validated_fastpath.c "$RT/N60SpectralDenoiser.c"
harness pr35_disabled_dsp_fastpath "${STRICT[@]}" -include stddef.h -I"$RT" ci/validate_pr35_disabled_dsp_fastpath.c \
    "$RT/N60Dynamics.c" "$RT/N60DynamicEQ.c" "$RT/N60SpectralDenoiser.c" "$RT/N60Protection.c" -lm
# shellcheck disable=SC2086
harness pr35_snapshot_pointer_api "${STRICT[@]}" -include stddef.h -I"$RT" ci/validate_pr35_snapshot_pointer_api.c $ALL_RT_NO_BRIDGE -framework Accelerate
harness pr35_protection_sparse_reset "${STRICT[@]}" -I"$RT" ci/validate_pr35_protection_sparse_reset.c "$RT/N60Protection.c"
# shellcheck disable=SC2086
harness pr35_meter_gating "${STRICT[@]}" -include stddef.h -I"$RT" ci/validate_pr35_meter_gating.c $ALL_RT_NO_BRIDGE -framework Accelerate
# shellcheck disable=SC2086
harness pr35_render_context_snapshot_pointer -std=c11 -Wall -Wextra -include stddef.h -I"$RT" \
    ci/validate_pr35_render_context_snapshot_pointer.c $ALL_RT_NO_BRIDGE -framework Accelerate
# shellcheck disable=SC2086
harness pr35_transition_ack "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_pr35_transition_ack.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e6_graph_takeover "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_e6_graph_takeover.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e20_bridge_fastpath "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e20_bridge_fastpath.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e25_fold "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e25_fold.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e6_fade_alignment "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e6_fade_alignment.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e6_nchannel_graph "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e6_nchannel_graph.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e4_speaker_drive "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e4_speaker_drive.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e8_routed_output "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e8_routed_output.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e6_shutdown_fade "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e6_shutdown_fade.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness pr38_denoiser_advanced "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_pr38_denoiser_advanced.c $ALL_RT_NO_BRIDGE \
    -framework Accelerate
# shellcheck disable=SC2086
harness pr41_same_device_output_map "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_pr41_same_device_output_map.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio

# shellcheck disable=SC2086
harness e28_route_meter "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e28_route_meter.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio

# shellcheck disable=SC2086
harness e28_loudness_capture "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e28_loudness_capture.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio

# Adaptive-rate transport (PR69-71).
harness pr69_adaptive_src "${STRICT[@]}" -O2 -I"$RT" ci/validate_pr69_adaptive_src.c "$RT/N60AdaptiveSampleRate.c" -lm
harness pr70_stereo_transport_sim "${STRICT[@]}" -O2 -I"$RT" ci/validate_pr70_stereo_transport_sim.c "$RT/N60AdaptiveSampleRate.c" -lm
harness pr71_nchannel_adaptive_src "${STRICT[@]}" -O2 -I"$RT" ci/validate_pr71_nchannel_adaptive_src.c "$RT/N60AdaptiveSampleRate.c" -lm

# MIMO room treatment (PR73-77).
for name in pr73_mimo_room_treatment pr74_mimo_fir_runtime pr76_treatment_transition pr77_live_room_treatment; do
    harness "$name" "${STRICT[@]}" -O2 -I"$RT" "ci/validate_$name.c" -lm
done

# Audio Unit rack exchange and stage-fault containment (PR82, PR84A).
for name in pr82_audio_unit_rack_exchange pr84a_audio_unit_stage_fault_gate; do
    harness "$name" "${STRICT[@]}" -O2 -I"$RT" "ci/validate_$name.c" \
        "$RT/N60AudioUnitRackExchange.c" "$RT/N60AudioUnitLiveRackBridge.c" -lm
done

# SOFA/AES69 reader bridge (PR85; vendored libmysofa).
SOFA=NotchSixty/Audio/SOFA
MYSOFA=$SOFA/Vendor/libmysofa
harness pr85_sofa_bridge -std=gnu11 -O2 -Wall -Wextra -I"$SOFA" -I"$MYSOFA/hrtf" -I"$MYSOFA/hdf" \
    ci/validate_pr85_sofa_bridge.c "$SOFA/N60SOFABridge.c" \
    "$MYSOFA/hrtf/reader.c" "$MYSOFA/hrtf/tools.c" "$MYSOFA/hrtf/spherical.c" \
    "$MYSOFA/hdf/superblock.c" "$MYSOFA/hdf/dataobject.c" "$MYSOFA/hdf/btree.c" \
    "$MYSOFA/hdf/fractalhead.c" "$MYSOFA/hdf/gunzip.c" "$MYSOFA/hdf/gcol.c" -lz -lm

# Output timing (PR96), FIR runtimes (PR107), realtime resource soak (PR101).
harness pr96_output_timing_smoke -std=c11 -I"$RT" -framework CoreAudio ci/pr96_output_timing_smoke.c
harness pr107_live_fir_render "${STRICT[@]}" -O2 -I"$RT" ci/validate_pr107_live_fir_render.c -lm
harness pr107_program_fir_runtime "${STRICT[@]}" -O2 -I"$RT" ci/validate_pr107_program_fir_runtime.c -lm
# shellcheck disable=SC2086
harness pr101_realtime_resource_soak "${STRICT[@]}" -O3 -arch arm64 -include stddef.h -I"$RT" \
    ci/validate_pr101_realtime_resource_soak.c $ALL_RT -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
