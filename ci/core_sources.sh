# Single list of libn60core sources (paths under core/src, without .cpp).
# Sourced by ci/run_harnesses.sh and .github/workflows/macos-full.yml so the
# lists cannot drift apart. Keep in step with core/CMakeLists.txt.
CORE_SOURCES=(
    graph snapshot fft stages_dsp conv/nufir stages_system stages_matrix stages_generator
    stages_cleanup stages_image stages_loudness stages_multiband stages_route stages_mimo fold layout
    measure/offline_fft measure/ess measure/deconvolve measure/reference_room measure/timing
    measure/distortion measure/decay measure/waterfall measure/monitor_ring measure/spl
    measure/rta correct/minphase correct/design correct/synth correct/bass
    correct/multisub_search xover/xover headroom/headroom mimo/design
)
