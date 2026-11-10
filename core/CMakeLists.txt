# libn60core: portable engine core (E6 S2, E21). No Apple framework, no third-party code.
cmake_minimum_required(VERSION 3.20)
project(n60core LANGUAGES C CXX)

add_library(n60core STATIC src/graph.cpp src/snapshot.cpp src/fft.cpp src/stages_dsp.cpp src/conv/nufir.cpp src/stages_system.cpp src/stages_matrix.cpp src/stages_generator.cpp src/stages_cleanup.cpp src/stages_image.cpp src/stages_loudness.cpp src/stages_multiband.cpp src/stages_route.cpp src/layout.cpp
    src/measure/offline_fft.cpp src/measure/ess.cpp src/measure/deconvolve.cpp src/measure/reference_room.cpp src/measure/timing.cpp src/measure/distortion.cpp src/measure/decay.cpp src/measure/waterfall.cpp src/measure/monitor_ring.cpp src/measure/spl.cpp src/measure/rta.cpp src/measure/predict.cpp src/mimo/design.cpp
    src/correct/minphase.cpp src/correct/design.cpp src/correct/synth.cpp src/correct/bass.cpp src/correct/multisub_search.cpp
    src/xover/xover.cpp src/headroom/headroom.cpp)
target_compile_features(n60core PUBLIC cxx_std_20)
target_include_directories(n60core PUBLIC include)
target_include_directories(n60core PRIVATE src)
target_compile_options(n60core PRIVATE -Wall -Wextra -Werror -Wno-unknown-warning-option -Werror=function-effects -fno-exceptions -fno-rtti)

enable_testing()
add_executable(n60core_graph_test tests/test_graph.c)
set_target_properties(n60core_graph_test PROPERTIES C_STANDARD 11)
target_link_libraries(n60core_graph_test PRIVATE n60core m)
set_target_properties(n60core_graph_test PROPERTIES LINKER_LANGUAGE CXX)
add_test(NAME n60core_graph COMMAND n60core_graph_test)

find_package(Threads REQUIRED)
add_executable(n60core_stages_test tests/test_stages.c)
set_target_properties(n60core_stages_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_stages_test PRIVATE n60core m Threads::Threads)
add_test(NAME n60core_stages COMMAND n60core_stages_test)

add_executable(n60core_alloc_test tests/test_alloc.cpp)
target_link_libraries(n60core_alloc_test PRIVATE n60core)
add_test(NAME n60core_alloc COMMAND n60core_alloc_test)

add_executable(n60core_fpenv_test tests/test_fpenv.cpp)
target_link_libraries(n60core_fpenv_test PRIVATE n60core)
target_include_directories(n60core_fpenv_test PRIVATE src)
add_test(NAME n60core_fpenv COMMAND n60core_fpenv_test)
add_executable(n60core_simd_parity_test tests/test_simd_parity.cpp)
target_link_libraries(n60core_simd_parity_test PRIVATE n60core)
target_include_directories(n60core_simd_parity_test PRIVATE src)
add_test(NAME n60core_simd_parity COMMAND n60core_simd_parity_test check)

add_executable(n60core_dsp_test tests/test_dsp.c)
set_target_properties(n60core_dsp_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_dsp_test PRIVATE n60core m)
add_test(NAME n60core_dsp COMMAND n60core_dsp_test)

add_executable(n60core_system_test tests/test_system.c)
set_target_properties(n60core_system_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_system_test PRIVATE n60core m)
add_test(NAME n60core_system COMMAND n60core_system_test)

add_executable(n60core_ambient_sections_test tests/test_ambient_sections.c)
set_target_properties(n60core_ambient_sections_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_ambient_sections_test PRIVATE n60core m)
add_test(NAME n60core_ambient_sections COMMAND n60core_ambient_sections_test)

add_executable(n60core_external_test tests/test_external.c)
set_target_properties(n60core_external_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_external_test PRIVATE n60core m)
add_test(NAME n60core_external COMMAND n60core_external_test)

add_executable(n60core_rebuild_test tests/test_rebuild.c)
set_target_properties(n60core_rebuild_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_rebuild_test PRIVATE n60core m)
add_test(NAME n60core_rebuild COMMAND n60core_rebuild_test)

