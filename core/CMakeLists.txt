# libn60core: portable engine core (E6 S2, E21). No Apple framework, no third-party code.
cmake_minimum_required(VERSION 3.20)
project(n60core LANGUAGES C CXX)

# E21 S1: core/sources.cmake is the one source list (ci/core_sources.sh reads it; the Xcode libn60core group is checked
# against it by the app-target XCTest N60CoreABITests, which calls one entry point per translation unit).
include(sources.cmake)
# E21 S3: N60_FFT_BACKEND picks the FFT implementation behind the one contract (src/fft.hpp, src/fft_backend.hpp):
# "vdsp" (core/platform/apple/fft_vdsp.cpp, Apple only, the default there) or "portable" (the in-house radix-2, the only
# choice elsewhere). Engine code never reads a flag; the choice is this build option.
if(APPLE)
  set(N60_FFT_BACKEND_DEFAULT vdsp)
else()
  set(N60_FFT_BACKEND_DEFAULT portable)
endif()
set(N60_FFT_BACKEND ${N60_FFT_BACKEND_DEFAULT} CACHE STRING "FFT backend: vdsp (Apple) or portable")
set_property(CACHE N60_FFT_BACKEND PROPERTY STRINGS vdsp portable)
if(NOT N60_FFT_BACKEND STREQUAL "vdsp" AND NOT N60_FFT_BACKEND STREQUAL "portable")
  message(FATAL_ERROR "N60_FFT_BACKEND must be vdsp or portable")
endif()
if(N60_FFT_BACKEND STREQUAL "vdsp" AND NOT APPLE)
  message(FATAL_ERROR "N60_FFT_BACKEND=vdsp needs an Apple platform")
endif()
set(N60_FFT_VDSP OFF)
if(N60_FFT_BACKEND STREQUAL "vdsp")
  set(N60_FFT_VDSP ON)
endif()
add_library(n60core STATIC ${N60_CORE_SOURCES} ${N60_CORE_C_SOURCES})
if(N60_FFT_VDSP)
  target_sources(n60core PRIVATE platform/apple/fft_vdsp.cpp)
  # PUBLIC so a test that includes src/fft_backend.hpp sees the vdsp declarations the library defines.
  target_compile_definitions(n60core PUBLIC N60_FFT_VDSP=1)
  target_link_libraries(n60core PUBLIC "-framework Accelerate")
endif()
target_compile_features(n60core PUBLIC cxx_std_20)
target_include_directories(n60core PUBLIC include)
target_include_directories(n60core PRIVATE src)
# E21 S1: one flag set per toolchain family. clang and gcc style on Linux and macOS; clang-cl (MSVC command line) on
# Windows, where /W4 is -Wall -Wextra, /WX is -Werror, /EHs-c- turns exceptions off and /GR- turns RTTI off.
if(MSVC)
  target_compile_options(n60core PRIVATE /W4 /WX /EHs-c- /GR- -Wno-unknown-warning-option -Werror=function-effects)
  target_compile_definitions(n60core PRIVATE _CRT_SECURE_NO_WARNINGS NOMINMAX _USE_MATH_DEFINES)
  # M_PI and friends come from <math.h> only with _USE_MATH_DEFINES on MSVC; the tests use them too.
  add_compile_definitions(_USE_MATH_DEFINES)
  set(N60_M "")
else()
  target_compile_options(n60core PRIVATE -Wall -Wextra -Werror -Wno-unknown-warning-option -Werror=function-effects -fno-exceptions -fno-rtti)
  set(N60_M m)
endif()

