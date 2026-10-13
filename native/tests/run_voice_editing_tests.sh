#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_root="$project_dir/work/voice-edit-update/logic-tests"
mkdir -p "$test_root/src" "$test_root/VoiceEditingTests.app/Contents/MacOS"
cp "$project_dir/native/"*.swift "$test_root/src/"
# Compile the actual view model in an isolated test bundle with its own Keychain namespace.
python3 - "$test_root" <<'PY'
import pathlib, sys, plistlib
p=pathlib.Path(sys.argv[1])
main=p/'src/MacTranslatorApp.swift'
main.write_text(main.read_text().split('@main\nstruct TranslationApp: App')[0])
model=p/'src/TranslatorViewModel.swift'
s=model.read_text()
# Never contact DeepL with the fixture key or modify production account usage.
s=s.replace('Task { await self.refreshSelectedEngineUsage() }', '// Usage fetch suppressed in isolated tests.')
model.write_text(s)
info={'CFBundleIdentifier':'cn.yike.voiceeditingtests','CFBundleExecutable':'VoiceEditingTests','CFBundleName':'VoiceEditingTests','CFBundlePackageType':'APPL'}
(p/'VoiceEditingTests.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -target arm64-apple-macos13.0 -parse-as-library -module-cache-path "$test_root/cache" \
  "$test_root/src/"*.swift "$project_dir/native/tests/VoiceEditingTests.swift" \
  -o "$test_root/VoiceEditingTests.app/Contents/MacOS/VoiceEditingTests"
"$test_root/VoiceEditingTests.app/Contents/MacOS/VoiceEditingTests"