add_executable(n60core_denoiser_carry_test tests/test_denoiser_carry.c)
set_target_properties(n60core_denoiser_carry_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_denoiser_carry_test PRIVATE n60core m)
add_test(NAME n60core_denoiser_carry COMMAND n60core_denoiser_carry_test)

add_executable(n60core_layout_test tests/test_layout.c)
set_target_properties(n60core_layout_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_layout_test PRIVATE n60core m)
add_test(NAME n60core_layout COMMAND n60core_layout_test)

add_executable(n60core_multisub_test tests/test_multisub.c)
set_target_properties(n60core_multisub_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_multisub_test PRIVATE n60core m)
add_test(NAME n60core_multisub COMMAND n60core_multisub_test)

add_executable(n60core_readbacks_test tests/test_readbacks.c)
set_target_properties(n60core_readbacks_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_readbacks_test PRIVATE n60core m)
add_test(NAME n60core_readbacks COMMAND n60core_readbacks_test)

# E11 S1: measurement core (n60/measure.h). The tests reach the internal offline FFT, so they see src/.
add_executable(n60core_measure_fft_test tests/test_measure_fft.cpp)
target_include_directories(n60core_measure_fft_test PRIVATE src)
target_link_libraries(n60core_measure_fft_test PRIVATE n60core)
add_test(NAME n60core_measure_fft COMMAND n60core_measure_fft_test)

add_executable(n60core_measure_test tests/test_measure.cpp)
target_include_directories(n60core_measure_test PRIVATE src)
target_link_libraries(n60core_measure_test PRIVATE n60core)
add_test(NAME n60core_measure COMMAND n60core_measure_test)

# E11 S2: timing reference and repeat averaging.
add_executable(n60core_measure_timing_test tests/test_measure_timing.cpp)
target_link_libraries(n60core_measure_timing_test PRIVATE n60core)
add_test(NAME n60core_measure_timing COMMAND n60core_measure_timing_test)

# E11 S3: distortion (H2-H5) and decay (EDT, T20, T30, RT60).
add_executable(n60core_measure_analysis_test tests/test_measure_analysis.cpp)
target_link_libraries(n60core_measure_analysis_test PRIVATE n60core)
add_test(NAME n60core_measure_analysis COMMAND n60core_measure_analysis_test)

# E19 S1: predicted treated IR and per-source modes in the reference room.
add_executable(n60core_measure_predict_test tests/test_measure_predict.cpp)
target_link_libraries(n60core_measure_predict_test PRIVATE n60core)
add_test(NAME n60core_measure_predict COMMAND n60core_measure_predict_test)

# E11 S4: waterfall (CSD) and spectrogram.
add_executable(n60core_measure_waterfall_test tests/test_measure_waterfall.cpp)
target_link_libraries(n60core_measure_waterfall_test PRIVATE n60core)
add_test(NAME n60core_measure_waterfall COMMAND n60core_measure_waterfall_test)

# E11 S7: generator stage (ABI v14).
add_executable(n60core_generator_test tests/test_generator.cpp)
target_include_directories(n60core_generator_test PRIVATE src)
target_link_libraries(n60core_generator_test PRIVATE n60core)
add_test(NAME n60core_generator COMMAND n60core_generator_test)

# E11 S8: input monitor ring, SPL meter and RTA.
add_executable(n60core_measure_monitor_test tests/test_measure_monitor.cpp)
target_link_libraries(n60core_measure_monitor_test PRIVATE n60core Threads::Threads)
add_test(NAME n60core_measure_monitor COMMAND n60core_measure_monitor_test)

# E10 S1: room-correction design core (n60/correct.h): FDW, minimum phase, mixed-phase synthesis, pre-ringing audit.
add_executable(n60core_correct_test tests/test_correct.cpp)
target_include_directories(n60core_correct_test PRIVATE src)
target_link_libraries(n60core_correct_test PRIVATE n60core)
add_test(NAME n60core_correct COMMAND n60core_correct_test)

