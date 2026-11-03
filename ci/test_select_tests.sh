#!/usr/bin/env bash
# Behavioural check of ci/select_tests.sh over sample path lists (not a source-text validator).
# Run by ci/run_harnesses.sh via the PR check.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
check() {   # name, expected (ALL | none-ALL | contains:<text> | lacks:<text>), paths...
    local name=$1 want=$2; shift 2
    local out; out=$(ci/select_tests.sh "$@" < /dev/null)
    case "$want" in
        ALL)       [ "$out" = "ALL" ] || { echo "FAIL $name: expected ALL"; fail=1; return; } ;;
        subset)    { [ "$out" != "ALL" ] && [ -n "$out" ]; } || { echo "FAIL $name: expected a subset"; fail=1; return; } ;;
        contains:*) printf '%s\n' "$out" | grep -qx -- "-only-testing:NotchSixtyTests/${want#contains:}" || { echo "FAIL $name: missing ${want#contains:}"; fail=1; return; } ;;
        lacks:*)   ! printf '%s\n' "$out" | grep -qx -- "-only-testing:NotchSixtyTests/${want#lacks:}" || { echo "FAIL $name: unexpected ${want#lacks:}"; fail=1; return; } ;;
    esac
    echo "ok   $name"
}
total=$(ls NotchSixtyTests/*Tests.swift | wc -l | tr -d ' ')

check "audio runs all"            ALL NotchSixty/Audio/RoomCorrectionCore.swift
check "realtime runs all"         ALL NotchSixty/Audio/Realtime/N60RenderKernel.c
check "pbxproj runs all"          ALL NotchSixty.xcodeproj/project.pbxproj
check "workflow runs all"         ALL .github/workflows/pr.yml
check "package runs all"          ALL Package.swift
check "unmapped runs all"         ALL somewhere/new/file.txt
check "mixed with audio runs all" ALL NotchSixty/UI/ProductionRootView.swift NotchSixty/Audio/CrossoverCore.swift
check "mixed with unmapped"       ALL NotchSixty/State/SystemSetupFlow.swift artwork/icon.png
check "no paths runs all"         ALL
check "docs only runs all (safe)" ALL docs/PROGRAM_PLAN.md
check "state subset"              subset NotchSixty/State/SystemSetupFlow.swift
check "state own test"            contains:SystemSetupFlowTests NotchSixty/State/SystemSetupFlow.swift
check "state excludes audio test" lacks:CrossoverCoreTests NotchSixty/State/SystemSetupFlow.swift
check "ui group"                  contains:ProductionSystemAreaTests NotchSixty/UI/ProductionRootView.swift
check "docs ignored in mix"       lacks:CrossoverCoreTests NotchSixty/UI/ProductionRootView.swift docs/x.md
check "test file selects itself"  contains:SeatMeasurerTests NotchSixtyTests/SeatMeasurerTests.swift
check "non-test test file"        ALL NotchSixtyTests/ReferenceRoomTransport.swift

n=$(ci/select_tests.sh NotchSixty/State/SystemSetupFlow.swift | wc -l | tr -d ' ')
[ "$n" -lt "$total" ] || { echo "FAIL state selection is not smaller than the suite"; fail=1; }
exit $fail
