#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$project_dir/work"
test_dir="$(mktemp -d "$project_dir/work/quota-retry.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/cache" \
  "$project_dir/native/SharedQuotaRetry.swift" "$project_dir/native/tests/QuotaRetryTests.swift" \
  -o "$test_dir/tests"
"$test_dir/tests"
