#!/bin/bash
# Builds llama.cpp's llama-server (MIT) at a pinned commit: one static binary with Metal and its shaders embedded,
# which the app runs as its embedding helper. Output: Vendor/llama-build/bin/llama-server. Does nothing when that
# build is already there. Needs cmake (brew install cmake).
set -euo pipefail
cd "$(dirname "$0")/.."
# The first llama.cpp builds with EmbeddingGemma 2 (text + vision + audio) are b11452+; this is b11461.
COMMIT=4d756bc72bf00a4aacf410ae15a2d315f3db400d
TARGET=13.0   # the oldest macOS the app supports
SOURCE=Vendor/llama.cpp
BUILD=Vendor/llama-build
BIN="$BUILD/bin/llama-server"
# Our changes on top of the pinned commit, applied to a clean checkout. llama-metal-idle: the Metal backend's residency
# heartbeat woke the CPU every 5 ms forever, ~50 wake-ups a second in an idle server; now every 250 ms while in use,
# and not at all once idle.
PATCHES=(patches/llama-metal-idle.patch)
STAMP="$COMMIT $TARGET $(cat "${PATCHES[@]}" | shasum | cut -c1-12)"

if [[ -x "$BIN" && "$(cat "$BUILD/COMMIT" 2>/dev/null)" == "$STAMP" ]]; then
  exit 0
fi

if [[ ! -d "$SOURCE/.git" ]]; then
  mkdir -p Vendor
  git init -q "$SOURCE"
  git -C "$SOURCE" remote add origin https://github.com/ggml-org/llama.cpp
fi
if [[ "$(git -C "$SOURCE" rev-parse HEAD 2>/dev/null)" != "$COMMIT" ]]; then
  git -C "$SOURCE" fetch -q --depth 1 origin "$COMMIT"
  git -C "$SOURCE" checkout -q FETCH_HEAD
fi
git -C "$SOURCE" checkout -q -- .
for patch in "${PATCHES[@]}"; do git -C "$SOURCE" apply "$PWD/$patch"; done

cmake -S "$SOURCE" -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON -DCMAKE_OSX_DEPLOYMENT_TARGET="$TARGET" \
  > "$BUILD.cmake.log" 2>&1
cmake --build "$BUILD" --target llama-server -j "$(sysctl -n hw.ncpu)" > "$BUILD.log" 2>&1
echo "$STAMP" > "$BUILD/COMMIT"
echo "Built $BIN"
