#!/usr/bin/env bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
speech_source="$project_dir/work/voice-edit-update/whisper.cpp"
speech_build="$project_dir/work/voice-edit-update/whisper-build"
speech_commit="a8d002cfd879315632a579e73f0148d06959de36"
cmake_bin="${YIKE_CMAKE:-cmake}"
if ! command -v "$cmake_bin" >/dev/null 2>&1; then
  cmake_bin="$project_dir/work/voice-edit-update/build-tools/cmake/data/bin/cmake"
fi
if [[ ! -x "$cmake_bin" ]] && ! command -v "$cmake_bin" >/dev/null 2>&1; then
  echo "CMake is required to build the bundled speech engine. Install CMake or set YIKE_CMAKE." >&2
  exit 1
fi
if [[ ! -d "$speech_source/.git" ]]; then
  mkdir -p "$(dirname "$speech_source")"
  git clone --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git "$speech_source"
fi
test "$(git -C "$speech_source" rev-parse HEAD)" = "$speech_commit"
"$cmake_bin" -S "$speech_source" -B "$speech_build" \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  -DCMAKE_OSX_SYSROOT="$(xcrun --sdk macosx --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DBUILD_SHARED_LIBS=OFF -DGGML_NATIVE=OFF \
  -DGGML_BLAS=OFF -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_CURL=OFF
"$cmake_bin" --build "$speech_build" --target whisper-cli -j 4
