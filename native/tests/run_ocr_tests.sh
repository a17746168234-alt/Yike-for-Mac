#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$project_dir/work/ocr2-tests"
mkdir -p "$test_dir"
xcrun swiftc -parse-as-library -module-cache-path "$test_dir/module-cache" \
  "$project_dir/native/TranslationCore.swift" "$project_dir/native/ImageModels.swift" \
  "$project_dir/native/OCRDocument.swift" "$project_dir/native/OCRService.swift" \
  "$project_dir/native/TextLayout.swift" "$project_dir/native/ImageRenderer.swift" "$project_dir/native/TranslationService.swift" "$project_dir/native/TranslationDiagnostics.swift" \
  "$project_dir/native/tests/OCR2Tests.swift" \
  -o "$test_dir/OCR2Tests"
if [[ "${1:-}" != "--compile-only" ]]; then
  "$test_dir/OCR2Tests" "$project_dir/native/tests/fixtures" "$@"
fi
