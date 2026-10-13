#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
mkdir -p "$project_dir/work"
test_work_dir="$(mktemp -d "$project_dir/work/translation-tests.XXXXXX")"
test_binary="$test_work_dir/TranslationCoreTests"
trap 'rm -rf "$test_work_dir"' EXIT
export CLANG_MODULE_CACHE_PATH="$test_work_dir/clang-module-cache"
export SWIFT_MODULE_CACHE_PATH="$test_work_dir/swift-module-cache"

xcrun swiftc \
  "$project_dir/native/TranslationCore.swift" \
  "$project_dir/native/SelectionShortcut.swift" \
  "$project_dir/native/SecureKeyStore.swift" \
  "$project_dir/native/tests/TranslationCoreTests.swift" \
  -framework Security \
  -o "$test_binary"

"$test_binary"
