# libn60core: portable engine core (E6 S2, E21). No Apple framework, no third-party code.
cmake_minimum_required(VERSION 3.20)
project(n60core LANGUAGES C CXX)

add_library(n60core STATIC src/graph.cpp src/snapshot.cpp src/fft.cpp src/stages_dsp.cpp src/stages_system.cpp src/stages_matrix.cpp src/stages_generator.cpp src/stages_route.cpp src/layout.cpp
    src/measure/offline_fft.cpp src/measure/ess.cpp src/measure/deconvolve.cpp src/measure/reference_room.cpp src/measure/timing.cpp src/measure/distortion.cpp src/measure/decay.cpp src/measure/waterfall.cpp src/measure/monitor_ring.cpp src/measure/spl.cpp src/measure/rta.cpp
    src/correct/minphase.cpp src/correct/design.cpp src/correct/synth.cpp src/correct/bass.cpp src/correct/multisub_search.cpp
    src/xover/xover.cpp)
target_compile_features(n60core PUBLIC cxx_std_20)
target_include_directories(n60core PUBLIC include)
target_include_directories(n60core PRIVATE src)
target_compile_options(n60core PRIVATE -Wall -Wextra -Werror -fno-exceptions -fno-rtti)

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

add_executable(n60core_dsp_test tests/test_dsp.c)
set_target_properties(n60core_dsp_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_dsp_test PRIVATE n60core m)
add_test(NAME n60core_dsp COMMAND n60core_dsp_test)

add_executable(n60core_system_test tests/test_system.c)
set_target_properties(n60core_system_test PROPERTIES C_STANDARD 11 LINKER_LANGUAGE CXX)
target_link_libraries(n60core_system_test PRIVATE n60core m)
add_test(NAME n60core_system COMMAND n60core_system_test)

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

# E8 A6a: multi-sub delay, gain and polarity search (n60/correct.h section 6).
add_executable(n60core_correct_multisub_test tests/test_correct_multisub.cpp)
target_link_libraries(n60core_correct_multisub_test PRIVATE n60core)
add_test(NAME n60core_correct_multisub COMMAND n60core_correct_multisub_test)
