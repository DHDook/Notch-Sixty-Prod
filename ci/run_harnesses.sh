#!/usr/bin/env bash
# Builds and runs every behavioural C harness against the realtime sources.
# Each harness exercises engine code directly (no source-text matching); a
# non-zero exit from any harness fails the run. Used by .github/workflows/pr.yml.
#
#   ci/run_harnesses.sh            run all harnesses
#   ci/run_harnesses.sh pr69 pr70  run only harnesses whose name contains a filter
set -uo pipefail

cd "$(dirname "$0")/.."
OUT="${RUNNER_TEMP:-$(mktemp -d)}/harnesses"
mkdir -p "$OUT"

RT=NotchSixty/Audio/Realtime
ALL_RT=$(find "$RT" -name '*.c' -print | sort)
ALL_RT_NO_BRIDGE=$(find "$RT" -name '*.c' ! -name 'N60RealtimeAudioBridge.c' -print | sort)
STRICT=(-std=c11 -Wall -Wextra -Werror)
FILTERS=("$@")

passed=()
failed=()

selected() {
    [ ${#FILTERS[@]} -eq 0 ] && return 0
    local filter
    for filter in "${FILTERS[@]}"; do
        [[ "$1" == *"$filter"* ]] && return 0
    done
    return 1
}

# harness <name> <compile args...>: compiles to $OUT/<name> and runs it.
harness() {
    local name=$1
    shift
    selected "$name" || return 0
    echo "::group::$name"
    if clang "$@" -o "$OUT/$name" && "$OUT/$name"; then
        passed+=("$name")
    else
        failed+=("$name")
    fi
    echo "::endgroup::"
}

# build_core_objs: compiles libn60core once into CORE_OBJS (CORE_OK=0 on failure).
# The realtime bridge calls n60_graph_*, so bridge harnesses link these objects too.
CORE_BUILT=0
CORE_OK=0
CORE_OBJS=()
build_core_objs() {
    [ "$CORE_BUILT" = 1 ] && return 0
    CORE_BUILT=1
    CORE_OK=1
    local src
    for src in graph snapshot fft stages_dsp stages_system stages_matrix layout; do
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -fno-exceptions -fno-rtti -Icore/include \
            -c "core/src/$src.cpp" -o "$OUT/n60core_$src.o"; then
            CORE_OBJS+=("$OUT/n60core_$src.o")
        else
            CORE_OK=0
        fi
    done
}
# Bridge harnesses: build the core only when one of them is selected.
if selected pr35_transition_ack || selected pr41_same_device_output_map || selected pr101_realtime_resource_soak || selected e6_graph_takeover || selected e6_fade_alignment; then
    build_core_objs
fi

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
    pr57_binaural_renderer pr58_multichannel_calibration pr59_advanced_spatial pr60_nchannel_transport \
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
harness e6_fade_alignment "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e6_fade_alignment.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness e6_nchannel_graph "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/harness_e6_nchannel_graph.c $ALL_RT \
    -Icore/include ${CORE_OBJS[@]+"${CORE_OBJS[@]}"} -lc++ -framework Accelerate -framework CoreAudio
# shellcheck disable=SC2086
harness pr38_denoiser_advanced "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_pr38_denoiser_advanced.c $ALL_RT_NO_BRIDGE \
    -framework Accelerate
# shellcheck disable=SC2086
harness pr41_same_device_output_map "${STRICT[@]}" -O2 -include stddef.h -I"$RT" ci/validate_pr41_same_device_output_map.c $ALL_RT \
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

# E4 S4: speaker-ANC howl guard, the first C++20 engine core. Compiled once,
# then linked into its C harness.
if selected e4_anc_guard; then
    if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$RT" -c "$RT/n60_anc_guard.cpp" -o "$OUT/n60_anc_guard.o"; then
        harness e4_anc_guard "${STRICT[@]}" -O2 -I"$RT" ci/harness_e4_anc_guard.c "$OUT/n60_anc_guard.o" -lc++ -lm
    else
        failed+=(e4_anc_guard)
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
        harness e6_core_fracdelay_parity "${STRICT[@]}" -O2 -Icore/include core/tests/test_fracdelay_parity.c \
            "${CORE_OBJS[@]}" -lc++ -lm
        harness e6_core_system "${STRICT[@]}" -O2 -Icore/include core/tests/test_system.c \
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
        if clang++ -std=c++20 -O2 -Wall -Wextra -Werror -Icore/include core/tests/test_alloc.cpp \
            "${CORE_OBJS[@]}" -o "$OUT/e6_core_alloc" \
            && "$OUT/e6_core_alloc"; then :; else failed+=(e6_core_alloc); fi
    else
        failed+=(e6_core_graph)
    fi
fi

# Acoustic reference lab: production-header probes checked against independent
# Python oracles at every standard rate from 44.1 to 384 kHz.
for name in pr117_acoustic_reference_lab pr117b_fir_latency_headroom pr117c_spatial_reference; do
    selected "$name" || continue
    echo "::group::$name"
    if python3 "ci/validate_$name.py"; then passed+=("$name"); else failed+=("$name"); fi
    echo "::endgroup::"
done
if selected e4_anc_guard_reference; then
    echo "::group::e4_anc_guard_reference"
    if python3 ci/acoustic_reference_lab/e4_anc_guard_reference.py; then
        passed+=(e4_anc_guard_reference)
    else
        failed+=(e4_anc_guard_reference)
    fi
    echo "::endgroup::"
fi
if selected e4_ff_survey_reference; then
    echo "::group::e4_ff_survey_reference"
    if python3 ci/acoustic_reference_lab/e4_ff_survey_reference.py; then
        passed+=(e4_ff_survey_reference)
    else
        failed+=(e4_ff_survey_reference)
    fi
    echo "::endgroup::"
fi
if selected e4_ff_shadow_reference; then
    echo "::group::e4_ff_shadow_reference"
    if python3 ci/acoustic_reference_lab/e4_ff_shadow_reference.py; then
        passed+=(e4_ff_shadow_reference)
    else
        failed+=(e4_ff_shadow_reference)
    fi
    echo "::endgroup::"
fi
if selected e4_fxlms_reference; then
    echo "::group::e4_fxlms_reference"
    if python3 ci/acoustic_reference_lab/e4_fxlms_reference.py; then
        passed+=(e4_fxlms_reference)
    else
        failed+=(e4_fxlms_reference)
    fi
    echo "::endgroup::"
fi

echo
echo "Harnesses passed: ${#passed[@]}"
if [ ${#failed[@]} -gt 0 ]; then
    echo "Harnesses FAILED (${#failed[@]}): ${failed[*]}"
    exit 1
fi
if [ ${#passed[@]} -eq 0 ]; then
    echo "No harness matched the filters."
    exit 1
fi