# E10 S3: two-band ROOM_FIR stage (ABI v15).
add_executable(n60core_room_fir_test tests/test_room_fir.cpp)
target_link_libraries(n60core_room_fir_test PRIVATE n60core)
add_test(NAME n60core_room_fir COMMAND n60core_room_fir_test)

# E10 S6: joint bass optimiser (n60/correct.h section 5).
add_executable(n60core_correct_bass_test tests/test_correct_bass.cpp)
target_include_directories(n60core_correct_bass_test PRIVATE src)
target_link_libraries(n60core_correct_bass_test PRIVATE n60core)
add_test(NAME n60core_correct_bass COMMAND n60core_correct_bass_test)

# E8 S1: crossover filter library (n60/xover.h): Butterworth, Bessel, Linkwitz-Riley, Linkwitz transform.
add_executable(n60core_xover_test tests/test_xover.cpp)
target_link_libraries(n60core_xover_test PRIVATE n60core)
add_test(NAME n60core_xover COMMAND n60core_xover_test)

# E8 S2: ROUTE and XOVER graph stages (ABI v17).
add_executable(n60core_route_test tests/test_route.cpp)
target_include_directories(n60core_route_test PRIVATE src)
target_link_libraries(n60core_route_test PRIVATE n60core)
add_test(NAME n60core_route COMMAND n60core_route_test)

# E8 S8: near-field driver linearisation (n60_xover_linearise_*).
add_executable(n60core_xover_linearise_test tests/test_xover_linearise.cpp)
target_link_libraries(n60core_xover_linearise_test PRIVATE n60core)
add_test(NAME n60core_xover_linearise COMMAND n60core_xover_linearise_test)

# E8 S7: linear-phase FIR crossovers (n60_xover_fir_*, N60_STAGE_DRIVER_FIR).
add_executable(n60core_xover_fir_test tests/test_xover_fir.cpp)
target_link_libraries(n60core_xover_fir_test PRIVATE n60core)
add_test(NAME n60core_xover_fir COMMAND n60core_xover_fir_test)

# E9 S4: designer single-band caps (n60/correct.h ABI v4, n60/xover.h ABI v5).
add_executable(n60core_designer_caps_test tests/test_designer_caps.cpp)
target_link_libraries(n60core_designer_caps_test PRIVATE n60core)
add_test(NAME n60core_designer_caps COMMAND n60core_designer_caps_test)

# E8 A6a: multi-sub delay, gain and polarity search (n60/correct.h section 6).
add_executable(n60core_correct_multisub_test tests/test_correct_multisub.cpp)
target_link_libraries(n60core_correct_multisub_test PRIVATE n60core)
add_test(NAME n60core_correct_multisub COMMAND n60core_correct_multisub_test)

add_executable(n60core_anc_actuators_test tests/test_anc_actuators.cpp)
target_link_libraries(n60core_anc_actuators_test PRIVATE n60core)
add_test(NAME n60core_anc_actuators COMMAND n60core_anc_actuators_test)

# E27 S2c: analyser taps (ABI v21).
add_executable(n60core_analyser_tap_test tests/test_analyser_tap.cpp)
target_link_libraries(n60core_analyser_tap_test PRIVATE n60core)
add_test(NAME n60core_analyser_tap COMMAND n60core_analyser_tap_test)

# E6 S12a: cleanup stage (DC, infrasonic, mains notch, hum detector).
add_executable(n60core_cleanup_test tests/test_cleanup.cpp)
target_link_libraries(n60core_cleanup_test PRIVATE n60core)
add_test(NAME n60core_cleanup COMMAND n60core_cleanup_test)

# E6 S12b: image (stereo mode, widener) and de-ess (de-harsh, de-esser) stages (ABI v23).
add_executable(n60core_image_test tests/test_image.cpp)
target_link_libraries(n60core_image_test PRIVATE n60core)
add_test(NAME n60core_image COMMAND n60core_image_test)

# E6 S12f2: state carry across a swap, non-finite reset, corner precision.
add_executable(n60core_state_carry_test tests/test_state_carry.cpp)
target_link_libraries(n60core_state_carry_test PRIVATE n60core)
add_test(NAME n60core_state_carry COMMAND n60core_state_carry_test)

