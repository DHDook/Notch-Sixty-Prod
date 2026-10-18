#!/usr/bin/env bash
# Runs every command in ci/legacy_validators.txt and reports all failures, not
# just the first. E1 S3 shrinks the list to nothing.
set -uo pipefail
cd "$(dirname "$0")/.."
failed=()
count=0
while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    count=$((count + 1))
    # shellcheck disable=SC2086
    if ! python3 $line >/dev/null 2>"${RUNNER_TEMP:-/tmp}/legacy-validator.err"; then
        failed+=("$line")
        echo "FAILED: $line"
        tail -5 "${RUNNER_TEMP:-/tmp}/legacy-validator.err"
    fi
done < ci/legacy_validators.txt
echo "Legacy validators run: $count, failed: ${#failed[@]}"
[ ${#failed[@]} -eq 0 ]
