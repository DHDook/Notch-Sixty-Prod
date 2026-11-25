# FFT note (E21 G20): these CI scripts compile the portable radix-2 FFT (no N60_FFT_VDSP), so harness and benchmark numbers describe the same FFT on every OS. The vDSP backend is built and tested by CMake ctest (n60core_fft_backend, fft_outputs_*).
# Single list of libn60core sources (paths under core/src, without .cpp), read from core/sources.cmake (E21 S1), which
# is the one source of truth. Sourced by ci/run_harnesses.sh, ci/build_benchmarks.sh and the workflows.
# src/anc/* is left out of CORE_SOURCES: the harness and benchmark scripts link the ANC objects (and the tonal runtime C object)
# separately with the render kernel, so listing them here would define every symbol twice. CMake builds them in the library.
_n60_sources_cmake="$(dirname "${BASH_SOURCE[0]}")/../core/sources.cmake"
CORE_SOURCES=()
while IFS= read -r _f; do
    CORE_SOURCES+=("$_f")
done < <(sed -n '/^set(N60_CORE_SOURCES/,/)/p' "$_n60_sources_cmake" | grep -o 'src/[A-Za-z0-9_/]*\.cpp' | sed 's|^src/||; s|\.cpp$||' | grep -v '^anc/')
unset _n60_sources_cmake _f
