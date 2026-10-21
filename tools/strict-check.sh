#!/usr/bin/env bash
# Builds app + tests with SWIFT_STRICT_CONCURRENCY=complete and ratchets the
# diagnostic count: fails if it rises above tools/strict-baseline.txt, and
# lowers the baseline when it drops. `--update` rewrites the baseline as-is.
set -uo pipefail
cd "$(dirname "$0")/.."
log=/tmp/parley-strict.log
diags=/tmp/parley-strict-diags.txt
baseline_file=tools/strict-baseline.txt

xcodegen generate >/dev/null || exit 1
# Incremental builds only re-emit diagnostics for recompiled files.
find Parley ParleyTests -name '*.swift' -exec touch {} +
xcodebuild build-for-testing -project Parley.xcodeproj -scheme Parley \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/parley-strict \
  SWIFT_STRICT_CONCURRENCY=complete >"$log" 2>&1
status=$?

grep -oE "^$PWD/(Parley|ParleyTests)/[^ ]+:[0-9]+:[0-9]+: (warning|error): .*" "$log" \
  | sed "s#^$PWD/##" | sort -u >"$diags"
count=$(wc -l <"$diags" | tr -d ' ')
errors=$(grep -c ': error: ' "$diags")
echo "strict diagnostics: $count ($errors errors), build exit $status, list $diags"

if [[ "${1:-}" == "--update" ]]; then
  echo "$count" >"$baseline_file"; echo "baseline set to $count"; exit 0
fi
baseline=$(cat "$baseline_file" 2>/dev/null || echo 999999)
if (( status != 0 )); then echo "strict build failed"; exit 1; fi
if (( count > baseline )); then echo "regressed: $count > baseline $baseline"; exit 1; fi
if (( count < baseline )); then echo "$count" >"$baseline_file"; echo "baseline lowered $baseline -> $count"; fi
exit 0
