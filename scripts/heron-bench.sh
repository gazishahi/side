#!/bin/zsh
# Heron's token benchmark (docs/SIDE_RFC_HERON_EFFICIENCY.md, Q3): a few fixed tasks on a fixture
# project, against the real Anthropic API, with your own ANTHROPIC_API_KEY. It spends money:
# about $1 a run on Sonnet 5, and stops past $3.
#
#   scripts/heron-bench.sh                 Sonnet 5
#   scripts/heron-bench.sh claude-opus-5-5 another model
#   SIDE_HERON_BENCH_TASKS=cancel scripts/heron-bench.sh   only some tasks (explain, discounts, cancel)
#
# The report is build/heron-bench/<date>-<model>.json; the table prints as it runs.
set -uo pipefail
cd "$(dirname "$0")/.."
# The key: ANTHROPIC_API_KEY if the API accepts it, else the one Side keeps in the Keychain
# (macOS asks before handing it over). The check is a free request (the model list).
valid() { [[ -n "$1" ]] && [[ "$(curl -s -o /dev/null -w '%{http_code}' https://api.anthropic.com/v1/models \
  -H "x-api-key: $1" -H 'anthropic-version: 2023-06-01')" == 200 ]]; }
if ! valid "${ANTHROPIC_API_KEY:-}"; then
  [[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "ANTHROPIC_API_KEY isn't accepted by the API; trying the key Side keeps in the Keychain." >&2
  ANTHROPIC_API_KEY=$(security find-generic-password -s com.shahi.side.provider-credential -a anthropic -w 2>/dev/null || true)
  if ! valid "$ANTHROPIC_API_KEY"; then echo "No working Anthropic key: set ANTHROPIC_API_KEY, or save one in Side's Settings." >&2; exit 1; fi
  export ANTHROPIC_API_KEY
fi
model=${1:-claude-sonnet-5}
mkdir -p build/heron-bench
out="$PWD/build/heron-bench/$(date +%Y-%m-%d-%H%M)-$model.json"
cd Packages/Heron
SIDE_HERON_BENCH=1 SIDE_HERON_BENCH_MODEL=$model SIDE_HERON_BENCH_OUT=$out \
  swift test --filter HeronBenchmarkTests 2>&1 | grep -E "HERONBENCH|error:|failed" | sed 's/^HERONBENCH //'
echo "Report: $out"
