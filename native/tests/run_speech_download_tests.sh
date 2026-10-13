#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/../.." && pwd)"
test_dir="$project_dir/work/voice-download-fix/network-tests"
mkdir -p "$test_dir"
python3 - "$test_dir/port" <<'PY' &
import http.server, pathlib, sys, time
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Length', '2097152')
        self.end_headers()
        try:
            for _ in range(64):
                self.wfile.write(b'x' * 32768)
                self.wfile.flush()
                time.sleep(0.03 if self.path == '/slow' else 0.003)
        except (BrokenPipeError, ConnectionResetError): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT
xcrun swiftc -target arm64-apple-macos13.0 -parse-as-library -module-cache-path "$test_dir/cache" \
  "$project_dir/native/LocalSpeechRecognizer.swift" "$project_dir/native/tests/SpeechDownloadTests.swift" \
  -o "$test_dir/SpeechDownloadTests"
"$test_dir/SpeechDownloadTests" "http://127.0.0.1:$(cat "$test_dir/port")"
