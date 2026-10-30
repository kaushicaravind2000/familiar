#!/bin/bash
# Builds build/Familiar.app and build/Familiar.dmg.
#   ./build.sh            the app and the DMG
#   ./build.sh --no-dmg   only the app
# The models aren't bundled: the app downloads EmbeddingGemma from Hugging Face on first launch (865 MB), and, if
# you turn them on, the answer model (2.7 GB) and the speech models (1.2 GB).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Familiar"
OUT=build
APP="$OUT/$APP_NAME.app"

# llama-server, the embedding helper (only rebuilt when its pinned commit changes).
scripts/build-llama-server.sh

swift build -c release --product FamiliarApp
swift build -c release --product fam
BIN_DIR="$(swift build -c release --show-bin-path)"
# The speech-to-text helper (Parakeet through FluidAudio): its own package, because FluidAudio needs macOS 14.
swift build -c release --package-path Transcriber --product familiar-speech
TRANSCRIBER="$(swift build -c release --package-path Transcriber --show-bin-path)/familiar-speech"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN_DIR/FamiliarApp" "$APP/Contents/MacOS/$APP_NAME"
cp Vendor/llama-build/bin/llama-server "$APP/Contents/Helpers/llama-server"
cp "$BIN_DIR/fam" "$APP/Contents/Helpers/fam"
cp "$TRANSCRIBER" "$APP/Contents/Helpers/familiar-speech"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp CREDITS.md THIRD-PARTY-NOTICES.md "$APP/Contents/Resources/"   # the About box's credits, and the licences shipped

# The icon, drawn by scripts/make-icon.swift, at every size macOS asks for.
ICONSET="$OUT/AppIcon.iconset"
if [[ ! -f "$OUT/AppIcon.icns" || scripts/make-icon.swift -nt "$OUT/AppIcon.icns" ]]; then
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$OUT/icon-1024.png"
  for size in 16 32 128 256 512; do
    sips -z $size $size "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    sips -z $((size * 2)) $((size * 2)) "$OUT/icon-1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT/AppIcon.icns"
  rm -rf "$ICONSET"
fi
cp "$OUT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Signed with "Familiar Self-Signed" when it's in the keychain (scripts/make-signing-identity.sh), so macOS keeps
# the app's permissions from one build to the next; otherwise ad-hoc, and every build asks for them again. Neither
# satisfies Gatekeeper: for that, a Developer ID and notarization (SIGN_ID="Developer ID Application: …" ./build.sh,
# then xcrun notarytool).
if [[ -z "${SIGN_ID:-}" ]] && security find-certificate -c "Familiar Self-Signed" >/dev/null 2>&1; then
  SIGN_ID="Familiar Self-Signed"
fi
IDENTITY="${SIGN_ID:--}"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/llama-server"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/fam"
codesign --force --sign "$IDENTITY" --options runtime "$APP/Contents/Helpers/familiar-speech"
codesign --force --sign "$IDENTITY" --options runtime --entitlements Resources/Familiar.entitlements "$APP"
echo "Built $APP"

if [[ "${1:-}" != "--no-dmg" ]]; then
  STAGE="$OUT/dmg"
  rm -rf "$STAGE" "$OUT/$APP_NAME.dmg"
  mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$OUT/$APP_NAME.dmg" > /dev/null
  rm -rf "$STAGE"
  echo "Built $OUT/$APP_NAME.dmg"
fi
