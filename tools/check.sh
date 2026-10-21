#!/usr/bin/env bash
# Regenerates the project, builds, and runs the full unit-test suite.
# Prints the executed/failed counts; exits non-zero on any build or test failure.
set -uo pipefail
cd "$(dirname "$0")/.."
log="${1:-/tmp/parley-check.log}"

xcodegen generate >/dev/null || exit 1
xcodebuild test -project Parley.xcodeproj -scheme Parley \
  -destination 'platform=macOS,arch=arm64' >"$log" 2>&1
status=$?

grep -E '^/[^ ]+:[0-9]+:[0-9]+: error: ' "$log" | sort -u | head -20
grep -E "Test Case .* failed" "$log" | head -20
summary=$(grep -E "Executed [0-9]+ tests" "$log" | tail -1 | sed 's/^[[:space:]]*//')
echo "${summary:-no test summary (build failed?)}"
echo "xcodebuild exit $status, log $log"
exit $status
