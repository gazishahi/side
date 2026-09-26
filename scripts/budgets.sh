#!/bin/zsh
# Every performance budget, measured in an optimized build, as one table
# (SIDETests/Budgets.swift holds the limits). Exits non-zero if any is over.
#
#   scripts/budgets.sh              all of them (about 15 minutes)
#   scripts/budgets.sh Review Find  only those suites (ReviewBudgetTests, FindBudgetTests)
#
# Run it on a quiet machine: other apps' work shows up in the frame and CPU numbers.
set -uo pipefail
cd "$(dirname "$0")/.."
suites=(AlloyBudgetTests CompletionBudgetTests FindBudgetTests ReviewBudgetTests ThinkBudgetTests AppBudgetTests)
if (( $# > 0 )); then suites=(); for name in "$@"; do suites+=("${name}BudgetTests"); done; fi
only=(); for suite in $suites; do only+=("-only-testing:SIDETests/$suite"); done
log=build/budgets.log
mkdir -p build
echo "==> Building (optimized); the log is $log"
rm -f build/budgets/Build/Products/*.xctestrun
xcodebuild -project SIDE.xcodeproj -scheme SIDE -destination 'platform=macOS' -configuration Release \
  -derivedDataPath build/budgets ENABLE_TESTABILITY=YES ENABLE_HARDENED_RUNTIME=NO build-for-testing > "$log" 2>&1 || { grep -m5 "error: " "$log"; exit 1; }
# Xcode loads its Main Thread Checker into every test run; it checks each AppKit call and
# makes the UI read slower than it is. The run file goes without it.
xctestrun=$(ls build/budgets/Build/Products/*.xctestrun | head -1)
python3 - "$xctestrun" <<'PY'
import os, plistlib, sys
path = sys.argv[1]
with open(path, "rb") as f: plan = plistlib.load(f)
def strip(env):
    if "DYLD_INSERT_LIBRARIES" in env:
        env["DYLD_INSERT_LIBRARIES"] = ":".join(p for p in env["DYLD_INSERT_LIBRARIES"].split(":") if "MainThreadChecker" not in p)
for config in plan.get("TestConfigurations", []):
    for target in config.get("TestTargets", []):
        for key in ("TestingEnvironmentVariables", "EnvironmentVariables"):
            strip(target.get(key, {}))
        env = target.setdefault("TestingEnvironmentVariables", {})
        env["SIDE_BUDGETS"] = "1"
        # TEST_RUNNER_X=value in this script's environment reaches the tests as X, as with xcodebuild test.
        for key, value in os.environ.items():
            if key.startswith("TEST_RUNNER_"): env[key[len("TEST_RUNNER_"):]] = value
with open(path, "wb") as f: plistlib.dump(plan, f)
PY
echo "==> Measuring (${suites[*]})"
xcodebuild -xctestrun "$xctestrun" -destination 'platform=macOS' -parallel-testing-enabled NO test-without-building "${only[@]}" >> "$log" 2>&1
result=$?
echo
grep "^BUDGET	" "$log" | awk -F'\t' '
  BEGIN { printf "%-4s  %-7s %-58s %14s  %-12s\n", "", "Area", "Measure", "Measured", "Budget"; over = 0 }
  { printf "%-4s  %-7s %-58s %14s  %-12s\n", $2, $3, substr($4, 1, 58), $5, $6; if ($7 != "") printf "              %s\n", $7; if ($2 ~ /OVER/) over++ }
  END { printf "\n%d measured, %d over budget\n", NR, over }'
grep "^BUDGETNOTE" "$log" | sort -u | sed 's/^BUDGETNOTE /  Note: /'
grep -E "^Test Case .*(failed|skipped)" "$log" | sed 's/^/  /'
grep -E "(: error: |^error: )" "$log" | head -5
exit $result
