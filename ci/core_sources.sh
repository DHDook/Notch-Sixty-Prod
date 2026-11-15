# Single list of libn60core sources (paths under core/src, without .cpp), read from core/sources.cmake (E21 S1), which
# is the one source of truth. Sourced by ci/run_harnesses.sh, ci/build_benchmarks.sh and the workflows.
# core/src/anc/{fxlms,remote_tonal}.cpp are in N60_CORE_ANC_SOURCES, not here: they still use try/catch (exceptions on)
# and the ANC harnesses compile them directly. E21 S4 folds them in (gap G1).
_n60_sources_cmake="$(dirname "${BASH_SOURCE[0]}")/../core/sources.cmake"
CORE_SOURCES=()
while IFS= read -r _f; do
    CORE_SOURCES+=("$_f")
done < <(sed -n '/^set(N60_CORE_SOURCES/,/)/p' "$_n60_sources_cmake" | grep -o 'src/[A-Za-z0-9_/]*\.cpp' | sed 's|^src/||; s|\.cpp$||')
unset _n60_sources_cmake _f
