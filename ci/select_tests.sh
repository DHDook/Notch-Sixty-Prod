#!/usr/bin/env bash
# Chooses which XCTest classes the PR check runs from the paths a PR changes, using the rules
# in ci/test_groups.map. Prints either the single word ALL (run the whole suite) or one
# -only-testing:NotchSixtyTests/<Class> argument per line.
#
#   ci/select_tests.sh <changed-path>...        paths as arguments
#   ci/select_tests.sh < paths.txt              or one path per line on stdin
#   ci/select_tests.sh --base origin/main       paths from git diff against the merge base
#
# Fail safe: no paths, an unmapped path, a group that matches no test file, or any error prints ALL.
set -uo pipefail
cd "$(dirname "$0")/.."
MAP="${N60_TEST_GROUP_MAP:-ci/test_groups.map}"
TESTS_DIR="${N60_TESTS_DIR:-NotchSixtyTests}"

paths=()
if [ "${1:-}" = "--base" ]; then
    mapfile_out=$(git diff --name-only "$2...HEAD") || { echo ALL; exit 0; }
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done <<< "$mapfile_out"
elif [ "$#" -gt 0 ]; then
    paths=("$@")
else
    while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done
fi
[ "${#paths[@]}" -gt 0 ] || { echo ALL; exit 0; }
[ -f "$MAP" ] || { echo ALL; exit 0; }

stems=""   # newline-separated test stems selected
add_matching() {   # $1 = glob over test stems
    local f s
    for f in "$TESTS_DIR"/$1.swift; do
        [ -f "$f" ] || continue
        s=$(basename "$f" .swift)
        stems="$stems"$'\n'"$s"
    done
}

any_tests=0
for path in "${paths[@]}"; do
    action=""
    while IFS= read -r line; do
        case "$line" in ''|'#'*) continue ;; esac
        pat=${line%%[[:space:]]*}
        act=${line#"$pat"}
        act=${act#"${act%%[![:space:]]*}"}
        # shellcheck disable=SC2254
        case "$path" in $pat) action="$act"; break ;; esac
    done < "$MAP"
    case "$action" in
        "")     echo ALL; exit 0 ;;
        ALL)    echo ALL; exit 0 ;;
        IGNORE) continue ;;
        SELF)   s=$(basename "$path" .swift); add_matching "$s"; any_tests=1 ;;
        *)
            any_tests=1
            fstem=$(basename "$path"); fstem=${fstem%.*}
            IFS=',' read -r -a toks <<< "$action"
            for t in "${toks[@]}"; do
                if [ "$t" = "@stem" ]; then add_matching "${fstem}*"; else add_matching "$t"; fi
            done
            ;;
    esac
done

[ "$any_tests" -eq 1 ] || { echo ALL; exit 0; }   # only ignorable paths: be safe
out=""
for s in $(printf '%s\n' "$stems" | sort -u); do
    classes=$(grep -hoE '^(final )?class [A-Za-z0-9_]+ *: *XCTestCase' "$TESTS_DIR/$s.swift" | sed -E 's/^(final )?class ([A-Za-z0-9_]+).*/\2/')
    for c in $classes; do out="$out-only-testing:NotchSixtyTests/$c"$'\n'; done
done
[ -n "$out" ] || { echo ALL; exit 0; }
printf '%s' "$out"
