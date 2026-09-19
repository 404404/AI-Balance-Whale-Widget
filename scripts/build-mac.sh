#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(node -p "require('./package.json').version")}"
BUILD_NUMBER="${BUILD_NUMBER:-${GITHUB_RUN_NUMBER:-1}}"
DIST="$ROOT/dist"
ICON="$ROOT/build/AI Balance Whale.icns"
rm -rf "$DIST/AI Balance Whale.app" "$DIST/AI Balance Whale-darwin-arm64" "$ROOT/build"
mkdir -p "$DIST" "$ROOT/build"
bash scripts/make-mac-icon.sh assets/DSniang1.png "$ICON"

npx electron-packager . "AI Balance Whale" \
  --platform=darwin \
  --arch=arm64 \
  --out="$DIST" \
  --overwrite \
  --asar \
  --prune=true \
  --app-bundle-id=com.404404.deepseekbalancewhale \
  --app-version="$VERSION" \
  --build-version="$BUILD_NUMBER" \
  --icon="$ICON" \
  --ignore='(^|/)(\.git|dist|build|qa-output|tests)(/|$)'

PACKAGED="$DIST/AI Balance Whale-darwin-arm64/AI Balance Whale.app"
if [[ ! -d "$PACKAGED" ]]; then
  echo "electron-packager did not produce $PACKAGED" >&2
  exit 1
fi
mv "$PACKAGED" "$DIST/AI Balance Whale.app"
rmdir "$DIST/AI Balance Whale-darwin-arm64" 2>/dev/null || true
codesign --deep --force --verbose --sign - "$DIST/AI Balance Whale.app"
VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" bash scripts/verify-mac-app.sh "$DIST/AI Balance Whale.app"
