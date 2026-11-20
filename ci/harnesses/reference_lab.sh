# Sourced by ci/run_harnesses.sh (shares its helpers: selected, OUT, passed, failed).
# Acoustic reference lab and reviewer-noise checks (Python).

# Acoustic reference lab: the E4 production-header probes checked against independent Python oracles at every
# standard rate from 44.1 to 384 kHz. (The PR117 lab's cases now run in `RateMatrixTests`; E7 S5.)
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

# E33 S20 part 3 (G77): per-speaker-group EQ on a 5.1 session in linear phase, against an RBJ model at the eight rates.
if selected e33_eq_groups_reference; then
    echo "::group::e33_eq_groups_reference"
    if python3 ci/acoustic_reference_lab/e33_eq_groups_reference.py; then
        passed+=(e33_eq_groups_reference)
    else
        failed+=(e33_eq_groups_reference)
    fi
    echo "::endgroup::"
fi
