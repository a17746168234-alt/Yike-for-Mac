#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$project_dir/work/language-tests"
mkdir -p "$test_root/src"
cp "$project_dir/native/"*.swift "$test_root/src/"
python3 - "$test_root/src/MacTranslatorApp.swift" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('@main\nstruct TranslationApp: App', 'struct TranslationApp: App'))
PY
xcrun swiftc -target arm64-apple-macos13.0 -parse-as-library -module-cache-path "$test_root/cache" \
  "$test_root/src/"*.swift "$project_dir/native/tests/LanguageSupportTests.swift" -o "$test_root/language-tests"
"$test_root/language-tests"
