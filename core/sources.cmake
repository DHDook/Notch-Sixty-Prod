# Single list of libn60core sources, relative to core/. E21 S1.
# Read by core/CMakeLists.txt and, through ci/core_sources.sh, by every CI script. Add a new file here only.
set(N60_CORE_SOURCES
    src/graph.cpp src/snapshot.cpp src/fft.cpp src/stages_dsp.cpp src/conv/nufir.cpp src/stages_system.cpp
    src/stages_matrix.cpp src/stages_generator.cpp src/stages_cleanup.cpp src/stages_image.cpp src/stages_loudness.cpp
    src/stages_multiband.cpp src/stages_route.cpp src/stages_mimo.cpp src/fold.cpp src/layout.cpp src/resample.cpp
    src/measure/offline_fft.cpp src/measure/ess.cpp src/measure/deconvolve.cpp src/measure/reference_room.cpp
    src/measure/timing.cpp src/measure/distortion.cpp src/measure/decay.cpp src/measure/waterfall.cpp
    src/measure/monitor_ring.cpp src/measure/spl.cpp src/measure/rta.cpp src/measure/predict.cpp src/measure/room_analysis.cpp src/mimo/design.cpp
    src/correct/minphase.cpp src/correct/design.cpp src/correct/synth.cpp src/correct/bass.cpp
    src/correct/multisub_search.cpp src/abi.cpp src/xover/xover.cpp src/headroom/headroom.cpp src/eqfit/eqfit.cpp)
# Built with exceptions on until E21 S4 (gap G1); ci/core_sources.sh leaves them out of CORE_SOURCES.
set(N60_CORE_ANC_SOURCES src/anc/fxlms.cpp src/anc/remote_tonal.cpp)