# E20 S10 part 6 (G17, owner decision 13 Nov 2026): x86-64 builds default to FMA3. -mfma makes simd::fma one fused operation
# (the narrowest flag that gives it), -mavx2 allows 256-bit moves; pre-Haswell x86 is not supported and every Intel Mac that can
# run macOS 26 has FMA3. The fused result is not bit-identical to a non-FMA x86 build (arm64 is fused too, so it matches arm64
# rounding). Pass -DN60_X86_FMA=OFF to build the SSE2 baseline (simd::fma then falls back to libm per element).
option(N60_X86_FMA "Build the engine core with FMA3 on x86-64" ON)
if(N60_X86_FMA AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
  target_compile_options(n60core PRIVATE -mfma -mavx2)
endif()
# E21 S1: the tests' scalar references must round like the engine. The engine is built with FMA (above); a reference compiled
# without it differs in the last bit on x86 (test_stereo_bass "bit for bit"), so every test target gets the same flags.
if(N60_X86_FMA AND CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64")
  add_compile_options(-mfma -mavx2)
endif()

enable_testing()
# E21 S3: with the vdsp backend as the default, a second copy of the library (n60core_portable) keeps the in-house FFT
# tested on macOS: the FFT contract, test_conv, test_measure_fft and the graph parity suite also run against it, and
# test_fft_backend compares the two backends in one process.
if(N60_FFT_VDSP)
  add_library(n60core_portable STATIC ${N60_CORE_SOURCES} ${N60_CORE_C_SOURCES})
  target_compile_features(n60core_portable PUBLIC cxx_std_20)
  target_include_directories(n60core_portable PUBLIC include)
  target_include_directories(n60core_portable PRIVATE src)
  get_target_property(N60_CORE_OPTS n60core COMPILE_OPTIONS)
  get_target_property(N60_CORE_DEFS n60core COMPILE_DEFINITIONS)
  if(N60_CORE_OPTS)
    target_compile_options(n60core_portable PRIVATE ${N60_CORE_OPTS})
  endif()
  if(N60_CORE_DEFS)
    list(REMOVE_ITEM N60_CORE_DEFS N60_FFT_VDSP=1)
    if(N60_CORE_DEFS)
      target_compile_definitions(n60core_portable PRIVATE ${N60_CORE_DEFS})
    endif()
  endif()
endif()
# E21 S1: n60/n60.h as C and n60_core_abi.
add_executable(n60core_core_abi_test tests/test_core_abi.c)
set_target_properties(n60core_core_abi_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_core_abi_test PRIVATE n60core)
add_test(NAME n60core_core_abi COMMAND n60core_core_abi_test)
add_executable(n60core_graph_test tests/test_graph.c)
set_target_properties(n60core_graph_test PROPERTIES C_STANDARD 11)
target_link_libraries(n60core_graph_test PRIVATE n60core ${N60_M})
set_target_properties(n60core_graph_test PROPERTIES LINKER_LANGUAGE CXX)
add_test(NAME n60core_graph COMMAND n60core_graph_test)

find_package(Threads REQUIRED)
# test_stages.c and test_parallel.cpp use POSIX threads, sched_setaffinity and unistd.h: not built on Windows (E21 gap G3).
if(NOT WIN32)
add_executable(n60core_stages_test tests/test_stages.c)
set_target_properties(n60core_stages_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_stages_test PRIVATE n60core ${N60_M} Threads::Threads)
add_test(NAME n60core_stages COMMAND n60core_stages_test)
endif()

add_executable(n60core_alloc_test tests/test_alloc.cpp)
target_link_libraries(n60core_alloc_test PRIVATE n60core)
add_test(NAME n60core_alloc COMMAND n60core_alloc_test)

add_executable(n60core_precision_audit_test tests/test_precision_audit.cpp)
target_link_libraries(n60core_precision_audit_test PRIVATE n60core)
add_test(NAME n60core_precision_audit COMMAND n60core_precision_audit_test)

add_executable(n60core_fpenv_test tests/test_fpenv.cpp)
target_link_libraries(n60core_fpenv_test PRIVATE n60core)
target_include_directories(n60core_fpenv_test PRIVATE src)
add_test(NAME n60core_fpenv COMMAND n60core_fpenv_test)
add_executable(n60core_protection_halfband_test tests/test_protection_halfband.cpp)
target_link_libraries(n60core_protection_halfband_test PRIVATE n60core)
add_test(NAME n60core_protection_halfband COMMAND n60core_protection_halfband_test)
add_executable(n60core_binaural_tail_test tests/test_binaural_tail.cpp)
target_link_libraries(n60core_binaural_tail_test PRIVATE n60core)
add_test(NAME n60core_binaural_tail COMMAND n60core_binaural_tail_test)
add_executable(n60core_binaural_interp_test tests/test_binaural_interp.cpp)
target_link_libraries(n60core_binaural_interp_test PRIVATE n60core)
add_test(NAME n60core_binaural_interp COMMAND n60core_binaural_interp_test)
if(NOT WIN32)
add_executable(n60core_parallel_test tests/test_parallel.cpp)
target_link_libraries(n60core_parallel_test PRIVATE n60core Threads::Threads)
add_test(NAME n60core_parallel COMMAND n60core_parallel_test)
# E20 S6b (G26): the same test pinned to two cores, three workers plus the render thread contending for them.
add_test(NAME n60core_parallel_two_cores COMMAND n60core_parallel_test)
set_tests_properties(n60core_parallel_two_cores PROPERTIES ENVIRONMENT "N60_PARALLEL_TEST_CPUS=2;N60_PARALLEL_TEST_LITE=1")
endif()

add_executable(n60core_protection_parallel_test tests/test_protection_parallel.cpp)
target_link_libraries(n60core_protection_parallel_test PRIVATE n60core Threads::Threads)
add_test(NAME n60core_protection_parallel COMMAND n60core_protection_parallel_test)

add_executable(n60core_simd_parity_test tests/test_simd_parity.cpp)
target_link_libraries(n60core_simd_parity_test PRIVATE n60core)
target_include_directories(n60core_simd_parity_test PRIVATE src)
add_test(NAME n60core_simd_parity COMMAND n60core_simd_parity_test check)

add_executable(n60core_fft_conv_test tests/test_fft_conv.cpp)
target_link_libraries(n60core_fft_conv_test PRIVATE n60core)
target_include_directories(n60core_fft_conv_test PRIVATE src)
add_test(NAME n60core_fft_conv COMMAND n60core_fft_conv_test check)

add_executable(n60core_dsp_test tests/test_dsp.c)
set_target_properties(n60core_dsp_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_dsp_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_dsp COMMAND n60core_dsp_test)

add_executable(n60core_system_test tests/test_system.c)
set_target_properties(n60core_system_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_system_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_system COMMAND n60core_system_test)

add_executable(n60core_ambient_sections_test tests/test_ambient_sections.c)
set_target_properties(n60core_ambient_sections_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_ambient_sections_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_ambient_sections COMMAND n60core_ambient_sections_test)
add_executable(n60core_ambient_carry_test tests/test_ambient_carry.c)
set_target_properties(n60core_ambient_carry_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_ambient_carry_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_ambient_carry COMMAND n60core_ambient_carry_test)

add_executable(n60core_external_test tests/test_external.c)
set_target_properties(n60core_external_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_external_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_external COMMAND n60core_external_test)

add_executable(n60core_rebuild_test tests/test_rebuild.c)
set_target_properties(n60core_rebuild_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_rebuild_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_rebuild COMMAND n60core_rebuild_test)

add_executable(n60core_denoiser_carry_test tests/test_denoiser_carry.c)
set_target_properties(n60core_denoiser_carry_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_denoiser_carry_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_denoiser_carry COMMAND n60core_denoiser_carry_test)

add_executable(n60core_layout_test tests/test_layout.c)
set_target_properties(n60core_layout_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_layout_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_layout COMMAND n60core_layout_test)

add_executable(n60core_multisub_test tests/test_multisub.c)
set_target_properties(n60core_multisub_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_multisub_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_multisub COMMAND n60core_multisub_test)

add_executable(n60core_readbacks_test tests/test_readbacks.c)
set_target_properties(n60core_readbacks_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_readbacks_test PRIVATE n60core ${N60_M})
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

# E21 S5: room response analysis and program spectrum.
add_executable(n60core_measure_room_analysis_test tests/test_measure_room_analysis.cpp)
target_link_libraries(n60core_measure_room_analysis_test PRIVATE n60core)
add_test(NAME n60core_measure_room_analysis COMMAND n60core_measure_room_analysis_test)

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

# E8 housekeeping: the engine crossover stages summed coherently at all eight rates (issue #121 evidence).
add_executable(n60core_xover_highrate_engine_test tests/test_xover_highrate_engine.cpp)
target_link_libraries(n60core_xover_highrate_engine_test PRIVATE n60core)
add_test(NAME n60core_xover_highrate_engine COMMAND n60core_xover_highrate_engine_test)

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

# E21 S6: room-correction FIR design maths (n60/correct.h section 7).
add_executable(n60core_room_design_test tests/test_room_design.cpp)
target_link_libraries(n60core_room_design_test PRIVATE n60core)
add_test(NAME n60core_room_design COMMAND n60core_room_design_test)

# E21 S7a: multichannel calibration alignment maths (n60/correct.h section 8).
add_executable(n60core_calibration_align_test tests/test_calibration_align.cpp)
target_link_libraries(n60core_calibration_align_test PRIVATE n60core)
add_test(NAME n60core_calibration_align COMMAND n60core_calibration_align_test)

# E21 S7b: multi-sub optimiser (n60/correct.h section 9).
add_executable(n60core_multisub_optimise_test tests/test_multisub_optimise.cpp)
target_link_libraries(n60core_multisub_optimise_test PRIVATE n60core)
add_test(NAME n60core_multisub_optimise COMMAND n60core_multisub_optimise_test)

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

# E28 S7a: compressor mix, link amount, detector, lookahead (ABI v33).
add_executable(n60core_comp_extras_test tests/test_comp_extras.cpp)
target_link_libraries(n60core_comp_extras_test PRIVATE n60core)
add_test(NAME n60core_comp_extras COMMAND n60core_comp_extras_test)
add_executable(n60core_exp_extras_test tests/test_exp_extras.cpp)
target_link_libraries(n60core_exp_extras_test PRIVATE n60core)
add_test(NAME n60core_exp_extras COMMAND n60core_exp_extras_test)

# E33 S5a: expander lookahead (ABI v41).
add_executable(n60core_exp_lookahead_test tests/test_exp_lookahead.cpp)
target_link_libraries(n60core_exp_lookahead_test PRIVATE n60core)
add_test(NAME n60core_exp_lookahead COMMAND n60core_exp_lookahead_test)

# E28 S7c: multiband bypass, solo, listen, detector and lookahead (ABI v37).
add_executable(n60core_mb_extras_test tests/test_mb_extras.cpp)
target_link_libraries(n60core_mb_extras_test PRIVATE n60core)
add_test(NAME n60core_mb_extras COMMAND n60core_mb_extras_test)

# E33 S5b: multiband with 2 to 5 bands (ABI v42).
add_executable(n60core_mb_nband_test tests/test_mb_nband.cpp)
target_link_libraries(n60core_mb_nband_test PRIVATE n60core)
target_include_directories(n60core_mb_nband_test PRIVATE tests)
add_test(NAME n60core_mb_nband COMMAND n60core_mb_nband_test)

# E28 G42: multiband band-pass tree (split mode, parameter 43).
add_executable(n60core_mb_split_test tests/test_mb_split.cpp)
target_link_libraries(n60core_mb_split_test PRIVATE n60core)
add_test(NAME n60core_mb_split COMMAND n60core_mb_split_test)

# E32 S4: gain-reduction telemetry without make-up, crossover edit crossfade, limiter lookahead toggle.
add_executable(n60core_e32_dynamics_core_test tests/test_e32_dynamics_core.cpp)
target_link_libraries(n60core_e32_dynamics_core_test PRIVATE n60core)
add_test(NAME n60core_e32_dynamics_core COMMAND n60core_e32_dynamics_core_test)
add_executable(n60core_e32_dynamics_sound_test tests/test_e32_dynamics_sound.cpp)
target_link_libraries(n60core_e32_dynamics_sound_test PRIVATE n60core)
add_test(NAME n60core_e32_dynamics_sound COMMAND n60core_e32_dynamics_sound_test)

add_executable(n60core_limiter_auto_release_test tests/test_limiter_auto_release.cpp)
target_link_libraries(n60core_limiter_auto_release_test PRIVATE n60core)
add_test(NAME n60core_limiter_auto_release COMMAND n60core_limiter_auto_release_test)

# E33 S21: fit EQ bands to a curve (n60/eqfit.h).
add_executable(n60core_eqfit_test tests/test_eqfit.cpp)
target_link_libraries(n60core_eqfit_test PRIVATE n60core)
add_test(NAME n60core_eqfit COMMAND n60core_eqfit_test)

# E33 S10: input overs at METER_IN (ABI v44).
add_executable(n60core_input_overs_test tests/test_input_overs.cpp)
target_link_libraries(n60core_input_overs_test PRIVATE n60core)
add_test(NAME n60core_input_overs COMMAND n60core_input_overs_test)

# E33 S13: LFE out of the compressor and expander detector, centre-aware dialogue leveler (ABI v45).
add_executable(n60core_surround_detector_test tests/test_surround_detector.cpp)
target_link_libraries(n60core_surround_detector_test PRIVATE n60core)
add_test(NAME n60core_surround_detector COMMAND n60core_surround_detector_test)

# E6 S12c: loudness (match, contour, dialogue leveler) stage (ABI v24).
add_executable(n60core_loudness_test tests/test_loudness.cpp)
target_link_libraries(n60core_loudness_test PRIVATE n60core)
add_test(NAME n60core_loudness COMMAND n60core_loudness_test)

# E6 S12e: PEQ kernel types 8-10 and wide chains (ABI v26).
add_executable(n60core_peq_wide_test tests/test_peq_wide.cpp)
target_link_libraries(n60core_peq_wide_test PRIVATE n60core)
add_test(NAME n60core_peq_wide COMMAND n60core_peq_wide_test)

# E33 S26: matched EQ filters (graph ABI v47).
add_executable(n60core_eq_matched_test tests/test_eq_matched.cpp)
target_link_libraries(n60core_eq_matched_test PRIVATE n60core)
add_test(NAME n60core_eq_matched COMMAND n60core_eq_matched_test)

# E33 S27: linear-phase EQ design in the core, four lengths at the eight rates.
add_executable(n60core_eq_linear_phase_test tests/test_eq_linear_phase.cpp)
target_link_libraries(n60core_eq_linear_phase_test PRIVATE n60core)
add_test(NAME n60core_eq_linear_phase COMMAND n60core_eq_linear_phase_test)

# E33 S20: per-speaker-group EQ lists as per-lane PEQ stages.
add_executable(n60core_eq_groups_test tests/test_eq_groups.cpp)
target_link_libraries(n60core_eq_groups_test PRIVATE n60core)
add_test(NAME n60core_eq_groups COMMAND n60core_eq_groups_test)

# E6 S12g2: lane delay ahead of bass management (ABI v28).
add_executable(n60core_lane_delay_test tests/test_lane_delay.cpp)
target_link_libraries(n60core_lane_delay_test PRIVATE n60core)
add_test(NAME n60core_lane_delay COMMAND n60core_lane_delay_test)

# E7 S1: capacities in time (20 ms delay, 500 ms split fractional delay, 20 ms look-ahead at 4x) at the eight rates.
add_executable(n60core_rate_capacity_test tests/test_rate_capacity.cpp)
target_link_libraries(n60core_rate_capacity_test PRIVATE n60core)
add_test(NAME n60core_rate_capacity COMMAND n60core_rate_capacity_test)

# E7 S2: control-plane asset resampler at all 64 pairs of the eight standard rates.
add_executable(n60core_resample_test tests/test_resample.cpp)
target_link_libraries(n60core_resample_test PRIVATE n60core)
add_test(NAME n60core_resample COMMAND n60core_resample_test)

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

# E19 S4: MIMO treatment graph stage (ABI v33).
add_executable(n60core_mimo_stage_test tests/test_mimo_stage.cpp)
target_include_directories(n60core_mimo_stage_test PRIVATE src)
target_link_libraries(n60core_mimo_stage_test PRIVATE n60core)
add_test(NAME n60core_mimo_stage COMMAND n60core_mimo_stage_test)

# E19 S5: MIMO safety (headroom term, budget, excursion cap).
add_executable(n60core_mimo_safety_test tests/test_mimo_safety.cpp)
target_link_libraries(n60core_mimo_safety_test PRIVATE n60core)
add_test(NAME n60core_mimo_safety COMMAND n60core_mimo_safety_test)

# E21 S8: in-house dense solvers (src/linalg/linalg.hpp, header only) and the designer at 32 sources.
add_executable(n60core_linalg_test tests/test_linalg.cpp)
target_include_directories(n60core_linalg_test PRIVATE src)
add_test(NAME n60core_linalg COMMAND n60core_linalg_test)

add_executable(n60core_mimo_n32_test tests/test_mimo_n32.cpp)
target_link_libraries(n60core_mimo_n32_test PRIVATE n60core)
add_test(NAME n60core_mimo_n32 COMMAND n60core_mimo_n32_test)

# E21 S0: the E4 ANC harnesses that exercise the moved sources (they live in ci/ with their shared plant helpers).
# The harness uses C99 _Complex (double complex), which MSVC-style C does not provide: not built on clang-cl (E21 gap G3).
if(NOT MSVC)
add_executable(n60core_e4_fxlms_test ../ci/harness_e4_fxlms.c)
set_target_properties(n60core_e4_fxlms_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_include_directories(n60core_e4_fxlms_test PRIVATE ../ci)
target_link_libraries(n60core_e4_fxlms_test PRIVATE n60core ${N60_M})
add_test(NAME n60core_e4_fxlms COMMAND n60core_e4_fxlms_test)
endif()

add_executable(n60core_e4_remote_tonal_test ../ci/harness_e4_remote_tonal.cpp)
target_include_directories(n60core_e4_remote_tonal_test PRIVATE ../ci)
target_link_libraries(n60core_e4_remote_tonal_test PRIVATE n60core)
add_test(NAME n60core_e4_remote_tonal COMMAND n60core_e4_remote_tonal_test)

# E21 S9a: speaker maths (n60/speaker.h).
add_executable(n60core_speaker_test tests/test_speaker.cpp)
target_link_libraries(n60core_speaker_test PRIVATE n60core)
add_test(NAME n60core_speaker COMMAND n60core_speaker_test)

# E21 S9b: crossover feasibility, classifier, early window and preview scoring (n60/speaker.h v2).
add_executable(n60core_speaker_s9b_test tests/test_speaker_s9b.cpp)
target_link_libraries(n60core_speaker_s9b_test PRIVATE n60core)
add_test(NAME n60core_speaker_s9b COMMAND n60core_speaker_s9b_test)

# E21 S10a: ANC design maths (n60/anc_design.h): virtual seat designer, causal FIR compiler, HAL clock, upstream survey.
add_executable(n60core_anc_design_test tests/test_anc_design.cpp)
target_link_libraries(n60core_anc_design_test PRIVATE n60core)
add_test(NAME n60core_anc_design COMMAND n60core_anc_design_test)

# E36 S3: virtual driver programme ring and clock steering (n60/vd_ring.h).
add_executable(n60core_vd_ring_test tests/test_vd_ring.cpp)
target_link_libraries(n60core_vd_ring_test PRIVATE n60core)
add_test(NAME n60core_vd_ring COMMAND n60core_vd_ring_test)

# E21 S10b: passive ambient field analysis (n60/anc_design.h v2).
add_executable(n60core_ambient_field_test tests/test_ambient_field.cpp)
target_link_libraries(n60core_ambient_field_test PRIVATE n60core)
add_test(NAME n60core_ambient_field COMMAND n60core_ambient_field_test)

# E21 S3: FFT backends. test_fft_backend compares vDSP with the in-house transforms and checks vDSP allocates nothing in
# forward and inverse; the portable-library copies keep the old FFT paths under test on Apple.
add_executable(n60core_parity_suite_test tests/test_parity_suite.c)
set_target_properties(n60core_parity_suite_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_parity_suite_test PRIVATE n60core ${N60_M})
if(N60_FFT_VDSP)
  # Goldens are pinned to the in-house FFT; the vdsp build still runs the equivalence and acoustic cases.
  add_test(NAME n60core_parity_suite COMMAND n60core_parity_suite_test)
  set_tests_properties(n60core_parity_suite PROPERTIES ENVIRONMENT "N60_PARITY_NO_GOLDENS=1")
  add_executable(n60core_parity_suite_portable_test tests/test_parity_suite.c)
  set_target_properties(n60core_parity_suite_portable_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
  target_link_libraries(n60core_parity_suite_portable_test PRIVATE n60core_portable ${N60_M})
  add_test(NAME n60core_parity_suite_portable COMMAND n60core_parity_suite_portable_test)

  add_executable(n60core_fft_backend_test tests/test_fft_backend.cpp)
  target_link_libraries(n60core_fft_backend_test PRIVATE n60core)
  target_include_directories(n60core_fft_backend_test PRIVATE src)
  add_test(NAME n60core_fft_backend COMMAND n60core_fft_backend_test)

  # Engine outputs (program FIR, binaural, measurement) from both libraries agree within -120 dBFS peak at the eight rates.
  add_executable(n60core_fft_outputs_vdsp_test tests/test_fft_outputs.cpp)
  target_link_libraries(n60core_fft_outputs_vdsp_test PRIVATE n60core)
  add_executable(n60core_fft_outputs_portable_test tests/test_fft_outputs.cpp)
  target_link_libraries(n60core_fft_outputs_portable_test PRIVATE n60core_portable)
  add_test(NAME n60core_fft_outputs_write_vdsp COMMAND n60core_fft_outputs_vdsp_test write ${CMAKE_BINARY_DIR}/fft_outputs_vdsp.bin)
  add_test(NAME n60core_fft_outputs_write_portable COMMAND n60core_fft_outputs_portable_test write ${CMAKE_BINARY_DIR}/fft_outputs_portable.bin)
  add_test(NAME n60core_fft_outputs_compare COMMAND n60core_fft_outputs_vdsp_test compare
           ${CMAKE_BINARY_DIR}/fft_outputs_vdsp.bin ${CMAKE_BINARY_DIR}/fft_outputs_portable.bin)
  set_tests_properties(n60core_fft_outputs_write_vdsp n60core_fft_outputs_write_portable PROPERTIES FIXTURES_SETUP n60_fft_outputs)
  set_tests_properties(n60core_fft_outputs_compare PROPERTIES FIXTURES_REQUIRED n60_fft_outputs)

  foreach(t fft_conv measure_fft conv)
    set(src tests/test_${t}.cpp)
    add_executable(n60core_${t}_portable_test ${src})
    target_link_libraries(n60core_${t}_portable_test PRIVATE n60core_portable)
    target_include_directories(n60core_${t}_portable_test PRIVATE src)
  endforeach()
  add_test(NAME n60core_fft_conv_portable COMMAND n60core_fft_conv_portable_test check)
  add_test(NAME n60core_measure_fft_portable COMMAND n60core_measure_fft_portable_test)
  add_test(NAME n60core_conv_portable COMMAND n60core_conv_portable_test)
else()
  add_test(NAME n60core_parity_suite COMMAND n60core_parity_suite_test)
  if(WIN32)
    # clang-cl (MSVC UCRT libm) rounds one binaural golden (layout 2, 48 kHz) across a 0.05 dB hash step that Linux and
    # macOS agree on (nightly 23 Nov 2026). The equivalence, live-edit and acoustic cases still run; goldens on Windows are E21 G32.
    set_tests_properties(n60core_parity_suite PROPERTIES ENVIRONMENT "N60_PARITY_NO_GOLDENS=1")
  endif()
endif()

# E21 S4: the realtime ANC sources (src/anc) and the E4 harnesses and reference-lab probes that exercise them, built against
# libn60core so they run wherever the core builds (Linux CI, macOS; the C99 _Complex users are skipped on clang-cl, gap G3).
add_executable(n60core_anc_lane_feed_test tests/test_anc_lane_feed.cpp)
target_link_libraries(n60core_anc_lane_feed_test PRIVATE n60core)
add_test(NAME n60core_anc_lane_feed COMMAND n60core_anc_lane_feed_test)

add_executable(n60core_e4_acoustic_twin_test ../ci/harness_e4_acoustic_twin.cpp)
target_include_directories(n60core_e4_acoustic_twin_test PRIVATE ../ci)
target_link_libraries(n60core_e4_acoustic_twin_test PRIVATE n60core)
add_test(NAME n60core_e4_acoustic_twin COMMAND n60core_e4_acoustic_twin_test)

if(NOT MSVC)
  foreach(h anc_guard ff_shadow ff_echo ff_live ff_live_echo ff_survey)
    add_executable(n60core_e4_${h}_test ../ci/harness_e4_${h}.c)
    set_target_properties(n60core_e4_${h}_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
    target_include_directories(n60core_e4_${h}_test PRIVATE ../ci)
    target_link_libraries(n60core_e4_${h}_test PRIVATE n60core ${N60_M})
    add_test(NAME n60core_e4_${h} COMMAND n60core_e4_${h}_test)
  endforeach()

  # The reference-lab cases: the C probe is built here, the Python reference (stdlib only) checks its numbers.
  find_package(Python3 COMPONENTS Interpreter)
  if(Python3_Interpreter_FOUND)
    foreach(p anc_guard ff_shadow ff_survey fxlms remote_tonal)
      add_executable(n60core_e4_${p}_probe ../ci/acoustic_reference_lab/e4_${p}_probe.c)
      set_target_properties(n60core_e4_${p}_probe PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
      target_include_directories(n60core_e4_${p}_probe PRIVATE ../ci)
      target_link_libraries(n60core_e4_${p}_probe PRIVATE n60core ${N60_M})
      add_test(NAME n60core_e4_${p}_reference
               COMMAND ${Python3_EXECUTABLE} -I ${CMAKE_CURRENT_SOURCE_DIR}/../ci/acoustic_reference_lab/e4_${p}_reference.py)
      set_tests_properties(n60core_e4_${p}_reference PROPERTIES ENVIRONMENT "N60_E4_PROBE=$<TARGET_FILE:n60core_e4_${p}_probe>")
    endforeach()
  endif()
endif()
