#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$project_dir/work"
test_work_dir="$(mktemp -d "$project_dir/work/online-tts-tests.XXXXXX")"
trap 'rm -rf "$test_work_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$test_work_dir/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$test_work_dir/swift-module-cache"

xcrun swiftc -target arm64-apple-macos13.0 -parse-as-library \
  "$project_dir/native/OnlineTTSService.swift" \
  "$project_dir/native/tests/OnlineTTSProtocolTests.swift" \
  -o "$test_work_dir/OnlineTTSProtocolTests"

"$test_work_dir/OnlineTTSProtocolTests" "$test_work_dir"
