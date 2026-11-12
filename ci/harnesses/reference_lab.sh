# Sourced by ci/run_harnesses.sh (shares its helpers: selected, OUT, passed, failed).
# Acoustic reference lab and reviewer-noise checks (Python).

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
if selected e4_remote_tonal_reference; then
    echo "::group::e4_remote_tonal_reference"
    if python3 ci/acoustic_reference_lab/e4_remote_tonal_reference.py; then
        passed+=(e4_remote_tonal_reference)
    else
        failed+=(e4_remote_tonal_reference)
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
if selected e4_reviewer_noise; then
    echo "::group::e4_reviewer_noise"
    # E4 S31: the reviewer noise generator is byte-identical across runs.
    RN="$OUT/reviewer_noise"
    rm -rf "$RN"
    if python3 -I ci/generate_reviewer_noise.py "$RN/a" --seconds 1 \
        && python3 -I ci/generate_reviewer_noise.py "$RN/b" --seconds 1 \
        && [ "$(ls "$RN/a" | wc -l)" -eq 7 ] && diff -r "$RN/a" "$RN/b"; then
        passed+=(e4_reviewer_noise)
    else
        failed+=(e4_reviewer_noise)
    fi
    echo "::endgroup::"
fi