# E6 S12h: loudness and multiband carry, carry bytes charged to the budget, deferred-swap path.
add_executable(n60core_stage_carry2_test tests/test_stage_carry2.cpp)
target_include_directories(n60core_stage_carry2_test PRIVATE src)
target_link_libraries(n60core_stage_carry2_test PRIVATE n60core)
add_test(NAME n60core_stage_carry2 COMMAND n60core_stage_carry2_test)

# E6 S12h (G36): float image and de-ess stages against a double reference at 80 Hz and a 1000 ms release.
add_executable(n60core_image_precision_test tests/test_image_precision.cpp)
target_include_directories(n60core_image_precision_test PRIVATE src)
target_link_libraries(n60core_image_precision_test PRIVATE n60core)
add_test(NAME n60core_image_precision COMMAND n60core_image_precision_test)

# E6 S12c: loudness (match, contour, dialogue leveler) stage (ABI v24).
add_executable(n60core_loudness_test tests/test_loudness.cpp)
target_link_libraries(n60core_loudness_test PRIVATE n60core)
add_test(NAME n60core_loudness COMMAND n60core_loudness_test)

# E6 S12e: PEQ kernel types 8-10 and wide chains (ABI v26).
add_executable(n60core_peq_wide_test tests/test_peq_wide.cpp)
target_link_libraries(n60core_peq_wide_test PRIVATE n60core)
add_test(NAME n60core_peq_wide COMMAND n60core_peq_wide_test)

# E6 S12g2: lane delay ahead of bass management (ABI v28).
add_executable(n60core_lane_delay_test tests/test_lane_delay.cpp)
target_link_libraries(n60core_lane_delay_test PRIVATE n60core)
add_test(NAME n60core_lane_delay COMMAND n60core_lane_delay_test)

add_executable(n60core_delta_audition_test tests/test_delta_audition.cpp)
target_link_libraries(n60core_delta_audition_test PRIVATE n60core)
add_test(NAME n60core_delta_audition COMMAND n60core_delta_audition_test)

# E6 S12d: multiband compressor stage (ABI v25).
add_executable(n60core_multiband_test tests/test_multiband.cpp)
target_link_libraries(n60core_multiband_test PRIVATE n60core)
add_test(NAME n60core_multiband COMMAND n60core_multiband_test)

add_executable(n60core_stereo_bass_test tests/test_stereo_bass.cpp)
target_link_libraries(n60core_stereo_bass_test PRIVATE n60core)
add_test(NAME n60core_stereo_bass COMMAND n60core_stereo_bass_test)

# E9 S1: non-uniform partitioned FIR engine, tested directly (internal header, so the src include path).
add_executable(n60core_conv_test tests/test_conv.cpp)
target_link_libraries(n60core_conv_test PRIVATE n60core)
target_include_directories(n60core_conv_test PRIVATE src)
add_test(NAME n60core_conv COMMAND n60core_conv_test)

add_executable(n60core_conv_rebuild_test tests/test_conv_rebuild.cpp)
target_link_libraries(n60core_conv_rebuild_test PRIVATE n60core)
target_include_directories(n60core_conv_rebuild_test PRIVATE src)
add_test(NAME n60core_conv_rebuild COMMAND n60core_conv_rebuild_test)

# E19 S2: MIMO room treatment design core (n60/mimo.h).
add_executable(n60core_mimo_test tests/test_mimo.cpp)
target_link_libraries(n60core_mimo_test PRIVATE n60core)
add_test(NAME n60core_mimo COMMAND n60core_mimo_test)
# E19 S3: realisation check (solved response against the taps, edge energy, overshoot).
add_executable(n60core_mimo_realise_test tests/test_mimo_realise.cpp)
target_link_libraries(n60core_mimo_realise_test PRIVATE n60core)
add_test(NAME n60core_mimo_realise COMMAND n60core_mimo_realise_test)

# E9 S6: per-output headroom maths (n60/headroom.h).
add_executable(n60core_headroom_test tests/test_headroom.cpp)
target_link_libraries(n60core_headroom_test PRIVATE n60core)
add_test(NAME n60core_headroom COMMAND n60core_headroom_test)
